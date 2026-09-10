;;; dsh-emacs-composer.el --- Composer chrome for chat buffers -*- lexical-binding: t; -*-

;; Copyright (C) 2025 vritser

;; Author: vritser
;; Version: 0.3.0
;; License: GPL-3.0-or-later
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; Composer owns the persistent read-only rows above the editable input:
;;
;;   Conversation Buffer
;;   ├── Transcript            -- owned by dsh-emacs-render.el
;;   └── Composer
;;       ├── Goal Row          -- optional goal, phase and actions
;;       ├── Next Message      -- optional pending-message preview
;;       └── Input Area        -- editing/geometry owned by dsh-emacs.el
;;
;; Goal data comes from the goal projection; its actions carry a CAS ref.
;; Queue data stays in dsh-emacs-queue.el, which determines which pending
;; message is visible and when burst updates repaint.  Composer only reads it.
;; Both rows fold line breaks and fit the narrowest viewing window.  Neither
;; row is transcript or editable input, and neither is included when sending.
;;
;; The top marker (insertion type t) is the transcript insertion seam.  The
;; end marker (insertion type nil) stops before the prompt.  They delimit the
;; complete chrome region, whether it contains zero, one or two rows.  Repaints
;; replace only that region and preserve the draft and its cursor position.

;;; Code:

(require 'cl-lib)
(require 'dsh-emacs-protocol)
(require 'dsh-emacs-faces)

;; render.el calls back through this seam.  Declare it without requiring
;; render here to avoid a cycle.  Input-marker geometry remains owned by
;; dsh-emacs.el; this module only reads the shared variable.
(declare-function dsh-emacs-render--input-insert-point "dsh-emacs-render" ())
(declare-function dsh-emacs-queue-next-item "dsh-emacs-queue" ())
(defvar dsh-emacs--input-marker)
(defvar-local dsh-emacs--composer-goal-pending nil
  "Identity token of this buffer's in-flight `goals.*' mutation, or nil.")
(declare-function dsh-emacs--active-session-id "dsh-emacs" ())
(declare-function dsh-emacs--rpc-async "dsh-emacs"
                  (method params callback))

;;; ---------------------------------------------------------------------------
;;; Customization
;;; ---------------------------------------------------------------------------

(defgroup dsh-emacs-composer nil
  "Read-only Goal and Next Message rows in chat buffers."
  :group 'dsh-emacs
  :prefix "dsh-emacs-")

(defcustom dsh-emacs-composer-goal-actions t
  "Whether the Goal Row shows the inline action buttons.
When non-nil the row appends clickable pause/resume/edit/clear dsh-web icons
after the objective (RET or mouse-1 runs the action; see `C-c C-g'); when nil
the row stays a plain read-only icon + objective + phase and the actions are
reachable only through the `C-c C-g' prefix keys.  Turning this off leaves any
already-rendered goal row stale until the next repaint; call
`dsh-emacs-composer-refresh' (or toggle via `dsh-emacs-goal-actions-toggle')
to re-render the current buffer immediately."
  :type 'boolean
  :group 'dsh-emacs-composer)

;;; ---------------------------------------------------------------------------
;;; Buffer-local composer chrome state
;;; ---------------------------------------------------------------------------

(defvar-local dsh-emacs--composer-goal nil
  "A `dsh-protocol-goal' for this session, or nil (no Goal Row shown).
Parsed from the server's `goal' session projection; carries id/revision (the
CAS ref for goal actions) plus objective/phase/blocked-reason.  The goal is
composer chrome — never a message and never sent to the model; only the
explicit `goals.*' actions the user triggers send its ref.")

(defvar-local dsh-emacs--composer-top-marker nil
  "Start of Composer's read-only rows; transcript inserts above this marker.
Its insertion type is t, so streaming leaves it attached to the chrome.")

(defvar-local dsh-emacs--composer-end-marker nil
  "End of Composer chrome, immediately before the editable prompt line.
Its insertion type is nil so text inserted at the prompt stays outside chrome.")

(defvar-local dsh-emacs--composer-sig nil
  "Content and layout inputs of the last rendered Composer region.")

;;; ---------------------------------------------------------------------------
;;; Goal view protocol (§9 `goal' projection -> dsh-protocol-goal)
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-composer-goal-from-projection (value)
  "Parse the `goal' projection VALUE into a `dsh-protocol-goal' or nil.
VALUE is the projection cell (a wire alist) or nil; nil/empty maps to nil so a
cleared goal hides the row."
  (dsh-protocol-goal-projection--from-alist value))

;;; ---------------------------------------------------------------------------
;;; Goal Row rendering (one read-only line above the `❯ ' input)
;;; ---------------------------------------------------------------------------
;; Match dsh web's GoalBar: a dartboard SVG tinted from the goal face, followed
;; by the objective and a muted phase suffix.  Without SVG support, fall back
;; to a text glyph using the same convention as the queue clock icon.

(defconst dsh-emacs-composer--goal-icon-svg
  (concat "<svg width=\"14\" height=\"14\" viewBox=\"0 0 16 16\" fill=\"none\" "
          "xmlns=\"http://www.w3.org/2000/svg\">"
          "<path d=\"M8 0C8.31451 0 8.62464 0.019379 8.92969 0.0546875C8.48228 "
          "0.403371 8.0952 0.825758 7.78809 1.30469C4.18586 1.41664 1.2998 4.37061 "
          "1.2998 8C1.2998 11.7003 4.29969 14.7002 8 14.7002C11.6297 14.7002 14.5829 "
          "11.8136 14.6943 8.21094C15.1734 7.90377 15.5956 7.51688 15.9443 7.06934C15.9797 "
          "7.37473 16 7.68512 16 8C16 12.4183 12.4183 16 8 16C3.58172 16 0 12.4183 0 8C0 "
          "3.58172 3.58172 0 8 0ZM7.0166 3.6084C7.00658 3.73765 7 3.86817 7 4C7 4.31845 "
          "7.03098 4.62973 7.08789 4.93164C5.76489 5.32438 4.7998 6.54958 4.7998 8C4.7998 "
          "9.76731 6.23269 11.2002 8 11.2002C9.45065 11.2002 10.6749 10.2345 11.0674 "
          "8.91113C11.3696 8.96818 11.6812 9 12 9C12.1315 9 12.2617 8.99239 12.3906 8.98242C11.9423 "
          "10.995 10.1477 12.5 8 12.5C5.51472 12.5 3.5 10.4853 3.5 8C3.5 5.85255 5.00435 4.05702 "
          "7.0166 3.6084Z\" fill=\"currentColor\"/>"
          "<path d=\"M7.5 8.62109L9.12109 7\" stroke=\"currentColor\" stroke-width=\"1.3\"/>"
          "<path d=\"M9.08245 3.35798L11.8651 0.575334C11.895 0.545384 11.9463 0.56391 11.9502 "
          "0.606086L12.2362 3.69859C12.2384 3.72259 12.2574 3.74159 12.2814 3.74378L15.3697 "
          "4.02583C15.4119 4.02968 15.4305 4.08101 15.4005 4.11098L12.618 6.89351C12.6086 6.90289 "
          "12.5959 6.90816 12.5826 6.90816L9.11781 6.90815C9.09019 6.90816 9.06781 6.88577 9.06781 "
          "6.85816L9.06781 3.39333C9.06781 3.38007 9.07308 3.36735 9.08245 3.35798Z\" "
          "stroke=\"currentColor\" stroke-width=\"1.3\"/></svg>")
  "SVG data of the Goal Row leading dartboard glyph (dsh web `IconGoalOutline16').
Colored via `currentColor', mapped to the goal face's foreground by
`dsh-emacs-composer--goal-icon'.")

(defun dsh-emacs-composer--icon-width ()
  "Return an icon pixel width fitting two columns in every viewing frame."
  (let ((windows (get-buffer-window-list (current-buffer) nil t)))
    (min 13 (* 2 (if windows
                     (apply #'min
                            (mapcar (lambda (window)
                                      (frame-char-width (window-frame window)))
                                    windows))
                   (frame-char-width))))))

(defun dsh-emacs-composer--goal-icon ()
  "Return the goal SVG icon image string, or nil when SVG is unavailable.
The result reserves two columns carrying the icon `display' property plus the
composer goal face, so the row's chrome tag / read-only stay one run."
  (when (image-type-available-p 'svg)
    (let ((fg (face-foreground 'dsh-emacs-composer-goal-face nil t)))
      (propertize "  "
                  'face 'dsh-emacs-composer-goal-face
                  'display
                  (create-image dsh-emacs-composer--goal-icon-svg
                                'svg t
                                :ascent 'center
                                :scale 1.0
                                :width (dsh-emacs-composer--icon-width)
                                :foreground (or fg "gray50"))))))

;; ---------------------------------------------------------------------------
;; dsh web GoalBar action icons (IconPause/Play/Edit/TrashOutline16, 16px
;; viewBox/currentColor).  Tint them from the action face and use Unicode
;; fallbacks when SVG support is unavailable.
;; ---------------------------------------------------------------------------

(defconst dsh-emacs-composer--pause-svg
  (concat "<svg width=\"13\" height=\"13\" viewBox=\"0 0 16 16\" fill=\"none\" "
          "xmlns=\"http://www.w3.org/2000/svg\">"
          "<path d=\"M14.1448 8.00024C14.1448 4.60644 11.394 1.85563 8.00024 1.85563C4.60644 "
          "1.85563 1.85563 4.60644 1.85563 8.00024C1.85563 11.394 4.60644 14.1448 8.00024 14.1448C11.394 "
          "14.1448 14.1448 11.394 14.1448 8.00024ZM15.5112 8.00024C15.5112 12.1482 12.1482 15.5112 8.00024 "
          "15.5112C3.85226 15.5112 0.489258 12.1482 0.489258 8.00024C0.489258 3.85226 3.85226 0.489258 "
          "8.00024 0.489258C12.1482 0.489258 15.5112 3.85226 15.5112 8.00024Z\" fill=\"currentColor\"/>"
          "<path d=\"M7.14244 5.14258V10.8569H5.71387V5.14258H7.14244Z\" fill=\"currentColor\"/>"
          "<path d=\"M10.286 5.14258V10.8569H8.85742V5.14258H10.286Z\" fill=\"currentColor\"/></svg>")
  "SVG data of the Goal Bar pause action (dsh web `IconPauseOutline16').")

(defconst dsh-emacs-composer--resume-svg
  (concat "<svg width=\"13\" height=\"13\" viewBox=\"0 0 16 16\" fill=\"none\" "
          "xmlns=\"http://www.w3.org/2000/svg\">"
          "<path d=\"M14.1446 8C14.1446 4.6062 11.3938 1.85539 8 1.85539C4.6062 1.85539 1.85539 4.6062 "
          "1.85539 8C1.85539 11.3938 4.6062 14.1446 8 14.1446C11.3938 14.1446 14.1446 11.3938 14.1446 8ZM15.511 "
          "8C15.511 12.148 12.148 15.511 8 15.511C3.85202 15.511 0.489014 12.148 0.489014 8C0.489014 3.85202 "
          "3.85202 0.489014 8 0.489014C12.148 0.489014 15.511 3.85202 15.511 8Z\" fill=\"currentColor\"/>"
          "<path d=\"M10.5617 8.42578C10.852 8.21614 10.852 7.78386 10.5617 7.57422L7.25708 5.18751C6.90974 "
          "4.93666 6.42436 5.18484 6.42436 5.61329V10.3867C6.42436 10.8152 6.90974 11.0633 7.25708 10.8125L10.5617 "
          "8.42578Z\" fill=\"currentColor\"/></svg>")
  "SVG data of the Goal Bar resume (play) action (dsh web `IconPlayOutline16').")

(defconst dsh-emacs-composer--edit-svg
  (concat "<svg width=\"13\" height=\"13\" viewBox=\"0 0 16 16\" fill=\"none\" "
          "xmlns=\"http://www.w3.org/2000/svg\">"
          "<path d=\"M9.94076 1.34942C10.7047 0.90231 11.6503 0.902415 12.4143 1.34942C12.7061 1.52015 12.9688 "
          "1.79118 13.3104 2.13284C13.6521 2.47448 13.9231 2.73721 14.0939 3.02894C14.5408 3.79294 14.5409 "
          "4.73856 14.0939 5.50251C13.9231 5.79415 13.652 6.05704 13.3104 6.39861L6.65932 13.0497C6.28068 "
          "13.4284 6.00695 13.7108 5.66543 13.9097C5.32391 14.1085 4.94315 14.2074 4.42705 14.3498L3.24394 "
          "14.6761C2.77527 14.8054 2.34538 14.9262 2.00131 14.9684C1.65196 15.0112 1.17964 15.0013 0.810764 "
          "14.6325C0.441921 14.2637 0.432107 13.7913 0.47486 13.442C0.517035 13.0979 0.6379 12.668 0.767181 "
          "12.1993L1.09352 11.0162C1.23588 10.5001 1.33481 10.1193 1.5336 9.77784C1.7325 9.43632 2.0149 9.1626 "
          "2.39355 8.78395L9.04466 2.13284C9.38625 1.79126 9.64911 1.52016 9.94076 1.34942ZM15.5427 14.8398H7.55223L8.96707 "
          "13.425H15.5427V14.8398ZM3.39382 9.78422C2.965 10.213 2.84244 10.3436 2.75709 10.49C2.67183 10.6366 "
          "2.61862 10.8079 2.45733 11.3925L2.13099 12.5756C2.00183 13.0439 1.92194 13.3419 1.88863 13.5536C2.10041 "
          "13.5204 2.39872 13.4416 2.86764 13.3123L4.05075 12.9859C4.63544 12.8246 4.80669 12.7715 4.95323 12.6862C5.09968 "
          "12.6008 5.23022 12.4783 5.65905 12.0494L10.721 6.98644L8.45577 4.72121L3.39382 9.78422ZM11.7 2.57079C11.3774 "
          "2.38198 10.9777 2.38198 10.6551 2.57079C10.5602 2.62647 10.4487 2.72931 10.0449 3.13311L9.45604 3.72094L11.7213 "
          "5.98617L12.3102 5.39833C12.7139 4.99457 12.8168 4.88307 12.8725 4.78818C13.0613 4.46561 13.0612 4.06585 "
          "12.8725 3.74326C12.8169 3.64827 12.7146 3.53752 12.3102 3.13311C11.9057 2.72863 11.795 2.6264 11.7 "
          "2.57079Z\" fill=\"currentColor\"/></svg>")
  "SVG data of the Goal Bar edit action (dsh web `IconEditOutline16').")

(defconst dsh-emacs-composer--clear-svg
  (concat "<svg width=\"13\" height=\"13\" viewBox=\"0 0 16 16\" fill=\"none\" "
          "xmlns=\"http://www.w3.org/2000/svg\">"
          "<path d=\"M14.4782 4.84067L14.2138 10.1152C14.1102 12.1872 14.067 13.0115 13.3866 13.9607C13.1044 "
          "14.3546 12.7498 14.6912 12.3424 14.9535C11.8239 15.2872 11.2415 15.4316 10.5585 15.4998C9.88727 15.5668 "
          "9.04946 15.5656 7.99998 15.5656C6.95051 15.5656 6.1127 15.5668 5.44142 15.4998C4.75851 15.4316 4.17602 "
          "15.2872 3.65753 14.9535C3.25012 14.6912 2.89559 14.3546 2.61332 13.9607C1.93296 13.0115 1.88979 12.1872 "
          "1.78619 10.1152L1.52179 4.84067L2.89006 4.77277L3.15343 10.0463C3.26221 12.2218 3.32452 12.6015 3.72646 "
          "13.1624C3.90825 13.4161 4.13686 13.6334 4.39927 13.8023C4.66204 13.9714 5.00263 14.0792 5.57825 14.1367C6.16562 "
          "14.1953 6.92298 14.1963 7.99998 14.1963C9.07699 14.1963 9.83434 14.1953 10.4217 14.1367C10.9973 14.0792 "
          "11.3379 13.9714 11.6007 13.8023C11.8631 13.6334 12.0917 13.4161 12.2735 13.1624C12.6755 12.6015 12.7378 "
          "12.2218 12.8465 10.0463L13.1099 4.77277L14.4782 4.84067ZM5.43011 6.22849H6.7994V11.3909H5.43011V6.22849ZM9.20056 "
          "6.22849H10.5699V11.3909H9.20056V6.22849ZM8.53597 0.434431C9.17976 0.434431 9.6522 0.426926 10.0966 0.571258C10.2357 "
          "0.616451 10.3717 0.672554 10.502 0.738948C10.9182 0.951107 11.2464 1.29099 11.7015 1.74612L12.4978 2.54136H15.3742V3.91169H0.625732V2.54136H3.50218L4.29845 "
          "1.74612C4.75358 1.29099 5.08174 0.951107 5.49801 0.738948C5.62831 0.672554 5.76425 0.616451 5.90334 0.571258C6.34776 "
          "0.426926 6.82021 0.434431 7.46399 0.434431H8.53597ZM7.46399 1.80476C6.73208 1.80476 6.51641 1.81187 6.32617 "
          "1.87369C6.25545 1.89667 6.18668 1.92533 6.12041 1.95907C5.96398 2.03878 5.82348 2.16253 5.44142 2.54136H10.5585C10.1765 "
          "2.16253 10.036 2.03878 9.87955 1.95907C9.81329 1.92533 9.74452 1.89667 9.6738 1.87369C9.48356 1.81187 9.26789 "
          "1.80476 8.53597 1.80476H7.46399Z\" fill=\"currentColor\"/></svg>")
  "SVG data of the Goal Bar clear action (dsh web `IconTrashOutline16').")

(defun dsh-emacs-composer--action-image (svg)
  "Return an image display spec for goal action SVG, or nil.
Colored via `currentColor' mapped to the action face's foreground."
  (and (image-type-available-p 'svg)
       (let ((fg (face-foreground 'dsh-emacs-composer-goal-action-face nil t)))
         (create-image svg 'svg t
                       :ascent 'center :scale 1.0
                       :width (dsh-emacs-composer--icon-width)
                       :foreground (or fg "gray50")))))

(defun dsh-emacs-composer--phase-text (goal)
  "Return the phase label text for GOAL (empty string when absent)."
  (or (dsh-protocol-goal-phase goal) ""))

(defun dsh-emacs-composer--objective-text (goal)
  "Return GOAL's objective as non-empty, single-line display text."
  (let* ((objective (or (dsh-protocol-goal-objective goal) ""))
         ;; Goal objectives come from an external projection and may contain
         ;; line breaks.  The Goal Row owns exactly one physical line, so fold
         ;; them before rendering; otherwise row removal would leave orphaned
         ;; chrome behind in the transcript.
         (one-line (replace-regexp-in-string "[\n\r]+" " " objective)))
    (if (string-empty-p (string-trim one-line))
        "untitled goal"
      one-line)))

(defun dsh-emacs-composer--pending-text ()
  "Return the current mutation's user-facing progress label, or nil."
  (pcase (car-safe dsh-emacs--composer-goal-pending)
    ("pause" "Pausing…")
    ("resume" "Resuming…")
    ("edit" "Updating…")
    ("clear" "Clearing…")))

(defun dsh-emacs-composer--phase-suffix-text (goal)
  "Return the phase suffix text for GOAL (empty string when no phase)."
  (let ((phase (or (dsh-emacs-composer--pending-text)
                   (dsh-emacs-composer--phase-text goal))))
    (if (string-empty-p phase) "" (format "  ·  %s" phase))))

(defun dsh-emacs-composer--sig (goal next)
  "Return the content and layout inputs of GOAL and NEXT's cached rows."
  (list (and goal (list (dsh-protocol-goal-objective goal)
                        (dsh-protocol-goal-phase goal)
                        (dsh-protocol-goal-blocked-reason goal)))
        (and next (list (dsh-protocol-queue-item-text next)))
        dsh-emacs-composer-goal-actions
        (dsh-emacs-composer--pending-text)
        (dsh-emacs-composer--row-width)
        (dsh-emacs-composer--icon-width)))

;; Declared before its reader: ROW-WIDTH falls back to this budget when no
;; window shows the buffer yet (mid setup / batch).
(defvar dsh-emacs-composer--default-row-width 120
  "Column budget for the Goal Row when no window shows the buffer yet.")

(defun dsh-emacs-composer--row-width ()
  "Return the text width available for Composer rows.
When several windows show this buffer, use the narrowest so the shared row
fits all of them.  Fall back to a generous cap when the buffer is not on screen
yet (mid setup / batch)."
  (let ((windows (get-buffer-window-list (current-buffer) nil t)))
    (max 1 (if windows
               (apply #'min (mapcar #'window-text-width windows))
             dsh-emacs-composer--default-row-width))))

(defun dsh-emacs-composer--fit-objective (objective available)
  "Truncate OBJECTIVE so the whole Goal Row fits in AVAILABLE columns.
Returns OBJECTIVE unchanged when it already fits; otherwise a leading slice
with an ellipsis suffix (`…') so the row stays on one visual line (web-style
`nowrap' objective).  AVAILABLE already accounts for the icon and phase suffix."
  (let ((budget (max 1 (- available 1))))      ; room for the ellipsis itself
    (if (<= (string-width objective) budget)
        objective
      (concat (truncate-string-to-width objective budget nil nil "")
              "…"))))

(defun dsh-emacs-composer--goal-action-cell (glyph svg cmd)
  "Return a clickable goal action cell running CMD.
When SVG is available the visible glyph is the dsh web action icon (SVG
`display' image tinted with the action face's `currentColor'); otherwise GLYPH
(a unicode fallback) is shown.  Binds mouse-1 and RET on a text-region keymap,
adds `mouse-face' highlight and a `help-echo', so the read-only Goal Row can
host real click targets."
  (let ((map (make-sparse-keymap))
        (img (dsh-emacs-composer--action-image svg)))
    (define-key map (kbd "RET") cmd)
    (define-key map [mouse-1] cmd)
    (propertize (if img "  " glyph)
                'face 'dsh-emacs-composer-goal-action-face
                'keymap map
                'mouse-face 'highlight
                'display img
                'help-echo
                (pcase cmd
                  ('dsh-emacs-goal-pause "Pause goal · C-c C-g p")
                  ('dsh-emacs-goal-resume "Resume goal · C-c C-g r")
                  ('dsh-emacs-goal-edit "Edit goal · C-c C-g e")
                  ('dsh-emacs-goal-clear "Clear goal · C-c C-g d")))))

(defun dsh-emacs-composer--goal-action-spec (key)
  "Return (GLYPH . SVG) of the dsh web goal action KEY, or nil.
KEY is pause / resume / edit / clear."
  (pcase key
    ('pause (cons "⏸" dsh-emacs-composer--pause-svg))
    ('resume (cons "▶" dsh-emacs-composer--resume-svg))
    ('edit (cons "✎" dsh-emacs-composer--edit-svg))
    ('clear (cons "🗑" dsh-emacs-composer--clear-svg))))

(defun dsh-emacs-composer--goal-action-strip (goal)
  "Return (STRING . WIDTH-COLUMNS) of the clickable action cells for GOAL.
The strip lists the actions applicable to GOAL's phase (dsh web GoalBar):
active → pause · edit · clear; paused → resume · edit · clear; else (blocked)
→ edit · clear.  Each cell shows the dsh web action SVG (unicode fallback when
Emacs lacks SVG support) and carries its own keymap (mouse-1 + RET) plus
`mouse-face' and `help-echo', so it is a real click target on the read-only
row.  The keys `C-c C-g <p|r|e|d>' do the same.  Returns nil when
`dsh-emacs-composer-goal-actions' is off or no actions apply (e.g. no goal /
complete)."
  (let* ((phase (dsh-emacs-composer--phase-text goal))
         (toggle (pcase phase
                   ("active" 'pause)
                   ("paused" 'resume)
                   (_ nil)))
         (keys (and dsh-emacs-composer-goal-actions
                    (not dsh-emacs--composer-goal-pending)
                    (delq nil (list toggle 'edit 'clear))))
         (strip (and keys
                     (mapconcat
                      (lambda (key)
                        (let ((spec (dsh-emacs-composer--goal-action-spec key))
                              (cmd (pcase key
                                     ('pause 'dsh-emacs-goal-pause)
                                     ('resume 'dsh-emacs-goal-resume)
                                     ('edit 'dsh-emacs-goal-edit)
                                     ('clear 'dsh-emacs-goal-clear))))
                          (dsh-emacs-composer--goal-action-cell
                           (car spec) (cdr spec) cmd)))
                      keys
                      " "))))
    (and strip (cons strip (string-width strip)))))

(defun dsh-emacs-composer--render-row (goal)
  "Return the propertized Goal Row string for GOAL (single-line chrome).
Leads with the dartboard SVG icon (text `◎ ' fallback when SVG is unavailable),
then a truncated objective in the body face, then a muted phase suffix, then a
trailing clickable action strip (pause/resume · edit · clear) when one applies.
All fitted to the current window width so the row never wraps (dsh web style).
Callers add the chrome tag and read-only over the whole span."
  (let* ((icon (or (dsh-emacs-composer--goal-icon)
                   (propertize "◎ " 'face 'dsh-emacs-composer-goal-face)))
         (objective (dsh-emacs-composer--objective-text goal))
         (suffix-text (dsh-emacs-composer--phase-suffix-text goal))
         (available (dsh-emacs-composer--row-width))
         ;; SVGs reserve two columns; fallback glyphs use their text width.
         (base-cols (+ (string-width icon) 1 (string-width suffix-text)))
         (strip (dsh-emacs-composer--goal-action-strip goal))
         ;; Keep at least eight objective columns before offering click cells.
         (action (and strip (<= (+ base-cols 2 (cdr strip) 8) available)
                      strip))
         (fixed (+ base-cols (if action (+ 2 (cdr action)) 0)))
         (objective-budget (max 1 (- available fixed)))
         (shown (dsh-emacs-composer--fit-objective objective objective-budget))
         (body (propertize shown
                           'face 'dsh-emacs-composer-goal-body-face
                           'help-echo
                           (concat (or (dsh-protocol-goal-objective goal) "")
                                   (when-let* ((reason
                                                (dsh-protocol-goal-blocked-reason
                                                 goal)))
                                     (format "\nBlocked: %s" reason))
                                   "\nC-c C-g ? for full details")))
         (suffix (if (string-empty-p suffix-text)
                     ""
                   (propertize suffix-text
                               'face 'dsh-emacs-composer-goal-body-face)))
         (actions (if action
                      (concat "  " (car action))
                    ""))
         (row (if (> (+ fixed 1) available)
                  (concat (string-trim-left suffix-text) " " body)
                (concat icon " " body suffix actions))))
    ;; Fixed chrome can itself exceed an unusually narrow split.  This final
    ;; clamp is the safety boundary that preserves the one-visual-line contract
    ;; while retaining text properties on whatever cells remain visible.
    (truncate-string-to-width row available nil nil "…")))

(defconst dsh-emacs-composer--next-icon-svg
  "<svg width=\"14\" height=\"14\" viewBox=\"0 0 14 14\" fill=\"none\" xmlns=\"http://www.w3.org/2000/svg\"><path d=\"M7.00049 0.199829C3.24488 0.199829 0.199952 3.24408 0.199707 6.99963C0.199707 8.0414 0.434087 9.03061 0.854004 9.91467L1.11279 10.4576L2.19775 9.94202L1.94092 9.39905L1.81787 9.12268C1.5498 8.46885 1.40186 7.75171 1.40186 6.99963C1.4021 3.90808 3.90888 1.40198 7.00049 1.40198C10.0919 1.40219 12.5979 3.90821 12.5981 6.99963C12.5981 10.0913 10.0921 12.5983 7.00049 12.5983C6.36734 12.5983 5.90348 12.5535 5.49268 12.4401C5.08803 12.3283 4.7041 12.1414 4.24463 11.8209C3.57111 11.3511 2.60588 11.1855 1.81006 11.6881L1.79736 11.6959L1.78467 11.7047L1.25537 12.0778L1.65381 13.2672L2.46045 12.6989C2.75029 12.5214 3.18004 12.5442 3.55615 12.8063C4.10063 13.1861 4.60863 13.4423 5.17334 13.5983C5.73194 13.7525 6.31665 13.8004 7.00049 13.8004C10.7561 13.8002 13.8003 10.7553 13.8003 6.99963C13.8 3.24421 10.7559 0.200041 7.00049 0.199829ZM3.81201 7.47327V8.67542H7.11572V7.47327H3.81201ZM3.81201 6.34924H10.2173V5.14709H3.81201V6.34924Z\" fill=\"currentColor\"></path></svg>"
  "SVG clock for the Composer Next Message row.")

(defun dsh-emacs-composer--render-next-row (item)
  "Return ITEM's single-line preview fitted to the viewing windows."
  (let* ((text (or (dsh-protocol-queue-item-text item) ""))
         (preview (replace-regexp-in-string "[\t\n\r]+" " " text))
         (icon (when (image-type-available-p 'svg)
                 (propertize
                  "  " 'display
                  (create-image dsh-emacs-composer--next-icon-svg 'svg t
                                :ascent 'center :scale 1.0
                                :width (dsh-emacs-composer--icon-width)
                                :foreground
                                (or (face-foreground 'dsh-emacs-input-prompt-face nil t)
                                    "gray50")))))
         (row (concat (if icon (concat icon " ") "Next: ") preview)))
    (propertize
     (truncate-string-to-width row (dsh-emacs-composer--row-width) nil nil "…")
     'face 'dsh-emacs-input-prompt-face
     'help-echo (concat text "\nC-c C-q to manage pending messages"))))

(defun dsh-emacs-composer--region ()
  "Return (BEG . END) of the live Composer chrome, or nil.
A buffer rebuild can collapse its markers; only a nonempty, tagged region
still belongs to Composer.  Never infer its extent from line contents."
  (when (and (markerp dsh-emacs--composer-top-marker)
             (markerp dsh-emacs--composer-end-marker)
             (eq (marker-buffer dsh-emacs--composer-top-marker) (current-buffer))
             (eq (marker-buffer dsh-emacs--composer-end-marker) (current-buffer)))
    (let ((beg (marker-position dsh-emacs--composer-top-marker))
          (end (marker-position dsh-emacs--composer-end-marker)))
      (when (and (<= (point-min) beg) (< beg end) (<= end (point-max))
                 (get-text-property beg 'dsh-emacs-composer-chrome))
        (cons beg end)))))

(defun dsh-emacs-composer--clear ()
  "Remove only the owned chrome region and release its markers and cache."
  (when-let* ((region (dsh-emacs-composer--region)))
    (let ((inhibit-read-only t))
      (delete-region (car region) (cdr region))))
  (dolist (marker (list dsh-emacs--composer-top-marker
                        dsh-emacs--composer-end-marker))
    (when (markerp marker) (set-marker marker nil)))
  (setq dsh-emacs--composer-top-marker nil
        dsh-emacs--composer-end-marker nil
        dsh-emacs--composer-sig nil))

(defun dsh-emacs-composer--visible-p (goal)
  "Return non-nil when GOAL should show a Goal Row.
Mirrors dsh web: absent goals AND completed goals render nothing — a complete
goal is a finished target, not an active strip.  Paused/blocked stay visible."
  (and goal
       (not (equal (dsh-protocol-goal-phase goal) "complete"))))

(defun dsh-emacs-composer-render ()
  "Render Goal and Next Message rows as one owned region above the input.
Queue selection and visibility belong to the queue module.  Composer reads
that mirror without copying it, and retains only a presentation signature.
Repeated renders preserve the region when content and width are unchanged."
  (when (and (markerp dsh-emacs--input-marker)
             (eq (marker-buffer dsh-emacs--input-marker) (current-buffer)))
    (let* ((goal (and (dsh-emacs-composer--visible-p dsh-emacs--composer-goal)
                      dsh-emacs--composer-goal))
           (next (dsh-emacs-queue-next-item))
           (sig (dsh-emacs-composer--sig goal next)))
      (unless (and (equal sig dsh-emacs--composer-sig)
                   (or (not (or goal next)) (dsh-emacs-composer--region)))
        (let ((text (concat
                     (when goal
                       (propertize
                        (concat (dsh-emacs-composer--render-row goal) "\n")
                        'dsh-emacs-composer-goal-row t))
                     (when next
                       (propertize
                        (concat (dsh-emacs-composer--render-next-row next) "\n")
                        'dsh-emacs-composer-next-row t))))
              (inhibit-read-only t))
          (save-excursion
            (dsh-emacs-composer--clear)
            (unless (string-empty-p text)
              (goto-char (dsh-emacs-render--input-insert-point))
              (let ((beg (point)))
                (insert (propertize text 'dsh-emacs-composer-chrome t
                                    'read-only t 'rear-nonsticky t))
                (setq dsh-emacs--composer-top-marker (copy-marker beg t)
                      dsh-emacs--composer-end-marker (copy-marker (point) nil))))
            (setq dsh-emacs--composer-sig sig)))))))

;;; ---------------------------------------------------------------------------
;;; Public API
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-composer-set-goal (goal)
  "Set this buffer's Composer Goal Row to parsed GOAL (or nil to hide it).
GOAL is a `dsh-protocol-goal' (see `dsh-emacs-composer-goal-from-projection').
Only the live chat buffer's chrome is touched; the goal is never a message and
never sent to the model."
  (setq-local dsh-emacs--composer-goal goal)
  (dsh-emacs-composer-render))

(defun dsh-emacs-composer-set-goal-from-projection (value)
  "Consume a `goal' projection VALUE: parse and render the Goal Row."
  (dsh-emacs-composer-set-goal
   (dsh-emacs-composer-goal-from-projection value)))

(defun dsh-emacs-composer-refresh ()
  "Re-render this buffer's Goal and Next Message rows.
Forces a repaint even when their content is unchanged, for example after
changing `dsh-emacs-composer-goal-actions'."
  (when (and (markerp dsh-emacs--input-marker)
             (eq (marker-buffer dsh-emacs--input-marker) (current-buffer)))
    (setq dsh-emacs--composer-sig nil)
    (dsh-emacs-composer-render)))

(defun dsh-emacs-composer--window-configuration-change ()
  "Reflow Composer after its displayed window geometry changes."
  (dsh-emacs-composer-render))

(defun dsh-emacs-composer-reset ()
  "Release Composer chrome and goal state when a chat buffer reopens.
The next projection/snapshot supplies goal and queue data."
  (dsh-emacs-composer--clear)
  (setq dsh-emacs--composer-goal nil
        dsh-emacs--composer-goal-pending nil)
  (add-hook 'window-configuration-change-hook
            #'dsh-emacs-composer--window-configuration-change nil t))

;;; ---------------------------------------------------------------------------
;;; Goal actions (pause / resume / edit / clear, matching dsh web semantics)
;;; ---------------------------------------------------------------------------
;; Each verb resolves the live Agent through `agentId' (the session id) and
;; carries a CAS `ref' ({id, revision}); the server rejects stale revisions.
;; GoalError is surfaced as `gateway/internal', so failures are handled through
;; ok=nil plus a message.  Success returns GoalView for edit/pause/resume or a
;; bare tombstone ref for clear.  The row updates optimistically, while the
;; projection remains authoritative.

(defun dsh-emacs-composer--goal-ref (goal)
  "Return the CAS ref of GOAL as a wire alist ((id . …) (revision . …))."
  (list (cons 'id (dsh-protocol-goal-id goal))
        (cons 'revision (dsh-protocol-goal-revision goal))))

(defun dsh-emacs-composer--goal-mutate (verb &optional objective on-ok)
  "Send a `goals/VERB' mutation for the current buffer's goal.
Resolves the session id (agentId) and CAS ref from the live goal.  Guards a
pending in-flight mutation so rapid keys can't double-CAS.  ON-OK (optional)
receives the parsed result view (clear returns a goal containing only its
tombstone identity).  Failures surface via `message' and leave the row unchanged."
  (let* ((session-id (dsh-emacs--active-session-id))
         (goal dsh-emacs--composer-goal))
    (cond
     ((null session-id) (message "No session is open"))
     ((null (dsh-emacs-composer--visible-p goal))
      (message "No current goal to %s" verb))
     ((null (dsh-protocol-goal-id goal))
      (message "Current goal has no id yet (waiting for the projection)"))
     ((and (equal verb "pause")
           (not (equal (dsh-protocol-goal-phase goal) "active")))
      (message "Only an active goal can be paused"))
     ((and (equal verb "resume")
           (not (equal (dsh-protocol-goal-phase goal) "paused")))
      (message "Only a paused goal can be resumed"))
     (dsh-emacs--composer-goal-pending
      (message "Goal %s already in progress" verb))
     (t
      (let* ((ref (dsh-emacs-composer--goal-ref goal))
             ;; Identity token as well as a truthy pending guard: a callback
             ;; from before a buffer reset must not clear or overwrite a newer
             ;; mutation that happens to use the same goal ref.
             (pending-token (list verb ref))
             (params `((agentId . ,session-id)
                       (ref . ,ref)
                       ,@(and objective `((request . ((objective . ,objective))))))))
        (setq dsh-emacs--composer-goal-pending pending-token)
        (dsh-emacs-composer-render)
        (dsh-emacs--rpc-async
         (format "goals/%s" verb) params
         (lambda (ok value)
           (let ((own-request
                  (eq dsh-emacs--composer-goal-pending pending-token)))
             (when own-request
               (setq dsh-emacs--composer-goal-pending nil)
               (dsh-emacs-composer-render))
             (if (null ok)
                 (message "Failed to %s goal: %S" verb value)
               ;; The projection stream is authoritative and can outrun the
               ;; HTTP response.  Apply the optimistic response only while
               ;; this exact request still owns the pending slot and its CAS
               ;; ref is still current; otherwise it would regress a newer
               ;; projection (or clear a newly-created goal).
               (let* ((response (and (listp value) value
                                     (dsh-protocol-goal--from-alist value)))
                      (current dsh-emacs--composer-goal)
                      (current-id (and current
                                       (dsh-protocol-goal-id current)))
                      (current-revision
                       (and current (dsh-protocol-goal-revision current)))
                      (request-current
                       (and current
                            (equal current-id (dsh-protocol-goal-id goal))
                            (equal current-revision
                                   (dsh-protocol-goal-revision goal))))
                      ;; The same operation's projection commonly arrives
                      ;; before its HTTP response.  Applying that identical
                      ;; view is safe and preserves the command's success
                      ;; feedback; only a different/newer ref is stale.
                      (response-current
                       (and current response
                            (equal current-id (dsh-protocol-goal-id response))
                            (equal current-revision
                                   (dsh-protocol-goal-revision response))))
                      (clear-already-applied
                       (and (equal verb "clear") (null current))))
                 (if (and own-request
                          (or request-current response-current
                              clear-already-applied))
                     (when (functionp on-ok)
                       (condition-case nil (funcall on-ok response) (quit nil)))
                   (message "Goal %s completed; kept current goal state"
                            verb))))))))))))

(defun dsh-emacs-goal-describe ()
  "Show the full goal objective, phase and blocked reason in a help buffer."
  (interactive)
  (let ((goal dsh-emacs--composer-goal)
        (pending (dsh-emacs-composer--pending-text)))
    (unless goal (user-error "No current goal"))
    (with-help-window "*dsh goal*"
      (princ (or (dsh-protocol-goal-objective goal) "Untitled goal"))
      (when pending
        (princ (format "\n\n%s" pending)))
      (when-let* ((phase (dsh-protocol-goal-phase goal)))
        (princ (format "\n\nPhase: %s" phase)))
      (when-let* ((reason (dsh-protocol-goal-blocked-reason goal)))
        (princ (format "\n\nBlocked: %s" reason)))
      (princ "\n"))))

(defun dsh-emacs-goal-pause ()
  "Pause the current session's active goal (goals/pause)."
  (interactive)
  (dsh-emacs-composer--goal-mutate
   "pause" nil
   (lambda (value)
     (dsh-emacs-composer-set-goal value)
     (message "Goal paused"))))

(defun dsh-emacs-goal-resume ()
  "Resume the current session's paused goal (goals/resume)."
  (interactive)
  (dsh-emacs-composer--goal-mutate
   "resume" nil
   (lambda (value)
     (dsh-emacs-composer-set-goal value)
     (message "Goal resumed"))))

(defun dsh-emacs-goal-edit ()
  "Replace the current goal's objective (goals/edit), prompted in the minibuffer."
  (interactive)
  (let* ((goal dsh-emacs--composer-goal)
         (current (and (dsh-emacs-composer--visible-p goal)
                       (or (dsh-protocol-goal-objective goal) ""))))
    (if (null current)
        (message "No current goal to edit")
      (let ((new (read-string "New goal objective: " current)))
        (if (string-empty-p (string-trim new))
            (message "Goal objective unchanged (empty input)")
          (dsh-emacs-composer--goal-mutate
           "edit" (if (equal new current) current (string-trim new))
           (lambda (value)
             (dsh-emacs-composer-set-goal value)
             (message "Goal updated"))))))))

(defun dsh-emacs-goal-clear ()
  "Clear (delete) the current goal (goals/clear tombstone), with confirmation."
  (interactive)
  (let ((goal dsh-emacs--composer-goal))
    (if (null (dsh-emacs-composer--visible-p goal))
        (message "No current goal to clear")
      (when (y-or-n-p "Clear the current goal? ")
        (dsh-emacs-composer--goal-mutate
         "clear" nil
         (lambda (_value) (dsh-emacs-composer-set-goal nil)))))))

(defun dsh-emacs-goal-actions-toggle ()
  "Toggle whether the Goal Row shows its inline action buttons.
Flips `dsh-emacs-composer-goal-actions' and re-renders the current buffer's
Goal Row immediately.  The `C-c C-g' prefix keys keep working either way."
  (interactive)
  (unless (and (markerp dsh-emacs--input-marker)
               (eq (marker-buffer dsh-emacs--input-marker) (current-buffer)))
    (user-error "Goal Row actions can only be toggled in a chat buffer"))
  (setq-local dsh-emacs-composer-goal-actions
              (not dsh-emacs-composer-goal-actions))
  (dsh-emacs-composer-refresh)
  (message "Goal Row action buttons %s"
           (if dsh-emacs-composer-goal-actions "shown" "hidden")))

;; Prefix keymap: C-c C-g <?|p|r|e|d|a>.
(defvar dsh-emacs-goal-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "?") #'dsh-emacs-goal-describe)
    (define-key map (kbd "p") #'dsh-emacs-goal-pause)
    (define-key map (kbd "r") #'dsh-emacs-goal-resume)
    (define-key map (kbd "e") #'dsh-emacs-goal-edit)
    (define-key map (kbd "d") #'dsh-emacs-goal-clear)
    (define-key map (kbd "a") #'dsh-emacs-goal-actions-toggle)
    map)
  "Prefix keymap for Goal actions (`C-c C-g').")

(provide 'dsh-emacs-composer)

;;; dsh-emacs-composer.el ends here
