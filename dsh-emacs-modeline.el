;;; dsh-emacs-modeline.el --- Mode-line status section for dsh-emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2025 vritser

;; Author: vritser
;; Version: 0.1.0
;; License: GPL-3.0-or-later
;; Package-Requires ((emacs "27.1"))

;;; Commentary:

;; 统计段拼接进 mode-line-format（紧跟 DSH 模式名之后、行尾区），展示
;; model • effort • preset • cwd • branch • tokens • ctx% • cost。
;; 布局参考 pi-mono 的 footer（终端底部状态条）设计；ctx 与 model/effort
;; 数据口径与 dsh web 对齐（服务器推送 contextPressure projection）。
;;
;; 公开 API：
;;
;;   (dsh-emacs-modeline-format)              ;;  当前 mode-line 字符串
;;   (dsh-emacs-modeline-update)              ;;  立即刷新 mode-line
;;   (dsh-emacs-modeline-toggle)              ;;  切换 mode-line 显示/隐藏
;;   (dsh-emacs-modeline-set-usage usage)     ;;  设置累计 token usage
;;   (dsh-emacs-modeline-add-usage usage)     ;;  累加 usage 并刷新
;;   (dsh-emacs-modeline-note-event event)    ;;  从 assistant/message 事件累计 usage
;;   (dsh-emacs-modeline-set-model "claude-opus-4-5") ;; 设置模型名
;;   (dsh-emacs-modeline-set-provider "deepseek")     ;; 设置模型所属 provider
;;   (dsh-emacs-modeline-set-effort "max")   ;; 设置推理 effort
;;   (dsh-emacs-modeline-set-preset "code")  ;; 设置 agent preset
;;
;; 用户可通过 `dsh-emacs-modeline-format-spec' 自定义显示哪些段（默认全部）。

;;; Code:

(require 'cl-lib)
(require 'dsh-emacs-ui)
(require 'dsh-emacs-faces)
(require 'dsh-emacs-tokens)

;; doom-modeline 集成只引用不依赖：有则用官方 API 把统计段插进它的
;; 布局（紧跟 major-mode 段），没有则退回原生的 mode-line-format splice。
(declare-function doom-modeline-def-segment "doom-modeline-core" (name &rest body))
(declare-function doom-modeline-add-segment "doom-modeline-core" (segment anchor &optional position modeline))
(declare-function doom-modeline-remove-segment "doom-modeline-core" (segment &optional modeline))

;;; ---------------------------------------------------------------------------
;;; 定制
;;; ---------------------------------------------------------------------------

(defgroup dsh-emacs-modeline nil
  "Mode-line status section for `dsh-emacs'."
  :group 'dsh-emacs
  :prefix "dsh-emacs-")

(defcustom dsh-emacs-modeline-enabled t
  "Whether the mode-line line is enabled."
  :type 'boolean
  :group 'dsh-emacs-modeline)

(defcustom dsh-emacs-modeline-format-spec
  '(:separator " "
    :segments (model effort preset ctx))
  "Plist describing the mode-line segments to render and the separator.
The compact status line sits right next to the DSH mode name in the mode
line, e.g.  DSH(deepseek-v4-flash·max·code CH95%).  Each segment is one of:
  model   — model id (e.g. deepseek-v4-flash)
  effort  — reasoning effort (effortId, e.g. off/max)
  preset  — agent preset (agentPreset: standard/minimal/code/cordis)
  cwd     — short cwd (~/foo)
  branch  — git current branch (or empty if unavailable)
  tokens  — token usage (↑input ↓output CH% cache-hit)
  ctx     — context window usage percentage
  cost    — cumulative USD cost

Customize by toggling checkboxes: uncheck a segment to remove it from the
mode line; the `:separator' is a separate string field."
  :type '(list :tag "Mode-line format"
          (const :format "Separator between segments: " :separator)
          (string :format "%v\n")
          (const :format "Segments shown in the mode line: " :segments)
          (set :greedy t
               (const :tag "model — model id" model)
               (const :tag "effort — reasoning effort" effort)
               (const :tag "preset — agent preset" preset)
               (const :tag "cwd — working directory" cwd)
               (const :tag "branch — git branch" branch)
               (const :tag "tokens — token usage ↑↓CH%" tokens)
               (const :tag "ctx — context window %" ctx)
               (const :tag "cost — cost in USD" cost)))
  :group 'dsh-emacs-modeline)

(defcustom dsh-emacs-modeline-branch-refresh-interval 10
  "Seconds to cache the git branch shown in the mode-line.
The branch segment runs `git rev-parse' in a subprocess, which is far too
expensive to re-run on every mode-line redraw (the running animation alone
forces a redraw ~12x/s while dsh is executing).  Within this interval the
last result — including a \"not a git repo\" nil — is reused."
  :type 'number
  :group 'dsh-emacs-modeline)

;;; ---------------------------------------------------------------------------
;;; 内部状态（buffer-local）
;;; ---------------------------------------------------------------------------

(defvar-local dsh-emacs--modeline-cwd nil
  "Override the cwd displayed in the mode-line. Default: use `default-directory'.")

(defvar-local dsh-emacs--modeline-branch nil
  "Override the git branch displayed. Default: detect via `vc-git'.")

(defvar-local dsh-emacs--modeline-branch-cache nil
  "Cons (branch-or-nil . timestamp) memoizing git branch detection.
Nil (no repo) is cached too so non-git dirs never spawn git per redraw.")

(defvar-local dsh-emacs--modeline-model nil
  "Model id displayed in the mode-line.")

(defvar-local dsh-emacs--modeline-provider nil
  "Provider id owning `dsh-emacs--modeline-model', or nil when unknown.
The same model id can exist under several providers (the model selector
already disambiguates rows by provider), so the model segment keeps the
owning provider alongside the id — shown in the tooltip, never guessing.")

(defvar-local dsh-emacs--modeline-effort nil
  "Reasoning effort (effortId, e.g. \"off\"/\"max\") shown in the mode-line.")

(defvar-local dsh-emacs--modeline-preset nil
  "Agent preset (agentPreset id, e.g. \"standard\"/\"code\") shown in the mode-line.")

(defvar-local dsh-emacs--modeline-context-window-server nil
  "Context window from the server's `contextPressure' projection (tokens).
Paired with `dsh-emacs--modeline-context-pressure': both come from the same
projection, so the ctx% divisor always matches the occupancy — even right
after a model switch.")

(defvar-local dsh-emacs--modeline-context-pressure nil
  "Server-reported current context occupancy (tokens), or nil.
Fed from the `contextPressure' projection (projectedTokens ?? pressureTokens,
dsh web's ctx-meter口径) — live via `session/projection' frames, and seeded
from the `session.list' snapshot when a chat buffer opens.  Pairs with
`dsh-emacs--modeline-context-window-server'.  Nil hides the ctx segment.")

(defvar-local dsh-emacs--modeline-usage nil
  "Latest usage struct (see `dsh-emacs-usage').")

(defvar-local dsh-emacs--modeline-overlay nil
  "Overlay for the structural end-of-buffer newline that the
input-area geometry relies on (not part of the mode line proper).")

(defvar-local dsh-emacs-modeline--modeline-patched nil
  "Non-nil once dsh segments were spliced into this buffer's mode-line-format.")

(defvar dsh-emacs-modeline--doom-segment-installed nil
  "Non-nil once the dsh stats segment is registered with doom-modeline.")

;;; ---------------------------------------------------------------------------
;;; 路径简化
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-modeline--shorten-cwd (cwd)
  "Shorten CWD using ~/ prefix when possible."
  (let* ((home (or (getenv "HOME") (user-login-name)))
         (home-dir (and home (expand-file-name (file-name-as-directory home))))
         (cwd (or cwd default-directory)))
    (if (and home-dir
             (string-prefix-p home-dir (expand-file-name cwd)))
        (concat "~" (substring (expand-file-name cwd) (length home-dir)))
      cwd)))

(defun dsh-emacs-modeline--detect-branch ()
  "Return current git branch, or nil.
Uses `call-process' straight on the git binary — no intermediate shell —
because this runs in the mode-line path and must stay cheap."
  (when (and default-directory (not (file-remote-p default-directory)))
    (ignore-errors
      (let ((default-directory (or dsh-emacs--modeline-cwd default-directory)))
        (with-temp-buffer
          (let ((ret (call-process "git" nil t nil
                                   "rev-parse" "--abbrev-ref" "HEAD")))
            (when (eq 0 ret)
              (string-trim (buffer-string)))))))))

(defun dsh-emacs-modeline--cached-branch ()
  "Return the git branch from cache, refreshing when stale.
Refreshes at most once per `dsh-emacs-modeline-branch-refresh-interval'
seconds; a nil (non-repo) result is cached the same way."
  (let* ((now (float-time))
         (cached dsh-emacs--modeline-branch-cache))
    (if (and cached (<= (- now (cdr cached))
                        dsh-emacs-modeline-branch-refresh-interval))
        (car cached)
      (let ((branch (dsh-emacs-modeline--detect-branch)))
        (setq dsh-emacs--modeline-branch-cache (cons branch now))
        branch))))

;;; ---------------------------------------------------------------------------
;;; 各段格式化
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-modeline--annotate (text tooltip)
  "Return TEXT with TOOLTIP attached as its `help-echo' plus the
standard mode-line hover affordance: `mouse-face' set to
`mode-line-highlight', so the segment's extent shows a box border
while the mouse is over it (the same face the built-in mode-line
elements use; GUI renders it as a released-button box, terminal as
inverse video).  Passes TEXT through unchanged when nil/empty,
keeping the existing hidden-segment semantics intact."
  (if (or (null text) (string-empty-p text))
      text
    (propertize text 'help-echo tooltip
                'mouse-face 'mode-line-highlight)))

(defun dsh-emacs-modeline--segment-cwd ()
  "Render the cwd segment."
  (let ((cwd (dsh-emacs-modeline--shorten-cwd (or dsh-emacs--modeline-cwd default-directory))))
    (dsh-emacs-modeline--annotate
     (propertize cwd 'face 'dsh-emacs-modeline-face)
     (format "Working directory: %s"
             (or dsh-emacs--modeline-cwd default-directory)))))

(defun dsh-emacs-modeline--segment-branch ()
  "Render the git branch segment (cached; see
`dsh-emacs-modeline-branch-refresh-interval')."
  (let ((branch (or dsh-emacs--modeline-branch
                    (dsh-emacs-modeline--cached-branch))))
    (when (and branch (not (string-empty-p branch)))
      (dsh-emacs-modeline--annotate
       (concat (propertize "(" 'face 'dsh-emacs-modeline-face)
               (propertize branch 'face 'dsh-emacs-modeline-face)
               (propertize ")" 'face 'dsh-emacs-modeline-face))
       (format "Git branch: %s" branch)))))

(defun dsh-emacs-modeline--segment-model ()
  "Render the model segment.
Falls back to `dsh-emacs-default-model' when the per-buffer model was never
set (e.g. a session that predates request events)."
  (let ((model (or dsh-emacs--modeline-model
                   (and (boundp 'dsh-emacs-default-model)
                        dsh-emacs-default-model))))
    (when (and model (not (string-empty-p model)))
      (dsh-emacs-modeline--annotate
       (propertize model 'face 'dsh-emacs-modeline-face)
       (format "Model: %s%s — reasoning model of this session (switch with C-c C-m)"
               model
               (if (and dsh-emacs--modeline-provider
                        (not (string-empty-p dsh-emacs--modeline-provider)))
                   (format " (provider %s)" dsh-emacs--modeline-provider)
                 ""))))))

(defun dsh-emacs-modeline--segment-effort ()
  "Render the reasoning-effort segment (effortId, e.g. \"max\")."
  (when (and dsh-emacs--modeline-effort
             (not (string-empty-p dsh-emacs--modeline-effort)))
    (dsh-emacs-modeline--annotate
     (propertize dsh-emacs--modeline-effort 'face 'dsh-emacs-modeline-face)
     (format "Reasoning effort: %s" dsh-emacs--modeline-effort))))

(defun dsh-emacs-modeline--segment-preset ()
  "Render the agent-preset segment (agentPreset, e.g. \"code\")."
  (when (and dsh-emacs--modeline-preset
             (not (string-empty-p dsh-emacs--modeline-preset)))
    (dsh-emacs-modeline--annotate
     (propertize dsh-emacs--modeline-preset 'face 'dsh-emacs-modeline-face)
     (format "Agent preset: %s" dsh-emacs--modeline-preset))))

(defun dsh-emacs-modeline--segment-tokens ()
  "Render the token usage segment."
  (when dsh-emacs--modeline-usage
    (let* ((u dsh-emacs--modeline-usage)
           (input (dsh-emacs-usage-input u))
           (output (dsh-emacs-usage-output u))
           (cr (dsh-emacs-usage-cache-read u))
           (cw (dsh-emacs-usage-cache-write u))
           (total-prompt (+ (or input 0) (or cr 0) (or cw 0)))
           (ch (if (> total-prompt 0)
                   (* 100.0 (/ (float (or cr 0)) total-prompt))
                 nil))
           parts)
      (when (> input 0) (push (propertize (concat "↑" (dsh-emacs-format-tokens input))
                                          'face 'dsh-emacs-modeline-token-face) parts))
      (when (> output 0) (push (propertize (concat "↓" (dsh-emacs-format-tokens output))
                                           'face 'dsh-emacs-modeline-token-face) parts))
      (when ch (push (propertize (format "CH%.0f%%" ch)
                                 'face 'dsh-emacs-modeline-token-face) parts))
      (when parts
        (let* ((seg (mapconcat
                     #'identity
                     (delq nil
                           (list
                            (and (> input 0)
                                 (format "↑%s in" (dsh-emacs-format-tokens input)))
                            (and (> output 0)
                                 (format "↓%s out" (dsh-emacs-format-tokens output)))
                            (and ch (format "CH%.0f%% cache hit" ch))))
                     " ")))
          (dsh-emacs-modeline--annotate
           (mapconcat #'identity (nreverse parts)
                      (propertize " " 'face 'dsh-emacs-modeline-separator-face))
           (format "Token usage: %s" seg)))))))

(defun dsh-emacs-modeline--segment-ctx ()
  "Render the context-window usage percentage segment.
Only the server's `contextPressure' snapshot is meaningful here: the
segment shows pressureTokens / the same snapshot's contextWindow (the
current prompt's actual occupancy).  Cumulative token usage (input +
cacheRead + cacheWrite) is a session lifetime total — it is NOT \"in\"
the context now, cacheRead alone is usually many times the window, so it
must never be used as ctx% numerator.  Without a server snapshot the
segment renders nothing (nil hides it)."
  (let* ((pressure dsh-emacs--modeline-context-pressure)
         (window dsh-emacs--modeline-context-window-server)
         (pct (and pressure window (> window 0)
                   (min 100.0 (* 100.0 (/ (float pressure) window))))))
    (when pct
      (dsh-emacs-modeline--annotate
       (propertize (dsh-emacs-format-percent pct)
                   'face (dsh-emacs-ctx-face pct))
       (format "Context window: %s (%s / %s tokens)"
               (dsh-emacs-format-percent pct)
               (dsh-emacs-format-tokens pressure)
               (dsh-emacs-format-tokens window))))))

(defun dsh-emacs-modeline--segment-cost ()
  "Render the cost segment."
  (when dsh-emacs--modeline-usage
    (let ((cost (dsh-emacs-usage-cost dsh-emacs--modeline-usage)))
      (when (> cost 0)
        (dsh-emacs-modeline--annotate
         (propertize (dsh-emacs-format-cost cost) 'face 'dsh-emacs-modeline-cost-face)
         (format "Session cost: %s" (dsh-emacs-format-cost cost)))))))

(defun dsh-emacs-modeline--render-segment (sym)
  "Render mode-line segment named SYM."
  (pcase sym
    ('cwd (dsh-emacs-modeline--segment-cwd))
    ('branch (dsh-emacs-modeline--segment-branch))
    ('model (dsh-emacs-modeline--segment-model))
    ('effort (dsh-emacs-modeline--segment-effort))
    ('preset (dsh-emacs-modeline--segment-preset))
    ('tokens (dsh-emacs-modeline--segment-tokens))
    ('ctx (dsh-emacs-modeline--segment-ctx))
    ('cost (dsh-emacs-modeline--segment-cost))
    (_ nil)))

;;; ---------------------------------------------------------------------------
;;; Mode-line 统计字符串
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-modeline-format ()
  "Build the mode-line string from the configured segments.
Returns the empty string if `dsh-emacs-modeline-enabled' is nil or no
segments render."
  (if (not dsh-emacs-modeline-enabled)
      ""
    (let* ((spec dsh-emacs-modeline-format-spec)
           (separator (or (plist-get spec :separator) " • "))
           (segments (or (plist-get spec :segments)
                         '(cwd branch model tokens ctx cost)))
           (separator-propertized (propertize separator 'face 'dsh-emacs-modeline-separator-face))
           parts)
      (dolist (sym segments)
        (let ((text (dsh-emacs-modeline--render-segment sym)))
          (when (and text (not (string-empty-p text)))
            (push text parts))))
      (if parts
          (mapconcat #'identity (nreverse parts) separator-propertized)
        ""))))

;;; ---------------------------------------------------------------------------
;;; Mode-line 行渲染（在 dsh-emacs.el 中由 mode-line-format 钩入）
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-modeline-update ()
  "Force re-render of the mode-line statistics. No-op outside a dsh-emacs buffer."
  (when (derived-mode-p 'dsh-emacs-mode)
    (force-mode-line-update)))

(defun dsh-emacs-modeline-toggle ()
  "Toggle mode-line line visibility."
  (interactive)
  (setq dsh-emacs-modeline-enabled (not dsh-emacs-modeline-enabled))
  (dsh-emacs-modeline-update)
  (message "dsh mode-line %s" (if dsh-emacs-modeline-enabled "shown" "hidden")))

;;; ---------------------------------------------------------------------------
;;; 设置器
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-modeline-set-usage (usage-struct)
  "Set the cumulative usage to USAGE-STRUCT (a `dsh-emacs-usage').
Nil clears it."
  (setq dsh-emacs--modeline-usage usage-struct)
  (dsh-emacs-modeline-update))

(defun dsh-emacs-modeline-add-usage (usage-or-message)
  "Accumulate USAGE-OR-MESSAGE into the current usage and refresh mode-line."
  (unless dsh-emacs--modeline-usage
    (setq dsh-emacs--modeline-usage (dsh-emacs-usage-zero)))
  (dsh-emacs-usage-add dsh-emacs--modeline-usage usage-or-message)
  (dsh-emacs-modeline-update))

(defun dsh-emacs-modeline-note-event (event)
  "Accumulate token usage reported by an `assistant/message' EVENT.
Other event types are ignored, so this can be called unconditionally from
the renderer.  Usage is read from `data.usage' (see
`dsh-emacs-usage-from-event')."
  (when (equal (dsh-emacs--alist-state event "type") "assistant/message")
    (dsh-emacs-modeline-add-usage (dsh-emacs-usage-from-event event))))

(defun dsh-emacs-modeline-note-request (event)
  "Pick the model id off a `request/context' EVENT.
The model id refreshes whenever the agent issues a new model request, so
the mode-line segment always reflects the live model.  Context-window
data rides the `session/projection' frames, not this event."
  (let ((data (dsh-emacs--alist-state event "data")))
    (when data
      (let ((model (dsh-emacs--alist-state data "model"))
            (provider (dsh-emacs--alist-state data "provider")))
        (when (and model (not (string-empty-p model)))
          (setq dsh-emacs--modeline-model model))
        (when (and provider (not (string-empty-p provider)))
          (setq dsh-emacs--modeline-provider provider)))
      (dsh-emacs-modeline-update))))

(defun dsh-emacs-modeline-note-header (event)
  "Pick the model id and reasoning effort off a `request/header' EVENT.
dsh 0.1.1-rc.1 emits `request/header' (data.header.config) instead of (or
before) the rc.2 `request/context', and — unlike `request/context' — the
event survives the windowed `session.history' response, so this is what
actually reaches the mode-line when a session is opened.  Consuming it makes
the model and effort segments live on open."
  (let* ((data (dsh-emacs--alist-state event "data"))
         (header (and data (dsh-emacs--alist-state data "header")))
         (config (and header (dsh-emacs--alist-state header "config"))))
    (when config
      (let ((model (dsh-emacs--alist-state config "model"))
            (effort (dsh-emacs--alist-state config "reasoningEffort"))
            (provider (dsh-emacs--alist-state config "provider")))
        (when (and model (not (string-empty-p model)))
          (setq dsh-emacs--modeline-model model))
        (when (and effort (not (string-empty-p effort)))
          (setq dsh-emacs--modeline-effort effort))
        (when (and provider (not (string-empty-p provider)))
          (setq dsh-emacs--modeline-provider provider)))
      (dsh-emacs-modeline-update))))

(defun dsh-emacs-modeline-set-context-snapshot (pressure window)
  "Set the server `contextPressure' projection: PRESSURE used / WINDOW total.
Both values come from the same projection, keeping the ctx% numerator and
divisor paired across model switches.  Nil hides the ctx segment."
  (setq dsh-emacs--modeline-context-pressure (and pressure (integerp pressure) pressure)
        dsh-emacs--modeline-context-window-server (and window (integerp window) window))
  (dsh-emacs-modeline-update))

(defun dsh-emacs-modeline-set-model (model)
  "Set the displayed model name to MODEL (a string)."
  (setq dsh-emacs--modeline-model model)
  (dsh-emacs-modeline-update))

(defun dsh-emacs-modeline-set-provider (provider)
  "Set the provider owning the displayed model to PROVIDER (a string or nil)."
  (setq dsh-emacs--modeline-provider provider)
  (dsh-emacs-modeline-update))

(defun dsh-emacs-modeline-set-effort (effort)
  "Set the displayed reasoning effort to EFFORT (an effortId string, or nil)."
  (setq dsh-emacs--modeline-effort effort)
  (dsh-emacs-modeline-update))

(defun dsh-emacs-modeline-set-preset (preset)
  "Set the displayed agent preset to PRESET (an agentPreset id string, or nil)."
  (setq dsh-emacs--modeline-preset preset)
  (dsh-emacs-modeline-update))

(defun dsh-emacs-modeline-set-cwd (cwd)
  "Override the cwd segment to CWD. Invalidates the branch cache."
  (setq dsh-emacs--modeline-cwd cwd
        dsh-emacs--modeline-branch-cache nil)
  (dsh-emacs-modeline-update))

(defun dsh-emacs-modeline-set-branch (branch)
  "Set the displayed branch name to BRANCH. Invalidates the branch cache."
  (setq dsh-emacs--modeline-branch branch
        dsh-emacs--modeline-branch-cache nil)
  (dsh-emacs-modeline-update))

;;; ---------------------------------------------------------------------------
;;; Mode line running-state animation (dsh 执行中滚动字符)
;;; ---------------------------------------------------------------------------

(defconst dsh-emacs--ml-busy-frames
  ;; Progress bar that fills left→right then drains right→left, borrowing
  ;; the `progress-bar-filled' type from Malabarba's spinner.el
  ;; (https://github.com/Malabarba/spinner.el), with the track drawn as
  ;; square brackets instead of pipes.
  '("[    ]" "[█   ]" "[██  ]" "[███ ]" "[████]" "[ ███]" "[  ██]" "[   █]")
  "Frames for the mode-line running animation (filled progress bar).")

(defconst dsh-emacs--ml-busy-interval 0.08
  "Seconds between mode-line running-animation frames (~12.5fps).")

(defvar-local dsh-emacs--ml-busy nil
  "Non-nil while this chat buffer's dsh session is executing a prompt.")

(defvar-local dsh-emacs--ml-busy-index 0
  "Current frame index of the mode-line running animation.
Buffer-local: each busy session owns its animation frame, so two sessions
running at once never fight over one counter (the index is only advanced
by the owning buffer's own timer).")

(defvar-local dsh-emacs--ml-busy-timer nil
  "Timer object driving the mode-line running animation.
Buffer-local: every busy chat buffer drives its own animation; a single
global timer would let one session's `turn/end' (rendered in a hidden
buffer) cancel the visible session's spinner.")

(defun dsh-emacs--ml-busy-tick (buffer)
  "Advance one frame of the mode-line running animation and redraw it.
Auto-stops when BUFFER is gone or no longer busy.  BUFFER is passed
explicitly because the timer callback may otherwise run in any buffer."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (if (and dsh-emacs--ml-busy (timerp dsh-emacs--ml-busy-timer))
          (progn
            (setq dsh-emacs--ml-busy-index
                  (mod (1+ dsh-emacs--ml-busy-index)
                       (length dsh-emacs--ml-busy-frames)))
            ;; Only churn the mode line while the chat is actually displayed;
            ;; an invisible buffer must not drive frame redraws at 12.5Hz.
            (when (get-buffer-window (current-buffer) 0)
              (force-mode-line-update)))
        ;; Buffer no longer busy (turn/end already ran): stop in place.
        (dsh-emacs--ml-busy-stop)))))

(defun dsh-emacs--ml-busy-start ()
  "Start the mode-line running animation for the current buffer."
  (dsh-emacs--ml-busy-stop)
  (setq dsh-emacs--ml-busy-index 0
        dsh-emacs--ml-busy-timer
        (run-at-time nil dsh-emacs--ml-busy-interval
                     #'dsh-emacs--ml-busy-tick (current-buffer))))

(defun dsh-emacs--ml-busy-stop ()
  "Stop the mode-line running animation and cancel its timer."
  (when (timerp dsh-emacs--ml-busy-timer)
    (cancel-timer dsh-emacs--ml-busy-timer))
  (setq dsh-emacs--ml-busy-timer nil
        dsh-emacs--ml-busy-index 0))

(defun dsh-emacs--ml-busy-set (flag)
  "Set the current buffer's running-state flag to FLAG.
Starting the flag drives the mode-line spinner; clearing it stops the timer.
Call in the chat buffer whose mode-line should animate."
  (setq dsh-emacs--ml-busy (and flag t))
  (if dsh-emacs--ml-busy
      (dsh-emacs--ml-busy-start)
    (dsh-emacs--ml-busy-stop)))

(defun dsh-emacs--ml-busy-clear ()
  "Clear the running-state flag and cancel the animation timer.
Public teardown used when the event stream is disconnected or the chat
buffer is being abandoned; the spinner must never keep ticking detached."
  (setq dsh-emacs--ml-busy nil)
  (dsh-emacs--ml-busy-stop))

(defun dsh-emacs--ml-busy-indicator ()
  "Return the current running-animation character for the mode-line.
Empty string when this buffer is not executing, so the spinner is hidden."
  (if (and (bound-and-true-p dsh-emacs--ml-busy)
           (boundp 'dsh-emacs--ml-busy-frames)
           (boundp 'dsh-emacs--ml-busy-index))
      (propertize
       (nth (mod dsh-emacs--ml-busy-index
                 (length dsh-emacs--ml-busy-frames))
            dsh-emacs--ml-busy-frames)
       'face 'dsh-emacs-mode-line-busy-face)
    ""))

;;; ---------------------------------------------------------------------------
;;; 结构 overlay 初始化
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-modeline--ml-indicator ()
  "Return the running animation for the mode line, padded for mode-name spot.
Empty string when idle, so the mode line is untouched; \" [██  ] \" when
running (space on both sides, ready to sit right after the DSH mode name)."
  (let ((frame (dsh-emacs--ml-busy-indicator)))
    (if (string-empty-p frame)
        ""
      (propertize (concat " " frame " ")
                  'help-echo "dsh is running a request…"
                  'mouse-face 'mode-line-highlight))))

(defun dsh-emacs-modeline--escape-percent (txt)
  "Escape `%' in TXT for mode-line display, keeping text properties.
Mode-line strings undergo `%'-sequence expansion, so a literal `%' must be
doubled to `%%'.  Each duplicate keeps the face at the original position, so
rendered tokens (faces on `CH99%') keep their color."
  (let ((i 0)
        (len (length txt))
        (out ""))
    (while (< i len)
      (if (eq (aref txt i) ?%)
          (let ((ch (substring txt i (1+ i))))
            ;; 两份拷贝都带原位置的文本属性。
            (setq out (concat out ch ch)
                  i (1+ i)))
        (setq out (concat out (substring txt i (1+ i)))
              i (1+ i))))
    out))

(defun dsh-emacs-modeline--modeinline ()
  "Return the compact stats segment for the mode line: \"(model ↑in ↓out CH%)\".
Empty string outside dsh-emacs buffers, when `dsh-emacs-modeline-enabled'
is nil, or nothing renders, so the pre-existing mode line is untouched
when idle.  Percent signs are escaped (%%): mode-line strings undergo
`%'-sequence expansion, so a raw `%' followed by the closing paren
would swallow it.  A trailing space also keeps the closing paren off
the window's right edge, where right-aligned mode lines (doom-modeline)
clip the last visible column."
  (if (not (derived-mode-p 'dsh-emacs-mode))
      ""
    (let ((txt (dsh-emacs-modeline-format)))
      (if (string-empty-p txt)
          ""
        (let ((escaped (dsh-emacs-modeline--escape-percent txt)))
          (concat (propertize "(" 'face 'dsh-emacs-modeline-separator-face)
                  escaped
                  (propertize ") " 'face 'dsh-emacs-modeline-separator-face)))))))

(defun dsh-emacs-modeline--splice (base)
  "Return BASE with the dsh mode-line segments spliced in.
Perfers inserting right after `mode-line-modes' (next to the mode name);
when the base format has no such anchor — e.g. package-composed mode lines
like doom-modeline that render everything through a single `:eval' — the
segments are inserted right after the first element instead, so they stay
visible at the left edge of the line instead of being clipped past the
width-filling renderer.  BASE is the pre-existing mode-line-format list."
  (let* ((stats '(:eval (dsh-emacs-modeline--modeinline)))
         (anim '(:eval (dsh-emacs-modeline--ml-indicator)))
         ;; 动画紧跟模式名（DSH 之后），统计段跟在动画后面。
         (segments (list anim stats)))
    (cond
     ((memq 'mode-line-modes base)
      ;; Insert directly after the mode names cluster.
      (let ((rest (cdr (memq 'mode-line-modes base))))
        (append (butlast base (length rest)) segments rest)))
     ((null base)
      segments)
     ((listp base)
      ;; No mode-name anchor: keep visible by inserting right after the
      ;; first element (usually \"%e\"), before the rest of the line.
      (cons (car base) (append segments (cdr base))))
     (t
      ;; Unknown format shape: lead with our segments.
      segments))))

(defun dsh-emacs-modeline--doom-segment ()
  "Doom-modeline segment body: the running animation right after the DSH
mode name, followed by the compact dsh stats.  Empty when idle or
outside a dsh-emacs buffer, so doom-modeline's layout stays untouched."
  (if (not (derived-mode-p 'dsh-emacs-mode))
      ""
    (concat (dsh-emacs-modeline--ml-indicator)
            (dsh-emacs-modeline--modeinline))))

(defun dsh-emacs-modeline--install-doom-segment ()
  "Register the dsh stats as a doom-modeline segment after `major-mode'.
Returns t on success; nil when doom-modeline is unavailable or lacks the
anchor (caller then falls back to the plain mode-line splice)."
  (when (and (featurep 'doom-modeline)
             (fboundp 'doom-modeline-def-segment)
             (fboundp 'doom-modeline-add-segment)
             (boundp 'doom-modeline--modelines)
             (boundp 'doom-modeline--fn-alist)
             ;; Probe the built-in "main" modeline for the mode-name anchor.
             (let* ((def (assq 'main (symbol-value 'doom-modeline--modelines)))
                    (sides (cdr def))              ; (lhs rhs)
                    (rhs (and sides (cadr sides))))
               (and rhs (memq 'major-mode rhs))))
    (unless dsh-emacs-modeline--doom-segment-installed
      ;; Define the segment at runtime with eval so the official macro
      ;; (not expandable at our byte-compile time — it lives in the user's
      ;; doom-modeline) expands against the actually installed version.
      (unless (alist-get 'dsh-emacs-stats
                         (symbol-value 'doom-modeline--fn-alist))
        (eval '(doom-modeline-def-segment dsh-emacs-stats
                (dsh-emacs-modeline--doom-segment))))
      (doom-modeline-add-segment 'dsh-emacs-stats 'major-mode :after)
      (setq dsh-emacs-modeline--doom-segment-installed t))
    ;; Verify the segment actually landed somewhere.
    (let* ((def (assq 'main (symbol-value 'doom-modeline--modelines)))
           (sides (cdr def))
           (lhs (car sides))
           (rhs (cadr sides)))
      (or (memq 'dsh-emacs-stats lhs) (memq 'dsh-emacs-stats rhs)))))

(defun dsh-emacs-modeline--remove-doom-segment ()
  "Unregister the dsh stats segment from doom-modeline."
  (when (and dsh-emacs-modeline--doom-segment-installed
             (featurep 'doom-modeline)
             (fboundp 'doom-modeline-remove-segment))
    (doom-modeline-remove-segment 'dsh-emacs-stats)
    (setq dsh-emacs-modeline--doom-segment-installed nil)))

(defun dsh-emacs-modeline-setup ()
  "Initialize the mode-line structures and splice dsh segments into the mode line.
The buffer keeps its existing (default or user-customized) mode-line-format;
dsh only adds the compact stats next to the DSH mode name and the running
animation.  Splice and structural overlay happen unconditionally: whether
stats are actually shown is decided per redraw by `dsh-emacs-modeline-enabled'
(evaluated inside the mode-line `:eval'), so toggling the mode-line on later
works without reopening the session.  Should be called from
`dsh-emacs-mode-hook' or after creating a dsh-emacs buffer."
  ;; Each open re-accumulates usage from the freshly loaded history, so
  ;; drop any usage left over from a previous visit to this buffer.
  (setq dsh-emacs--modeline-usage nil)
  ;; Create the structural end-of-buffer overlay (kept purely as the
  ;; separator the input-area geometry relies on).
  (unless dsh-emacs--modeline-overlay
    (let ((inhibit-read-only t))
      (goto-char (point-max))
      (insert "\n")
      (setq dsh-emacs--modeline-overlay (make-overlay (point) (point) nil t t))
      (overlay-put dsh-emacs--modeline-overlay 'after-string
                   (propertize "\n" 'face 'dsh-emacs-modeline-face))))

  ;; Render route: doom-modeline owns the layout when present, so the stats
  ;; become one of its segments (next to the major-mode name, right-aligned);
  ;; otherwise splice into the plain mode-line-format as before.
  (if (dsh-emacs-modeline--install-doom-segment)
      ;; Clean up any local splice left by an earlier visit or fallback.
      (when (local-variable-p 'mode-line-format)
        (kill-local-variable 'mode-line-format))
    ;; Splice dsh segments into the existing mode line instead of replacing it.
    (unless dsh-emacs-modeline--modeline-patched
      (let ((base (or (and (local-variable-p 'mode-line-format)
                           mode-line-format)
                      (default-value 'mode-line-format)))
            ;; Fallback if the user set their global mode-line-format to nil.
            (fallback '("%e" mode-line-front-space mode-line-mule-info
                        mode-line-modified mode-line-buffer-identification
                        "   " mode-line-position mode-line-modes
                        mode-line-misc-info mode-line-end-spaces)))
        (setq-local mode-line-format
                    (dsh-emacs-modeline--splice (or base fallback)))
        (setq dsh-emacs-modeline--modeline-patched t))))

  ;; Initial render (also forces the `:eval' segments to re-evaluate).
  (dsh-emacs-modeline-update)
  (message "dsh: mode-line setup (mode=%S enabled=%S patched=%S)"
           (if dsh-emacs-modeline--doom-segment-installed 'doom 'splice)
           dsh-emacs-modeline-enabled dsh-emacs-modeline--modeline-patched))

(defun dsh-emacs-modeline-teardown ()
  "Clean up the structural end-of-buffer overlay and the mode-line splicing
when leaving dsh-emacs-mode."
  (dsh-emacs-modeline--remove-doom-segment)
  (setq dsh-emacs-modeline--modeline-patched nil)
  (kill-local-variable 'mode-line-format)
  (when dsh-emacs--modeline-overlay
    (delete-overlay dsh-emacs--modeline-overlay)
    (setq dsh-emacs--modeline-overlay nil)))

;;; ---------------------------------------------------------------------------
;;; 兼容别名（0.1.0 时代叫 footer）：老配置/老命令继续有效
;;; ---------------------------------------------------------------------------

(define-obsolete-variable-alias 'dsh-emacs-footer-enabled
  'dsh-emacs-modeline-enabled "0.2.0")
(define-obsolete-variable-alias 'dsh-emacs-footer-format-spec
  'dsh-emacs-modeline-format-spec "0.2.0")
(define-obsolete-variable-alias 'dsh-emacs-footer-branch-refresh-interval
  'dsh-emacs-modeline-branch-refresh-interval "0.2.0")
(define-obsolete-function-alias 'dsh-emacs-footer-toggle
  'dsh-emacs-modeline-toggle "0.2.0")
(define-obsolete-function-alias 'dsh-emacs-footer-setup
  'dsh-emacs-modeline-setup "0.2.0")
(define-obsolete-function-alias 'dsh-emacs-footer-update
  'dsh-emacs-modeline-update "0.2.0")

(provide 'dsh-emacs-modeline)

;;; dsh-emacs-modeline.el ends here