;;; dsh-emacs-modeline.el --- Mode-line status section for dsh-emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2025 vritser

;; Author: vritser
;; Version: 0.7.0
;; License: GPL-3.0-or-later
;; Package-Requires: ((emacs "28.1"))

;;; Commentary:

;; The stats segments are spliced into mode-line-format (right after the DSH
;; mode name, in the end-of-line area) and show provider • model • effort •
;; preset • permission • cwd • branch • tokens • ctx% • cost.  The layout
;; follows pi-mono's footer (a terminal bottom status bar); the ctx and
;; model/effort data semantics align with dsh web (the server pushes the
;; contextPressure projection), and the permission segment reads the
;; `permissions' projection's current value.
;;
;; Public API:
;;
;;   (dsh-emacs-modeline-format)              ;;  current mode-line string
;;   (dsh-emacs-modeline-update)              ;;  refresh the mode-line now
;;   (dsh-emacs-modeline-toggle)              ;;  toggle mode-line visibility
;;   (dsh-emacs-modeline-set-usage usage)     ;;  set cumulative token usage
;;   (dsh-emacs-modeline-add-usage usage)     ;;  add usage and refresh
;;   (dsh-emacs-modeline-note-event event)    ;;  accumulate usage from message events
;;   (dsh-emacs-modeline-note-step turn step start-p) ;; record the current step badge
;;   (dsh-emacs-modeline-set-model "claude-opus-4-5") ;; set the model name
;;   (dsh-emacs-modeline-set-provider "deepseek")     ;; set the model's provider
;;   (dsh-emacs-modeline-set-effort "max")   ;; set the reasoning effort
;;   (dsh-emacs-modeline-set-preset "ptc")  ;; set the agent preset
;;   (dsh-emacs-modeline-set-permission "workspace-write") ;; set the permission preset
;;
;; `dsh-emacs-modeline-format-spec' lets users choose which segments are shown
;; (all by default).

;;; Code:
(declare-function dsh-emacs-subagent-indicator "dsh-emacs-subagent" (&optional phase))
(declare-function dsh-emacs-subagent-animation-text "dsh-emacs-subagent" ())

(require 'cl-lib)
(require 'color)
(require 'dsh-emacs-protocol)
(require 'dsh-emacs-faces)
(require 'dsh-emacs-tokens)
;; Animation is optional; a missing library leaves a static running caption.
(require 'motion-line nil t)
(declare-function motion-line-playing-p "motion-line" (slot))
(declare-function motion-line-play "motion-line" (slot clip &rest options))
(declare-function motion-line-clip "motion-line" (duration renderer))
(declare-function motion-line-stop "motion-line" (slot))
(declare-function motion-line-string "motion-line" (slot))
(defvar motion-line-redisplay-function)

;; Public animation facade: the only place this package touches motion-line.
;; Presentation code asks these helpers instead of featurep/playing checks, so
;; another backend (or no animation at all) changes one layer.
(defun dsh-emacs-modeline-animation-available-p ()
  "Whether the optional motion-line animation engine is installed."
  (featurep 'motion-line))

(defun dsh-emacs-modeline-animation-playing-p (slot)
  "Whether SLOT is playing in this buffer."
  (and (dsh-emacs-modeline-animation-available-p)
       (motion-line-playing-p slot)))

(defun dsh-emacs-modeline-animation-clip (duration renderer)
  "Build a DURATION clip rendered by RENDERER, or nil without a backend.
Callers build the clip lazily, so an absent backend must not signal."
  (when (dsh-emacs-modeline-animation-available-p)
    (motion-line-clip duration renderer)))

(defun dsh-emacs-modeline-animation-play (slot clip)
  "Play CLIP in SLOT when the animation engine is installed."
  (when (dsh-emacs-modeline-animation-available-p)
    (motion-line-play slot clip)))

(defun dsh-emacs-modeline-animation-stop (slot)
  "Stop SLOT when the animation engine is installed."
  (when (dsh-emacs-modeline-animation-available-p)
    (motion-line-stop slot)))

(defun dsh-emacs-modeline-animation-text (slot)
  "Return SLOT's cached animated text, or nil when it is not playing."
  (when (dsh-emacs-modeline-animation-playing-p slot)
    (motion-line-string slot)))

;; doom-modeline integration references it without depending on it: when
;; present, the official API splices the stats segment into its layout (right
;; after the major-mode segment); otherwise it falls back to the native
;; mode-line-format splice.
(declare-function doom-modeline-def-segment "doom-modeline-core" (name &rest body))
(declare-function doom-modeline-add-segment "doom-modeline-core" (segment anchor &optional position modeline))
(defvar nerd-icons-mode-icon-alist)

;; The renderer's pending text refresh can also redraw the running indicator.
(defvar dsh-emacs--streaming-assistant)
(defvar dsh-emacs--streaming-thinking)

;;; ---------------------------------------------------------------------------

;;; Customization
;;; ---------------------------------------------------------------------------

(defgroup dsh-emacs-modeline nil
  "Mode-line status section for `dsh-emacs'."
  :group 'dsh-emacs
  :prefix "dsh-emacs-")

(defcustom dsh-emacs-modeline-enabled t
  "Whether the mode-line line is enabled."
  :type 'boolean
  :group 'dsh-emacs-modeline)

(defcustom dsh-emacs-modeline-show-step nil
  "Whether the mode line shows the running turn's step badge.
A step is one model call plus the tool executions it requested
\(`step/start' to `step/end').  While the session runs, the badge sits nextto the running animation as \"step 2\" (\"step 2 · 3s\" once the step passes
a second) and is hidden when idle.  Off by default: the transcript already
shows the work, and the step number is diagnostic rather than actionable."
  :type 'boolean
  :group 'dsh-emacs-modeline)

(defcustom dsh-emacs-modeline-format-spec
  '(:separator " "
    :segments (model effort preset permission ctx))
  "Plist describing the mode-line segments to render and the separator.
The compact status line sits right next to the DSH mode name in the mode
line, e.g.  DSH (deepseek-v4-flash max ptc [shield] 95.0%).  Each
segment is one of:
  provider   — provider id serving the model (e.g. deepseek; opt-in — the
               provider also rides the model segment's tooltip)
  model      — model id (e.g. deepseek-v4-flash)
  effort     — reasoning effort (effortId, e.g. off/max)
  preset     — agent preset (agentPreset: standard/minimal/ptc/cordis)
  permission — permission preset (the `permissions' projection), drawn as
               a shield icon (see `dsh-emacs-modeline-permission-style')
  cwd        — short cwd (~/foo)
  branch     — git current branch (or empty if unavailable)
  tokens     — token usage (↑input ↓output CH% cache-hit)
  ctx        — context window usage percentage
  cost       — cumulative USD cost

Customize by toggling checkboxes: uncheck a segment to remove it from the
mode line; the `:separator' is a separate string field."
  :type '(list :tag "Mode-line format"
          (const :format "Separator between segments: " :separator)
          (string :format "%v\n")
          (const :format "Segments shown in the mode line: " :segments)
          (set :greedy t
               (const :tag "provider — model's provider id" provider)
               (const :tag "model — model id" model)
               (const :tag "effort — reasoning effort" effort)
               (const :tag "preset — agent preset" preset)
               (const :tag "permission — permission preset" permission)
               (const :tag "cwd — working directory" cwd)
               (const :tag "branch — git branch" branch)
               (const :tag "tokens — token usage ↑↓CH%" tokens)
               (const :tag "ctx — context window %" ctx)
               (const :tag "cost — cost in USD" cost)))
  :group 'dsh-emacs-modeline)

(defcustom dsh-emacs-modeline-permission-style 'icon
  "How the mode line shows the session's permission preset.
`icon' (default) draws the dsh-web shield icon: the real SVG shield
\(check/pencil/exclamation for read-only/workspace-write/danger-full-access)
when graphical Emacs has SVG support, else the matching Nerd Font shield
glyph when `nerd-icons' is installed and its font is available, else a
short token.  `text' always shows the preset name, unabbreviated.

Icons are used instead of emoji on purpose: a mode-line glyph must be one
cell wide and inherit the segment's face color, which emoji do not."
  :type '(choice (const :tag "Shield icon (SVG, then Nerd Font glyph)" icon)
                 (const :tag "Preset name text" text))
  :group 'dsh-emacs-modeline)

(defcustom dsh-emacs-modeline-branch-refresh-interval 10
  "Seconds to cache the git branch shown in the mode-line.
The branch segment runs `git rev-parse' in a subprocess, which is far too
expensive to re-run on every mode-line redraw (the running animation alone
can request a redraw ~20x/s while dsh is executing).  Within this interval the
last result — including a \"not a git repo\" nil — is reused."
  :type 'number
  :group 'dsh-emacs-modeline)

;;; ---------------------------------------------------------------------------
;;; Internal state (buffer-local)
;;; ---------------------------------------------------------------------------

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
  "Agent preset (agentPreset id, e.g. \"standard\"/\"ptc\") shown in the mode-line.")

(defvar-local dsh-emacs--modeline-permission nil
  "Permission preset (the `permissions' projection's currentValue) shown here.
A configured preset key (e.g. \"workspace-write\"/\"danger-full-access\"), the
live \"auto\", or the derived \"custom\"; nil hides the segment (no permission
service mounted, or no projection frame seen yet).")

(defvar-local dsh-emacs--modeline-context-window-server nil
  "Context window from the server's `contextPressure' projection (tokens).
Paired with `dsh-emacs--modeline-context-pressure': both come from the same
projection, so the ctx% divisor always matches the occupancy — even right
after a model switch.")

(defvar-local dsh-emacs--modeline-context-pressure nil
  "Server-reported current context occupancy (tokens), or nil.
Fed from the `contextPressure' projection (projectedTokens ?? pressureTokens,
dsh web's ctx-meter semantics) — live via `session/projection' frames, and seeded
from the `session/list' snapshot when a chat buffer opens.  Pairs with
`dsh-emacs--modeline-context-window-server'.  Nil hides the ctx segment.")

(defvar-local dsh-emacs--modeline-usage nil
  "Latest usage struct (see `dsh-emacs-usage').")

(defvar-local dsh-emacs--modeline-step nil
  "Current step of the running turn, shown beside the running animation.
Plist (:turn TURN :step STEP :start SECONDS :end SECONDS-OR-NIL) recorded
from the `step/start' / `step/end' events (see
`dsh-emacs-modeline-note-step'); nil when no step is known or the running
flag was cleared.  Steps are turn-internal boundaries, so they live on the
mode line instead of the transcript.")

(defvar-local dsh-emacs--modeline-overlay nil
  "Overlay for the structural end-of-buffer newline that the
input-area geometry relies on (not part of the mode line proper).")

(defvar-local dsh-emacs-modeline--modeline-patched nil
  "Non-nil once dsh segments were spliced into this buffer's mode-line-format.")

(defvar-local dsh-emacs-modeline--inline-cache nil
  "Last (INPUTS . TEXT) for the compact stats segment in this buffer.")

(defvar dsh-emacs-modeline--doom-segment-installed nil
  "Non-nil once the dsh stats segment is registered with doom-modeline.")

;;; ---------------------------------------------------------------------------
;;; Path shortening
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
Uses `call-process' straight on the git binary -- no intermediate shell --
because this runs in the mode-line path and must stay cheap."
  (when (and default-directory (not (file-remote-p default-directory)))
    (ignore-errors
      (with-temp-buffer
        (let ((ret (call-process "git" nil t nil
                                 "rev-parse" "--abbrev-ref" "HEAD")))
          (when (eq 0 ret)
            (string-trim (buffer-string))))))))

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
;;; Per-segment formatting
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
  (let ((cwd (dsh-emacs-modeline--shorten-cwd default-directory)))
    (dsh-emacs-modeline--annotate
     (propertize cwd 'face 'dsh-emacs-modeline-face)
     (format "Working directory: %s" default-directory))))

(defun dsh-emacs-modeline--segment-branch ()
  "Render the git branch segment (cached; see
`dsh-emacs-modeline-branch-refresh-interval')."
  (let ((branch (dsh-emacs-modeline--cached-branch)))
    (when (and branch (not (string-empty-p branch)))
      (dsh-emacs-modeline--annotate
       (concat (propertize "(" 'face 'dsh-emacs-modeline-face)
               (propertize branch 'face 'dsh-emacs-modeline-face)
               (propertize ")" 'face 'dsh-emacs-modeline-face))
       (format "Git branch: %s" branch)))))

(defun dsh-emacs-modeline--segment-provider ()
  "Render the provider segment (provider id owning the session's model).
Hidden while the provider is unknown — unlike the model segment there is
no default-provider guess to fall back on."
  (when (and dsh-emacs--modeline-provider
             (not (string-empty-p dsh-emacs--modeline-provider)))
    (dsh-emacs-modeline--annotate
     (propertize dsh-emacs--modeline-provider 'face 'dsh-emacs-modeline-face)
     (format "Provider: %s — provider serving this session's model"
             dsh-emacs--modeline-provider))))

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
  "Render the agent-preset segment (agentPreset, e.g. \"ptc\")."
  (when (and dsh-emacs--modeline-preset
             (not (string-empty-p dsh-emacs--modeline-preset)))
    (dsh-emacs-modeline--annotate
     (propertize dsh-emacs--modeline-preset 'face 'dsh-emacs-modeline-face)
     (format "Agent preset: %s" dsh-emacs--modeline-preset))))

;;; ---------------------------------------------------------------------------
;;; Permission-preset segment (dsh-web shield icons)
;;; ---------------------------------------------------------------------------
;; The three shields are dsh web's permission design set: one shield contour
;; plus a check (read-only), a pencil (workspace-write) or an exclamation
;; (danger-full-access).  `__C__' is replaced with the segment's face color,
;; the same placeholder convention `dsh-emacs--tool-icon-svgs' uses.  A preset
;; outside that set (`auto', `custom', a host-configured name) has no shield
;; and renders as text.

(defconst dsh-emacs--permission-icon-svgs
  '(("read-only" . "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 16 16\" fill=\"none\"><path d=\"M8.20554 0.899994L14.7901 3.36857V7.01026C14.7901 12 11.0466 14.2103 8.20554 15.3C5.36446 14.2103 1.62012 12 1.62012 7.01026V3.36857L8.20554 0.899994Z\" stroke=\"__C__\" stroke-width=\"1.31831\" stroke-linejoin=\"round\"/><path d=\"M12.1654 5.7552L8.9447 9.41475C8.73044 9.65816 8.53628 9.8804 8.35774 10.0423C8.1713 10.2114 7.94235 10.3717 7.64016 10.4254C7.48207 10.4535 7.32 10.4552 7.16151 10.4294C6.85843 10.3801 6.62728 10.2223 6.43836 10.0559C6.25752 9.89653 6.06037 9.67732 5.84264 9.43705L4.72925 8.20897L5.63557 7.38707L6.74897 8.61594C6.98603 8.87755 7.12974 9.03533 7.24673 9.13839C7.31033 9.19443 7.34485 9.21476 7.35823 9.22122C7.38068 9.22484 7.40352 9.22515 7.42593 9.22122C7.40522 9.22502 7.42893 9.23294 7.53583 9.136C7.65132 9.03126 7.79316 8.87139 8.02643 8.60638L11.2479 4.94763L12.1654 5.7552Z\" fill=\"__C__\"/></svg>")
    ("workspace-write" . "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 16 16\" fill=\"none\"><path d=\"M8.08887 0.251709C8.20479 0.23085 8.32486 0.241168 8.43652 0.282959L15.0215 2.75171C15.2787 2.84819 15.4492 3.09414 15.4492 3.3689V7.0105C15.4492 7.10986 15.4441 7.2081 15.4414 7.30542C15.0285 7.07175 14.5905 6.87695 14.1309 6.73022V3.82495L8.20508 1.60327L2.2793 3.82495V7.0105C2.27936 9.7171 3.4745 11.5379 5.02734 12.7947C5.01025 12.9942 5 13.1962 5 13.4001C5.00001 13.7617 5.02722 14.1169 5.08008 14.4636C2.91555 13.0393 0.961014 10.752 0.960938 7.0105V3.3689C0.960938 3.09417 1.13146 2.84821 1.38867 2.75171L7.97461 0.282959L8.08887 0.251709Z\" fill=\"__C__\"/><path d=\"M11.3525 5.64688V6.85688H5V5.64688H11.3525Z\" fill=\"__C__\"/><path d=\"M9.5824 8.29376V9.50376H5V8.29376H9.5824Z\" fill=\"__C__\"/><path d=\"M14.6647 15.6852H10.0338C10.3878 15.3751 10.7567 15.0517 11.0772 14.7706C11.2531 14.6164 11.4144 14.4746 11.5511 14.3547H14.6647V15.6852Z\" fill=\"__C__\"/><path d=\"M8.14852 14.1308L7.33925 15.4976C7.22458 15.6912 7.42245 15.9194 7.63037 15.8333L9.09785 15.2254L15.0399 10.0719L14.0905 8.97733L8.14852 14.1308Z\" fill=\"__C__\"/></svg>")
    ("danger-full-access" . "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 16 16\" fill=\"none\"><path d=\"M8.20554 0.899994L14.7901 3.36857V7.01026C14.7901 12 11.0466 14.2103 8.20554 15.3C5.36446 14.2103 1.62012 12 1.62012 7.01026V3.36857L8.20554 0.899994Z\" stroke=\"__C__\" stroke-width=\"1.31831\" stroke-linejoin=\"round\"/><path d=\"M9.10094 4.5V8.75939H7.59888V4.5H9.10094Z\" fill=\"__C__\"/><path d=\"M9.10094 9.8114V11.5H7.59888V9.8114H9.10094Z\" fill=\"__C__\"/></svg>"))
  "dsh-web permission shield SVGs (design set 1556), keyed by preset value.")

(defconst dsh-emacs--permission-icon-names
  '(("read-only" . "nf-md-shield_check")
    ("workspace-write" . "nf-md-shield_edit")
    ("danger-full-access" . "nf-md-shield_alert"))
  "Nerd Font Material Design Icons names per permission preset.
Their marks mirror the SVGs: check / pencil / exclamation.")

(defconst dsh-emacs--permission-short-names
  '(("read-only" . "ro")
    ("workspace-write" . "ws")
    ("danger-full-access" . "full"))
  "Compact text for a preset whose icon cannot be drawn.")

(defun dsh-emacs-modeline--permission-svg (value color)
  "Return permission VALUE's shield SVG tinted COLOR, or nil.
VALUE outside the design set (a host-configured preset, `auto', `custom')
has no shield."
  (let ((template (cdr (assoc value dsh-emacs--permission-icon-svgs))))
    (when template
      (replace-regexp-in-string "__C__" color template t t))))

(defun dsh-emacs-modeline--permission-color (face)
  "A concrete foreground color for FACE, or nil when it resolves to none."
  (let ((fg (face-foreground face nil t)))
    (and fg (not (equal fg "unspecified")) fg)))

(defun dsh-emacs-modeline--permission-face (value)
  "The mode-line face for permission VALUE.
An unrestricted session and the derived `custom' state warn; every other
value (including the live `auto') uses the plain permission face."
  (if (member value '("danger-full-access" "custom"))
      'dsh-emacs-modeline-permission-warn-face
    'dsh-emacs-modeline-permission-face))

(defun dsh-emacs-modeline--permission-image (value face)
  "Return VALUE's shield as an SVG display string tinted with FACE, or nil.
Requires a graphical frame whose Emacs can render SVG."
  (when (and (display-graphic-p)
             (fboundp 'image-type-available-p)
             (image-type-available-p 'svg))
    (let ((color (dsh-emacs-modeline--permission-color face)))
      (when color
        (let ((svg (dsh-emacs-modeline--permission-svg value color)))
          (when svg
            (condition-case nil
                (propertize " " 'display
                            (create-image svg 'svg t :ascent 'center :height 1.0))
              (error nil))))))))

(defun dsh-emacs-modeline--permission-nerd-icon (value face)
  "Return VALUE's Nerd Font shield glyph inheriting FACE, or nil.
`nerd-icons' is optional: without it (or without its font) the caller falls
back to text.  The glyph is one cell wide, unlike an emoji."
  (let ((name (cdr (assoc value dsh-emacs--permission-icon-names))))
    (when (and name
               (or (fboundp 'nerd-icons-mdicon)
                   (require 'nerd-icons nil t))
               (fboundp 'nerd-icons-mdicon))
      (nerd-icons-mdicon name :face face))))

(defun dsh-emacs-modeline--permission-short (value)
  "Return VALUE's compact text form, bounded so a host preset cannot sprawl."
  (or (cdr (assoc value dsh-emacs--permission-short-names))
      (truncate-string-to-width value 8 nil nil "…")))

(defun dsh-emacs-modeline--permission-display (value)
  "Return the mode-line display string for permission VALUE, or nil.
`dsh-emacs-modeline-permission-style' `text' always returns VALUE; `icon'
prefers the SVG shield, then the Nerd Font glyph, and falls back to short
text.  Emoji are never used: a mode-line glyph must be one cell wide and
take the segment's face color."
  (let ((face (dsh-emacs-modeline--permission-face value)))
    (if (eq dsh-emacs-modeline-permission-style 'text)
        (propertize value 'face face)
      (or (dsh-emacs-modeline--permission-image value face)
          (dsh-emacs-modeline--permission-nerd-icon value face)
          (propertize (dsh-emacs-modeline--permission-short value) 'face face)))))

(defun dsh-emacs-modeline--segment-permission ()
  "Render the permission-preset segment (the `permissions' projection)."
  (when (and dsh-emacs--modeline-permission
             (not (string-empty-p dsh-emacs--modeline-permission)))
    (dsh-emacs-modeline--annotate
     (dsh-emacs-modeline--permission-display dsh-emacs--modeline-permission)
     (format "Permission preset: %s" dsh-emacs--modeline-permission))))

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
    ('provider (dsh-emacs-modeline--segment-provider))
    ('model (dsh-emacs-modeline--segment-model))
    ('effort (dsh-emacs-modeline--segment-effort))
    ('preset (dsh-emacs-modeline--segment-preset))
    ('permission (dsh-emacs-modeline--segment-permission))
    ('tokens (dsh-emacs-modeline--segment-tokens))
    ('ctx (dsh-emacs-modeline--segment-ctx))
    ('cost (dsh-emacs-modeline--segment-cost))
    (_ nil)))

;;; ---------------------------------------------------------------------------
;;; Mode-line stats string
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
;;; Mode-line line rendering (hooked into mode-line-format in dsh-emacs.el)
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-modeline-update ()
  "Force re-render of the mode-line statistics. No-op outside a dsh-emacs buffer."
  (when (derived-mode-p 'dsh-emacs-mode)
    (setq dsh-emacs-modeline--inline-cache nil)
    (force-mode-line-update)))

(defun dsh-emacs-modeline-toggle ()
  "Toggle mode-line line visibility."
  (interactive)
  (setq dsh-emacs-modeline-enabled (not dsh-emacs-modeline-enabled))
  (dsh-emacs-modeline-update)
  (message "dsh mode-line %s" (if dsh-emacs-modeline-enabled "shown" "hidden")))

;;; ---------------------------------------------------------------------------
;;; Setters
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
  (when (equal (dsh-protocol-event-kind--from-alist event) "assistant/message")
    (dsh-emacs-modeline-add-usage (dsh-emacs-usage-from-event event))))

(defun dsh-emacs-modeline-note-request (event)
  "Pick the model id off a `request/context' EVENT.
The model id refreshes whenever the agent issues a new model request, so
the mode-line segment always reflects the live model.  Context-window
data rides the `session/projection' frames, not this event."
  (let ((data (dsh-protocol-request-model--from-alist event)))
    (when data
      (let ((model (dsh-protocol-model-selection-model data))
            (provider (dsh-protocol-model-selection-provider data)))
        (when (and model (not (string-empty-p model)))
          (setq dsh-emacs--modeline-model model))
        (when (and provider (not (string-empty-p provider)))
          (setq dsh-emacs--modeline-provider provider)))
      (dsh-emacs-modeline-update))))

(defun dsh-emacs-modeline-note-header (event)
  "Pick the model id and reasoning effort off a `request/header' EVENT.
`request/header' carries the model config (data.header.config) when a run
starts; consuming it makes the model, effort and provider segments live on
open, before any later context data arrives."
  (let ((config (dsh-protocol-request-model--from-alist event :header-p t)))
    (when config
      (let ((model (dsh-protocol-model-selection-model config))
            (effort (dsh-protocol-model-selection-reasoning-effort config))
            (provider (dsh-protocol-model-selection-provider config)))
        (when (and model (not (string-empty-p model)))
          (setq dsh-emacs--modeline-model model))
        (when (and effort (not (string-empty-p effort)))
          (setq dsh-emacs--modeline-effort effort))
        (when (and provider (not (string-empty-p provider)))
          (setq dsh-emacs--modeline-provider provider)))
      (dsh-emacs-modeline-update))))

(defvar-local dsh-emacs--modeline-plan nil
  "Last confirmed `dsh-protocol-plan' for this chat, or nil if unavailable.
Plan mode persists across turns and disconnects until a projection replaces it.")

(defvar-local dsh-emacs--modeline-plan-seq nil
  "Newest Plan projection sequence, retained even when the capability is absent.")

(defun dsh-emacs-modeline-set-plan (plan)
  "Merge decoded PLAN by its sequence; nil resets this chat's Plan mirror.
An absent capability still carries a watermark, so an older update cannot
resurrect it after a newer baseline removed it."
  (let ((seq (and plan (dsh-protocol-plan-seq plan))))
    (when (or (not (integerp seq)) (null dsh-emacs--modeline-plan-seq)
              (>= seq dsh-emacs--modeline-plan-seq))
      (setq dsh-emacs--modeline-plan
            (and plan (dsh-protocol-plan-available plan) plan))
      (cond ((integerp seq) (setq dsh-emacs--modeline-plan-seq seq))
            ((null plan) (setq dsh-emacs--modeline-plan-seq nil)))
      (force-mode-line-update))))

(defvar-local dsh-emacs--modeline-compaction nil
  "Current compaction's `dsh-protocol-execution-event', or nil.")

(defvar-local dsh-emacs--modeline-execution-seq nil
  "Newest execution event folded into this buffer's status.")

(defun dsh-emacs-modeline-note-execution (event &optional defer-update)
  "Fold a decoded execution EVENT into this buffer's compaction status.
Standalone compactions survive unrelated turn endings.  With DEFER-UPDATE
non-nil, leave refresh to the caller so snapshot rebuilds redraw only once."
  (let ((seq (dsh-protocol-execution-event-seq event))
        (type (dsh-protocol-execution-event-type event))
        (turn (dsh-protocol-execution-event-turn event))
        (id (dsh-protocol-execution-event-id event))
        (previous-compaction dsh-emacs--modeline-compaction))
    (when (and (member type '("compaction/start" "compaction/end" "turn/end"))
               (or (not (integerp seq))
                   (null dsh-emacs--modeline-execution-seq)
                   (> seq dsh-emacs--modeline-execution-seq)))
      (when (integerp seq) (setq dsh-emacs--modeline-execution-seq seq))
      (pcase type
        ("compaction/start"
         (when (stringp id) (setq dsh-emacs--modeline-compaction event)))
        ("compaction/end"
         (when (and dsh-emacs--modeline-compaction
                    (equal id (dsh-protocol-execution-event-id
                               dsh-emacs--modeline-compaction)))
           (setq dsh-emacs--modeline-compaction nil)))
        ("turn/end"
         (when (and (integerp turn) dsh-emacs--modeline-compaction
                    (equal turn (dsh-protocol-execution-event-turn
                                 dsh-emacs--modeline-compaction)))
           (setq dsh-emacs--modeline-compaction nil))))
      (unless defer-update
        (dsh-emacs-modeline--sync-animation previous-compaction)))))

(defun dsh-emacs-modeline-reset-execution (&optional events)
  "Replace execution feedback with decoded snapshot EVENTS, or clear it.
Fold the whole retained window independently of the transcript's dedup anchor;
an old start may still describe the current operation after reconnection."
  (let ((previous-compaction dsh-emacs--modeline-compaction))
    (setq dsh-emacs--modeline-compaction nil
          dsh-emacs--modeline-execution-seq nil)
    (dolist (event events)
      (dsh-emacs-modeline-note-execution event t))
    (dsh-emacs-modeline--sync-animation previous-compaction)))

(defun dsh-emacs-modeline--status-detail ()
  "Describe this buffer's execution and Plan mode, or return empty text."
  (string-join
   (delq nil
         (list
          (when-let* ((plan dsh-emacs--modeline-plan))
            (concat
             (format "Plan mode: %s"
                     (if (dsh-protocol-plan-active plan) "active" "inactive"))
             (when (dsh-protocol-plan-pending plan)
               (format "\nPending: %s Plan mode (awaiting host confirmation)"
                       (if (dsh-protocol-plan-active plan) "leave" "enter")))
             "\nUse /plan to enter, /plan off to leave."))
          (when-let* ((event dsh-emacs--modeline-compaction))
            (format "Compacting context (%s)"
                    (cond
                     ((dsh-protocol-execution-event-command-id event)
                      "slash command")
                     ((dsh-protocol-execution-event-turn event)
                      (format "turn %s"
                              (dsh-protocol-execution-event-turn event)))
                     (t "between turns"))))))
   "\n\n"))

(defun dsh-emacs-describe-status ()
  "Show the current chat's context-compaction and Plan mode details."
  (interactive "@")
  (unless (derived-mode-p 'dsh-emacs-mode)
    (user-error "Status details require a chat buffer"))
  (let ((detail (dsh-emacs-modeline--status-detail)))
    (with-help-window "*dsh status*"
      (princ (if (string-empty-p detail)
                 "No context compaction or Plan mode is observed."
               detail))
      (princ "\n"))))

(defvar dsh-emacs-modeline--status-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mode-line mouse-1] #'dsh-emacs-describe-status)
    map)
  "Mode-line map for status details.")

(defun dsh-emacs-modeline--plan-indicator ()
  "Return the active or pending Plan mode label, independent of turn liveness."
  (when-let* ((plan dsh-emacs--modeline-plan)
              ((or (dsh-protocol-plan-active plan)
                   (dsh-protocol-plan-pending plan))))
    (propertize
     (if (dsh-protocol-plan-pending plan)
         (if (dsh-protocol-plan-active plan) " Plan → off " " Plan → on ")
       " Plan ")
     'face (if (dsh-protocol-plan-pending plan)
               'dsh-emacs-mode-line-busy-face 'dsh-emacs-accent-face)
     'help-echo (concat (dsh-emacs-modeline--status-detail)
                        "\n\nClick or M-x dsh-emacs-describe-status")
     'mouse-face 'mode-line-highlight
     'local-map dsh-emacs-modeline--status-map)))

(defun dsh-emacs-modeline-note-step (turn step start-p)
  "Record the running turn's step for the mode line.
TURN and STEP are the integers from a `step/start' / `step/end' event,
START-P non-nil for `step/start'.  Durations are measured in local wall-clock
time rather than from the event timestamps on purpose: a reconnect or session
reopen replays a still-open turn's `step/start' from history, and the wire
timestamp would then report an elapsed time of hours instead of the seconds
this process actually watched.  A `step/end' closes only the step it names,
so a replayed or out-of-order end cannot replace a newer step; the badge is
shown only while the running flag is set (`turn/end' clears it)."
  (when (and (integerp turn) (integerp step))
    (if start-p
        (setq dsh-emacs--modeline-step
              (list :turn turn :step step :start (float-time) :end nil))
      (when (and dsh-emacs--modeline-step
                 (= (plist-get dsh-emacs--modeline-step :turn) turn)
                 (= (plist-get dsh-emacs--modeline-step :step) step))
        (setq dsh-emacs--modeline-step
              (plist-put dsh-emacs--modeline-step :end (float-time)))))
    (when dsh-emacs-modeline-show-step
      (dsh-emacs-modeline-update))))

(defun dsh-emacs-modeline-set-context-snapshot (pressure window)
  "Set the server `contextPressure' projection: PRESSURE used / WINDOW total.
Both values come from the same projection, keeping the ctx% numerator and
divisor paired across model switches.  Nil hides the ctx segment.
A non-positive PRESSURE is the degenerate sample of a provider-rejected run
(quota/rate reports usage 0/0 and the fold's last-wins sample collapses to
0), never a real occupancy reading: the previous snapshot is kept untouched
until the next genuine usage sample lands the live pair."
  (let ((p (and pressure (integerp pressure) pressure)))
    (when (or (null p) (> p 0))
      (setq dsh-emacs--modeline-context-pressure p
            dsh-emacs--modeline-context-window-server (and window (integerp window) window))
      (dsh-emacs-modeline-update))))

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

(defun dsh-emacs-modeline-set-permission (permission)
  "Set the displayed permission preset to PERMISSION (a preset key, or nil).
PERMISSION is the `permissions' projection's `currentValue'."
  (setq dsh-emacs--modeline-permission permission)
  (dsh-emacs-modeline-update))

;;; ---------------------------------------------------------------------------
;;; Mode line running-state animation
;;; ---------------------------------------------------------------------------

(defvar-local dsh-emacs--ml-busy nil
  "Non-nil while this chat buffer's dsh session is executing a prompt.")

(defvar-local dsh-emacs--modeline-subagent-active nil
  "Non-nil while a direct child of this chat buffer's session is running.
This drives the activity animation only; it deliberately does not mark the
session busy, so input submission and stop commands keep their turn
semantics.")

(defvar-local dsh-emacs--modeline-run-start nil
  "Local time when this buffer last entered the running state.
Kept while a turn or a direct child is active; cleared when both are idle or
on disconnect.  Never inferred from old history.")

(defvar-local dsh-emacs--modeline-compaction-start nil
  "Local time when this buffer first observed the active compaction.
Independent of the turn clock; repeated snapshots preserve this interval.")

(defun dsh-emacs-modeline--animation-redisplay ()
  "Let pending text paint the whale tail, otherwise request a redraw."
  (unless (or (plist-get (bound-and-true-p dsh-emacs--streaming-assistant)
                        :timer)
              (plist-get (bound-and-true-p dsh-emacs--streaming-thinking)
                        :timer))
    (force-mode-line-update)))

(defun dsh-emacs-modeline--activity-p ()
  "Non-nil when this buffer should show the running activity.
The current turn, standalone compaction, or a running direct child."
  (or dsh-emacs--ml-busy
      dsh-emacs--modeline-compaction
      dsh-emacs--modeline-subagent-active))

(defun dsh-emacs-modeline--sync-run-clock ()
  "Start or clear the local turn clock for the current activity state.
Standalone compaction keeps its own clock, so only a turn or a running
direct child owns this one."
  (if (or dsh-emacs--ml-busy dsh-emacs--modeline-subagent-active)
      (unless dsh-emacs--modeline-run-start
        (setq dsh-emacs--modeline-run-start (float-time)))
    (setq dsh-emacs--modeline-run-start nil)))

(defun dsh-emacs-modeline-set-subagent-activity (active)
  "Track ACTIVE direct-child execution for the running animation.
Called by the subagent owner whenever the child running count changes.  A
running child keeps the whale and its clock alive after the parent turn
ends, but leaves `dsh-emacs--ml-busy' alone so `C-c C-c' does not mistake
the idle parent for a running turn."
  (setq dsh-emacs--modeline-subagent-active (and active t))
  (dsh-emacs-modeline--sync-animation dsh-emacs--modeline-compaction))

(defun dsh-emacs-modeline--sync-animation (previous-compaction)
  "Update the shared activity slot after PREVIOUS-COMPACTION changes.
Turns and standalone compaction share one animation.  A new compaction phase
restarts its caption sweep and local clock without changing the turn clock.
The activity clock follows whichever activity is still live, so a parent turn
ending under a running child keeps it."
  (dsh-emacs-modeline--sync-run-clock)
  (let ((changed
         (not (equal
               (and previous-compaction
                    (dsh-protocol-execution-event-id previous-compaction))
               (and dsh-emacs--modeline-compaction
                    (dsh-protocol-execution-event-id
                     dsh-emacs--modeline-compaction))))))
    (when changed
      (setq dsh-emacs--modeline-compaction-start
            (and dsh-emacs--modeline-compaction (float-time))))
    (when (dsh-emacs-modeline-animation-available-p)
      (if (dsh-emacs-modeline--activity-p)
          (when (or changed
                    (not (dsh-emacs-modeline-animation-playing-p 'dsh-running)))
            (setq-local motion-line-redisplay-function
                        #'dsh-emacs-modeline--animation-redisplay)
            (dsh-emacs-modeline-animation-play
             'dsh-running
             (dsh-emacs-modeline-animation-clip
              3 #'dsh-emacs-modeline--running-status)))
        (dsh-emacs-modeline-animation-stop 'dsh-running)))
    (force-mode-line-update)))

(defun dsh-emacs--ml-busy-set (flag)
  "Set this buffer's running state to FLAG and update its animation slot.
Repeated running snapshots preserve playback position.  Clearing the flag
also drops the finished turn's step badge."
  (setq dsh-emacs--ml-busy (and flag t))
  (unless dsh-emacs--ml-busy
    (setq dsh-emacs--modeline-step nil))
  (dsh-emacs-modeline--sync-animation dsh-emacs--modeline-compaction))

(defun dsh-emacs--ml-busy-clear ()
  "Clear execution status and release this buffer's running animation."
  (setq dsh-emacs--modeline-subagent-active nil)
  (dsh-emacs--ml-busy-set nil)
  (dsh-emacs-modeline-reset-execution))

(defun dsh-emacs--ml-busy-indicator ()
  "Return the running, compacting or child activity, empty when all are idle."
  (if (not (dsh-emacs-modeline--activity-p))
      ""
    (propertize
     (or (dsh-emacs-modeline-animation-text 'dsh-running)
         (if dsh-emacs--modeline-compaction
             (propertize "Compacting" 'face 'dsh-emacs-modeline-compacting-face)
           (propertize "Deep diving" 'face 'dsh-emacs-modeline-running-face)))
     'help-echo (if dsh-emacs--modeline-compaction
                    (concat (dsh-emacs-modeline--status-detail)
                            "\n\nClick or M-x dsh-emacs-describe-status")
                  "dsh is running a request…")
     'mouse-face 'mode-line-highlight
     'local-map (and dsh-emacs--modeline-compaction
                     dsh-emacs-modeline--status-map))))

;;; ---------------------------------------------------------------------------
;;; Structural overlay initialization
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-modeline--step-elapsed (state)
  "Elapsed-time label for step STATE, or nil when under a second or unknown.
STATE carries the boundary events' wall-clock `:start' / `:end' seconds; a
missing end (an open step) measures against the current time, so the label
advances with the running animation's redraws and needs no timer."
  (let ((start (plist-get state :start)))
    (when (numberp start)
      (let ((seconds (floor (- (or (plist-get state :end) (float-time))
                               start))))
        (when (>= seconds 1)
          (if (< seconds 60)
              (format "%ds" seconds)
            (format "%dm%02ds" (/ seconds 60) (% seconds 60))))))))

(defun dsh-emacs-modeline--step-indicator ()
  "Return the running turn's step badge, e.g. \"step 2 · 3s\"; empty when off.
Hidden when `dsh-emacs-modeline-show-step' is nil, when the running animation
is inactive (a finished turn's last step is not a status), or when no step is
known.  The step comes from `step/start' / `step/end' events, which are
turn-internal boundaries rather than transcript content."
  (if (or (not dsh-emacs-modeline-show-step)
          (not (bound-and-true-p dsh-emacs--ml-busy))
          (null dsh-emacs--modeline-step))
      ""
    (let* ((state dsh-emacs--modeline-step)
           (elapsed (dsh-emacs-modeline--step-elapsed state))
           (text (concat "step "
                         (number-to-string (plist-get state :step))
                         (when elapsed (concat " · " elapsed)))))
      (propertize text
                  'face 'dsh-emacs-mode-line-busy-face
                  'help-echo (format "dsh turn %s · step %s"
                                     (plist-get state :turn)
                                     (plist-get state :step))
                  'mouse-face 'mode-line-highlight))))

(defun dsh-emacs-modeline--join (&rest parts)
  "Join nonempty PARTS with one space, preserving display-bearing spaces.
Only ordinary edge padding is removed; SVG placeholders, internal spacing
and text properties remain intact."
  (let (trimmed)
    (dolist (text parts)
      (when text
        (let ((start 0) (end (length text)))
          (while (and (< start end) (= (aref text start) ?\s)
                      (not (get-text-property start 'display text)))
            (setq start (1+ start)))
          (while (and (> end start) (= (aref text (1- end)) ?\s)
                      (not (get-text-property (1- end) 'display text)))
            (setq end (1- end)))
          (when (< start end) (push (substring text start end) trimmed)))))
    (string-join (nreverse trimmed) " ")))

(defun dsh-emacs-modeline--ml-indicator ()
  "Return the running animation, step and Plan mode near the mode name.
Standalone compaction shares the activity slot without implying a busy turn."
  (let* ((frame (if dsh-emacs-modeline--doom-segment-installed ""
                  (dsh-emacs--ml-busy-indicator)))
         (text (dsh-emacs-modeline--join
                frame
                (when dsh-emacs--ml-busy
                  (dsh-emacs-modeline--step-indicator))
                (dsh-emacs-modeline--plan-indicator))))
    (if (string-empty-p text) "" (concat " " text " "))))

(defun dsh-emacs-modeline--escape-percent (txt)
  "Escape `%' in TXT for mode-line display, keeping text properties.
Mode-line strings undergo `%'-sequence expansion, so a literal `%' must be
doubled to `%%'.  Each duplicate keeps the face at the original position, so
rendered tokens (faces on `CH99%') keep their color."
  (save-match-data
    (let ((start 0) pos parts)
      (while (setq pos (string-match "%" txt start))
        (push (substring txt start (1+ pos)) parts)
        (push (substring txt pos (1+ pos)) parts)
        (setq start (1+ pos)))
      (if parts
          (apply #'concat (nreverse (cons (substring txt start) parts)))
        txt))))

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
    ;; INPUTS mirrors every value the segments read: a segment input missing
    ;; here stays frozen at its cached text.
    (let* ((spec dsh-emacs-modeline-format-spec)
           (segments (or (plist-get spec :segments)
                         '(cwd branch model tokens ctx cost)))
           (inputs
            (list dsh-emacs-modeline-enabled
                  (or (plist-get spec :separator) " • ") segments
                  (or dsh-emacs--modeline-model
                      (and (boundp 'dsh-emacs-default-model)
                           dsh-emacs-default-model))
                  dsh-emacs--modeline-provider dsh-emacs--modeline-effort
                  dsh-emacs--modeline-preset
                  default-directory
                  dsh-emacs--modeline-permission
                  dsh-emacs-modeline-permission-style
                  ;; The shield's color is baked into the SVG image, so a
                  ;; theme change (same value, different face color) must
                  ;; invalidate the cached inline string too.
                  (and dsh-emacs--modeline-permission
                       (dsh-emacs-modeline--permission-color
                        (dsh-emacs-modeline--permission-face
                         dsh-emacs--modeline-permission)))
                  (and (memq 'cwd segments)
                       (or (getenv "HOME") (user-login-name)))
                  (and dsh-emacs-modeline-enabled (memq 'branch segments)
                       (dsh-emacs-modeline--cached-branch))
                  dsh-emacs--modeline-context-pressure
                  dsh-emacs--modeline-context-window-server
                  dsh-emacs--modeline-usage)))
      (unless (and dsh-emacs-modeline--inline-cache
                   (equal-including-properties
                    inputs (car dsh-emacs-modeline--inline-cache)))
        (let* ((txt (dsh-emacs-modeline-format))
               (inline (if (string-empty-p txt) ""
                         (concat
                          (propertize "(" 'face 'dsh-emacs-modeline-separator-face)
                          (dsh-emacs-modeline--escape-percent txt)
                          (propertize ") " 'face 'dsh-emacs-modeline-separator-face)))))
          ;; Snapshot caller-owned strings and lists so an in-place edit
          ;; differs from the snapshot.  The usage plist is copied the same
          ;; way, which also hides in-place mutation: every mutator must
          ;; clear this cache through `dsh-emacs-modeline-update'.
          (setq dsh-emacs-modeline--inline-cache
                (cons (mapcar (lambda (value)
                                (if (or (stringp value) (consp value))
                                    (copy-sequence value)
                                  value))
                              inputs)
                      inline))))
      (cdr dsh-emacs-modeline--inline-cache))))

;; DeepSeek Harness favicon, @deepseek-ai/dsh-web-frontend 0.2.0-rc.2.
;; Source: https://github.com/deepseek-ai/deepseek-harness
;; MIT License
;;
;; Copyright (c) 2026 DeepSeek
;;
;; Permission is hereby granted, free of charge, to any person obtaining a copy
;; of this software and associated documentation files (the "Software"), to deal
;; in the Software without restriction, including without limitation the rights
;; to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
;; copies of the Software, and to permit persons to whom the Software is
;; furnished to do so, subject to the following conditions:
;;
;; The above copyright notice and this permission notice shall be included in all
;; copies or substantial portions of the Software.
;;
;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
;; IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
;; FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
;; AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
;; LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
;; OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
;; SOFTWARE.

(defconst dsh-emacs-modeline--logo-svg
  "<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" width=\"21\" height=\"16\" viewBox=\"0 6 50 38\" fill=\"none\">\n\t<path id=\"path\" d=\"M48.8354 10.0479C48.3232 9.79199 48.1025 10.2798 47.8032 10.5278C47.7007 10.6079 47.6143 10.7119 47.5273 10.8076C46.7793 11.624 45.9048 12.1597 44.7622 12.0957C43.0923 12 41.666 12.5356 40.4058 13.8398C40.1377 12.2319 39.2476 11.272 37.8926 10.6558C37.1836 10.3359 36.4668 10.0156 35.9702 9.31982C35.6235 8.82373 35.5293 8.27197 35.356 7.72754C35.2456 7.3999 35.1353 7.06396 34.7651 7.00781C34.3633 6.94385 34.2056 7.2876 34.0479 7.57568C33.418 8.75195 33.1733 10.0479 33.1973 11.3599C33.2524 14.312 34.4736 16.6641 36.8999 18.3359C37.1758 18.5278 37.2466 18.7197 37.1597 19C36.9946 19.5757 36.7974 20.1357 36.624 20.7119C36.5137 21.0801 36.3486 21.1597 35.9624 21C34.6309 20.4321 33.481 19.5918 32.4644 18.5757C30.7393 16.8721 29.1792 14.9917 27.2334 13.52C26.7764 13.1758 26.3193 12.856 25.8467 12.5518C23.8618 10.584 26.1069 8.96777 26.627 8.77588C27.1704 8.57568 26.8159 7.8877 25.0591 7.896C23.3022 7.90381 21.6953 8.50391 19.647 9.30371C19.3477 9.42383 19.0322 9.51172 18.7095 9.58398C16.8501 9.22363 14.9199 9.14355 12.9033 9.37598C9.10596 9.80762 6.07275 11.6396 3.84326 14.7681C1.16455 18.5278 0.53418 22.7998 1.30664 27.2559C2.11768 31.9521 4.46582 35.8398 8.07373 38.8799C11.8159 42.0322 16.1255 43.5762 21.041 43.2803C24.0269 43.104 27.3516 42.6963 31.1016 39.4561C32.0469 39.936 33.0396 40.1279 34.686 40.272C35.9546 40.3921 37.1758 40.208 38.1211 40.0078C39.6021 39.688 39.4995 38.2881 38.9639 38.0322C34.623 35.9678 35.5762 36.8081 34.71 36.1279C36.9155 33.4639 40.2402 30.6958 41.54 21.728C41.6426 21.0161 41.5557 20.5679 41.54 19.9917C41.5322 19.6396 41.6108 19.5039 42.0049 19.4639C43.0923 19.3359 44.1479 19.0317 45.1167 18.4878C47.9292 16.9199 49.064 14.3438 49.3315 11.2559C49.3711 10.7837 49.3237 10.2959 48.8354 10.0479ZM24.3262 37.8398C20.1196 34.4639 18.0791 33.3521 17.2358 33.3999C16.4482 33.4482 16.5898 34.3682 16.7632 34.9678C16.9443 35.5601 17.1812 35.9683 17.5117 36.4878C17.7402 36.832 17.8979 37.3442 17.2832 37.728C15.9282 38.584 13.5728 37.4399 13.4624 37.3838C10.7207 35.7358 8.42822 33.5601 6.81348 30.584C5.25342 27.7197 4.34766 24.6479 4.19775 21.3677C4.1582 20.5757 4.38672 20.2959 5.15869 20.1519C6.17529 19.96 7.22314 19.9199 8.23926 20.0718C12.5327 20.7119 16.1885 22.6719 19.2529 25.7759C21.002 27.5439 22.3252 29.6558 23.6885 31.7202C25.1377 33.9121 26.6978 36 28.6831 37.7119C29.3843 38.312 29.9434 38.7681 30.479 39.104C28.8643 39.2881 26.1699 39.3281 24.3262 37.8398ZM26.3433 24.6001C26.3433 24.248 26.6191 23.9678 26.9658 23.9678C27.0444 23.9678 27.1152 23.9839 27.1782 24.0078C27.2651 24.04 27.3438 24.0879 27.4067 24.1602C27.5171 24.272 27.5801 24.4321 27.5801 24.6001C27.5801 24.9521 27.3042 25.2319 26.9575 25.2319C26.6108 25.2319 26.3433 24.9521 26.3433 24.6001ZM32.6064 27.8799C32.2046 28.0479 31.8027 28.1919 31.4165 28.208C30.8179 28.2397 30.1641 27.9922 29.8096 27.688C29.2583 27.2158 28.8643 26.9521 28.6987 26.1279C28.6279 25.7759 28.6675 25.2319 28.7305 24.9199C28.8721 24.248 28.7144 23.8159 28.2495 23.4238C27.8716 23.104 27.3911 23.0161 26.8633 23.0161C26.666 23.0161 26.4849 22.9277 26.3511 22.856C26.1304 22.7441 25.9492 22.4639 26.1226 22.1201C26.1777 22.0078 26.4458 21.7358 26.5088 21.688C27.2256 21.272 28.0527 21.4077 28.8169 21.7197C29.5259 22.0161 30.0615 22.5601 30.834 23.3281C31.6216 24.2559 31.7632 24.5117 32.2124 25.208C32.5669 25.752 32.8901 26.312 33.1104 26.9521C33.2446 27.3521 33.0713 27.6802 32.6064 27.8799Z\" fill=\"#000\" fill-opacity=\"1.000000\" fill-rule=\"nonzero\"/>\n</svg>"
  "DeepSeek Harness whale SVG with vertical padding cropped.
The visible whale matches the shield height without making the line taller.")

(defvar dsh-emacs-modeline--logo-labels nil
  "Alist of whale colors to cached mode names with image display properties.")

(defun dsh-emacs-modeline--logo-color ()
  "Return the shared logo and whale-tail color for the selected frame."
  (if (eq (frame-parameter nil 'background-mode) 'dark) "#4d6bfe" "#000"))

(defun dsh-emacs-modeline--whale-label ()
  "Return a larger DSH whale label, or `DSH' when SVG is unavailable."
  (if (and (display-graphic-p) (image-type-available-p 'svg))
      (let ((color (dsh-emacs-modeline--logo-color)))
        (or (cdr (assoc color dsh-emacs-modeline--logo-labels))
            (let* ((svg (replace-regexp-in-string
                         "#000" color dsh-emacs-modeline--logo-svg t t))
                   (label (propertize
                           "DSH" 'display
                           (create-image svg 'svg t :ascent 'center :height 1.3))))
              (push (cons color label) dsh-emacs-modeline--logo-labels)
              label)))
    "DSH"))

;; Static fallback from @deepseek-ai/dsh-client-ui-chat 0.2.0-rc.2,
;; RunningWhaleTail.js (MIT). The animated web version uses an APNG mask.
(defconst dsh-emacs-modeline--whale-tail-path
  "M8.844 13.742C8.967 12.328 8.45 10.4 8.45 9.65C8.45 8.94 8.88 8.43 9.6 8.43C11.285 8.43 12.106 8.281 12.685 8.104C13.71 7.791 14.585 6.768 15.055 5.945C15.137 5.803 14.99 5.641 14.829 5.671C13.829 5.86 12.828 5.376 11.827 4.978C10.659 4.514 9.491 4.707 8.935 4.876C8.805 4.915 8.658 4.819 8.636 4.686C8.468 3.643 7.405 2.615 5.498 2.238C4.54 2.048 3.748 1.574 3.347 1.202C3.252 1.113 3.088 1.125 3.03 1.242C2.628 2.059 2.168 3.82 5.248 6.115C5.82 6.494 6.31 6.785 6.574 7.637C6.72 8.104 6.157 9.168 6.061 9.368C5.157 11.27 5.089 12.19 4.926 13.742")

(defvar dsh-emacs-modeline--whale-tail-labels nil
  "Alist of mode-line colors to cached DSH whale-tail labels.")

;; Embedded whale artwork, derived from DeepSeek Harness (MIT).
;; Regenerate with scripts/build-whale-tail.py; see assets/dsh-whale-tail.md.
;; Copyright (c) 2026 DeepSeek
;;
;; Permission is hereby granted, free of charge, to any person obtaining a copy
;; of this software and associated documentation files (the "Software"), to deal
;; in the Software without restriction, including without limitation the rights
;; to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
;; copies of the Software, and to permit persons to whom the Software is
;; furnished to do so, subject to the following conditions:
;;
;; The above copyright notice and this permission notice shall be included in all
;; copies or substantial portions of the Software.
;;
;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
;; IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
;; FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
;; AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
;; LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
;; OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
;; SOFTWARE.

(defconst dsh-emacs-modeline--whale-tail-gif-base64
  "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
hDrUJsWqS2dKzWk0KACqUFnuDOu1rFmBAQEAOw=="
  "Base64 GIF mask: sixty 28×28 frames, each displayed for 50ms.")

(defvar dsh-emacs-modeline--whale-tail-gif-data nil
  "Raw APNG-derived GIF frames used for the running whale tail.")

(defun dsh-emacs-modeline--whale-tail-animation-data (color)
  "Return the animated tail GIF tinted to COLOR."
  (unless dsh-emacs-modeline--whale-tail-gif-data
    (setq dsh-emacs-modeline--whale-tail-gif-data
          (base64-decode-string dsh-emacs-modeline--whale-tail-gif-base64)))
  (let ((data (copy-sequence dsh-emacs-modeline--whale-tail-gif-data))
        (rgb (color-values color)))
    ;; The asset's two-entry global palette reserves index 0 for transparent
    ;; pixels and index 1 for the foreground color.
    (when (and (> (length data) 18)
               (string-prefix-p "GIF89a" data)
               (= (aref data 10) #xf0)
               (= (length rgb) 3))
      (let ((offset 16))
        (dolist (component rgb)
          (aset data offset (logand #xff (lsh component -8)))
          (setq offset (1+ offset)))))
    data))

(defvar dsh-emacs-modeline--whale-tail-frames nil
  "Last (COLOR . FRAMES) for the web whale's sixty indexed GIF images.")

(defun dsh-emacs-modeline--running-frame (seconds)
  "Render the web whale at local SECONDS without starting image timers.
The embedded asset retains the web APNG's sixty 50ms frames.  GIF image
indices are selected explicitly; redisplay only sees the cached string."
  (if (and (display-graphic-p) (image-type-available-p 'gif))
      (let ((color (dsh-emacs-modeline--logo-color)))
        (unless (equal color (car dsh-emacs-modeline--whale-tail-frames))
          (let ((data (dsh-emacs-modeline--whale-tail-animation-data color)))
            (setq dsh-emacs-modeline--whale-tail-frames
                  (cons color
                        (vconcat
                         (cl-loop for index below 60 collect
                                  (propertize
                                   "DSH" 'display
                                   (create-image data 'gif t :index index
                                                 :width 18 :height 18
                                                 :ascent 'center))))))))
        (aref (cdr dsh-emacs-modeline--whale-tail-frames)
              (min 59 (floor (* seconds 20)))))
    (propertize (aref ["DSH.  " "DSH.. " "DSH..."]
                      (min 2 (floor seconds)))
                'face 'dsh-emacs-mode-line-busy-face)))

(defun dsh-emacs-modeline--running-status (phase)
  "Compose the whale, sweeping caption and elapsed time at loop PHASE.
PHASE drives only the three-second visual loop.  Compaction takes over the
caption and clock while preserving the enclosing turn's running interval."
  (let* ((compacting dsh-emacs--modeline-compaction)
         (face (if compacting 'dsh-emacs-modeline-compacting-face
                 'dsh-emacs-modeline-running-face))
         (highlight (if compacting
                        'dsh-emacs-modeline-compacting-highlight-face
                      'dsh-emacs-modeline-running-highlight-face))
         (caption (propertize (if compacting "Compacting" "Deep diving")
                              'face face))
         (start (if compacting dsh-emacs--modeline-compaction-start
                  dsh-emacs--modeline-run-start))
         (elapsed (max 0 (floor (- (float-time)
                                   (or start (float-time))))))
         (duration (if (< elapsed 60) (format "%ds" elapsed)
                     (format "%dm%02ds" (/ elapsed 60) (% elapsed 60)))))
    (when (display-graphic-p)
      (let* ((base (color-name-to-rgb
                    (face-foreground face nil t)))
             (peak (color-name-to-rgb
                    (face-foreground highlight nil t)))
             ;; Enter and exit outside the text so the loop has a quiet gap.
             (center (- (* (/ phase 3.0) (+ (length caption) 6)) 3)))
        (when (and base peak)
          (dotimes (index (length caption))
            (let ((strength (max 0 (- 1 (/ (abs (- index center)) 2.0)))))
              (when (> strength 0)
                (put-text-property
                 index (1+ index) 'face
                 (list :inherit face
                       :foreground
                       (apply #'color-rgb-to-hex
                              (append (cl-mapcar
                                       (lambda (low high)
                                         (+ low (* strength (- high low))))
                                       base peak)
                                      '(2))))
                 caption)))))))
    (concat (dsh-emacs-modeline--running-frame phase) " " caption
            (propertize (concat " · " duration)
                        'face face))))

(defun dsh-emacs-modeline--whale-tail-label ()
  "Return the running or idle tail, using a centered 18-pixel display box."
  (cond
   ((dsh-emacs-modeline--activity-p)
    (dsh-emacs--ml-busy-indicator))
   ((and (display-graphic-p) (image-type-available-p 'svg))
    (let ((color (dsh-emacs-modeline--logo-color)))
      (or (cdr (assoc color dsh-emacs-modeline--whale-tail-labels))
          (let* ((svg (format
                       (concat "<svg xmlns=\"http://www.w3.org/2000/svg\" "
                               "width=\"18\" height=\"18\" "
                               "viewBox=\"0 0 16 16\" fill=\"none\">"
                               "<path d=\"%s\" stroke=\"%s\" "
                               "stroke-width=\"1\"/></svg>")
                       dsh-emacs-modeline--whale-tail-path color))
                 (label (propertize
                         "DSH" 'display
                         (create-image svg 'svg t :ascent 'center))))
            (push (cons color label) dsh-emacs-modeline--whale-tail-labels)
            label))))
   (t "DSH")))

(defun dsh-emacs-modeline--nerd-icon (_icon-name &rest _args)
  "Return the DSH whale for Nerd Icons' major-mode lookup."
  (dsh-emacs-modeline--whale-label))

(defun dsh-emacs-modeline--nerd-icon-for-mode (orig-fn mode &rest args)
  "Return the DSH whale for MODE, otherwise call ORIG-FN with ARGS."
  (if (eq mode 'dsh-emacs-mode)
      (dsh-emacs-modeline--whale-label)
    (apply orig-fn mode args)))

(defun dsh-emacs-modeline--install-nerd-icon ()
  "Register the DSH major-mode icon with Nerd Icons."
  ;; Nerd Icons caches mode icons; this intercepts DSH before stale cached
  ;; results reach `nerd-icons-completion' buffer candidates.
  (advice-add 'nerd-icons-icon-for-mode :around
              #'dsh-emacs-modeline--nerd-icon-for-mode)
  (add-to-list 'nerd-icons-mode-icon-alist
               '(dsh-emacs-mode dsh-emacs-modeline--nerd-icon "DSH")))

(eval-after-load 'nerd-icons #'dsh-emacs-modeline--install-nerd-icon)

(defun dsh-emacs-modeline--mode-name ()
  "Return plain DSH for native mode lines, or Doom's static whale label.
Native activity stays in its separate animation segment."
  (if dsh-emacs-modeline--doom-segment-installed
      (dsh-emacs-modeline--whale-label)
    "DSH"))

(defun dsh-emacs-modeline--splice (base)
  "Return BASE with the dsh mode-line segments spliced in.
Perfers inserting right after `mode-line-modes' (next to the mode name);
when the base format has no such anchor — e.g. package-composed mode lines
like doom-modeline that render everything through a single `:eval' — the
segments are inserted right after the first element instead, so they stay
visible at the left edge of the line instead of being clipped past the
width-filling renderer.  BASE is the pre-existing mode-line-format list."
  (let ((segments '((:eval (dsh-emacs-modeline--doom-segment)))))
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

(defun dsh-emacs-modeline--subagent-text ()
  "Return the subagent segment, animated while its pulse is playing.
The animated string already escapes percent signs for mode-line expansion;
the static indicator still needs `dsh-emacs-modeline--escape-percent'."
  (or (dsh-emacs-subagent-animation-text)
      (dsh-emacs-modeline--escape-percent (dsh-emacs-subagent-indicator))))

(defun dsh-emacs-modeline--doom-segment ()
  "Compose dsh status for both Doom and the native mode-line splice.
Nonempty pieces have one separating space.  Outer padding separates the
mode name and protects the final column on right-aligned mode lines."
  (if (not (derived-mode-p 'dsh-emacs-mode))
      ""
    (let ((text (dsh-emacs-modeline--join
                 (dsh-emacs-modeline--ml-indicator)
                 (dsh-emacs-modeline--subagent-text)
                 (dsh-emacs-modeline--modeinline))))
      (if (string-empty-p text) "" (concat " " text " ")))))

(defun dsh-emacs-modeline--doom-major-mode (text)
  "Show the DSH Web running-status whale tail in Doom's mode slot.
Compaction opens status details; otherwise keep the standard major-mode menu.
Both presentations preserve Doom's segment styling."
  (if (and (derived-mode-p 'dsh-emacs-mode) (stringp text))
      (let ((label (copy-sequence (dsh-emacs-modeline--whale-tail-label))))
        (add-face-text-property 0 (length label)
                                (get-text-property 1 'face text) t label)
        (if dsh-emacs--modeline-compaction
            label
          (propertize label
                      'help-echo (get-text-property 1 'help-echo text)
                      'mouse-face (get-text-property 1 'mouse-face text)
                      'local-map mode-line-major-mode-keymap)))
    text))

(defun dsh-emacs-modeline--doom-buffer-file-icon (orig-fn &rest args)
  "Skip Doom's file-icon refresh for a fileless DSH chat buffer."
  (if (and (derived-mode-p 'dsh-emacs-mode) (null buffer-file-name))
      nil
    (apply orig-fn args)))

(defun dsh-emacs-modeline--install-doom-icon ()
  "Register the DSH buffer icon with Doom Modeline."
  (when (fboundp 'doom-modeline-update-buffer-file-icon)
    (advice-add 'doom-modeline-update-buffer-file-icon :around
                #'dsh-emacs-modeline--doom-buffer-file-icon)))

(eval-after-load 'doom-modeline-segments
  #'dsh-emacs-modeline--install-doom-icon)

(defun dsh-emacs-modeline--install-doom-segment ()
  "Register the DSH whale before `buffer-info' and stats after `major-mode'.
Returns t on success; nil when Doom Modeline is unavailable or lacks either
anchor (caller then falls back to the plain mode-line splice)."
  (when (and (featurep 'doom-modeline)
             (fboundp 'doom-modeline-def-segment)
             (fboundp 'doom-modeline-add-segment)
             (boundp 'doom-modeline--modelines)
             (boundp 'doom-modeline--fn-alist)
             (let* ((def (assq 'main (symbol-value 'doom-modeline--modelines)))
                    (sides (cdr def))
                    (lhs (car sides))
                    (rhs (cadr sides)))
               (and (memq 'buffer-info lhs) (memq 'major-mode rhs))))
    (let ((renderer (alist-get 'major-mode
                               (symbol-value 'doom-modeline--fn-alist))))
      (when (and (symbolp renderer) (fboundp renderer))
        (advice-add renderer :filter-return
                    #'dsh-emacs-modeline--doom-major-mode)))
    (unless dsh-emacs-modeline--doom-segment-installed
      ;; Define the segment at runtime with eval so the official macro
      ;; (not expandable at our byte-compile time — it lives in the user's
      ;; doom-modeline) expands against the actually installed version.
      (unless (alist-get 'dsh-emacs-whale
                         (symbol-value 'doom-modeline--fn-alist))
        (eval '(doom-modeline-def-segment dsh-emacs-whale
                 (when (derived-mode-p 'dsh-emacs-mode)
                   (propertize
                     (dsh-emacs-modeline--mode-name)
                     'help-echo "Major mode\nmouse-1: Display major mode menu\nmouse-2: Show help for major mode\nmouse-3: Toggle minor modes"
                     'face (doom-modeline-face
                            'doom-modeline-buffer-major-mode)
                     'mouse-face 'doom-modeline-highlight
                     'local-map mode-line-major-mode-keymap)))))
      (unless (alist-get 'dsh-emacs-stats
                         (symbol-value 'doom-modeline--fn-alist))
        (eval '(doom-modeline-def-segment dsh-emacs-stats
                (dsh-emacs-modeline--doom-segment))))
      (setq dsh-emacs-modeline--doom-segment-installed t))
    ;; Custom layouts use the same anchors.  Check each layout on every setup
    ;; so a later definition gets its segments without duplicating earlier ones.
    ;; Doom's API continues to honor `doom-modeline-excluded-modelines'.
    (dolist (definition (symbol-value 'doom-modeline--modelines))
      (pcase-let* ((`(,name ,lhs ,rhs) definition)
                   (segments (append lhs rhs)))
        (when (and (memq 'buffer-info segments)
                   (not (memq 'dsh-emacs-whale segments)))
          (doom-modeline-add-segment 'dsh-emacs-whale 'buffer-info :before name))
        (when (and (memq 'major-mode segments)
                   (not (memq 'dsh-emacs-stats segments)))
          (doom-modeline-add-segment 'dsh-emacs-stats 'major-mode :after name))))
    ;; Verify the segment actually landed somewhere.
    (let* ((def (assq 'main (symbol-value 'doom-modeline--modelines)))
           (sides (cdr def))
           (lhs (car sides))
           (rhs (cadr sides)))
      (and (memq 'dsh-emacs-whale lhs)
           (memq 'dsh-emacs-stats rhs)))))

(defun dsh-emacs-modeline-setup ()
  "Initialize the mode-line structures and splice dsh segments into the mode line.
The buffer keeps its existing (default or user-customized) mode-line-format;
Doom places the DSH whale before the buffer name, and the stats stay beside the
right-side major-mode segment.  The running animation is also composed here.
Splice and structural overlay happen unconditionally: whether stats are shown
is decided per redraw by `dsh-emacs-modeline-enabled' (evaluated inside the
mode-line `:eval'), so toggling the mode-line on later works without reopening
the session.  Should be called from `dsh-emacs-mode-hook' or after creating a
dsh-emacs buffer."
  ;; Each open re-accumulates usage from the freshly loaded history, so
  ;; drop any usage left over from a previous visit to this buffer.
  (setq dsh-emacs--modeline-usage nil)
  (dsh-emacs-modeline-set-plan nil)
  (dsh-emacs-modeline-reset-execution)
  ;; Create the structural end-of-buffer overlay (kept purely as the
  ;; separator the input-area geometry relies on).  The newline is input-area
  ;; geometry, not user text: it must never become an undo step of its own.
  (unless dsh-emacs--modeline-overlay
    (let ((inhibit-read-only t)
          (buffer-undo-list t))
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
  (dsh-emacs-modeline-update))

;;; ---------------------------------------------------------------------------

(provide 'dsh-emacs-modeline)

;;; dsh-emacs-modeline.el ends here
