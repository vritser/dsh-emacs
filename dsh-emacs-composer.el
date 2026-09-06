;;; dsh-emacs-composer.el --- Composer chrome for chat buffers -*- lexical-binding: t; -*-

;; Copyright (C) 2025 vritser

;; Author: vritser
;; Version: 0.2.0
;; License: GPL-3.0-or-later
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; The **Composer chrome** layer at the bottom of a chat buffer.  As in dsh
;; web, composer means the input area together with persistent read-only chrome
;; pinned above it.  This file owns the non-transcript portion:
;;
;;   Conversation Buffer
;;   ├── Transcript            -- owned by dsh-emacs-render.el
;;   └── Composer              -- owned here
;;       ├── Goal Row          -- read-only chrome, not transcript content
;;       │    └── action glyphs -- clickable/keyed pause/resume/edit/clear
;;       └── Input Area        -- editable; geometry owned by dsh-emacs.el
;;                                          (dsh-emacs--input-marker / --input-end)
;;
;; The chrome is a **Goal Row**: one read-only line for the session's current
;; goal, directly above the editable `❯ ' input.  Long objectives are
;; ellipsized to the window width and never wrap; complete goals are hidden.
;; The row is never transcript content and is never sent to the model.  Goal
;; data arrives passively through the `goal' session projection (§9), while
;; pause/resume/edit/clear are explicit user-triggered `goals.*' RPCs (§4.10)
;; carrying a CAS ref.  `dsh-emacs-composer-goal-actions' controls the inline
;; buttons; `C-c C-g a' toggles them locally without affecting other goal keys.
;;
;; ## Geometry: the composer-top seam
;;
;; `dsh-emacs-render--input-insert-point' normally resolves to the start of the
;; `❯ ' line.  Once the Goal Row is inserted above that line, later transcript
;; blocks must land above the row or they would separate the chrome from the
;; input.  The buffer-local `dsh-emacs--composer-top-marker' anchors the row;
;; while it is live the renderer inserts at that marker, and when it is nil the
;; renderer falls back to the `❯ ' line.
;;
;; This keeps the ownership seam narrow: fragment rendering and the wire
;; protocol remain unchanged.

;;; Code:

(require 'cl-lib)
(require 'dsh-emacs-protocol)
(require 'dsh-emacs-faces)

;; render.el calls back through this seam.  Declare it without requiring
;; render here to avoid a cycle.  Input-marker geometry remains owned by
;; dsh-emacs.el; this module only reads the shared variable.
(declare-function dsh-emacs-render--input-insert-point "dsh-emacs-render" ())
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
  "Composer chrome (the Goal Row above the chat input) for `dsh-emacs'."
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
  "Marker at the start of the Goal Row chrome above the editable input.
Non-nil only while a Goal Row is shown; it is the single anchor for both the
row's own region (its line is the chrome) and the transcript seam: when live,
`dsh-emacs-render--input-insert-point' inserts above it so streamed content
never lands between the Goal Row and the editable input.  Marker-based so
transcript inserts above it never invalidate the recorded region.  Buffer-local.")

(defvar-local dsh-emacs--composer-goal-sig nil
  "Signature of the last rendered Goal Row (text content), for idempotent
re-renders.  Buffer-local.")

;;; ---------------------------------------------------------------------------
;;; Goal view protocol (§9 `goal' projection -> dsh-protocol-goal)
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-composer-goal-from-projection (value)
  "Parse the `goal' projection VALUE into a `dsh-protocol-goal' or nil.
VALUE is the projection cell (a wire alist) or nil; nil/empty maps to nil so a
cleared goal hides the row."
  (when (and value (listp value)
             (let ((g (cdr (assq 'goal value))))
               (and g (listp g))))
    (dsh-protocol-goal--from-projection value)))

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

(defun dsh-emacs-composer--goal-icon ()
  "Return the goal SVG icon image string, or nil when SVG is unavailable.
The result is a single space carrying the icon `display' property plus the
composer goal face, so the row's chrome tag / read-only stay one run."
  (when (image-type-available-p 'svg)
    (let ((fg (face-foreground 'dsh-emacs-composer-goal-face nil t)))
      (propertize " "
                  'face 'dsh-emacs-composer-goal-face
                  'display
                  (create-image dsh-emacs-composer--goal-icon-svg
                                'svg t
                                :ascent 'center
                                :scale 1.0
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

(defun dsh-emacs-composer--phase-suffix-text (goal)
  "Return the phase suffix text for GOAL (empty string when no phase)."
  (let ((phase (dsh-emacs-composer--phase-text goal)))
    (if (string-empty-p phase) "" (format "  ·  %s" phase))))

(defun dsh-emacs-composer--sig (goal)
  "Return the plain-text signature of GOAL's row (for idempotent re-renders).
Independent of icon/face presentation so the same objective+phase never forces
a redundant repaint across rebuilds.  Includes whether the inline action
buttons are enabled, so toggling `dsh-emacs-composer-goal-actions' re-renders
an existing Goal Row."
  (let ((phase (dsh-emacs-composer--phase-text goal)))
    (format "%s|actions=%s|width=%d"
            (if (string-empty-p phase)
                (dsh-emacs-composer--objective-text goal)
              (format "%s\n%s" (dsh-emacs-composer--objective-text goal) phase))
            (if dsh-emacs-composer-goal-actions "on" "off")
            (dsh-emacs-composer--row-width))))

(defun dsh-emacs-composer--row-width ()
  "Return the text width available for the Goal Row.
When several windows show this buffer, use the narrowest so the shared row
fits all of them.  Fall back to a generous cap when the buffer is not on screen
yet (mid setup / batch)."
  (let ((windows (get-buffer-window-list (current-buffer) nil t)))
    (max 1 (if windows
               (apply #'min (mapcar #'window-text-width windows))
             dsh-emacs-composer--default-row-width))))

(defvar dsh-emacs-composer--default-row-width 120
  "Column budget for the Goal Row when no window shows the buffer yet.")

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
    (propertize (if img " " glyph)
                'face 'dsh-emacs-composer-goal-action-face
                'keymap map
                'mouse-face 'highlight
                'display img
                'help-echo (format "%s (mouse-1/RET)" (symbol-name cmd)))))

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
         (phase-text (dsh-emacs-composer--phase-text goal))
         (suffix-text (dsh-emacs-composer--phase-suffix-text goal))
         (action (dsh-emacs-composer--goal-action-strip goal))
         (action-cols (and action (cdr action)))
         (available (dsh-emacs-composer--row-width))
         ;; The rendered icon can be wider than one column in the non-SVG
         ;; fallback, so measure it instead of assuming a fixed cell width.
         (suffix-cols (string-width suffix-text))
         (fixed (+ (string-width icon) 1 suffix-cols
                   (if action-cols (+ 2 action-cols) 0)))
         (objective-budget (max 1 (- available fixed)))
         (shown (dsh-emacs-composer--fit-objective objective objective-budget))
         (body (propertize shown 'face 'dsh-emacs-composer-goal-body-face))
         (suffix (if (string-empty-p phase-text)
                     ""
                   (propertize suffix-text
                               'face 'dsh-emacs-composer-goal-body-face)))
         (actions (if action
                      (concat "  " (car action))
                    ""))
         (row (concat icon " " body suffix actions)))
    ;; Fixed chrome can itself exceed an unusually narrow split.  This final
    ;; clamp is the safety boundary that preserves the one-visual-line contract
    ;; while retaining text properties on whatever cells remain visible.
    (truncate-string-to-width row available nil nil "…")))

(defun dsh-emacs-composer--goal-row-region ()
  "Return (BEG . END) of the Goal Row line, or nil when not shown.
BEG is the composer-top marker; END is just past the row's trailing newline.
Both derive from the marker, so transcript inserts above the row never drift
them."
  (when (and dsh-emacs--composer-top-marker
             (markerp dsh-emacs--composer-top-marker)
             (eq (marker-buffer dsh-emacs--composer-top-marker)
                 (current-buffer)))
    (let ((beg (marker-position dsh-emacs--composer-top-marker)))
      (when (and (>= beg (point-min)) (<= beg (point-max)))
        (save-excursion
          (goto-char beg)
          (let ((line-end (line-end-position)))
            ;; The row is exactly one line ending at (line-end + 1) when its
            ;; newline is present; if a torn region has no newline yet, cap at
            ;; point-max.
            (cons beg (min (point-max) (1+ line-end)))))))))

(defun dsh-emacs-composer--remove-goal-row ()
  "Delete the current Goal Row chrome line and clear its bookkeeping.
Removes only the region derived from the composer-top marker, so streamed
transcript (always inserted above the marker) is never touched."
  (when-let* ((region (dsh-emacs-composer--goal-row-region)))
    (let ((inhibit-read-only t))
      (delete-region (car region) (cdr region))))
  (when (and dsh-emacs--composer-top-marker
             (marker-buffer dsh-emacs--composer-top-marker))
    (set-marker dsh-emacs--composer-top-marker nil))
  (setq dsh-emacs--composer-top-marker nil
        dsh-emacs--composer-goal-sig nil))

(defun dsh-emacs-composer--insert-goal-row (goal)
  "Render GOAL as a read-only Goal Row directly above the editable input.
The row occupies its own line at the transcript boundary; the composer-top
marker is placed at its start so future transcript inserts land above it."
  (let* ((inhibit-read-only t)
         (row (dsh-emacs-composer--render-row goal)))
    (save-excursion
      ;; Land where a transcript block would today: the start of the editable
      ;; `❯ ' line.  The Goal Row becomes a fresh line above it.
      (goto-char (or (dsh-emacs-render--input-insert-point) (point-max)))
      (beginning-of-line)
      (let ((beg (point)))
        (insert row "\n")
        (let ((end (1- (point))))    ; exclude the trailing newline
          ;; read-only + tagged as chrome; deliberately NO prompt face so the
          ;; anchor scan (`dsh-emacs-render--input-anchor-pos') still resolves
          ;; to the real `❯ ' run below it.  Faces come from --render-row.
          (put-text-property beg end 'dsh-emacs-composer-goal-row t)
          (put-text-property beg end 'read-only t))
        ;; insert-type t: transcript is inserted AT the marker position (the
        ;; goal row's line start); with t the marker moves past the inserted
        ;; text and stays pinned to the goal row start as content stacks above.
        (setq dsh-emacs--composer-top-marker (copy-marker beg t)
              dsh-emacs--composer-goal-sig (dsh-emacs-composer--sig goal))))))

(defun dsh-emacs-composer--visible-p (goal)
  "Return non-nil when GOAL should show a Goal Row.
Mirrors dsh web: absent goals AND completed goals render nothing — a complete
goal is a finished target, not an active strip.  Paused/blocked stay visible."
  (and goal
       (not (equal (dsh-protocol-goal-phase goal) "complete"))))

(defun dsh-emacs-composer-render ()
  "Re-render the Goal Row chrome from `dsh-emacs--composer-goal'.
Shows a read-only row when a goal is present and not complete, removes it
otherwise (a complete goal hides, like dsh web).  Idempotent: re-renders only
when the goal text actually changed.  When the buffer has no live editable
region yet (not a chat buffer / mid setup) nothing renders."
  (when (and (markerp dsh-emacs--input-marker)
             (eq (marker-buffer dsh-emacs--input-marker) (current-buffer)))
    (if (dsh-emacs-composer--visible-p dsh-emacs--composer-goal)
        (let ((sig (dsh-emacs-composer--sig dsh-emacs--composer-goal)))
          (unless (equal sig dsh-emacs--composer-goal-sig)
            (dsh-emacs-composer--remove-goal-row)
            (dsh-emacs-composer--insert-goal-row dsh-emacs--composer-goal)))
      (when dsh-emacs--composer-top-marker
        (dsh-emacs-composer--remove-goal-row)))))

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
  "Re-render the Goal Row of the current buffer from its current goal.
Forces a repaint even when the goal is unchanged — e.g. after the user toggled
`dsh-emacs-composer-goal-actions' and wants the row to pick up the change."
  (when (and (markerp dsh-emacs--input-marker)
             (eq (marker-buffer dsh-emacs--input-marker) (current-buffer)))
    (setq dsh-emacs--composer-goal-sig nil)
    (dsh-emacs-composer-render)))

(defun dsh-emacs-composer--window-configuration-change ()
  "Reflow this buffer's Goal Row after its displayed window geometry changes."
  (when dsh-emacs--composer-goal
    (dsh-emacs-composer-render)))

(defun dsh-emacs-composer-reset ()
  "Reset composer chrome state (called when a chat buffer (re)opens).
Drops any stale goal view and the composer-top marker; the Goal Row is rebuilt
from the next projection/snapshot, so reopen stays self-consistent."
  (setq-local dsh-emacs--composer-goal nil)
  (setq dsh-emacs--composer-top-marker nil
        dsh-emacs--composer-goal-sig nil
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

(defun dsh-emacs-composer--goal-view-from-rpc (value)
  "Build a `dsh-protocol-goal' from an RPC GoalView VALUE (or nil).
The `goals/pause|resume|edit' response is the bare goal core
\(\{id, revision, objective, phase, …\}\) — the same keys the projection nests
under `goal', so wrap it in that shape to reuse the projection parser."
  (and value (listp value)
       (dsh-emacs-composer-goal-from-projection
        (list (cons 'goal value)))))

(defun dsh-emacs-composer--goal-mutate (verb &optional objective on-ok)
  "Send a `goals/VERB' mutation for the current buffer's goal.
Resolves the session id (agentId) and CAS ref from the live goal.  Guards a
pending in-flight mutation so rapid keys can't double-CAS.  ON-OK (optional)
receives the parsed result view when the verb returns one (clear/creates pass
nil).  Failures surface via `message' and leave the row unchanged."
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
        (dsh-emacs--rpc-async
         (format "goals/%s" verb) params
         (lambda (ok value)
           (let ((own-request
                  (eq dsh-emacs--composer-goal-pending pending-token)))
             (when own-request
               (setq dsh-emacs--composer-goal-pending nil))
             (if (null ok)
                 (message "Failed to %s goal: %S" verb value)
               ;; The projection stream is authoritative and can outrun the
               ;; HTTP response.  Apply the optimistic response only while
               ;; this exact request still owns the pending slot and its CAS
               ;; ref is still current; otherwise it would regress a newer
               ;; projection (or clear a newly-created goal).
               (let* ((current dsh-emacs--composer-goal)
                      (current-id (and current
                                       (dsh-protocol-goal-id current)))
                      (current-revision
                       (and current (dsh-protocol-goal-revision current)))
                      (request-current
                       (and current
                            (equal current-id (cdr (assq 'id ref)))
                            (equal current-revision
                                   (cdr (assq 'revision ref)))))
                      ;; The same operation's projection commonly arrives
                      ;; before its HTTP response.  Applying that identical
                      ;; view is safe and preserves the command's success
                      ;; feedback; only a different/newer ref is stale.
                      (response-current
                       (and current (listp value)
                            (equal current-id (cdr (assq 'id value)))
                            (equal current-revision
                                   (cdr (assq 'revision value)))))
                      (clear-already-applied
                       (and (equal verb "clear") (null current))))
                 (if (and own-request
                          (or request-current response-current
                              clear-already-applied))
                     (when (functionp on-ok)
                       (condition-case nil (funcall on-ok value) (quit nil)))
                   (message "Goal %s completed; kept current goal state"
                            verb))))))))))))

(defun dsh-emacs-goal-pause ()
  "Pause the current session's active goal (goals/pause)."
  (interactive)
  (dsh-emacs-composer--goal-mutate
   "pause" nil
   (lambda (value)
     (dsh-emacs-composer-set-goal
      (dsh-emacs-composer--goal-view-from-rpc value))
     (message "Goal paused"))))

(defun dsh-emacs-goal-resume ()
  "Resume the current session's paused goal (goals/resume)."
  (interactive)
  (dsh-emacs-composer--goal-mutate
   "resume" nil
   (lambda (value)
     (dsh-emacs-composer-set-goal
      (dsh-emacs-composer--goal-view-from-rpc value))
     (message "Goal resumed"))))

(defun dsh-emacs-goal-edit ()
  "Replace the current goal's objective (goals/edit), prompted in the minibuffer."
  (interactive)
  (let* ((goal dsh-emacs--composer-goal)
         (current (and (dsh-emacs-composer--visible-p goal)
                       (dsh-emacs-composer--objective-text goal))))
    (if (null current)
        (message "No current goal to edit")
      (let ((new (read-string "New goal objective: " current)))
        (if (string-empty-p (string-trim new))
            (message "Goal objective unchanged (empty input)")
          (dsh-emacs-composer--goal-mutate
           "edit" (string-trim new)
           (lambda (value)
             (dsh-emacs-composer-set-goal
              (dsh-emacs-composer--goal-view-from-rpc value))
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

;; Prefix keymap: C-c C-g <p|r|e|d|a>.
(defvar dsh-emacs-goal-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "p") #'dsh-emacs-goal-pause)
    (define-key map (kbd "r") #'dsh-emacs-goal-resume)
    (define-key map (kbd "e") #'dsh-emacs-goal-edit)
    (define-key map (kbd "d") #'dsh-emacs-goal-clear)
    (define-key map (kbd "a") #'dsh-emacs-goal-actions-toggle)
    map)
  "Prefix keymap for Goal actions (`C-c C-g').")

(provide 'dsh-emacs-composer)

;;; dsh-emacs-composer.el ends here
