;;; dsh-emacs-ui.el --- Chat UI fragment system with box-drawing borders -*- lexical-binding: t; -*-

;; Copyright (C) 2025 vritser

;; Author: vritser
;; URL: https://github.com/vritser/dsh-emacs
;; Version: 0.2.0
;; License: GPL-3.0-or-later
;; Package-Requires: ((emacs "27.1"))

;; This file is NOT part of GNU Emacs.

;;; Commentary:

;; Identified text blocks with complete snapshot updates and folding.
;; Minimal blocks render a header and optional body; rounded/sharp blocks
;; add box-drawing borders.  The stored snapshot owns content and faces,
;; so updates and fold changes use the same render path and atomic replacement.
;; Inspired by xenodium/agent-shell-ui.el.

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

;;; ---------------------------------------------------------------------------
;;; 标签样式
;;; ---------------------------------------------------------------------------

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
                                           (style 'rounded) color-key
                                           face header-face non-foldable)
  "Create a complete fragment snapshot as an alist.
NAMESPACE-ID and BLOCK-ID identify the block.  LABEL-LEFT, LABEL-RIGHT
and BODY may be nil to clear their content on update.  STYLE is rounded,
sharp or minimal.  COLOR-KEY is opaque caller metadata, not a face.
FACE applies to the whole block; HEADER-FACE applies only to the header.
Both merge after embedded text faces, preserving icon and body styling.
NON-FOLDABLE disables folding.  Updates preserve the user's fold state."
  (list (cons :namespace-id namespace-id)
        (cons :block-id block-id)
        (cons :label-left (dsh-emacs-ui--string-or-nil label-left))
        (cons :label-right (dsh-emacs-ui--string-or-nil label-right))
        (cons :body (dsh-emacs-ui--string-or-nil body))
        (cons :style style)
        (cons :color-key color-key)
        (cons :face face)
        (cons :header-face header-face)
        (cons :non-foldable non-foldable)))

;;; ---------------------------------------------------------------------------
;;; 内部辅助函数
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-ui--string-or-nil (str)
  "Return STR if it is not nil and not empty, otherwise nil."
  (and str (not (string-empty-p str)) str))

(defun dsh-emacs-ui--make-border-string (str)
  "Return STR propertized with the border face."
  (propertize str 'face 'dsh-emacs-ui-border-face))

(defun dsh-emacs-ui--box-width ()
  "Return body columns for the displaying window, excluding four frame columns.
Hidden buffers use an 80-column fallback."
  (let ((window (get-buffer-window (current-buffer))))
    (max 1 (- (if window (window-text-width window) 80) 4))))

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

;;; ---------------------------------------------------------------------------
;;; 边框渲染
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-ui--label-merge (text &optional non-foldable)
  "Merge the label face into TEXT and supply default fold interactions.
Existing keymaps, local maps and button properties retain their actions.
NON-FOLDABLE suppresses only the default folding interaction."
  (let ((s (copy-sequence text))
        (pos 0))
    (add-face-text-property 0 (length s) 'dsh-emacs-ui-label-face t s)
    (unless non-foldable
      (while (< pos (length s))
        (let ((end (next-property-change pos s (length s))))
          (unless (or (get-text-property pos 'keymap s)
                      (get-text-property pos 'local-map s)
                      (get-text-property pos 'button s))
            (put-text-property pos end 'keymap dsh-emacs-ui-fragment-map s))
          (setq pos end))))
    s))

(defun dsh-emacs-ui--top-border (label-left label-right collapsed-p style
                                            non-foldable width)
  "Render a header using WIDTH body columns, giving LABEL-LEFT priority.
Bordered headers add four framing columns, matching the body and footer.
Minimal headers use WIDTH columns without framing."
  (let* ((minimal (eq style 'minimal))
         (chars (dsh-emacs-ui--border-chars style))
         (left (truncate-string-to-width (or label-left "") width nil nil "…"))
         (gap (if (string-empty-p left) ""
                (if minimal (concat " " dsh-emacs-ui-label-separator " ") "  ")))
         (remaining (- width (string-width left) (string-width gap)))
         (right (if (> remaining 0)
                    (truncate-string-to-width (or label-right "")
                                              remaining nil nil "…")
                  ""))
         (labels (concat
                  (dsh-emacs-ui--label-merge left non-foldable)
                  (unless (string-empty-p right)
                    (concat gap (dsh-emacs-ui--label-merge right non-foldable))))))
    (if minimal
        labels
      (concat
       (dsh-emacs-ui--make-border-string (alist-get 'top-left chars))
       (propertize (if non-foldable "──" (if collapsed-p "+ " "- "))
                   'face 'dsh-emacs-ui-fold-indicator-face
                   'keymap (unless non-foldable dsh-emacs-ui-fragment-map))
       labels
       (dsh-emacs-ui--make-border-string
        (concat (make-string (max 0 (- width (string-width labels))) ?─)
                (alist-get 'top-right chars)))))))

(defun dsh-emacs-ui--bottom-border (style width)
  "Render the bottom border for STYLE with WIDTH body columns."
  (let ((chars (dsh-emacs-ui--border-chars style)))
    (dsh-emacs-ui--make-border-string
     (concat (alist-get 'bottom-left chars)
             (make-string (+ width 2) ?─)
             (alist-get 'bottom-right chars)))))

(defun dsh-emacs-ui--body-line (text width style)
  "Render TEXT with WIDTH body columns and STYLE framing.
Long body lines retain their content rather than being truncated."
  (if (eq style 'minimal)
      text
    (let ((v (alist-get 'v (dsh-emacs-ui--border-chars style))))
      (concat
       (dsh-emacs-ui--make-border-string (concat v " "))
       text
       (make-string (max 0 (- width (string-width text))) ?\s)
       (dsh-emacs-ui--make-border-string (concat " " v))))))

(defun dsh-emacs-ui--body-region (body width style)
  "Render BODY lines with WIDTH body columns and STYLE framing."
  (mapcar (lambda (line) (dsh-emacs-ui--body-line line width style))
          (split-string (or body "") "\n")))

(defun dsh-emacs-ui--hidden-line (count width style)
  "Render a hidden-line COUNT within WIDTH body columns and STYLE framing."
  (dsh-emacs-ui--body-line
   (propertize
    (truncate-string-to-width
     (format "(%d line%s hidden)" count (if (= count 1) "" "s"))
     width nil nil "…")
    'face 'dsh-emacs-ui-hidden-count-face)
   width style))

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
  "Return the preceding text's requested blank-line spacing, or nil.
Call at the insertion line.  Renderers set `dsh-emacs-ui-space-after'
to the number of blank lines to preserve after their content."
  (save-excursion
    (forward-line -1)
    (while (and (not (bobp))
                (save-excursion
                  (beginning-of-line)
                  (looking-at-p "[ \t]*$")))
      (forward-line -1))
    (get-text-property (line-beginning-position) 'dsh-emacs-ui-space-after)))

(defun dsh-emacs-ui--render-fragment (model &optional expanded)
  "Render MODEL as a propertized string without changing the buffer.
MODEL carries both identity components; EXPANDED sets its fold state."
  (let* ((style (map-elt model :style))
         (body (map-elt model :body))
         (non-foldable (map-elt model :non-foldable))
         (collapsed (not (or non-foldable expanded)))
         (width (dsh-emacs-ui--box-width))
         (header (concat (dsh-emacs-ui--top-border
                          (map-elt model :label-left) (map-elt model :label-right)
                          collapsed style non-foldable width)
                         "\n"))
         (lines (cond
                 ((and collapsed body)
                  (unless (eq style 'minimal)
                    (list (dsh-emacs-ui--hidden-line
                           (length (split-string body "\n" t)) width style))))
                 ((or body (not (eq style 'minimal)))
                  (dsh-emacs-ui--body-region body width style))))
         (text (concat header
                       (when lines (concat (mapconcat #'identity lines "\n") "\n"))
                       (unless (eq style 'minimal)
                         (concat (dsh-emacs-ui--bottom-border style width) "\n"))))
         (state (copy-tree model)))
    (setf (alist-get :collapsed state) collapsed)
    (add-text-properties 0 (length text)
                         (list 'dsh-emacs-ui-state state
                               'read-only t 'front-sticky '(read-only)) text)
    (when-let* ((face (map-elt model :face)))
      (add-face-text-property 0 (length text) face t text))
    (when-let* ((face (map-elt model :header-face)))
      (add-face-text-property 0 (length header) face t text))
    text))

(cl-defun dsh-emacs-ui-update-fragment (model &key create-new expanded insert-before)
  "Replace or insert the complete MODEL snapshot.
Existing blocks preserve their fold state; nil fields clear old values.
CREATE-NEW bypasses lookup.  EXPANDED sets initial visibility.
INSERT-BEFORE selects the insertion position for a new block.
Return the exact (START . END) range, excluding surrounding spacing.
Rendering completes before editing; failed replacements roll back and signal."
  (let* ((namespace-id (map-elt model :namespace-id))
         (block-id (map-elt model :block-id))
         (window (get-buffer-window (current-buffer)))
         (saved-window-start (and window (window-start window)))
         (was-at-bottom
          (and window
               (<= (count-lines (window-start window) (point-max))
                   (+ (max 1 (window-text-height window)) 10)))))
    (unwind-protect
        (save-mark-and-excursion
          (let* ((inhibit-read-only t)
                 (block (unless create-new
                          (dsh-emacs-ui-find-block namespace-id block-id)))
                 (state (and block (get-text-property
                                    (car block) 'dsh-emacs-ui-state)))
                 (text (dsh-emacs-ui--render-fragment
                        model
                        (if block (not (map-elt state :collapsed)) expanded))))
            (atomic-change-group
              (if block
                  (progn
                    (delete-region (car block) (cdr block))
                    (goto-char (car block)))
                (if insert-before
                    (progn
                      (goto-char insert-before)
                      (beginning-of-line)
                      (dsh-emacs-ui--consume-blanks-above
                       (dsh-emacs-ui--blank-above-preserve)))
                  (goto-char (point-max))
                  (unless (or (bobp)
                              (get-text-property (1- (point)) 'dsh-emacs-ui-state))
                    (insert (propertize "\n" 'read-only t
                                        'front-sticky '(read-only))))))
              (let ((start (point)))
                (insert text)
                (cons start (point))))))
      (when (window-live-p window)
        (if was-at-bottom
            (save-excursion
              (goto-char (point-max))
              (forward-line (- (1- (max 1 (window-text-height window)))))
              (set-window-start window (max (point-min) (point)) t))
          (set-window-start window saved-window-start t))))))

(defun dsh-emacs-ui-find-block (namespace-id block-id)
  "Find the block identified by NAMESPACE-ID and BLOCK-ID in this buffer.
Returns (START . END) or nil."
  (save-mark-and-excursion
    (goto-char (point-max))
    (when-let* ((match (text-property-search-backward
                        'dsh-emacs-ui-state nil
                        (lambda (_ state)
                          (and (equal (map-elt state :namespace-id) namespace-id)
                               (equal (map-elt state :block-id) block-id)))
                        t)))
      (cons (prop-match-beginning match)
            (prop-match-end match)))))

(defun dsh-emacs-ui--block-at (pos)
  "Return the contiguous fragment bounds at POS, or nil.
Local actions use property boundaries rather than searching by identity."
  (when (get-text-property pos 'dsh-emacs-ui-state)
    (cons (previous-single-property-change
           (1+ pos) 'dsh-emacs-ui-state nil (point-min))
          (next-single-property-change
           pos 'dsh-emacs-ui-state nil (point-max)))))

(defun dsh-emacs-ui--toggle-fragment-at-point ()
  "Toggle the block at point, preserving it if rendering or replacement fails."
  (save-mark-and-excursion
    (when-let* ((state (get-text-property (point) 'dsh-emacs-ui-state))
                ((not (map-elt state :non-foldable)))
                (block (dsh-emacs-ui--block-at (point))))
      (let ((inhibit-read-only t)
            (text (dsh-emacs-ui--render-fragment
                   state (map-elt state :collapsed))))
        (atomic-change-group
          (delete-region (car block) (cdr block))
          (goto-char (car block))
          (insert text))))))

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

(defun dsh-emacs-ui-delete-fragment (namespace-id block-id)
  "Delete fragment with NAMESPACE-ID and BLOCK-ID."
  (save-mark-and-excursion
    (let* ((inhibit-read-only t)
           (match (dsh-emacs-ui-find-block namespace-id block-id)))
      (when match
        (delete-region (car match) (cdr match))))))

;;; ---------------------------------------------------------------------------
;;; 导航辅助
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-ui-forward-block ()
  "Jump to the next fragment block."
  (interactive)
  (let* ((block (dsh-emacs-ui--block-at (point)))
         (pos (if block (cdr block) (point))))
    (unless (get-text-property pos 'dsh-emacs-ui-state)
      (setq pos (next-single-property-change
                 pos 'dsh-emacs-ui-state nil (point-max))))
    (when (get-text-property pos 'dsh-emacs-ui-state)
      (goto-char pos))))

(defun dsh-emacs-ui-backward-block ()
  "Jump to the previous fragment block."
  (interactive)
  (when-let* ((found (save-mark-and-excursion
                       (let* ((block (dsh-emacs-ui--block-at (point)))
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
                     (not (map-elt state :collapsed)))
            (dsh-emacs-ui--toggle-fragment-at-point)))
        (goto-char (next-single-property-change
                    (point) 'dsh-emacs-ui-state nil (point-max)))))))

(defun dsh-emacs-ui-expand-all ()
  "Expand every fragment in the current buffer."
  (interactive)
  (save-mark-and-excursion
    (let ((inhibit-read-only t))
      (goto-char (point-min))
      (while (not (eobp))
        (let ((state (get-text-property (point) 'dsh-emacs-ui-state)))
          (when (and state
                     (map-elt state :collapsed))
            (dsh-emacs-ui--toggle-fragment-at-point)))
        (goto-char (next-single-property-change
                    (point) 'dsh-emacs-ui-state nil (point-max)))))))

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
