;;; dsh-emacs-ui.el --- Chat UI fragment system with box-drawing borders -*- lexical-binding: t; -*-

;; Copyright (C) 2025 vritser

;; Author: vritser
;; URL: https://github.com/vritser/dsh-emacs
;; Version: 0.1.0
;; License: GPL-3.0-or-later

;; This file is NOT part of GNU Emacs.

;;; Commentary:

;; A chat UI fragment system for Emacs, inspired by
;; xenodium/agent-shell-ui.el, with collapsible blocks and clean borders.
;;
;; Each fragment (block) is rendered as a bordered box:
;;
;;   ╭─▶  Label Left              Label Right ──╮
;;   │  Body content text here                   │
;;   │  More body content                        │
;;   ╰───────────────────────────────────────────╯
;;
;; Collapsed:
;;
;;   ╭─▶  Label Left              Label Right ──╮
;;   ╰───────────────────────────────────────────╯
;;
;; Group header:
;;
;;   ╭─▶  Group Title ──────────────────────────╮
;;   ╰───────────────────────────────────────────╯
;;
;; Key differences from agent-shell-ui.el:
;;   - Box-drawing borders (╭─╮│╰─╯) instead of plain text
;;   - Body content prefixed with │ and space
;;   - Cleaner visual hierarchy with border separators
;;   - Minimalist face palette

;;; Code:

(require 'cl-lib)
(require 'map)
(require 'text-property-search)

;;; ---------------------------------------------------------------------------
;;; 定制面孔
;;; ---------------------------------------------------------------------------

(defface dsh-emacs-ui-border-face
  '((((class color) (background light)) :foreground "#888888")
    (((class color) (background dark))  :foreground "#666666")
    (t :inherit shadow))
  "Border lines (╭─╮│╰─╯)."
  :group 'dsh-emacs)

(defface dsh-emacs-ui-label-face
  '((t :weight bold))
  "Fragment label text."
  :group 'dsh-emacs)

(defface dsh-emacs-ui-body-face
  '((t))
  "Fragment body text."
  :group 'dsh-emacs)

(defface dsh-emacs-ui-fold-indicator-face
  '((((class color) (background light)) :foreground "#666666")
    (((class color) (background dark))  :foreground "#999999")
    (t :inherit shadow))
  "Fold indicator (bordered fragments only; minimal fragments carry none)."
  :group 'dsh-emacs)

(defface dsh-emacs-ui-hidden-count-face
  '((((class color) (background light)) :foreground "#999999" :slant italic)
    (((class color) (background dark))  :foreground "#666666" :slant italic)
    (t :inherit font-lock-comment-face))
  "Hidden lines count indicator."
  :group 'dsh-emacs)

(defface dsh-emacs-ui-group-header-face
  '((((class color) (background light)) :foreground "#555555" :weight bold)
    (((class color) (background dark))  :foreground "#aaaaaa" :weight bold)
    (t :inherit bold))
  "Group header text."
  :group 'dsh-emacs)

;;; ---------------------------------------------------------------------------
;;; 颜色常量
;;; ---------------------------------------------------------------------------

(defconst dsh-emacs-ui--border-color "888888"
  "Border color for light theme.")

(defconst dsh-emacs-ui--border-color-dark "666666"
  "Border color for dark theme.")

(defcustom dsh-emacs-ui-label-separator "·"
  "Separator between the left label and the right summary on flat rows.
Minimal (flat) fragments — Thinking and Tool cards — render
\"label-left · label-right\" when both sides are present.  A space is
added on each side automatically; set to \"\" to fall back to the plain
two-space gap."
  :type 'string
  :group 'dsh-emacs)

;;; Border-style character tables.
(defconst dsh-emacs-ui--rounded-chars
  '((top-left . "┌")
    (top-right . "┐")
    (bottom-left . "└")
    (bottom-right . "┘")
    (h . "─")
    (v . "│"))
  "Box-drawing characters for the rounded style.")

(defconst dsh-emacs-ui--sharp-chars
  '((top-left . "╭")
    (top-right . "╮")
    (bottom-left . "╰")
    (bottom-right . "╯")
    (h . "─")
    (v . "│"))
  "Box-drawing characters for the sharp style.")

(defconst dsh-emacs-ui--minimal-chars
  '((top-left . " ")
    (top-right . " ")
    (bottom-left . " ")
    (bottom-right . " ")
    (h . " ")
    (v . "│"))
  "Character table for the minimal style.")

(defun dsh-emacs-ui--border-chars (style)
  "Return the border character alist for STYLE (\\='rounded, \\='sharp, or \\='minimal)."
  (pcase style
    ('minimal dsh-emacs-ui--minimal-chars)
    ('sharp dsh-emacs-ui--sharp-chars)
    (_ dsh-emacs-ui--rounded-chars)))

;;; ---------------------------------------------------------------------------
;;; 片段模型
;;; ---------------------------------------------------------------------------

(cl-defun dsh-emacs-ui-make-fragment (&key (namespace-id "global") (block-id "1")
                                       label-left label-right body
                                       group-id group-label (group-expanded t)
                                       (style 'rounded) (color-key nil)
                                       (hide-label-on-collapse nil)
                                       (non-foldable nil))
  "Create a fragment model alist.
NAMESPACE-ID, BLOCK-ID, LABEL-LEFT, LABEL-RIGHT, and BODY are the keys.
GROUP-ID nests this fragment under a collapsible group header.
When that header does not yet exist, GROUP-LABEL materializes it.
GROUP-EXPANDED sets its initial fold state.
STYLE controls border style: \\='rounded (┌─┐│└─┘) or \\='sharp (╭─╮│╰─╯).
COLOR-KEY is a symbol stored in fragment state; callers can re-style
fragments matching a color-key by re-supplying :color-key on update.
HIDE-LABEL-ON-COLLAPSE non-nil suppresses the right-side label when folded."
  (let ((m (list (cons :namespace-id namespace-id)
                 (cons :block-id block-id)
                 (cons :label-left (dsh-emacs-ui--string-or-nil label-left))
                 (cons :label-right (dsh-emacs-ui--string-or-nil label-right))
                 (cons :body (dsh-emacs-ui--string-or-nil body))
                 (cons :group-id (dsh-emacs-ui--string-or-nil group-id))
                 (cons :group-label (dsh-emacs-ui--string-or-nil group-label))
                 (cons :group-expanded group-expanded)
                 (cons :style (or style 'rounded))
                 (cons :color-key (dsh-emacs-ui--string-or-nil color-key))
                 (cons :hide-label-on-collapse hide-label-on-collapse)
                 (cons :non-foldable non-foldable))))
    m))

(cl-defun dsh-emacs-ui-make-group-model (&key (namespace-id "global") (block-id "1")
                                          label-left label-right (expanded t))
  "Create a group-header model alist.
A group header is a collapsible fragment with no body of its own;
its children are separate fragments referencing it by qualified-id.
NAMESPACE-ID, BLOCK-ID, LABEL-LEFT, and LABEL-RIGHT render the header.
EXPANDED sets the initial fold state."
  (list (cons :namespace-id namespace-id)
        (cons :block-id block-id)
        (cons :kind 'group)
        (cons :label-left (dsh-emacs-ui--string-or-nil label-left))
        (cons :label-right (dsh-emacs-ui--string-or-nil label-right))
        (cons :expanded expanded)))

;;; ---------------------------------------------------------------------------
;;; 内部辅助函数
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-ui--string-or-nil (str)
  "Return STR if it is not nil and not empty, otherwise nil."
  (and str (not (string-empty-p str)) str))

(defun dsh-emacs-ui--qualified-id (namespace-id block-id)
  "Return qualified-id string for NAMESPACE-ID and BLOCK-ID."
  (format "%s-%s" namespace-id block-id))

(defun dsh-emacs-ui--border-face ()
  "Return the appropriate border face for the current theme."
  (if (display-graphic-p)
      'dsh-emacs-ui-border-face
    'dsh-emacs-ui-border-face))

(defun dsh-emacs-ui--make-border (char)
  "Return CHAR propertized with the border face."
  (propertize (string char) 'face 'dsh-emacs-ui-border-face))

(defun dsh-emacs-ui--make-border-string (str)
  "Return STR propertized with the border face."
  (propertize str 'face 'dsh-emacs-ui-border-face))

(defun dsh-emacs-ui--box-width ()
  "Return the width of the box interior (excluding borders)."
  ;; We use a fixed 72-column interior for a clean chat UI look.
  (max 40 (- (or (and (window-live-p (get-buffer-window)) (window-width)) 80) 4)))

;;; ---------------------------------------------------------------------------
;;; 文本属性工具
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-ui--insert-read-only (text &optional face)
  "Insert TEXT as read-only output with optional FACE."
  (let ((len (length text))
        (txt (copy-sequence text)))
    (add-text-properties 0 len '(read-only t front-sticky (read-only)) txt)
    (when face
      (add-text-properties 0 len `(face ,face) txt))
    (insert txt)))

(defun dsh-emacs-ui--add-text-properties (string &rest properties)
  "Add text PROPERTIES to entire STRING and return the propertized string."
  (let ((str (copy-sequence string))
        (len (length string)))
    (while properties
      (let ((prop (car properties))
            (value (cadr properties)))
        (put-text-property 0 len prop value str)
        (setq properties (cddr properties))))
    str))

;;; ---------------------------------------------------------------------------
;;; 折叠指示符
;;; ---------------------------------------------------------------------------

(defvar dsh-emacs-ui-fragment-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'dsh-emacs-ui-toggle-fragment)
    (define-key map [mouse-1] #'dsh-emacs-ui-toggle-fragment)
    (define-key map [remap self-insert-command] #'ignore)
    map)
  "Keymap active on a fragment's fold indicator and labels.
Applied as a `keymap' text property.  RET toggles the fragment.")

(defun dsh-emacs-ui--make-foldable-text (text &optional _hint)
  "Return TEXT propertized with `dsh-emacs-ui-fragment-map'.
HINT is a verb for the action (e.g. \"toggle\")."
  (let ((str (copy-sequence text)))
    (put-text-property 0 (length str) 'keymap dsh-emacs-ui-fragment-map str)
    (put-text-property 0 (length str) 'pointer 'hand str)
    (put-text-property 0 (length str) 'rear-nonsticky t str)
    str))

;;; ---------------------------------------------------------------------------
;;; 边框渲染
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-ui--label-merge (text &optional non-foldable)
  "Merge `dsh-emacs-ui-label-face' into TEXT and add the fragment keymap.
Unlike `propertize' which overwrites the `face' property, this uses
`add-face-text-property' to APPEND the label face so pre-existing face
attributes (e.g. a Nerd Font `:family' on icon glyphs) are preserved.
NON-FOLDABLE non-nil suppresses the fold keymap so the label renders as a
passive line (no RET/click toggle)."
  (let ((s (copy-sequence text)))
    (add-face-text-property 0 (length s) 'dsh-emacs-ui-label-face t s)
    (unless non-foldable
      (put-text-property 0 (length s) 'keymap dsh-emacs-ui-fragment-map s))
    s))

(defun dsh-emacs-ui--top-border (label-left label-right collapsed-p _expanded &optional style non-foldable)
  "Render the top border line with labels.
Returns (BORDER-STRING . CONTENT-WIDTH).
STYLE selects border characters (\\='rounded or \\='sharp).
Minimal (flat) fragments render icon + title + summary flush at column 0
with no fold indicator; bordered fragments keep a leading [+-] indicator."
  (let* ((box-width (dsh-emacs-ui--box-width))
         (chars (dsh-emacs-ui--border-chars style))
         (leading-indicator (if (eq style 'minimal) "" (if collapsed-p "+ " "- ")))
         (left-label (or label-left ""))
         (right-label (or label-right ""))
         (leading-width (string-width leading-indicator))
         (left-width (string-width left-label))
         (right-width (string-width right-label))
         ;; Minimal rows separate title and summary with the user-selected
         ;; separator (e.g. " · "); bordered rows keep the two-space gap.
         (gap-string (if (eq style 'minimal)
                         (concat " " dsh-emacs-ui-label-separator " ")
                       "  "))
         ;; Calculate available space for labels
         (available (- box-width leading-width (string-width gap-string)))
         ;; Reserve the gap between left and right labels
         (gap-width (string-width gap-string))
         (left-max (max 0 (- available right-width gap-width)))
         (truncated-left (if (> left-width left-max)
                             (truncate-string-to-width left-label left-max nil nil "…")
                           left-label))
         (truncated-left-width (string-width truncated-left))
         (right-max (max 0 (- available truncated-left-width gap-width)))
         (truncated-right (if (> right-width right-max)
                              (truncate-string-to-width right-label right-max nil nil "…")
                            right-label))
         (truncated-right-width (string-width truncated-right))
         ;; Calculate fill dashes
         (fill-left (- box-width leading-width truncated-left-width truncated-right-width gap-width))
         (fill-left-str (when (> fill-left 0) (make-string fill-left ?─))))
    (if (eq style 'minimal)
        ;; Minimal (flat) fragments: icon + title + summary, flush at column 0
        ;; with no leading or trailing fold indicator.
        (cons
         (concat
          (dsh-emacs-ui--label-merge truncated-left non-foldable)
          (when (and truncated-right (> (length truncated-right) 0))
            (concat gap-string
                    (dsh-emacs-ui--label-merge truncated-right non-foldable))))
         box-width)
      (cons
       (concat
        (dsh-emacs-ui--make-border-string (concat (alist-get 'top-left chars) "── "))
        (if non-foldable
            (dsh-emacs-ui--make-border-string leading-indicator)
          (propertize leading-indicator 'face 'dsh-emacs-ui-fold-indicator-face
                      'keymap dsh-emacs-ui-fragment-map))
        (dsh-emacs-ui--label-merge truncated-left non-foldable)
        (when (> (length fill-left-str) 0)
          (dsh-emacs-ui--make-border-string fill-left-str))
        (when (and truncated-right (> (length truncated-right) 0))
          (concat " " (dsh-emacs-ui--label-merge truncated-right non-foldable) " "))
        (dsh-emacs-ui--make-border-string (concat "──" (alist-get 'top-right chars))))
       box-width))))

(defun dsh-emacs-ui--bottom-border (&optional style)
  "Render the bottom border line. STYLE selects the border characters."
  (let* ((box-width (dsh-emacs-ui--box-width))
         (chars (dsh-emacs-ui--border-chars style)))
    (if (eq style 'minimal)
        ""
      (dsh-emacs-ui--make-border-string
       (concat (alist-get 'bottom-left chars)
               (make-string box-width ?─)
               (alist-get 'bottom-right chars))))))

(defun dsh-emacs-ui--body-line (text &optional box-width style)
  "Render TEXT as a body line with vertical border prefix.
STYLE selects border characters."
  (let* ((bw (or box-width (dsh-emacs-ui--box-width)))
         (chars (dsh-emacs-ui--border-chars style))
         (v (alist-get 'v chars))
         (content (if (stringp text) text ""))
         (content-width (string-width content))
         (padding (max 0 (- bw content-width))))
    (if (eq style 'minimal)
        content
      (concat
       (dsh-emacs-ui--make-border-string (concat v " "))
       content
       (make-string padding ?\s)
       (dsh-emacs-ui--make-border-string (concat " " v))))))

(defun dsh-emacs-ui--body-region (body &optional box-width style)
  "Render BODY text as a region of pipe-prefixed lines.
STYLE is passed through to `dsh-emacs-ui--body-line'."
  (let* ((bw (or box-width (dsh-emacs-ui--box-width)))
         (lines (split-string (or body "") "\n")))
    (mapcar (lambda (line)
              (dsh-emacs-ui--body-line line bw style))
            lines)))

(defun dsh-emacs-ui--hidden-line (count &optional box-width style)
  "Render a hidden line indicator for COUNT hidden lines.
STYLE selects border characters."
  (let* ((bw (or box-width (dsh-emacs-ui--box-width)))
         (chars (dsh-emacs-ui--border-chars style))
         (v (alist-get 'v chars))
         (msg (format "(%d line%s hidden)"
                      count
                      (if (= count 1) "" "s")))
         (msg-props (propertize msg 'face 'dsh-emacs-ui-hidden-count-face))
         (padding (max 0 (- bw (length msg)))))
    (if (eq style 'minimal)
        (concat "  " (propertize "..." 'face 'dsh-emacs-ui-hidden-count-face))
      (concat
       (dsh-emacs-ui--make-border-string (concat v " "))
       msg-props
       (make-string padding ?\s)
       (dsh-emacs-ui--make-border-string (concat " " v))))))

;;; ---------------------------------------------------------------------------
;;; 片段插入与更新
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-ui--consume-blanks-above (&optional preserve)
  "Delete every consecutive blank line immediately above point, keeping
the last PRESERVE of them (default 0 = flush stacking).
Point must be at the beginning of a line.  Lines belonging to an existing UI
fragment (carrying `dsh-emacs-ui-state') are never consumed, so stacked fragments
stay intact.  Afterward point is at the beginning of the line that followed
the last consumed blank, i.e. flush against the content above (or PRESERVE
blank lines below it).  PRESERVE keeps the blanks closest to the content
above; used to give user-message cards air before/after."
  (when (not (bobp))
    (let ((kill-end (point))
          (blanks nil))
      (save-excursion
        (while (and (not (bobp))
                    (progn (forward-line -1) t)
                    (not (bobp))
                    (not (get-text-property (point) 'dsh-emacs-ui-state))
                    (save-excursion
                      (beginning-of-line)
                      (looking-at-p "[ \t]*$")))
          (setq blanks (cons (point) blanks))))
      ;; `blanks' lists the blank-line starts from top to bottom; keep the
      ;; first PRESERVE of them and delete whatever follows.
      (let ((keep (min (or preserve 0) (length blanks))))
        (when (> (length blanks) keep)
          (delete-region (nth keep blanks) kill-end))))))

(defun dsh-emacs-ui--blank-above-preserve ()
  "Blank line to keep when consuming above: 1 when the previous
non-blank line is a user-message block (they are rendered with one blank
line before and after), else nil.  Call with point at the insertion line;
a nil result doubles as the zero preserve count."
  (save-excursion
    (forward-line -1)
    (while (and (not (bobp))
                (save-excursion
                  (beginning-of-line)
                  (looking-at-p "[ \t]*$")))
      (forward-line -1))
    (when (and (not (bobp))
               (get-text-property (line-beginning-position)
                                  'dsh-emacs-user-message))
      1)))

(defun dsh-emacs-ui--insert-fragment (model qualified-id &optional expanded)
  "Insert a fragment from MODEL with QUALIFIED-ID text properties.
EXPANDED determines initial visibility state.
Style is taken from MODEL's :style property (\\='rounded or \\='sharp)."
  (let* ((block-start (point))
         (kind (map-elt model :kind))
         (group (eq kind 'group))
         (style (map-elt model :style))
         (label-left (map-elt model :label-left))
         (label-right (map-elt model :label-right))
         (body (unless group (map-elt model :body)))
         (hide-label-on-collapse (map-elt model :hide-label-on-collapse))
         (non-foldable (map-elt model :non-foldable))
         (collapsed (not expanded))
         (effective-label-right (if (and collapsed hide-label-on-collapse) nil label-right))
         (top-info (dsh-emacs-ui--top-border label-left effective-label-right collapsed expanded style non-foldable))
         (top-border (car top-info))
         (box-width (cdr top-info))
         (body-start nil)
         (body-end nil)
         (block-end nil))

    ;; Insert top border
    (dsh-emacs-ui--insert-read-only top-border)
    (dsh-emacs-ui--insert-read-only "\n")

    ;; Insert body (or hidden indicator)
    (setq body-start (point))
    (cond
     (group
      ;; Group header has no body, just a bottom border follows
      ;; But we insert a placeholder line so the group spans two lines
      (dsh-emacs-ui--insert-read-only
       (dsh-emacs-ui--body-line "" box-width style) 'dsh-emacs-ui-group-header-face)
      (dsh-emacs-ui--insert-read-only "\n"))
     (body
      (if collapsed
          ;; Compact (minimal): collapse to a single header line, no
          ;; placeholder.  The real body is kept in :body so it can always
          ;; be restored on expand.  Bordered styles keep the hidden-count
          ;; placeholder.
          (unless (eq style 'minimal)
            (let* ((lines (split-string body "\n" t))
                   (count (length lines)))
              (dsh-emacs-ui--insert-read-only
               (dsh-emacs-ui--hidden-line count box-width style))
              (dsh-emacs-ui--insert-read-only "\n")))
        ;; Show full body
        (dolist (line (dsh-emacs-ui--body-region body box-width style))
          (dsh-emacs-ui--insert-read-only line)
          (dsh-emacs-ui--insert-read-only "\n"))))
     (t
      ;; No body: minimal style is a flat single line — skip the empty body
      ;; line so command rows stay compact.  Bordered styles need the empty
      ;; body to maintain the box structure.
      (unless (eq style 'minimal)
        (dsh-emacs-ui--insert-read-only
         (dsh-emacs-ui--body-line "" box-width style))
        (dsh-emacs-ui--insert-read-only "\n"))))

    (setq body-end (point))

    ;; Insert bottom border.  Minimal is a flat style: no bottom border, so
    ;; collapsed blocks stack tightly and expanded bodies have no trailing
    ;; blank line.
    (unless (eq style 'minimal)
      (dsh-emacs-ui--insert-read-only (dsh-emacs-ui--bottom-border style))
      (dsh-emacs-ui--insert-read-only "\n"))
    (setq block-end (point))

    ;; Apply text properties for the block
    (let ((state (list (cons :qualified-id qualified-id)
                       (cons :kind kind)
                       (cons :group-id (map-elt model :group-qualified-id))
                       (cons :group-indent (or (map-elt model :group-indent) ""))
                       (cons :collapsed collapsed)
                       (cons :style style)
                       (cons :color-key (map-elt model :color-key))
                       (cons :hide-label-on-collapse hide-label-on-collapse)
                       (cons :non-foldable non-foldable)
                       (cons :navigatable (or group (and body t)))
                       (cons :body body))))
      (put-text-property block-start block-end 'dsh-emacs-ui-state state)
      (put-text-property block-start block-end 'read-only t)
      (put-text-property block-start block-end 'front-sticky '(read-only))
      ;; Tag the body region
      (put-text-property body-start body-end 'dsh-emacs-ui-section 'body)
      ;; Tag the top border region
      (put-text-property block-start body-start 'dsh-emacs-ui-section 'header))

    ;; Return block range
    (list (cons :start block-start)
          (cons :end block-end)
          (cons :body-start body-start)
          (cons :body-end body-end))))

(defun dsh-emacs-ui--replace-body-section (block-range new-body _qualified-id)
  "Replace the body section in BLOCK-RANGE with NEW-BODY.
Returns the updated block range."
  (let* ((block-start (map-elt block-range :start))
         (block-end (map-elt block-range :end))
         (state (get-text-property block-start 'dsh-emacs-ui-state))
         (collapsed (map-elt state :collapsed))
         (style (map-elt state :style))
         (box-width (dsh-emacs-ui--box-width))
         (inhibit-read-only t)
         new-body-start new-body-end)

    ;; Find the body region within the block
    (save-excursion
      (goto-char block-start)
      ;; Skip top border line
      (forward-line 1)
      (setq new-body-start (point))
      ;; Find where body ends (before bottom border)
      (goto-char block-end)
      (forward-line -1)
      (setq new-body-end (point)))

    ;; Delete old body lines
    (delete-region new-body-start new-body-end)

    ;; Insert new body
    (goto-char new-body-start)
    (cond
     ((not new-body)
      ;; No body
      (dsh-emacs-ui--insert-read-only
       (dsh-emacs-ui--body-line "" box-width style))
      (dsh-emacs-ui--insert-read-only "\n"))
     (collapsed
      (let* ((lines (split-string new-body "\n" t))
             (count (length lines)))
        (dsh-emacs-ui--insert-read-only
         (dsh-emacs-ui--hidden-line count box-width style))
        (dsh-emacs-ui--insert-read-only "\n")))
     (t
      (dolist (line (dsh-emacs-ui--body-region new-body box-width style))
        (dsh-emacs-ui--insert-read-only line)
        (dsh-emacs-ui--insert-read-only "\n"))))

    ;; Update state
    (let ((new-state (copy-sequence state)))
      (map-put! new-state :collapsed collapsed)
      (map-put! new-state :body new-body)
      (put-text-property block-start block-end 'dsh-emacs-ui-state new-state))

    (list (cons :start block-start)
          (cons :end block-end))))

(defun dsh-emacs-ui--append-body-section (block-range chunk _qualified-id)
  "Append CHUNK to the body in BLOCK-RANGE."
  (when (and (stringp chunk) (not (string-empty-p chunk)))
    (let* ((block-start (map-elt block-range :start))
           (block-end (map-elt block-range :end))
           (state (get-text-property block-start 'dsh-emacs-ui-state))
           (collapsed (map-elt state :collapsed))
           (style (map-elt state :style))
           (box-width (dsh-emacs-ui--box-width))
           (inhibit-read-only t)
           body-start body-end)

      ;; Find body region
      (save-excursion
        (goto-char block-start)
        (forward-line 1) ; skip top border
        (setq body-start (point))
        (goto-char block-end)
        (forward-line -1) ; before bottom border
        (setq body-end (point)))

      (if collapsed
          ;; Just update the hidden count
          (let* ((old-body (or (map-elt state :body) ""))
                 (old-count (length (split-string old-body "\n" t))))
            (delete-region body-start body-end)
            (unless (eq style (quote minimal))
              (goto-char body-start)
              (dsh-emacs-ui--insert-read-only
               (dsh-emacs-ui--hidden-line (1+ old-count) box-width style))
              (dsh-emacs-ui--insert-read-only "\n")))
        ;; Append to visible body
        (goto-char body-end)
        (forward-line -1) ; back to last body line
        ;; Insert new chunk lines before the "│" line
        (goto-char body-end)
        (forward-line -1)
        (end-of-line)
        (forward-char 1) ; after the last body line
        (dolist (line (dsh-emacs-ui--body-region chunk box-width style))
          (dsh-emacs-ui--insert-read-only line)
          (dsh-emacs-ui--insert-read-only "\n")))


      ;; Persist the appended body so expand can always restore it.
      (let ((new-state (copy-sequence state)))
        (map-put! new-state :body
                  (concat (or (map-elt state :body) "") chunk))
        (put-text-property block-start block-end (quote dsh-emacs-ui-state) new-state))
      ;; Return updated range
      (list (cons :start block-start)
            (cons :end block-end)))))

;;; ---------------------------------------------------------------------------
;;; 片段更新主入口
;;; ---------------------------------------------------------------------------

(cl-defun dsh-emacs-ui-update-fragment (model &key append create-new expanded insert-before)
  "Update or add a fragment using MODEL.
When APPEND is non-nil, append to body instead of replacing.
When CREATE-NEW is non-nil, always create a new block.
When EXPANDED is non-nil, body will be expanded by default.
For existing blocks, the current expansion state is preserved.
When INSERT-BEFORE is a marker position, insert the new fragment
before that position (useful for buffers with a fixed input area)."
  (let* ((namespace-id (map-elt model :namespace-id))
         (block-id (map-elt model :block-id))
         (qualified-id (dsh-emacs-ui--qualified-id namespace-id block-id))
         (new-label-left (map-elt model :label-left))
         (new-label-right (map-elt model :label-right))
         (new-body (map-elt model :body))
         (group-id (map-elt model :group-id))
         (group-qualified-id (and group-id
                                  (dsh-emacs-ui--qualified-id namespace-id group-id)))
         (window (get-buffer-window (current-buffer)))
         (saved-window-start (and window (window-start window)))
         (was-at-bottom
          (and window
               (<= (count-lines (window-start window) (point-max))
                   (+ (max 1 (window-text-height window)) 10)))))

    (unwind-protect
        (save-mark-and-excursion
          (let* ((inhibit-read-only t)
                 (match (unless create-new
                          (dsh-emacs-ui--find-block qualified-id)))
                 (existing-start (and match (car match)))
                 (existing-end (and match (cdr match)))
                 (result nil))

            (cond
             ;; Update existing block
             ((and existing-start (not create-new))
              (let* ((state (get-text-property existing-start 'dsh-emacs-ui-state))
                     (old-collapsed (map-elt state :collapsed))
                     (block-range (list (cons :start existing-start)
                                        (cons :end existing-end))))

                (when (or new-label-left new-label-right new-body)
                  (let* ((old-kind (map-elt state :kind))
                         (old-group-id (map-elt state :group-id))
                         (old-group-indent (map-elt state :group-indent))
                         (old-style (map-elt state :style))
                         (old-color-key (map-elt state :color-key))
                         (old-hide-label (map-elt state :hide-label-on-collapse))
                         (old-non-foldable (map-elt state :non-foldable))
                         (final-model (list (cons :namespace-id namespace-id)
                                            (cons :block-id block-id)
                                            (cons :kind old-kind)
                                            (cons :label-left (or new-label-left
                                                                  (map-elt model :label-left)))
                                            (cons :label-right (or new-label-right
                                                                   (map-elt model :label-right)))
                                            (cons :body (if append nil new-body))
                                            (cons :group-qualified-id old-group-id)
                                            (cons :group-indent old-group-indent)
                                            (cons :style (or (map-elt model :style) old-style))
                                            (cons :color-key (or (map-elt model :color-key) old-color-key))
                                            (cons :hide-label-on-collapse
                                                  (if (map-elt model :hide-label-on-collapse)
                                                      (map-elt model :hide-label-on-collapse)
                                                    old-hide-label))
                                            (cons :non-foldable
                                                  (if (map-elt model :non-foldable)
                                                      (map-elt model :non-foldable)
                                                    old-non-foldable)))))

                    (if (or new-label-left new-label-right)
                        ;; Header changed: do a full delete + re-insert instead of
                        ;; a body edit.  A body edit first would grow the block in
                        ;; place and leave a stray fragment once the stale region is
                        ;; deleted/re-inserted (body sizes differ between a running
                        ;; call and its settled IN/OUT ioCard).
                        (progn
                          (delete-region existing-start existing-end)
                          (goto-char existing-start)
                          (dsh-emacs-ui--insert-fragment final-model qualified-id
                                                    (not old-collapsed)))
                      ;; Only the body changed: replace/append it in place.
                      (if append
                          (dsh-emacs-ui--append-body-section block-range new-body qualified-id)
                        (dsh-emacs-ui--replace-body-section block-range new-body qualified-id)))
                    (setq result (list (cons :block (list (cons :start existing-start)
                                                          (cons :end (point))))))))))
              (t
               ;; New block
               (let* ((final-model (list (cons :namespace-id namespace-id)
                                         (cons :block-id block-id)
                                         (cons :kind (map-elt model :kind))
                                         (cons :label-left new-label-left)
                                         (cons :label-right new-label-right)
                                         (cons :body new-body)
                                         (cons :group-qualified-id group-qualified-id)
                                         (cons :style (map-elt model :style))
                                         (cons :color-key (map-elt model :color-key))
                                         (cons :hide-label-on-collapse
                                               (map-elt model :hide-label-on-collapse))
                                         (cons :non-foldable
                                               (map-elt model :non-foldable))))
                      (padding-start (point)))
                 ;; Insert at the specified position, or at point-max
                 (if insert-before
                     (progn
                       (goto-char insert-before)
                       ;; If we're at the start of a line, stay there
                       ;; Otherwise, go to beginning of line
                       (beginning-of-line)
                       ;; Flush against the content above: consume any blank
                       ;; lines left by the preceding message/stream so a tool
                       ;; row never shows a gap above it — unless the previous
                       ;; entry is a user message, which keeps one blank line.
                       (dsh-emacs-ui--consume-blanks-above
                        (dsh-emacs-ui--blank-above-preserve))
                       (dsh-emacs-ui--insert-fragment final-model qualified-id expanded))
                   (goto-char (point-max))
                   (unless (or (bobp)
                               (get-text-property (1- (point)) 'dsh-emacs-ui-state))
                     (dsh-emacs-ui--insert-read-only "\n"))
                   (dsh-emacs-ui--insert-fragment final-model qualified-id expanded))
                 (setq result (list (cons :block (list (cons :start padding-start)
                                                       (cons :end (point)))))))))

            result))

      (when window
        (if was-at-bottom
            ;; Chat transcript pinned to the bottom: keep the newest content
            ;; visible instead of restoring the stale scroll position.
            (save-excursion
              (goto-char (point-max))
              (forward-line (- (1- (max 1 (window-text-height window)))))
              (set-window-start window (max (point-min) (point)) t))
          (set-window-start window saved-window-start t))))))

(defun dsh-emacs-ui--find-block (qualified-id)
  "Find a block by QUALIFIED-ID in the current buffer.
Returns (START . END) or nil."
  (save-mark-and-excursion
    (goto-char (point-max))
    (when-let* ((match (text-property-search-backward
                        'dsh-emacs-ui-state nil
                        (lambda (_ state)
                          (equal (map-elt state :qualified-id) qualified-id))
                        t)))
      (cons (prop-match-beginning match)
            (prop-match-end match)))))

(defun dsh-emacs-ui-update-header (qualified-id label-left label-right)
  "Update only the top-border (header) line of block QUALIFIED-ID in place.
Body and collapse state are preserved; the `dsh-emacs-ui-state' text property is
re-applied to the new header line so folding/finding keep working.
Returns non-nil on success."
  (save-mark-and-excursion
    (when-let* ((block (dsh-emacs-ui--find-block qualified-id)))
      (let* ((inhibit-read-only t)
             (start (car block))
             (block-end (cdr block))
             (state (get-text-property start 'dsh-emacs-ui-state))
             (collapsed (map-elt state :collapsed))
             (style (or (map-elt state :style) 'minimal))
             (non-foldable (map-elt state :non-foldable))
             (line-end (save-excursion (goto-char start) (line-end-position)))
             (header (car (dsh-emacs-ui--top-border
                           (or label-left (map-elt state :label-left))
                           (or label-right (map-elt state :label-right))
                           collapsed t style non-foldable))))
        (goto-char start)
        (delete-region start (min (point-max) (1+ line-end)))
        (goto-char start)
        (dsh-emacs-ui--insert-read-only header)
        (dsh-emacs-ui--insert-read-only "\n")
        ;; Re-apply the state across the WHOLE block (header + body) in one
        ;; contiguous span.  If we only re-applied it to the header, the body
        ;; would keep its own `dsh-emacs-ui-state' and `dsh-emacs-ui-find-block' (which
        ;; searches backward) would resolve to the body-start instead of the
        ;; header-start, breaking tool/result updates and folding.
        (put-text-property start (max (point) block-end) 'dsh-emacs-ui-state state)
        t))))

;;; ---------------------------------------------------------------------------
;;; 折叠切换
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-ui--toggle-fragment-at-point ()
  "Toggle visibility of fragment body at point.
The full body is kept in the block's :body so it survives collapse and can
always be restored on expand.  Minimal (flat) blocks collapse to a single
header line; bordered styles use a hidden-count placeholder."
  (save-mark-and-excursion
    (let* ((inhibit-read-only t)
           (state (get-text-property (point) 'dsh-emacs-ui-state))
           (qualified-id (map-elt state :qualified-id))
           (block (dsh-emacs-ui--find-block qualified-id)))
      (when (and block (not (map-elt state :non-foldable)))
        (let* ((block-start (car block))
               (block-end (cdr block))
               (new-collapsed (not (map-elt state :collapsed)))
               (style (map-elt state :style))
               (box-width (dsh-emacs-ui--box-width))
               (body-text (or (map-elt state :body) ""))
               after-header)
          ;; Position just past the header (top border) line.
          (save-excursion
            (goto-char block-start)
            (forward-line 1)
            (setq after-header (point)))
          (goto-char after-header)
          (if new-collapsed
              ;; -> collapse
              (if (eq style 'minimal)
                  (delete-region after-header block-end)
                (let* ((bend (save-excursion
                               (goto-char block-end)
                               (forward-line -1)
                               (point)))
                       (count (max 1 (length (split-string body-text "\n" t)))))
                  (delete-region after-header bend)
                  (goto-char after-header)
                  (dsh-emacs-ui--insert-read-only
                   (dsh-emacs-ui--hidden-line count box-width style))
                  (dsh-emacs-ui--insert-read-only "\n")))
            ;; -> expand: insert the stored body after the header
            (delete-region after-header block-end)
            (goto-char after-header)
            (dolist (line (dsh-emacs-ui--body-region body-text box-width style))
              (dsh-emacs-ui--insert-read-only line)
              (dsh-emacs-ui--insert-read-only "\n"))
            (unless (eq style 'minimal)
              (dsh-emacs-ui--insert-read-only (dsh-emacs-ui--bottom-border style))
              (dsh-emacs-ui--insert-read-only "\n")))
          ;; Update the fold indicator in the header.  Minimal (flat)
          ;; fragments carry no fold indicator, so only bordered fragments
          ;; need their leading [+-] marker refreshed.
          (save-excursion
            (goto-char block-start)
            (let ((line-end (line-end-position)))
              (unless (eq style 'minimal)
                (when (re-search-forward "[+-] " line-end t)
                  (replace-match (if new-collapsed "+ " "- ") t t)))))
          ;; Update state across the (possibly shrunk/grown) block.
          (map-put! state :collapsed new-collapsed)
          (put-text-property block-start (point) 'dsh-emacs-ui-state state))))))

;;;###autoload
(defun dsh-emacs-ui-toggle-fragment ()
  "Toggle fragment fold at or near point.
Silent no-op when no fragment exists at or after point."
  (interactive)
  (when-let* ((pos (dsh-emacs-ui--enclosing-fragment-position)))
    (goto-char pos)
    (dsh-emacs-ui--toggle-fragment-at-point)))

(defun dsh-emacs-ui--enclosing-fragment-position ()
  "Return position of the nearest enclosing fragment, or nil."
  (if (get-text-property (point) 'dsh-emacs-ui-state)
      (point)
    (save-mark-and-excursion
      (or (when-let* ((match (text-property-search-backward
                              'dsh-emacs-ui-state nil
                              (lambda (_ state) (and state t))
                              t))
                      (start (prop-match-beginning match))
                      (end (prop-match-end match))
                      ((>= (point) start))
                      ((<= (point) end)))
            start)
          (when-let* ((match (text-property-search-forward
                              'dsh-emacs-ui-state nil
                              (lambda (_ state) (and state t))
                              t)))
            (prop-match-beginning match))))))

;;; ---------------------------------------------------------------------------
;;; 删除片段
;;; ---------------------------------------------------------------------------

(cl-defun dsh-emacs-ui-delete-fragment (&key namespace-id block-id)
  "Delete fragment with NAMESPACE-ID and BLOCK-ID."
  (save-mark-and-excursion
    (let* ((inhibit-read-only t)
           (qualified-id (dsh-emacs-ui--qualified-id namespace-id block-id))
           (match (dsh-emacs-ui--find-block qualified-id)))
      (when match
        (delete-region (car match) (cdr match))))))

;;; ---------------------------------------------------------------------------
;;; 导航辅助
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-ui-forward-block ()
  "Jump to the next fragment block."
  (interactive)
  (when-let* ((found (save-mark-and-excursion
                       ;; If in a block, move past it
                       (when-let* ((state (get-text-property (point) 'dsh-emacs-ui-state))
                                   (block (dsh-emacs-ui--find-block
                                           (map-elt state :qualified-id))))
                         (goto-char (cdr block)))
                       ;; Find next block
                       (let ((match (text-property-search-forward
                                     'dsh-emacs-ui-state nil
                                     (lambda (_ state) (and state t))
                                     t)))
                         (and match (prop-match-beginning match))))))
    (goto-char found)))

(defun dsh-emacs-ui-backward-block ()
  "Jump to the previous fragment block."
  (interactive)
  (when-let* ((found (save-mark-and-excursion
                       (let* ((state (get-text-property (point) 'dsh-emacs-ui-state))
                              (block (and state (dsh-emacs-ui--find-block
                                                  (map-elt state :qualified-id))))
                              (block-start (and block (car block))))
                         (if (and block-start (< block-start (point)))
                             block-start
                           (when-let* ((match (text-property-search-backward
                                               'dsh-emacs-ui-state nil
                                               (lambda (_ state) (and state t))
                                               t)))
                             (prop-match-beginning match)))))))
    (goto-char found)))

;;; ---------------------------------------------------------------------------
;;; 清除所有片段
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-ui-clear ()
  "Clear all UI fragments from the buffer."
  (interactive)
  (let ((inhibit-read-only t))
    (erase-buffer)))

;;; ---------------------------------------------------------------------------
;;; 公共查询/状态操作
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-ui-state-at (pos)
  "Return the dsh-emacs-ui-state alist at buffer position POS, or nil."
  (get-text-property pos 'dsh-emacs-ui-state))

(defun dsh-emacs-ui-find-block (qualified-id)
  "Public wrapper for `dsh-emacs-ui--find-block'. Returns (START . END) or nil."
  (dsh-emacs-ui--find-block qualified-id))

(defun dsh-emacs-ui-block-p (pos)
  "Return non-nil if POS is inside any dsh-emacs-ui fragment block."
  (and (dsh-emacs-ui-state-at pos) t))

(defun dsh-emacs-ui-restyle-block (qualified-id new-color-key)
  "Update the :color-key for the block with QUALIFIED-ID."
  (when-let* ((block (dsh-emacs-ui--find-block qualified-id)))
    (let* ((state (get-text-property (car block) 'dsh-emacs-ui-state))
           (new-state (copy-sequence state))
           (inhibit-read-only t))
      (map-put! new-state :color-key new-color-key)
      (put-text-property (car block) (cdr block) 'dsh-emacs-ui-state new-state))))

;;; ---------------------------------------------------------------------------
;;; 折叠所有片段
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-ui-collapse-all ()
  "Collapse every fragment in the current buffer."
  (interactive)
  (save-mark-and-excursion
    (let ((inhibit-read-only t))
      (goto-char (point-min))
      (while (not (eobp))
        (let ((state (get-text-property (point) 'dsh-emacs-ui-state)))
          (when (and state
                     (not (map-elt state :collapsed))
                     (not (eq (map-elt state :kind) 'group)))
            (dsh-emacs-ui--toggle-fragment-at-point)))
        (forward-line 1)))))

(defun dsh-emacs-ui-expand-all ()
  "Expand every fragment in the current buffer."
  (interactive)
  (save-mark-and-excursion
    (let ((inhibit-read-only t))
      (goto-char (point-min))
      (while (not (eobp))
        (let ((state (get-text-property (point) 'dsh-emacs-ui-state)))
          (when (and state
                     (map-elt state :collapsed)
                     (not (eq (map-elt state :kind) 'group)))
            (dsh-emacs-ui--toggle-fragment-at-point)))
        (forward-line 1)))))

;;; ---------------------------------------------------------------------------
;;; 模式
;;; ---------------------------------------------------------------------------

(defvar dsh-emacs-ui-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "TAB") #'dsh-emacs-ui-forward-block)
    (define-key map (kbd "<backtab>") #'dsh-emacs-ui-backward-block)
    (define-key map (kbd "RET") #'dsh-emacs-ui-toggle-fragment)
    map)
  "Keymap for `dsh-emacs-ui-mode'.")

;;;###autoload
(define-minor-mode dsh-emacs-ui-mode
  "Minor mode for chat UI fragment navigation.

\\{dsh-emacs-ui-mode-map}"
  :lighter " UI"
  :keymap dsh-emacs-ui-mode-map
  (if dsh-emacs-ui-mode
      (setq-local search-invisible 'open-all)
    (kill-local-variable 'search-invisible)))

(provide 'dsh-emacs-ui)

;;; dsh-emacs-ui.el ends here
