;;; dsh-emacs-footer.el --- Footer (status) line for dsh-emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2025 vritser

;; Author: vritser
;; Version: 0.1.0
;; License: GPL-3.0-or-later
;; Package-Requires ((emacs "27.1"))

;;; Commentary:

;; Footer 显示在 dsh 对话缓冲的底部（mode-line 之下、输入区之上）。
;; 参考 pi-mono 的 footer 设计：model • effort • preset • ctx% • tokens • cost。
;;
;; 公开 API：
;;
;;   (dsh-emacs-footer-format)              ;;  当前 footer 字符串
;;   (dsh-emacs-footer-update)              ;;  立即刷新 footer
;;   (dsh-emacs-footer-toggle)              ;;  切换 footer 显示/隐藏
;;   (dsh-emacs-footer-set-usage usage)     ;;  设置累计 token usage
;;   (dsh-emacs-footer-add-usage usage)     ;;  累加 usage 并刷新
;;   (dsh-emacs-footer-note-event event)    ;;  从 assistant/message 事件累计 usage
;;   (dsh-emacs-footer-set-model "claude-opus-4-5") ;; 设置模型名
;;   (dsh-emacs-footer-set-effort "max")   ;; 设置推理 effort
;;   (dsh-emacs-footer-set-preset "code")  ;; 设置 agent preset
;;
;; 用户可通过 `dsh-emacs-footer-format-spec' 自定义显示哪些段（默认全部）。

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

(defgroup dsh-emacs-footer nil
  "Footer / status line for `dsh-emacs'."
  :group 'dsh-emacs
  :prefix "dsh-emacs-")

(defcustom dsh-emacs-footer-enabled t
  "Whether the footer line is enabled."
  :type 'boolean
  :group 'dsh-emacs-footer)

(defcustom dsh-emacs-footer-format-spec
  '(:separator " "
    :segments (model effort preset ctx))
  "Plist describing the footer segments to render and the separator.
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
  :type '(list :tag "Footer format"
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
  :group 'dsh-emacs-footer)

(defcustom dsh-emacs-footer-branch-refresh-interval 10
  "Seconds to cache the git branch shown in the footer.
The branch segment runs `git rev-parse' in a subprocess, which is far too
expensive to re-run on every mode-line redraw (the running animation alone
forces a redraw ~12x/s while dsh is executing).  Within this interval the
last result — including a \"not a git repo\" nil — is reused."
  :type 'number
  :group 'dsh-emacs-footer)

;;; ---------------------------------------------------------------------------
;;; 内部状态（buffer-local）
;;; ---------------------------------------------------------------------------

(defvar-local dsh-emacs--footer-cwd nil
  "Override the cwd displayed in the footer. Default: use `default-directory'.")

(defvar-local dsh-emacs--footer-branch nil
  "Override the git branch displayed. Default: detect via `vc-git'.")

(defvar-local dsh-emacs--footer-branch-cache nil
  "Cons (branch-or-nil . timestamp) memoizing git branch detection.
Nil (no repo) is cached too so non-git dirs never spawn git per redraw.")

(defvar-local dsh-emacs--footer-model nil
  "Model name displayed in the footer.")

(defvar-local dsh-emacs--footer-effort nil
  "Reasoning effort (effortId, e.g. \"off\"/\"max\") shown in the footer.")

(defvar-local dsh-emacs--footer-preset nil
  "Agent preset (agentPreset id, e.g. \"standard\"/\"code\") shown in the footer.")

(defvar-local dsh-emacs--footer-context-window-server nil
  "Context window from the server's `contextPressure' projection (tokens).
Paired with `dsh-emacs--footer-context-pressure': both come from the same
projection, so the ctx% divisor always matches the occupancy — even right
after a model switch.")

(defvar-local dsh-emacs--footer-context-pressure nil
  "Server-reported current context occupancy (tokens), or nil.
Fed from the `contextPressure' projection (projectedTokens ?? pressureTokens,
dsh web's ctx-meter口径) — live via `session/projection' frames, and seeded
from the `session.list' snapshot when a chat buffer opens.  Pairs with
`dsh-emacs--footer-context-window-server'.  Nil hides the ctx segment.")

(defvar-local dsh-emacs--footer-usage nil
  "Latest usage struct (see `dsh-emacs-usage').")

(defvar-local dsh-emacs--footer-overlay nil
  "Overlay used to render the footer line at the bottom of the buffer.")

(defvar-local dsh-emacs-footer--modeline-patched nil
  "Non-nil once dsh segments were spliced into this buffer's mode-line-format.")

(defvar dsh-emacs-footer--doom-segment-installed nil
  "Non-nil once the dsh stats segment is registered with doom-modeline.")

;;; ---------------------------------------------------------------------------
;;; 路径简化
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-footer--shorten-cwd (cwd)
  "Shorten CWD using ~/ prefix when possible."
  (let* ((home (or (getenv "HOME") (user-login-name)))
         (home-dir (and home (expand-file-name (file-name-as-directory home))))
         (cwd (or cwd default-directory)))
    (if (and home-dir
             (string-prefix-p home-dir (expand-file-name cwd)))
        (concat "~" (substring (expand-file-name cwd) (length home-dir)))
      cwd)))

(defun dsh-emacs-footer--detect-branch ()
  "Return current git branch, or nil.
Uses `call-process' straight on the git binary — no intermediate shell —
because this runs in the mode-line path and must stay cheap."
  (when (and default-directory (not (file-remote-p default-directory)))
    (ignore-errors
      (let ((default-directory (or dsh-emacs--footer-cwd default-directory)))
        (with-temp-buffer
          (let ((ret (call-process "git" nil t nil
                                   "rev-parse" "--abbrev-ref" "HEAD")))
            (when (eq 0 ret)
              (string-trim (buffer-string)))))))))

(defun dsh-emacs-footer--cached-branch ()
  "Return the git branch from cache, refreshing when stale.
Refreshes at most once per `dsh-emacs-footer-branch-refresh-interval'
seconds; a nil (non-repo) result is cached the same way."
  (let* ((now (float-time))
         (cached dsh-emacs--footer-branch-cache))
    (if (and cached (<= (- now (cdr cached))
                        dsh-emacs-footer-branch-refresh-interval))
        (car cached)
      (let ((branch (dsh-emacs-footer--detect-branch)))
        (setq dsh-emacs--footer-branch-cache (cons branch now))
        branch))))

;;; ---------------------------------------------------------------------------
;;; 各段格式化
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-footer--annotate (text tooltip)
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

(defun dsh-emacs-footer--segment-cwd ()
  "Render the cwd segment."
  (let ((cwd (dsh-emacs-footer--shorten-cwd (or dsh-emacs--footer-cwd default-directory))))
    (dsh-emacs-footer--annotate
     (propertize cwd 'face 'dsh-emacs-footer-face)
     (format "Working directory: %s"
             (or dsh-emacs--footer-cwd default-directory)))))

(defun dsh-emacs-footer--segment-branch ()
  "Render the git branch segment (cached; see
`dsh-emacs-footer-branch-refresh-interval')."
  (let ((branch (or dsh-emacs--footer-branch
                    (dsh-emacs-footer--cached-branch))))
    (when (and branch (not (string-empty-p branch)))
      (dsh-emacs-footer--annotate
       (concat (propertize "(" 'face 'dsh-emacs-footer-face)
               (propertize branch 'face 'dsh-emacs-footer-face)
               (propertize ")" 'face 'dsh-emacs-footer-face))
       (format "Git branch: %s" branch)))))

(defun dsh-emacs-footer--segment-model ()
  "Render the model segment.
Falls back to `dsh-emacs-default-model' when the per-buffer model was never
set (e.g. a session that predates request events)."
  (let ((model (or dsh-emacs--footer-model
                   (and (boundp 'dsh-emacs-default-model)
                        dsh-emacs-default-model))))
    (when (and model (not (string-empty-p model)))
      (dsh-emacs-footer--annotate
       (propertize model 'face 'dsh-emacs-footer-face)
       (format "Model: %s — reasoning model of this session (switch with C-c C-m)"
               model)))))

(defun dsh-emacs-footer--segment-effort ()
  "Render the reasoning-effort segment (effortId, e.g. \"max\")."
  (when (and dsh-emacs--footer-effort
             (not (string-empty-p dsh-emacs--footer-effort)))
    (dsh-emacs-footer--annotate
     (propertize dsh-emacs--footer-effort 'face 'dsh-emacs-footer-face)
     (format "Reasoning effort: %s" dsh-emacs--footer-effort))))

(defun dsh-emacs-footer--segment-preset ()
  "Render the agent-preset segment (agentPreset, e.g. \"code\")."
  (when (and dsh-emacs--footer-preset
             (not (string-empty-p dsh-emacs--footer-preset)))
    (dsh-emacs-footer--annotate
     (propertize dsh-emacs--footer-preset 'face 'dsh-emacs-footer-face)
     (format "Agent preset: %s" dsh-emacs--footer-preset))))

(defun dsh-emacs-footer--segment-tokens ()
  "Render the token usage segment."
  (when dsh-emacs--footer-usage
    (let* ((u dsh-emacs--footer-usage)
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
                                          'face 'dsh-emacs-footer-token-face) parts))
      (when (> output 0) (push (propertize (concat "↓" (dsh-emacs-format-tokens output))
                                           'face 'dsh-emacs-footer-token-face) parts))
      (when ch (push (propertize (format "CH%.0f%%" ch)
                                 'face 'dsh-emacs-footer-token-face) parts))
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
          (dsh-emacs-footer--annotate
           (mapconcat #'identity (nreverse parts)
                      (propertize " " 'face 'dsh-emacs-footer-separator-face))
           (format "Token usage: %s" seg)))))))

(defun dsh-emacs-footer--segment-ctx ()
  "Render the context-window usage percentage segment.
Only the server's `contextPressure' snapshot is meaningful here: the
segment shows pressureTokens / the same snapshot's contextWindow (the
current prompt's actual occupancy).  Cumulative token usage (input +
cacheRead + cacheWrite) is a session lifetime total — it is NOT \"in\"
the context now, cacheRead alone is usually many times the window, so it
must never be used as ctx% numerator.  Without a server snapshot the
segment renders nothing (nil hides it)."
  (let* ((pressure dsh-emacs--footer-context-pressure)
         (window dsh-emacs--footer-context-window-server)
         (pct (and pressure window (> window 0)
                   (min 100.0 (* 100.0 (/ (float pressure) window))))))
    (when pct
      (dsh-emacs-footer--annotate
       (propertize (dsh-emacs-format-percent pct)
                   'face (dsh-emacs-ctx-face pct))
       (format "Context window: %s (%s / %s tokens)"
               (dsh-emacs-format-percent pct)
               (dsh-emacs-format-tokens pressure)
               (dsh-emacs-format-tokens window))))))

(defun dsh-emacs-footer--segment-cost ()
  "Render the cost segment."
  (when dsh-emacs--footer-usage
    (let ((cost (dsh-emacs-usage-cost dsh-emacs--footer-usage)))
      (when (> cost 0)
        (dsh-emacs-footer--annotate
         (propertize (dsh-emacs-format-cost cost) 'face 'dsh-emacs-footer-cost-face)
         (format "Session cost: %s" (dsh-emacs-format-cost cost)))))))

(defun dsh-emacs-footer--render-segment (sym)
  "Render footer segment named SYM."
  (pcase sym
    ('cwd (dsh-emacs-footer--segment-cwd))
    ('branch (dsh-emacs-footer--segment-branch))
    ('model (dsh-emacs-footer--segment-model))
    ('effort (dsh-emacs-footer--segment-effort))
    ('preset (dsh-emacs-footer--segment-preset))
    ('tokens (dsh-emacs-footer--segment-tokens))
    ('ctx (dsh-emacs-footer--segment-ctx))
    ('cost (dsh-emacs-footer--segment-cost))
    (_ nil)))

;;; ---------------------------------------------------------------------------
;;; Footer 字符串
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-footer-format ()
  "Build the footer string from the configured segments.
Returns the empty string if `dsh-emacs-footer-enabled' is nil or no
segments render."
  (if (not dsh-emacs-footer-enabled)
      ""
    (let* ((spec dsh-emacs-footer-format-spec)
           (separator (or (plist-get spec :separator) " • "))
           (segments (or (plist-get spec :segments) '(cwd branch model tokens ctx cost)))
           (separator-propertized (propertize separator 'face 'dsh-emacs-footer-separator-face))
           parts)
      (dolist (sym segments)
        (let ((text (dsh-emacs-footer--render-segment sym)))
          (when (and text (not (string-empty-p text)))
            (push text parts))))
      (if parts
          (mapconcat #'identity (nreverse parts) separator-propertized)
        ""))))

;;; ---------------------------------------------------------------------------
;;; Footer 行渲染（在 dsh-emacs.el 中由 mode-line-format 钩入）
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-footer-update ()
  "Force re-render of the mode-line statistics. No-op outside a dsh-emacs buffer."
  (when (derived-mode-p 'dsh-emacs-mode)
    (force-mode-line-update)))

(defun dsh-emacs-footer-toggle ()
  "Toggle footer line visibility."
  (interactive)
  (setq dsh-emacs-footer-enabled (not dsh-emacs-footer-enabled))
  (dsh-emacs-footer-update)
  (message "dsh footer %s" (if dsh-emacs-footer-enabled "shown" "hidden")))

;;; ---------------------------------------------------------------------------
;;; 设置器
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-footer-set-usage (usage-struct)
  "Set the cumulative usage to USAGE-STRUCT (a `dsh-emacs-usage').
Nil clears it."
  (setq dsh-emacs--footer-usage usage-struct)
  (dsh-emacs-footer-update))

(defun dsh-emacs-footer-add-usage (usage-or-message)
  "Accumulate USAGE-OR-MESSAGE into the current usage and refresh footer."
  (unless dsh-emacs--footer-usage
    (setq dsh-emacs--footer-usage (dsh-emacs-usage-zero)))
  (dsh-emacs-usage-add dsh-emacs--footer-usage usage-or-message)
  (dsh-emacs-footer-update))

(defun dsh-emacs-footer-note-event (event)
  "Accumulate token usage reported by an `assistant/message' EVENT.
Other event types are ignored, so this can be called unconditionally from
the renderer.  Usage is read from `data.usage' (see
`dsh-emacs-usage-from-event')."
  (when (equal (dsh-emacs--alist-state event "type") "assistant/message")
    (dsh-emacs-footer-add-usage (dsh-emacs-usage-from-event event))))

(defun dsh-emacs-footer-note-request (event)
  "Pick the model id off a `request/context' EVENT.
The model id refreshes whenever the agent issues a new model request, so
the mode-line segment always reflects the live model.  Context-window
data rides the `session/projection' frames, not this event."
  (let ((data (dsh-emacs--alist-state event "data")))
    (when data
      (let ((model (dsh-emacs--alist-state data "model")))
        (when (and model (not (string-empty-p model)))
          (setq dsh-emacs--footer-model model)))
      (dsh-emacs-footer-update))))

(defun dsh-emacs-footer-note-header (event)
  "Pick the model id and reasoning effort off a `request/header' EVENT.
dsh 0.1.1-rc.1 emits `request/header' (data.header.config) instead of (or
before) the rc.2 `request/context', and — unlike `request/context' — the
event survives the windowed `session.history' response, so this is what
actually reaches the footer when a session is opened.  Consuming it makes
the model and effort segments live on open."
  (let* ((data (dsh-emacs--alist-state event "data"))
         (header (and data (dsh-emacs--alist-state data "header")))
         (config (and header (dsh-emacs--alist-state header "config"))))
    (when config
      (let ((model (dsh-emacs--alist-state config "model"))
            (effort (dsh-emacs--alist-state config "reasoningEffort")))
        (when (and model (not (string-empty-p model)))
          (setq dsh-emacs--footer-model model))
        (when (and effort (not (string-empty-p effort)))
          (setq dsh-emacs--footer-effort effort)))
      (dsh-emacs-footer-update))))

(defun dsh-emacs-footer-set-context-snapshot (pressure window)
  "Set the server `contextPressure' projection: PRESSURE used / WINDOW total.
Both values come from the same projection, keeping the ctx% numerator and
divisor paired across model switches.  Nil hides the ctx segment."
  (setq dsh-emacs--footer-context-pressure (and pressure (integerp pressure) pressure)
        dsh-emacs--footer-context-window-server (and window (integerp window) window))
  (dsh-emacs-footer-update))

(defun dsh-emacs-footer-set-model (model)
  "Set the displayed model name to MODEL (a string)."
  (setq dsh-emacs--footer-model model)
  (dsh-emacs-footer-update))

(defun dsh-emacs-footer-set-effort (effort)
  "Set the displayed reasoning effort to EFFORT (an effortId string, or nil)."
  (setq dsh-emacs--footer-effort effort)
  (dsh-emacs-footer-update))

(defun dsh-emacs-footer-set-preset (preset)
  "Set the displayed agent preset to PRESET (an agentPreset id string, or nil)."
  (setq dsh-emacs--footer-preset preset)
  (dsh-emacs-footer-update))

(defun dsh-emacs-footer-set-cwd (cwd)
  "Override the cwd segment to CWD. Invalidates the branch cache."
  (setq dsh-emacs--footer-cwd cwd
        dsh-emacs--footer-branch-cache nil)
  (dsh-emacs-footer-update))

(defun dsh-emacs-footer-set-branch (branch)
  "Set the displayed branch name to BRANCH. Invalidates the branch cache."
  (setq dsh-emacs--footer-branch branch
        dsh-emacs--footer-branch-cache nil)
  (dsh-emacs-footer-update))

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
;;; Footer overlay 初始化
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-footer--ml-indicator ()
  "Return the running animation for the mode line, padded for mode-name spot.
Empty string when idle, so the mode line is untouched; \" [██  ] \" when
running (space on both sides, ready to sit right after the DSH mode name)."
  (let ((frame (dsh-emacs--ml-busy-indicator)))
    (if (string-empty-p frame)
        ""
      (propertize (concat " " frame " ")
                  'help-echo "dsh is running a request…"
                  'mouse-face 'mode-line-highlight))))

(defun dsh-emacs-footer--escape-percent (txt)
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

(defun dsh-emacs-footer--modeinline ()
  "Return the compact stats segment for the mode line: \"(model ↑in ↓out CH%)\".
Empty string outside dsh-emacs buffers, when `dsh-emacs-footer-enabled'
is nil, or nothing renders, so the pre-existing mode line is untouched
when idle.  Percent signs are escaped (%%): mode-line strings undergo
`%'-sequence expansion, so a raw `%' followed by the closing paren
would swallow it.  A trailing space also keeps the closing paren off
the window's right edge, where right-aligned mode lines (doom-modeline)
clip the last visible column."
  (if (not (derived-mode-p 'dsh-emacs-mode))
      ""
    (let ((txt (dsh-emacs-footer-format)))
      (if (string-empty-p txt)
          ""
        (let ((escaped (dsh-emacs-footer--escape-percent txt)))
          (concat (propertize "(" 'face 'dsh-emacs-footer-separator-face)
                  escaped
                  (propertize ") " 'face 'dsh-emacs-footer-separator-face)))))))

(defun dsh-emacs-footer--splice (base)
  "Return BASE with the dsh mode-line segments spliced in.
Perfers inserting right after `mode-line-modes' (next to the mode name);
when the base format has no such anchor — e.g. package-composed mode lines
like doom-modeline that render everything through a single `:eval' — the
segments are inserted right after the first element instead, so they stay
visible at the left edge of the line instead of being clipped past the
width-filling renderer.  BASE is the pre-existing mode-line-format list."
  (let* ((stats '(:eval (dsh-emacs-footer--modeinline)))
         (anim '(:eval (dsh-emacs-footer--ml-indicator)))
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

(defun dsh-emacs-footer--doom-segment ()
  "Doom-modeline segment body: the running animation right after the DSH
mode name, followed by the compact dsh stats.  Empty when idle or
outside a dsh-emacs buffer, so doom-modeline's layout stays untouched."
  (if (not (derived-mode-p 'dsh-emacs-mode))
      ""
    (concat (dsh-emacs-footer--ml-indicator)
            (dsh-emacs-footer--modeinline))))

(defun dsh-emacs-footer--install-doom-segment ()
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
    (unless dsh-emacs-footer--doom-segment-installed
      ;; Define the segment at runtime with eval so the official macro
      ;; (not expandable at our byte-compile time — it lives in the user's
      ;; doom-modeline) expands against the actually installed version.
      (unless (alist-get 'dsh-emacs-stats
                         (symbol-value 'doom-modeline--fn-alist))
        (eval '(doom-modeline-def-segment dsh-emacs-stats
                (dsh-emacs-footer--doom-segment))))
      (doom-modeline-add-segment 'dsh-emacs-stats 'major-mode :after)
      (setq dsh-emacs-footer--doom-segment-installed t))
    ;; Verify the segment actually landed somewhere.
    (let* ((def (assq 'main (symbol-value 'doom-modeline--modelines)))
           (sides (cdr def))
           (lhs (car sides))
           (rhs (cadr sides)))
      (or (memq 'dsh-emacs-stats lhs) (memq 'dsh-emacs-stats rhs)))))

(defun dsh-emacs-footer--remove-doom-segment ()
  "Unregister the dsh stats segment from doom-modeline."
  (when (and dsh-emacs-footer--doom-segment-installed
             (featurep 'doom-modeline)
             (fboundp 'doom-modeline-remove-segment))
    (doom-modeline-remove-segment 'dsh-emacs-stats)
    (setq dsh-emacs-footer--doom-segment-installed nil)))

(defun dsh-emacs-footer-setup ()
  "Initialize the footer structures and splice dsh segments into the mode line.
The buffer keeps its existing (default or user-customized) mode-line-format;
dsh only adds the compact stats next to the DSH mode name and the running
animation.  Splice and structural overlay happen unconditionally: whether
stats are actually shown is decided per redraw by `dsh-emacs-footer-enabled'
(evaluated inside the mode-line `:eval'), so toggling the footer on later
works without reopening the session.  Should be called from
`dsh-emacs-mode-hook' or after creating a dsh-emacs buffer."
  ;; Each open re-accumulates usage from the freshly loaded history, so
  ;; drop any usage left over from a previous visit to this buffer.
  (setq dsh-emacs--footer-usage nil)
  ;; Create footer overlay at buffer end (kept purely as the structural
  ;; separator the input-area geometry relies on).
  (unless dsh-emacs--footer-overlay
    (let ((inhibit-read-only t))
      (goto-char (point-max))
      (insert "\n")
      (setq dsh-emacs--footer-overlay (make-overlay (point) (point) nil t t))
      (overlay-put dsh-emacs--footer-overlay 'after-string
                   (propertize "\n" 'face 'dsh-emacs-footer-face))))

  ;; Render route: doom-modeline owns the layout when present, so the stats
  ;; become one of its segments (next to the major-mode name, right-aligned);
  ;; otherwise splice into the plain mode-line-format as before.
  (if (dsh-emacs-footer--install-doom-segment)
      ;; Clean up any local splice left by an earlier visit or fallback.
      (when (local-variable-p 'mode-line-format)
        (kill-local-variable 'mode-line-format))
    ;; Splice dsh segments into the existing mode line instead of replacing it.
    (unless dsh-emacs-footer--modeline-patched
      (let ((base (or (and (local-variable-p 'mode-line-format)
                           mode-line-format)
                      (default-value 'mode-line-format)))
            ;; Fallback if the user set their global mode-line-format to nil.
            (fallback '("%e" mode-line-front-space mode-line-mule-info
                        mode-line-modified mode-line-buffer-identification
                        "   " mode-line-position mode-line-modes
                        mode-line-misc-info mode-line-end-spaces)))
        (setq-local mode-line-format
                    (dsh-emacs-footer--splice (or base fallback)))
        (setq dsh-emacs-footer--modeline-patched t))))

  ;; Initial render (also forces the `:eval' segments to re-evaluate).
  (dsh-emacs-footer-update)
  (message "dsh: footer setup (mode=%S enabled=%S patched=%S)"
           (if dsh-emacs-footer--doom-segment-installed 'doom 'splice)
           dsh-emacs-footer-enabled dsh-emacs-footer--modeline-patched))

(defun dsh-emacs-footer-teardown ()
  "Clean up footer overlay and mode-line splicing when leaving dsh-emacs-mode."
  (dsh-emacs-footer--remove-doom-segment)
  (setq dsh-emacs-footer--modeline-patched nil)
  (kill-local-variable 'mode-line-format)
  (when dsh-emacs--footer-overlay
    (delete-overlay dsh-emacs--footer-overlay)
    (setq dsh-emacs--footer-overlay nil)))

(provide 'dsh-emacs-footer)

;;; dsh-emacs-footer.el ends here