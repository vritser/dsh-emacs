;;; dsh-emacs-render.el --- Event renderers for dsh-emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2025 vritser

;; Author: vritser
;; Version: 0.7.0
;; License: GPL-3.0-or-later
;; Package-Requires: ((emacs "28.1"))

;;; Commentary:

;; Event renderers.  The visual language follows agent-shell / pi / opencode:
;;
;;   * user message → card background (pale cyan), no heavy border
;;   * assistant message → borderless, just the markdown body + top/bottom rules
;;   * thinking block → `<details>`-style, collapsible, collapsed by default
;;   * tool call → rounded box, recolored by pending/success/error state
;; Used together with dsh-emacs.el.  Every render function expects the
;; buffer-local variables `dsh-emacs--session-id' and `dsh-emacs--input-marker'
;; to be set.

;;; Code:

(require 'json)
(require 'cl-lib)
(require 'subr-x)
(require 'button)
(require 'hl-line)
(require 'dsh-emacs-protocol)
(require 'dsh-emacs-server)
(require 'dsh-emacs-ui)
(require 'dsh-emacs-faces)
(require 'dsh-emacs-tokens)
(require 'dsh-emacs-markdown)
(require 'dsh-emacs-plan)

(declare-function dsh-emacs-markdown--stream-end "dsh-emacs-markdown" (state))
(declare-function dsh-emacs-markdown--watermark-start "dsh-emacs-markdown"
                  (&optional stream-state))
(defvar dsh-emacs-markdown--render-window)

;; Defined by image.el, which a build without image support may not load; the
;; attachment placeholder checks the available types at runtime.
(defvar image-types)

;; Defined in dsh-emacs-reference.el, loaded by dsh-emacs.el.  Turns completed
;; @ file/session mentions in a user message into clickable colored links, and
;; propertizes a standalone file path for the deliverables row's link.
(declare-function dsh-emacs-reference-fontify "dsh-emacs-reference"
                  (string &optional references))
(declare-function dsh-emacs-reference-file-link "dsh-emacs-reference" (path))

;; Defined in dsh-emacs-command.el, loaded by dsh-emacs.el.  Chips the
;; catalog-confirmed `/name' gestures of a user message, and re-chips one from
;; the host's `skill-invocation' evidence (see
;; `dsh-emacs-render--insert-user-block').
(declare-function dsh-emacs-command-fontify-gestures "dsh-emacs-command"
                  (string))
(declare-function dsh-emacs-command-decorate-skill-gesture "dsh-emacs-command"
                  (beg end name))

;; Defined in dsh-emacs-composer.el, which loads via dsh-emacs.el after this
;; module.  The goal round trigger reuses the Goal Row's dsh-web dartboard so
;; one goal keeps one icon across the composer and the transcript.
(declare-function dsh-emacs-composer--goal-icon "dsh-emacs-composer" ())

;; Defined in dsh-emacs-modeline.el, which loads via dsh-emacs.el after this
;; module.  Called at runtime from turn/end handling and event dispatch.
(declare-function dsh-emacs--ml-busy-set "dsh-emacs-modeline" (flag))
(declare-function dsh-emacs-modeline-note-event "dsh-emacs-modeline" (event))
(declare-function dsh-emacs-modeline-note-request "dsh-emacs-modeline" (event))
(declare-function dsh-emacs-modeline-note-header "dsh-emacs-modeline" (event))
(declare-function dsh-emacs-modeline-note-step
    "dsh-emacs-modeline" (turn step start-p))
(declare-function dsh-emacs-modeline-note-execution
    "dsh-emacs-modeline" (event &optional defer-update))
;; Defined in dsh-emacs.el, which loads after this module.  Called at runtime
;; from the inline-image attachment path (placeholder fill / RET open).
(declare-function dsh-emacs--active-session-id "dsh-emacs" ())
(declare-function dsh-emacs--forget-user-message-echo "dsh-emacs" (message))
(declare-function dsh-emacs-fork-session "dsh-emacs" (session-id &optional at-seq))
(defvar dsh-emacs--buffer-session)
(defvar dsh-emacs--buffer-subagent)
;; Notification backends are built into their respective Emacs ports.
(declare-function dsh-emacs--chat-title "dsh-emacs" (session-id))
(declare-function notifications-notify "notifications" (&rest params))
(declare-function ns-do-applescript "ns-win" (script))
(declare-function w32-notification-notify "w32fns.c" (&rest params))
;; Defined in dsh-emacs-command.el; called from the optimistic slash-command
;; render path before that module is loaded.
(declare-function dsh-emacs-command-parse "dsh-emacs-command" (line))
(defvar dsh-emacs--input-marker)
(defvar dsh-emacs--composer-top-marker)
;; Latest decoded question projection, owned by dsh-emacs.el.
(defvar dsh-emacs--session-questions)

;;; ---------------------------------------------------------------------------
;;; Customization
;;; ---------------------------------------------------------------------------

(defgroup dsh-emacs-render nil
  "Event renderers for `dsh-emacs'."
  :group 'dsh-emacs
  :prefix "dsh-emacs-")

(defcustom dsh-emacs-stream-markdown-limit 8192
  "Maximum pending characters to format immediately in assistant replies.
Longer partial lines remain visible and finish styling at a newline or the
final reply.  Large ready regions are formatted after 0.1 seconds of idle
time, with user input interrupting the attempt until the next idle period.
This also applies to final-only replies and messages loaded from history.
Nil keeps all formatting synchronous."
  :type '(choice (const :tag "Always synchronous" nil)
                 (integer :tag "Characters"))
  :group 'dsh-emacs)

(defcustom dsh-emacs-show-thinking t
  "Whether to show thinking (reasoning) content in the transcript.
The UI row is the Think row; the wire content kind is `reasoning'.  On by
default, matching dsh web (the web UI always shows the Think row); set to
nil for a leaner transcript."
  :type 'boolean
  :group 'dsh-emacs-render)

(defcustom dsh-emacs-show-tool-calls t
  "Whether to show tool calls (bash / read / write etc.) in the transcript."
  :type 'boolean
  :group 'dsh-emacs-render)

(defcustom dsh-emacs-render-style 'full
  "Leading icon style for transcript event rows.
`full' draws each row's own dsh-web icon: the per-tool SVG, the Think
sparkle, the plan checklist, and the goal and turn-trigger glyphs.  Displays
without SVG use their text or dot fallbacks.  `simple' replaces every event
icon with one compact dot in the row's accent color, like pi or Claude Code;
tool dots follow their pending/success/error/stopped state, while row labels
and summaries use the muted `dsh-emacs-event-row-face' and status text stays
muted, so the dot is the only colored row element.  This option affects newly
rendered rows; reopen a session to restyle an existing transcript."
  :type '(choice (const :tag "Full icons" full)
                 (const :tag "Simplified dots" simple))
  :group 'dsh-emacs-render)

(defcustom dsh-emacs-enable-notifications t
  "Notify when a submitted run finishes or an interaction needs attention.
Posts a desktop notification when a run ends, and when an ask-question or
approval request arrives while its chat is not visible."
  :type 'boolean
  :group 'dsh-emacs-render)

(defcustom dsh-emacs-thinking-style 'expand
  "How live reasoning is rendered in the transcript.
`expand' (default) streams the reasoning body under the Think header and folds
it into a collapsible row when the answer text starts, like earlier releases.
`inline' renders dsh web's compact disclosure from the first delta: one
collapsed Think row whose preview advances with the latest completed
paragraph, expandable in place; the finished row keeps its position and is
updated rather than folded above the answer.  Every Think row starts collapsed;
open it in place to read the body, and that fold state survives updates."
  :type '(choice (const :tag "Expanded live body" expand)
                 (const :tag "Inline collapsed row" inline))
  :group 'dsh-emacs-render)

(defcustom dsh-emacs-thinking-preview-max 48
  "Maximum display width (columns) of the thinking-block first-line preview;
anything longer is truncated with \"...\".  Set to 0 to disable the preview
(the collapsed row then shows only the icon + Think)."
  :type 'integer
  :group 'dsh-emacs-render)

(defcustom dsh-emacs-tool-expand-by-default nil
  "Whether tool calls are expanded by default.
nil = collapsed by default (only tool title + summary are shown)."
  :type 'boolean
  :group 'dsh-emacs-render)

(defcustom dsh-emacs-show-commands t
  "Whether slash commands (/goal, /compact, ...) show in the transcript.
Command `command/run' + `command/done' events render as one flow node:
the run creates the muted label, the done restyles it with a short status
and folds the outcome text into a collapsible body below (collapsed by
default); the error kind turns the node red."
  :type 'boolean
  :group 'dsh-emacs-render)

(defcustom dsh-emacs-reply-footer-items '(copy fork usage)
  "Footer items for the latest completed text turn between human messages.
Items appear in this order; nil hides the row.  `copy' copies the selected
turn's last reply as original Markdown; `fork' branches through that reply.
Items stay together on the left, separated by dots.
`usage' sums that turn's reported tokens, including cache reads/writes;
`duration' optionally adds its server timestamps' elapsed time; the default
leaves elapsed time in the Completed summary.  Turns are not aggregated.
Existing rows are not automatically redrawn when this option changes."
  :type '(repeat (choice (const copy) (const fork)
                         (const usage) (const duration)))
  :group 'dsh-emacs)

(defcustom dsh-emacs-max-tool-result-chars 80
  "Maximum number of characters in the tool-result preview."
  :type 'integer
  :group 'dsh-emacs-render)

(defcustom dsh-emacs-tool-call-chars 100
  "Maximum number of characters in the tool-call arguments preview."
  :type 'integer
  :group 'dsh-emacs-render)

(defcustom dsh-emacs-tool-preview-lines 8
  "Maximum number of lines in the collapsed tool-call preview."
  :type 'integer
  :group 'dsh-emacs-render)

(defcustom dsh-emacs-max-buffer-size 200000
  "Maximum character count of the chat transcript buffer.
When the buffer exceeds this size old content is trimmed from the top, never
past the editable input area.  Trimming is deferred while loading an older
page, while a displayed window is not following new output, and when the
input area's position cannot be located, so the limit is soft during history
browsing.  Set to nil to disable trimming."
  :type '(choice integer (const nil))
  :group 'dsh-emacs-render)

(defcustom dsh-emacs-render-image-thumbnail-lines 4
  "Height of one image thumbnail in a user message, in text lines.
Every image attachment renders below the text inside a square box of this
size, in wrapping rows like dsh web's message gallery (64px tiles); a lone
image uses the same style as a gallery.  Aspect ratio is preserved, so a wide
picture fills the box's width and is shorter than its height.  RET or mouse-1
opens the original."
  :type 'integer
  :group 'dsh-emacs-render)

(defcustom dsh-emacs-fold-work-details t
  "Whether to use Web-style task and activity disclosures.
When a turn ends, thinking and tool cards between visible messages fold
into activity summaries.  Successful turns without mid-turn input also
fold their whole process, leaving any final answer visible.  Failed and
stopped turns keep their replies visible and their status row non-foldable.
Active turns stay open.  RET or click toggles a disclosure independently
of individual cards.  Set to nil and reopen the chat buffer for a flat
transcript without task or activity disclosures."
  :type 'boolean
  :group 'dsh-emacs-render)

(defcustom dsh-emacs-show-todos t
  "Whether to render the session's todo (plan) rows.
Each `todo_write' snapshot renders ONE row in the transcript (like a tool
card), showing the latest whole checklist; the rows accumulate in the order the
todo events arrive.  Set to nil to suppress todo rows entirely."
  :type 'boolean
  :group 'dsh-emacs-render)

(defcustom dsh-emacs-todo-title "Todo"
  "Title shown on each todo (plan) row header in the transcript."
  :type 'string
  :group 'dsh-emacs-render)

(defcustom dsh-emacs-todo-expand-by-default nil
  "Whether todo rows start expanded showing the checklist.
nil (default): each todo row starts collapsed showing only the header line
(icon + title + progress summary); RET or click expands to reveal the
checklist body.  Set to t to show the full checklist on first render."
  :type 'boolean
  :group 'dsh-emacs-render)

(defcustom dsh-emacs-todo-summary-only nil
  "Whether todo rows show only the progress summary.
When non-nil each row renders as a single passive line carrying the icon +
title and the task count/progress summary, with no per-item checklist body and
no fold toggle (RET/click are inert).  Set to nil to restore the interactive
collapsible checklist."
  :type 'boolean
  :group 'dsh-emacs-render)

;;; ---------------------------------------------------------------------------
;;; Tool variant / icon / summary
;;; ---------------------------------------------------------------------------

(defconst dsh-emacs--tool-variants
  '(("bash"       . "bash")
    ("pwsh"       . "bash")
    ("read"       . "read")
    ("web_fetch"  . "read")
    ("search"     . "search")
    ("web_search" . "search")
    ("grep"       . "search")
    ("glob"       . "search")
    ("write"      . "write")
    ("edit"       . "edit")
    ("run_code"   . "code")
    ("ask_user_question" . "question")
    ("create_goal" . "goal")
    ("get_goal"   . "goal")
    ("update_goal" . "goal")
    ("cordis_package_inspect" . "read")
    ("cordis_runtime_inspect" . "read")
    ("cordis_run" . "others")
    ("cordis_stop" . "others")
    ("cordis_undefine" . "others"))
  "Tool name -> variant mapping.
The `goal' variant has no icon-table entry: `dsh-emacs-render--tool-variant'
draws it with the Composer Goal Row's dartboard instead.")

(defconst dsh-emacs--tool-name-icon-keys
  '(("web_search" . "web"))
  "Tool name -> icon-key override, consulted before the variant table.
Tools listed here deviate from their variant's default icon, mirroring dsh
web's keyed toolviews (WebRow): web_search uses the meridian-globe family
(`dsh-emacs--tool-icon-svgs' \"web\") while local grep/glob keep the
magnifier family.")

(defconst dsh-emacs--tool-icon-svgs
  ;; Each SVG template is the exact dsh-web icon (VARIANT_ICONS), with a
  ;; "__C__" placeholder for the fill color.  Path data was extracted from
  ;; dsh-web's compiled icon components (IconApiOutline14, IconBrowseOutline16,
  ;; IconSearchOutline16, IconEditOutline16, IconCodeOutline16, IconSparkle16).
  '(("bash" . "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 14 14\" fill=\"none\"><path transform=\"translate(0.6689 1.073)\" d=\"M11.4818 5.57813C11.4818 4.45301 11.4807 3.66237 11.4075 3.05908C11.3359 2.46953 11.2024 2.13852 10.9939 1.89441C10.9247 1.81341 10.8493 1.73801 10.7683 1.66882C10.5242 1.46033 10.1932 1.32686 9.60364 1.25525C9.00034 1.18198 8.20974 1.18091 7.0846 1.18091L5.57813 1.18091C4.45301 1.18091 3.66238 1.18198 3.05908 1.25525C2.46953 1.32686 2.13852 1.46033 1.89441 1.66882C1.81341 1.73801 1.73801 1.81341 1.66882 1.89441C1.46033 2.13852 1.32686 2.46953 1.25525 3.05908C1.18198 3.66238 1.18091 4.45301 1.18091 5.57813L1.18091 6.2771C1.18091 7.40218 1.18197 8.19288 1.25525 8.79614C1.32687 9.38553 1.46036 9.71674 1.66882 9.96082C1.73797 10.0417 1.81347 10.1173 1.89441 10.1864C2.13851 10.3948 2.46965 10.5275 3.05908 10.5991C3.66238 10.6724 4.45298 10.6735 5.57813 10.6735L7.0846 10.6735C8.20977 10.6735 9.00033 10.6724 9.60364 10.5991C10.1931 10.5275 10.5242 10.3948 10.7683 10.1864C10.8493 10.1173 10.9247 10.0417 10.9939 9.96082C11.2024 9.71674 11.3358 9.38553 11.4075 8.79614C11.4808 8.19288 11.4818 7.40218 11.4818 6.2771L11.4818 5.57813ZM12.6627 6.2771C12.6627 7.37222 12.6637 8.247 12.5798 8.93799C12.4942 9.64284 12.3133 10.2359 11.8928 10.7282C11.7834 10.8562 11.6637 10.9751 11.5356 11.0845C11.0434 11.5049 10.4511 11.6867 9.74634 11.7723C9.05525 11.8563 8.17999 11.8552 7.0846 11.8552L5.57813 11.8552C4.48273 11.8552 3.60747 11.8563 2.91638 11.7723C2.21157 11.6867 1.61933 11.5049 1.12708 11.0845C0.99901 10.9751 0.879281 10.8562 0.769898 10.7282C0.349454 10.2359 0.168506 9.64284 0.0828864 8.93799C-0.00101964 8.247 4.88512e-07 7.37222 6.47206e-07 6.2771L6.47206e-07 5.57813C6.47206e-07 4.48273 -0.00106163 3.60747 0.0828864 2.91638C0.168502 2.21168 0.349594 1.61928 0.769898 1.12708C0.879302 0.998981 0.998981 0.879302 1.12708 0.769898C1.61928 0.349594 2.21168 0.168502 2.91638 0.0828864C3.60747 -0.00106163 4.48273 6.47206e-07 5.57813 6.47206e-07L7.0846 6.47206e-07C8.17999 6.47206e-07 9.05525 -0.00106163 9.74634 0.0828864C10.451 0.168505 11.0434 0.349587 11.5356 0.769898C11.6637 0.879302 11.7834 0.998981 11.8928 1.12708C12.3131 1.61928 12.4942 2.21169 12.5798 2.91638C12.6638 3.60747 12.6627 4.48273 12.6627 5.57813L12.6627 6.2771Z\" fill=\"__C__\" stroke=\"none\"/><path transform=\"translate(0.6689 1.073)\" d=\"M6.02607 5.50955L6.44306 5.9274L3.84284 8.52762L3.425 8.11063L3.00715 7.69278L4.77253 5.9274L3.00715 4.16202L3.84284 3.32633L6.02607 5.50955Z\" fill=\"__C__\" stroke=\"none\"/><path transform=\"translate(0.6689 1.073)\" d=\"M9.23789 7.35397L9.23789 8.53488L6.96238 8.53488L6.96238 7.35397L9.23789 7.35397Z\" fill=\"__C__\" stroke=\"none\"/></svg>")
    ("read" . "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 16 16\" fill=\"none\"><path d=\"M11.2426 4.80473V6.10551H4.75819V4.80473H11.2426Z\" fill=\"__C__\" stroke=\"none\"/><path d=\"M9.40858 7.84478V9.14557H4.75819V7.84478H9.40858Z\" fill=\"__C__\" stroke=\"none\"/><path d=\"M9.23438 0.546389C10.1941 0.546389 10.9683 0.544914 11.5859 0.611819C12.2161 0.680096 12.7634 0.825745 13.2393 1.17139C13.5172 1.3733 13.7619 1.61812 13.9639 1.896C14.3096 2.37183 14.4551 2.91922 14.5234 3.54932C14.5903 4.16686 14.5889 4.94133 14.5889 5.90088V10.0981C14.5889 11.0576 14.5903 11.8321 14.5234 12.4497C14.4552 13.0798 14.3094 13.6272 13.9639 14.103C13.7619 14.381 13.5172 14.6257 13.2393 14.8276C12.7633 15.1734 12.2163 15.3189 11.5859 15.3872C10.9683 15.4541 10.1942 15.4536 9.23438 15.4536H6.76563C5.80591 15.4536 5.03168 15.4541 4.41407 15.3872C3.78385 15.3189 3.23665 15.1734 2.76074 14.8276C2.48291 14.6257 2.23802 14.3809 2.03614 14.103C1.69066 13.6272 1.54483 13.0798 1.47657 12.4497C1.40973 11.8321 1.41114 11.0576 1.41114 10.0981V5.90088C1.41113 4.94132 1.40966 4.16686 1.47657 3.54932C1.54488 2.91921 1.69042 2.37184 2.03614 1.896C2.2381 1.61807 2.4828 1.37333 2.76074 1.17139C3.23665 0.825682 3.78386 0.680109 4.41407 0.611819C5.03168 0.544905 5.80591 0.546389 6.76563 0.546389H9.23438ZM6.76563 1.896C5.77586 1.896 5.0876 1.89738 4.55957 1.95459C4.0443 2.01043 3.76214 2.11349 3.55469 2.26416C3.39135 2.38284 3.24761 2.52662 3.12891 2.68994C2.97821 2.89736 2.8752 3.17967 2.81934 3.69483C2.76214 4.22279 2.76075 4.91131 2.76074 5.90088V10.0981C2.76074 11.0876 2.76221 11.7762 2.81934 12.3042C2.87516 12.8194 2.97829 13.1026 3.12891 13.3101C3.24754 13.4733 3.39147 13.6172 3.55469 13.7358C3.76213 13.8865 4.04438 13.9896 4.55957 14.0454C5.0876 14.1026 5.77586 14.103 6.76563 14.103H9.23438C10.2242 14.103 10.9124 14.1026 11.4404 14.0454C11.9556 13.9896 12.2379 13.8865 12.4453 13.7358C12.6086 13.6172 12.7525 13.4733 12.8711 13.3101C13.0217 13.1026 13.1248 12.8195 13.1807 12.3042C13.2378 11.7762 13.2393 11.0876 13.2393 10.0981V5.90088C13.2393 4.91131 13.2379 4.22279 13.1807 3.69483C13.1248 3.17969 13.0218 2.89736 12.8711 2.68994C12.7524 2.52667 12.6086 2.38281 12.4453 2.26416C12.2379 2.11355 11.9556 2.01041 11.4404 1.95459C10.9124 1.8974 10.2241 1.896 9.23438 1.896H6.76563Z\" fill=\"__C__\" stroke=\"none\"/></svg>")
    ("search" . "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 16 16\" fill=\"none\"><path d=\"M11.894845 6.647401C11.894845 3.725463 9.534486 1.356779 6.623219 1.35657C3.711786 1.35657 1.351635 3.725338 1.351635 6.647401C1.351843 9.569296 3.711911 11.938273 6.623219 11.938273C9.534361 11.938064 11.894637 9.569171 11.894845 6.647401ZM13.245462 6.647401C13.245254 10.317935 10.280401 13.293613 6.623219 13.293821C2.965871 13.293821 0.000204 10.31806 0 6.647401C0 2.976574 2.965746 0 6.623219 0C10.280526 0.000205 13.245462 2.9767 13.245462 6.647401Z\" fill=\"__C__\" stroke=\"none\"/><path d=\"M16.000417 15.041079L15.044449 16.000433L11.530434 12.473588L12.486298 11.514234L16.000417 15.041079Z\" fill=\"__C__\" stroke=\"none\"/></svg>")
    ("web" . "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 14 14\" fill=\"none\"><path fill-rule=\"evenodd\" clip-rule=\"evenodd\" d=\"M7.00018 0.353516C10.6708 0.353535 13.6468 3.32958 13.6469 7.00018C13.6468 10.6708 10.6708 13.6468 7.00018 13.6469C3.32957 13.6468 0.353535 10.6708 0.353516 7.00018C0.353535 3.32957 3.32957 0.353531 7.00018 0.353516ZM5.44643 7.59661C5.49463 8.97506 5.70762 10.191 6.02136 11.0793C6.20141 11.5891 6.40328 11.9585 6.59898 12.1889C6.79501 12.4196 6.93213 12.454 7.00018 12.454C7.06822 12.454 7.20533 12.4197 7.40138 12.1889C7.59708 11.9585 7.79895 11.589 7.979 11.0793C8.29274 10.191 8.50574 8.97506 8.55394 7.59661H5.44643ZM1.57861 7.59661C1.80785 9.70467 3.2386 11.4509 5.1715 12.1388C5.07135 11.9317 4.97972 11.7098 4.89746 11.477C4.53084 10.4391 4.30224 9.0828 4.25357 7.59661H1.57861ZM9.74679 7.59661C9.69813 9.0828 9.46952 10.4391 9.1029 11.477C9.0206 11.7099 8.92818 11.9316 8.82797 12.1388C10.7613 11.4511 12.1925 9.70496 12.4218 7.59661H9.74679ZM5.1706 1.8616C3.23814 2.54963 1.80876 4.29604 1.5795 6.40376H4.25357C4.30224 4.91756 4.53083 3.56129 4.89746 2.5234C4.97968 2.29066 5.07051 2.0686 5.1706 1.8616ZM7.00018 1.54637C6.93213 1.54638 6.79503 1.5807 6.59898 1.81145C6.40332 2.04177 6.20139 2.41058 6.02136 2.92012C5.70754 3.80851 5.49461 5.02499 5.44643 6.40376H8.55394C8.50575 5.025 8.29282 3.80851 7.979 2.92012C7.79898 2.41059 7.59705 2.04177 7.40138 1.81145C7.20531 1.58067 7.06823 1.54637 7.00018 1.54637ZM8.82887 1.8616C8.92902 2.0687 9.02064 2.29053 9.1029 2.5234C9.46953 3.56129 9.69812 4.91756 9.74679 6.40376H12.4209C12.1916 4.29575 10.7618 2.54943 8.82887 1.8616Z\" fill=\"__C__\" stroke=\"none\"/></svg>")
    ("write" . "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 16 16\" fill=\"none\"><path d=\"M9.94076 1.34942C10.7047 0.90231 11.6503 0.902415 12.4143 1.34942C12.7061 1.52015 12.9688 1.79118 13.3104 2.13284C13.6521 2.47448 13.9231 2.73721 14.0939 3.02894C14.5408 3.79294 14.5409 4.73856 14.0939 5.50251C13.9231 5.79415 13.652 6.05704 13.3104 6.39861L6.65932 13.0497C6.28068 13.4284 6.00695 13.7108 5.66543 13.9097C5.32391 14.1085 4.94315 14.2074 4.42705 14.3498L3.24394 14.6761C2.77527 14.8054 2.34538 14.9262 2.00131 14.9684C1.65196 15.0112 1.17964 15.0013 0.810764 14.6325C0.441921 14.2637 0.432107 13.7913 0.47486 13.442C0.517035 13.0979 0.6379 12.668 0.767181 12.1993L1.09352 11.0162C1.23588 10.5001 1.33481 10.1193 1.5336 9.77784C1.7325 9.43632 2.0149 9.1626 2.39355 8.78395L9.04466 2.13284C9.38625 1.79126 9.64911 1.52016 9.94076 1.34942ZM15.5427 14.8398H7.55223L8.96707 13.425H15.5427V14.8398ZM3.39382 9.78422C2.965 10.213 2.84244 10.3436 2.75709 10.49C2.67183 10.6366 2.61862 10.8079 2.45733 11.3925L2.13099 12.5756C2.00183 13.0439 1.92194 13.3419 1.88863 13.5536C2.10041 13.5204 2.39872 13.4416 2.86764 13.3123L4.05075 12.9859C4.63544 12.8246 4.80669 12.7715 4.95323 12.6862C5.09968 12.6008 5.23022 12.4783 5.65905 12.0494L10.721 6.98644L8.45577 4.72121L3.39382 9.78422ZM11.7 2.57079C11.3774 2.38198 10.9777 2.38198 10.6551 2.57079C10.5602 2.62647 10.4487 2.72931 10.0449 3.13311L9.45604 3.72094L11.7213 5.98617L12.3102 5.39833C12.7139 4.99457 12.8168 4.88307 12.8725 4.78818C13.0613 4.46561 13.0612 4.06585 12.8725 3.74326C12.8169 3.64827 12.7146 3.53752 12.3102 3.13311C11.9057 2.72863 11.795 2.6264 11.7 2.57079Z\" fill=\"__C__\" stroke=\"none\"/></svg>")
    ("edit" . "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 16 16\" fill=\"none\"><path d=\"M9.94076 1.34942C10.7047 0.90231 11.6503 0.902415 12.4143 1.34942C12.7061 1.52015 12.9688 1.79118 13.3104 2.13284C13.6521 2.47448 13.9231 2.73721 14.0939 3.02894C14.5408 3.79294 14.5409 4.73856 14.0939 5.50251C13.9231 5.79415 13.652 6.05704 13.3104 6.39861L6.65932 13.0497C6.28068 13.4284 6.00695 13.7108 5.66543 13.9097C5.32391 14.1085 4.94315 14.2074 4.42705 14.3498L3.24394 14.6761C2.77527 14.8054 2.34538 14.9262 2.00131 14.9684C1.65196 15.0112 1.17964 15.0013 0.810764 14.6325C0.441921 14.2637 0.432107 13.7913 0.47486 13.442C0.517035 13.0979 0.6379 12.668 0.767181 12.1993L1.09352 11.0162C1.23588 10.5001 1.33481 10.1193 1.5336 9.77784C1.7325 9.43632 2.0149 9.1626 2.39355 8.78395L9.04466 2.13284C9.38625 1.79126 9.64911 1.52016 9.94076 1.34942ZM15.5427 14.8398H7.55223L8.96707 13.425H15.5427V14.8398ZM3.39382 9.78422C2.965 10.213 2.84244 10.3436 2.75709 10.49C2.67183 10.6366 2.61862 10.8079 2.45733 11.3925L2.13099 12.5756C2.00183 13.0439 1.92194 13.3419 1.88863 13.5536C2.10041 13.5204 2.39872 13.4416 2.86764 13.3123L4.05075 12.9859C4.63544 12.8246 4.80669 12.7715 4.95323 12.6862C5.09968 12.6008 5.23022 12.4783 5.65905 12.0494L10.721 6.98644L8.45577 4.72121L3.39382 9.78422ZM11.7 2.57079C11.3774 2.38198 10.9777 2.38198 10.6551 2.57079C10.5602 2.62647 10.4487 2.72931 10.0449 3.13311L9.45604 3.72094L11.7213 5.98617L12.3102 5.39833C12.7139 4.99457 12.8168 4.88307 12.8725 4.78818C13.0613 4.46561 13.0612 4.06585 12.8725 3.74326C12.8169 3.64827 12.7146 3.53752 12.3102 3.13311C11.9057 2.72863 11.795 2.6264 11.7 2.57079Z\" fill=\"__C__\" stroke=\"none\"/></svg>")
    ("code" . "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 16 16\" fill=\"none\"><path d=\"M12.3368 1.53569L11.931 4.43172H14.8086V5.79673H11.7404L11.1962 9.67859H14.2839V11.0436H11.0056L10.4994 14.6529L9.14873 14.4643L9.62731 11.0436H5.75876L5.25252 14.6529L3.90186 14.4643L4.38043 11.0436H1.69141V9.67859H4.57104L5.11417 5.79673H2.21609V4.43172H5.30581L5.73724 1.34713L7.08995 1.53569L6.68414 4.43172H10.5527L10.9841 1.34713L12.3368 1.53569ZM5.94937 9.67859H9.81791L10.361 5.79673H6.49353L5.94937 9.67859Z\" fill=\"__C__\" stroke=\"none\"/></svg>")
    ("command" . "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 16 16\" fill=\"none\"><path d=\"M9.64572 1.0455C9.76513 0.755118 10.0095 0.530578 10.309 0.437078C10.6086 0.343578 10.9369 0.394798 11.1939 0.575858L11.2012 0.581418C11.3182 0.661738 11.4221 0.760918 11.5034 0.8755C11.6954 1.14086 11.8542 1.4732 12.0085 1.8645C12.3203 2.6551 12.5387 3.65868 12.7963 5.00636L13.1411 6.51662C13.3881 6.97662 13.2748 7.53122 12.8678 7.86842C12.4607 8.20542 11.9025 8.19562 11.5073 7.84522C11.475 7.81655 11.4443 7.78658 11.4152 7.75542C11.4172 8.25776 11.3912 8.75092 11.3373 9.22898C11.2168 10.2971 11.0096 11.2154 10.7187 11.9567C10.5838 12.3118 10.3567 12.6263 10.0195 12.8129C9.92472 12.8645 9.82446 12.9061 9.72037 12.9368C9.82774 13.3274 9.86604 13.7345 9.83316 14.1389C9.80302 14.5069 9.62146 14.8444 9.32762 15.0619C9.03356 15.2793 8.65482 15.3692 8.27122 15.2454C7.87092 15.116 7.52282 14.872 7.26235 14.5431C6.89096 14.0741 6.55986 13.2548 6.16811 11.9501C5.80842 10.7459 5.40551 9.12869 4.97117 7.10983C4.86597 6.62643 4.98747 6.12163 5.29587 5.74463C5.60427 5.36763 6.06447 5.16503 6.53547 5.19483C7.22692 5.23743 7.92050 5.30787 8.60580 5.40420C8.62320 5.31802 8.64380 5.23258 8.66757 5.14810C8.69923 5.08838 8.71202 5.02050 8.70402 4.95382C8.68602 4.79682 8.55462 4.67382 8.41242 4.58502C8.29972 4.51512 8.17252 4.44762 8.03562 4.39882C7.76116 4.30336 7.57267 4.01694 7.56703 3.73038C7.56103 3.41998 7.68723 3.12158 7.92803 2.91498C8.14663 2.72838 8.43559 2.64336 8.71785 2.68403C9.14985 2.74463 9.48305 2.83943 9.64572 1.0455ZM11.9092 9.31463C11.8775 9.97603 11.6655 10.5722 11.3551 11.0817C11.1287 11.4805 10.8322 11.8266 10.4862 12.0999C10.3972 12.1841 10.3009 12.2605 10.1987 12.328C10.5802 13.5469 10.8160 14.1493 10.9275 14.1975C11.4897 14.4287 12.0083 14.0268 12.0416 13.4145C12.0657 12.9633 11.9724 12.3789 11.7989 11.7176C11.7692 11.6139 11.7377 11.5103 11.7043 11.4070C12.0070 11.0933 12.2912 10.7631 12.4902 10.3871C12.7589 9.87770 12.8951 9.32482 12.8930 8.76790C12.7832 8.96782 12.6543 9.15691 12.5087 9.32210C12.3467 9.51423 12.1243 9.65222 11.9092 9.31463Z\" fill=\"__C__\" stroke=\"none\"/></svg>")
    ("question" . "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 14 14\" fill=\"none\"><path d=\"M12.5757 7.00012C12.5757 3.92085 10.0794 1.42463 7.00012 1.42456C3.9208 1.42456 1.42456 3.9208 1.42456 7.00012C1.42463 10.0794 3.92085 12.5757 7.00012 12.5757C10.0793 12.5756 12.5756 10.0793 12.5757 7.00012ZM13.8002 7.00012C13.8001 10.7559 10.7559 13.8001 7.00012 13.8002C3.2443 13.8002 0.199291 10.7559 0.199219 7.00012C0.199219 3.24426 3.24426 0.199219 7.00012 0.199219C10.7559 0.199291 13.8002 3.2443 13.8002 7.00012Z\" fill=\"__C__\" stroke=\"none\"/><path d=\"M6.18042 8.68184C6.18043 8.09153 6.32893 7.34655 6.92127 6.8481C7.28566 6.54148 7.76104 6.27318 8.0022 6.10811C8.28964 5.91137 8.42234 5.76562 8.48328 5.58944C8.57774 5.31609 8.53121 5.00904 8.34912 4.76741C8.17409 4.53522 7.83879 4.32222 7.28186 4.32222C5.99668 4.32225 5.46969 5.11832 5.46949 5.78939H4.24414C4.24436 4.39942 5.36327 3.09691 7.28186 3.09688C8.17773 3.09688 8.89489 3.45606 9.32752 4.02999C9.75287 4.59438 9.86938 5.32775 9.64026 5.99019C9.44847 6.5444 9.04722 6.87743 8.69434 7.11898C8.29506 7.39226 8.02318 7.52192 7.70996 7.78548C7.51943 7.94582 7.40577 8.24899 7.40577 8.68184V8.75533H6.18042V8.68184Z\" fill=\"__C__\" stroke=\"none\"/><path d=\"M7.39455 9.44026V10.8109H6.16921V9.44026H7.39455Z\" fill=\"__C__\" stroke=\"none\"/></svg>")
    ("others" . "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 16 16\" fill=\"none\"><path d=\"M6.1 3.1Q6.6 7.8 11.3 8.3Q6.6 8.8 6.1 13.5Q5.6 8.8 0.9 8.3Q5.6 7.8 6.1 3.1Z\" fill=\"__C__\" stroke=\"none\"/><path d=\"M11.9 1Q12.2 3.7 14.9 4Q12.2 4.3 11.9 7Q11.6 4.3 8.9 4Q11.6 3.7 11.9 1Z\" fill=\"__C__\" stroke=\"none\"/><path d=\"M12.5 9.4Q12.7 11.4 14.7 11.6Q12.7 11.8 12.5 13.8Q12.3 11.8 10.3 11.6Q12.3 11.4 12.5 9.4Z\" fill=\"__C__\" stroke=\"none\"/></svg>"))
  "Variant -> dsh-web SVG icon template, with a \"__C__\" fill placeholder.
Graphical Emacs renders these via `create-image'; displays without SVG fall
back to the single dot in `dsh-emacs-render--simple-icon'.  The \"web\" key
\(meridian globe, IconGlobeOutline14) is selected for web_search through
`dsh-emacs--tool-name-icon-keys', mirroring dsh web's WebRow.")

(defconst dsh-emacs--think-icon-svg-template
  "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 14 14\" fill=\"none\"><path d=\"M7.06431 5.93342C7.68763 5.93342 8.19307 6.43904 8.19322 7.06233C8.19322 7.68573 7.68772 8.19123 7.06431 8.19123C6.44099 8.19113 5.9354 7.68567 5.9354 7.06233C5.93555 6.43911 6.44108 5.93353 7.06431 5.93342Z\" fill=\"__C__\" stroke=\"none\"/><path fill-rule=\"evenodd\" clip-rule=\"evenodd\" d=\"M8.6815 0.963693C10.1169 0.447019 11.6266 0.374829 12.5633 1.31135C13.5 2.24805 13.4277 3.75776 12.911 5.19319C12.7126 5.74431 12.4386 6.31796 12.0965 6.89729C12.4969 7.54638 12.8141 8.19018 13.036 8.80647C13.5527 10.2419 13.6251 11.7516 12.6883 12.6883C11.7516 13.625 10.242 13.5527 8.8065 13.036C8.19022 12.8141 7.54641 12.4969 6.89732 12.0965C6.31797 12.4386 5.74435 12.7125 5.19322 12.911C3.75777 13.4276 2.2481 13.5 1.31138 12.5633C0.374859 11.6266 0.447049 10.1168 0.963724 8.68147C1.17185 8.10338 1.46321 7.50063 1.82896 6.8924C1.52182 6.35711 1.27235 5.82825 1.08872 5.31819C0.572068 3.88278 0.499714 2.37306 1.43638 1.43635C2.37308 0.499655 3.8828 0.572044 5.31822 1.08869C5.82828 1.27232 6.35715 1.5218 6.89243 1.82893C7.50066 1.46318 8.10341 1.17181 8.6815 0.963693ZM11.3573 8.01154C10.9083 8.62253 10.3901 9.22873 9.80943 9.8094C9.22877 10.3901 8.62255 10.9083 8.01158 11.3572C8.4257 11.5841 8.8287 11.7688 9.21275 11.9071C10.5456 12.3868 11.4246 12.2547 11.8397 11.8397C12.2548 11.4246 12.3869 10.5456 11.9071 9.21272C11.7688 8.82866 11.5841 8.42568 11.3573 8.01154ZM2.56529 8.02912C2.37344 8.39322 2.21495 8.74796 2.09263 9.08772C1.61291 10.4204 1.74512 11.2995 2.16001 11.7147C2.57505 12.1297 3.45415 12.2618 4.78697 11.7821C5.11057 11.6656 5.44786 11.5164 5.7938 11.3367C5.249 10.9223 4.70922 10.4533 4.19029 9.9344C3.57578 9.31987 3.03169 8.67633 2.56529 8.02912ZM6.90708 3.2469C6.24065 3.70479 5.5646 4.26321 4.91392 4.91389C4.26325 5.56456 3.70482 6.24063 3.24693 6.90705C3.72674 7.63325 4.32777 8.37459 5.03892 9.08576C5.64943 9.69627 6.28183 10.2265 6.90806 10.6678C7.59368 10.2025 8.2908 9.63076 8.96079 8.96076C9.6308 8.29075 10.2025 7.59366 10.6678 6.90803C10.2265 6.2818 9.69631 5.6494 9.08579 5.03889C8.37462 4.32773 7.63328 3.72672 6.90708 3.2469ZM11.7147 2.15998C11.2996 1.74509 10.4204 1.61288 9.08775 2.0926C8.74835 2.21479 8.39382 2.37271 8.03013 2.56428C8.67728 3.03065 9.31995 3.5758 9.93443 4.19026C10.4534 4.7092 10.9223 5.24896 11.3368 5.79377C11.5164 5.44785 11.6656 5.11052 11.7821 4.78694C12.2618 3.45416 12.1297 2.57502 11.7147 2.15998ZM4.91197 2.2176C3.57922 1.73788 2.70004 1.86995 2.28501 2.28498C1.87001 2.70003 1.73791 3.5792 2.21763 4.91194C2.31709 5.18822 2.44112 5.47427 2.58677 5.7674C3.01931 5.1887 3.51474 4.6158 4.06529 4.06526C4.61584 3.5147 5.18872 3.01928 5.76743 2.58674C5.47431 2.4411 5.18824 2.31706 4.91197 2.2176Z\" fill=\"__C__\" stroke=\"none\"/></svg>"
  "dsh web's IconThinkOutline14 (the ReasoningRow sparkle icon) as an SVG
template with a \"__C__\" fill placeholder.  Graphical Emacs renders it via
`create-image'; terminal Emacs falls back to the \"✶\" glyph.")

(defcustom dsh-emacs-tool-titles
  '(("pwsh" . "PowerShell")
    ("present" . "Present files")
    ("ask_user_question" . "Ask question")
    ("create_goal" . "Create goal")
    ("get_goal" . "View goal")
    ("update_goal" . "Update goal")
    ("job_output" . "Job Output")
    ("job_list" . "Jobs")
    ("job_kill" . "Kill Job"))
  "Alist of tool name -> display title overrides.
Tools not listed here show a humanized name (\"grep\" -> \"Grep\",
\"web_search\" -> \"Web Search\") while keeping their variant icon, so
distinct tools never share a display name just because they share an
icon.  Add your own entries to curate custom tool names."
  :type '(alist :key-type string :value-type string)
  :group 'dsh-emacs-render)

;;; ---------------------------------------------------------------------------
;;; Tool classification and summary
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-render--simple-icon (face)
  "Return the simplified event-row glyph: one dot carrying FACE."
  (propertize "●" 'face face))

(defun dsh-emacs-render--row-label-face (accent)
  "Return the face for an event-row label.
In the `simple' style the leading dot is the only colored element, so the
label uses `dsh-emacs-event-row-face' with bold weight; otherwise return
ACCENT."
  (if (eq dsh-emacs-render-style 'simple)
      '(bold dsh-emacs-event-row-face)
    accent))

(defun dsh-emacs-render--row-chrome-face (face)
  "Return FACE for event-row header chrome.
In the `simple' style the leading dot is the only colored element, so the
header row uses the muted `dsh-emacs-event-row-face'."
  (if (eq dsh-emacs-render-style 'simple)
      'dsh-emacs-event-row-face
    face))

(defun dsh-emacs-render--tool-icon-svg (variant color &optional tool-name)
  "Return the dsh-web SVG icon for VARIANT, filled with COLOR.
TOOL-NAME selects a per-tool icon override (`dsh-emacs--tool-name-icon-keys')
when the tool deviates from its variant's default icon (web_search uses the
meridian globe; grep/glob keep the magnifier family)."
  (let* ((icon-key (or (and tool-name
                            (cdr (assoc tool-name dsh-emacs--tool-name-icon-keys)))
                       variant))
         (template (cdr (assoc icon-key dsh-emacs--tool-icon-svgs))))
    (when template
      (replace-regexp-in-string "__C__" color template t t))))

(defun dsh-emacs-render--tool-icon (variant &optional tool-name)
  "Return VARIANT's icon as a display string.
TOOL-NAME picks a per-tool icon override (`dsh-emacs--tool-name-icon-keys').
With `dsh-emacs-render-style' `simple', or on a display that cannot draw
SVG, this is one tool-accent dot.  Otherwise it is the real dsh-web SVG image
for the variant."
  (if (or (eq dsh-emacs-render-style 'simple)
          (not (and (display-graphic-p)
                    (fboundp 'image-type-available-p)
                    (image-type-available-p 'svg))))
      (dsh-emacs-render--simple-icon 'dsh-emacs-tool-icon-face)
    (condition-case nil
        (let* ((fg (face-foreground 'dsh-emacs-tool-icon-face nil t))
               (color (if (and fg (not (equal fg "unspecified")))
                          fg
                        "#a78bfa")))
          (propertize "●"
                      'face 'dsh-emacs-tool-icon-face
                      'display
                      (create-image
                       (dsh-emacs-render--tool-icon-svg variant color tool-name)
                       'svg t :ascent 'center :height 1.0)))
      (error (dsh-emacs-render--simple-icon 'dsh-emacs-tool-icon-face)))))

(defun dsh-emacs-render--event-icon (state)
  "Return a compact status dot for an exceptional execution STATE.
Like dsh web's StateDot, the dot identifies status without suggesting a tool.
STATE is `retry', `error' or `idle'; the adjacent title supplies its meaning."
  (let* ((face (pcase state
                 ('retry 'dsh-emacs-running-face)
                 ('error 'dsh-emacs-error-face)
                 (_ 'dsh-emacs-timestamp-face)))
         (glyph (propertize "●" 'face face)))
    (if (and (display-graphic-p) (image-type-available-p 'svg))
        (let* ((foreground (face-foreground face nil t))
               ;; Emacs/X11 names such as red1 are not SVG/CSS colors.
               (rgb (and foreground (color-values foreground)))
               (color (if rgb
                          (apply #'format "#%02x%02x%02x"
                                 (mapcar (lambda (channel) (/ channel 257)) rgb))
                        "#808080")))
          (propertize
           glyph 'display
           (create-image
            (format (concat "<svg xmlns=\"http://www.w3.org/2000/svg\" "
                            "width=\"16\" height=\"16\" viewBox=\"0 0 16 16\">"
                            "<circle cx=\"8\" cy=\"8\" r=\"3\" fill=\"%s\"/></svg>")
                    color)
            'svg t :ascent 'center :height 1.0)))
      glyph)))

(defun dsh-emacs-render--think-icon-svg (color)
  "Return the dsh-web IconThinkOutline14 sparkle icon filled with COLOR."
  (replace-regexp-in-string "__C__" color dsh-emacs--think-icon-svg-template t t))

(defun dsh-emacs-render--think-icon ()
  "Return the Thinking row leading glyph as a display string.
With `dsh-emacs-render-style' `simple' this is one thinking-accent dot.
Otherwise, in graphical Emacs with SVG support it is the real dsh-web
IconThinkOutline14 sparkle, tinted with the thinking color (matching
`dsh-emacs-thinking-face'); without SVG it falls back to the \"✶\" glyph."
  (if (eq dsh-emacs-render-style 'simple)
      (dsh-emacs-render--simple-icon 'dsh-emacs-thinking-face)
    (if (and (display-graphic-p)
             (fboundp 'image-type-available-p)
             (image-type-available-p 'svg))
        (condition-case nil
            (let* ((fg (face-foreground 'dsh-emacs-thinking-face nil t))
                   (color (if (and fg (not (equal fg "unspecified")))
                              fg
                            "#b45f06")))
              (propertize "✶"
                          'display
                          (create-image
                           (dsh-emacs-render--think-icon-svg color)
                           'svg t :ascent 'center :height 1.0)))
          (error "✶"))
      "✶")))

(defconst dsh-emacs--todo-icon-svg-template
  "<svg width=\"14\" height=\"14\" viewBox=\"0 0 14 14\" fill=\"none\" xmlns=\"http://www.w3.org/2000/svg\"><path d=\"M13.3277 9.69629V10.976H7.28086V9.69629H13.3277Z\" fill=\"__C__\"/><path d=\"M13.3277 2.97256V4.25225H7.28086V2.97256H13.3277Z\" fill=\"__C__\"/><path d=\"M4.64512 10.336C4.64505 9.62755 4.07081 9.05322 3.3623 9.05322C2.65386 9.05329 2.07956 9.62759 2.07949 10.336C2.07949 11.0445 2.65382 11.6188 3.3623 11.6188C4.07085 11.6188 4.64512 11.0446 4.64512 10.336ZM5.92559 10.336C5.92559 11.7515 4.77777 12.8993 3.3623 12.8993C1.94689 12.8993 0.799805 11.7515 0.799805 10.336C0.799871 8.92066 1.94693 7.7736 3.3623 7.77354C4.77773 7.77354 5.92552 8.92062 5.92559 10.336Z\" fill=\"__C__\"/><path d=\"M4.64531 3.6123C4.6453 2.90382 4.07098 2.32949 3.3625 2.32949C2.65403 2.32951 2.0797 2.90383 2.07969 3.6123C2.07969 4.32079 2.65402 4.8951 3.3625 4.89512C4.07099 4.89512 4.64531 4.3208 4.64531 3.6123ZM5.925 3.6123C5.925 5.02772 4.77792 6.1748 3.3625 6.1748C1.9471 6.17479 0.8 5.02771 0.8 3.6123C0.800013 2.19691 1.9471 1.04982 3.3625 1.0498C4.77791 1.0498 5.92499 2.1969 5.925 3.6123Z\" fill=\"__C__\"/></svg>"
  "dsh web's plan/todo icon (a checklist: two rows + bullet marks) as an SVG
template with a \"__C__\" fill placeholder.  The color comes from the surrounding
line's face; graphical Emacs renders it via `create-image', terminal Emacs
falls back to a list glyph.")

(defun dsh-emacs-render--todo-icon-svg (color)
  "Return the dsh-web plan checklist icon filled with COLOR."
  (replace-regexp-in-string "__C__" color dsh-emacs--todo-icon-svg-template t t))

(defun dsh-emacs-render--todo-icon ()
  "Return the todo row leading glyph as a display string.
With `dsh-emacs-render-style' `simple' this is one tool-purple dot.
Otherwise, in graphical Emacs with SVG support it is the real dsh-web plan
checklist icon, tinted with the tool purple accent
\(`dsh-emacs-tool-icon-face'); it is distinct from the green row text.
Terminal Emacs without SVG falls back to the \"▤\" glyph carrying that same
face."
  (if (eq dsh-emacs-render-style 'simple)
      (dsh-emacs-render--simple-icon 'dsh-emacs-tool-icon-face)
    (let ((glyph (if (and (display-graphic-p)
                          (fboundp 'image-type-available-p)
                          (image-type-available-p 'svg))
                     (condition-case nil
                         (let* ((fg (face-foreground 'dsh-emacs-tool-icon-face nil t))
                                (color (if (and fg (not (equal fg "unspecified")))
                                           fg
                                         "#a78bfa")))
                           (propertize "▤"
                                       'display
                                       (create-image
                                        (dsh-emacs-render--todo-icon-svg color)
                                        'svg t :ascent 'center :height 1.0)))
                       (error "▤"))
                   "▤")))
      (propertize glyph 'face 'dsh-emacs-tool-icon-face))))

(defun dsh-emacs-render--goal-trigger-icon ()
  "Return the goal dartboard as a display string.
With `dsh-emacs-render-style' `simple' this is one goal-accent dot.
Otherwise it reuses the Composer Goal Row's dsh-web goal SVG
\(`dsh-emacs-composer--goal-icon') so a goal keeps one icon across the
composer, the transcript trigger notice and the goal tool cards; terminal
Emacs without SVG shows the row's `◎ ' text fallback."
  (if (eq dsh-emacs-render-style 'simple)
      (dsh-emacs-render--simple-icon 'dsh-emacs-composer-goal-face)
    (or (dsh-emacs-composer--goal-icon)
        (propertize "◎ " 'face 'dsh-emacs-composer-goal-face))))

(defconst dsh-emacs-render--turn-trigger-icon-svg-template
  (concat "<svg xmlns=\"http://www.w3.org/2000/svg\" "
          "width=\"14\" height=\"14\" viewBox=\"0 0 16 16\" "
          "fill=\"none\" stroke-width=\"1\">"
          "<path d=\"M4.74024 9.11029L1.82882 7.79865C1.75022 7.76323 "
          "1.75026 7.65161 1.82889 7.61626L12.9665 2.60943C13.0354 2.57846 "
          "13.1125 2.63213 13.1073 2.70749L12.3914 13.1388C12.3864 13.2117 "
          "12.3073 13.2548 12.2433 13.2194L6.12677 9.83657\" stroke=\"__C__\"/>"
          "<path d=\"M8.44336 11.0825L6.2832 13.2843C6.22048 13.3482 "
          "6.11182 13.3038 6.11182 13.2143V9.86772C6.11182 9.84165 6.122 "
          "9.8166 6.1402 9.79793L12.972 2.78748\" stroke=\"__C__\"/></svg>")
  "dsh web's `IconPaperPlaneOutline' trigger glyph with a \"__C__\" placeholder.
Web tints one source-family icon per trigger; the Emacs row keeps one
incoming-message glyph and names the family in its label, so a foreign
source never invents an identity it did not record.")

(defun dsh-emacs-render--turn-trigger-icon ()
  "Return the turn-trigger leading glyph as a display string.
With `dsh-emacs-render-style' `simple' this is one muted dot.
Otherwise it is dsh web's paper-plane trigger icon tinted from
`dsh-emacs-meta-face'; terminal Emacs without SVG falls back to the `➤'
glyph carrying that face."
  (if (eq dsh-emacs-render-style 'simple)
      (dsh-emacs-render--simple-icon 'dsh-emacs-meta-face)
    (let ((glyph (propertize "➤" 'face 'dsh-emacs-meta-face)))
      (if (and (display-graphic-p)
               (fboundp 'image-type-available-p)
               (image-type-available-p 'svg))
          (condition-case nil
              (let* ((fg (face-foreground 'dsh-emacs-meta-face nil t))
                     (color (if (and fg (not (equal fg "unspecified"))) fg
                              "#8b949e")))
                (propertize glyph
                            'display
                            (create-image
                             (replace-regexp-in-string
                              "__C__" color
                              dsh-emacs-render--turn-trigger-icon-svg-template
                              t t)
                             'svg t :ascent 'center :height 1.0)))
            (error glyph))
        glyph))))

(defun dsh-emacs-render--tool-variant (tool-name)
  "Return (VARIANT . ICON) for TOOL-NAME.
ICON is a display string: the real dsh-web SVG image where Emacs can draw
SVG, or one tool-accent dot otherwise.  A goal tool takes the dartboard dsh
web's `DetailsRow' keys off the `_goal' suffix instead of a variant icon."
  (let* ((variant (or (cdr (assoc tool-name dsh-emacs--tool-variants)) "others"))
         (icon (if (equal variant "goal")
                   (dsh-emacs-render--goal-trigger-icon)
                 (dsh-emacs-render--tool-icon variant tool-name))))
    (cons variant icon)))

(defun dsh-emacs-render--humanize-name (name)
  "Humanize TOOL-NAME for display: split on _/-, capitalize each word.
Returns \"Tool\" for empty or missing names."
  (if (or (null name) (string-empty-p name))
      "Tool"
    (mapconcat #'capitalize (split-string name "[_-]+" t) " ")))

(defun dsh-emacs-render--tool-header (tool-name variant args)
  "Return the (TITLE . SUMMARY) header pair for TOOL-NAME of VARIANT.
TITLE comes from `dsh-emacs-tool-titles'; otherwise a variant-less tool (dsh
web's `others', for example a plugin's `dev_*' tools) is titled \"Tool Call\"
with its wire name as the summary — `Tool Call · <tool name>'.  Its
arguments are deliberately NOT in the header: the expanded card already
carries them in its IN row, and repeating the raw JSON on the collapsed line
only crowds it.  Every other row keeps the humanized tool name — so grep /
glob / web_search share the search magnifier icon but show distinct titles —
and the summary chosen by `dsh-emacs-render--tool-summary'.
ARGS is the decoded `dsh-protocol-tool-arguments' view of the call."
  (let ((curated (cdr (assoc tool-name dsh-emacs-tool-titles))))
    (cond
     (curated (cons curated
                    (dsh-emacs-render--tool-summary tool-name args)))
     ((equal variant "others")
      (cons "Tool Call" tool-name))
     (t (cons (dsh-emacs-render--humanize-name tool-name)
              (dsh-emacs-render--tool-summary tool-name args))))))

(defun dsh-emacs-render--first-line (text)
  "First line of TEXT, trimmed."
  (let ((nl (string-match "\n" text)))
    (if nl (string-trim (substring text 0 nl)) (string-trim text))))

(defun dsh-emacs-render--trim (text limit)
  "Trim TEXT to LIMIT chars on one line, append \"…\" if cut."
  (let* ((one-line (replace-regexp-in-string "[ \t]+" " "
                                          (replace-regexp-in-string "[\n\r]+" " " text)))
         (one-line (string-trim one-line)))
    (if (> (length one-line) limit)
        (concat (substring one-line 0 limit) "…")
      one-line)))

(defun dsh-emacs-render--first-sentence (text)
  "Return the first sentence of TEXT, or nil.
A sentence ends at the first `.', `!', `?', Chinese `。' / `！' / `？', or a
newline.  The terminating punctuation is kept, newlines are flattened to a
space.  Empty/whitespace-only TEXT yields nil."
  (when (and (stringp text) (not (string-empty-p text)))
    (let* ((end (string-match "[.!?。！？\n]" text))
           (first (if end (substring text 0 (1+ end)) text))
           (first (replace-regexp-in-string "[\n\r]+" " " first))
           (first (string-trim first)))
      (and (not (string-empty-p first)) first))))

(defun dsh-emacs-render--thinking-live-preview (text)
  "Return the running preview for reasoning TEXT, or nil.
Mirrors dsh web: the first line of the latest paragraph completed so far, so
the collapsed row advances as the model thinks.  A tail paragraph without a
closing blank line is still in flight and contributes nothing; bold markers
(`**') are dropped and `dsh-emacs-thinking-preview-max' bounds the width."
  (let ((latest nil)
        ;; The last element is the still-streaming tail unless TEXT ends with
        ;; a blank line: `butlast' drops it, and a trailing empty element has
        ;; no first line to show anyway.  Splitting in one pass (instead of a
        ;; `string-match' loop) keeps this linear and independent of match data
        ;; that helpers such as `string-trim' may overwrite.
        (paragraphs (butlast (split-string
                              (replace-regexp-in-string "\r" "" text)
                              "\n\\(?:[ \t]*\n\\)+"))))
    (dolist (paragraph paragraphs)
      (let* ((line (car (split-string paragraph "\n")))
             (line (string-trim
                    (replace-regexp-in-string "\*\*" "" (or line "")))))
        (unless (string-empty-p line)
          (setq latest line))))
    (when (and latest (> dsh-emacs-thinking-preview-max 0))
      (truncate-string-to-width latest dsh-emacs-thinking-preview-max
                                nil nil "..."))))

(defun dsh-emacs-render--thinking-preview (text)
  "Return the collapse-time preview for reasoning TEXT.
The preview is the first sentence, truncated to `dsh-emacs-thinking-preview-max'
display columns with an ASCII \"...\" when it is too long (so a CJK-heavy
sentence is cut at the box width rather than overflowing).  Returns nil when
there is no previewable content."
  (let ((first (dsh-emacs-render--first-sentence text)))
    (when (and first (> dsh-emacs-thinking-preview-max 0))
      (truncate-string-to-width first dsh-emacs-thinking-preview-max nil nil "..."))))

(defun dsh-emacs-render--tool-summary (name args)
  "Format NAME's decoded ARGS as a one-line summary."
  (or (dsh-emacs-render--goal-call-summary name args)
      (let ((paths (dsh-protocol-tool-arguments-paths args))
            (summary (dsh-protocol-tool-arguments-summary args)))
        (if (and (equal name "present") paths)
            (mapconcat #'identity paths ", ")
          (when summary (dsh-emacs-render--first-line summary))))))

(defun dsh-emacs-render--tool-body-text (args)
  "Format decoded tool ARGS as the args section of a tool card body."
  (let ((parsed (dsh-protocol-tool-arguments-object args))
        (command (dsh-protocol-tool-arguments-command args)))
    (cond
     ((and (stringp command) (not (string-empty-p command)))
      (concat "$ " command))
     ((and parsed (listp parsed))
      (let ((json-encoding-pretty-print t))
        (json-encode parsed)))
     (t (or (dsh-protocol-tool-arguments-raw args) "")))))

(defun dsh-emacs-render--tool-result-preview (text)
  "Format TEXT as the one-line preview of a settled tool result.
The first line, capped at `dsh-emacs-max-tool-result-chars' chars, with a
trailing \" …\" when TEXT carried more lines.  Used as the collapsed row's
summary when the call's arguments yield none (a zero-argument tool), so the
row states its outcome instead of showing a bare title."
  (let* ((lines (split-string text "\n" t))
         (first (or (car lines) ""))
         (line (dsh-emacs-render--trim first dsh-emacs-max-tool-result-chars)))
    (concat line (when (> (length lines) 1) " …"))))

;;; ---------------------------------------------------------------------------
;;; content block extraction
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-render--text-from-content (content)
  "Concatenate text blocks from decoded CONTENT in display order."
  (mapconcat #'dsh-protocol-content-block-text
             (cl-remove-if-not
              (lambda (block)
                (equal (dsh-protocol-content-block-kind block) "text"))
              content)
             "\n"))

(defun dsh-emacs-render--reasoning-from-content (content)
  "Concatenate reasoning blocks from decoded CONTENT in display order."
  (mapconcat #'dsh-protocol-content-block-text
             (cl-remove-if-not
              (lambda (block)
                (equal (dsh-protocol-content-block-kind block) "reasoning"))
              content)
             "\n"))

(defun dsh-emacs-render--reconcile-inline-thinking (step content)
  "Update STEP's inline Think rows from final CONTENT in place.
Returns non-nil when the streamed rows cover every final non-empty reasoning
block one-to-one, so the rows can keep their positions; nil asks the caller to
fall back to the single folded row (a block was added or removed by the
correction)."
  (let ((blocks (cl-loop for block in content
                         for kind = (dsh-protocol-content-block-kind block)
                         for text = (dsh-protocol-content-block-text block)
                         when (and (equal kind "reasoning")
                                   (stringp text) (not (string-empty-p text)))
                         collect text))
        (regions (reverse (plist-get step :thinking-regions))))
    (when (and regions (= (length blocks) (length regions)))
      (cl-loop for text in blocks
               for region in regions
               do (dsh-emacs-render--render-thinking-block
                   (plist-get region :ns) (plist-get region :block-id)
                   text nil t))
      (plist-put step :reasoning (mapconcat #'identity blocks "\n"))
      t)))

;;; ---------------------------------------------------------------------------
;;; Timestamps
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-render--event-time (event)
  "HH:MM:SS string from event's epoch-ms `time' field, or nil."
  (let ((time (dsh-protocol-event-clock--from-alist event)))
    (when time
      (format-time-string "%H:%M:%S" (/ time 1000.0)))))

;;; ---------------------------------------------------------------------------
;;; Rendering primitives
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-render--make-namespace ()
  "Return the namespace string for fragments of the current session."
  (format "sess-%s" (or (and (boundp 'dsh-emacs--session-id) dsh-emacs--session-id) "global")))

(defun dsh-emacs-render--make-block-id (event)
  "Return a block-id string for the event (using seq)."
  (let ((seq (dsh-protocol-event-sequence--from-alist event)))
    (format "evt-%s" (or seq (random 999999)))))

(defun dsh-emacs-render--face-matches-prompt-p (face)
  "Return non-nil when FACE contains `dsh-emacs-input-prompt-face'."
  (cond
   ((eq face 'dsh-emacs-input-prompt-face) t)
   ((listp face) (memq 'dsh-emacs-input-prompt-face face))
   (t nil)))

(defun dsh-emacs-render--input-anchor-pos ()
  "Return the buffer position of the internal input prompt, or nil.
The anchor is the `❯ ' prompt of the editable input line.  It is always the
last `dsh-emacs-input-prompt-face' run in the buffer because every chat
message is inserted strictly above it."
  (let ((pos (point-max))
        (found nil))
    (while (and (not found) pos (> pos (point-min)))
      (setq pos (previous-single-property-change pos 'face nil (point-min)))
      (when pos
        (when (dsh-emacs-render--face-matches-prompt-p
               (get-text-property pos 'face))
          (setq found pos))))
    found))

(defun dsh-emacs-render--following-windows ()
  "Return windows currently following this buffer's draft input.
Capture this immediately before a stream edit so large writes cannot make
a following window look manually scrolled away.  No state survives the edit."
  (when-let* ((windows (get-buffer-window-list (current-buffer) nil t))
              (anchor (dsh-emacs-render--input-anchor-pos)))
    (cl-loop for window in windows
             when (and (window-live-p window)
                       (>= (window-point window) anchor)
                       (dsh-emacs-ui--window-at-bottom-p
                        window (window-point window)))
             collect window)))

;; Declared before their first reader: the FOLLOW-STREAM default argument
;; expression consults both for a pending batch, and a `defvar' must
;; precede its use for the byte-compiler to treat it as special.
(defvar-local dsh-emacs--streaming-assistant nil
  "Current assistant stream state, or nil.
The plist contains :key, :index, :start, :end, :event-id, :chunks and :timer.
:chunks retains all raw deltas in reverse order for final reconciliation.
:pending holds unpainted deltas; :timer coalesces insertion and Markdown
work every 50ms.  :markdown owns the incremental parser's scan markers.
The body between :start and :end contains the painted transcript.")

(defvar-local dsh-emacs--streaming-thinking nil
  "Current live reasoning/Think block stream state, or nil.
The plist contains :key, :index, :start, :end, :chunks, :all, :ns, :block-id and
:timer.  Pending deltas are collected in reverse order (…:chunks) and inserted
every 100ms; :all keeps every delta of the block for finalization.  Reasoning
deltas grow a raw body below the \"✶ Think\" header; when the block ends
(text resumes, a new block index or `assistant/message') the raw region is
replaced by the collapsible Think fragment.")

(defvar-local dsh-emacs--markdown-pending nil
  "Stream states awaiting interruptible Markdown formatting, in order.")

(defvar-local dsh-emacs--streamed-step nil
  "Record of what the live step has already put on screen, or nil.
Plist with :key (turn/step), :text (text committed into finished assistant
bodies), :text-regions (their stream states, so a divergent authoritative body can
drop them) and :reasoning (reasoning folded into Think fragments).  A step can
carry several protocol blocks, and each block owns its own transcript region;
the record lets the authoritative `assistant/message' render only what is
missing instead of rewriting blocks the user has already read.  :blocks lists
the indices that supplied content, including blocks that are no longer live,
so a delayed `block-end' cannot render them again.  :thinking-blocks keeps the
folded fragments' (NAMESPACE . BLOCK-ID) identities for repair or discard;
:thinking-regions retains their indexed stream states for later deltas.")

(defun dsh-emacs-render--step-record (key)
  "Return the live step's record for KEY, creating it when needed.
A new KEY (turn/step) starts a fresh record."
  (unless (equal (plist-get dsh-emacs--streamed-step :key) key)
    (setq dsh-emacs--streamed-step
          (list :key key :text "" :reasoning "" :text-regions nil
                :thinking-blocks nil :thinking-regions nil :blocks nil)))
  dsh-emacs--streamed-step)

(defun dsh-emacs-render--commit-text-segment (state)
  "Record STATE's streamed text as a body the user has already seen.
The body's region is kept so a divergent authoritative message can drop it."
  (let* ((step (dsh-emacs-render--step-record (plist-get state :key)))
         (seen (apply #'concat (reverse (plist-get state :chunks))))
         (committed (plist-get step :text)))
    (plist-put step :text (if (string-empty-p committed) seen
                           (concat committed "\n" seen)))
    ;; The deferred renderer and reconciliation share the same boundaries.
    ;; Later blocks must not extend this finished body's end marker.
    (set-marker-insertion-type (plist-get state :end) nil)
    (push state (plist-get step :text-regions))))

(defun dsh-emacs-render--uncommitted-content (committed content)
  "Return CONTENT after COMMITTED blocks, or nil when they diverge.
Both strings join protocol blocks with newlines.  The separator before an
uncommitted block belongs to the join, not to that block's Markdown body."
  (cond
   ((string-empty-p committed) content)
   ((equal committed content) "")
   ((string-prefix-p (concat committed "\n") content)
    (substring content (1+ (length committed))))))

(defun dsh-emacs-render--drop-committed-text (step)
  "Delete the finished assistant bodies STEP recorded.
A divergent authoritative body supersedes them; keeping them would leave the
wrong text above the repaired one.  The caller binds `inhibit-read-only'."
  (dolist (state (plist-get step :text-regions))
    (setq dsh-emacs--markdown-pending
          (delq state dsh-emacs--markdown-pending))
    (let ((rs (marker-position (plist-get state :start)))
          (re (marker-position (plist-get state :end))))
      (when (and rs re (< rs re))
        (delete-region rs re)))
    (dsh-emacs-render--reset-markdown-state state)
    (set-marker (plist-get state :start) nil)
    (set-marker (plist-get state :end) nil))
  (plist-put step :text-regions nil)
  (plist-put step :text ""))

(defun dsh-emacs-render--drop-committed-thinking (step)
  "Delete STEP's folded Think fragments and return their first position."
  (let (first)
    (dolist (block (plist-get step :thinking-blocks))
      (when-let* ((range (dsh-emacs-ui-find-block (car block) (cdr block))))
        (setq first (min (or first (car range)) (car range)))
        (dsh-emacs-ui-delete-fragment (car block) (cdr block))))
    (plist-put step :thinking-blocks nil)
    (plist-put step :thinking-regions nil)
    (plist-put step :reasoning "")
    first))

(cl-defun dsh-emacs-render--follow-stream
    (&optional (windows
                (unless (or (plist-get dsh-emacs--streaming-assistant :timer)
                            (plist-get dsh-emacs--streaming-thinking :timer))
                  (dsh-emacs-render--following-windows))))
  "Realign line highlights and keep WINDOWS' own draft points visible.
When omitted, select current following windows unless a stream batch is
pending.  A supplied list retains the follow decision made before an edit;
explicit nil follows no windows.  Readers outside that list stay untouched."
  ;; Inserting at the prompt stretches hl-line's overlay over new output.
  ;; Async writes have no post-command hook to restore its range.  Move only
  ;; live overlays, preserving their window scope even in background chats.
  (dolist (overlay (list (and hl-line-mode hl-line-overlay)
                        (and global-hl-line-mode global-hl-line-overlay)))
    (when (and (overlayp overlay)
               (eq (overlay-buffer overlay) (current-buffer)))
      (hl-line-move overlay)))
  ;; Without the prompt, point-max would pin the phantom line below input.
  (when-let* ((anchor (and windows (dsh-emacs-render--input-anchor-pos))))
    (dolist (window windows)
      (when (and (window-live-p window)
                 (eq (window-buffer window) (current-buffer)))
        ;; Character-row capacity ignores line spacing and larger faces.
        ;; Scanning back that many rows puts input below the viewport; the
        ;; next redisplay then scrolls it back, fighting every stream flush.
        ;; Native recentering accounts for pixel heights and the draft point.
        (let ((target (max anchor (window-point window))))
          (with-selected-window window
            (save-excursion
              (goto-char target)
              (recenter -1)))
          ;; Insertion at the prompt can leave its window point behind.
          (unless (or (eq window (selected-window))
                      (= (window-point window) target))
            (set-window-point window target)))))))

(defun dsh-emacs-render--input-insert-point ()
  "Return the start of the editable prompt line, or nil.
Rendered transcript blocks must be inserted before this line.  Do not move
back one line: after the first reply that would point inside the previous
assistant body and reverse the order of subsequent replies.

When `dsh-emacs--history-insert-marker' is set, an older-history prepend is
in progress and it wins: the batch must stack above the oldest block already
in the buffer, not above the prompt.  Otherwise, when Composer chrome (Goal /
Next Message) is shown above the input, its marker (`dsh-emacs--composer-top-marker')
wins so streamed content stays above the chrome; then the live prompt marker
is preferred; when it is missing or points into another buffer, the anchor is
located again by the prompt face so messages can never be appended below the
input area."
  (or
   ;; 0. Older-history prepend: stack above the loaded transcript.
   (when (and (boundp 'dsh-emacs--history-insert-marker)
              (markerp dsh-emacs--history-insert-marker)
              (eq (marker-buffer dsh-emacs--history-insert-marker)
                  (current-buffer)))
     (save-excursion
       (goto-char (marker-position dsh-emacs--history-insert-marker))
       (line-beginning-position)))
   ;; 1. Composer chrome top: transcript must insert above it so the
   ;; chrome never separates from the editable input.
   (when (and (boundp 'dsh-emacs--composer-top-marker)
              (markerp dsh-emacs--composer-top-marker)
              (eq (marker-buffer dsh-emacs--composer-top-marker)
                  (current-buffer)))
     (save-excursion
       (goto-char (marker-position dsh-emacs--composer-top-marker))
       (line-beginning-position)))
   ;; 2. Live marker pointing into the current buffer.
   (let ((m (and (boundp 'dsh-emacs--input-marker)
                 (markerp dsh-emacs--input-marker)
                 dsh-emacs--input-marker)))
     (when (and m (eq (marker-buffer m) (current-buffer)))
       (save-excursion
         (goto-char (marker-position m))
         (line-beginning-position))))
   ;; 3. Last prompt-face run: the anchor itself.
   (when-let* ((anchor (dsh-emacs-render--input-anchor-pos)))
     (save-excursion
       (goto-char anchor)
       (line-beginning-position)))))

(defun dsh-emacs-render--insert-read-only (text &optional face)
  "Insert TEXT as read-only with optional FACE."
  (let ((len (length text))
        (txt (copy-sequence text)))
    (add-text-properties 0 len '(read-only t front-sticky (read-only)) txt)
    (when face
      (add-text-properties 0 len (list 'face face) txt))
    (let ((buffer-undo-list t))
      (insert txt))))

(defun dsh-emacs-render--yank-user-text (text)
  "Insert copied user TEXT without transcript display or identity properties."
  (insert (substring-no-properties text)))

(defun dsh-emacs-render--insert-chat-message (text face insert-point event-id &optional role)
  "Insert TEXT as a read-only chat message.
FACE is applied to the message body.  EVENT-ID is stored for navigation.
The prompt remains after the message and each message ends with a newline,
so subsequent messages are appended in history order.  Blank lines left by
the previous content are consumed so everything stacks flush — except
around a user message (`role' = `user'), which gets one blank line
above AND is marked so the NEXT insertion keeps one blank line below it
(see `dsh-emacs-ui--blank-above-preserve').
ROLE also tags the body with its transcript property
\(`dsh-emacs-user-message' / `dsh-emacs-assistant-message') so commands can
locate message bodies by role; nil tags nothing.
Return (START . END) for the inserted message text, excluding separators."
  (when (and (stringp text) (not (string-empty-p text)))
    ;; Rendering happens from an asynchronous callback.  Never leave point at
    ;; the transcript insertion position; the user's cursor belongs after ❯.
    (save-excursion
      (let ((inhibit-read-only t)
            (buffer-undo-list t))
        (if insert-point
            (progn (goto-char insert-point) (beginning-of-line))
          ;; Robust fallback: never append below the input when the prompt
          ;; marker was unavailable to the caller.
          (if-let* ((anchor (dsh-emacs-render--input-anchor-pos)))
              (progn (goto-char anchor) (beginning-of-line))
            (goto-char (point-max))))
        ;; User messages start a new visual group, even after a footer that
        ;; leaves no blank lines.  Other content keeps the preceding request.
        (dsh-emacs-ui--consume-blanks-above
         (if (eq role 'user) 1 (dsh-emacs-ui--blank-above-preserve)))
        (when (and (eq role 'user) (not (bobp)))
          (let ((missing (save-excursion
                           (let ((end (point)))
                             (skip-chars-backward "\n")
                             (max 0 (- 2 (- end (point))))))))
            (insert (propertize (make-string missing ?\n)
                                'read-only t 'front-sticky '(read-only)
                                ;; History must prepend before this message's
                                ;; spacing, where its work-start marker sits.
                                'dsh-emacs-transcript-block t))))
        (let ((start (point))
              (text-end (progn (insert text) (point))))
          (unless (string-suffix-p "\n" text)
            (insert "\n"))
          ;; Trailing separator: consumed by the next content if any, or left
          ;; as spacing before the input area.
          (insert "\n")
          (let ((end (point)))
            (put-text-property start end 'read-only t)
            (put-text-property start end 'front-sticky '(read-only))
            ;; One identity for "a transcript block starts here", shared with
            ;; UI fragments: `dsh-emacs-render--history-prepend-marker' keys
            ;; the older-history insertion point off it.
            (put-text-property start text-end 'dsh-emacs-transcript-block t)
            ;; Add the background only to the message TEXT, never to the
            ;; trailing blank separator line, so blank lines stay transparent.
            (add-face-text-property start text-end face t)
            (when (eq role 'user)
              (let ((prefix
                     (if (display-graphic-p)
                         (concat
                          (propertize " " 'display '(space :width (3))
                                      'face 'dsh-emacs-user-border-face)
                          (propertize " " 'display '(space :width 2)))
                       (propertize "│ " 'face 'dsh-emacs-reply-meta-face))))
                (add-text-properties
                 start text-end (list 'line-prefix prefix 'wrap-prefix prefix))
                (when (display-graphic-p)
                  ;; A zero-width strut adds headroom only to the first visual
                  ;; line, including when the first paragraph wraps.
                  (put-text-property
                   start (1+ start) 'line-prefix
                   (concat (propertize " " 'display
                                       '(space :width (0) :height 1 :ascent 100))
                           prefix))
                  (let ((newline (if (string-suffix-p "\n" text)
                                     (1- text-end) text-end)))
                    (put-text-property newline (1+ newline) 'line-spacing 0.25))))
              ;; UI spacing is independent of the message's business identity.
              (put-text-property start text-end 'yank-handler
                                 '(dsh-emacs-render--yank-user-text))
              (put-text-property start text-end 'dsh-emacs-ui-space-after 1)
              (put-text-property start text-end 'dsh-emacs-user-message t))
            (when (eq role 'assistant)
              (put-text-property start text-end 'dsh-emacs-assistant-message
                                 (or event-id t)))
            (when event-id
              (put-text-property start end 'dsh-emacs-event-block event-id)))
          (cons start text-end))))))

;;; ---------------------------------------------------------------------------
;;; Shared helpers: tool state tracking
;;; ---------------------------------------------------------------------------

(defvar-local dsh-emacs--anchor-seq 0
  "Seq of the last stably rendered event in the transcript.
Used for incremental rendering.")

(defvar-local dsh-emacs--history-insert-marker nil
  "When set, transcript insertion happens here instead of above the input.
`dsh-emacs-load-older-history' prepends an older `session/page' batch by
binding this to a marker at the current transcript start; nil keeps the
normal live-stream behavior (insert above the prompt / Composer chrome).")

(defvar-local dsh-emacs--history-earliest-seq nil
  "Seq of the earliest event rendered in this transcript, or nil.
Set from the follow snapshot's message-aligned tail and pulled earlier by
every prepended `session/page' batch.  `dsh-emacs-load-older-history' passes
it as the page's exclusive `beforeSeq' cursor, so each page continues where
the loaded history begins.")

(defvar-local dsh-emacs--history-has-more nil
  "Non-nil when the server reported older messages before the loaded tail.
A fresh follow snapshot replaces this from its own `hasMore' flag; a loaded
page replaces it with the page's flag.  nil keeps `dsh-emacs-load-older-history'
from issuing a doomed page request.")

(defvar-local dsh-emacs--history-cursor nil
  "The follow snapshot's inclusive session cursor, or nil.
`dsh-emacs-load-older-history' sends it as `session/page' `throughSeq'.  It
must be a real seq: the server slices `events[0 .. min(throughSeq + 1,
beforeSeq))', so the wire's `-1' convention (\"the newest page\") collapses the
slice to `events[0 .. 0)' and reads an EMPTY page, even when older messages
exist.  The snapshot cursor is always at or below the server's current cursor,
so it stays a valid upper bound as the session grows.")

(defvar-local dsh-emacs--history-page nil
  "Bound around one older-history page render; nil for live/snapshot renders.
Unlike `dsh-emacs--history-insert-marker', which exists for POSITIONING and is
only set while a block to insert above exists, this flag says what the render
IS, so page-vs-live decisions never depend on the transcript's contents.")

(defun dsh-emacs-render--history-page-p ()
  "Return non-nil while an older-history page is being rendered here.
Renderers consult this instead of `dsh-emacs--history-insert-marker': keeping
one definition of \"this render belongs to a settled page, not to the live
turn\" means the marker stays a positioning concern."
  (and (boundp 'dsh-emacs--history-page) dsh-emacs--history-page))

(defvar-local dsh-emacs--markdown-timer nil
  "One-shot idle timer for this buffer's pending Markdown.")

(defvar-local dsh-emacs--tool-states (make-hash-table :test 'equal)
  "Map from toolCallId -> plist (:state :variant :title :summary :args :result).")

(defvar-local dsh-emacs--turn-awaiting nil
  "Non-nil while a run submitted by this buffer awaits `turn/end'.")

(defvar-local dsh-emacs-render--turn-deliverables nil
  "Alist of (TURN . FILES) collected from `deliverables/presented' events.
FILES is a list of (PATH . DESCRIPTION) cells.  The row is rendered by
`turn/end' (`dsh-emacs-render--flush-deliverables'), so a turn's deliveries
sit after its closing message, mirroring dsh web's turnTail placement.")

(defvar-local dsh-emacs-render--attempt-turns nil
  "Turn plists with :facts by seq and a :position marker for their newest :seq.
Older pages can supply missing outcomes; trimming removes consumed turns.")

(defvar-local dsh-emacs-render--reply-turns nil
  "Turn summaries for reply footers and work folds, keyed by turn number.
Retain per-message usage and answer eligibility by seq for history merges,
plus work boundary markers and the reader's disclosure overlay.")

(defvar-local dsh-emacs-render--inbox-pending nil
  "Pending inbox messages per target, as (ID . SOURCE-KIND) cells.
Replayed from `agent/inbox/spliced' only to classify a notice that claims a
turn: the renderer paints nothing and keeps no Agent or queue state.")

(defvar-local dsh-emacs-render--inbox-claim nil
  "Latest inbox claim per target, or nil.
Each value is a plist of :seq, :entries (the claimed (ID . SOURCE-KIND)
cells), :human (whether the batch claimed human input) and :truncated (the
queue lost the inserted batch to a page cut).  dsh web's `InboxState'
replaces a target's claim on every claim, and an insertion removes a
requeued id again.")

(defvar-local dsh-emacs-render--turn-start-seq nil
  "Event seq of the current turn's `turn/start', or nil.
dsh web's idle-steer test compares it with the latest inbox claims.")

(defvar-local dsh-emacs-render--turn-step nil
  "Current `step/start' step number, or nil.
A non-human next-step claim only wakes a turn at step 1.")

(defvar-local dsh-emacs-render--turn-opener-painted nil
  "Non-nil once the current turn's opening input painted a row.
A hidden injection does not set it: the opening claim batch decides whether a
later notice may still use the opener fallback.  A visible opener ends
attribution, and so does an exhausted batch below.")

(defvar-local dsh-emacs-render--turn-claim-slots nil
  "Opening claim messages still expected to render in the current turn.
The host logs its claims after `turn/start' and before the first `step/start',
so their non-canceled removals record the admitted batch even when a page cut
lost the queue entries.  Every rendered `user/message' spends one slot; once
they run out, a later notice belongs to a later step and cannot use the
opener fallback.")

(defvar dsh-emacs-render--footer-batch nil
  "Non-nil while collecting a bounded history batch before painting footers.")

(defvar dsh-emacs-render--footer-dirty nil
  "Turn numbers changed during the current history batch.")

(defvar-local dsh-emacs--command-blocks (make-hash-table :test 'equal)
  "Map from node id -> (NS BLOCK-ID LABEL ICON) of rendered bash-command rows.
Serverside slash commands are keyed by their `command/run' commandId;
client-side `!command' rows (see `dsh-emacs-render-shell-start') use
their own monotonic `shell-N' ids so the two never collide.  Both share
the same row machinery — icon, pending tint and success/error restyle —
and both are cleared by `dsh-emacs-render--reset-tool-tracking'.")

(defvar-local dsh-emacs--pending-command nil
  "When non-nil, an optimistic slash-command row rendered before the RPC round-trip.
Value is (TEMP-COMMAND-ID LABEL) where TEMP-COMMAND-ID is the temporary key
used in `dsh-emacs--command-blocks' and LABEL is the display name.
The real `command/run' event replaces this entry; on RPC error or admission
miss the entry is cleaned up.")

(defun dsh-emacs-render--reset-tool-tracking ()
  "Reset tool tracking state. Called on full transcript reload."
  (dsh-emacs-render--flush-stream nil t)
  (dsh-emacs-render--cancel-markdown)
  (when dsh-emacs-render--reply-turns
    (maphash (lambda (_turn state)
               (dsh-emacs-render--release-work-details state))
             dsh-emacs-render--reply-turns))
  (setq dsh-emacs--streaming-assistant nil
        dsh-emacs--streaming-thinking nil
        dsh-emacs--streamed-step nil
        dsh-emacs--tool-states (make-hash-table :test 'equal)
        dsh-emacs--command-blocks (make-hash-table :test 'equal)
        dsh-emacs--pending-command nil
        dsh-emacs-render--turn-deliverables nil
        dsh-emacs-render--inbox-pending nil
        dsh-emacs-render--inbox-claim nil
        dsh-emacs-render--turn-start-seq nil
        dsh-emacs-render--turn-step nil
        dsh-emacs-render--turn-opener-painted nil
        dsh-emacs-render--turn-claim-slots nil
        dsh-emacs-render--reply-turns nil
        dsh-emacs-render--attempt-turns nil)
  ;; Todo strip folds its snapshot from replayed `tool/call' events, so clear
  ;; the state and the fragment; the replay rebuilds it.
  (when (boundp 'dsh-emacs--todo-namespace)
    (dsh-emacs-render-todo-clear)))

(defun dsh-emacs-render--tool-state (tool-call-id)
  "Return the tracked state plist for TOOL-CALL-ID, or nil."
  (gethash tool-call-id dsh-emacs--tool-states))

(defun dsh-emacs-render--set-tool-state (tool-call-id &rest props)
  "Set props onto the tracked state of TOOL-CALL-ID, replacing all."
  (puthash tool-call-id props dsh-emacs--tool-states))

(defun dsh-emacs-render--stream-state-key (state)
  "Return the logical key stored in streaming STATE."
  (plist-get state :key))

(defun dsh-emacs-render--reset-markdown-state (state)
  "Release and clear STATE's parsing markers."
  (let ((markdown (plist-get state :markdown)))
    (dolist (key '(:scan :pending :watermark))
      (when-let* ((marker (plist-get markdown key)))
        (set-marker marker nil)
        (setf (plist-get markdown key) nil)))
    ;; A reset invalidates the open block along with the scan markers it was
    ;; opened against, so drop its identity and release its markers too.
    (dsh-emacs-markdown--release-open-block markdown)
    (setf (plist-get markdown :kind) nil)))

(defun dsh-emacs-render--protect-stream-region (state start end)
  "Apply STATE's transcript protection and event identity to START..END.
STATE is always an assistant stream, so the region is also tagged as an
assistant message body for the copy commands."
  (when (< start end)
    (let ((inhibit-read-only t)
          (buffer-undo-list t)
          (event-id (plist-get state :event-id)))
      (add-text-properties
       start end
       (append '(read-only t front-sticky (read-only)
                 rear-nonsticky (read-only))
               ;; The event id doubles as the message identity here, so two
               ;; adjacent replies stay separate property runs.
               (list 'dsh-emacs-assistant-message (or event-id t))
               (when (plist-get state :seq)
                 (list 'dsh-emacs-message-seq (plist-get state :seq)))
               (when event-id (list 'dsh-emacs-event-block event-id)))))))

(defun dsh-emacs-render--schedule-markdown ()
  "Schedule one idle attempt for this buffer's pending Markdown."
  (when (and dsh-emacs--markdown-pending (null dsh-emacs--markdown-timer))
    (setq dsh-emacs--markdown-timer
          ;; An already-expired idle deadline would spin when rearmed from
          ;; its own callback.  Check current idleness at the next clock tick.
          (run-at-time 0.1 nil #'dsh-emacs-render--run-markdown
                       (current-buffer) t))))

(defun dsh-emacs-render--stream-render-region (state &optional force final new-text)
  "Format STATE's ready Markdown and apply transcript properties there.
FORCE repairs a replaced body; FINAL also renders unfinished tables.
Pending raw text already carries transcript properties from insertion.
NEW-TEXT lets long partial lines skip formatting until a newline arrives."
  (when force (dsh-emacs-render--reset-markdown-state state))
  (when final (setf (plist-get state :render-final) t))
  (let ((start (marker-position (plist-get state :start)))
        (end (marker-position (plist-get state :end))))
    (when (and start end (<= start end)
               (or force final (null new-text)
                   ;; An open block's flush only styles the chars that just
                   ;; arrived — no parsing — so the wait-for-a-newline
                   ;; throttle has nothing to save there.
                   (plist-get (plist-get state :markdown) :open-block)
                   (null dsh-emacs-stream-markdown-limit)
                   (<= (- end (or (plist-get (plist-get state :markdown)
                                             :watermark)
                                  start))
                       dsh-emacs-stream-markdown-limit)
                   (string-match-p "\n" new-text)))
      (save-excursion
        (save-restriction
          (narrow-to-region start end)
          (let* ((markdown (plist-get state :markdown))
                 (ready (if final end (dsh-emacs-markdown--stream-end markdown)))
                 (begin (dsh-emacs-markdown--watermark-start markdown)))
            (if (or (memq state dsh-emacs--markdown-pending)
                    (and dsh-emacs-stream-markdown-limit
                         ;; An open block must keep streaming into the live
                         ;; buffer: deferred work re-reads the body as
                         ;; markdown and cannot see the block.
                         (not (plist-get markdown :open-block))
                         (> (- ready begin) dsh-emacs-stream-markdown-limit)))
                (progn
                  ;; Future messages inserted at this boundary belong to
                  ;; their own jobs.  Appending a delta advances it explicitly.
                  (set-marker-insertion-type (plist-get state :start) t)
                  (set-marker-insertion-type (plist-get state :end) nil)
                  (unless (memq state dsh-emacs--markdown-pending)
                    (setq dsh-emacs--markdown-pending
                          (nconc dsh-emacs--markdown-pending (list state))))
                  (dsh-emacs-render--schedule-markdown))
              (save-excursion
                (let* ((inhibit-read-only t)
                       (buffer-undo-list t)
                       (end-marker (plist-get state :end))
                       (insertion-type (marker-insertion-type end-marker)))
                  (unwind-protect
                      (progn
                        (set-marker-insertion-type end-marker t)
                        (pcase-let ((`(,body-start . ,body-end)
                                     (dsh-emacs-markdown-replace-markup
                                      :force force :final final
                                      :base-face 'dsh-emacs-assistant-body-face
                                      :stream-state markdown)))
                          (dsh-emacs-render--protect-stream-region
                           state body-start body-end)))
                    (set-marker (plist-get state :start) start)
                    (set-marker-insertion-type end-marker insertion-type)))))))))))

(defun dsh-emacs-render--cancel-markdown ()
  "Cancel pending Markdown when this transcript is reset or destroyed."
  (when dsh-emacs--markdown-timer
    (cancel-timer dsh-emacs--markdown-timer)
    (setq dsh-emacs--markdown-timer nil))
  (dolist (state dsh-emacs--markdown-pending)
    (dsh-emacs-render--reset-markdown-state state)
    (set-marker (plist-get state :start) nil)
    (set-marker (plist-get state :end) nil))
  (setq dsh-emacs--markdown-pending nil))

(cl-defun dsh-emacs-render--run-markdown (buffer &optional idle-only)
  "Prepare one pending reply in BUFFER, aborting work when input arrives.
Only a complete result replaces visible text.  Interrupted work is retried
at the next idle period; edits during preparation invalidate that attempt.
IDLE-ONLY is set by the timer; nil permits an explicit immediate attempt."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when dsh-emacs--markdown-timer
        (cancel-timer dsh-emacs--markdown-timer)
        (setq dsh-emacs--markdown-timer nil))
      (when (and idle-only
                 (let ((idle (current-idle-time)))
                   (or (null idle) (< (float-time idle) 0.1))))
        (dsh-emacs-render--schedule-markdown)
        (cl-return-from dsh-emacs-render--run-markdown nil))
      (when-let* ((state (car dsh-emacs--markdown-pending)))
        (let (finished)
          (condition-case err
              (if (not (and (marker-buffer (plist-get state :start))
                            (marker-buffer (plist-get state :end))))
                  (progn
                    (when (eq state dsh-emacs--streaming-assistant)
                      (dsh-emacs-render--flush-stream))
                    (setq finished t))
                (when (eq state dsh-emacs--streaming-assistant)
                  (dsh-emacs-render--flush-stream))
                (let* ((body-start (marker-position (plist-get state :start)))
                       (start (marker-position
                               (or (plist-get (plist-get state :markdown) :watermark)
                                   (plist-get state :start))))
                       (end (marker-position (plist-get state :end)))
                       (tick (buffer-chars-modified-tick))
                       (window (or (get-buffer-window buffer t) (selected-window)))
                       (source (buffer-substring start end))
                       (result
                        (while-no-input
                          (with-temp-buffer
                            (let ((inhibit-read-only t)
                                  (dsh-emacs-markdown--render-window window)
                                  (markdown (list :scan nil :pending nil :kind nil
                                                  :watermark nil)))
                              (insert source)
                              (dsh-emacs-markdown-replace-markup
                               :stream-state markdown
                               :final (plist-get state :render-final)
                               :base-face 'dsh-emacs-assistant-body-face)
                              (list (buffer-string)
                                    (when-let* ((frontier
                                                 (plist-get markdown :watermark)))
                                      (- frontier (point-min)))
                                    ;; A block the temp render opened is on
                                    ;; screen once TEXT lands; carry its
                                    ;; identity out so the live state can keep
                                    ;; streaming that body raw.
                                    (when-let* ((open (plist-get markdown :open-block)))
                                      (list :lang (plist-get open :lang)
                                            :fence (plist-get open :fence)
                                            :prefix (plist-get open :prefix)))))))))
                  (when (and (consp result) (= tick (buffer-chars-modified-tick)))
                    (pcase-let ((`(,text ,frontier ,open) result)
                                (windows (dsh-emacs-render--following-windows))
                                (inhibit-read-only t)
                                (buffer-undo-list t))
                      (save-excursion
                        (atomic-change-group
                          ;; Available since Emacs 27.1.  Preserve reading
                          ;; positions and neighboring jobs; cap diff work.
                          ;; Diff only characters: protected string properties
                          ;; can leak into Emacs's internal coding work buffer.
                          (replace-region-contents
                           start end (lambda () (substring-no-properties text)) 0.01)
                          ;; The text diff retains old properties on unchanged
                          ;; characters.  Install the prepared display properties.
                          (let ((pos 0))
                            (while (< pos (length text))
                              (let ((next (next-property-change pos text (length text))))
                                (set-text-properties
                                 (+ start pos) (+ start next)
                                 (text-properties-at pos text))
                                (setq pos next))))
                          (dsh-emacs-render--protect-stream-region
                           state start (+ start (length text)))))
                      (set-marker (plist-get state :start) body-start)
                      (set-marker (plist-get state :end) (+ start (length text)))
                      (dsh-emacs-render--reset-markdown-state state)
                      (when frontier
                        (let ((markdown (plist-get state :markdown)))
                          (setf (plist-get markdown :scan)
                                (copy-marker (+ start frontier))
                                (plist-get markdown :watermark)
                                (copy-marker (+ start frontier)))
                          ;; The temp render wrote a card's chrome into the
                          ;; transcript: the live state must own the same open
                          ;; block, or the next pass re-reads the body as
                          ;; markdown and leaves the closing fence raw.
                          (when open
                            (plist-put markdown :kind (plist-get open :fence))
                            (plist-put markdown :open-block
                                       (list :lang (plist-get open :lang)
                                             :fence (plist-get open :fence)
                                             :prefix (plist-get open :prefix)
                                             :body-start
                                             (copy-marker (+ start frontier)
                                                          nil))))))
                      (setq finished t)
                      (dsh-emacs-render--follow-stream windows)))))
            (error
             (setq finished t)
             (message "dsh: Markdown rendering failed: %s"
                      (error-message-string err))))
          (when finished
            (setq dsh-emacs--markdown-pending
                  (delq state dsh-emacs--markdown-pending))
            (unless (or (eq state dsh-emacs--streaming-assistant)
                        (memq state (plist-get dsh-emacs--streamed-step
                                               :text-regions)))
              (dsh-emacs-render--reset-markdown-state state)
              (set-marker (plist-get state :start) nil)
              (set-marker (plist-get state :end) nil)))))
      (dsh-emacs-render--schedule-markdown))))

(defconst dsh-emacs-render--stream-batch-interval 0.05
  "Seconds to accumulate streamed text before a scheduled flush.
Kept aligned with `dsh-emacs-events--read-batch-interval'.")

(defun dsh-emacs-render--flush-stream (&optional buffer final)
  "Insert and format BUFFER's queued text and cancel its one-shot timer.
FINAL also finishes deferred markup when no timer is pending."
  (let ((buffer (or buffer (current-buffer))))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (dsh-emacs-render--flush-thinking)
        (when-let* ((state dsh-emacs--streaming-assistant))
          (let* ((timer (plist-get state :timer))
                 (text (when (plist-get state :pending)
                         (apply #'concat (reverse (plist-get state :pending)))))
                 (windows (when (or timer final)
                            (dsh-emacs-render--following-windows))))
            (when timer
              (cancel-timer timer)
              (setf (plist-get state :timer) nil))
            (when text
              (let ((inhibit-read-only t)
                    (buffer-undo-list t))
                (save-excursion
                  (goto-char (plist-get state :end))
                  (insert (propertize text
                                      'read-only t
                                      'front-sticky '(read-only)
                                      'rear-nonsticky '(read-only)
                                      'face 'dsh-emacs-assistant-body-face
                                      'dsh-emacs-assistant-message
                                      (plist-get state :event-id)
                                      'dsh-emacs-event-block
                                      (plist-get state :event-id)))
                  (set-marker (plist-get state :end) (point)))
                (setf (plist-get state :pending) nil)))
            (when (or timer final)
              (dsh-emacs-render--stream-render-region state nil final text)
              (dsh-emacs-render--follow-stream windows))))))))

(defun dsh-emacs-render--close-live-text-block ()
  "Detach the live text body above the block that is about to start.
The text streamed so far stays on screen as its own assistant body and is
recorded on the step; a later text block starts fresh below the new block.
Without this the live region would span the new block, so the Markdown passes
would rewrite that block's text and the final repair would delete it."
  (when-let* ((state dsh-emacs--streaming-assistant))
    (dsh-emacs-render--flush-stream)
    ;; An unfinished fence/table belongs to the text that just ended.
    ;; Deferred work keeps its bounded region and finishes at idle; retrying
    ;; while input is pending would prevent the command loop consuming it.
    (dsh-emacs-render--stream-render-region state nil t)
    (dsh-emacs-render--commit-text-segment state)
    (setq dsh-emacs--streaming-assistant nil)))

(defun dsh-emacs-render--start-assistant-stream (event text)
  "Create or extend the live assistant stream with TEXT from EVENT."
  (when (and (stringp text) (not (string-empty-p text)))
    (let* ((key (dsh-protocol-stream-key--from-alist event))
           (index (dsh-protocol-chunk-index--from-alist event))
           (state dsh-emacs--streaming-assistant)
           (new-state nil)
           windows)
      ;; A new step or block index owns a separate body, even when the
      ;; preceding block also contained text and no block-end has arrived.
      (when (and state
                 (or (not (equal key (plist-get state :key)))
                     (and index (not (eql index (plist-get state :index))))))
        (dsh-emacs-render--close-live-text-block)
        (setq state nil))
      (unless state
        ;; A new text block starts: the block above it (reasoning) owns the
        ;; transcript up to here and must be folded before this body opens.
        (dsh-emacs-render--close-live-thinking-block)
        (setq windows (dsh-emacs-render--following-windows))
        (let* ((insert-point (dsh-emacs-render--input-insert-point))
               (event-id (format "%s-stream-%s"
                                 (dsh-emacs-render--make-namespace) key))
               start end)
          (save-excursion
            (let ((inhibit-read-only t)
                  (buffer-undo-list t))
              (if insert-point
                  (progn (goto-char insert-point) (beginning-of-line))
                ;; Never append below the input when the prompt marker was
                ;; unavailable: fall back to the anchor itself.
                (if-let* ((anchor (dsh-emacs-render--input-anchor-pos)))
                    (progn (goto-char anchor) (beginning-of-line))
                  (goto-char (point-max))))
              ;; Match settled messages: preserve the preceding content's
              ;; requested spacing, including the gap below a user message.
              (dsh-emacs-ui--consume-blanks-above
               (dsh-emacs-ui--blank-above-preserve))
              (setq start (point))
              (insert (propertize text
                                  'read-only t
                                  'front-sticky '(read-only)
                                  'rear-nonsticky '(read-only)
                                  'face 'dsh-emacs-assistant-body-face
                                  'dsh-emacs-assistant-message event-id
                                  'dsh-emacs-event-block event-id))
              (dsh-emacs-render--insert-read-only "\n\n")
              (setq end (copy-marker (- (point) 2) t))))
          (setq state (list :key key :index index
                            :start (copy-marker start nil)
                            :end end
                            :event-id event-id :seq nil
                            :chunks (list text)
                            :pending nil
                            :markdown (list :scan nil :pending nil :kind nil
                                            :watermark nil)
                            :render-final nil
                            :timer nil)
                dsh-emacs--streaming-assistant state
                new-state t)))
      (when (and state (not new-state))
        (push text (plist-get state :chunks))
        (push text (plist-get state :pending)))
      (if new-state
          (progn
            (dsh-emacs-render--stream-render-region state nil nil text)
            (dsh-emacs-render--follow-stream windows))
        (unless (plist-get state :timer)
          (setf (plist-get state :timer)
                (run-at-time dsh-emacs-render--stream-batch-interval nil
                             #'dsh-emacs-render--flush-stream
                             (current-buffer)))))
      state)))

(defun dsh-emacs-render--finish-assistant-stream (event final-text &optional step)
  "Replace the live stream with FINAL-TEXT from assistant/message EVENT.
STEP records the text this step already rendered (see `--step-record'), so only
the live segment is reconciled and finished bodies are left alone.  Matching
text needs only the pending incremental pass; changed text is replaced and
rendered in full."
  (let ((state dsh-emacs--streaming-assistant))
    (when (and state
               (equal (dsh-protocol-stream-key--from-alist event)
                      (dsh-emacs-render--stream-state-key state)))
      (let* ((step (or step
                       (dsh-emacs-render--step-record (plist-get state :key))))
             (committed (or (plist-get step :text) ""))
             (text (or final-text ""))
             (seen (apply #'concat (reverse (plist-get state :chunks))))
             ;; What this live body should show once finished: the part of the
             ;; authoritative text that was not already committed.
             (replacement (dsh-emacs-render--uncommitted-content committed text)))
        (if (equal replacement seen)
            (dsh-emacs-render--flush-stream nil t)
          (when-let* ((timer (plist-get state :timer)))
            (cancel-timer timer)
            (setf (plist-get state :timer) nil))
          (let ((inhibit-read-only t)
                (buffer-undo-list t)
                (windows (dsh-emacs-render--following-windows)))
            ;; A divergent body supersedes everything this step painted as
            ;; text: drop the finished bodies so the wrong text does not stay
            ;; above the repaired one.  A prefix divergence only repairs the
            ;; live segment and leaves them alone.
            (unless replacement
              (dsh-emacs-render--drop-committed-text step)
              (setq replacement text))
            (let ((start (marker-position (plist-get state :start)))
                  (end (marker-position (plist-get state :end))))
              (when (and start end)
                (save-excursion
                  (goto-char start)
                  (delete-region start end)
                  (insert (propertize replacement
                                      'face 'dsh-emacs-assistant-body-face
                                      'dsh-emacs-assistant-message
                                      (plist-get state :event-id)))
                  (set-marker (plist-get state :start) start)
                  (set-marker (plist-get state :end) (point)))
                (dsh-emacs-render--protect-stream-region
                 state start (plist-get state :end))
                (dsh-emacs-render--stream-render-region state t t)
                (dsh-emacs-render--follow-stream windows))))))
      ;; Only the durable message supplies a fork boundary.  Keep it in the
      ;; state too, so a deferred Markdown pass preserves the same identity.
      (set-marker-insertion-type (plist-get state :end) nil)
      (setf (plist-get state :seq) (dsh-protocol-event-sequence--from-alist event))
      (when (plist-get state :seq)
        (let ((inhibit-read-only t)
              (buffer-undo-list t))
          (put-text-property (plist-get state :start) (plist-get state :end)
                             'dsh-emacs-message-seq (plist-get state :seq))))
      (unless (memq state dsh-emacs--markdown-pending)
        (set-marker (plist-get state :start) nil)
        (set-marker (plist-get state :end) nil))
      (setq dsh-emacs--streaming-assistant nil)
      t)))

(defun dsh-emacs-render--flush-thinking (&optional buffer)
  "Insert BUFFER's queued reasoning deltas in one edit and follow once."
  (when (buffer-live-p (or buffer (current-buffer)))
    (with-current-buffer (or buffer (current-buffer))
      (when-let* ((state dsh-emacs--streaming-thinking)
                  (timer (plist-get state :timer)))
        (cancel-timer timer)
        (setf (plist-get state :timer) nil)
        (let ((windows (dsh-emacs-render--following-windows)))
          (if (plist-get state :inline)
              (dsh-emacs-render--render-thinking-block
               (plist-get state :ns) (plist-get state :block-id)
               (apply #'concat (reverse (plist-get state :all)))
               nil t t)
            (let ((text (apply #'concat (reverse (plist-get state :chunks))))
                  (inhibit-read-only t)
                  (buffer-undo-list t))
              (setf (plist-get state :chunks) nil)
              (save-excursion
                (goto-char (plist-get state :end))
                (dsh-emacs-render--insert-read-only
                 text 'dsh-emacs-thinking-body-face))))
          (dsh-emacs-render--follow-stream windows))))))

(defun dsh-emacs-render--thinking-stream-alive-for-p (key)
  "Return non-nil when the live thinking stream is active for KEY."
  (and dsh-emacs--streaming-thinking
       (equal key (plist-get dsh-emacs--streaming-thinking :key))))

(defun dsh-emacs-render--inline-thinking-stream (event text key index state)
  "Create or extend the inline Think row for TEXT and return its state.
EVENT names the stream, KEY and INDEX identify the reasoning block, and STATE
is the current live state or nil.  Mirrors dsh web: one collapsed row that
advances its paragraph preview while the model thinks."
  (when (and state
             (or (not (equal key (plist-get state :key)))
                 (and index (not (eql index (plist-get state :index))))))
    (dsh-emacs-render--close-live-thinking-block)
    (setq state nil))
  (if state
      (progn
        (push text (plist-get state :all))
        (unless (plist-get state :timer)
          (setf (plist-get state :timer)
                (run-at-time 0.1 nil #'dsh-emacs-render--flush-thinking
                             (current-buffer))))
        state)
    ;; A reasoning block starts: close the text above it so the row lands at
    ;; the block boundary, then render the collapsed disclosure in one edit.
    (dsh-emacs-render--close-live-text-block)
    (let* ((insert-point (dsh-emacs-render--input-insert-point))
           (windows (dsh-emacs-render--following-windows))
           (ns (dsh-emacs-render--make-namespace))
           (block-id (dsh-emacs-render--make-block-id event)))
      (dsh-emacs-render--render-thinking-block
       ns block-id text insert-point nil t)
      (setq state (list :key key :index index :inline t
                        :all (list text) :timer nil
                        :ns ns :block-id block-id))
      (setq dsh-emacs--streaming-thinking state)
      (dsh-emacs-render--follow-stream windows)
      state)))

(cl-defun dsh-emacs-render--start-thinking-stream (event text)
  "Create or extend the live Thinking stream with reasoning TEXT.
With `dsh-emacs-thinking-style' `expand' the stream is a raw body under a
dsh-web \"IconThink…\" header (see `dsh-emacs-render--think-icon') inserted at
the transcript's input point, so `reasoning-delta' chunks stay cheap to append;
`dsh-emacs-render-assistant-message' folds it into the collapsible Think
fragment once the authoritative reasoning text arrives.  With `inline' the
first delta renders the collapsed fragment itself and later deltas refresh
it."
  (when (and dsh-emacs-show-thinking
             (stringp text) (not (string-empty-p text)))
    (let* ((key (dsh-protocol-stream-key--from-alist event))
           (index (dsh-protocol-chunk-index--from-alist event))
           (state dsh-emacs--streaming-thinking)
           (new-state nil))
      ;; A later block can start before this reasoning block finishes.
      ;; Its index still owns the folded row: reopening it at the input
      ;; would split the answer and create a second Think fragment.
      (when-let* ((step (and (integerp index)
                             (equal key (plist-get dsh-emacs--streamed-step :key))
                             dsh-emacs--streamed-step))
                  (closed (cl-find index (plist-get step :thinking-regions)
                                   :key (lambda (entry) (plist-get entry :index)))))
        (push text (plist-get closed :all))
        (dsh-emacs-render--render-thinking-block
         (plist-get closed :ns) (plist-get closed :block-id)
         (apply #'concat (reverse (plist-get closed :all)))
         nil t)
        (setf (plist-get step :reasoning)
              (mapconcat
               (lambda (entry)
                 (apply #'concat (reverse (plist-get entry :all))))
               (reverse (plist-get step :thinking-regions)) "\n"))
        (cl-return-from dsh-emacs-render--start-thinking-stream closed))
      ;; An active stream keeps the shape it opened with: the option picks
      ;; how a new stream starts.  Re-reading it here would send a mid-stream
      ;; change into the other shape's accumulator and drop deltas.
      (when (if state
                (plist-get state :inline)
              (eq dsh-emacs-thinking-style 'inline))
        (cl-return-from dsh-emacs-render--start-thinking-stream
          (dsh-emacs-render--inline-thinking-stream
           event text key index state)))
      ;; Consecutive reasoning blocks have distinct indices even when no
      ;; text delta separates them. Keep their regions and separators apart.
      (when (and state
                 (or (not (equal key (plist-get state :key)))
                     (and index (not (eql index (plist-get state :index))))))
        (dsh-emacs-render--close-live-thinking-block)
        (setq state nil))
      (unless state
        ;; A new reasoning block starts: the text above it owns the
        ;; transcript up to here and must be closed before this raw body
        ;; opens, or the text stream's Markdown region would span it.
        (dsh-emacs-render--close-live-text-block)
        (let* ((insert-point (dsh-emacs-render--input-insert-point))
               (windows (dsh-emacs-render--following-windows))
               start end)
          (save-excursion
            (let ((inhibit-read-only t)
                  (buffer-undo-list t))
              (if insert-point
                  (progn (goto-char insert-point) (beginning-of-line))
                (if-let* ((anchor (dsh-emacs-render--input-anchor-pos)))
                    (progn (goto-char anchor) (beginning-of-line))
                  (goto-char (point-max))))
              (dsh-emacs-ui--consume-blanks-above
               (dsh-emacs-ui--blank-above-preserve))
              (setq start (point))
              (dsh-emacs-render--insert-read-only
               (concat
                (propertize (dsh-emacs-render--think-icon)
                            'face 'dsh-emacs-thinking-face)
                (propertize " Think\n"
                            'face (dsh-emacs-render--row-label-face
                                   'dsh-emacs-thinking-face)))
               nil)
              (dsh-emacs-render--insert-read-only
               (concat text "\n") 'dsh-emacs-thinking-body-face)
              (setq end (copy-marker (- (point) 1) t))))
          (setq state (list :key key :index index
                            :start (copy-marker start nil)
                            :end end :chunks nil :timer nil
                            :all (list text)
                            :ns (dsh-emacs-render--make-namespace)
                            :block-id (dsh-emacs-render--make-block-id event))
                dsh-emacs--streaming-thinking state
                new-state t)
          (dsh-emacs-render--follow-stream windows)))
      (when (and state (not new-state))
        (push text (plist-get state :chunks))
        (push text (plist-get state :all))
        (unless (plist-get state :timer)
          (setf (plist-get state :timer)
                (run-at-time 0.1 nil #'dsh-emacs-render--flush-thinking
                             (current-buffer)))))
      state)))

(defun dsh-emacs-render--replace-live-thinking-text (ns block-id final-text)
  "Swap the live thinking stream for the final Think fragment.
NS and BLOCK-ID name the collapsible fragment; FINAL-TEXT is the
completed reasoning body.  Returns non-nil
when a live stream existed and was replaced."
  (dsh-emacs-render--flush-thinking)
  (let ((state dsh-emacs--streaming-thinking))
    (when state
      (let ((start (marker-position (plist-get state :start)))
            (end (marker-position (plist-get state :end))))
        (when (and start end (> end start))
          (let ((inhibit-read-only t)
                (buffer-undo-list t))
            (delete-region start end)
            (setq dsh-emacs--streaming-thinking nil)
            (dsh-emacs-render--render-thinking-block
             ns block-id final-text start)))
        (set-marker (plist-get state :start) nil)
        (set-marker (plist-get state :end) nil)
        (setq dsh-emacs--streaming-thinking nil))
      t)))

(defun dsh-emacs-render--close-live-thinking-block ()
  "Close the live Think block at the next text boundary.
The reasoning streamed so far stays on screen, behind its label, and is
recorded on the step; a later reasoning block opens a new Think block below
the text.  `expand' folds the raw body into its fragment here, while `inline'
settles the preview of the row that already exists.  Without this a raw
reasoning region would span the text that follows and be deleted when the
stream is finalized."
  (when-let* ((state dsh-emacs--streaming-thinking))
    (dsh-emacs-render--flush-thinking)
    (let* ((step (dsh-emacs-render--step-record (plist-get state :key)))
           (streamed (apply #'concat (reverse (plist-get state :all))))
           (committed (plist-get step :reasoning)))
      (plist-put step :reasoning
                 (if (string-empty-p committed) streamed
                   (concat committed "\n" streamed)))
      (if (plist-get state :inline)
          ;; The row already exists; settle its preview in place instead of
          ;; folding above the text that follows.
          (progn
            (dsh-emacs-render--render-thinking-block
             (plist-get state :ns) (plist-get state :block-id)
             streamed nil t)
            (setq dsh-emacs--streaming-thinking nil))
        (dsh-emacs-render--replace-live-thinking-text
         (plist-get state :ns) (plist-get state :block-id) streamed))
      (push state (plist-get step :thinking-regions))
      (push (cons (plist-get state :ns) (plist-get state :block-id))
            (plist-get step :thinking-blocks)))))

(defun dsh-emacs-render-assistant-chunk (event chunk)
  "Render an `assistant/chunk' EVENT incrementally.
CHUNK is EVENT's decoded `dsh-protocol-chunk', shared with the dispatcher.
Each protocol block owns its own transcript region: a `text-delta' opens or
extends the live assistant body and closes any live Thinking block, while a
`reasoning-delta' opens or extends the live Thinking block and closes the live
assistant body.  `block-end' supplies content only for an unseen block index;
providers may close earlier blocks after later blocks have already streamed."
  (let* ((ending (dsh-protocol-chunk-ending chunk))
         (type (dsh-protocol-chunk-type chunk))
         (text (dsh-protocol-chunk-text chunk))
         (index (dsh-protocol-chunk-index chunk))
         (key (dsh-protocol-stream-key--from-alist event)))
    (when (and (member type '("text-delta" "reasoning-delta"
                              "text" "reasoning"))
               (stringp text) (not (string-empty-p text))
               (not (and ending
                         (equal key (plist-get dsh-emacs--streamed-step :key))
                         (memq index (plist-get dsh-emacs--streamed-step
                                                :blocks)))))
      ;; Missing deltas use the same stream/commit path, so the final message
      ;; sees their content too.  A start notification alone renders nothing
      ;; and therefore cannot suppress this fallback.
      (if (member type '("text-delta" "text"))
          (dsh-emacs-render--start-assistant-stream event text)
        (dsh-emacs-render--start-thinking-stream event text))
      (when (integerp index)
        (let ((step (dsh-emacs-render--step-record key)))
          (cl-pushnew index (plist-get step :blocks))))))
  (dsh-protocol-event-sequence--from-alist event))

;;; ---------------------------------------------------------------------------
;;; Renderer: inline image attachments (session/attachment)
;;; ---------------------------------------------------------------------------

(defvar dsh-emacs-render--image-keymap
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'dsh-emacs-render--image-open)
    (define-key map [return] #'dsh-emacs-render--image-open)
    (define-key map [mouse-1] #'dsh-emacs-render--image-open)
    map)
  "Keymap on `[image …]' placeholders: opens the picture in its own buffer.")

(defun dsh-emacs-render--image-type-from-media (media-type)
  "Map MEDIA-TYPE (e.g. \"image/png\") to an Emacs image type symbol, or nil."
  (when (and (stringp media-type)
             (string-prefix-p "image/" media-type))
    (let ((type (intern (substring media-type (length "image/")))))
      (and (memq type image-types) type))))

(defun dsh-emacs-render--image-box-pixels (lines)
  "Return the side in pixels of a square image box LINES text lines tall."
  (max 1 (* (frame-char-height) (max 1 lines))))

(defun dsh-emacs-render--attachment-image (data media-type)
  "Build an image spec from decoded image DATA for MEDIA-TYPE.
The picture fits one compact gallery tile
\(`dsh-emacs-render-image-thumbnail-lines') whether the message carries one
image or several.  Returns nil when DATA is empty, the type is unsupported,
or the display cannot render images (terminal Emacs keeps the placeholder)."
  (when (and (display-graphic-p)
             (stringp data)
             (> (length data) 0))
    (let ((type (dsh-emacs-render--image-type-from-media media-type))
          (box (dsh-emacs-render--image-box-pixels
                dsh-emacs-render-image-thumbnail-lines)))
      (when type
        (ignore-errors
          (create-image data type t :max-width box :max-height box))))))

(defun dsh-emacs-render--open-image-data (data name)
  "Show raw image DATA (unibyte string) in a dedicated image buffer."
  (let ((buffer (get-buffer-create
                 (format " *dsh image: %s*" (or name "image")))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (set-buffer-multibyte nil)
        (insert data))
      (image-mode))
    (pop-to-buffer buffer)))

(defun dsh-emacs-render--image-open ()
  "Open the image under point in its own buffer.
Uses the bytes stashed on the placeholder when present, otherwise
re-fetches them via `session/attachment'."
  (interactive)
  (let* ((data (get-text-property (point) 'dsh-emacs-image-data))
         (attachment-id (get-text-property (point) 'dsh-emacs-attachment-id))
         (name (get-text-property (point) 'dsh-emacs-image-name)))
    (cond
     (data (dsh-emacs-render--open-image-data data name))
     (attachment-id
      (message "Fetching image…")
      (dsh-emacs-render--request-attachment
       (dsh-emacs--active-session-id) attachment-id
       (lambda (bytes)
         (if bytes
             (dsh-emacs-render--open-image-data bytes name)
           (message "Image fetch failed")))))
     (t (message "Image bytes unavailable")))))

(defun dsh-emacs-render--request-attachment (session-id attachment-id on-bytes)
  "Fetch image bytes for ATTACHMENT-ID from SESSION-ID via
`session/attachment'.  ON-BYTES receives the decoded unibyte string,
or nil when the RPC fails or the payload is malformed."
  (when (and session-id attachment-id)
    (dsh-emacs--rpc-async
     "session/attachment"
     (dsh-protocol-session-attachment-request session-id attachment-id)
     (lambda (ok value)
       ;; The callback may run inside a process filter: swallow the C-g quit.
       (condition-case nil
           (funcall on-bytes
                    (and ok value
                         (ignore-errors
                           (base64-decode-string
                            (dsh-protocol-attachment-data--from-alist value)))))
         (quit nil))))))

(defun dsh-emacs-render--apply-attachment (buffer id image data)
  "Fill the `[image …]' placeholder tagged ID in BUFFER in place.
IMAGE (when non-nil) goes on the `display' property; DATA (decoded
bytes, when non-nil) is stashed so RET keeps working offline.  A
missing placeholder (re-render, trimmed buffer) is a no-op."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((pos (text-property-any (point-min) (point-max)
                                    'dsh-emacs-image-id id)))
        (when pos
          (let ((end (next-single-property-change pos 'dsh-emacs-image-id
                                                  nil (point-max)))
                (inhibit-read-only t)
                (buffer-undo-list t))
            (when image
              (put-text-property pos end 'display image))
            (when data
              (put-text-property pos end 'dsh-emacs-image-data data))))))))

(defun dsh-emacs-render--show-attachment (id block)
  "Fill the `[image …]' placeholder tagged ID with BLOCK's picture.
Inline base64 applies immediately (no round-trip — the bytes are
already in the event); an attachment ref is fetched via
`session/attachment' and applied when the RPC settles."
  (let* ((buffer (current-buffer))
         (media-type (dsh-protocol-content-block-media-type block))
         (data-b64 (dsh-protocol-content-block-data block))
         (attachment-id (dsh-protocol-content-block-attachment-id block))
         (data (and data-b64 (ignore-errors (base64-decode-string data-b64)))))
    (if data
        (dsh-emacs-render--apply-attachment
         buffer id
         (dsh-emacs-render--attachment-image data media-type)
         data)
      (when attachment-id
        (dsh-emacs-render--request-attachment
         (dsh-emacs--active-session-id) attachment-id
         (lambda (bytes)
           (dsh-emacs-render--apply-attachment
            buffer id
            (dsh-emacs-render--attachment-image bytes media-type)
            bytes)))))))

(defun dsh-emacs-render--image-gallery-columns ()
  "Return how many thumbnails fit on one user-message line.
Widths are measured in pixels, so the count follows the buffer's window;
the user-message rail costs five columns of the line."
  (let* ((window (or (get-buffer-window (current-buffer) t)
                     (selected-window)))
         (width (window-body-width window t))
         (box (dsh-emacs-render--image-box-pixels
               dsh-emacs-render-image-thumbnail-lines))
         (gap (frame-char-width))
         (usable (max 0 (- width (* 5 gap)))))
    (max 1 (/ usable (+ box gap)))))

(defun dsh-emacs-render--image-gallery (placeholders)
  "Lay out image PLACEHOLDERS as thumbnail rows that fit the window.
PLACEHOLDERS are propertized strings, one per image, each keeping its own
identity properties.  A row joins its images with one space and rows are
joined with newlines, so the asynchronous fill-in still finds every slot."
  (let ((per-row (dsh-emacs-render--image-gallery-columns))
        (rows nil)
        (row nil)
        (count 0))
    (dolist (placeholder placeholders)
      (push placeholder row)
      (setq count (1+ count))
      (when (>= count per-row)
        (push (mapconcat #'identity (nreverse row) " ") rows)
        (setq row nil count 0)))
    (when row
      (push (mapconcat #'identity (nreverse row) " ") rows))
    (mapconcat #'identity (nreverse rows) "\n")))

(defun dsh-emacs-render--image-placeholder (id block)
  "Build the `[image …]' placeholder string tagged ID for image BLOCK."
  (let ((name (dsh-protocol-content-block-name block))
        (attachment-id (dsh-protocol-content-block-attachment-id block)))
    (propertize (if name (format "[image: %s]" name) "[image]")
                'dsh-emacs-image-id id
                'dsh-emacs-attachment-id attachment-id
                'dsh-emacs-image-name name
                'keymap dsh-emacs-render--image-keymap
                'help-echo (format "%s — RET or mouse-1 opens it"
                                   (or name "Image"))
                'mouse-face 'highlight)))

(defun dsh-emacs-render--file-placeholder (block)
  "Build the `[file: NAME · SIZE]' placeholder string for file BLOCK.
BLOCK is a `{type: \"file\", attachment}' content block: the durable
reference carries the sanitized leaf name and the exact byte count, so the
line says what the model received.  The bytes live on the host as a
content-addressed session attachment with no read path of its own, so the
line is display-only (unlike an image, which has `session/attachment')."
  (let* ((ref (dsh-protocol-content-block-file block))
         (name (dsh-protocol-file-ref-name ref))
         (bytes (dsh-protocol-file-ref-bytes ref)))
    (propertize (format "[file: %s%s]" (or name "file")
                        (if (integerp bytes)
                            (format " · %s" (dsh-emacs-format-bytes bytes))
                          ""))
                'face 'dsh-emacs-meta-face
                'dsh-emacs-file-name name
                'help-echo "Stored on the dsh host as a session attachment")))

;;; ---------------------------------------------------------------------------
;;; Renderer: user messages
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-render--user-authored-p (event)
  "Whether EVENT is a `user/message' the human actually wrote.
The host appends its own model-facing copies to the same surface and names
their origin in `data.source.kind': workspace instructions
\(`agent-instructions'), runtime-context snapshots, compaction checkpoints
and other plugin notices (`plugin'), agent and subagent traffic
\(`agent-message', `subagent-settled', `subagent-report'), and recall
context (`session-reference').  Only `user' — or a source-less fixture or
the optimistic echo — is conversation the user typed: the transcript hides
the rest, and `M-p' recall must not offer it back.  A goal round
continuation is the one exception: it is not author text either, but it
opens a turn the user should see, so it renders as a trigger notice
\(`dsh-emacs-render--goal-trigger-block')."
  (let ((kind (dsh-protocol-message-source-kind
               (dsh-protocol-message--from-alist event))))
    (or (null kind) (equal kind "user"))))

(defun dsh-emacs-render--insert-user-block (event references)
  "Insert EVENT's user block and return its (START . END) text region, or nil.
EVENT is a `user/message' wire event (or an optimistic look-alike carrying
just `data.content'); a host-injected copy (see
`dsh-emacs-render--user-authored-p') renders nothing — but a
`skill-invocation' copy is evidence that the user message it follows carried
a real skill gesture, so it re-chips that gesture instead (a replayed
transcript can render before the skill catalog is fetched).  REFERENCES
behaves as in `dsh-emacs-render-user-message'.  Split out of that renderer so
the optimistic echo path can capture the inserted region and roll it back
when its submit is rejected, while the canonical render keeps returning the
event seq."
  (let* ((message (dsh-protocol-message--from-alist event))
         (content (dsh-protocol-message-content message))
         (text (dsh-emacs-command-fontify-gestures
                (dsh-emacs-reference-fontify
                 (dsh-emacs-render--text-from-content content)
                 references)))
         (insert-point (dsh-emacs-render--input-insert-point))
         (block-id (dsh-emacs-render--make-block-id event))
         (specs nil)
         (images nil)
         (files nil))
    (prog1
        (when (dsh-emacs-render--user-authored-p event)
          ;; Attachments follow the body: every image is one compact thumbnail
          ;; in a wrapping gallery row, the same style whether the message
          ;; carries one image or several.  Files stay one static chip per
          ;; line.  An image gets a unique id so the asynchronous fill-in can
          ;; locate its slot.
          (let ((index 0))
            (dolist (block content)
              (pcase (dsh-protocol-content-block-kind block)
                ("image"
                 (setq index (1+ index))
                 (let ((id (format "%s-img-%d" block-id index)))
                   (setq specs (append specs (list (cons id block))))
                   (push (dsh-emacs-render--image-placeholder id block)
                         images)))
                ("file"
                 (push (dsh-emacs-render--file-placeholder block) files)))))
          (let ((gallery (and images (dsh-emacs-render--image-gallery
                                      (nreverse images))))
                (chips (and files (mapconcat #'identity (nreverse files)
                                             "\n"))))
            (when (or gallery chips)
              (setq text (concat text
                                 (and (not (string-empty-p text)) "\n")
                                 (mapconcat #'identity
                                            (delq nil (list gallery chips))
                                            "\n")))))
          (prog1
              (dsh-emacs-render--insert-chat-message
               text
               'dsh-emacs-user-block-face insert-point
               (format "%s-%s" (dsh-emacs-render--make-namespace) block-id)
               'user)
            (dolist (spec specs)
              (dsh-emacs-render--show-attachment (car spec) (cdr spec)))))
      ;; The injected copy itself is never rendered, but its source is the
      ;; host's evidence that NAME's `/name' gesture in the message above was
      ;; a skill: chip it even when the skill catalog is not fetched yet.
      (when-let* ((name (dsh-emacs-render--skill-invocation-name event)))
        (dsh-emacs-render--decorate-last-user-gesture name)))))

(defun dsh-emacs-render--skill-invocation-name (event)
  "Return the skill name EVENT injects, or nil when it is not an injection.
The host appends one hidden `user/message' per `/name' gesture it expanded
for a step, carrying `data.source = {kind: \"skill-invocation\", name: …}'
\(see dsh-tool-skill); the transcript reads it as evidence, never as text."
  (let ((message (dsh-protocol-message--from-alist event)))
    (when (equal (dsh-protocol-message-source-kind message) "skill-invocation")
      (dsh-protocol-message-source-name message))))

(defun dsh-emacs-render--last-user-message-region ()
  "Return (BEG . END) of the user message before the insertion point, or nil.
During a history prepend, search above the page's advancing insertion marker;
otherwise search above the composer."
  (let* ((anchor (or (dsh-emacs-render--input-insert-point) (point-max)))
         (end (previous-single-property-change anchor
                                               'dsh-emacs-user-message)))
    (when (and end (get-text-property (1- end) 'dsh-emacs-user-message))
      (cons (previous-single-property-change end 'dsh-emacs-user-message)
            end))))

(defun dsh-emacs-render--decorate-last-user-gesture (name)
  "Chip the `/NAME' gesture of the user message before the insertion point.
The injected copy NAME came from is not rendered, so the decoration lands on
the message the host scanned (see
`dsh-emacs-command-decorate-skill-gesture').  Nil when no user message is
before the insertion point — an isolated fixture, or a transcript whose block
was already rewritten."
  (when-let* ((region (dsh-emacs-render--last-user-message-region)))
    (dsh-emacs-command-decorate-skill-gesture (car region) (cdr region) name)))

(defconst dsh-emacs-render--goal-trigger-label "Continuing goal"
  "Transcript label of a goal round trigger (dsh web `message.trigger.goal').")

(defun dsh-emacs-render--goal-continuation-p (event)
  "Whether EVENT is the host's goal round continuation.
The goal round driver appends one `user/message' per automatic round to the
conversation surface, naming `data.source = {kind: \"goal\", goalId,
revision, round}' (see dsh-goal-round-driver).  dsh web paints such a message
as a turn-trigger notice (`TurnTriggerNodeView') instead of author text; the
transcript shows the same notice."
  (equal "goal"
         (dsh-protocol-message-source-kind
          (dsh-protocol-message--from-alist event))))

(defun dsh-emacs-render--note-inbox-splice (event)
  "Replay one `agent/inbox/spliced' EVENT for turn-trigger attribution.
Only the inbox queues matter: dsh web paints a non-human message as a
`turn-trigger' node when the latest claim admits it.  The next-turn claim
wakes any target; a next-step claim wakes only step 1 (the idle-steer rule
below).  A canceled removal admits nothing, and a requeued insertion leaves
the claim again (see the web `InboxState').  This keeps display-only state
and paints no row; returns EVENT's seq."
  (let ((seq (dsh-protocol-event-sequence--from-alist event)))
    (when-let* ((splice (dsh-protocol-inbox-splice--from-alist event))
                (target (dsh-protocol-inbox-splice-target splice))
                ((member target '("next-turn" "next-step"))))
      (let* ((pending (alist-get target dsh-emacs-render--inbox-pending
                                 nil nil #'equal))
             (start (min (max 0 (or (dsh-protocol-inbox-splice-start
                                     splice) 0))
                         (length pending)))
             (removed-count (max 0 (or (dsh-protocol-inbox-splice-removed-count
                                        splice) 0)))
             (end (min (length pending) (+ start removed-count)))
             (removed (cl-subseq pending start end))
             (kept (append (cl-subseq pending 0 start)
                           (cl-subseq pending end)))
             (at (min start (length kept)))
             (inserted (dsh-protocol-inbox-splice-inserted splice)))
        (setf (alist-get target dsh-emacs-render--inbox-pending nil nil #'equal)
              (append (cl-subseq kept 0 at) inserted (cl-subseq kept at)))
        ;; dsh web's `withoutInserted': a requeued id is not claimed.
        (let ((claim (alist-get target dsh-emacs-render--inbox-claim
                                nil nil #'equal)))
          (when claim
            (dolist (entry inserted)
              (setf (plist-get claim :entries)
                    (delete (assoc (car entry) (plist-get claim :entries))
                            (plist-get claim :entries))))))
        (when (and (> removed-count 0)
                   (not (equal (dsh-protocol-inbox-splice-outcome splice)
                               "canceled")))
          ;; A page cut can drop the insertion but keep the claim; remember
          ;; that the removed batch could not be materialized.
          (setf (alist-get target dsh-emacs-render--inbox-claim
                           nil nil #'equal)
                (list :seq seq :entries removed
                      :human (cl-some (lambda (entry)
                                        (equal (cdr entry) "user"))
                                      removed)
                      :truncated (< (length pending)
                                    (+ start removed-count))))
          ;; The host claims before step 1 opens, so these removals are the
          ;; turn's opening batch even when the page cut lost their entries.
          (when (and dsh-emacs-render--turn-start-seq
                     (null dsh-emacs-render--turn-step))
            (setq dsh-emacs-render--turn-claim-slots
                  (+ (or dsh-emacs-render--turn-claim-slots 0)
                     removed-count))))))
    seq))

(defun dsh-emacs-render--claimed-p (target id)
  "Whether ID is in TARGET's latest inbox claim."
  (when-let* ((claim (alist-get target dsh-emacs-render--inbox-claim
                                nil nil #'equal)))
    (and (assoc id (plist-get claim :entries)) t)))

(defun dsh-emacs-render--idle-steer-p (id)
  "Whether ID is a non-human notice claimed into step 1 of this turn.
dsh web's idle-steer rule: a step-1 claim after the turn started, no
next-turn claim in that turn, and no human input in the same batch.  Without
it a child message admitted while the parent is idle would wake a turn whose
only attribution is hidden."
  (when-let* ((turn-start dsh-emacs-render--turn-start-seq)
              ((equal dsh-emacs-render--turn-step 1))
              (claim (alist-get "next-step" dsh-emacs-render--inbox-claim
                                nil nil #'equal))
              (claim-seq (plist-get claim :seq))
              ((integerp claim-seq))
              ((> claim-seq turn-start))
              ((not (plist-get claim :human))))
    (let ((next-turn (alist-get "next-turn" dsh-emacs-render--inbox-claim
                                nil nil #'equal)))
      (and (or (null next-turn)
               (let ((seq (plist-get next-turn :seq)))
                 (or (not (integerp seq)) (< seq turn-start))))
           (assoc id (plist-get claim :entries))
           t))))

(defconst dsh-emacs-render--waking-source-kinds
  '("agent-message" "team-message" "subagent-settled" "webhook" "schedule"
    "tool-jobs" "cordis-host-runner")
  "Non-human sources known to wake a turn.
The opener fallback uses this list so a truncated claim cannot turn a
runtime-context or other injection into invented attribution.")

(defun dsh-emacs-render--turn-opener-p ()
  "Whether the current turn's opening input has not painted a row yet."
  (and dsh-emacs-render--turn-start-seq
       (not dsh-emacs-render--turn-opener-painted)))

(defun dsh-emacs-render--truncated-claim-p ()
  "Whether a claim made in this turn lost its queued messages.
A history page can begin after the insertion that queued a notice; its claim
then removes nothing and cannot name the admitted id.  Only a message in the
turn's opening claim batch may use the fallback, and only for a known waking
source."
  (when-let* ((turn-start dsh-emacs-render--turn-start-seq))
    (cl-some
     (lambda (target)
       (let ((claim (alist-get target dsh-emacs-render--inbox-claim
                               nil nil #'equal)))
         (and claim
              (plist-get claim :truncated)
              (let ((seq (plist-get claim :seq)))
                (and (integerp seq) (> seq turn-start))))))
     '("next-turn" "next-step"))))

(defun dsh-emacs-render--turn-trigger-p (event)
  "Whether EVENT is a non-human message claimed to open a turn.
Mirrors dsh web's `turn-trigger' node: a `user/message' whose source is not
`user' and whose id the latest next-turn claim admits, or the idle step-1
next-step claim.  When a page cut kept the claim but lost the insertion, the
turn's first known waking input within the opening claim batch still gets the
row instead of reappearing as an orphan Completed summary.  The goal round
keeps its own notice; every other injection that did not wake a turn stays
hidden."
  (when-let* ((message (dsh-protocol-message--from-alist event))
              (id (dsh-protocol-message-id message))
              (kind (dsh-protocol-message-source-kind message)))
    (and (not (equal kind "user"))
         (not (equal kind "goal"))
         (or (dsh-emacs-render--claimed-p "next-turn" id)
             (dsh-emacs-render--idle-steer-p id)
             (and (member kind dsh-emacs-render--waking-source-kinds)
                  (dsh-emacs-render--turn-opener-p)
                  (> (or dsh-emacs-render--turn-claim-slots 0) 0)
                  (dsh-emacs-render--truncated-claim-p))))))

(defun dsh-emacs-render--turn-trigger-title (message)
  "Return dsh web's trigger title for MESSAGE's recorded source.
The source family is named, not inferred: an unknown or malformed source
falls back to `Execution requested' without claiming an identity."
  (pcase (dsh-protocol-message-source-kind message)
    ("agent-message" "Task message received")
    ("team-message" "Team message received")
    ("subagent-settled" "Subtask status updated")
    ("webhook" (if (equal (dsh-protocol-message-source-provider message)
                          "github")
                   "GitHub event received"
                 "External event received"))
    ("schedule" "Automation task")
    ("tool-jobs" "Background task updated")
    ("cordis-host-runner" "Plugin status updated")
    (_ "Execution requested")))

(defun dsh-emacs-render--trigger-body (event)
  "Return EVENT's model-facing notice text, or nil.
Adjacent text blocks join with no separator, as the provider flattens them
\(matching dsh web's context body), so an injected `Agent … sent a message: '
prefix stays on the sentence the child sent."
  (let ((text (mapconcat
               #'identity
               (delq nil
                     (mapcar #'dsh-protocol-content-block-text
                             (cl-remove-if-not
                              (lambda (block)
                                (equal (dsh-protocol-content-block-kind block)
                                       "text"))
                              (dsh-protocol-message-content
                               (dsh-protocol-message--from-alist event)))))
               "")))
    (unless (string-empty-p text) text)))

(defun dsh-emacs-render--trigger-block (event label icon prefix status)
  "Insert EVENT as a collapsed trigger notice named LABEL.
ICON leads LABEL, PREFIX keys the fragment and STATUS separates the goal
round from another turn trigger.  The model-facing body stays folded until
inspected; an empty body leaves the row unfoldable."
  (let ((body (dsh-emacs-render--trigger-body event))
        (time (dsh-emacs-render--event-time event)))
    (dsh-emacs-ui-update-fragment
     (dsh-emacs-ui-make-fragment
      :namespace-id (dsh-emacs-render--make-namespace)
      :block-id (format "%s-%s" prefix (dsh-emacs-render--make-block-id event))
      :label-left (concat icon " "
                          (propertize label
                                      'face (dsh-emacs-render--row-label-face
                                             'dsh-emacs-meta-face)))
      :label-right (and time
                        (propertize time 'face 'dsh-emacs-timestamp-face))
      :body body
      :style 'minimal
      :status status
      :non-foldable (null body)
      :padding t)
     :create-new t :expanded nil
     :insert-before (dsh-emacs-render--input-insert-point))))

(defun dsh-emacs-render--goal-trigger-block (event)
  "Insert EVENT's goal round continuation as a collapsed trigger notice.
Mirrors dsh web's `TurnTriggerNodeView': the goal dartboard, `Continuing
goal' and the event clock over the injected round prompt, folded by default
so the model-facing `<goal_round>' instruction stays out of the way until
inspected.  An empty body leaves the row unfoldable."
  (dsh-emacs-render--trigger-block
   event dsh-emacs-render--goal-trigger-label
   (dsh-emacs-render--goal-trigger-icon) "goal" 'goal-trigger))

(defun dsh-emacs-render--turn-trigger-block (event)
  "Insert EVENT as dsh web's turn-trigger notice.
A non-human message claimed to open a turn is attribution, not conversation:
the row names the source family, carries the event clock and folds the
recorded notice body until inspected.  Showing it keeps the turn's
`Completed in …' summary from reading as an unprompted reply."
  (dsh-emacs-render--trigger-block
   event
   (dsh-emacs-render--turn-trigger-title
    (dsh-protocol-message--from-alist event))
   (dsh-emacs-render--turn-trigger-icon) "trigger" 'turn-trigger))

(defun dsh-emacs-render-user-message (event &optional references)
  "Render a `user/message' event with a left rail and the user block face.
The block gets two blank lines before and one after (see
`dsh-emacs-render--insert-chat-message' and
`dsh-emacs-ui--blank-above-preserve').
Image content blocks render below the text like dsh web's message gallery:
every image is a compact thumbnail in wrapping rows (four text lines tall by
default), whether the message carries one image or several.
Inline base64 shows immediately, attachment refs fill in when
`session/attachment' settles (see `dsh-emacs-render--show-attachment') and
RET or mouse-1 opens the original.  File content blocks render as
display-only `[file: name · size]' lines (see
`dsh-emacs-render--file-placeholder').
A host-injected goal round continuation renders its trigger notice; a
non-human message an inbox claim woke renders dsh web's turn-trigger notice
\(see `dsh-emacs-render--goal-trigger-block' and
`dsh-emacs-render--turn-trigger-block').  Optional REFERENCES (list of
\(LABEL . SESSION-ID)) from the immediately following `session-reference'
recall event lets the readable `@label' session tokens the server persisted
\(canonical id stripped) render as real session chips; see
`dsh-emacs-reference-fontify'.  Returns the event seq."
  (let ((painted
         (cond
          ((dsh-emacs-render--goal-continuation-p event)
           (dsh-emacs-render--goal-trigger-block event)
           t)
          ((dsh-emacs-render--turn-trigger-p event)
           (dsh-emacs-render--turn-trigger-block event)
           t)
          (t (dsh-emacs-render--insert-user-block event references)))))
    (when (and dsh-emacs-render--turn-start-seq painted)
      (setq dsh-emacs-render--turn-opener-painted t))
    (when (and dsh-emacs-render--turn-start-seq
               (integerp dsh-emacs-render--turn-claim-slots)
               (> dsh-emacs-render--turn-claim-slots 0))
      (setq dsh-emacs-render--turn-claim-slots
            (1- dsh-emacs-render--turn-claim-slots))))
  (dsh-protocol-event-sequence--from-alist event))

(defun dsh-emacs-render-delete-user-message (start end)
  "Delete the user message from START to END and reconcile reply footers.
Removing an optimistic echo can merge groups that completed while its
submission was pending.  Reply text and per-turn facts remain unchanged."
  (let ((inhibit-read-only t)
        (buffer-undo-list t))
    (delete-region start end))
  (when dsh-emacs-render--reply-turns
    (maphash #'dsh-emacs-render--reply-footer dsh-emacs-render--reply-turns)))

;;; ---------------------------------------------------------------------------
;;; Renderer: assistant messages
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-render-assistant-message (event)
  "Render an `assistant/message' event with an assistant background color."
  (let* ((seq (dsh-protocol-event-sequence--from-alist event))
         (message (dsh-protocol-message--from-alist event :assistant t))
         (content (dsh-protocol-message-content message))
         (text (dsh-emacs-render--text-from-content content))
         (reasoning (dsh-emacs-render--reasoning-from-content content))
         (key (dsh-protocol-stream-key--from-alist event))
         (ns (dsh-emacs-render--make-namespace))
         (block-id (dsh-emacs-render--make-block-id event))
         (step (dsh-emacs-render--step-record key))
         ;; If reasoning arrives only in the final message, reserve its
         ;; position before text is inserted or its live markers released.
         (reasoning-position
          (when (and dsh-emacs-show-thinking (not (string-empty-p reasoning)))
            (copy-marker
             (or (plist-get (car (last (plist-get step :text-regions))) :start)
                 (and (equal key (plist-get dsh-emacs--streaming-assistant
                                            :key))
                      (plist-get dsh-emacs--streaming-assistant :start))
                 (dsh-emacs-render--input-insert-point) (point-max)) nil))))
    ;; Blocks already folded into Think fragments or finished assistant
    ;; bodies are left alone: only the remainder is rendered here.
    (when (dsh-emacs-render--thinking-stream-alive-for-p key)
      (dsh-emacs-render--close-live-thinking-block))
    (unless (dsh-emacs-render--finish-assistant-stream event text step)
      (let* ((committed (or (plist-get step :text) ""))
             (todo (dsh-emacs-render--uncommitted-content committed text)))
        (unless todo
          (let ((inhibit-read-only t)
                (buffer-undo-list t))
            (dsh-emacs-render--drop-committed-text step))
          (setq todo text))
        (unless (string-empty-p todo)
          ;; An older-history page renders synchronously: it is settled text,
          ;; so it must not join the buffer's idle queue — that queue is how a
          ;; live stream formats its tail, and page jobs would compete with it.
          (let* ((defer (and (not (dsh-emacs-render--history-page-p))
                             dsh-emacs-stream-markdown-limit
                             (> (length todo) dsh-emacs-stream-markdown-limit)))
                 (event-id (format "%s-%s" ns block-id))
                 (body (if defer
                           (if (string-suffix-p "\n" todo) todo (concat todo "\n"))
                         (dsh-emacs-markdown-render todo)))
                 (range (dsh-emacs-render--insert-chat-message
                         body 'dsh-emacs-assistant-body-face
                         (dsh-emacs-render--input-insert-point) event-id
                         'assistant)))
            (let ((inhibit-read-only t)
                  (buffer-undo-list t))
              (put-text-property (car range) (cdr range)
                                 'dsh-emacs-message-seq seq))
            (when defer
              (dsh-emacs-render--stream-render-region
               (list :start (copy-marker (car range))
                     :end (copy-marker (cdr range) nil)
                     :event-id event-id :seq seq :render-final nil
                     :markdown (list :scan nil :pending nil :kind nil :watermark nil))
               nil t))))))
    ;; Finish text before replacing earlier fragments: removing a Think row
    ;; can put the following text's start at the insertion boundary. Active
    ;; text repair must not mistake the replacement Think for its own body.
    (cond
     ;; Inline style: keep one row per streamed block where it appeared.  Only
     ;; a block added or removed by the correction falls back to the folded
     ;; row, which then still sits before the answer.
     ((and (eq dsh-emacs-thinking-style 'inline)
           dsh-emacs-show-thinking
           (plist-get step :thinking-regions)
           (dsh-emacs-render--reconcile-inline-thinking step content)))
     ((not (equal (plist-get step :reasoning) reasoning))
      ;; The `expand' style replaces the old fragments where they first
      ;; appeared, rather than appending the corrected body after text.
      (let ((position (dsh-emacs-render--drop-committed-thinking step)))
        (when (and dsh-emacs-show-thinking (not (string-empty-p reasoning)))
          (dsh-emacs-render--render-thinking-block
           ns block-id reasoning
           (or position reasoning-position))))))
    (when reasoning-position (set-marker reasoning-position nil))
    ;; Deferred jobs retain their markers until their idle render completes.
    (dolist (state (plist-get step :text-regions))
      (setf (plist-get state :seq) seq)
      (when seq
        (let ((inhibit-read-only t)
              (buffer-undo-list t))
          (put-text-property (plist-get state :start) (plist-get state :end)
                             'dsh-emacs-message-seq seq)))
      (unless (memq state dsh-emacs--markdown-pending)
        (dsh-emacs-render--reset-markdown-state state)
        (set-marker (plist-get state :start) nil)
        (set-marker (plist-get state :end) nil)))
    (setq dsh-emacs--streamed-step nil)
    seq))

(defun dsh-emacs-render--render-thinking-block
    (namespace-id block-id text insert-point &optional update running)
  "Render a collapsible <details>-style thinking block.
UPDATE refreshes the existing block while preserving its fold state.
RUNNING selects the live preview (latest completed paragraph); otherwise the
settled preview names the first sentence.  A new row starts collapsed."
  (dsh-emacs-ui-update-fragment
   (dsh-emacs-ui-make-fragment
    :namespace-id namespace-id
    :block-id block-id
    :label-left (concat
                 ;; The completed fragment outlives the live stream.  In
                 ;; `simple' its dot settles to the same muted grey as the
                 ;; label; `full' keeps the thinking accent.
                 (propertize (dsh-emacs-render--think-icon)
                             'face (if (eq dsh-emacs-render-style 'simple)
                                       'dsh-emacs-event-row-face
                                     'dsh-emacs-thinking-face))
                 (propertize " Think"
                             'face (dsh-emacs-render--row-label-face
                                    'dsh-emacs-thinking-face)))
    ;; No clock fallback: dsh web's row is the label alone without a preview.
    :label-right (if running
                    (dsh-emacs-render--thinking-live-preview text)
                  (dsh-emacs-render--thinking-preview text))
    ;; A deferred body keeps a collapsed live row cheap: minimal fragments do
    ;; not render a function body until the reader expands it.
    :body (if running
              (let ((running-text text))
                (lambda () running-text))
            text)
    :style 'minimal
    :status 'thinking
    ;; Reasoning text is muted in both styles: the header chrome (separator +
    ;; preview) and the body share the body face.  In `full' the label keeps
    ;; the thinking accent above it; `simple' leaves it neutral.
    :header-face 'dsh-emacs-thinking-body-face
    :body-face 'dsh-emacs-thinking-body-face)
   :create-new (not update)
   :insert-before insert-point))

;;; ---------------------------------------------------------------------------
;;; Renderer: todo plan rows (one line per event, like a tool card)
;;; ---------------------------------------------------------------------------
;;; dsh's `todo_write' tool carries a full replacement snapshot of the whole
;;; list every time ([{content, status}]).  Each snapshot renders **one**
;;; independent collapsible fragment in the chat transcript (namespace "todo",
;;; block-id = call-id), stacked line by line in time order like tool events
;;; rather than living in one block updated in place.  An empty list renders no
;;; row at all.

(defconst dsh-emacs--todo-namespace "todo"
  "Namespace for the rendered todo (plan) rows.")

(defvar-local dsh-emacs--todo-list nil
  "Latest whole todo list snapshot as (\"content\" . \"status\") cells, or nil.
nil (or empty) means there is no plan yet.")

(defun dsh-emacs-render--todo-counts (list)
  "Return (DONE ACTIVE PENDING) counts for LIST of (\\\"content\\\" . STATUS) cells."
  (let ((done 0) (active 0))
    (dolist (cell list)
      (pcase (cdr cell)
        ("completed" (setq done (1+ done)))
        ("in_progress" (setq active (1+ active)))))
    (list done active (max 0 (- (length list) done active)))))

(defun dsh-emacs-render--todo-summary (list)
  "Compact progress label for LIST, e.g. \\\"2/5 completed · 1 in progress\\\".
Zero-count segments are omitted (a non-empty list keeps at least one)."
  (let* ((counts (dsh-emacs-render--todo-counts list))
         (done (nth 0 counts))
         (active (nth 1 counts))
         (pending (nth 2 counts))
         (total (length list))
         (parts '()))
    (when (> done 0) (push (format "%d/%d completed" done total) parts))
    (when (> active 0) (push (format "%d in progress" active) parts))
    (when (> pending 0) (push (format "%d pending" pending) parts))
    (mapconcat #'identity (nreverse parts) " · ")))

(defun dsh-emacs-render--todo-glyph (status)
  "Checkbox glyph for STATUS: ☑ (completed), ☐ (pending/in progress)."
  (pcase status
    ("completed" "☑")
    (_ "☐")))

(defun dsh-emacs-render--todo-glyph-face (_status)
  "Face for the STATUS checkbox glyph (green, per dsh web's plan checkbox)."
  'dsh-emacs-todo-check-face)

(defun dsh-emacs-render--todo-body (list)
  "Render LIST as a multi-line checkbox string, one `☑|☐ CONTENT — STATUS'
line per item.  The checkbox glyph carries `dsh-emacs-todo-check-face' (green);
`split-string' preserves these text properties through the fragment body
renderer.  `line-spacing' is pinned to 0 so a theme's line-spacing does not
spread the rows apart (each todo is one line)."
  (propertize
   (mapconcat
    (lambda (cell)
      (let* ((status (cdr cell))
             (glyph (propertize (dsh-emacs-render--todo-glyph status)
                                'face (dsh-emacs-render--todo-glyph-face status)))
             (word (pcase status
                     ("completed" "completed")
                     ("in_progress" "in progress")
                     (_ "pending"))))
        (concat "  " glyph " " (car cell) " — " word)))
    list
    "\n")
   'line-spacing 0))

(defun dsh-emacs-render--todo-block-id (call-id)
  "Return the per-event block-id of a todo row with CALL-ID."
  (or call-id "unknown"))

(defun dsh-emacs-render--todo-row (list call-id)
  "Render one todo row for the whole snapshot LIST at the event's position.
Like a tool card, each `todo_write' snapshot gets its own collapsible row in
the transcript; a nil/empty LIST or `dsh-emacs-show-todos' nil renders nothing."
  (when (and dsh-emacs-show-todos list (car list))
    (let* ((insert-point (dsh-emacs-render--input-insert-point))
           (summary-only dsh-emacs-todo-summary-only)
           (sum (dsh-emacs-render--todo-summary list))
           (body (unless summary-only (dsh-emacs-render--todo-body list)))
           ;; Title + summary in the todo green accent in `full'; `simple'
           ;; leaves them neutral so only the leading dot carries color.
           ;; Separator: one space each side.
           (label-face (dsh-emacs-render--row-label-face
                        'dsh-emacs-todo-text-face))
           (label (concat (dsh-emacs-render--todo-icon) " "
                          (propertize dsh-emacs-todo-title 'face label-face)
                          " · "
                          (propertize sum 'face label-face))))
      (dsh-emacs-ui-update-fragment
       (dsh-emacs-ui-make-fragment
        :namespace-id dsh-emacs--todo-namespace
        :block-id (dsh-emacs-render--todo-block-id call-id)
        :label-left label
        :label-right nil
        :body body
        :style 'minimal
        :status 'tool-pending
        :non-foldable (and summary-only t))
       :expanded dsh-emacs-todo-expand-by-default
       :insert-before insert-point))))

(defun dsh-emacs-render-todo-clear ()
  "Clear the latest todo snapshot state.  Rendered todo rows stay in the
transcript; they are removed with the buffer on a session reset/replay."
  (setq dsh-emacs--todo-list nil))

;;; ---------------------------------------------------------------------------
;;; Renderer: tool call
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-render--tool-call-block-id (tool-call-id)
  "Return a stable block-id for TOOL-CALL-ID (so we can update it later)."
  (format "tool-%s" tool-call-id))

(defun dsh-emacs-render--plan-text (name arguments)
  "Read NAME's decoded Plan document, reporting malformed JSON."
  (when (and (equal name "exit_plan_mode") (stringp arguments))
    (let* ((document
            (condition-case err
                (dsh-protocol-plan-document--from-alist arguments :json-p t)
              (json-error
               (message "Invalid plan document: %s" (error-message-string err))
               nil)))
           (text (and document (dsh-protocol-plan-document-text document))))
      (and (stringp text) (not (string-empty-p (string-trim text))) text))))

(defun dsh-emacs-render--open-plan (button)
  "Open the historical document carried by BUTTON."
  (pop-to-buffer
   (dsh-emacs-plan--show
    (current-buffer) (button-get button 'dsh-emacs-plan--call-id)
    (button-get button 'dsh-emacs-plan--markdown))))

(defun dsh-emacs-render--plan-card (call-id text &optional status detail)
  "Render CALL-ID's TEXT as a persistent document link with STATUS and DETAIL."
  (let* ((ns (dsh-emacs-render--make-namespace))
         (label (concat "Plan: " (dsh-emacs-plan--title text)))
         (link (with-temp-buffer
                 (insert-text-button label 'follow-link t
                                     'action #'dsh-emacs-render--open-plan
                                     'dsh-emacs-plan--call-id call-id 'dsh-emacs-plan--markdown text)
                 (buffer-string))))
    (dsh-emacs-render--set-tool-state call-id :plan-text text)
    (dsh-emacs-ui-update-fragment
     (dsh-emacs-ui-make-fragment
      :namespace-id ns :block-id (dsh-emacs-render--tool-call-block-id call-id)
      :label-left link :label-right (or status "Open plan")
      :body detail :style 'minimal :non-foldable t)
     :create-new (null status) :expanded t
     :insert-before (dsh-emacs-render--input-insert-point))))

(defun dsh-emacs-render--pending-tool-body
    (variant name args body-text questions)
  "Format a pending card from VARIANT, NAME, ARGS, BODY-TEXT and QUESTIONS."
  (cond (questions (dsh-emacs-render--ask-body questions nil nil))
        ((equal variant "bash")
         (or (dsh-emacs-render--bash-card-body body-text) body-text))
        ((member variant '("write" "edit"))
         (or (dsh-emacs-render--diff-card-body name args nil 'pending) body-text))
        (t body-text)))

(defun dsh-emacs-render-tool-call (event)
  "Render a `tool/call' EVENT and return its seq, or nil when hidden.
Todo snapshots still apply when ordinary tool cards are hidden."
  (pcase-let* (((cl-struct dsh-protocol-tool-call name call-id (arguments args))
                (dsh-protocol-tool-call--from-alist
                 event :event-p t))
               (seq (dsh-protocol-event-sequence--from-alist event))
               (plan-text (and dsh-emacs-show-tool-calls
                               (dsh-emacs-render--plan-text name args))))
    (cond
     (plan-text
      (dsh-emacs-render--plan-card call-id plan-text)
      seq)
     ((equal name "todo_write")
      (setq dsh-emacs--todo-list (dsh-protocol-todos--from-alist args))
      (dsh-emacs-render--todo-row dsh-emacs--todo-list
                                  (or call-id (format "seq-%s" seq)))
      seq)
     ((not dsh-emacs-show-tool-calls) nil)
     (t
      (let* ((variant-info (dsh-emacs-render--tool-variant name))
             (variant (car variant-info))
             (icon (cdr variant-info))
             (arguments (dsh-protocol-tool-arguments--from-alist
                         args name variant))
             (header (dsh-emacs-render--tool-header name variant arguments))
             (title (car header))
             ;; An ask call's questions were decoded from its arguments:
             ;; its row states which stage the question set is in, and its
             ;; body is the questionnaire (see the ask card section).  The
             ;; variant is the gate, like the bash and write/edit cards.
             (ask-questions (and (equal variant "question")
                                 (dsh-protocol-ask-questions--from-alist args)))
             (summary (or (and ask-questions
                               (dsh-emacs-render--ask-summary
                                nil nil nil))
                          (cdr header)))
             (body-text (dsh-emacs-render--tool-body-text arguments))
             (display-body
              (apply-partially #'dsh-emacs-render--pending-tool-body
                               variant name args body-text ask-questions))
             (ns (dsh-emacs-render--make-namespace))
             (insert-point (dsh-emacs-render--input-insert-point))
             (ts (dsh-emacs-render--event-time event))
             (label-left (concat icon " "
                                 (propertize title
                                     'face (dsh-emacs-render--row-label-face
                                            'dsh-emacs-tool-title-face))))
             (label-right (or summary ""))
             (block-id (dsh-emacs-render--tool-call-block-id call-id)))
        ;; Track state for later (tool/result will update this block).
        (dsh-emacs-render--set-tool-state
         call-id :state 'pending :variant variant :icon icon :title title
         :name name :args body-text :args-raw args
         :summary summary :call-time ts :ns ns)
        (dsh-emacs-ui-update-fragment
         (dsh-emacs-ui-make-fragment
          :namespace-id ns
          :block-id block-id
          :label-left label-left
          :label-right label-right
          :body display-body
          :style 'minimal
          :status 'tool-pending
          ;; In `full', the state tint covers the header row only, never the
          ;; body; `simple' keeps the header neutral for the colored dot.
          :header-face (dsh-emacs-render--row-chrome-face
                        'dsh-emacs-tool-pending-face))
         :create-new t
         :expanded dsh-emacs-tool-expand-by-default
         :insert-before insert-point))
      seq))))

;;; ---------------------------------------------------------------------------
;;; Renderer: tool result (bash terminal card / ioCard for other tools)
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-render--tool-leading (icon state)
  "Leading glyph for a tool row, mirroring dsh web's `leadingFor`:
ok/running keep the variant ICON; error/stopped are overridden by a
colored status dot (red / warning-yellow).
With `dsh-emacs-render-style' `simple', every state uses one dot:
pending keeps the tool accent, success is green, error red, and stopped
takes the interrupted face."
  (if (eq dsh-emacs-render-style 'simple)
      (concat (dsh-emacs-render--simple-icon
               (pcase state
                 ('success 'dsh-emacs-tool-success-face)
                 ('error 'dsh-emacs-tool-error-face)
                 ('stopped 'dsh-emacs-tool-stopped-face)
                 (_ 'dsh-emacs-tool-icon-face)))
              " ")
    (pcase state
      ('error  "● ")
      ('stopped "◐ ")
      (_ (concat icon " ")))))

(defconst dsh-emacs-render--tool-io-label-width 3
  "Width of the generic ioCard's section-label column.
`IN' is padded to this width so both labels leave their text at the same
column (`IN  foo' above `OUT bar'), and continuation lines align there too.")

(defun dsh-emacs-render--tool-io-rows (label text)
  "Return the ioCard rows for section LABEL and its TEXT.
The label opens the first row in the section-label column; every following
line of TEXT hangs at the shared text column.  LABEL carries
`dsh-emacs-tool-io-face'; TEXT stays unstyled."
  (let* ((lines (split-string text "\n"))
         (text-column (+ 2 dsh-emacs-render--tool-io-label-width 1))
         (hang (make-string text-column ?\s)))
    (cons (concat "  "
                  (propertize label 'face 'dsh-emacs-tool-io-face)
                  (make-string (- dsh-emacs-render--tool-io-label-width
                                  (length label))
                               ?\s)
                  " "
                  (car lines))
          (mapcar (lambda (line) (concat hang line)) (cdr lines)))))

(defun dsh-emacs-render--tool-io-inline (text)
  "Flatten TEXT to one display line for the ioCard's IN section.
Newlines and runs of whitespace collapse to single spaces, so a
pretty-printed argument object reads as one compact row.  A value wider than
the card box is ellipsized and keeps the full text as a `help-echo' tooltip —
the treatment the bash card gives an over-long command — so the IN row never
grows the block and the OUT rows below it stay where the eye expects them."
  (let* ((flat (string-trim
                (replace-regexp-in-string
                 "[ \t]+" " "
                 (replace-regexp-in-string "[\n\r]+" " " text))))
         (limit (max 20 (- (dsh-emacs-ui--box-width) 8))))
    (if (> (string-width flat) limit)
        (let ((short (truncate-string-to-width flat limit nil nil "…")))
          (put-text-property 0 (length short) 'help-echo flat short)
          short)
      flat)))

(defun dsh-emacs-render--tool-body-io (in-text out-text &optional status-text)
  "Compose the expanded tool body from IN-TEXT (args) and OUT-TEXT (result).
Mirrors dsh web's ioCard as one aligned block: the `IN` and `OUT` labels sit
in a shared label column, their text in a shared text column, and a thin `─'
divider sized to the content separates the sections.  The block is indented
like the bash terminal card, so rows of either kind keep one left edge.

The `IN` arguments read as ONE row (flattened and ellipsized, see
`dsh-emacs-render--tool-io-inline'); the `OUT` result keeps its own lines,
hanging at the text column.

STATUS-TEXT, when non-empty, is a leading line — callers pass it only for a
failed or interrupted call, because a clean success carries no status text
outside the bash card (dsh web's exit-0 pill never renders).

A zero-argument body (`{}`/`[]`) drops the IN section instead of printing an
empty pair of braces, so such a card shows its result alone.  Section labels
and the divider carry their own faces; the args/output text stays unstyled —
the tool's state face belongs to the header row, not the body."
  (let* ((trimmed-in (and (stringp in-text) (string-trim in-text)))
         (in-rows (and trimmed-in
                       (not (member trimmed-in '("{}" "[]")))
                       (dsh-emacs-render--tool-io-rows
                        "IN" (dsh-emacs-render--tool-io-inline trimmed-in))))
         (out-text (and (stringp out-text)
                        (not (string-empty-p (string-trim out-text)))
                        (string-trim-right out-text "\n")))
         (out-rows (and out-text (dsh-emacs-render--tool-io-rows "OUT" out-text)))
         (divider (when (and in-rows out-rows)
                    (let ((content-width (apply #'max 0
                                                (mapcar #'string-width
                                                        (append in-rows
                                                                out-rows)))))
                      (concat "  "
                              (propertize
                               (make-string
                                (min 80 (max 4 (- content-width 2))) ?─)
                               'face 'dsh-emacs-divider-face)))))
         (status (and (stringp status-text)
                      (not (string-empty-p status-text))
                      (concat "  " status-text))))
    (mapconcat #'identity
               (append (and status (list status))
                       in-rows
                       (and divider (list divider))
                       out-rows)
               "\n")))

(defun dsh-emacs-render--tool-status-text (state exit-code signal &optional reason)
  "Short human status for STATE/EXIT-CODE/SIGNAL, or nil.
REASON is a failed `tool/result' error's raw user-facing explanation —
the dsh 0.1.6 `error.reason', which the host keeps OUTSIDE the
model-facing message — and is appended to the error status so a refused
call explains itself instead of showing a bare `✗ failed'."
  (let* ((base (pcase state
                 ('success (format "✓ exit %s" (or exit-code "0")))
                 ('error (cond
                          ((and (integerp exit-code) (/= exit-code 0))
                           (format "✗ exit %d" exit-code))
                          (signal (format "✗ signal %s" signal))
                          (t "✗ failed")))
                 ('stopped "⏸ interrupted")
                 (_ nil)))
         (reason (and (stringp reason)
                      (replace-regexp-in-string
                       "[[:space:][:cntrl:]]+" " " (string-trim reason)))))
    (cond ((null base) nil)
          ((and reason (not (string-empty-p reason)) (eq state 'error))
           (concat base " — " reason))
          (t base))))

(defun dsh-emacs-render--bash-command (args-text)
  "Return the shell command inside ARGS-TEXT, or nil.
ARGS-TEXT is the rendered body of a tool call
(`dsh-emacs-render--tool-body-text'); a bash/pwsh call carries the command
prefixed with \"$ \".  Anything else (pretty-printed JSON from a malformed
call, no command key) yields nil, so callers keep the generic ioCard."
  (when (and (stringp args-text) (string-prefix-p "$ " args-text))
    (let ((command (string-trim (substring args-text 2))))
      (and (not (string-empty-p command)) command))))

(defun dsh-emacs-render--bash-command-line (command)
  "Return COMMAND (possibly multi-line) flattened to ONE display line.
Internal newlines and runs of whitespace collapse to single spaces, and
anything longer than the card's command width is truncated with \"…\" — a
script or backslash-wrapped pipeline never grows the card's command block
past a single row.  Returns nil for an empty COMMAND."
  (when (and (stringp command) (not (string-empty-p command)))
    (let* ((flat (string-trim
                  (replace-regexp-in-string
                   "[ \t]+" " "
                   (replace-regexp-in-string "[\n\r]+" " " command))))
           (limit (max 20 (- (dsh-emacs-ui--box-width) 4))))
      (if (> (string-width flat) limit)
          (truncate-string-to-width flat limit nil nil "…")
        flat))))

(defun dsh-emacs-render--bash-card-body (args-text &optional out-text state exit-code signal reason)
  "Compose the expanded body of a bash/pwsh tool row as a terminal card.
Mirrors dsh web's TerminalBlock inside BashRow: a single `$' prompt row for
the command (see `dsh-emacs-render--bash-command-line' — one line, overflow
ellipsized), a hairline divider, then the raw output below.  A failure or
interrupt appends a state-colored footer (`✗ exit 1', `✗ signal …',
`⏸ interrupted'); a clean exit (0, no signal) ends bare at the output, like
the web card whose exit-0 pill never renders.

ARGS-TEXT is the rendered call body (\"$ <command>\" for a bash call) from
`dsh-emacs-render--tool-body-text'; OUT-TEXT is the full result text.
STATE/EXIT-CODE/SIGNAL follow `dsh-emacs-render--tool-status-text'; REASON
is that status helper's optional failed-result explanation.  A nil
STATE (call still running) draws the prompt row only (no output yet, so no
divider either).

When the one-line prompt is elided, the row carries the full raw command as
a `help-echo' tooltip.  Faces are baked onto the returned string so
fold/unfold preserves the styling.  Returns nil when ARGS-TEXT carries no
\"$ \" command — callers then keep the generic ioCard.  Rows are drawn on the
transcript background with no card surface band, and are not padded to the
box width."
  (let* ((raw-cmd (dsh-emacs-render--bash-command args-text))
         (cmd-line (dsh-emacs-render--bash-command-line raw-cmd))
         (raw-out (and (stringp out-text)
                       (not (string-empty-p out-text))
                       (string-trim-right out-text "\n")))
         (out-lines (and raw-out (split-string raw-out "\n")))
         ;; A clean settle shows no footer: the header's green state tint
         ;; already says "done", and exit 0 carries no news to print.
         (status-text (and (memq state '(error stopped))
                           (dsh-emacs-render--tool-status-text
                            state exit-code signal reason))))
    (when cmd-line
      (let* ((prompt-row (concat "  "
                                 (propertize "$ " 'face
                                             'dsh-emacs-tool-bash-prompt-face)
                                 cmd-line))
             (out-rows (mapcar (lambda (line) (concat "  " line)) out-lines))
             ;; The prompt row doubles as the full-command tooltip whenever
             ;; the visible line is elided (flattened or truncated).
             (prompt-row (if (equal raw-cmd cmd-line)
                             prompt-row
                           (progn
                             (put-text-property 0 (length prompt-row)
                                                'help-echo raw-cmd
                                                prompt-row)
                             prompt-row)))
             ;; Divider spans the widest content row (command or output), so
             ;; the rule stops flush with the text instead of overrunning it.
             (content-width (apply #'max 0
                                   (mapcar #'string-width
                                           (cons prompt-row out-rows))))
             (divider (and out-lines
                           (concat "  "
                                   (propertize (make-string
                                                (min 80 (max 4 (- content-width 2)))
                                                ?─)
                                               'face 'dsh-emacs-divider-face))))
             (footer (and status-text
                          (concat "  "
                                  (propertize status-text 'face
                                              (if (eq state 'error)
                                                  'dsh-emacs-tool-error-face
                                                'dsh-emacs-tool-stopped-face)))))
             (rows (append (list prompt-row)
                           (and divider (list divider))
                           out-rows
                           (and footer (list footer)))))
        (mapconcat #'identity rows "\n")))))

;;; ---------------------------------------------------------------------------
;;; Renderer: read card (dsh web ReadBlock)
;;; ---------------------------------------------------------------------------

(defconst dsh-emacs--read-result-prefix
  "\\`<path>[^\n]*</path>\n<type>file</type>\n<content>\n"
  "Regexp matching the opening envelope of a file read.
A directory or image read carries a different `<type>', and a malformed
result carries none; both keep the generic ioCard (web `readCardModel').
The closing tag is checked separately to avoid regexp stack growth over
large file contents.")

(defun dsh-emacs-render--read-card-body (name args-raw meta result-text)
  "Compose the expanded body of a `read' card, or nil for the generic ioCard.
Mirrors dsh web's ReadBlock: the file's lines with their numbers in a muted
gutter, and — when the call read a window of a larger file — a footer
saying how many lines were shown, followed by the language when the Host
reported one.  NAME and ARGS-RAW are the tool call's name and argument JSON;
META and RESULT-TEXT are the settled result's metadata and text.

Rows are drawn on the transcript background with no card surface band, and
are not padded to the box width.  The card is drawn only for a plain readable
file whose arguments, metadata and result envelope agree; a directory or image
read, a failed call, or a truncated payload returns nil so the caller keeps
the generic card."
  (when (and (equal name "read") (listp meta))
    (let* ((file (dsh-protocol-read-file--from-alist args-raw meta))
           (path (dsh-protocol-read-file-path file))
           (offset (dsh-protocol-read-file-offset file))
           (total (dsh-protocol-read-file-total file))
           (lang (dsh-protocol-read-file-language file))
           (lines (dsh-protocol-read-file-lines file)))
      (when (and (stringp path) (not (string-empty-p (string-trim path)))
                 (integerp offset) (>= offset 1)
                 (integerp total) (>= total 0)
                 (listp lines) (stringp result-text)
                 (string-match dsh-emacs--read-result-prefix result-text)
                 (<= (match-end 0)
                     (- (length result-text) (length "\n</content>")))
                 (string-suffix-p "\n</content>" result-text))
        ;; Numbers are right-aligned to the widest one, so the gutter keeps
        ;; one column count down the whole card.
        (let* ((gutter-format (format "%%%dd"
                                      (length (number-to-string (max total 1)))))
               (shown (length lines))
               (rows (mapcar
                      (lambda (cell)
                        (concat
                         "  "
                         (propertize (format gutter-format (car cell))
                                     'face 'dsh-emacs-tool-meta-face)
                         "  " (cdr cell)))
                      lines)))
          (when (> shown 0)
            (when (< shown total)
              (setq rows
                    (append rows
                            (list (concat
                                   "  "
                                   (propertize
                                    (concat (format "Showing %d of %d lines"
                                                    shown total)
                                            (if (and (stringp lang)
                                                     (not (string-empty-p lang)))
                                                (concat " · " lang)
                                              ""))
                                    'face 'dsh-emacs-tool-meta-face))))))
            (mapconcat #'identity rows "\n")))))))

;;; ---------------------------------------------------------------------------
;;; Renderer: diff card (dsh web DiffBlock)
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-render--diff-lines (text)
  "Split diff TEXT into lines the way dsh web's `wo' does.
The empty string has no lines; one trailing newline is dropped while any
further empty line is a real line, so a blank line inside a hunk survives."
  (if (or (null text) (string= text ""))
      nil
    (split-string (if (string-suffix-p "\n" text) (substring text 0 -1) text)
                  "\n")))

(defun dsh-emacs-render--diff-align (old new)
  "Align OLD and NEW text as (KIND . LINE) cells.
KIND is `context', `del' or `add'.  Strip common edges before computing a
longest common subsequence of the middle lines.  Limit the comparison table
to 262144 cells so a large replacement cannot stall the event renderer;
above that limit, a `note' cell introduces the unaligned middle replacement."
  (let* ((old (vconcat (dsh-emacs-render--diff-lines old)))
         (new (vconcat (dsh-emacs-render--diff-lines new)))
         (start 0) (old-end (length old)) (new-end (length new))
         rows tail)
    (while (and (< start old-end) (< start new-end)
                (equal (aref old start) (aref new start)))
      (push (cons 'context (aref old start)) rows)
      (setq start (1+ start)))
    (while (and (< start old-end) (< start new-end)
                (equal (aref old (1- old-end)) (aref new (1- new-end))))
      (setq old-end (1- old-end) new-end (1- new-end))
      (push (cons 'context (aref old old-end)) tail))
    (let* ((n (- old-end start)) (m (- new-end start))
           (i 0) (j 0)
           (align-p (and (> n 0) (> m 0)
                         (<= (* (1+ n) (1+ m)) 262144)))
           (table (and align-p (make-vector (1+ n) nil))))
      (when align-p
        (dotimes (row (1+ n))
          (aset table row (make-vector (1+ m) 0)))
        (let ((row n))
          (while (> row 0)
            (setq row (1- row))
            (let ((col m))
              (while (> col 0)
                (setq col (1- col))
                (aset (aref table row) col
                      (if (equal (aref old (+ start row))
                                 (aref new (+ start col)))
                          (1+ (aref (aref table (1+ row)) (1+ col)))
                        (max (aref (aref table (1+ row)) col)
                             (aref (aref table row) (1+ col))))))))))
      (when (and (> n 0) (> m 0) (not align-p))
        (push '(note . "⋯ Large replacement: middle shown without alignment")
              rows))
      (while (or (< i n) (< j m))
        (cond
         ((and align-p (< i n) (< j m)
               (equal (aref old (+ start i)) (aref new (+ start j))))
          (push (cons 'context (aref old (+ start i))) rows)
          (setq i (1+ i) j (1+ j)))
         ((and (< i n)
               (or (not align-p) (= j m)
                   (>= (aref (aref table (1+ i)) j)
                       (aref (aref table i) (1+ j)))))
          (push (cons 'del (aref old (+ start i))) rows)
          (setq i (1+ i)))
         (t
          (push (cons 'add (aref new (+ start j))) rows)
          (setq j (1+ j))))))
    (nconc (nreverse rows) tail)))

(defun dsh-emacs-render--diff-rows (hunks)
  "Return the rendered rows and totals for HUNKS as (ROWS ADDED REMOVED FILES).
HUNKS is a list of (PATH OLD-TEXT NEW-TEXT).  The rows mirror dsh web's
DiffBlock's path and gap rows, but align unchanged lines as plain context.
Removed lines use `- TEXT' in the error color and added lines `+ TEXT' in
the success color.  Only those changed rows contribute to the totals.
FILES is the number of distinct paths."
  (let ((rows '()) (added 0) (removed 0) (files '()) (previous nil))
    (dolist (hunk hunks)
      (pcase-let ((`(,path ,old ,new) hunk))
        (push (concat "  " (propertize (if (equal path previous) "⋯" path)
                                       'face (if (equal path previous)
                                                 'dsh-emacs-tool-meta-face
                                               'dsh-emacs-tool-diff-path-face)))
              rows)
        (setq previous path)
        (unless (member path files) (push path files))
        (dolist (change (dsh-emacs-render--diff-align old new))
          (pcase-let ((`(,kind . ,line) change))
            (push
             (pcase kind
               ('context (concat "    " line))
               ('note (concat "  " (propertize line 'face
                                               'dsh-emacs-tool-meta-face)))
               ('del
                (setq removed (1+ removed))
                (concat "  " (propertize (concat "- " line)
                                        'face 'dsh-emacs-tool-diff-del-face)))
               ('add
                (setq added (1+ added))
                (concat "  " (propertize (concat "+ " line)
                                        'face 'dsh-emacs-tool-diff-add-face))))
             rows)))))
    (list (nreverse rows) added removed (length files))))

(defun dsh-emacs-render--diff-card-body (name args-raw meta state)
  "Compose the expanded body of a `write'/`edit' diff card, or nil.
Mirrors dsh web's DiffBlock; see `dsh-emacs-render--diff-rows' for the rows,
which are drawn on the transcript background with no card surface band — the
-/+ line colors carry the structure, and padding every row of a whole-file
write to the box width would bloat the transcript for no gain.
NAME and ARGS-RAW are the tool call's name and argument JSON, META the
settled result's metadata.

While STATE is `pending' the body is the diff the arguments intend.  On
`success', the recorded applied `meta.diffs' win; an `edit' whose result
records none falls back to the generic ioCard (an edit can match nothing)
while a `write' keeps its intended whole-file diff.  Other states or
unusable arguments return nil so the caller preserves diagnostic output."
  (let* ((intended (dsh-protocol-intended-diff--from-alist name args-raw))
         (hunks (cond ((null intended) nil)
                      ((eq state 'pending) (list intended))
                      ((not (eq state 'success)) nil)
                      ((equal name "write")
                       (or (dsh-protocol-applied-diffs--from-alist meta) (list intended)))
                      (t (dsh-protocol-applied-diffs--from-alist meta)))))
    (when hunks
      (pcase-let ((`(,rows ,added ,removed ,files)
                   (dsh-emacs-render--diff-rows hunks)))
        (mapconcat #'identity
                   (append rows
                           (list (concat
                                  "  "
                                  (propertize
                                   (format "└ +%d -%d · %s" added removed
                                           (if (= files 1) "1 file"
                                             (format "%d files" files)))
                                   'face 'dsh-emacs-tool-meta-face))))
                   "\n")))))

;;; ---------------------------------------------------------------------------
;;; Renderer: background-job cards (`job_output' / `job_list' / `job_kill')
;;; ---------------------------------------------------------------------------

(defconst dsh-emacs--job-tools '("job_output" "job_list" "job_kill")
  "Tool names whose results render as a background-job card.")

(defun dsh-emacs-render--job-status (text)
  "Split job result TEXT into (OUTPUT STATUS), or nil without a status line.
The Host appends `[status: <status>[, <detail>]]' as the final line of a
`job_output' result; OUTPUT is TEXT without it."
  (when (and (stringp text)
             (string-match "\n\\[status: \\([^]\n]+\\)\\]\\'" text))
    (list (substring text 0 (match-beginning 0)) (match-string 1 text))))

(defun dsh-emacs-render--job-status-face (status)
  "Face for a job STATUS token and its optional detail.
The Host calls any normally exited command `completed'; a nonzero exit
code in its detail still indicates failure.  Preserve the caller's match
data because `job_list' is in the middle of parsing its row."
  (save-match-data
    (cond ((and (string-match
                 "\\`completed, exit code: \\(-?[0-9]+\\)\\'" status)
                (/= (string-to-number (match-string 1 status)) 0))
           'dsh-emacs-tool-error-face)
          ((string-prefix-p "completed" status) 'dsh-emacs-tool-success-face)
          ((string-prefix-p "failed" status) 'dsh-emacs-tool-error-face)
          ((string-prefix-p "killed" status) 'dsh-emacs-tool-stopped-face)
          ((string-prefix-p "stopping" status) 'dsh-emacs-tool-stopped-face)
          (t 'dsh-emacs-tool-pending-face))))

(defun dsh-emacs-render--body-rows (text)
  "Return TEXT as indented card rows, or nil when it has no content."
  (when (and (stringp text) (not (string-empty-p text)))
    (mapcar (lambda (line) (concat "  " line))
            (split-string (string-trim-right text "\n") "\n"))))

;;; ---------------------------------------------------------------------------
;;; Renderer: present card (dsh web `PresentRow')
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-render--present-card-body (name text)
  "Compose the expanded body of a `present' card for tool NAME, or nil.
TEXT is the settled result text (`Presented <path>' lines, or the Host's
failure message).  The argument JSON is never repeated: the row summary
already names the declared paths, as dsh web's `PresentRow' does."
  (when (equal name "present")
    (when-let* ((rows (dsh-emacs-render--body-rows text)))
      (mapconcat #'identity rows "\n"))))

(defconst dsh-emacs--job-list-row-regexp
  "\\`\\([^ \n]+\\) \\[\\([^]\n]+\\)\\] \\([a-z]+\\) — \\(.*\\)\\'"
  "A `job_list' row: `ID [KIND] STATUS — LABEL'.
The Host prints one per job, but a label can itself contain newlines (it is a
background command verbatim), so only the opening line matches.")

(defun dsh-emacs-render--job-list-rows (text)
  "Return a `job_list' result TEXT as rows.
The opening line of each job carries its id/kind in the muted meta face and
its status in the face matching that status; a label that continues on later
lines stays indented under its job."
  (when (and (stringp text) (not (string-empty-p text)))
    (let (rows)
      (dolist (line (split-string (string-trim-right text "\n") "\n"))
        (push (if (string-match dsh-emacs--job-list-row-regexp line)
                  (concat
                   "  "
                   (propertize (concat (match-string 1 line)
                                       " [" (match-string 2 line) "]")
                               'face 'dsh-emacs-tool-meta-face)
                   " "
                   (propertize (match-string 3 line)
                               'face (dsh-emacs-render--job-status-face
                                      (match-string 3 line)))
                   " — " (match-string 4 line))
                (concat "    " line))
              rows))
      (nreverse rows))))

(defun dsh-emacs-render--job-card-body (name text)
  "Compose the expanded body of a background-job card for tool NAME, or nil.
TEXT is the settled result text.  `job_output' splits the Host's trailing
`[status: ...]' line into a state-colored footer and `job_list' colors each
job's status; `job_kill' renders its one-line result as a row.  The argument
JSON is never repeated: the row header already carries the job id.  A
`job_output' without its status line returns nil, so the caller keeps the
generic card."
  (when (member name dsh-emacs--job-tools)
    (cond
     ((equal name "job_output")
      (when-let* ((split (dsh-emacs-render--job-status text)))
        (let ((output (nth 0 split))
              (status (nth 1 split)))
          (mapconcat #'identity
                     (append
                      (dsh-emacs-render--body-rows output)
                      (list (concat
                             "  "
                             (propertize (concat "[status: " status "]")
                                         'face
                                         (dsh-emacs-render--job-status-face
                                          status)))))
                     "\n"))))
     ((equal name "job_list")
      (mapconcat #'identity (dsh-emacs-render--job-list-rows text) "\n"))
     (t (mapconcat #'identity (dsh-emacs-render--body-rows text) "\n")))))

;;; ---------------------------------------------------------------------------
;;; Renderer: ask card (dsh web `AskQuestionCard')
;;; ---------------------------------------------------------------------------
;;; dsh's `ask_user_question' call carries its questions in the arguments and
;;; the settled answers in its result — both the shapes the protocol decoder
;;; and the answer reader below consume.  The card records the decision
;;; instead of dumping the two JSON documents into an ioCard: every question
;;; with its numbered options and descriptions, the chosen options marked, and
;;; `Not answered' where the batch settled empty.  A call whose arguments name
;;; no usable question keeps the generic ioCard.

(defun dsh-emacs-render--ask-summary (answers error-code settled &optional pending)
  "Collapsed-row summary for an ask call, or nil to keep the caller's summary.
ANSWERS is `dsh-protocol-ask-answers--from-alist' output, nil while the call runs or
when its result carried no answer entry; ERROR-CODE is the settled
`data.error.code'; SETTLED non-nil means the call has a result; PENDING means
the result is the timed tool's pending payload.  Mirrors dsh web, whose total
is the answer document's own length: `A/B answered' once the answers are
known, `cancelled' for a user-dismissed question set, `interrupted' for an
abandoned one, `pending' when the window expired with the questions still
answerable, `waiting' while the call runs — and nil for any other settled
outcome, which the caller reports with its result preview."
  (cond
   (answers
    (format "%d/%d answered"
            (cl-count-if (lambda (cell) (or (nth 1 cell) (nth 2 cell)))
                         answers)
            (length answers)))
   (pending "pending")
   ((equal error-code "ASK_CANCELLED") "cancelled")
   ((equal error-code "ASK_ABORTED") "interrupted")
   ((not settled) "waiting")))

(defun dsh-emacs-render--ask-question-row (index multi header text)
  "Return the heading row for question INDEX of a MULTI-question batch.
The question's own HEADER is the chip dsh web shows as its eyebrow and leads
the row in the accent face; a batch of several questions prefixes the index as
`Q2 · '.  Both parts are optional, so a bare question still renders as one
clean row."
  (let* ((number (and multi (concat "Q" (number-to-string index) " · ")))
         (chip (and (stringp header)
                    (not (string-empty-p header))
                    (propertize header 'face 'dsh-emacs-accent-face))))
    (concat "  "
            (and number (propertize number 'face 'dsh-emacs-tool-meta-face))
            chip
            (and chip " — ")
            text)))

(defun dsh-emacs-render--ask-question-block (question index multi answer)
  "Return one ask QUESTION as a block of body rows, joined by newlines.
INDEX and MULTI place the question in its batch; QUESTION is a
`dsh-protocol-question' struct and ANSWER its settled (ID SELECTED CUSTOM)
cell, or nil while the call runs.  Every option keeps the reader's own
numbering, with the chosen ones checked and accented; an option's description
hangs at the label column in `dsh-emacs-meta-face' (the transcript's note
face), and a settled question closes with its free-text answer or
`Not answered'."
  (let* ((selected (nth 1 answer))
         (custom (nth 2 answer))
         (rows (list (dsh-emacs-render--ask-question-row
                      index multi
                      (dsh-protocol-question-header question)
                      (dsh-protocol-question-text question))))
         (number 0))
    (dolist (option (dsh-protocol-question-options question))
      (setq number (1+ number))
      (let* ((label (or (dsh-protocol-question-option-label option) ""))
             (chosen (and selected (member label selected)))
             (indent (concat "  " (format "%2d. " number)
                             (if chosen "✓ " "  ")))
             (description (dsh-protocol-question-option-description option))
             (label-row (concat indent
                                (if chosen
                                    (propertize label
                                                'face 'dsh-emacs-accent-face)
                                  label)))
             (description-row
              (and (stringp description)
                   (not (string-empty-p description))
                   (concat (make-string (string-width indent) ?\s)
                           (propertize description
                                       'face 'dsh-emacs-meta-face)))))
        (setq rows (append rows (list label-row)
                           (and description-row (list description-row))))))
    (let ((answer-row (cond
                       (custom
                        (concat "  "
                                (propertize "→ " 'face 'dsh-emacs-accent-face)
                                custom))
                       ((and answer (null selected))
                        (concat "  " (propertize "Not answered"
                                                 'face
                                                 'dsh-emacs-tool-meta-face))))))
      (mapconcat #'identity
                 (append rows (and answer-row (list answer-row)))
                 "\n"))))

(defun dsh-emacs-render--ask-body (questions answers status-text)
  "Compose the expanded body of an ask card, or nil without QUESTIONS.
ANSWERS is `dsh-protocol-ask-answers--from-alist' output (nil while the call runs);
STATUS-TEXT, when non-empty, is the settled call's failure line or the ask
verdict for a cancelled / interrupted set, printed above the questions like
the other cards' status lines.  One question is one block of rows; a batch
separates its questions with a blank line.  Faces are baked onto the rows,
so fold/unfold preserves the styling."
  (when questions
    (let ((multi (> (length questions) 1))
          (index 0)
          (blocks '()))
      (dolist (question questions)
        (setq index (1+ index))
        (push (dsh-emacs-render--ask-question-block
               question index multi
               (and answers
                    (assoc (dsh-protocol-question-id question) answers)))
              blocks))
      (mapconcat #'identity
                 (append (and (stringp status-text)
                              (not (string-empty-p status-text))
                              (list (concat "  " status-text)))
                         (nreverse blocks))
                 "\n\n"))))

(defun dsh-emacs-render--shell-status (text)
  "Split TEXT into (BODY EXIT-CODE SIGNAL).
dsh's shell renderer appends `[exit code: N]' or `[killed by signal: X]' to
the model-facing result text; the wire block carries no exit-status field
(web `parseExitStatus').  BODY is TEXT without that trailing marker, and both
EXIT-CODE and SIGNAL are nil when TEXT ends with neither."
  (if (not (stringp text))
      (list text nil nil)
    (cond
     ((string-match "\n\\[killed by signal: \\([^]\n]+\\)\\]\\'" text)
      (list (substring text 0 (match-beginning 0)) nil (match-string 1 text)))
     ((string-match "\n\\[exit code: \\([0-9]+\\)\\]\\'" text)
      (list (substring text 0 (match-beginning 0))
            (string-to-number (match-string 1 text)) nil))
     (t (list text nil nil)))))

(defun dsh-emacs-render--result-state (is-error error-code exit-code signal)
  "Resolve a settled call's display state from its result facts.
IS-ERROR is the result block's `isError' flag; ERROR-CODE is the Host's
failure identity (an `interrupted' abort settles as an error too, but reads as
stopped); EXIT-CODE and SIGNAL come from the shell status marker.  Mirrors web
`toolRowModel' and `terminalFailed': only `interrupted' is `stopped', any
other failure — a nonzero exit or a killing signal included — is `error',
everything else `success'."
  (cond ((equal error-code "interrupted") 'stopped)
        (is-error 'error)
        ((and (integerp exit-code) (/= exit-code 0)) 'error)
        (signal 'error)
        (t 'success)))

(defun dsh-emacs-render-tool-result (event)
  "Render a `tool/result' event by appending to the corresponding tool-call block."
  (when dsh-emacs-show-tool-calls
    (dsh-emacs-render--apply-tool-result
     (dsh-protocol-tool-result--from-alist
      event :event-p t))
    (dsh-protocol-event-sequence--from-alist event)))

(cl-defun dsh-emacs-render--settled-tool-body
    (&key variant name args args-raw meta text state out-text exit-code signal
          error-reason status-text)
  "Format a settled tool body from captured card facts at the current width."
  (or (and (equal variant "bash")
           (dsh-emacs-render--bash-card-body
            args out-text state exit-code signal error-reason))
      (and (eq state 'success)
           (dsh-emacs-render--read-card-body name args-raw meta text))
      (and (member variant '("write" "edit"))
           (dsh-emacs-render--diff-card-body name args-raw meta state))
      (dsh-emacs-render--present-card-body name text)
      (dsh-emacs-render--job-card-body name text)
      (dsh-emacs-render--tool-body-io args text status-text)))

(cl-defun dsh-emacs-render--apply-tool-result (result)
  "Update an existing tool card from decoded RESULT.
Both stream results and late question answers use this path; event sequence
tracking belongs to `dsh-emacs-render-tool-result'."
  (pcase-let* (((cl-struct dsh-protocol-tool-result
                           call-id (text full-text) is-error
                           (exit-code block-exit-code) (signal block-signal)
                           error-code error-reason meta)
                result)
               (ns (dsh-emacs-render--make-namespace))
               (block-id (dsh-emacs-render--tool-call-block-id call-id)))
    (when-let* ((prev (dsh-emacs-render--tool-state call-id)))
      (when-let* ((text (plist-get prev :plan-text)))
        (dsh-emacs-render--plan-card
         call-id text (if is-error "Review ended" "Approved")
         (and is-error (not (string-empty-p full-text)) full-text))
        (cl-return-from dsh-emacs-render--apply-tool-result nil))
      (let* ((title (or (plist-get prev :title) "Tool"))
             (name (or (plist-get prev :name) ""))
             (args (or (plist-get prev :args) ""))
             (args-raw (or (plist-get prev :args-raw) ""))
             (summary (or (plist-get prev :summary) ""))
             (icon (or (plist-get prev :icon) ""))
             (variant (plist-get prev :variant))
             ;; Control can settle a question before its follow result or
             ;; older history page renders.  Reconcile at row creation as
             ;; well as on projection updates; the recorded result stays
             ;; pending forever even after the late answer is admitted.
             (settled-question
              (and (equal variant "question")
                   dsh-emacs--session-questions
                   (dsh-protocol-ask-pending--from-alist full-text)
                   (cl-find call-id
                            (dsh-protocol-user-questions-settled
                             dsh-emacs--session-questions)
                            :key #'dsh-protocol-settled-question-call-id
                            :test #'equal)))
             (full-text
              (if settled-question
                  (dsh-protocol-question-answers-json
                   (dsh-protocol-settled-question-answers settled-question))
                full-text))
             ;; The shell status rides in the result text, not the wire
             ;; block: parse it before resolving the display state.
             (shell (and (equal variant "bash")
                         (dsh-emacs-render--shell-status full-text)))
             (exit-code (or block-exit-code (nth 1 shell)))
             (signal (or block-signal (nth 2 shell)))
             (state (dsh-emacs-render--result-state
                     is-error error-code exit-code signal))
             ;; The two user-driven ask outcomes are the human's own
             ;; decision, not a tool failure: a cancelled question set
             ;; settles and an abandoned one interrupts, the mapping dsh
             ;; web's AskQuestionRow applies.  `result-state' cannot know
             ;; that, so the ask call corrects its own state here.
             (state (if (equal variant "question")
                        (pcase error-code
                          ("ASK_CANCELLED" 'success)
                          ("ASK_ABORTED" 'stopped)
                          (_ state))
                      state))
             ;; An ask call also explains those two outcomes in its body
             ;; (web's `ask.cancelledDetail' / `ask.interruptedDetail'),
             ;; where the generic status line would say only "interrupted".
             (ask-verdict (and (equal variant "question")
                               (pcase error-code
                                 ("ASK_CANCELLED"
                                  "This question set was cancelled before answers were submitted.")
                                 ("ASK_ABORTED"
                                  "This question set was interrupted before answers were submitted."))))
             (ask-questions (and (equal variant "question")
                                 (dsh-protocol-ask-questions--from-alist
                                  args-raw)))
             (ask-answers (and ask-questions
                               (dsh-protocol-ask-answers--from-alist full-text)))
             ;; dsh 0.2.0's timed tool reports an expired foreground
             ;; window as a successful pending result; the questions stay
             ;; answerable (`dsh-emacs-answer-question'), so the row must
             ;; not read as an answered or failed set.
             (ask-pending (and ask-questions
                               (dsh-protocol-ask-pending--from-alist full-text)))
             ;; The three goal tools carry dsh web's structured card: the
             ;; objective is the summary and the body is State / Rounds
             ;; (+ Blocker).  A cleared `{goal: null}' answer is that
             ;; card's empty state, not an unrecognized payload; a failed
             ;; or malformed result keeps the generic ioCard.
             (goal-card (and (equal variant "goal")
                             (eq state 'success)
                             (dsh-protocol-goal-result--from-alist full-text)))
             (goal-value (car-safe goal-card))
             (goal-cleared (cdr-safe goal-card))
             (goal-body (cond ((null goal-card) nil)
                              (goal-value
                               (dsh-emacs-render--goal-card-body goal-value))
                              (t "")))
             ;; An ask row's header states the outcome of its question
             ;; set (`2/3 answered', `pending', `interrupted',
             ;; `cancelled'); a settled set the card cannot describe falls
             ;; back to the result preview like any other row.
             (row-summary (cond
                           (ask-questions
                            (or (dsh-emacs-render--ask-summary
                                 ask-answers error-code t ask-pending)
                                (dsh-emacs-render--tool-result-preview
                                 full-text)))
                           (goal-card
                            (or (and goal-value
                                     (when-let* ((objective
                                                  (dsh-protocol-goal-objective
                                                   goal-value)))
                                       (dsh-emacs-reference-fontify
                                        objective)))
                                "No goal"))
                           (t summary)))
             (face (pcase state
                     ('success 'dsh-emacs-tool-success-face)
                     ('error 'dsh-emacs-tool-error-face)
                     ('stopped 'dsh-emacs-tool-stopped-face)
                     (_ 'dsh-emacs-tool-pending-face)))
             ;; The generic ioCard prints a status line only when the
             ;; call failed or was interrupted: the header's green tint
             ;; already says a clean call settled, and "✓ exit 0" is
             ;; shell news a non-shell tool never had (see the bash card,
             ;; which suppresses it too).  The line stays unstyled — a
             ;; state face tints the header row, never a body.
             (status-text (and (memq state '(error stopped))
                               (dsh-emacs-render--tool-status-text
                                state exit-code signal error-reason)))
             ;; A timed question whose window expired explains itself in
             ;; the body, where the questionnaire still is, and names the
             ;; command that answers it later.
             (pending-text (and ask-pending
                                (concat "This question set is pending — "
                                        "answer it later with M-x "
                                        "dsh-emacs-answer-question.")))
             ;; A settled question/goal card stays eager: its body is small
             ;; and the card is interactive.  Large result bodies are formatted
             ;; on demand, including the pending card's own questionnaire.
             (body (or goal-body
                       (and ask-questions
                            (dsh-emacs-render--ask-body
                             ask-questions ask-answers
                             (or pending-text ask-verdict status-text)))
                       (apply-partially
                        #'dsh-emacs-render--settled-tool-body
                        :variant variant :name name :args args :args-raw args-raw
                        :meta meta :text full-text :state state
                        :out-text (nth 0 shell)
                        :exit-code exit-code :signal signal
                        :error-reason error-reason :status-text status-text))))
        (dsh-emacs-ui-update-fragment
         (dsh-emacs-ui-make-fragment
          :namespace-id ns
          :block-id block-id
          :label-left (concat
                       (dsh-emacs-render--tool-leading icon state)
                       (propertize title
                       'face (dsh-emacs-render--row-label-face
                              'dsh-emacs-tool-title-face)))
          :label-right (if (string-empty-p row-summary)
                           (dsh-emacs-render--tool-result-preview
                            full-text)
                         row-summary)
          :body body
          :style 'minimal
          ;; A cleared goal has no fields to unfold.
          :non-foldable goal-cleared
          ;; In `full', the state tint covers the header row only; the body
          ;; keeps its own neutral faces.  `simple' leaves the header neutral
          ;; for the colored dot.
          :header-face (dsh-emacs-render--row-chrome-face face)
          :status (pcase state
                    ('success 'tool-success)
                    ('error 'tool-error)
                    (_ 'tool-stopped)))
         :create-new nil)
        ;; Track the new state, keeping the call-time identity the card
        ;; was built from: a later projection-driven settle
        ;; (`dsh-emacs-render-question-settled') updates this row through
        ;; the same result path and needs the original arguments.
        (dsh-emacs-render--set-tool-state
         call-id :state state :result full-text :exit-code exit-code
         :variant variant :title title :name name :args args
         :args-raw args-raw :icon icon :summary summary
         :call-time (plist-get prev :call-time) :ns (plist-get prev :ns)))))
  nil)

(defun dsh-emacs-render-question-settled (call-id answers-json)
  "Settle the transcript ask row for CALL-ID with ANSWERS-JSON.
The `userQuestions' projection reports a timed question settled when its late
answer was steered in; the recorded tool result is only the pending payload,
so the card is completed by applying the settled batch through the shared
decoded-result path that updates a row in place (an in-time answer already
settled its row normally, so its card is left alone).  No-op unless this
buffer still tracks CALL-ID's row and that row is showing the pending result."
  (let ((prev (dsh-emacs-render--tool-state call-id)))
    (when (and dsh-emacs-show-tool-calls prev
               (equal (plist-get prev :variant) "question")
               (dsh-protocol-ask-pending--from-alist (plist-get prev :result)))
      (dsh-emacs-render--apply-tool-result
       (dsh-protocol--make-tool-result :call-id call-id :text answers-json)))))

;;; ---------------------------------------------------------------------------
;;; Renderer: goal card (`create_goal' / `get_goal' / `update_goal')
;;; ---------------------------------------------------------------------------
;; dsh web hands the three goal tools to one compact details card
;; (`detailsCardModel' -> `goalDetail'): the objective becomes the row summary
;; and the expanded heading, followed by State / Rounds and, while blocked,
;; the blocker message.  The generic ioCard's IN/OUT JSON is dropped once the
;; call settles — the structured card is the whole body.

(defconst dsh-emacs--goal-tools '("create_goal" "get_goal" "update_goal")
  "Tool names whose result renders as the goal card.")

(defconst dsh-emacs-render--goal-field-label-width 8
  "Width of the goal card's field-label column.
`Status' is the longest label and still leaves a separating space.")

(defun dsh-emacs-render--goal-tool-p (name)
  "Whether NAME is one of the goal tools."
  (and (stringp name) (member name dsh-emacs--goal-tools)))

(defun dsh-emacs-render--goal-call-summary (name args)
  "Format a goal call NAME's objective or update action from decoded ARGS."
  (when (dsh-emacs-render--goal-tool-p name)
    (let ((objective (dsh-protocol-tool-arguments-objective args))
          (action (dsh-protocol-tool-arguments-action args)))
      (cond
       ((and (stringp objective) (not (string-empty-p objective)))
        (dsh-emacs-render--first-line objective))
       ((and (stringp action) (not (string-empty-p action)))
        (capitalize action))))))

(defun dsh-emacs-render--goal-state-text (goal)
  "Human state of GOAL, mirroring dsh web's `detail.goal.*' copy."
  (pcase (dsh-protocol-goal-phase goal)
    ("active" (if (equal (dsh-protocol-goal-activation goal) "disarmed")
                  "Awaiting continuation"
                "Active"))
    ("paused" "Paused")
    ("blocked" "Blocked")
    ("complete" "Completed")
    (_ "")))

(defun dsh-emacs-render--goal-field-row (label value)
  "Return one `LABEL  VALUE' goal card row in the shared label column."
  (concat "  "
          (propertize label 'face 'dsh-emacs-tool-io-face)
          (make-string (max 1 (- dsh-emacs-render--goal-field-label-width
                                 (string-width label)))
                       ?\s)
          value))

(defun dsh-emacs-render--goal-card-body (goal)
  "Compose the expanded body of GOAL's card, or nil.
The objective heads the body, then State and Rounds, and the blocker message
only while the goal is blocked.  Faces are baked onto the rows, so fold and
unfold preserve the styling."
  (let* ((objective (dsh-protocol-goal-objective goal))
         (reason (dsh-protocol-goal-blocked-reason goal))
         (rounds (format "%s / %s"
                         (or (dsh-protocol-goal-rounds-started goal) 0)
                         (or (dsh-protocol-goal-max-goal-rounds goal) 0))))
    (mapconcat
     #'identity
     (append
      (and (stringp objective) (not (string-empty-p objective))
           (list (concat "  "
                         (let ((text (dsh-emacs-reference-fontify objective)))
                           ;; Prepend, so a collapsed session chip keeps its
                           ;; own link face instead of the title face.
                           (add-face-text-property
                            0 (length text)
                            'dsh-emacs-tool-title-face nil text)
                           text))))
      (list (dsh-emacs-render--goal-field-row
             "Status" (dsh-emacs-render--goal-state-text goal)))
      (list (dsh-emacs-render--goal-field-row "Rounds" rounds))
      (and (stringp reason) (not (string-empty-p reason))
           (list (dsh-emacs-render--goal-field-row "Blocker" reason))))
     "\n")))

;;; ---------------------------------------------------------------------------
;;; Reply footer: actions and per-turn statistics
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-render--reply-action (button)
  "Perform the reply action attached to BUTTON."
  (pcase (button-get button 'dsh-emacs-reply-action)
    ('copy
     (kill-new (button-get button 'dsh-emacs-reply-text))
     (message "Reply copied"))
    ('fork
     (unless dsh-emacs--buffer-session
       (user-error "No chat session in this buffer"))
     (dsh-emacs-fork-session dsh-emacs--buffer-session
                             (button-get button 'dsh-emacs-reply-seq)))))

(defun dsh-emacs-render--reply-footer (turn state)
  "Paint TURN's footer from STATE, after its final transcript content."
  (when (and (plist-get state :end-seq) (plist-get state :reply-seq))
    (let ((pos (point-min))
          (seq (plist-get state :reply-seq))
          (usage (list :input 0 :output 0 :cache-read 0 :cache-write 0))
          (complete (plist-get state :start-seq))
          (reported nil)
          end parts)
      ;; A reply may have several text segments separated by Think cards.
      ;; Find its final segment without treating the toolbar as reply text.
      (while (setq pos (text-property-any pos (point-max)
                                          'dsh-emacs-message-seq seq))
        (setq end (next-single-property-change pos 'dsh-emacs-message-seq
                                               nil (point-max))
              pos end))
      ;; Hidden wakeups can finish several turns between human messages.
      ;; Reconcile only their chrome, using rendered boundaries so optimistic
      ;; echoes and history pages behave exactly like live canonical input.
      (when end
        (let* ((namespace (dsh-emacs-render--make-namespace))
               (block-id (format "reply-footer-%s" turn))
               (start (previous-single-property-change
                       end 'dsh-emacs-user-message nil (point-min)))
               (limit (or (text-property-not-all
                           end (point-max) 'dsh-emacs-user-message nil)
                          (point-max)))
               older superseded)
          (maphash
           (lambda (other-turn other-state)
             (let ((other-seq (plist-get other-state :reply-seq)))
               (when (and other-seq (/= other-turn turn)
                          (plist-get other-state :end-seq)
                          (text-property-any start limit
                                             'dsh-emacs-message-seq other-seq)
                          ;; A streamed reply can straddle human input;
                          ;; only its final segment assigns its group.
                          (not (text-property-any
                                limit (point-max)
                                'dsh-emacs-message-seq other-seq)))
                 (if (> other-seq seq)
                     (setq superseded t)
                   (push (format "reply-footer-%s" other-turn) older)))))
           dsh-emacs-render--reply-turns)
          (if superseded
              (progn
                (dsh-emacs-ui-delete-fragment namespace block-id)
                (setq end nil))
            ;; Point follows deletions before the reply; a raw END would not.
            (save-excursion
              (goto-char end)
              (dolist (id older)
                (dsh-emacs-ui-delete-fragment namespace id))
              (setq end (point))))))
      (when end
        ;; The last text reply is the action target, but tools, reasoning
        ;; and diagnostics can follow it before the turn actually ends.
        (when-let* ((tail
                     (if-let* ((id (plist-get state :tail-fragment)))
                         (cdr (dsh-emacs-ui-find-block (car id) (cdr id)))
                       (when-let* ((id (plist-get state :tail-message)))
                         (save-excursion
                           (goto-char (point-max))
                           (when-let* ((match (text-property-search-backward
                                               'dsh-emacs-event-block id #'equal)))
                             (prop-match-end match)))))))
          (setq end (max end tail)))
        (dolist (entry (plist-get state :messages))
          (if (null (cdr entry))
              (setq complete nil)
            (setq reported t)
            (dolist (key '(:input :output :cache-read :cache-write))
              (cl-incf (plist-get usage key) (plist-get (cdr entry) key)))))
        (dolist (item (delete-dups (copy-sequence dsh-emacs-reply-footer-items)))
          (pcase item
            ((or 'copy 'fork)
             (unless (and (eq item 'fork) (bound-and-true-p dsh-emacs--buffer-subagent))
               (push (make-text-button
                      (if (eq item 'copy) "Copy" "Fork") nil
                      'follow-link t
                      'mouse-face 'highlight 'action #'dsh-emacs-render--reply-action
                      'help-echo (if (eq item 'copy) "Copy this reply as Markdown"
                                   "Branch through this reply")
                      'dsh-emacs-reply-action item 'dsh-emacs-reply-seq seq
                      'dsh-emacs-reply-text (plist-get state :text)) parts)))
            ('usage
             (push (propertize
                    (if reported
                        (format "Tokens %s%s" (if complete "" "≥")
                                (dsh-emacs-format-tokens
                                 (apply #'+ (cl-loop for (_key value) on usage by #'cddr
                                                     collect value))))
                      "Tokens —")
                    'help-echo
                    (format "Turn %s: input %d, output %d, cache read %d, cache write %d%s"
                            turn (plist-get usage :input) (plist-get usage :output)
                            (plist-get usage :cache-read) (plist-get usage :cache-write)
                            (if (and complete reported) ""
                              "; incomplete history or missing reported usage"))) parts))
            ('duration
             (let ((start (plist-get state :start-time))
                   (finish (plist-get state :end-time)))
               (push (propertize
                      (if (and (numberp start) (numberp finish) (>= finish start))
                          (let ((seconds (/ (- finish start) 1000.0)))
                            (if (< seconds 60) (format "Time %.1fs" seconds)
                              (format "Time %dm%02ds" (/ (floor seconds) 60)
                                      (% (floor seconds) 60))))
                        "Time —")
                      'help-echo "Turn elapsed time, including tools and waits; server timestamps")
                     parts)))))
        (when parts
          (setq parts (nreverse parts))
          (let ((label (mapconcat #'identity parts "  ·  ")))
            ;; Prepend to the title face `dsh-emacs-ui--top-border' appends;
            ;; its explicit normal weight keeps the row muted.
            (add-face-text-property 0 (length label)
                                    'dsh-emacs-reply-meta-face t label)
            (let ((range
                   (dsh-emacs-ui-update-fragment
                    (dsh-emacs-ui-make-fragment
                     :namespace-id (dsh-emacs-render--make-namespace)
                     :block-id (format "reply-footer-%s" turn)
                     :label-left label
                     ;; Keep a trailing gap when history adds this row after
                     ;; the next user message reserved its leading whitespace.
                     :padding t
                     :style 'minimal :status 'reply-footer :non-foldable t
                     :header-face 'dsh-emacs-reply-meta-face)
                    :insert-before (save-excursion
                                     (goto-char end)
                                     (unless (bolp) (forward-line 1))
                                     (point)))))
              ;; This padded row already ends with its own blank line.  When a
              ;; following message reserved one before the row existed, drop
              ;; the duplicate so the next question keeps a single blank line.
              ;; Never touch an authored leading blank line or a fragment.
              (when (and (eq (char-after (cdr range)) ?\n)
                         (not (get-text-property
                               (cdr range) 'dsh-emacs-ui-state))
                         (not (get-text-property
                               (cdr range) 'dsh-emacs-user-message))
                         (not (get-text-property
                               (cdr range) 'dsh-emacs-assistant-message)))
                (let ((inhibit-read-only t)
                      (buffer-undo-list t))
                  (delete-region (cdr range) (1+ (cdr range))))))))))))

(defun dsh-emacs-render--activity-summary (calls)
  "Summarize CALLS, an ordered list of (ID . NAME), as in Web's processTitle.
Count each call once, rank categories by count with stable ties, and display
at most three categories.  Reasoning-only groups have no tool categories."
  (let (seen counts)
    (dolist (call calls)
      (unless (member (car call) seen)
        (push (car call) seen)
        (let* ((name (cdr call))
               (label
                (cond
                 ((equal name "read") "Read files")
                 ((equal name "read_image") "Read images")
                 ((or (member name '("grep" "glob"))
                      (string-suffix-p "_inspect" name)) "Searched code")
                 ((equal name "write") "Wrote files")
                 ((member name '("edit" "apply_patch")) "Edited files")
                 ((or (member name '("bash" "pwsh" "exec_command" "write_stdin"))
                      (string-prefix-p "terminal_" name)) "Ran commands")
                 ((equal name "run_code") "Ran code")
                 ((equal name "web_search") "Searched the web")
                 ((equal name "web_fetch") "Visited web pages")
                 ((or (equal name "subagent") (string-prefix-p "subagent_" name))
                  "Coordinated subagents")
                 ((member name '("todo_write" "create_goal" "update_goal" "get_goal"))
                  "Updated the plan")
                 ((member name '("ask_user_question" "request_user_input"))
                  "Asked questions")
                 (t "Called tools")))
               (entry (assoc label counts)))
          (if entry (cl-incf (cdr entry))
            (setq counts (append counts (list (cons label 1))))))))
    (setq counts (cl-stable-sort counts (lambda (a b) (> (cdr a) (cdr b)))))
    (if (null counts) "Analysis completed"
      (let ((labels (mapcar #'car (cl-subseq counts 0 (min 3 (length counts))))))
        (concat (car labels)
                (mapconcat (lambda (label)
                             (concat (if (= (length counts) 2) " and " ", ")
                                     (downcase (substring label 0 1))
                                     (substring label 1)))
                           (cdr labels) "")
                (when (> (length counts) 3) ", etc."))))))

(defun dsh-emacs-render--activity-details (turn state)
  "Fold contiguous process cards in settled TURN, leaving replies outside.
STATE owns the overlays and decoded tool identities.  Existing fragment
boundaries supply the visible order; messages and process-external rows
split groups.  This is Web's detailed/history policy, not step grouping."
  (let ((origin (plist-get state :work-start))
        (end (plist-get state :work-end))
        (old (plist-get state :activity-overlays))
        (namespace (dsh-emacs-render--make-namespace))
        groups kept current existing)
    (cl-labels
        ((flush ()
           (when current
             (setf (plist-get current :overlay) existing)
             (push current groups))
           (setq current nil existing nil)))
      (when (and dsh-emacs-fold-work-details (plist-get state :end-seq)
                 (markerp origin) (marker-buffer origin)
                 (markerp end) (marker-buffer end))
        (save-excursion
          (goto-char origin)
          (while (< (point) end)
            (let* ((fragment (get-text-property (point) 'dsh-emacs-ui-state))
                   (status (map-elt fragment :status))
                   (id (map-elt fragment :block-id))
                   (call-id (cond
                             ((equal (map-elt fragment :namespace-id)
                                     dsh-emacs--todo-namespace) id)
                             ((and (stringp id) (string-prefix-p "tool-" id))
                              (substring id 5))))
                   (next (next-single-property-change
                          (point) 'dsh-emacs-ui-state nil end)))
              (cond
               ((eq status 'activity-details)
                (unless existing
                  (setq existing (get-text-property
                                  0 'dsh-emacs-work-details
                                  (map-elt fragment :label-left)))))
               ((eq status 'work-details))
               ;; Compaction belongs to the process but contributes no tool count.
               ((or (memq status '(thinking compaction-summary)) call-id)
                (unless current
                  (setq current (list :first id :start (copy-marker (point))
                                      :end (copy-marker next t))))
                (set-marker (plist-get current :end) next)
                (when-let* ((name (cdr (assoc call-id (plist-get state :tool-names)))))
                  (push (cons call-id name) (plist-get current :calls))))
               ((and (null fragment)
                     (string-blank-p (buffer-substring-no-properties (point) next))))
               (t (flush)))
              (goto-char next))))
        (flush)))
    (setq groups (nreverse groups))
    (unwind-protect
        (dolist (group groups)
          (let* ((overlay (plist-get group :overlay))
                 (id (if overlay (overlay-get overlay 'block-id)
                       (format "activity-%s-%s" turn (plist-get group :first)))))
            (push (dsh-emacs-ui-fold-region
                   namespace id (plist-get group :start) (plist-get group :end)
                   overlay (dsh-emacs-render--activity-summary
                            (nreverse (plist-get group :calls)))
                   'activity-details)
                  kept)))
      (dolist (group groups)
        (set-marker (plist-get group :start) nil)
        (set-marker (plist-get group :end) nil)))
    (dolist (overlay old)
      (unless (memq overlay kept) (dsh-emacs-ui-delete-work-details overlay)))
    (setf (plist-get state :activity-overlays) (nreverse kept))))

(defun dsh-emacs-render--work-details (turn state)
  "Reconcile TURN's two disclosure levels from STATE.
As in Web's detailed mode, settled activity groups leave every reply outside.
Only successful turns without interleaved input may also hide the whole
process.  Their final answer, if any, remains outside that outer fold."
  (dsh-emacs-render--activity-details turn state)
  (let* ((overlay (plist-get state :work-overlay))
         (namespace (dsh-emacs-render--make-namespace))
         (id (format "work-details-%s" turn))
         (origin (plist-get state :work-start))
         (end (plist-get state :work-end))
         (reason (plist-get state :end-reason))
         (settled (and dsh-emacs-fold-work-details
                       (member reason '("completed" "error" "aborted" "interrupted"))
                       (markerp origin) (marker-buffer origin)
                       (markerp end) (marker-buffer end))))
    ;; A disabled summary owns no overlay; move it as older history arrives.
    (when (and (plist-get state :work-header) (not overlay))
      (dsh-emacs-ui-delete-fragment namespace id))
    (if (not settled)
        (progn
          (when overlay (dsh-emacs-ui-delete-work-details overlay))
          (setf (plist-get state :work-overlay) nil
                (plist-get state :work-header) nil))
      (save-excursion
        (goto-char origin)
        (while (progn
                 (skip-chars-forward " \t\n" end)
                 (and (< (point) end)
                      (cond
                       ((get-text-property (point) 'dsh-emacs-user-message)
                        (goto-char (next-single-property-change
                                    (point) 'dsh-emacs-user-message nil end)))
                       ((memq (map-elt (get-text-property
                                        (point) 'dsh-emacs-ui-state) :status)
                              '(goal-trigger turn-trigger reply-footer
                                work-details))
                        (goto-char (next-single-property-change
                                    (point) 'dsh-emacs-ui-state nil end)))))))
        (let* ((start (copy-marker (line-beginning-position)))
               (answer (and (plist-get state :answer-seq)
                            (text-property-any start end 'dsh-emacs-message-seq
                                               (plist-get state :answer-seq))))
               (boundary (or answer end))
               (interleaved (text-property-any start end 'dsh-emacs-user-message t))
               (caption
                (cond
                 ((equal reason "error") "Failed")
                 ((member reason '("aborted" "interrupted")) "Stopped")
                 (t
                  (let ((begin (plist-get state :start-time))
                        (finish (plist-get state :end-time)))
                    (if (and (numberp begin) (numberp finish) (>= finish begin))
                        (let ((seconds (max 1 (floor (/ (- finish begin) 1000.0)))))
                          (concat "Completed in "
                                  (cond
                                   ((>= seconds 3600)
                                    (format "%dh %dm %ds" (/ seconds 3600)
                                            (% (/ seconds 60) 60) (% seconds 60)))
                                   ((>= seconds 60)
                                    (format "%dm %ds" (/ seconds 60) (% seconds 60)))
                                   (t (format "%ds" seconds)))))
                      "Completed"))))))
          ;; Mid-turn automatic input has a visible trigger rather than a bubble.
          (while (and (not interleaved) (< (point) end))
            (when (memq (map-elt (get-text-property
                                  (point) 'dsh-emacs-ui-state) :status)
                        '(goal-trigger turn-trigger))
              (setq interleaved t))
            (goto-char (next-single-property-change
                        (point) 'dsh-emacs-ui-state nil end)))
          (unwind-protect
              (if (and (equal reason "completed") (not interleaved)
                       (< start boundary))
                  (setf (plist-get state :work-overlay)
                        (dsh-emacs-ui-fold-region
                         namespace id start boundary overlay caption))
                (when overlay
                  (dsh-emacs-ui-delete-work-details overlay)
                  (setf (plist-get state :work-overlay) nil))
                (dsh-emacs-ui-update-fragment
                 (dsh-emacs-ui-make-fragment
                  :namespace-id namespace :block-id id
                  :label-left (propertize caption 'face 'dsh-emacs-reply-meta-face)
                  :style 'minimal :status 'work-details :non-foldable t)
                 :insert-before start))
            (set-marker start nil))
          (setf (plist-get state :work-header) (cons namespace id)))))))

(defun dsh-emacs-render--release-work-details (state)
  "Release STATE's task header, activity groups and boundary markers."
  (dolist (overlay (cons (plist-get state :work-overlay)
                         (plist-get state :activity-overlays)))
    (when overlay (dsh-emacs-ui-delete-work-details overlay)))
  (when-let* ((header (plist-get state :work-header)))
    (dsh-emacs-ui-delete-fragment (car header) (cdr header)))
  (dolist (key '(:work-start :work-end))
    (when-let* ((marker (plist-get state key)))
      (set-marker marker nil)
      (setf (plist-get state key) nil)))
  (setf (plist-get state :work-overlay) nil
        (plist-get state :work-header) nil
        (plist-get state :activity-overlays) nil))

(defun dsh-emacs-render--note-reply-event (event &optional start)
  "Merge decoded reply EVENT, with START preceding its rendered content.
The earliest loaded event bounds visible work even without `turn/start'."
  (when (and event (integerp (dsh-protocol-reply-event-turn event))
             (integerp (dsh-protocol-reply-event-seq event)))
    (unless dsh-emacs-render--reply-turns
      (setq dsh-emacs-render--reply-turns (make-hash-table :test 'eql)))
    (let* ((turn (dsh-protocol-reply-event-turn event))
           (seq (dsh-protocol-reply-event-seq event))
           (type (dsh-protocol-reply-event-type event))
           (state (or (gethash turn dsh-emacs-render--reply-turns)
                      (list :start-seq nil :start-time nil :end-seq nil
                            :end-time nil :reply-seq nil :text nil :messages nil
                            :work-overlay nil :work-header nil
                            :activity-overlays nil :tool-names nil))))
      (when (and start (not (equal type "turn/end"))
                 (< seq (or (plist-get state :work-start-seq)
                            most-positive-fixnum)))
        (when-let* ((old (plist-get state :work-start)))
          (set-marker old nil))
        (setf (plist-get state :work-start) (copy-marker start nil)
              (plist-get state :work-start-seq) seq))
      (pcase type
        ("tool/call"
         (when-let* ((id (dsh-protocol-reply-event-call-id event))
                     (name (dsh-protocol-reply-event-tool-name event)))
           (setf (alist-get id (plist-get state :tool-names) nil nil #'equal) name)))
        ("turn/start"
         (setf (plist-get state :start-seq) seq
               (plist-get state :start-time) (dsh-protocol-reply-event-time event)))
        ("turn/end"
         (unless (plist-get state :work-end)
           ;; Stop before turn-end diagnostics and deliverables are inserted.
           (setf (plist-get state :work-end)
                 (copy-marker (or start (dsh-emacs-render--input-insert-point)
                                  (point-max)) nil)))
         (setf (plist-get state :end-seq) seq
               (plist-get state :end-reason) (dsh-protocol-reply-event-reason event)
               (plist-get state :end-time) (dsh-protocol-reply-event-time event))
         ;; Capture content identity, not a position that later insertions or
         ;; deferred Markdown could move.  Turn-end diagnostics are already
         ;; rendered, and the history insertion point bounds an older page.
         (save-excursion
           (goto-char (or (dsh-emacs-render--input-insert-point) (point-max)))
           (skip-chars-backward " \t\n")
           (when (> (point) (point-min))
             (let ((fragment (get-text-property (1- (point)) 'dsh-emacs-ui-state)))
               (setf (plist-get state :tail-fragment)
                     (when fragment
                       (cons (map-elt fragment :namespace-id)
                             (map-elt fragment :block-id)))
                     (plist-get state :tail-message)
                     (unless fragment
                       (get-text-property (1- (point)) 'dsh-emacs-event-block)))))))
        ((or "assistant/message" "assistant/attempt")
         (unless (assq seq (plist-get state :messages))
           (push (cons seq (dsh-protocol-reply-event-usage event))
                 (plist-get state :messages)))
         (when (and (equal type "assistant/message")
                    (not (string-empty-p (dsh-protocol-reply-event-text event)))
                    (> seq (or (plist-get state :reply-seq) -1)))
           (setf (plist-get state :reply-seq) seq
                 (plist-get state :text) (dsh-protocol-reply-event-text event)))))
      ;; Unlike the Copy target, a final answer cannot precede more work.
      ;; Sequence ordering also protects it from older history page facts.
      (when (and (member type '("step/start" "tool/call" "assistant/message"
                                "assistant/attempt"))
                 (> seq (or (plist-get state :answer-event-seq) -1)))
        (setf (plist-get state :answer-event-seq) seq
              (plist-get state :answer-seq)
              (and (dsh-protocol-reply-event-answer-p event) seq)))
      (puthash turn state dsh-emacs-render--reply-turns)
      (if dsh-emacs-render--footer-batch
          (cl-pushnew turn dsh-emacs-render--footer-dirty)
        (progn
          (dsh-emacs-render--reply-footer turn state)
          (dsh-emacs-render--work-details turn state))))))

;;; ---------------------------------------------------------------------------
;;; Renderer: turn start / end / interrupt / error
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-render-turn-start (event)
  "Record a `turn/start' EVENT without adding visual chrome.
The event stream is the authoritative source for turn liveness: a replayed
or re-fetched history whose tail is a `turn/start' without a matching
`turn/end' means the turn is still in flight, so re-light the mode-line
running spinner (idempotent — the send path already lit it, and a
`turn/end' later clears it)."
  ;; A turn started (or a still-open turn was replayed after a reconnect /
  ;; session reopen): light the mode-line running spinner.  The turn start
  ;; also bounds dsh web's idle-steer inbox classification.
  (setq dsh-emacs-render--turn-start-seq
        (dsh-protocol-event-sequence--from-alist event)
        dsh-emacs-render--turn-step nil
        dsh-emacs-render--turn-opener-painted nil
        dsh-emacs-render--turn-claim-slots nil)
  (unless (dsh-emacs-render--history-page-p)
    (dsh-emacs--ml-busy-set t))
  (dsh-protocol-event-sequence--from-alist event))

;;; ---------------------------------------------------------------------------
;;; Native desktop notification when a run ends
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-notify--visible-p (&optional buffer)
  "Return non-nil when BUFFER (default: current) is visible on a focused frame."
  (cl-some (lambda (window)
             (eq t (frame-focus-state (window-frame window))))
           (get-buffer-window-list (or buffer (current-buffer)) nil t)))

(defun dsh-emacs-notify--post (session-id body &optional buffer)
  "Post BODY for SESSION-ID unless its chat is already visible.
The visibility gate applies to BUFFER (default: the current buffer, which
is the chat buffer when called from the render dispatch); SESSION-ID only
identifies the chat for the notification title."
  (when (and dsh-emacs-enable-notifications
             (not (dsh-emacs-notify--visible-p buffer)))
    (let ((title (or (and (stringp session-id)
                          (dsh-emacs--chat-title session-id))
                     (buffer-name (or buffer (current-buffer))))))
      (setq title (replace-regexp-in-string "[[:cntrl:]]" " " title)
            body (replace-regexp-in-string "[[:cntrl:]]" " " body))
      (condition-case err
          (cond
           ((fboundp 'w32-notification-notify)
            (w32-notification-notify :title title :body body))
           ((fboundp 'ns-do-applescript)
            (ns-do-applescript
             (format "display notification %S with title %S" body title)))
           ((and (eq system-type 'darwin) (executable-find "osascript"))
            (start-process "dsh-notification" nil "osascript" "-e"
                           (format "display notification %S with title %S"
                                   body title)))
           ((and (featurep 'dbusbind)
                 (ignore-errors (require 'notifications nil t))
                 (fboundp 'notifications-notify))
            (notifications-notify :title title :body body
                                  :app-name "dsh-emacs"))
           ((executable-find "notify-send")
            (start-process "dsh-notification" nil "notify-send" title body))
           (t (message "dsh: %s — %s" title body)))
        (error (message "dsh: %s — %s (%s)" title body
                        (error-message-string err)))))))

(defun dsh-emacs-render-turn-end (event)
  "Record a `turn/end' event; surface a failed model run.
A terminal `turn/end' whose DATA.REASON.KIND is \"error\" (dsh web's
turn-error node — the provider rejected the run: quota, rate, ...)
renders as a visible error row; anything else just clears the running
spinner."
  (dsh-emacs-render--flush-stream nil t)
  ;; A turn's declared deliverables close the transcript after its final
  ;; message (web's turnTail), so they are rendered here, not at their own
  ;; event position.
  (let ((turn (dsh-protocol-turn--from-alist event)))
    (when (integerp turn)
      (dsh-emacs-render--flush-deliverables turn)))
  ;; The turn finished: stop the mode-line running spinner and drop the
  ;; attribution bounds (no message can belong to a closed turn).
  (setq dsh-emacs-render--turn-start-seq nil
        dsh-emacs-render--turn-step nil
        dsh-emacs-render--turn-opener-painted nil
        dsh-emacs-render--turn-claim-slots nil)
  (unless (dsh-emacs-render--history-page-p)
    (dsh-emacs--ml-busy-set nil))
  ;; A failed run must not be silently swallowed: dsh signals it as
  ;; `turn/end' + data.reason.kind = \"error\", mirroring dsh web's
  ;; turn-error node.
  (let ((failure (dsh-protocol-turn-failure--from-alist event)))
    (when failure
      (dsh-emacs-render-info
       "Model error" (car failure) nil (cdr failure)))
    ;; The flag covers only runs submitted by this client: a replayed
    ;; `turn/end' (reload, reconnect) or an interrupted run stays silent.
    (when dsh-emacs--turn-awaiting
      (setq dsh-emacs--turn-awaiting nil)
      (dsh-emacs-notify--post
       (and (boundp 'dsh-emacs--buffer-session)
            dsh-emacs--buffer-session)
       (if failure (format "✗ Run failed — %s" (car failure))
         "✓ Run finished"))))
  (dsh-protocol-event-sequence--from-alist event))

(defun dsh-emacs-render-info (label text &optional block-id detail)
  "Render a compact event row with LABEL, TEXT and optional muted DETAIL.
BLOCK-ID identifies the fragment.  Keep the explanation expanded initially."
  (let* ((ns (dsh-emacs-render--make-namespace))
         (bid (or block-id (format "info-%d" (random 999999))))
         (insert-point (dsh-emacs-render--input-insert-point)))
    (dsh-emacs-ui-update-fragment
     (dsh-emacs-ui-make-fragment
      :namespace-id ns
      :block-id bid
      :label-left (concat (dsh-emacs-render--event-icon 'error) " "
                          (propertize label
                                      'face (dsh-emacs-render--row-label-face
                                             'dsh-emacs-tool-title-face)))
      :label-right (when detail
                     (propertize detail 'face 'dsh-emacs-timestamp-face))
      :body text
      :body-face 'dsh-emacs-thinking-body-face
      :style 'minimal
      :status 'info)
     :create-new t :expanded t
     :insert-before insert-point)))

(defun dsh-emacs-render-compaction-summary (event)
  "Render automatic compaction EVENT as a folded tool-style row; return seq.
The row records a generated summary, not successful checkpoint application.
Manual compactions retain their command card; later automatic failures keep
their own error card.  Neither the old conversation nor input history changes."
  (let* ((summary (dsh-protocol--struct
                   #'dsh-protocol-compaction-summary-p
                   #'dsh-protocol-compaction-summary--from-alist event))
         (seq (dsh-protocol-compaction-summary-seq summary))
         (text (dsh-protocol-compaction-summary-text summary))
         (items (dsh-protocol-compaction-summary-item-count summary))
         (tokens (dsh-protocol-compaction-summary-token-count summary)))
    (unless (dsh-protocol-compaction-summary-command-id summary)
      (dsh-emacs-ui-update-fragment
       (dsh-emacs-ui-make-fragment
        :namespace-id (dsh-emacs-render--make-namespace)
        :block-id (format "compaction-summary-%s"
                          (or (dsh-protocol-compaction-summary-id summary) seq))
        ;; Web's CompactionItem shares the terminal icon with tool rows.
        ;; Do not borrow a success tint: the checkpoint is not committed yet.
        :label-left (concat
                     (dsh-emacs-render--tool-icon "bash") " "
                     (propertize "Automatic compaction"
                                 'face (dsh-emacs-render--row-label-face
                                        'dsh-emacs-tool-title-face)))
        :label-right
        (propertize
         (string-join
          (delq nil
                (list (when items
                        (format "%d history item%s" items
                                (if (= items 1) "" "s")))
                      (when tokens
                        (format "~%s tokens" (dsh-emacs-format-tokens tokens)))))
          " · ")
         'face 'dsh-emacs-timestamp-face
         'help-echo "Size of the summarized history; not tokens saved")
        :body (unless (string-blank-p text) (dsh-emacs-markdown-render text))
        :style 'minimal :status 'compaction-summary
        :non-foldable (string-blank-p text))
       :expanded nil :insert-before (dsh-emacs-render--input-insert-point)))
    seq))

;;; ---------------------------------------------------------------------------
;;; Renderer: step boundaries and attempts (V3 vocabulary completion)
;;; ---------------------------------------------------------------------------
;;; `step/start' / `step/end' (a step = one model call plus the tool executions
;;; it requested) are turn-internal boundaries, not conversation content: they
;;; go to the modeline step badge (see `dsh-emacs-modeline-note-step') and take
;;; no transcript space.
;;; `assistant/attempt' (a failed/retried/cancelled attempt that submitted no
;;; surface message, with content only in data.stream) carries body meaning
;;; and renders a card.  `session/end-seed' only advances the event anchor.

(defun dsh-emacs-render-step-event (event)
  "Feed a `step/start' / `step/end' EVENT to the mode-line step badge.
Steps are boundaries of a turn, not transcript content: the transcript stays
content-only, and the badge shows which step of the running turn is active.
Returns the event seq so the follow stream's dedup anchor advances."
  (let ((position (dsh-protocol-turn-step-event--from-alist event)))
    (dsh-emacs-modeline-note-step
     (dsh-protocol-turn-step-event-turn position)
     (dsh-protocol-turn-step-event-step position)
     (equal (dsh-protocol-turn-step-event-kind position) "step/start")))
  (dsh-protocol-event-sequence--from-alist event))

(defun dsh-emacs-render--assistant-stream-text (stream)
  "Reconstruct the visible text of an assistant attempt STREAM.
STREAM is the decoded `AssistantStreamRecord' list of `assistant/attempt'
(and `assistant/message'): deltas are packed into `text-chunks' /
`reasoning-chunks' runs (parallel `texts' arrays) and tool calls into
`tool-call-chunks'.  Reasoning is included only when reasoning display is on.
Returns the record-ordered content as one newline-joined string."
  (let ((parts '()))
    (dolist (record stream)
      (let ((type (dsh-protocol-assistant-record-type record)))
        (pcase type
          ((or "text-chunks" "reasoning-chunks")
           (when (or dsh-emacs-show-thinking
                     (equal type "text-chunks"))
             (let ((text (apply #'concat
                                (dsh-protocol-assistant-record-texts record))))
               (unless (string-empty-p text)
                 (push text parts)))))
          ("tool-call-chunks"
           (let ((name (dsh-protocol-assistant-record-name record))
                 (args (apply #'concat
                              (dsh-protocol-assistant-record-args record))))
             (push (dsh-emacs-render--trim
                    (concat "→ " (or name "tool")
                            (unless (string-empty-p args)
                              (concat " " args)))
                    dsh-emacs-tool-call-chars)
                   parts))))))
    (mapconcat #'identity (nreverse parts) "\n")))

(defun dsh-emacs-render--discard-stream (&optional key)
  "Discard uncommitted transcript blocks, optionally only for step KEY.
Used when an attempt is replaced by its diagnostic card or a reconnect
snapshot. Settled messages and the input draft stay intact. Return non-nil
when visible content was removed."
  (let* ((step (when (or (null key)
                         (equal key (plist-get dsh-emacs--streamed-step :key)))
                 dsh-emacs--streamed-step))
         (states (cl-remove-if-not
                  (lambda (state)
                    (and state (or (null key)
                                   (equal key (plist-get state :key)))))
                  (list dsh-emacs--streaming-assistant
                        dsh-emacs--streaming-thinking)))
         (size (buffer-size))
         (windows (when (or states (plist-get step :text-regions)
                            (plist-get step :thinking-blocks))
                    (dsh-emacs-render--following-windows)))
         (inhibit-read-only t)
         (buffer-undo-list t))
    (when step
      (dsh-emacs-render--drop-committed-text step)
      (dsh-emacs-render--drop-committed-thinking step)
      (setq dsh-emacs--streamed-step nil))
    (dolist (state states)
      (when-let* ((timer (plist-get state :timer)))
        (cancel-timer timer))
      (setq dsh-emacs--markdown-pending
            (delq state dsh-emacs--markdown-pending))
      (when (plist-get state :markdown)
        (dsh-emacs-render--reset-markdown-state state))
      (if (plist-get state :inline)
          ;; A live inline row is a fragment, not a raw region.
          (dsh-emacs-ui-delete-fragment (plist-get state :ns)
                                        (plist-get state :block-id))
        (delete-region (plist-get state :start) (plist-get state :end))
        (set-marker (plist-get state :start) nil)
        (set-marker (plist-get state :end) nil))
      (when (eq state dsh-emacs--streaming-assistant)
        (setq dsh-emacs--streaming-assistant nil))
      (when (eq state dsh-emacs--streaming-thinking)
        (setq dsh-emacs--streaming-thinking nil)))
    (when (< (buffer-size) size)
      (dsh-emacs-render--follow-stream windows)
      t)))

(defun dsh-emacs-render--note-attempt-outcome (event)
  "Merge decoded EVENT and classify this turn's visible attempt cards.
Replay by seq, not arrival order: an older page may arrive after its outcome.
A retry consumes only the preceding attempt in the same step.  Turn failure
settles the last unresolved attempt; it never relabels earlier started retries."
  (when (and event
             (integerp (dsh-protocol-execution-event-turn event))
             (integerp (dsh-protocol-execution-event-seq event))
             (member (dsh-protocol-execution-event-type event)
                     '("assistant/attempt" "assistant/message" "llm/retry"
                       "llm/retry-started" "turn/end")))
    (unless dsh-emacs-render--attempt-turns
      (setq dsh-emacs-render--attempt-turns (make-hash-table :test 'eql)))
    (let* ((turn (dsh-protocol-execution-event-turn event))
           (seq (dsh-protocol-execution-event-seq event))
           (state (or (gethash turn dsh-emacs-render--attempt-turns)
                      (list :facts nil :position (make-marker) :seq nil)))
           (facts (plist-get state :facts))
           (pending nil)
           (waiting nil)
           (cards nil))
      (setf (alist-get seq facts) event)
      (setq facts (sort facts (lambda (a b) (< (car a) (car b)))))
      (setf (plist-get state :facts) facts)
      (puthash turn state dsh-emacs-render--attempt-turns)
      (dolist (entry facts)
        (let* ((fact (cdr entry))
               (type (dsh-protocol-execution-event-type fact)))
          ;; Recovery plugins can retry directly without an llm/retry event.
          ;; Another response in the same step proves the request resumed.
          (when (and (member type '("assistant/attempt" "assistant/message"))
                     (or pending waiting)
                     (equal (dsh-protocol-execution-event-step fact)
                            (dsh-protocol-execution-event-step
                             (plist-get (or pending waiting) :event))))
            (if pending
                (setf (plist-get pending :cause) fact
                      (plist-get pending :label) "Retried")
              (setf (plist-get waiting :label) "started")))
          (pcase type
            ("assistant/attempt"
             (setq pending (list :event fact :label "Incomplete reply"
                                 :cause nil)
                   waiting nil)
             (push pending cards))
            ("assistant/message" (setq pending nil waiting nil))
            ("llm/retry"
             (when (and pending
                        (equal (dsh-protocol-execution-event-step fact)
                               (dsh-protocol-execution-event-step
                                (plist-get pending :event))))
               (setf (plist-get pending :cause) fact
                     (plist-get pending :label) "scheduled")
               (setq waiting pending pending nil)))
            ("llm/retry-started"
             (when-let* ((retry (plist-get waiting :cause)))
               (when (and (equal (dsh-protocol-execution-event-id fact)
                                 (dsh-protocol-execution-event-id retry))
                          (equal (dsh-protocol-execution-event-step fact)
                                 (dsh-protocol-execution-event-step retry))
                          (equal (dsh-protocol-execution-event-attempt fact)
                                 (dsh-protocol-execution-event-attempt retry)))
                 (setf (plist-get waiting :label) "started")
                 (setq waiting nil))))
            ("turn/end"
             (let ((card (or pending waiting))
                   (reason (dsh-protocol-execution-event-reason fact)))
               (when (and card (member reason '("error" "aborted")))
                 (setf (plist-get card :cause) fact
                       (plist-get card :label)
                       (if (equal reason "error") "Failed reply"
                         (if waiting "Retry cancelled" "Cancelled reply")))))
             (setq pending nil waiting nil)))))
      (dolist (card cards)
        (let* ((attempt (plist-get card :event))
               (cause (plist-get card :cause))
               (label (plist-get card :label))
               (retry (and cause
                           (equal (dsh-protocol-execution-event-type cause)
                                  "llm/retry")))
               (recovered (and cause
                               (member (dsh-protocol-execution-event-type cause)
                                       '("assistant/attempt" "assistant/message"))))
               (detail (if recovered
                           "A later response was recorded for the same turn and step"
                         (and cause
                              (string-join
                               (delq nil
                                     (list (dsh-protocol-execution-event-provider cause)
                                           (dsh-protocol-execution-event-code cause)
                                           (dsh-protocol-execution-event-message cause)))
                               " · "))))
               (block (dsh-emacs-ui-find-block
                       (dsh-emacs-render--make-namespace)
                       (format "evt-%s" (dsh-protocol-execution-event-seq attempt)))))
          ;; Trimming may have removed this card.  Never recreate it at the tail.
          (when block
            (let ((model (copy-tree (get-text-property
                                     (car block) 'dsh-emacs-ui-state))))
              (when retry
                (setq label
                      (format "Retry %s%s · %s"
                              (dsh-protocol-execution-event-attempt cause)
                              (if-let* ((limit (dsh-protocol-execution-event-limit cause)))
                                  (format "/%s" limit) "")
                              label)))
              (setf (map-elt model :label-left)
                    (concat (dsh-emacs-render--event-icon
                             (cond ((or retry recovered) 'retry)
                                   ((and cause
                                         (equal (dsh-protocol-execution-event-reason cause)
                                                "error"))
                                    'error)
                                   (t 'idle)))
                            " " (propertize label
                                            'face (dsh-emacs-render--row-label-face
                                                   'dsh-emacs-tool-title-face)
                                            'help-echo (or detail "Outcome not available")))
                    (map-elt model :label-right)
                    (propertize
                     (concat (format "turn %s · step %s" turn
                                     (dsh-protocol-execution-event-step attempt))
                             (when (and retry (numberp (dsh-protocol-execution-event-delay cause)))
                               (format " · wait %gs"
                                       (/ (dsh-protocol-execution-event-delay cause) 1000.0))))
                     'face 'dsh-emacs-timestamp-face 'help-echo detail))
              (dsh-emacs-ui-update-fragment
               (assq-delete-all :collapsed model))))))
      ;; Older pages must not move the retained frontier back to an old card.
      ;; Leave the marker before subsequent turns inserted at this boundary.
      (when (or (null (plist-get state :seq))
                (>= seq (plist-get state :seq)))
        (setf (plist-get state :seq) seq)
        (set-marker (plist-get state :position)
                    (dsh-emacs-render--input-insert-point))))))

(defun dsh-emacs-render-assistant-attempt (event)
  "Render an `assistant/attempt' EVENT as one compact unfinished-reply card.
An attempt that settled without committing a surface message (failure,
retry, cancellation) has no `assistant/message'; its exact stream is the only
record of what the model produced.  The card opens expanded when it replaced
a visible live body, collapsed when replayed from history."
  (let* ((position (dsh-protocol-turn-step-event--from-alist event))
         (live (dsh-emacs-render--discard-stream
                (dsh-protocol-stream-key--from-alist event)))
         (body (dsh-emacs-render--assistant-stream-text
                (dsh-protocol-turn-step-event-stream position)))
         (empty (string-empty-p body)))
    (dsh-emacs-ui-update-fragment
     (dsh-emacs-ui-make-fragment
      :namespace-id (dsh-emacs-render--make-namespace)
      :block-id (dsh-emacs-render--make-block-id event)
      :label-left
      (concat (dsh-emacs-render--event-icon 'idle) " "
              (propertize "Incomplete reply"
                          'face (dsh-emacs-render--row-label-face
                                 'dsh-emacs-tool-title-face)
                          'help-echo "Uncommitted output; may follow failure, retry or cancellation"))
      :label-right
      (propertize (format "turn %s · step %s"
                          (dsh-protocol-turn-step-event-turn position)
                          (dsh-protocol-turn-step-event-step position))
                  'face 'dsh-emacs-timestamp-face)
      :body (unless empty body)
      :style 'minimal
      :status 'attempt
      :body-face 'dsh-emacs-thinking-body-face
      :non-foldable empty)
     :create-new t
     :expanded (and live (not empty))
     :insert-before (dsh-emacs-render--input-insert-point)))
  (dsh-protocol-event-sequence--from-alist event))

;;; ---------------------------------------------------------------------------
;;; Renderer: deliverables/presented (files the present tool declared)
;;; ---------------------------------------------------------------------------
;;; `deliverables/presented' is a durable event appended after the present tool
;;; closes successfully ({turn, callId, files:[{path, description?}]}).  dsh web
;;; merges it with this turn's write/edit changes into the turnTail deliverables
;;; card; here only the explicitly declared part is taken — the file changes
;;; themselves are already shown by the write/edit tool cards in the transcript.
;;; Row rendering is deferred to this turn's `turn/end', so the deliverables row
;;; lands after the closing message (web's turnTail position).

(defun dsh-emacs-render--deliverables-merge (files addition)
  "Merge ADDITION into FILES, last description winning per path.
FILES and ADDITION are (PATH . DESCRIPTION) lists; returns the new list."
  (dolist (file addition files)
    (let ((cell (assoc (car file) files)))
      (if cell
          (setcdr cell (cdr file))
        (setq files (append files (list file)))))))

(defun dsh-emacs-render-deliverables (event)
  "Collect a `deliverables/presented' EVENT for its turn's closing row.
The row itself is rendered by `dsh-emacs-render--flush-deliverables' from
`turn/end' (or at the end of a history batch whose snapshot cut the turn
before its `turn/end').  Returns the event seq."
  (let* ((view (dsh-protocol--struct
                #'dsh-protocol-deliverables-p
                #'dsh-protocol-deliverables--from-alist event))
         (turn (dsh-protocol-deliverables-turn view))
         (files (dsh-protocol-deliverables-files view)))
    (when (and (integerp turn) files)
      (let ((cell (assq turn dsh-emacs-render--turn-deliverables)))
        (if cell
            (setcdr cell (dsh-emacs-render--deliverables-merge
                          (cdr cell) files))
          (push (cons turn files) dsh-emacs-render--turn-deliverables))))
    (dsh-protocol-deliverables-seq view)))

(defun dsh-emacs-render--deliverable-line (file)
  "Return one deliverables body line for FILE, a (PATH . DESCRIPTION) cell.
The path is a clickable file reference (RET / mouse-1 opens it).  A
description is flattened to one line: one body line means one file, so a
newline inside a model-written description must not fake a second entry."
  (concat (dsh-emacs-reference-file-link (car file))
          (when (cdr file)
            (propertize
             (concat " — " (string-trim
                            (replace-regexp-in-string
                             "[\n\r]+" " " (cdr file))))
             'face 'dsh-emacs-muted-face))))

(defun dsh-emacs-render--deliverables-body (files)
  "Compose the expanded deliverables FILES as indented file lines.
One `  PATH — DESCRIPTION' line per file.  No panel/background band: the
paths carry their own clickable link face, and the row stays plain
transcript text."
  (mapconcat (lambda (file)
               (concat "  " (dsh-emacs-render--deliverable-line file)))
             files
             "\n"))

(defun dsh-emacs-render--deliverables-row (turn files)
  "Render TURN's FILES, a (PATH . DESCRIPTION) list, as one green row.
A green dot and green title lead the collapsed row (the produced/delivered
marker, `dsh-emacs-deliverable-dot-face' / `-text-face'); expanding shows one
indented line per file, with no body background."
  (let ((count (length files)))
    (dsh-emacs-ui-update-fragment
     (dsh-emacs-ui-make-fragment
      :namespace-id (dsh-emacs-render--make-namespace)
      :block-id (format "deliverables-%s" turn)
      :label-left (concat
                   (propertize "● " 'face 'dsh-emacs-deliverable-dot-face)
                   (propertize
                    (format "Deliverables · %d file%s" count
                            (if (= count 1) "" "s"))
                    'face (dsh-emacs-render--row-label-face
                           'dsh-emacs-deliverable-text-face)))
      :body (dsh-emacs-render--deliverables-body files)
      :style 'minimal
      :status 'deliverables
      :header-face (dsh-emacs-render--row-chrome-face
                    'dsh-emacs-deliverable-text-face))
     :create-new t :expanded nil
     :insert-before (dsh-emacs-render--input-insert-point))))

(defun dsh-emacs-render--flush-deliverables (&optional turn)
  "Render pending deliverables rows and clear them.
With TURN, only that turn's row is rendered (its `turn/end' arrived); without
it, every pending turn is flushed in order — the follow snapshot's
message-aligned tail can cut a turn before its `turn/end', and the batch end
is then the tail."
  (let ((cells (if (integerp turn)
                   (let ((cell (assq turn dsh-emacs-render--turn-deliverables)))
                     (and cell (list cell)))
                 (reverse dsh-emacs-render--turn-deliverables))))
    (dolist (cell cells)
      (dsh-emacs-render--deliverables-row (car cell) (cdr cell))))
  (if (integerp turn)
      (setq dsh-emacs-render--turn-deliverables
            (assq-delete-all turn dsh-emacs-render--turn-deliverables))
    (setq dsh-emacs-render--turn-deliverables nil)))

(defun dsh-emacs-render-command-label (name &optional _args)
  "Return the display string for slash command NAME.
The leading \"/\" is stripped from NAME so the row reads e.g. \"compact\".
ARGS is ignored — command rows show only the command name, not the
user's input text."
  (if (and (stringp name) (string-prefix-p "/" name))
      (substring name 1)
    (or name "")))

(defun dsh-emacs-render--command-label-left (icon label state)
  "Return the left-hand label for a command row.
ICON is the leading bash/tool icon (or nil), LABEL the command text, and
STATE `pending', `success' or `error'.  This is the pure presentation seam:
a future animation can replace the returned string without touching the
row/fragment callers."
  (concat (dsh-emacs-render--tool-leading icon state)
          (propertize label
                      'face (dsh-emacs-render--row-label-face
                             'dsh-emacs-tool-title-face))))

(defun dsh-emacs-render--command-status-text (state)
  "Short status suffix for a slash-command node STATE (success/error)."
  (pcase state
    ('success "✓ done")
    ('error "✗ failed")
    (_ nil)))

;;; ---------------------------------------------------------------------------
;;; Slash-command row styling: bash terminal icon + pending tint
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-render-command-optimistic (line)
  "Render a slash-command row immediately for LINE (e.g. \"/compact\").
This is the optimistic path called from `dsh-emacs--submit-prompt' before
the RPC round-trip, so the user sees the command row instantly.  The temp
entry is tracked in `dsh-emacs--pending-command' and will be replaced by
the real `command/run' event when it arrives."
  (when (and dsh-emacs-show-commands line)
    (let* ((parsed (dsh-emacs-command-parse line))
           (name (car parsed))
           (args (cdr parsed))
           (temp-id (format "pending-%s" name))
           (label (dsh-emacs-render-command-label
                   (concat "/" name) args))
           (icon (dsh-emacs-render--tool-icon "bash"))
           (ns (dsh-emacs-render--make-namespace))
           (block-id (format "cmd-%s" temp-id)))
      (when (and name (not (gethash temp-id dsh-emacs--command-blocks)))
        (puthash temp-id (list ns block-id label icon)
                 dsh-emacs--command-blocks)
        (setq dsh-emacs--pending-command (list temp-id label))
        (dsh-emacs-ui-update-fragment
         (dsh-emacs-ui-make-fragment
          :namespace-id ns :block-id block-id
          :label-left (dsh-emacs-render--command-label-left
                       icon label 'pending)
          :style 'minimal
          :status 'tool-pending
          :header-face (dsh-emacs-render--row-chrome-face
                        'dsh-emacs-tool-pending-face))
         :create-new t :expanded t
         :insert-before (dsh-emacs-render--input-insert-point))))))

(defun dsh-emacs-render-command-cleanup-optimistic ()
  "Remove the optimistic slash-command row (if any) on RPC error or miss.
Deletes the fragment and clears `dsh-emacs--pending-command'."
  (when dsh-emacs--pending-command
    (let* ((temp-id (nth 0 dsh-emacs--pending-command))
           (entry (gethash temp-id dsh-emacs--command-blocks)))
      (when entry
        (dsh-emacs-ui-delete-fragment (nth 0 entry) (nth 1 entry)))
      (remhash temp-id dsh-emacs--command-blocks))
    (setq dsh-emacs--pending-command nil)))

(defun dsh-emacs-render-command (event)
  "Render a `command/run' or `command/done' EVENT as one flow node,
mirroring dsh web's command rows: a leading bash terminal icon (the same
dsh-web SVG as bash tool rows, or one tool-accent dot on displays without
SVG) followed
by the command name; a running row is marked by the pending
tint and leading icon color, with no timer-driven animation.
On completion the header shows only the command name + a short status
(`✓ done' / `✗ failed', green on success, red on error), and the outcome
text is folded into a collapsible body below, collapsed by default.

Run creates the node; done (matched by commandId) restyles it — success
turns the row green, error red.  Events on load render in seq order, so
a run followed by its done (the usual shape) becomes a single node.
Returns the event seq."
  (let ((seq (dsh-protocol-event-sequence--from-alist event)))
    (when dsh-emacs-show-commands
      (pcase-let (((cl-struct dsh-protocol-command-event
                              type command-id name kind text)
                   (dsh-protocol-command-event--from-alist event)))
        (when command-id
          (if (equal type "command/run")
              (let* ((ns (dsh-emacs-render--make-namespace))
                     (block-id (format "cmd-%s" command-id))
                     (label (dsh-emacs-render-command-label name))
                     (icon (dsh-emacs-render--tool-icon "bash")))
                ;; Only a live run takes over the optimistic submit row.
                (unless (dsh-emacs-render--history-page-p)
                  (dsh-emacs-render-command-cleanup-optimistic))
                (puthash command-id (list ns block-id label icon)
                         dsh-emacs--command-blocks)
                (dsh-emacs-ui-update-fragment
                 (dsh-emacs-ui-make-fragment
                  :namespace-id ns :block-id block-id
                  :label-left (dsh-emacs-render--command-label-left
                               icon label 'pending)
                  :style 'minimal
                  :status 'tool-pending
                  :header-face (dsh-emacs-render--row-chrome-face
                                'dsh-emacs-tool-pending-face))
                 :create-new t :expanded nil
                 :insert-before (dsh-emacs-render--input-insert-point)))
            (when-let* ((entry (gethash command-id dsh-emacs--command-blocks)))
              (pcase-let* ((`(,ns ,block-id ,label ,icon) entry)
                           (ok (not (equal kind "error")))
                           (state (if ok 'success 'error))
                           (face (if ok 'dsh-emacs-tool-success-face
                                   'dsh-emacs-tool-error-face))
                           (entry-icon (or icon
                                           (dsh-emacs-render--tool-icon "bash"))))
                (dsh-emacs-ui-update-fragment
                 (dsh-emacs-ui-make-fragment
                  :namespace-id ns :block-id block-id
                  :label-left (dsh-emacs-render--command-label-left
                               entry-icon label state)
                  ;; Keep the run's label and a short status in the header;
                  ;; the possibly multi-line result belongs in the folded body.
                  :label-right (propertize
                                (or (dsh-emacs-render--command-status-text state)
                                    "")
                                'face (if (eq dsh-emacs-render-style 'simple)
                                          'dsh-emacs-timestamp-face
                                        face))
                  :body (and (stringp text) (not (string-empty-p text)) text)
                  :style 'minimal
                  :status (if ok 'tool-success 'tool-error)
                  ;; The body does not inherit a header accent; `simple'
                  ;; keeps the whole header neutral for the colored dot.
                  :header-face (dsh-emacs-render--row-chrome-face face))
                 :create-new nil)))))))
    seq))

;; ---------------------------------------------------------------------------
;; Renderer: local `!command' command lines (called by dsh-emacs-shell.el)
;; ---------------------------------------------------------------------------
;; `!<command>' runs locally rather than as a server slash command, but its row
;; style is exactly that of `command/run': bash icon + pending coloring; when it finishes it shows the exit code and collects the output
;; into a collapsible body.  The two functions are uniquely associated across
;; buffers by the id returned from `dsh-emacs-render-shell-start'.

(defvar dsh-emacs--shell-seq 0
  "Monotonic counter for local `!command' row ids.
Ids are `shell-N' strings; the counter never repeats, so concurrent and
consecutive runs can not collide in `dsh-emacs--command-blocks'.")

(defun dsh-emacs-render-shell-start (command)
  "Render the pending row of a local `!command' run; return its id.
Inserts a row (bash icon + COMMAND, pending tinted) above the input,
exactly like a running slash-command row.  The caller passes the
returned id back to `dsh-emacs-render-shell-done' once the process
finishes."
  (let* ((id (format "shell-%d" (setq dsh-emacs--shell-seq
                                     (1+ dsh-emacs--shell-seq))))
         (icon (dsh-emacs-render--tool-icon "bash"))
         (ns (dsh-emacs-render--make-namespace))
         (block-id (format "cmd-%s" id)))
    (puthash id (list ns block-id command icon) dsh-emacs--command-blocks)
    (dsh-emacs-ui-update-fragment
     (dsh-emacs-ui-make-fragment
      :namespace-id ns :block-id block-id
      :label-left (dsh-emacs-render--command-label-left
                   icon command 'pending)
      :style 'minimal
      :status 'tool-pending
      :header-face (dsh-emacs-render--row-chrome-face
                    'dsh-emacs-tool-pending-face))
     :create-new t :expanded t
     :insert-before (dsh-emacs-render--input-insert-point))
    id))

(defun dsh-emacs-render-shell-done (id ok exit-code signal output)
  "Restyle the local `!command' row ID with its outcome.
OK / EXIT-CODE / SIGNAL classify the run (success on exit 0); OUTPUT is
the merged stdout+stderr shown as the row body, expanded and tinted with
the tool success/error faces — mirroring `command/done' rows.  No-op when
the row no longer exists (buffer reloaded).  Drops the tracked entry once the
row is settled."
  (when-let* ((entry (gethash id dsh-emacs--command-blocks)))
    (let* ((state (if ok 'success 'error))
           (face (if ok 'dsh-emacs-tool-success-face
                   'dsh-emacs-tool-error-face))
           (entry-icon (or (nth 3 entry)
                           (dsh-emacs-render--tool-icon "bash")))
           (status (dsh-emacs-render--tool-status-text state exit-code signal))
           (body (and (stringp output) (not (string-empty-p output)) output)))
      (dsh-emacs-ui-update-fragment
       (dsh-emacs-ui-make-fragment
        :namespace-id (nth 0 entry) :block-id (nth 1 entry)
        :label-left (dsh-emacs-render--command-label-left
                     entry-icon (nth 2 entry) state)
        :label-right (propertize
                      (or status "")
                      'face (if (eq dsh-emacs-render-style 'simple)
                                'dsh-emacs-timestamp-face
                              face))
        :body body
        :style 'minimal
        :status (if ok 'tool-success 'tool-error)
        ;; In `full' the success/error accent covers the header row only;
        ;; `simple' keeps it neutral for the colored dot.
        :header-face (dsh-emacs-render--row-chrome-face face))
       :create-new nil :expanded t)
      (remhash id dsh-emacs--command-blocks))))

;;; ---------------------------------------------------------------------------
;;; Top-level dispatcher
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-render-event (event)
  "Dispatch EVENT to the appropriate renderer. Returns the event seq, or nil."
  (let* ((type (dsh-protocol-event-kind--from-alist event))
         (execution (dsh-protocol-execution-event--from-alist event))
         (replacement (dsh-protocol-replacement--from-alist event))
         (chunk (and (equal type "assistant/chunk")
                     (dsh-protocol-chunk--from-alist event)))
         (chunk-type (and chunk (dsh-protocol-chunk-kind chunk)))
         (seq nil)
         (reply (and (or dsh-emacs-reply-footer-items
                         dsh-emacs-fold-work-details)
                     (not replacement)
                     (dsh-protocol-reply-event--from-alist event)))
         (start-marker nil))
    ;; Publish queued text before another event can insert transcript content.
    (when (and (plist-get dsh-emacs--streaming-assistant :timer)
               (not (equal chunk-type "text-delta")))
      (dsh-emacs-render--flush-stream))
    ;; Preserve event order at boundaries; reasoning has its own burst timer.
    (unless (equal chunk-type "reasoning-delta")
      (dsh-emacs-render--flush-thinking))
    (when (and execution (not (dsh-emacs-render--history-page-p)))
      (dsh-emacs-modeline-note-execution execution))
    (setq start-marker
          (and reply (copy-marker
                      (or (dsh-emacs-render--input-insert-point) (point-max)) nil)))
    (unwind-protect
        (progn
          (pcase type
            ((or "llm/retry" "llm/retry-started" "compaction/start")
             (setq seq (dsh-protocol-event-sequence--from-alist event)))
            ("compaction/summary"
             (setq seq (dsh-emacs-render-compaction-summary event)))
            ("compaction/end"
             (setq seq (dsh-protocol-event-sequence--from-alist event))
             ;; Slash-command failures already have a command/done card.  An
             ;; automatic compaction needs its own durable, inspectable failure.
             (when (and (dsh-protocol-execution-event-message execution)
                        (not (dsh-protocol-execution-event-command-id execution)))
               (dsh-emacs-render-info
                "Context compaction failed"
                (dsh-protocol-execution-event-message execution)
                (format "compaction-%s"
                        (dsh-protocol-execution-event-id execution)))))
            ("user/message" (setq seq (dsh-emacs-render-user-message event)))
            ("assistant/chunk"
             (setq seq (dsh-emacs-render-assistant-chunk event chunk)))
            ("assistant/message" (setq seq (dsh-emacs-render-assistant-message event))
             (unless (dsh-emacs-render--history-page-p)
               (dsh-emacs-modeline-note-event event)))
            ;; A `plan/mode' record is durable but paints no row: the `plan'
            ;; projection owns the badge, so the event is only consumed.
            ("plan/mode" (setq seq (dsh-protocol-event-sequence--from-alist event)))
            ("request/context" (setq seq (dsh-protocol-event-sequence--from-alist event))
             (unless (dsh-emacs-render--history-page-p)
               (dsh-emacs-modeline-note-request event)))
            ("request/header" (setq seq (dsh-protocol-event-sequence--from-alist event))
             (unless (dsh-emacs-render--history-page-p)
               (dsh-emacs-modeline-note-header event)))
            ("tool/call" (setq seq (dsh-emacs-render-tool-call event)))
            ;; A replacement `tool/result' rewrites what the model sees; the human
            ;; card keeps the append-origin record.  Skipping the copy still counts
            ;; the event as consumed (seq returned), so the dedup anchor advances.
            ("tool/result" (if replacement
                               (setq seq (dsh-protocol-event-sequence--from-alist event))
                             (setq seq (dsh-emacs-render-tool-result event))))
            ("command/run" (setq seq (dsh-emacs-render-command event)))
            ("command/done" (setq seq (dsh-emacs-render-command event)))
            ("turn/start" (setq seq (dsh-emacs-render-turn-start event)))
            ("turn/end" (setq seq (dsh-emacs-render-turn-end event)))
            ((or "step/start" "step/end")
             (when (equal type "step/start")
               (setq dsh-emacs-render--turn-step
                     (dsh-protocol-turn-step-event-step
                      (dsh-protocol-turn-step-event--from-alist event))))
             (setq seq (if (dsh-emacs-render--history-page-p)
                           (dsh-protocol-event-sequence--from-alist event)
                         (dsh-emacs-render-step-event event))))
            ("assistant/attempt"
             (setq seq (dsh-emacs-render-assistant-attempt event)))
            ("session/end-seed" (setq seq (dsh-protocol-event-sequence--from-alist event)))
            ;; Display-only attribution state: no row, but the seq is durable
            ;; and must advance the anchor like any other consumed record.
            ("agent/inbox/spliced"
             (setq seq (dsh-emacs-render--note-inbox-splice event)))
            ("deliverables/presented"
             (setq seq (dsh-emacs-render-deliverables event)))
            (_ nil))
          (unless replacement
            (dsh-emacs-render--note-attempt-outcome execution))
          (when reply
            (dsh-emacs-render--note-reply-event reply start-marker))
          (when (and (integerp seq)
                     (boundp 'dsh-emacs--anchor-seq)
                     (> seq (or dsh-emacs--anchor-seq 0)))
            (setq dsh-emacs--anchor-seq seq))
          seq)
      (when start-marker
        (set-marker start-marker nil)))))

(defun dsh-emacs-render--consume-pending-user-message (event)
  "Consume one optimistic user message matching EVENT, if present.
The optimistic entry is the exact text dsh-emacs submitted (session references
kept in their canonical `@[label](dsh-session:…)' form), but the host echoes
that user message with references already normalized to their readable `@label'
(no id).  So an entry also matches when its display form (`dsh-emacs-reference-fontify'
collapsing canonical mentions to `@label') equals the echoed text — otherwise
the optimistic copy would survive next to the echoed one and the message would
render twice."
  (when (and (boundp 'dsh-emacs--pending-user-messages)
             (equal (dsh-protocol-event-kind--from-alist event) "user/message"))
    (let* ((message (dsh-protocol-message--from-alist event))
           (text (dsh-emacs-render--text-from-content
                  (dsh-protocol-message-content message)))
           (pending dsh-emacs--pending-user-messages)
           (matched nil)
           remaining)
      (dolist (message pending)
        (if (and (not matched)
                 (or (equal message text)
                     (equal (substring-no-properties
                             (dsh-emacs-reference-fontify message))
                            text)))
            (setq matched message)
          (push message remaining)))
      (when matched
        (setq dsh-emacs--pending-user-messages (nreverse remaining))
        ;; The canonical message now owns this echo: its optimistic rollback
        ;; record must go, or a later re-send of the same text that fails
        ;; could delete this accepted block instead.
        (dsh-emacs--forget-user-message-echo matched))
      matched)))

(defun dsh-emacs-render--trim-buffer ()
  "Trim old transcript content when the buffer exceeds `dsh-emacs-max-buffer-size'.
Defer while loading older history, while any displayed window is reading
above the input anchor, or when the editable input area cannot be located:
without a known boundary there is no cut point that provably spares the
draft.  The size limit is soft in all three cases."
  (when (and dsh-emacs-max-buffer-size
             (> (buffer-size) dsh-emacs-max-buffer-size)
             (not (dsh-emacs-render--history-page-p))
             (let ((followers (dsh-emacs-render--following-windows)))
               (cl-every (lambda (window) (memq window followers))
                         (get-buffer-window-list (current-buffer) nil t))))
    (let* ((limit dsh-emacs-max-buffer-size)
           (input (dsh-emacs-render--input-insert-point))
           (trim-to (and input (min (- (point-max) (/ limit 2)) input))))
      (when (and trim-to (> trim-to (point-min)))
        (let ((inhibit-read-only t)
              (buffer-undo-list t))
          (delete-region (point-min) trim-to))
        (when dsh-emacs-render--attempt-turns
          (maphash
           (lambda (turn state)
             (let ((position (plist-get state :position)))
               (when (<= position (point-min))
                 (set-marker position nil)
                 (remhash turn dsh-emacs-render--attempt-turns))))
           dsh-emacs-render--attempt-turns))
        (when dsh-emacs-render--reply-turns
          (maphash
           (lambda (turn state)
             (when-let* ((start (plist-get state :work-start))
                         ((<= start (point-min))))
               (dsh-emacs-render--release-work-details state))
             (when (and (plist-get state :end-seq)
                        (null (plist-get state :work-start))
                        (or (null (plist-get state :reply-seq))
                            (not (text-property-any
                                  (point-min) (point-max) 'dsh-emacs-message-seq
                                  (plist-get state :reply-seq)))))
               (remhash turn dsh-emacs-render--reply-turns)))
           dsh-emacs-render--reply-turns))))))

(defun dsh-emacs-render--note-history-window (entries has-more)
  "Record the pagination frontier of a freshly seeded history tail.
ENTRIES is the snapshot's message-aligned records (ascending seq) and
HAS-MORE the decoded older-messages flag (a boolean, normalized by the
snapshot decoder).  The earliest rendered seq becomes
`dsh-emacs--history-earliest-seq' — `dsh-emacs-load-older-history' passes it
as the next page's exclusive cursor.  The frontier only moves EARLIER: a
reconnect snapshot's tail can start newer than pages this buffer already
loaded, and moving the cursor past them would make the next page re-fetch
history that is already on screen.  An empty tail leaves it unchanged."
  (when-let* ((event (dsh-protocol-record-event--from-alist (car entries)))
              (seq (dsh-protocol-event-sequence--from-alist event)))
    (when (integerp seq)
      (setq dsh-emacs--history-earliest-seq
            (if (integerp dsh-emacs--history-earliest-seq)
                (min dsh-emacs--history-earliest-seq seq)
              seq))))
  (setq dsh-emacs--history-has-more has-more))

(defun dsh-emacs-render--recall-refs-by-message-seq (events)
  "Map referencing message seq -> its session references in EVENTS.
EVENTS is the [{event: …}] history batch.  dsh web associates each
`session-reference' recall context with the user message that cited it and
immediately precedes it (recall at seq N decorates the message at seq N-1),
so a recall's references are keyed by `recall.seq - 1'.  Returns an alist
(SEQ . REFERENCES)."
  (let ((map '()))
    (dolist (entry events)
      (let* ((ev (and entry (dsh-protocol-record-event--from-alist entry)))
             (seq (and ev (dsh-protocol-event-sequence--from-alist ev))))
        (when (and ev (integerp seq)
                   (equal (dsh-protocol-event-kind--from-alist ev) "user/message"))
          (let ((refs (dsh-protocol-message-references
                       (dsh-protocol-message--from-alist ev))))
            (when refs
              (push (cons (- seq 1) refs) map))))))
    map))

(cl-defun dsh-emacs-render-history-events (events &optional stream bound
                                                  &key insert-before (follow-p t))
  "Render EVENTS in seq order, optionally processing live STREAM chunks.
EVENTS is a vector/sequence of {\"event\": alist} entries.  With STREAM nil
only entries aligned to the live frontier — seq > `dsh-emacs--anchor-seq' —
render; this is the follow snapshot reseed, where completed
`assistant/message' snapshots are sufficient and replaying thousands of old
deltas is avoided (STREAM is a legacy option retained for the shared
renderer, not used by the follow path).

For an older-history prepend, BOUND is the exclusive seq cap of a
`session/page' batch.  Entries with seq < BOUND render in ascending order.
The caller sets `dsh-emacs--history-insert-marker' at INSERT-BEFORE; it
advances with each insertion above the existing transcript.  Stream,
pending-command, todo and turn presentation state are scoped to the page;
mode-line updates and notifications belong only to live events.  `dsh-emacs--anchor-seq' is
left alone: the page sits below the live frontier, and advancing it would
make live events replay.  FOLLOW-P nil leaves the caller's viewport alone —
loading older history must not yank the view to the bottom.

A reseeded user message that references another session arrives with its
session mention collapsed to the readable `@label' (the id stripped), and
the real id+label is delivered by the immediately-following `session-reference'
recall context.  Before rendering, the batch is scanned once to key each
citing message's seq to those references, so the message's `@label' renders
as a real session chip.
Every batch this renderer receives is settled and bounded (an older-history
page or the opening follow snapshot), so it runs to completion; it yields
between groups for timers and process input but defers redisplay until final
footers and work-detail folds are reconciled.  The batch is never abandoned.
Dropping records was the root cause of a wedged mode-line
spinner: the snapshot caller advances `dsh-emacs--anchor-seq' to the snapshot
cursor once the render returns, so a dropped trailing `turn/end' was never
re-delivered and the running animation had no later event to stop it."
  (let* (;; History reconciles its final folds below.  Yields may process
         ;; timers and socket input, but must not paint the unfolded batch.
         (inhibit-redisplay t)
         (entries (if (vectorp events) (append events nil) events))
         (dsh-emacs-render--footer-batch t)
         (dsh-emacs-render--footer-dirty nil)
         (refs-map (and (null stream)
                        (dsh-emacs-render--recall-refs-by-message-seq entries)))
         (cap (and (integerp bound) bound))
         (anchor (or dsh-emacs--anchor-seq 0))
         (prepend-p (and cap (integerp insert-before)
                         (markerp dsh-emacs--history-insert-marker)))
         (rendered 0)
         (counter 0))
    (cl-flet ((consume-entry (entry)
                "Render one history ENTRY; return non-nil when it painted."
                (let* ((ev (dsh-protocol-record-event--from-alist entry))
                       (seq (and ev (dsh-protocol-event-sequence--from-alist ev)))
                       (refs (and (integerp seq)
                                  (cdr (assq seq refs-map))))
                       (within (and ev
                                    (if cap
                                        (< (or seq 0) cap)
                                      (> (or seq 0) anchor)))))
                  (when (and within
                             (or stream
                                 (not (equal (dsh-protocol-event-kind--from-alist ev)
                                             "assistant/chunk"))))
                    (if (and (not prepend-p)
                             (dsh-emacs-render--consume-pending-user-message ev))
                        ;; The optimistic copy is already visible.  Still
                        ;; advance the anchor so this canonical event is not
                        ;; processed repeatedly.
                        (when (integerp seq)
                          (setq dsh-emacs--anchor-seq
                                (max (or dsh-emacs--anchor-seq 0) seq)))
                      (if (and refs
                               (equal (dsh-protocol-event-kind--from-alist ev)
                                      "user/message"))
                          ;; Render the citing message with the recall's real
                          ;; session refs so its readable @label is a jumpable
                          ;; session chip.
                          (when (dsh-emacs-render-user-message ev refs)
                            (unless prepend-p
                              (when (integerp seq)
                                (setq dsh-emacs--anchor-seq
                                      (max (or dsh-emacs--anchor-seq 0) seq))))
                            (setq rendered (1+ rendered))
                            t)
                        (when (dsh-emacs-render-event ev)
                          (setq rendered (1+ rendered))
                          t)))))))
      ;; Both batches this renderer receives are settled and bounded: an older
      ;; history page (PREPEND-P) and the opening follow snapshot.  Run either
      ;; to completion.  The snapshot used to take `while-no-input's early
      ;; exit, which dropped records whenever input was pending; the caller
      ;; then advanced `dsh-emacs--anchor-seq' to the snapshot cursor, so the
      ;; dropped tail was never re-delivered (a dropped `turn/end' wedged the
      ;; mode-line running animation).
      (if prepend-p
          ;; Old pages share the transcript and its fragment index, but must
          ;; not flush a live reply or consume pending turn/command state.
          (let ((dsh-emacs--streaming-assistant nil)
                (dsh-emacs--streaming-thinking nil)
                (dsh-emacs--streamed-step nil)
                (dsh-emacs--turn-awaiting nil)
                (dsh-emacs--pending-command nil)
                (dsh-emacs--todo-list nil)
                (dsh-emacs-render--turn-deliverables nil)
                ;; This page's claims are older than the live tail's; scope
                ;; them so the tail's inbox attribution survives the prepend.
                (dsh-emacs-render--inbox-pending nil)
                (dsh-emacs-render--inbox-claim nil)
                (dsh-emacs-render--turn-start-seq nil)
                (dsh-emacs-render--turn-step nil)
                (dsh-emacs-render--turn-opener-painted nil)
                (dsh-emacs-render--turn-claim-slots nil)
                (work-starts nil))
            ;; Existing turns at the page boundary belong AFTER the page.
            ;; New starts created by this batch still precede their own work.
            (when dsh-emacs-render--reply-turns
              (maphash
               (lambda (_turn state)
                 (when-let* ((marker (plist-get state :work-start))
                             ((= marker insert-before)))
                   (push marker work-starts)
                   (set-marker-insertion-type marker t)))
               dsh-emacs-render--reply-turns))
            (unwind-protect
                (progn
                  (dolist (entry entries)
                    (consume-entry entry))
                  (dsh-emacs-render--flush-deliverables))
              (dolist (marker work-starts)
                (set-marker-insertion-type marker nil))))
        ;; A snapshot is anchor-gated, so records already processed (and
        ;; their claims) are not replayed here; keep the attribution state
        ;; they built.  The full reload path clears it instead.
        (dolist (entry entries)
          (consume-entry entry)
          ;; Let timers and process input run between groups.  Redisplay is
          ;; deferred until this batch's footer and fold reconciliation ends.
          (cl-incf counter)
          (when (>= counter 5)
            (setq counter 0)
            (sit-for 0)))))
    ;; The message-aligned tail can end mid-turn, with a collected
    ;; `deliverables/presented' whose `turn/end' is outside the window; the
    ;; batch end is then the turn's tail, so nothing stays buffered.
    (unless prepend-p
      (dsh-emacs-render--flush-deliverables))
    (dolist (turn dsh-emacs-render--footer-dirty)
      (let ((state (gethash turn dsh-emacs-render--reply-turns)))
        (dsh-emacs-render--reply-footer turn state)
        (dsh-emacs-render--work-details turn state)))
    ;; A prepend is a settled history page: no viewport follow.
    (when (and (> rendered 0) follow-p (not prepend-p))
      (dsh-emacs-render--follow-stream))
    (when (> rendered 0)
      (dsh-emacs-render--trim-buffer))
    rendered))

(defun dsh-emacs-render--history-prepend-marker ()
  "Return a marker at the top of this buffer's loaded transcript, or nil.
The marker aims at the line the oldest transcript block (a UI fragment or a
chat message body) starts on, and advances past content inserted there — a
prepended batch therefore stacks above the block in order.  Returns nil when
the buffer holds no transcript block (nothing to page above)."
  (save-excursion
    (when-let* ((start (text-property-any
                        (point-min) (point-max)
                        'dsh-emacs-transcript-block t)))
      (goto-char start)
      (copy-marker (line-beginning-position) t))))

(provide 'dsh-emacs-render)

;;; dsh-emacs-render.el ends here
