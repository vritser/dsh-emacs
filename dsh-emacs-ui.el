;;; dsh-emacs-ui.el --- Chat UI fragment system with box-drawing borders -*- lexical-binding: t; -*-

;; Copyright (C) 2025 vritser

;; Author: vritser
;; URL: https://github.com/vritser/dsh-emacs
;; Version: 0.7.0
;; License: GPL-3.0-or-later
;; Package-Requires: ((emacs "28.1"))

;; This file is NOT part of GNU Emacs.

;;; Commentary:

;; Identified text blocks with complete snapshot updates and folding.
;; Minimal blocks render a header and optional body; rounded/sharp blocks
;; add box-drawing borders.  The stored snapshot owns content and faces,
;; so updates and fold changes use the same render path and atomic replacement.
;; Inspired by xenodium/agent-shell-ui.el.

;;; Code:

(require 'cl-lib)
(require 'button)
(require 'map)
(require 'text-property-search)
(require 'dsh-emacs-faces)

;;; ---------------------------------------------------------------------------
;;; Ordered completion
;;; ---------------------------------------------------------------------------
;;
;; Completion-framework adaptation belongs here with the menus, so feature
;; modules call it directly instead of declaring into the entry point.

;; Emacs 31-only; the 28.1 baseline falls back to
;; `dsh-emacs-ui--completion-table-with-metadata'.  The declaration only keeps
;; byte-compile on Emacs <=30 from warning about an unknown function.
(declare-function completion-table-with-metadata "minibuffer" (table metadata))

;; With `ivy-mode' on, `ivy-sort-functions-alist' takes over sorting; the
;; defvar only silences a byte-compile warning and guarantees dynamic
;; binding; it has no effect when the framework is not loaded.
(defvar ivy-sort-functions-alist)

(defun dsh-emacs-ui--completion-table-with-metadata (collection metadata)
  "Return COLLECTION as a completion table carrying METADATA.
METADATA is an alist of completion metadata (see `completion-metadata'),
e.g. `display-sort-function' pinned to identity to stop a frontend from
reordering the candidates.  Uses the Emacs 31 built-in when present and
the equivalent table lambda otherwise; the built-in is Emacs 31-only,
while the package baseline is 28.1."
  (if (fboundp 'completion-table-with-metadata)
      (completion-table-with-metadata collection metadata)
    (lambda (string pred action)
      (if (eq action 'metadata)
          `(metadata . ,metadata)
        (complete-with-action action collection string pred)))))

(defun dsh-emacs-ui--completing-read-ordered (prompt collection &rest args)
  "`completing-read', but keep COLLECTION's incoming order.
Adapts to whichever framework the user actually enabled, without
hardcoding any of them:
- vertico / corfu / stock minibuffer: reads the completion metadata's
  `display-sort-function' (Vertico's sort function and Corfu both take
  priority over their own sort toggles); set it to identity here and the
  framework drops the reorder by itself;
- ivy: does not read that metadata and takes the sort function per
  collection/caller from `ivy-sort-functions-alist' — bound dynamically to
  ((t . nil)) (docstring: nil = no sorting), effective for this call only;
- other frameworks (selectrum etc.) also honor the display-sort-function
  convention.
PROMPT/COLLECTION/ARGS have exactly the same semantics as
`completing-read'."
  (let ((ordered (dsh-emacs-ui--completion-table-with-metadata
                  collection
                  '((display-sort-function . identity)))))
    (if (bound-and-true-p ivy-mode)
        (let ((ivy-sort-functions-alist '((t))))
          (apply #'completing-read prompt ordered args))
      (apply #'completing-read prompt ordered args))))

;;; ---------------------------------------------------------------------------
;;; Minibuffer menus
;;; ---------------------------------------------------------------------------
;;
;; Queue and job menus share one shape: unique labels for a plain
;; `completing-read' pick, modified action keys that leave typing alone,
;; and the host's own order.  A single action spec per menu carries the
;; keys, their actions and the global flag, so the keymap, the pre-command
;; recorder and the caller's dispatch cannot drift apart.  Order is declared
;; as completion metadata by the caller; the one frontend accommodation here
;; (`--menu-keep-order') neutralizes Vertico's sort override, which outranks
;; that metadata.  The menus own their prompts and actions; this boundary
;; delegates selection to the frontend's normal RET command.

(defun dsh-emacs-ui-menu-entries (items label-function)
  "Return ((LABEL . ITEM) ...) for ITEMS with unique LABELs.
LABEL-FUNCTION returns each item's base label.  A collision takes a
\"[N]\" suffix; a candidate that would still collide with an already
assigned label (for example a row literally named \"same [2]\") keeps
incrementing until it is free.  Every final label therefore maps to
exactly one item, and the item rides in the cdr the menu verbs act on."
  (let ((seen (make-hash-table :test 'equal))
        (used (make-hash-table :test 'equal)))
    (mapcar
     (lambda (item)
       (let* ((base (funcall label-function item))
              (n (1+ (gethash base seen 0)))
              (label (if (= n 1) base (format "%s [%d]" base n))))
         (while (gethash label used)
           (setq n (1+ n)
                 label (format "%s [%d]" base n)))
         (puthash base n seen)
         (puthash label t used)
         (cons label item)))
     items)))

(defun dsh-emacs-ui--menu-keep-order ()
  "Keep the menu's own candidate order against a frontend sort override.
The collection metadata already declares `display-sort-function', which
frontends honor over their default sort.  Vertico's
`vertico-sort-override-function' is the one exception: it is consulted
before the metadata, so a global override would reorder a menu whose
order is part of its meaning.  Bind it away buffer-locally here."
  (when (boundp 'vertico-sort-override-function)
    (setq-local vertico-sort-override-function nil)))

(defvar dsh-emacs-ui--menu-context nil
  "Dynamically bound action and key bindings of the current menu.
Each `dsh-emacs-ui-menu-read' owns its context, including recursive reads.")

(defun dsh-emacs-ui--menu-setup ()
  "Keep menu order and add modified actions to the active frontend map.
The map is copied from the one the frontend installed.  Ordering matters:
`minibuffer-with-setup-hook' prepends, so this hook is added before
`completing-read' runs; a frontend that installs its map from a setup hook
added during that call (Vertico, Ivy) then runs first, and the copy below
sees its map."
  (dsh-emacs-ui--menu-keep-order)
  (let ((accept (key-binding (kbd "RET")))
        (map (copy-keymap (current-local-map))))
    (unless (commandp accept)
      (error "Completion frontend has no RET command"))
    (dolist (binding (plist-get dsh-emacs-ui--menu-context :bindings))
      (define-key map (kbd (car binding))
                  (if (memq (cdr binding)
                            (plist-get dsh-emacs-ui--menu-context :global-actions))
                      #'dsh-emacs-ui--menu-global-action
                    accept)))
    (use-local-map map)
    (add-hook 'pre-command-hook #'dsh-emacs-ui--menu-record-action nil t))
  nil)

(defun dsh-emacs-ui--menu-action-for-key (keys)
  "Return the menu action bound to the canonical key description KEYS.
Bindings are written in `kbd' syntax; canonicalizing them here keeps the
recorder in step with `key-description' of the pressed keys."
  (cdr (cl-find-if (lambda (binding)
                     (equal (key-description (kbd (car binding))) keys))
                   (plist-get dsh-emacs-ui--menu-context :bindings))))

(defun dsh-emacs-ui--menu-record-action ()
  "Record the current menu key's action before the native command runs.
Every other key restores the default action, including RET after an
incomplete modified acceptance.  The frontend sees its original command
and runs its usual candidate preparation and acceptance hooks."
  (setf (plist-get dsh-emacs-ui--menu-context :action)
        (or (dsh-emacs-ui--menu-action-for-key
             (key-description (this-command-keys-vector)))
            (plist-get dsh-emacs-ui--menu-context :default-action))))

(defun dsh-emacs-ui--menu-global-action ()
  "Close the current menu with an action that needs no selected item."
  (interactive)
  (let ((action (plist-get dsh-emacs-ui--menu-context :action)))
    (unless (memq action (plist-get dsh-emacs-ui--menu-context :global-actions))
      (error "Unknown global menu action"))
    (throw 'dsh-emacs-ui-menu-result (list action nil))))

(defun dsh-emacs-ui-menu-read (prompt entries default-action actions)
  "Read ENTRIES with PROMPT and return (ACTION ITEM).
ENTRIES maps unique labels to items.  RET uses DEFAULT-ACTION.  ACTIONS is
((KEY ACTION &optional GLOBAL) ...): KEY is a `kbd' sequence, an item
action runs after the frontend accepts the selected label, and a non-nil
GLOBAL makes KEY exit without a selected item (ITEM is then nil).  Callers
run ACTION after this read returns."
  (let* ((bindings (mapcar (lambda (action)
                             (cons (car action) (cadr action)))
                           actions))
         (global-actions (delq nil
                               (mapcar (lambda (action)
                                         (and (nth 2 action) (cadr action)))
                                       actions)))
         (dsh-emacs-ui--menu-context
          (list :action default-action :default-action default-action
                :bindings bindings :global-actions global-actions)))
    (catch 'dsh-emacs-ui-menu-result
      (let* ((label (minibuffer-with-setup-hook #'dsh-emacs-ui--menu-setup
                      (dsh-emacs-ui--completing-read-ordered
                       prompt (mapcar #'car entries) nil t nil nil
                       (caar entries))))
             (entry (assoc label entries)))
        (unless entry (user-error "Unknown menu item: %s" label))
        (list (plist-get dsh-emacs-ui--menu-context :action) (cdr entry))))))

(defvar-local dsh-emacs-ui--following-windows-function nil
  "Optional function returning this buffer's windows that follow new output.
When nil, fragments use their generic bottom-of-buffer check.  Chat buffers
share the stream renderer's input-anchor policy instead.")

;;; ---------------------------------------------------------------------------
;;; Customization faces
;;; ---------------------------------------------------------------------------

(defface dsh-emacs-ui-border-face
  '((((class color) (background light)) :foreground "#888888")
    (((class color) (background dark))  :foreground "#666666")
    (t :inherit shadow))
  "Border lines (╭─╮│╰─╯)."
  :group 'dsh-emacs)

(defface dsh-emacs-ui-label-face
  '((t :weight bold))
  "Fragment title text (the header's left label only).
The right label is a summary and is styled by its own or the fragment's
header face, never by this title face."
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
;;; Label styling
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
;;; Fragment model
;;; ---------------------------------------------------------------------------

(cl-defun dsh-emacs-ui-make-fragment (&key (namespace-id "global") (block-id "1")
                                           label-left label-right body
                                           (style 'rounded) status
                                           header-face body-face non-foldable padding)
  "Create a complete fragment snapshot as an alist.
NAMESPACE-ID and BLOCK-ID identify the block.  LABEL-LEFT, LABEL-RIGHT
and BODY may be nil to clear their content on update.  STYLE is rounded,
sharp or minimal.  STATUS is opaque caller metadata, not a face.
HEADER-FACE styles the header row only (icon, title, summary, fold
indicator); BODY-FACE styles the expanded body only.  There is no
whole-block face.  Both merge after embedded text faces, preserving icon
and body styling.  NON-FOLDABLE disables folding.  Updates preserve the
user's fold state.  PADDING adds a blank line above and below the fragment,
including when collapsed.
BODY may also be a zero-argument function returning a string or nil.  It
must capture immutable inputs and only format text in the current buffer.
Minimal collapsed fragments defer this function until expansion; other
styles need the body for their line count.  Successful renders cache its
result at the current body width until the function or width changes.
A state carrying such a function must not be deep-copied with `copy-tree`:
that would copy the function and defeat the identity the cache relies on."
  (list (cons :namespace-id namespace-id)
        (cons :block-id block-id)
        (cons :label-left (dsh-emacs-ui--string-or-nil label-left))
        (cons :label-right (dsh-emacs-ui--string-or-nil label-right))
        (cons :body (if (functionp body) body
                      (dsh-emacs-ui--string-or-nil body)))
        (cons :style style)
        (cons :status status)
        (cons :header-face header-face)
        (cons :body-face body-face)
        (cons :non-foldable non-foldable)
        (cons :padding padding)))

;;; ---------------------------------------------------------------------------
;;; Internal helpers
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
;;; Fold indicator
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
;;; Border rendering
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-ui--label-merge (text &optional non-foldable title-p)
  "Merge default fold interactions into TEXT.
TITLE-P also merges `dsh-emacs-ui-label-face' — the header's left label is
the title; the right label is a summary and must not inherit the title's
weight, only its own (or the fragment's header) face.  Existing keymaps,
local maps and button properties retain their actions.  NON-FOLDABLE
suppresses only the default folding interaction."
  (let ((s (copy-sequence text))
        (pos 0))
    (when title-p
      (add-face-text-property 0 (length s) 'dsh-emacs-ui-label-face t s))
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
                (if minimal
                    (propertize (concat " " dsh-emacs-ui-label-separator " ")
                                'face (and label-right
                                           (> (length label-right) 0)
                                           (get-text-property
                                            0 'face label-right)))
                  "  ")))
         (remaining (- width (string-width left) (string-width gap)))
         (right (if (> remaining 0)
                    (truncate-string-to-width (or label-right "")
                                              remaining nil nil "…")
                  ""))
         (labels (concat
                  (dsh-emacs-ui--label-merge left non-foldable t)
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
;;; Fragment insertion and update
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

(defun dsh-emacs-ui--window-at-bottom-p (window pos)
  "Return non-nil when WINDOW currently shows POS near its bottom.
True when POS is within one window height plus ten screen rows of the
window start, respecting wrapping and display properties.  The slack
absorbs insertions that push POS down between passes while leaving
manually scrolled-up windows untouched."
  (ignore-errors
    (let ((start (window-start window)))
      (and (<= start pos)
           (save-excursion
             (goto-char start)
             (vertical-motion (+ (max 1 (window-text-height window)) 10) window)
             (>= (point) pos))))))

(defvar-local dsh-emacs-ui--blocks nil
  "Identity to (START-MARKER STATE TICK LAYOUT) lookup cache.
Text properties remain authoritative; invalid markers are never returned.")

(defun dsh-emacs-ui--invalidate-index (&rest _)
  "Release cached markers on erase or undo, which can restore duplicate IDs."
  (when (and dsh-emacs-ui--blocks
             (or undo-in-progress (= (buffer-size) 0)))
    (maphash (lambda (_ entry) (set-marker (car entry) nil))
             dsh-emacs-ui--blocks)
    (clrhash dsh-emacs-ui--blocks)))

(cl-defun dsh-emacs-ui--remember-block (range &optional layout)
  "Cache RANGE after a successful write or lookup, with optional LAYOUT."
  (when (buffer-narrowed-p)
    (cl-return-from dsh-emacs-ui--remember-block nil))
  (unless dsh-emacs-ui--blocks
    (setq dsh-emacs-ui--blocks (make-hash-table :test 'equal))
    (add-hook 'after-change-functions #'dsh-emacs-ui--invalidate-index nil t))
  (let* ((state (get-text-property (car range) 'dsh-emacs-ui-state))
         (key (cons (map-elt state :namespace-id) (map-elt state :block-id)))
         (entry (gethash key dsh-emacs-ui--blocks)))
    ;; CREATE-NEW can deliberately duplicate an identity.  Lookup retains
    ;; its existing last-in-buffer rule, even when inserting an earlier copy.
    (unless (and entry (marker-position (car entry))
                 (< (car entry) (point-max))
                 (> (car entry) (car range))
                 (eq (get-text-property (car entry) 'dsh-emacs-ui-state)
                     (nth 1 entry)))
      (when entry (set-marker (car entry) nil))
      (puthash key (list (copy-marker (car range) t) state
                         (and layout (buffer-modified-tick)) layout)
               dsh-emacs-ui--blocks))))

(defun dsh-emacs-ui--render-fragment (model &optional expanded width)
  "Render MODEL as a propertized string without changing the buffer.
MODEL carries both identity components; EXPANDED sets its fold state.
WIDTH, when supplied, is the body width already measured by the caller."
  (let* ((style (map-elt model :style))
         (non-foldable (map-elt model :non-foldable))
         (collapsed (not (or non-foldable expanded)))
         (width (or width (dsh-emacs-ui--box-width)))
         ;; Do not copy a closure's lexical environment.  Cache entries are
         ;; immutable; publish a new one only with the successfully drawn state.
         (state (mapcar (lambda (entry)
                          (if (memq (car entry) '(:body :body-cache))
                              (cons (car entry) (cdr entry))
                            (copy-tree entry)))
                        model))
         (source (map-elt model :body))
         (body
          (if (not (functionp source)) source
            (unless (and collapsed (eq style 'minimal))
              (let ((cache (map-elt model :body-cache)))
                (unless (and (eq (nth 0 cache) source)
                             (eql (nth 1 cache) width))
                  (setq cache
                        (list source width
                              (when-let* ((text (dsh-emacs-ui--string-or-nil
                                                (funcall source))))
                                (copy-sequence text))))
                  (setf (alist-get :body-cache state) cache))
                (nth 2 cache)))))
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
         (body-text (when lines (concat (mapconcat #'identity lines "\n") "\n")))
         (padding (if (map-elt model :padding) "\n" ""))
         (offset (length padding))
         (text (concat padding header body-text
                       (unless (eq style 'minimal)
                         (concat (dsh-emacs-ui--bottom-border style width) "\n"))
                       padding)))
    ;; Snapshots must not alias mutable strings owned by the caller.
    (dolist (key '(:namespace-id :block-id :label-left :label-right :body))
      (when (stringp (map-elt state key))
        (setf (alist-get key state) (copy-sequence (map-elt state key)))))
    (setf (alist-get :collapsed state) collapsed)
    (add-text-properties 0 (length text)
                         (list 'dsh-emacs-ui-state state
                               ;; Shared "a transcript block starts here"
                               ;; identity (chat messages carry it too):
                               ;; the older-history insertion point is
                               ;; located through it.
                               'dsh-emacs-transcript-block t
                               'read-only t 'front-sticky '(read-only)) text)
    ;; Region-scoped: header row and body lines are disjoint spans, and neither
    ;; face touches the border chrome — a row/status face cannot reach the body.
    (when-let* ((face (map-elt model :header-face)))
      (add-face-text-property offset (+ offset (length header)) face t text))
    (when-let* ((face (map-elt model :body-face)))
      (add-face-text-property (+ offset (length header))
                              (+ offset (length header) (length body-text))
                              face t text))
    text))

(cl-defun dsh-emacs-ui-update-fragment (model &key create-new expanded insert-before)
  "Replace or insert the complete MODEL snapshot.
Existing blocks preserve their fold state; nil fields clear old values.
CREATE-NEW bypasses lookup.  EXPANDED sets initial visibility.
INSERT-BEFORE selects the insertion position for a new block.
Return the exact (START . END) range, excluding surrounding spacing.
Rendering completes before editing; failed replacements roll back and signal."
  (let* ((model (cl-remove-if
                 (lambda (entry) (memq (car entry) '(:collapsed :body-cache)))
                 model))
         (namespace-id (map-elt model :namespace-id))
         (block-id (map-elt model :block-id))
         (width (dsh-emacs-ui--box-width))
         (layout (list width (copy-sequence dsh-emacs-ui-label-separator)))
         (changed nil)
         (views nil))
    (unwind-protect
        (save-mark-and-excursion
          (let* ((inhibit-read-only t)
                 (buffer-undo-list t)
                 (block (unless create-new
                          (dsh-emacs-ui-find-block namespace-id block-id)))
                 (state (and block (get-text-property
                                    (car block) 'dsh-emacs-ui-state)))
                 (entry (and block (not (buffer-narrowed-p)) dsh-emacs-ui--blocks
                             (gethash (cons namespace-id block-id)
                                      dsh-emacs-ui--blocks)))
                 (text
                  (progn
                    (when (and entry
                               (eql (nth 2 entry) (buffer-modified-tick))
                               (equal (nth 3 entry) layout)
                               (equal-including-properties
                                model (cl-remove-if
                                       (lambda (entry)
                                         (memq (car entry)
                                               '(:collapsed :body-cache)))
                                       state)))
                      (cl-return-from dsh-emacs-ui-update-fragment block))
                    (let ((cache (assq :body-cache state)))
                      (dsh-emacs-ui--render-fragment
                       (if (and cache (eq (map-elt model :body)
                                          (map-elt state :body)))
                           (cons cache model)
                         model)
                       (if block (not (map-elt state :collapsed)) expanded)
                       width)))))
            (when (and block
                       (let ((old (buffer-substring (car block) (cdr block)))
                             (end (length text)))
                         ;; Emacs 28 compares string property values by identity.
                         ;; Compare each property's data so fresh but equivalent
                         ;; snapshots do not rewrite an unchanged block.
                         (and (equal text old)
                              (cl-loop for pos = 0 then
                                       (min (next-property-change pos text end)
                                            (next-property-change pos old end))
                                       while (< pos end)
                                       always (equal-including-properties
                                               (text-properties-at pos text)
                                               (text-properties-at pos old))))))
              (dsh-emacs-ui--remember-block block layout)
              (cl-return-from dsh-emacs-ui-update-fragment block))
            ;; Captured only once a write is certain, so cache hits stay free.
            ;; Each reader's start is a marker that moves with the text: only
            ;; following windows and starts collapsed into the replaced span
            ;; need adjustment after the write.
            (let ((followers (when dsh-emacs-ui--following-windows-function
                               (funcall dsh-emacs-ui--following-windows-function))))
              (setq views (cl-loop for window in (get-buffer-window-list
                                                  (current-buffer) nil t)
                                   collect (list window
                                                 (if dsh-emacs-ui--following-windows-function
                                                     (memq window followers)
                                                   (dsh-emacs-ui--window-at-bottom-p
                                                    window (point-max)))
                                                 (save-excursion
                                                   (goto-char (window-start window))
                                                   (bolp))))))
            (let ((range (atomic-change-group
                           (if block
                               (let* ((start (car block))
                                      (old (buffer-substring-no-properties start (cdr block)))
                                      (comparison (compare-strings old nil nil text nil nil))
                                      (prefix (if (eq comparison t) (length old)
                                                (1- (abs comparison))))
                                      (suffix 0)
                                      (limit (- (min (length old) (length text)) prefix))
                                      (old-end (length old))
                                      (new-end (length text))
                                      (pos 0))
                                 ;; Keep the common prefix/suffix in place.  Only one
                                 ;; contiguous middle span is replaced, without a diff index.
                                 ;; Native substring comparisons avoid both per-character
                                 ;; Lisp calls and reversed copies of a potentially huge body.
                                 (while (< suffix limit)
                                   (let ((size (/ (+ suffix limit 1) 2)))
                                     (if (eq t (compare-strings old (- old-end size) old-end
                                                                text (- new-end size) new-end))
                                         (setq suffix size)
                                       (setq limit (1- size)))))
                                 (setq old-end (- old-end suffix)
                                       new-end (- new-end suffix))
                                 (delete-region (+ start prefix) (+ start old-end))
                                 (goto-char (+ start prefix))
                                 (when (> new-end prefix)
                                   (insert (substring text prefix new-end)))
                                 ;; Retained characters also need the new snapshot and
                                 ;; exact faces/keymaps, including property-only changes.
                                 (put-text-property start (+ start (length text))
                                                    'dsh-emacs-ui-state
                                                    (get-text-property 0 'dsh-emacs-ui-state text))
                                 (while (< pos (length text))
                                   (let* ((end (min (next-property-change pos text (length text))
                                                    (- (next-property-change
                                                        (+ start pos) nil (+ start (length text)))
                                                       start)))
                                          (props (text-properties-at pos text)))
                                     (unless (equal-including-properties
                                              props (text-properties-at (+ start pos)))
                                       (set-text-properties (+ start pos) (+ start end) props))
                                     (setq pos end)))
                                 (cons start (+ start (length text))))
                             (progn
                               (if insert-before
                                   (progn
                                     (goto-char insert-before)
                                     (beginning-of-line)
                                     (dsh-emacs-ui--consume-blanks-above
                                      (unless (map-elt model :padding)
                                        (dsh-emacs-ui--blank-above-preserve))))
                                 (goto-char (point-max))
                                 (unless (or (bobp)
                                             (get-text-property (1- (point)) 'dsh-emacs-ui-state))
                                   (insert (propertize "\n" 'read-only t
                                                       'front-sticky '(read-only))))))
                             (let ((start (point)))
                               (insert text)
                               (cons start (point)))))))
              (dsh-emacs-ui--remember-block range layout)
              (setq changed t)
              range)))
      (when changed
        (pcase-dolist (`(,window ,at-bottom ,start-bolp) views)
          (when (window-live-p window)
            (cond
             (at-bottom
              ;; Native recentering accounts for wrapping, line spacing and
              ;; faces.  Re-setting the start unforced still lets redisplay
              ;; keep point visible instead of moving it.
              (with-selected-window window
                (save-excursion
                  (goto-char (point-max))
                  (recenter -1))
                (set-window-start window (window-start window) t)))
             ((and start-bolp
                   (save-excursion
                     (goto-char (window-start window))
                     (not (bolp))))
              ;; The start sat in the replaced span and collapsed onto the
              ;; edit; show that whole line rather than a fragment of it.
              (set-window-start window
                                (save-excursion
                                  (goto-char (window-start window))
                                  (line-beginning-position))
                                t)))))))))

(cl-defun dsh-emacs-ui-find-block (namespace-id block-id)
  "Find the block identified by NAMESPACE-ID and BLOCK-ID in this buffer.
Returns (START . END) or nil."
  (let* ((key (cons namespace-id block-id))
         (entry (and (not (buffer-narrowed-p)) dsh-emacs-ui--blocks
                     (gethash key dsh-emacs-ui--blocks)))
         (pos (and entry (marker-position (car entry)))))
    (when (and pos (<= (point-min) pos) (< pos (point-max))
               (eq (get-text-property pos 'dsh-emacs-ui-state) (nth 1 entry)))
      (cl-return-from dsh-emacs-ui-find-block (dsh-emacs-ui--block-at pos)))
    (when entry
      (set-marker (car entry) nil)
      (remhash key dsh-emacs-ui--blocks)))
  (save-mark-and-excursion
    (goto-char (point-max))
    (when-let* ((match (text-property-search-backward
                        'dsh-emacs-ui-state nil
                        (lambda (_ state)
                          (and (equal (map-elt state :namespace-id) namespace-id)
                               (equal (map-elt state :block-id) block-id)))
                        t)))
      (let ((range (cons (prop-match-beginning match) (prop-match-end match))))
        (dsh-emacs-ui--remember-block range)
        range))))

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
  (when-let* ((state (get-text-property (point) 'dsh-emacs-ui-state))
              ((not (map-elt state :non-foldable)))
              (block (dsh-emacs-ui--block-at (point))))
    (let ((inhibit-read-only t)
          (buffer-undo-list t)
          (offset (- (point) (car block)))
          (text (dsh-emacs-ui--render-fragment
                 state (map-elt state :collapsed))))
      (save-mark-and-excursion
        (atomic-change-group
          ;; Insert first so markers at the old end stay after the replacement,
          ;; including a following live reply's non-advancing start marker.
          (goto-char (car block))
          (insert text)
          (delete-region (point) (+ (cdr block) (length text))))
        (dsh-emacs-ui--remember-block
         (cons (car block) (+ (car block) (length text)))))
      ;; The saved point marker falls to the new end when old text is deleted.
      ;; Keep its relative position instead, clamping if the body disappeared.
      (goto-char (+ (car block) (min offset (1- (length text))))))))

;;;###autoload
(defun dsh-emacs-ui-toggle-fragment ()
  "Toggle fragment fold at or near point.
Silent no-op when no fragment exists at or after point."
  (interactive)
  (when-let* ((pos (dsh-emacs-ui--enclosing-fragment-position)))
    (goto-char pos)
    (let* ((state (get-text-property pos 'dsh-emacs-ui-state))
           (label (map-elt state :label-left))
           (overlay (and label (get-text-property
                                0 'dsh-emacs-work-details label))))
      (if overlay
          (dsh-emacs-ui--set-work-details-expanded
           overlay (overlay-get overlay 'invisible))
        (dsh-emacs-ui--toggle-fragment-at-point)))))

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

(defun dsh-emacs-ui--set-work-details-expanded (overlay expanded)
  "Set OVERLAY's work-detail visibility to EXPANDED."
  (overlay-put overlay 'invisible (unless expanded 'dsh-emacs-work-details))
  ;; A hidden first character's image display can otherwise remain visible.
  (overlay-put overlay 'display (unless expanded ""))
  (when-let* ((block (dsh-emacs-ui-find-block
                      (overlay-get overlay 'namespace)
                      (overlay-get overlay 'block-id)))
              (pos (text-property-not-all (car block) (cdr block) 'button nil))
              (button (button-at pos)))
    (let* ((inhibit-read-only t)
           (buffer-undo-list t)
           (start (button-start button))
           (end (button-end button))
           (icon
            (if (and (display-graphic-p) (image-type-available-p 'svg))
                (let* ((foreground (face-foreground 'dsh-emacs-reply-meta-face nil t))
                       (rgb (and foreground (color-values foreground)))
                       (color (if rgb
                                  (apply #'format "#%02x%02x%02x"
                                         (mapcar (lambda (channel) (/ channel 257)) rgb))
                                "#808080")))
                  (create-image
                   (format (concat "<svg xmlns=\"http://www.w3.org/2000/svg\" "
                                   "width=\"16\" height=\"16\" viewBox=\"0 0 16 16\">"
                                   "<path d=\"%s\" fill=\"none\" stroke=\"%s\" "
                                   "stroke-width=\"1.4\" stroke-linecap=\"round\" "
                                   "stroke-linejoin=\"round\"/></svg>")
                           (if expanded "M4 10l4-4 4 4" "M4 6l4 4 4-4") color)
                   'svg t :ascent 'center :height 0.9))
              (if expanded "▴" "▾"))))
      ;; The caption keeps the label's own face.  A display replacement would
      ;; bypass the header's width truncation and widen a narrow window.
      (remove-text-properties start end '(display nil))
      ;; Space below the summary without changing its font or the answer's.
      (when (and (< end (point-max)) (eq (char-after end) ?\n))
        (put-text-property end (1+ end) 'line-spacing 0.5))
      ;; Only a surviving chevron can carry the icon; a truncated header keeps
      ;; its ellipsis instead of overflowing the row.
      (when (and (>= (- end start) 2)
                 (equal " ▾" (buffer-substring-no-properties (- end 2) end)))
        (put-text-property (1- end) end 'display icon)))))

(defun dsh-emacs-ui--toggle-work-details (button)
  "Toggle the work-detail region controlled by BUTTON."
  (let ((overlay (button-get button 'dsh-emacs-work-details)))
    (dsh-emacs-ui--set-work-details-expanded
     overlay (overlay-get overlay 'invisible))))

(defun dsh-emacs-ui--isearch-open-work-details (overlay)
  "Reveal work details in OVERLAY when search finds hidden content."
  (dsh-emacs-ui--set-work-details-expanded overlay t))

(defun dsh-emacs-ui-fold-region (namespace block-id start end
                                           &optional overlay label status)
  "Fold START..END behind a control named NAMESPACE and BLOCK-ID.
Keep original text and child fragments in place.  Reuse OVERLAY when supplied,
preserving manual expansion as older history extends the region.  LABEL
is the summary, defaulting to Completed.  STATUS distinguishes a task's
work-details header from an activity-details header."
  (let* ((live (and overlay (overlay-buffer overlay)))
         (header (and live (dsh-emacs-ui-find-block namespace block-id)))
         (expanded (and live (not (overlay-get overlay 'invisible))))
         (previous (and live (overlay-get overlay 'dsh-emacs-work-label)))
         (caption (or label "Completed")))
    (when live (overlay-put overlay 'dsh-emacs-work-label caption))
    (if (and header (<= (car header) start) (<= start (cdr header))
             (equal previous caption))
        (move-overlay overlay (cdr header) end)
      (unless live
        (setq overlay (make-overlay start end nil nil nil))
        (overlay-put overlay 'dsh-emacs-work-label caption)
        (overlay-put overlay 'namespace namespace)
        (overlay-put overlay 'block-id block-id)
        (overlay-put overlay 'isearch-open-invisible
                     #'dsh-emacs-ui--isearch-open-work-details)
        (add-to-invisibility-spec 'dsh-emacs-work-details))
      (let ((end-marker (copy-marker end t))
            (start-marker (copy-marker start nil)))
        (unwind-protect
            (progn
              (when header (dsh-emacs-ui-delete-fragment namespace block-id))
              (setq header
                    (dsh-emacs-ui-update-fragment
                     (dsh-emacs-ui-make-fragment
                      :namespace-id namespace :block-id block-id
                      :label-left
                      (make-text-button
                       (concat caption " ▾") nil 'follow-link t
                       'face 'dsh-emacs-reply-meta-face
                       'help-echo "Show or hide details"
                       'action #'dsh-emacs-ui--toggle-work-details
                       'dsh-emacs-work-details overlay)
                      :style 'minimal :status (or status 'work-details)
                      :non-foldable t)
                     :insert-before start-marker))
              (move-overlay overlay (cdr header) end-marker))
          (set-marker start-marker nil)
          (set-marker end-marker nil))))
    (dsh-emacs-ui--set-work-details-expanded overlay expanded)
    overlay))

(defun dsh-emacs-ui-delete-work-details (overlay)
  "Release OVERLAY and its disclosure header."
  (dsh-emacs-ui-delete-fragment (overlay-get overlay 'namespace)
                                (overlay-get overlay 'block-id))
  (delete-overlay overlay))

;;; ---------------------------------------------------------------------------
;;; Delete fragment
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-ui-delete-fragment (namespace-id block-id)
  "Delete fragment with NAMESPACE-ID and BLOCK-ID."
  (save-mark-and-excursion
    (let* ((inhibit-read-only t)
           (buffer-undo-list t)
           (match (dsh-emacs-ui-find-block namespace-id block-id)))
      (when match
        (delete-region (car match) (cdr match))
        (when-let* ((entry (and dsh-emacs-ui--blocks
                               (gethash (cons namespace-id block-id)
                                        dsh-emacs-ui--blocks))))
          (set-marker (car entry) nil)
          (remhash (cons namespace-id block-id) dsh-emacs-ui--blocks))))))

;;; ---------------------------------------------------------------------------
;;; Navigation helpers
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-ui-forward-block ()
  "Jump to the next fragment block."
  (interactive)
  (let* ((block (dsh-emacs-ui--block-at (point)))
         (escape (and (invisible-p (point))
                      (next-single-char-property-change
                       (point) 'invisible nil (point-max))))
         (pos (if block (cdr block) (point))))
    (while (and (< pos (point-max))
                (or (invisible-p pos)
                    (not (get-text-property pos 'dsh-emacs-ui-state))))
      (setq pos (if (invisible-p pos)
                    (next-single-char-property-change
                     pos 'invisible nil (point-max))
                  (next-single-property-change
                   pos 'dsh-emacs-ui-state nil (point-max)))))
    (cond ((and (not (invisible-p pos))
                (get-text-property pos 'dsh-emacs-ui-state))
           (goto-char pos))
          (escape (goto-char escape)))))

(defun dsh-emacs-ui-backward-block ()
  "Jump to the previous fragment block."
  (interactive)
  (when-let* ((found
               (save-mark-and-excursion
                 (let* ((block (dsh-emacs-ui--block-at (point)))
                        (start (and block (car block)))
                        match found)
                   (if (and start (< start (point)) (not (invisible-p start)))
                       start
                     (while (and (not found)
                                 (setq match
                                       (text-property-search-backward
                                        'dsh-emacs-ui-state nil
                                        (lambda (_ state) (and state t)) t)))
                       (unless (invisible-p (prop-match-beginning match))
                         (setq found (prop-match-beginning match))))
                     found)))))
    (goto-char found)))

;;; ---------------------------------------------------------------------------
;;; Clear all fragments
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-ui-clear ()
  "Clear all UI fragments from the buffer."
  (interactive)
  (let ((inhibit-read-only t)
        (buffer-undo-list t))
    (erase-buffer)))

;;; ---------------------------------------------------------------------------
;;; Collapse all fragments
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-ui-collapse-all ()
  "Collapse every fragment in the current buffer."
  (interactive)
  (save-mark-and-excursion
    (let ((inhibit-read-only t))
      (goto-char (point-min))
      (while (not (eobp))
        (let* ((state (get-text-property (point) 'dsh-emacs-ui-state))
               (label (map-elt state :label-left))
               (overlay (and label (get-text-property
                                    0 'dsh-emacs-work-details label))))
          (cond (overlay (dsh-emacs-ui--set-work-details-expanded overlay nil))
                ((and state (not (map-elt state :collapsed)))
                 (dsh-emacs-ui--toggle-fragment-at-point))))
        (goto-char (next-single-property-change
                    (point) 'dsh-emacs-ui-state nil (point-max))))))
  (when (invisible-p (point))
    (dsh-emacs-ui-backward-block)))

(defun dsh-emacs-ui-expand-all ()
  "Expand every fragment in the current buffer."
  (interactive)
  (save-mark-and-excursion
    (let ((inhibit-read-only t))
      (goto-char (point-min))
      (while (not (eobp))
        (let* ((state (get-text-property (point) 'dsh-emacs-ui-state))
               (label (map-elt state :label-left))
               (overlay (and label (get-text-property
                                    0 'dsh-emacs-work-details label))))
          (cond (overlay (dsh-emacs-ui--set-work-details-expanded overlay t))
                ((and state (map-elt state :collapsed))
                 (dsh-emacs-ui--toggle-fragment-at-point))))
        (goto-char (next-single-property-change
                    (point) 'dsh-emacs-ui-state nil (point-max)))))))

;;; ---------------------------------------------------------------------------
;;; Mode
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
