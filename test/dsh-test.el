;;; dsh-test.el --- dsh-emacs unit tests (modular layout) -*- lexical-binding: t; -*-
(setq debug-on-error t)
;; Batch/cron runs have no working gcc: `cl-letf' on a built-in subr like
;; `completing-read' would otherwise demand a native trampoline compile and
;; die with "native-ice (error invoking gcc driver)".  Disabling the
;; trampoline falls back to the (slower) non-compiled advice path.
(when (boundp 'comp-enable-subr-trampolines)
  (setq comp-enable-subr-trampolines nil))
(add-to-list 'load-path (expand-file-name ".." (file-name-directory load-file-name)))

;; Load all modules
(require 'dsh-emacs)

(defvar vertico-mode nil "Stub: vertico global minor mode flag (test-only).")
(defvar vertico-preselect nil "Stub: vertico preselect option (test-only).")

(defvar dsh-test-results '())

(defun dsh-emacs-test--session-items (items)
  "Wrap raw session-item alists ITEMS as `dsh-protocol-session' structs
so the code under test can read fields through the protocol accessors."
  (mapcar #'dsh-protocol-session--from-alist items))

(defun dsh-test-pass (name)
  (push (cons name t) dsh-test-results)
  (princ (format "PASS: %s\n" name)))

(defun dsh-test-fail (name detail)
  (push (cons name nil) dsh-test-results)
  (princ (format "FAIL: %s -- %s\n" name detail)))

(defun dsh-test-assert (name &rest conditions)
  "Record PASS for NAME when every CONDITIONS form is non-nil, else FAIL.
Unlike the pass-only `(when COND (dsh-test-pass NAME))' idiom, this
ALWAYS records a result, so an assertion that never holds shows up as
FAIL instead of silently vanishing from the summary.  Empty CONDITIONS
(programmer error) fail loudly."
  (if (and conditions (cl-every #'identity conditions))
      (dsh-test-pass name)
    (dsh-test-fail name "assertion failed (dsh-test-assert)")))

(defun dsh-test--faces-at (pos)
  "Return the `face' property at POS as a list (nil when unset).
Lets face assertions read uniformly whether the property holds one face
symbol or an ordered list."
  (ensure-list (get-text-property pos 'face)))

;; Follow checks must stop after one screen plus slack, even in long history.
(with-temp-buffer
  (insert (make-string 20000 ?\n) "tail")
  (let ((window (selected-window))
        (counted 0)
        (original (symbol-function 'count-lines)))
    (cl-letf (((symbol-function 'window-start) (lambda (&rest _) 1))
              ((symbol-function 'window-text-height) (lambda (&rest _) 5))
              ((symbol-function 'count-lines)
               (lambda (start end &rest args)
                 (setq counted (+ counted (- end start)))
                 (apply original start end args))))
      (dsh-test-assert "follow-threshold-keeps-boundary"
        (dsh-emacs-render--window-at-bottom-p window 16)
        (not (dsh-emacs-render--window-at-bottom-p window 17)))
      (dsh-test-assert "follow-long-history-is-not-at-bottom"
        (not (dsh-emacs-render--window-at-bottom-p window (point-max))))
      (cl-letf (((symbol-function 'get-buffer-window) (lambda (&rest _) window))
                ((symbol-function 'set-window-start) #'ignore))
        (dsh-emacs-ui-update-fragment
         (dsh-emacs-ui-make-fragment :label-left "New" :style 'minimal)
         :create-new t))
      (dsh-test-assert "follow-checks-do-not-count-entire-history"
        (< counted 100)))))

;; Default character rows can overestimate capacity with line spacing/fonts.
(dolist (draft '("" "draft line one\nline two\nline three"))
  (save-window-excursion
    (with-temp-buffer
      (dsh-emacs-mode)
      (let ((inhibit-read-only t))
        (goto-char (point-min))
        (insert (apply #'concat (make-list 100 "history line\n"))))
      (goto-char dsh-emacs--input-marker)
      (insert draft)
      (let* ((window (selected-window))
             (draft-point (point))
             (reported-height (+ (window-text-height window) 10)))
        (set-window-buffer window (current-buffer))
        (cl-letf (((symbol-function 'window-text-height)
                   (lambda (&rest _) reported-height)))
          (dsh-emacs-render--follow-stream (list window))
          (let ((start (window-start window)))
            (dsh-emacs-render--follow-stream (list window))
            (dsh-test-assert
                (if (string-empty-p draft) "follow-keeps-empty-input-visible"
                  "follow-keeps-multiline-draft-visible")
              (= (point) draft-point)
              ;; Batch mode has no glyph matrix for visibility queries.
              ;; Check the actual row budget, not the overstated metric.
              (save-excursion
                (goto-char (window-start window))
                (vertical-motion (window-body-height window) window)
                (>= (point) draft-point))
              (= (window-start window) start))))))))

;; Wrapped transcript lines count as screen rows for following and pinning.
(save-window-excursion
  (with-temp-buffer
    (dsh-emacs-mode)
    (let ((window (selected-window))
          (inhibit-read-only t))
      (set-window-buffer window (current-buffer))
      (goto-char (point-min))
      (insert (make-string 10000 ?x) "\n")
      (let ((anchor (dsh-emacs-render--input-anchor-pos)))
        (set-window-start window (point-min))
        (goto-char (point-max))
        (dsh-test-assert "follow-wrapped-history-is-not-at-bottom"
          (not (dsh-emacs-render--window-at-bottom-p window anchor)))
        (dsh-emacs-render--follow-stream)
        (dsh-test-assert "follow-preserves-scrolled-wrapped-window"
          (= (window-start window) (point-min)))
        (goto-char anchor)
        (vertical-motion (- (1- (window-text-height window))) window)
        (let ((expected (point)))
          (set-window-start window expected)
          (goto-char (point-max))
          (let ((draft-point (point)))
            (dsh-emacs-render--follow-stream)
            (dsh-test-assert "follow-pins-by-screen-rows-without-moving-draft"
              (= (window-start window) expected)
              (> expected (point-min))
              (= (point) draft-point))))))))

;; Reading the transcript rules out following before any screen-row scan.
(save-window-excursion
  (with-temp-buffer
    (dsh-emacs-mode)
    (set-window-buffer (selected-window) (current-buffer))
    (dsh-emacs-render--start-assistant-stream
     '((data . ((turn . 1) (step . 1)))) "visible history\n")
    (goto-char (point-min))
    (let ((scans 0))
      (cl-letf (((symbol-function 'dsh-emacs-render--window-at-bottom-p)
                 (lambda (&rest _) (cl-incf scans) t)))
        (dsh-emacs-render--follow-stream))
      (dsh-test-assert "follow-history-reader-skips-screen-row-scans"
        (zerop scans)
        (= (point) (point-min))))))

;; Large stream writes retain the windows following before the edit.
(dolist (kind '(assistant thinking assistant-first thinking-first correction))
  (save-window-excursion
    (with-temp-buffer
      (dsh-emacs-mode)
      (let* ((window (selected-window))
             (event '((data . ((turn . 1) (step . 1)))))
             (start (if (memq kind '(thinking thinking-first))
                        #'dsh-emacs-render--start-thinking-stream
                      #'dsh-emacs-render--start-assistant-stream))
             (text (apply #'concat (make-list 100 "new row\n"))))
        (set-window-buffer window (current-buffer))
        (goto-char (point-max))
        (insert "draft")
        (unless (memq kind '(assistant-first thinking-first))
          (funcall start event "intro\n"))
        (let ((draft-offset (- (point) dsh-emacs--input-marker)))
          (if (eq kind 'correction)
              (dsh-emacs-render--finish-assistant-stream event text)
            (funcall start event text)
            (if (eq kind 'thinking)
                (dsh-emacs-render--flush-thinking)
              (unless (memq kind '(assistant-first thinking-first))
                (dsh-emacs-render--flush-stream))))
          (dsh-test-assert (format "stream-large-%s-retains-follow" kind)
            (= (window-start window)
               (save-excursion
                 (goto-char (dsh-emacs-render--input-anchor-pos))
                 (vertical-motion (- (1- (window-text-height window))) window)
                 (point)))
            (> (window-start window) 1)
            (= (- (point) dsh-emacs--input-marker) draft-offset)
            (equal (dsh-emacs--get-input) "draft")))
        (dsh-emacs-render--flush-stream nil t)))))

;; A user scroll while a timer is pending wins over the queued output.
(dolist (kind '(assistant thinking))
  (save-window-excursion
    (with-temp-buffer
      (dsh-emacs-mode)
      (let ((window (selected-window))
            (event '((data . ((turn . 1) (step . 1)))))
            (start (if (eq kind 'thinking)
                       #'dsh-emacs-render--start-thinking-stream
                     #'dsh-emacs-render--start-assistant-stream)))
        (set-window-buffer window (current-buffer))
        (funcall start event (apply #'concat (make-list 100 "history\n")))
        (goto-char (point-max))
        (funcall start event "queued\n")
        (set-window-start window 1)
        (goto-char 5)
        (dsh-emacs-render--flush-stream)
        (dsh-test-assert (format "stream-%s-flush-respects-new-scroll" kind)
          (= (window-start window) 1) (= (point) 5))
        (dsh-emacs-render--flush-stream nil t)))))

;; Following must not move the cursor in an unselected history reader.
(save-window-excursion
  (with-temp-buffer
    (dsh-emacs-mode)
    (let ((reader (split-window-right))
          (inhibit-read-only t))
      (goto-char (point-min))
      (insert (apply #'concat (make-list 100 "history\n")))
      (set-window-buffer reader (current-buffer))
      (set-window-start reader 1)
      (set-window-point reader 10)
      (dsh-emacs-render--follow-stream)
      (dsh-test-assert "follow-preserves-unselected-history-cursor"
        (= (window-start reader) 1)
        (= (window-point reader) 10)))))

;; A displayed buffer can contain an offscreen running command.
(with-temp-buffer
  (let ((dsh-emacs--command-spinners (make-hash-table :test 'equal))
        (dsh-emacs--command-blocks (make-hash-table :test 'equal))
        (window (selected-window))
        (visible nil)
        (redraws 0))
    (puthash "spin" (list (current-buffer) nil 0) dsh-emacs--command-spinners)
    (puthash "spin" '("ns" "cmd-spin" "goal" "") dsh-emacs--command-blocks)
    (cl-letf (((symbol-function 'get-buffer-window) (lambda (&rest _) window))
              ((symbol-function 'get-buffer-window-list)
               (lambda (&rest _) (list window)))
              ((symbol-function 'dsh-emacs-ui-find-block)
               (lambda (&rest _) '(1 . 10)))
              ((symbol-function 'pos-visible-in-window-p)
               (lambda (&rest _) visible))
              ((symbol-function 'dsh-emacs-ui-update-fragment)
               (lambda (&rest _) (setq redraws (1+ redraws)))))
      (dsh-emacs--command-spinner-tick (current-buffer) "spin")
      (dsh-test-assert "spinner-offscreen-advances-without-redraw"
        (= redraws 0)
        (= (nth 2 (gethash "spin" dsh-emacs--command-spinners)) 1))
      (setq visible t)
      (dsh-emacs--command-spinner-tick (current-buffer) "spin")
      (dsh-test-assert "spinner-visible-resumes-redraw"
        (= redraws 1)
        (= (nth 2 (gethash "spin" dsh-emacs--command-spinners)) 2)))))

;; Identical fragment updates must preserve interior markers and change ticks.
(dolist (style '(minimal rounded sharp))
  (with-temp-buffer
    (let* ((model (dsh-emacs-ui-make-fragment
                   :namespace-id "unchanged" :block-id "a" :style style
                   :label-left "Title" :body "body"))
           (range (dsh-emacs-ui-update-fragment model :expanded t))
           (inside (copy-marker (+ (car range) 2)))
           (tick (buffer-modified-tick)))
      (dsh-test-assert (format "fragment-identical-update-no-write-%s" style)
        (equal range (dsh-emacs-ui-update-fragment model))
        (= tick (buffer-modified-tick))
        (= inside (+ (car range) 2)))
      (setf (alist-get :body model) (propertize "body" 'face 'bold))
      (dsh-emacs-ui-update-fragment model)
      (goto-char (point-min))
      (search-forward "body")
      (dsh-test-assert (format "fragment-property-only-update-applies-%s" style)
        (eq (get-text-property (1- (point)) 'face) 'bold))
      (set-marker inside nil))))

;; Hidden content and layout changes must not be mistaken for identical updates.
(with-temp-buffer
  (let ((model (dsh-emacs-ui-make-fragment
                :label-left "Long title" :body "old" :style 'minimal)))
    (dsh-emacs-ui-update-fragment model)
    (setf (alist-get :body model) (propertize "new" 'face 'italic))
    (dsh-emacs-ui-update-fragment model)
    (goto-char (point-min))
    (dsh-emacs-ui-toggle-fragment)
    (search-forward "new")
    (dsh-test-assert "fragment-hidden-update-retains-new-body-properties"
      (eq (get-text-property (1- (point)) 'face) 'italic))
    (cl-letf (((symbol-function 'dsh-emacs-ui--box-width) (lambda () 4)))
      (dsh-emacs-ui-update-fragment model))
    (goto-char (point-min))
    (dsh-test-assert "fragment-same-model-reflows-at-new-width"
      (equal (buffer-substring-no-properties (point) (line-end-position))
             "Lon…"))))

;; Changed fragments retain markers in the unchanged prefix and suffix.
(with-temp-buffer
  (let* ((model (dsh-emacs-ui-make-fragment
                 :style 'minimal :label-left "Title" :body "alpha\nold\nomega"))
         (range (dsh-emacs-ui-update-fragment model :expanded t))
         (title (copy-marker (+ (car range) 2)))
         (suffix (copy-marker (- (cdr range) 4))))
    (setf (alist-get :body model) "alpha\nlong replacement\nomega")
    (dsh-emacs-ui-update-fragment model)
    (dsh-test-assert "fragment-diff-preserves-unchanged-markers"
      (= title 3)
      (equal (buffer-substring-no-properties suffix (+ suffix 3)) "ega"))
    (set-marker title nil)
    (set-marker suffix nil)))

;; Repeated lookup and identical updates must not scan or render again.
(with-temp-buffer
  (let ((model (dsh-emacs-ui-make-fragment
                :namespace-id "cache" :block-id "a" :style 'minimal
                :label-left "Title" :body "Body"))
        (scans 0) (renders 0)
        (scan (symbol-function 'text-property-search-backward))
        (render (symbol-function 'dsh-emacs-ui--render-fragment)))
    (dsh-emacs-ui-update-fragment model :expanded t)
    (cl-letf (((symbol-function 'text-property-search-backward)
               (lambda (&rest args) (setq scans (1+ scans)) (apply scan args)))
              ((symbol-function 'dsh-emacs-ui--render-fragment)
               (lambda (&rest args) (setq renders (1+ renders)) (apply render args))))
      (dotimes (_ 3)
        (dsh-emacs-ui-find-block "cache" "a")
        (dsh-emacs-ui-update-fragment model))
      (dsh-test-assert "fragment-repeated-updates-skip-scan-and-render"
        (= scans 0) (= renders 0)))
    ;; Caller mutation and external text edits must invalidate the fast path.
    (aset (alist-get :body model) 0 ?b)
    (dsh-emacs-ui-update-fragment model)
    (dsh-test-assert "fragment-caller-string-mutation-is-not-cached"
      (string-match-p "body" (buffer-string)))
    (let ((inhibit-read-only t))
      (goto-char (point-min)) (insert "prefix\n"))
    (dsh-test-assert "fragment-index-follows-external-prefix-insertion"
      (= (car (dsh-emacs-ui-find-block "cache" "a")) 8))
    (let ((inhibit-read-only t)) (erase-buffer))
    (dsh-test-assert "fragment-index-does-not-return-erased-block"
      (not (dsh-emacs-ui-find-block "cache" "a")))
    (dsh-emacs-ui-update-fragment model)
    (goto-char (point-min)) (dsh-emacs-ui-toggle-fragment)
    (dsh-test-assert "fragment-index-survives-recreate-and-fold"
      (equal (dsh-emacs-ui-find-block "cache" "a")
             (cons (point-min) (point-max))))))

;; Header changes do not rewrite unchanged body styling; rollback stays atomic.
(with-temp-buffer
  (let* ((model (dsh-emacs-ui-make-fragment
                 :style 'minimal :label-left "Old"
                 :body (propertize "unchanged body" 'face 'italic)))
         (writes 0)
         (setter (symbol-function 'set-text-properties)))
    (dsh-emacs-ui-update-fragment model :expanded t)
    (setf (alist-get :label-left model) "New")
    (cl-letf (((symbol-function 'set-text-properties)
               (lambda (start end props &optional object)
                 (when (and (not object) (>= start 5))
                   (setq writes (1+ writes)))
                 (funcall setter start end props object))))
      (dsh-emacs-ui-update-fragment model))
    (dsh-test-assert "fragment-header-change-does-not-restyle-body"
      (= writes 0)
      (eq (get-text-property 5 'face) 'italic))
    (let ((before (buffer-string))
          (putter (symbol-function 'put-text-property))
          caught)
      (setf (alist-get :body model) (propertize "unchanged body" 'face 'bold))
      (condition-case err
          (cl-letf (((symbol-function 'put-text-property)
                     (lambda (start end prop value &optional object)
                       (funcall putter start end prop value object)
                       (when (and (not object) (eq prop 'dsh-emacs-ui-state))
                         (error "injected property failure")))))
            (dsh-emacs-ui-update-fragment model))
        (error (setq caught (equal (error-message-string err)
                                   "injected property failure"))))
      (dsh-test-assert "fragment-property-failure-rolls-back-cache-and-text"
        caught (equal-including-properties before (buffer-string))
        (equal (dsh-emacs-ui-find-block "global" "1")
               (cons (point-min) (point-max)))))))

;; The index preserves duplicate-ID ordering, delete and buffer isolation.
(with-temp-buffer
  (buffer-enable-undo)
  (let ((model (dsh-emacs-ui-make-fragment :style 'minimal :label-left "Later")))
    (dsh-emacs-ui-update-fragment model :create-new t)
    (setf (alist-get :label-left model) "Earlier")
    (dsh-emacs-ui-update-fragment model :create-new t :insert-before (point-min))
    (dsh-test-assert "fragment-index-keeps-last-duplicate"
      (= (car (dsh-emacs-ui-find-block "global" "1")) 9))
    (save-restriction
      (narrow-to-region 1 9)
      (dsh-test-assert "fragment-index-respects-narrowing"
        (equal (dsh-emacs-ui-find-block "global" "1") '(1 . 9))))
    (dsh-test-assert "fragment-index-widen-restores-last-duplicate"
      (= (car (dsh-emacs-ui-find-block "global" "1")) 9))
    (undo-boundary)
    (dsh-emacs-ui-delete-fragment "global" "1")
    (dsh-test-assert "fragment-index-delete-reveals-earlier-duplicate"
      (equal (dsh-emacs-ui-find-block "global" "1") '(1 . 9)))
    ;; Drive undo itself: it must run out of history without restoring Later
    ;; or disturbing the remaining fragment and its cached index.
    (let ((before (buffer-string))
          (last-command nil) (this-command 'undo) (pending-undo-list nil)
          (undo-equiv-table (make-hash-table :test 'eq))
          exhausted)
      (condition-case nil
          (undo)
        (user-error (setq exhausted t)))
      (dsh-test-assert "fragment-delete-is-not-undoable"
        exhausted
        (equal-including-properties before (buffer-string))
        (equal (dsh-emacs-ui-find-block "global" "1") '(1 . 9))))
    (with-temp-buffer
      (dsh-test-assert "fragment-index-is-buffer-local"
        (not (dsh-emacs-ui-find-block "global" "1"))))))

;; A cached model must still honor separator and arbitrary buffer changes.
(with-temp-buffer
  (let ((model (dsh-emacs-ui-make-fragment
                :style 'minimal :label-left "Title" :label-right "Summary")))
    (dsh-emacs-ui-update-fragment model)
    (let ((dsh-emacs-ui-label-separator "/"))
      (dsh-emacs-ui-update-fragment model)
      (dsh-test-assert "fragment-cache-invalidates-on-separator-change"
        (equal (buffer-substring-no-properties (point-min) (point-max))
               "Title / Summary\n"))
      (let ((inhibit-read-only t))
        (subst-char-in-region (point-min) (point-max) ?T ?X))
      (dsh-emacs-ui-update-fragment model)
      (dsh-test-assert "fragment-cache-repairs-external-text-edit"
        (equal (buffer-substring-no-properties (point-min) (point-max))
               "Title / Summary\n")))))

;; Entirely narrowed operations need no global cache, including deletion.
(with-temp-buffer
  (insert "outside\n")
  (save-restriction
    (narrow-to-region (point-max) (point-max))
    (dsh-emacs-ui-update-fragment
     (dsh-emacs-ui-make-fragment :style 'minimal :label-left "Inside"))
    (condition-case err
        (progn
          (dsh-emacs-ui-delete-fragment "global" "1")
          (dsh-test-assert "fragment-narrowed-delete-without-index"
            (= (point-min) (point-max))))
      (error (dsh-test-fail "fragment-narrowed-delete-without-index"
                            (error-message-string err))))))

;; --- Test 1: module loading ---
(when (featurep 'dsh-emacs)
  (dsh-test-pass "dsh-emacs loaded"))

(when (featurep 'dsh-emacs-faces)
  (dsh-test-pass "dsh-emacs-faces loaded"))

(when (featurep 'dsh-emacs-tokens)
  (dsh-test-pass "dsh-emacs-tokens loaded"))

(when (featurep 'dsh-emacs-render)
  (dsh-test-pass "dsh-emacs-render loaded"))

(when (featurep 'dsh-emacs-modeline)
  (dsh-test-pass "dsh-emacs-modeline loaded"))

(when (featurep 'dsh-emacs-session)
  (dsh-test-pass "dsh-emacs-session loaded"))

(when (featurep 'dsh-emacs-markdown)
  (dsh-test-pass "dsh-emacs-markdown loaded"))

(when (featurep 'dsh-emacs-command)
  (dsh-test-pass "dsh-emacs-command loaded"))

(when (featurep 'dsh-emacs-reference)
  (dsh-test-pass "dsh-emacs-reference loaded"))

;; --- Test 2: Token formatting ---
(when (string= "1.2k" (dsh-emacs-format-tokens 1234))
  (dsh-test-pass "format-tokens 1234"))

(when (string= "1.5M" (dsh-emacs-format-tokens 1500000))
  (dsh-test-pass "format-tokens 1500000"))

(when (string= "100" (dsh-emacs-format-tokens 100))
  (dsh-test-pass "format-tokens 100"))

;; --- Test 3: Token structure ---
(let ((usage (dsh-emacs-make-usage)))
  (when (and (= 0 (dsh-emacs-usage-input usage))
             (= 0 (dsh-emacs-usage-output usage)))
    (dsh-test-pass "usage-create")))

(let ((usage (dsh-emacs-make-usage 100 50)))
  (when (and (= 100 (dsh-emacs-usage-input usage))
             (= 50 (dsh-emacs-usage-output usage)))
    (dsh-test-pass "usage-create with args")))

;; --- Test 4: Token accumulation ---
(let ((u1 (dsh-emacs-make-usage 100 50))
      (u2 (dsh-emacs-make-usage 200 100)))
  (dsh-emacs-usage-add u1 u2)
  (when (and (= 300 (dsh-emacs-usage-input u1))
             (= 150 (dsh-emacs-usage-output u1)))
    (dsh-test-pass "usage-add")))

;; --- Test 5b: usage parsing (real dsh event shape: data.usage + camelCase) ---
(let* ((event '(("type" . "assistant/message")
                ("seq" . 103)
                ("data" . (("usage" . (("inputTokens" . 626)
                                       ("outputTokens" . 155)
                                       ("cacheReadTokens" . 7168)))))))
       (usage (dsh-emacs-usage-from-event event)))
  (when (and (= 626 (dsh-emacs-usage-input usage))
             (= 155 (dsh-emacs-usage-output usage))
             (= 7168 (dsh-emacs-usage-cache-read usage)))
    (dsh-test-pass "usage-from-event parses real data.usage")))

(let* ((usage (dsh-emacs-usage-from-event
               '(("type" . "assistant/message")
                 ("data" . (("message" . (("content" . "no usage here"))))))))
       (all-zero (and (= 0 (dsh-emacs-usage-input usage))
                      (= 0 (dsh-emacs-usage-output usage)))))
  (when all-zero
    (dsh-test-pass "usage-from-event no-usage yields zero")))

;; --- Test 5c: mode-line event accumulation and rendering ---
(let (txt)
  (setq dsh-emacs--modeline-usage nil)
  (dsh-emacs-modeline-note-event
   '(("type" . "assistant/message")
     ("data" . (("usage" . (("inputTokens" . 100) ("outputTokens" . 20)))))))
  (dsh-emacs-modeline-note-event
   '(("type" . "assistant/message")
     ("data" . (("usage" . (("inputTokens" . 200)
                            ("outputTokens" . 40)
                            ("cacheReadTokens" . 3500)))))))
  ;; Non-message events must not touch the accumulator.
  (dsh-emacs-modeline-note-event
   '(("type" . "user/message") ("data" . (("content" . "hi")))))
  (when (and dsh-emacs--modeline-usage
             (= 300 (dsh-emacs-usage-input dsh-emacs--modeline-usage))
             (= 60 (dsh-emacs-usage-output dsh-emacs--modeline-usage))
             (= 3500 (dsh-emacs-usage-cache-read dsh-emacs--modeline-usage)))
    (dsh-test-pass "modeline-note-event accumulates assistant/message usage"))
  (let ((dsh-emacs-modeline-format-spec '(:separator " " :segments (tokens))))
    (setq txt (dsh-emacs-modeline-format))
    (when (and (string-match "↑300" txt) (string-match "↓60" txt)
               (string-match "CH92%" txt))
      (dsh-test-pass "modeline-format renders accumulated tokens"))))

;; --- Test 5d: request/context feeds model (window arrives via
;; session/projection frames) ---
(let ((rc '(("type" . "request/context")
            ("seq" . 42)
            ("data" . (("provider" . "qwen-token-plan")
                       ("model" . "deepseek-v4-flash-0731")
                       ("contextWindow" . 1000000)))))
      (before (or (bound-and-true-p dsh-emacs--modeline-model) "none")))
  (dsh-emacs-modeline-note-request rc)
  (when (and (equal "deepseek-v4-flash-0731" dsh-emacs--modeline-model)
             (equal "qwen-token-plan" dsh-emacs--modeline-provider))
    (dsh-test-pass "note-request feeds model")))
(let ((rc '(("type" . "request/context") ("seq" . 43) ("data" . (("model" . "m9"))))))
  ;; When provider is missing, the previous provider must not linger (cross-provider
  ;; disambiguation of the same id relies on it)
  (setq dsh-emacs--modeline-provider "stale")
  (dsh-emacs-modeline-note-request rc)
  (when (equal "stale" dsh-emacs--modeline-provider)
    (dsh-test-pass "note-request keeps provider when event omits it"))
  (setq dsh-emacs--modeline-provider nil))

;; --- Test 5e: three independent model/effort/preset segments +
;; modeinline parens ---
(let ((dsh-emacs-modeline-format-spec '(:separator " " :segments (model effort preset)))
      (txt (progn
             (setq dsh-emacs--modeline-model "m1"
                   dsh-emacs--modeline-effort "max"
                   dsh-emacs--modeline-preset "standard")
             (dsh-emacs-modeline-format))))
  (when (and (string-match "m1" txt)
             (string-match "max" txt)
             (string-match "standard" txt)
             (not (string-match "m1-standard" txt)))
    (dsh-test-pass "model effort preset render as separate segments")))

;; --- Test 5f: the permission segment draws the dsh-web shield icons ---
;; `icon' style (default) prefers the SVG shield, then the Nerd Font shield
;; glyph, then a short token — never an emoji (`char-width' 1 and the
;; segment's face color are the reasons).  A batch run has no graphical
;; frame and no `nerd-icons', so it pins the text fallback.
(let ((txt (with-temp-buffer
             (dsh-emacs-mode)
             (let ((dsh-emacs-modeline-format-spec
                    '(:separator " " :segments (preset permission))))
               (setq-local dsh-emacs--modeline-preset "standard"
                           dsh-emacs--modeline-permission "workspace-write")
               (dsh-emacs-modeline-format)))))
  (dsh-test-assert "permission-segment-renders-beside-preset"
    (string-match-p "standard" txt)
    ;; icon style without SVG display or nerd-icons -> the short token
    (string-match-p " ws" txt)
    (not (string-match-p "standard-ws" txt))))
(let ((txt (with-temp-buffer
             (dsh-emacs-mode)
             (let ((dsh-emacs-modeline-format-spec
                    '(:separator " " :segments (permission)))
                   (dsh-emacs-modeline-permission-style 'text))
               (setq-local dsh-emacs--modeline-permission "danger-full-access")
               (dsh-emacs-modeline-format)))))
  (dsh-test-assert "permission-segment-text-style-shows-preset-name"
    (string-match-p "danger-full-access" txt)))
(let ((txt (with-temp-buffer
             (dsh-emacs-mode)
             (let ((dsh-emacs-modeline-format-spec
                    '(:separator " " :segments (permission))))
               (setq-local dsh-emacs--modeline-permission nil)
               (dsh-emacs-modeline-format)))))
  (dsh-test-assert "permission-segment-hidden-when-unset"
    (string-empty-p txt)))

;; The inline stats string is cached on its inputs: a permission change (the
;; projection frame path, which does NOT call the setter's cache reset here)
;; must re-render instead of freezing the previous shield/token.
(with-temp-buffer
  (dsh-emacs-mode)
  (let ((dsh-emacs-modeline-format-spec '(:separator " " :segments (permission))))
    (setq-local dsh-emacs--modeline-permission "workspace-write")
    (let ((first (dsh-emacs-modeline--modeinline)))
      (setq-local dsh-emacs--modeline-permission "danger-full-access")
      (dsh-test-assert "permission-change-invalidates-modeinline-cache"
        (string-match-p "ws" first)
        (let ((second (dsh-emacs-modeline--modeinline)))
          (string-match-p "full" second)
          (not (equal first second)))))))

(dsh-test-assert "permission-svg-covers-the-design-set"
  (= 3 (length dsh-emacs--permission-icon-svgs))
  (equal '("read-only" "workspace-write" "danger-full-access")
         (mapcar #'car dsh-emacs--permission-icon-svgs)))
(let ((svg (dsh-emacs-modeline--permission-svg "workspace-write" "#123456")))
  (dsh-test-assert "permission-svg-tints-and-leaves-no-placeholder"
    (stringp svg)
    (string-prefix-p "<svg" svg)
    (string-match-p "#123456" svg)
    (not (string-match-p "__C__" svg))
    (not (string-match-p "currentColor" svg))))
(dsh-test-assert "permission-svg-only-for-the-design-set"
  (null (dsh-emacs-modeline--permission-svg "auto" "#123456"))
  (null (dsh-emacs-modeline--permission-svg "custom" "#123456"))
  (null (dsh-emacs-modeline--permission-svg "host-preset" "#123456")))

(let ((selected nil))
  (cl-letf (((symbol-function 'nerd-icons-mdicon)
             (lambda (name &rest args)
               (setq selected (list name args))
               "<glyph>")))
    (dsh-test-assert "permission-nerd-icon-uses-the-matching-shield"
      (equal "<glyph>"
             (dsh-emacs-modeline--permission-nerd-icon
              "danger-full-access" 'dsh-emacs-modeline-permission-warn-face))
      (equal '("nf-md-shield_alert"
               (:face dsh-emacs-modeline-permission-warn-face))
             selected))
    ;; No shield name outside the design set: the caller shows text instead.
    (dsh-test-assert "permission-nerd-icon-none-for-unknown-values"
      (null (dsh-emacs-modeline--permission-nerd-icon "auto" 'default))
      (null (dsh-emacs-modeline--permission-nerd-icon "custom" 'default)))))

(dsh-test-assert "permission-short-fallback-bounded"
  (equal "ws" (dsh-emacs-modeline--permission-short "workspace-write"))
  (equal "full" (dsh-emacs-modeline--permission-short "danger-full-access"))
  (equal "custom" (dsh-emacs-modeline--permission-short "custom"))
  (<= (string-width (dsh-emacs-modeline--permission-short "verylonghostname")) 8)
  (not (equal "verylonghostname"
              (dsh-emacs-modeline--permission-short "verylonghostname"))))

(dsh-test-assert "permission-face-warns-only-when-unrestricted"
  (eq 'dsh-emacs-modeline-permission-face
      (dsh-emacs-modeline--permission-face "workspace-write"))
  (eq 'dsh-emacs-modeline-permission-face
      (dsh-emacs-modeline--permission-face "read-only"))
  (eq 'dsh-emacs-modeline-permission-face
      (dsh-emacs-modeline--permission-face "auto"))
  (eq 'dsh-emacs-modeline-permission-warn-face
      (dsh-emacs-modeline--permission-face "danger-full-access"))
  (eq 'dsh-emacs-modeline-permission-warn-face
      (dsh-emacs-modeline--permission-face "custom")))

(let ((dsh-emacs-modeline-permission-style 'text))
  ;; The style must be bound before the display call: a sibling `let' init
  ;; runs in the outer environment.
  (let ((s (dsh-emacs-modeline--permission-display "workspace-write")))
    (dsh-test-assert "permission-display-text-style-faces-the-value"
      (equal "workspace-write" s)
      (eq 'dsh-emacs-modeline-permission-face (get-text-property 0 'face s)))))
(let ((dsh-emacs-modeline-permission-style 'icon))
  (let ((s (dsh-emacs-modeline--permission-display "custom")))
    (dsh-test-assert "permission-display-icon-style-falls-back-to-warn-text"
      (equal "custom" s)
      (eq 'dsh-emacs-modeline-permission-warn-face (get-text-property 0 'face s)))))
;; modeinline rendering requires the current buffer to be in dsh-emacs-mode, and
;; all modeline state is buffer-local — it must be setq-local'd in the same buffer
;; before rendering, otherwise the value is never available (this test previously
;; never fired and silently vanished).
(let ((txt (with-temp-buffer
             (dsh-emacs-mode)
             (let ((dsh-emacs-modeline-format-spec
                    '(:separator " " :segments (model tokens ctx))))
               (setq-local dsh-emacs--modeline-usage nil)
               (dsh-emacs-modeline-note-event
                '(("type" . "assistant/message")
                  ("data" . (("usage" . (("inputTokens" . 100)
                                          ("outputTokens" . 20)))))))
               (dsh-emacs-modeline-note-event
                '(("type" . "assistant/message")
                  ("data" . (("usage" . (("inputTokens" . 200)
                                          ("outputTokens" . 40)
                                          ("cacheReadTokens" . 3500)))))))
               (setq-local dsh-emacs--modeline-model "m1"
                           dsh-emacs--modeline-preset "standard")
               (dsh-emacs-modeline-set-effort nil)
               (dsh-emacs-modeline--modeinline)))))
  (dsh-test-assert "modeinline wraps stats in parens and escapes percent"
    (string-prefix-p "(" txt)
    (string-match-p ") *$" txt)
    (string-match "CH92%%" txt)))

(with-temp-buffer
  (setq major-mode 'dsh-emacs-mode)
  (let ((dsh-emacs-modeline-format-spec
         (list :separator " " :segments '(model ctx)))
        (model (copy-sequence "model-A"))
        (calls 0)
        (render (symbol-function 'dsh-emacs-modeline--render-segment)))
    (setq dsh-emacs--modeline-model model)
    (cl-letf (((symbol-function 'dsh-emacs-modeline--render-segment)
               (lambda (sym) (cl-incf calls) (funcall render sym))))
      (dotimes (_ 100) (dsh-emacs-modeline--modeinline)))
    (dsh-test-assert "modeline-unchanged-stats-render-once" (= calls 2))
    (aset model 6 ?B)
    (dsh-test-assert "modeline-cache-sees-mutated-model"
      (string-match-p "model-B" (dsh-emacs-modeline--modeinline)))
    (dsh-emacs-modeline-set-context-snapshot 2500 10000)
    (dsh-test-assert "modeline-cache-sees-context-update"
      (string-match-p "25.0%%" (dsh-emacs-modeline--modeinline)))
    (setcar (plist-get dsh-emacs-modeline-format-spec :segments) 'effort)
    (setq dsh-emacs--modeline-effort "high")
    (dsh-test-assert "modeline-cache-sees-mutated-format-spec"
      (string-match-p "high" (dsh-emacs-modeline--modeinline))
      (not (string-match-p "model-B" (dsh-emacs-modeline--modeinline))))
    (let ((dsh-emacs-modeline-enabled nil))
      (dsh-test-assert "modeline-cache-honors-disabled"
        (equal "" (dsh-emacs-modeline--modeinline))))))

;; --- Test 5e+1: mode-line segments carry help-echo tooltips, empty values
;; pass through ---
(let ((dsh-emacs-modeline-format-spec '(:separator " " :segments (model effort preset ctx))))
  (setq dsh-emacs--modeline-model "m1"
        dsh-emacs--modeline-effort "max"
        dsh-emacs--modeline-preset "standard"
        dsh-emacs--modeline-context-pressure 1234
        dsh-emacs--modeline-context-window-server 10000)
  (let* ((txt (dsh-emacs-modeline-format))
         (model-pos (string-match "m1" txt))
         (ctx-pos (string-match "12\\.3%" txt))
         (model-tip (and model-pos (get-text-property model-pos 'help-echo txt)))
         (effort-tip (and (string-match "max" txt)
                          (get-text-property (match-beginning 0) 'help-echo txt)))
         (ctx-tip (and ctx-pos (get-text-property ctx-pos 'help-echo txt))))
    (when (and (string-match-p "Model: m1" model-tip)
               (string-match-p "Reasoning effort: max" effort-tip)
               (string-match-p "1\\.2k" ctx-tip)
               (string-match-p "10k" ctx-tip)
               (eq 'mode-line-highlight
                   (get-text-property model-pos 'mouse-face txt)))
      (dsh-test-pass "modeline-segments-carry-help-echo")))
  (setq dsh-emacs--modeline-context-pressure nil
        dsh-emacs--modeline-context-window-server nil))
(let ((nil-tip (dsh-emacs-modeline--annotate nil "x"))
      (empty-tip (dsh-emacs-modeline--annotate "" "x")))
  (when (and (null nil-tip) (equal "" empty-tip))
    (dsh-test-pass "annotate-passes-nil-and-empty-through")))

;; --- Test 5f: request/header feeds model and reasoningEffort (rc.1 event
;; shape) ---
(let ((hdr '(("type" . "request/header")
             ("seq" . 11)
             ("data" . (("header" . (("config" . (("provider" . "opencode-go")
                                                  ("model" . "deepseek-v4-flash")
                                                  ("reasoningEffort" . "high"))))))))))
  (setq dsh-emacs--modeline-model nil
        dsh-emacs--modeline-effort nil)
  (dsh-emacs-modeline-note-header hdr)
  (when (and (equal "deepseek-v4-flash" dsh-emacs--modeline-model)
             (equal "high" dsh-emacs--modeline-effort)
             (equal "opencode-go" dsh-emacs--modeline-provider))
    (dsh-test-pass "note-header feeds model and reasoning effort"))
  (setq dsh-emacs--modeline-model nil
        dsh-emacs--modeline-effort nil))

;; --- Test 5f+0: the model segment falls back to the default model for an empty
;; session (no request/projection feed) ---
;; For a freshly created session with no request events yet, the mode-line's
;; per-buffer model is nil; the model segment must fall back to
;; `dsh-emacs-default-model' rather than stay empty.
(let ((old-default dsh-emacs-default-model))
  (unwind-protect
      (let ((txt (with-temp-buffer
                   (dsh-emacs-mode)
                   (let ((dsh-emacs-modeline-format-spec
                          '(:separator " " :segments (model))))
                     (setq dsh-emacs-default-model "fallback-model-7")
                     (setq-local dsh-emacs--modeline-model nil)
                     (dsh-emacs-modeline-format)))))
        (dsh-test-assert "blank-session-model-falls-back-to-default"
          (string-match-p "fallback-model-7" txt)))
    (setq dsh-emacs-default-model old-default)))

;; --- Test 5f+1: opening a session syncs the authoritative model from the cache
;; row's modelSelection projection ---
;; The default model is only a segment-level fallback: syncing must overwrite the
;; buffer-local value with the `lastUsed' triple (the projection arrives with
;; session/list rows and follow/control projection frames, with no extra RPC).
(let* ((old-sessions dsh-emacs--sessions)
       (buf (get-buffer-create " *t5f1-chat*"))
       (calls nil)
       (item (dsh-protocol-session--from-alist
              '((sessionId . "sess-modelsync")
                (projections . ((values
                                 . ((modelSelection
                                     . ((lastUsed
                                         . ((provider . "zhipu")
                                            (model . "glm-5.3-flash")
                                            (reasoningEffort . "max")))))))))))))
  (unwind-protect
      (progn
        (setq dsh-emacs--sessions (list item))
        (with-current-buffer buf
          (setq-local dsh-emacs--buffer-session "sess-modelsync")
          (setq dsh-emacs--modeline-model "stale-model"
                dsh-emacs--modeline-effort "stale-effort"
                dsh-emacs--modeline-provider "stale-provider"))
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (&rest _) (push t calls))))
          (dsh-emacs--chat-buffer-model-sync "sess-modelsync" buf))
        (with-current-buffer buf
          (when (and (equal "glm-5.3-flash" dsh-emacs--modeline-model)
                     (equal "max" dsh-emacs--modeline-effort)
                     (equal "zhipu" dsh-emacs--modeline-provider)
                     (null calls))
            (dsh-test-pass
             "chat-buffer-model-sync-lands-provider-model-effort"))))
    (setq dsh-emacs--sessions old-sessions)
    (when (buffer-live-p buf) (kill-buffer buf))))
(let* ((old-sessions dsh-emacs--sessions)
       (buf (get-buffer-create " *t5f2-chat*"))
       (item (dsh-protocol-session--from-alist
              '((sessionId . "sess-modelsync")
                (projections . ((values
                                 . ((modelSelection
                                     . ((lastUsed
                                         . ((provider . "p9") (model . "m9")))))))))))))
  ;; Session mismatch (the sync target row belongs to another session) must not land
  ;; in this buffer (prevents cross-talk)
  (unwind-protect
      (progn
        (setq dsh-emacs--sessions (list item))
        (with-current-buffer buf
          (setq-local dsh-emacs--buffer-session "sess-other")
          (setq dsh-emacs--modeline-model nil
                dsh-emacs--modeline-provider nil))
        (dsh-emacs--chat-buffer-model-sync "sess-modelsync" buf)
        (with-current-buffer buf
          (when (and (null dsh-emacs--modeline-model)
                     (null dsh-emacs--modeline-provider))
            (dsh-test-pass
             "chat-buffer-model-sync-ignores-foreign-session"))))
    (setq dsh-emacs--sessions old-sessions)
    (when (buffer-live-p buf) (kill-buffer buf))))
;; --- Regression: the mode-line preset segment reads the session's agentPreset
;; projection ---
;; dsh 0.1.2 moved agentPreset from a top-level session-row field to a
;; projection (projections.values.agentPreset).  The protocol used to read only
;; the top-level field, so a real server row yielded no preset and the preset
;; segment never appeared; it must now be read from the projection (keeping the
;; top-level field as the optimistic session/create fallback).
(let* ((old-sessions dsh-emacs--sessions)
       (buf (get-buffer-create " *t5f3-chat*"))
       (item (dsh-protocol-session--from-alist
              '((sessionId . "sess-presetproj")
                (projections . ((values . ((agentPreset . "code")))))))))
  (unwind-protect
      (progn
        (setq dsh-emacs--sessions (list item))
        (with-current-buffer buf
          (setq-local dsh-emacs--buffer-session "sess-presetproj")
          (setq dsh-emacs--modeline-preset nil)
          (dsh-emacs--link-session-preset "sess-presetproj")
          (when (equal "code" dsh-emacs--modeline-preset)
            (dsh-test-pass "link-session-preset-reads-agentpreset-projection"))))
    (setq dsh-emacs--sessions old-sessions)
    (when (buffer-live-p buf) (kill-buffer buf))))
;; Protocol layer: both sources (the projection and the optimistic top-level
;; cache row) parse into agent-preset.
(let ((proj (dsh-protocol-session--from-alist
             '((sessionId . "s1")
               (projections . ((values . ((agentPreset . "minimal"))))))))
      (top (dsh-protocol-session--from-alist
            '((sessionId . "s2") (agentPreset . "standard")))))
  (when (and (equal "minimal" (dsh-protocol-session-agent-preset proj))
             (equal "standard" (dsh-protocol-session-agent-preset top)))
    (dsh-test-pass "session-agent-preset-projection-and-top-level")))
;; --- Test: a cache refresh syncs the agentPreset projection into the mode-line
;; preset (the same cadence as model) ---
;; `dsh-emacs--chat-buffers-sync-all' now re-feeds the preset segment on a
;; session.list refresh through the same per-buffer sync as model/ctx, so an
;; already-open session no longer captures its preset only once at open.
(let* ((old-sessions dsh-emacs--sessions)
       (buf (get-buffer-create " *t5f4-chat*"))
       (item (dsh-protocol-session--from-alist
              '((sessionId . "sess-presetsync")
                (projections . ((values . ((agentPreset . "code")))))))))
  (unwind-protect
      (progn
        (setq dsh-emacs--sessions (list item))
        (with-current-buffer buf
          (setq-local dsh-emacs--buffer-session "sess-presetsync")
          (setq dsh-emacs--modeline-preset nil))
        (dsh-emacs--chat-buffer-preset-sync "sess-presetsync" buf)
        (with-current-buffer buf
          (when (equal "code" dsh-emacs--modeline-preset)
            (dsh-test-pass "chat-buffer-preset-sync-lands-from-projection"))))
    (setq dsh-emacs--sessions old-sessions)
    (when (buffer-live-p buf) (kill-buffer buf))))
;; The synced session does not match this buffer's session -> the preset must
;; not land in it (guard against cross-session leakage).
(let* ((old-sessions dsh-emacs--sessions)
       (buf (get-buffer-create " *t5f5-chat*"))
       (item (dsh-protocol-session--from-alist
              '((sessionId . "sess-presetsync")
                (projections . ((values . ((agentPreset . "code")))))))))
  (unwind-protect
      (progn
        (setq dsh-emacs--sessions (list item))
        (with-current-buffer buf
          (setq-local dsh-emacs--buffer-session "sess-other")
          (setq dsh-emacs--modeline-preset nil))
        (dsh-emacs--chat-buffer-preset-sync "sess-presetsync" buf)
        (with-current-buffer buf
          (when (null dsh-emacs--modeline-preset)
            (dsh-test-pass "chat-buffer-preset-sync-ignores-foreign-session"))))
    (setq dsh-emacs--sessions old-sessions)
    (when (buffer-live-p buf) (kill-buffer buf))))
;; The tooltip carries provider (the model segment disambiguates the same id
;; across providers)
(let ((dsh-emacs-modeline-format-spec '(:separator " " :segments (model))))
  (setq dsh-emacs--modeline-model "m1"
        dsh-emacs--modeline-provider "zhipu")
  (let* ((txt (dsh-emacs-modeline-format))
         (tip (get-text-property 0 'help-echo txt)))
    (when (and (string-match-p "Model: m1 (provider zhipu)" tip)
               (string-match-p "switch with C-c C-m" tip))
      (dsh-test-pass "model-tooltip-carries-provider")))
  (setq dsh-emacs--modeline-provider nil))

;; --- Test 5f+2: provider as its own segment (segment order: provider before
;; model) ---
(let ((dsh-emacs-modeline-format-spec '(:separator " " :segments (provider model))))
  (setq dsh-emacs--modeline-provider "zhipu"
        dsh-emacs--modeline-model "glm-5.3-flash")
  (let* ((txt (dsh-emacs-modeline-format))
         (ppos (string-match "zhipu" txt))
         (tip (and ppos (get-text-property ppos 'help-echo txt))))
    (when (and ppos
               (string-match-p "glm-5.3-flash" txt)
               (< ppos (string-match "glm-5.3-flash" txt))
               (string-match-p "Provider: zhipu" tip)
               (eq 'mode-line-highlight (get-text-property ppos 'mouse-face txt)))
      (dsh-test-pass "provider-segment-renders-before-model")))
  (setq dsh-emacs--modeline-provider nil
        dsh-emacs--modeline-model "m1"))
;; Unknown provider → the segment disappears entirely (there is no
;; default-provider guess to fall back on)
(let ((dsh-emacs-modeline-format-spec '(:separator " " :segments (provider model))))
  (setq dsh-emacs--modeline-provider nil)
  (let ((txt (dsh-emacs-modeline-format)))
    (when (and (string-match-p "m1" txt)
               (not (string-match-p "zhipu" txt)))
      (dsh-test-pass "provider-segment-hidden-when-unknown"))))
;; The default spec has no provider segment (hidden by default; shown only when
;; opted in, while provider still disambiguates through the model segment's
;; tooltip)
(let ((segs (plist-get (default-value 'dsh-emacs-modeline-format-spec)
                       :segments)))
  (when (and (not (memq 'provider segs))
             (memq 'model segs))
    (dsh-test-pass "default-format-spec-excludes-provider")))
;; The fallback segment table used when the spec lacks :segments also omits
;; provider (it stays hidden even when provider is set)
(let ((dsh-emacs-modeline-format-spec '(:separator " ")))
  (setq dsh-emacs--modeline-provider "zhipu"
        dsh-emacs--modeline-model "m1")
  (let ((txt (dsh-emacs-modeline-format)))
    (when (and (string-match-p "m1" txt)
               (not (string-match-p "zhipu" txt)))
      (dsh-test-pass "fallback-segments-exclude-provider")))
  (setq dsh-emacs--modeline-provider nil))

;; --- Test 5g: render dispatch forwards request/header to the mode-line feed ---
(let ((fired 0))
  (cl-letf (((symbol-function 'dsh-emacs-modeline-note-header)
             (lambda (_event) (setq fired (1+ fired)))))
    (dsh-emacs-render-event '(("type" . "request/header") ("seq" . 5)))
    (dsh-emacs-render-event '(("type" . "request/context") ("seq" . 6))))
  (when (= 1 fired)
    (dsh-test-pass "render-dispatches-request-header-to-mode-line")))

;; --- Test 5m: session/projection frames update mode-line ctx% in real time
;; (push model) ---
;; Aligned with dsh web's session-projection push: the host pushes contextPressure
;; frames ({projectedTokens, pressureTokens, contextWindow}) along the event
;; stream, and the client routes them to the chat buffer by session and lands them
;; straight in the mode-line. Semantics: projected ?? pressure.
(let* ((buf (get-buffer-create " *t5m-chat*"))
       (seen nil))
  (unwind-protect
      (progn
        (with-current-buffer buf
          (setq-local dsh-emacs--buffer-session "sess-proj"))
        (puthash "sess-proj" buf dsh-emacs--chat-buffers)
        (with-current-buffer buf
          (setq-local dsh-emacs--modeline-context-pressure nil
                     dsh-emacs--modeline-context-window-server nil))
        ;; Real frame payload → routed by session to the chat buffer's mode-line
        ;; (the projection frame handler reads key/value/sessionId from the payload)
        (dsh-emacs--events-apply-context-projection
         "sess-proj"
         '((projectedTokens . 354257)
           (pressureTokens . 350000)
           (contextWindow . 1000000)))
        (let ((p (buffer-local-value 'dsh-emacs--modeline-context-pressure buf))
              (w (buffer-local-value 'dsh-emacs--modeline-context-window-server buf)))
          (when (and (= 354257 p) (= 1000000 w))
            (dsh-test-pass "session-projection-frame-updates-ctx-mode-line"))
          (setq seen (list p w)))
        ;; Falls back to pressureTokens when projectedTokens is absent
        (dsh-emacs--events-apply-context-projection
         "sess-proj"
         '((pressureTokens . 13067) (contextWindow . 1000000)))
        (let ((p (buffer-local-value 'dsh-emacs--modeline-context-pressure buf)))
          (when (= 13067 p)
            (dsh-test-pass "session-projection-falls-back-to-pressure")))
        ;; Dispatch level: the full frame reaches the handler through --dispatch-json
        ;; (host-stream gate)
        (with-current-buffer buf
          (setq-local dsh-emacs--modeline-context-pressure nil
                     dsh-emacs--modeline-context-window-server nil))
        (let ((host-props (list (cons 'dsh-emacs-host-stream t))))
          (cl-letf (((symbol-function 'processp)
                     (lambda (_p) t))
                    ((symbol-function 'process-get)
                     (lambda (_p prop)
                       (cdr (assq prop host-props)))))
            (dsh-emacs-events--dispatch-json
             'host-proc
             (concat "{\"type\":\"item\",\"streamId\":\"c1\","
                     "\"value\":{\"type\":\"projection\","
                     "\"sessionId\":\"sess-proj\","
                     "\"key\":\"contextPressure\",\"seq\":50,"
                     "\"value\":{\"projectedTokens\":88345,"
                     "\"pressureTokens\":88000,"
                     "\"contextWindow\":1000000}}}"))))
        (let ((p (buffer-local-value 'dsh-emacs--modeline-context-pressure buf)))
          (when (= 88345 p)
            (dsh-test-pass "session-projection-frame-dispatch"))))
    (remhash "sess-proj" dsh-emacs--chat-buffers)
    (when (buffer-live-p buf) (kill-buffer buf))))

;; --- Test 5i: the session struct parses the contextPressure projection
;; (pressure+window as a pair) ---
(let* ((session (dsh-protocol-session--from-alist
                 (list (cons 'sessionId "ctx-1")
                       (cons 'projections
                             (list (cons 'values
                                         (list (cons 'contextPressure
                                                     (list (cons 'pressureTokens 129946)
                                                           (cons 'projectedTokens 130028)
                                                           (cons 'contextWindow 262144)))))))))))
  (when (and (= 129946 (dsh-protocol-session-context-pressure session))
             (= 262144 (dsh-protocol-session-context-window session)))
    (dsh-test-pass "session-struct-parses-context-pressure")))

;; --- Test 5j: the ctx segment prefers the server snapshot (pressure/window
;; divided as a pair from one snapshot) ---
;; Simulates a real session: pressure 129.9k / window 262k ≈ 49.6%; the old formula
;; counted cumulative cacheRead (millions) as 100% full red — the server snapshot
;; path must give 49.6%.
(let ((dsh-emacs-modeline-format-spec '(:separator " " :segments (ctx))))
  (setq dsh-emacs--modeline-context-pressure 129946
        dsh-emacs--modeline-context-window-server 262144
        dsh-emacs--modeline-usage (dsh-emacs-make-usage 295045 90220 7020928 0))
  (let ((txt (dsh-emacs-modeline-format)))
    (when (and (string-match "49.6%" txt)
               (not (string-match "100.0%" txt)))
      (dsh-test-pass "ctx-segment-uses-server-snapshot")))
  (setq dsh-emacs--modeline-context-pressure nil
        dsh-emacs--modeline-context-window-server nil
        dsh-emacs--modeline-usage nil))

;; --- Test 5l: the ctx segment is hidden when there is no server snapshot
;; (cumulative usage no longer doubles as ctx% ---
(let ((dsh-emacs-modeline-format-spec '(:separator " " :segments (ctx))))
  ;; With only cumulative usage and no server pressure snapshot → the ctx segment
  ;; must not render. Cumulative cacheRead is the session total (several times the
  ;; window); treating it as "occupied" computes 100% full red — ctx% trusts only
  ;; the server's pressureTokens.
  (setq dsh-emacs--modeline-context-pressure nil
        dsh-emacs--modeline-context-window-server nil
        dsh-emacs--modeline-usage (dsh-emacs-make-usage 1000 500 8000000 0))
  (let ((txt (dsh-emacs-modeline-format)))
    (when (string-empty-p txt)
      (dsh-test-pass "ctx-hidden-without-server-snapshot")))
  (setq dsh-emacs--modeline-usage nil))

;; --- Test 6: face definitions ---
(when (facep 'dsh-emacs-user-face)
  (dsh-test-pass "user-face exists"))

(when (facep 'dsh-emacs-assistant-face)
  (dsh-test-pass "assistant-face exists"))

(when (facep 'dsh-emacs-tool-pending-face)
  (dsh-test-pass "tool-pending-face exists"))

(when (facep 'dsh-emacs-tool-success-face)
  (dsh-test-pass "tool-success-face exists"))

(when (facep 'dsh-emacs-tool-error-face)
  (dsh-test-pass "tool-error-face exists"))

(when (facep 'dsh-emacs-modeline-face)
  (dsh-test-pass "mode-line-face exists"))

(when (facep 'dsh-emacs-session-title-face)
  (dsh-test-pass "session-title-face exists"))

;; --- Test 7: UI rendering ---
(with-temp-buffer
  (let ((frag (dsh-emacs-ui-make-fragment
               :namespace-id "test"
               :block-id "1"
               :label-left "👤 You"
               :label-right "12:00"
               :body "hello"
               :style 'rounded)))
    (when (and frag
               (string= "test" (map-elt frag :namespace-id))
               (string= "1" (map-elt frag :block-id)))
      (dsh-test-pass "ui-make-fragment"))))

;; --- Test 8: minimal label line separator · ---
(with-temp-buffer
  (let ((dsh-emacs-ui-label-separator "·"))
    (dsh-emacs-ui-update-fragment
     (dsh-emacs-ui-make-fragment
      :namespace-id "sep" :block-id "1"
      :label-left "✶ Think" :label-right "preview"
      :body "body line" :style 'minimal)
     :create-new t :expanded t)
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      ;; Body lines in the minimal style carry no "│ " prefix (that is decoration for
      ;; the full/other styles), and the separator "·" appears between label-left and
      ;; label-right.
      (dsh-test-assert "minimal-label-separator-dot"
        (string-match-p "✶ Think · preview" text)
        (string-match-p "body line" text)))))

(with-temp-buffer
  (let ((dsh-emacs-ui-label-separator ""))
    (dsh-emacs-ui-update-fragment
     (dsh-emacs-ui-make-fragment
      :namespace-id "sep2" :block-id "1"
      :label-left "✶ Think" :label-right "preview"
      :body "body line" :style 'minimal)
     :create-new t :expanded t)
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      (when (and (string-match-p "✶ Think  preview" text)
                 (not (string-match-p "·" text)))
        (dsh-test-pass "minimal-label-separator-disabled")))))

;; Fragment updates are complete snapshots; adjacent blocks stay intact.
(dolist (style '(minimal rounded sharp))
  (with-temp-buffer
    (dsh-emacs-ui-update-fragment
     (dsh-emacs-ui-make-fragment
      :namespace-id "snapshot" :block-id "a" :style style
      :label-left "Original" :label-right "Summary" :body "old body")
     :expanded t)
    (dsh-emacs-ui-update-fragment
     (dsh-emacs-ui-make-fragment
      :namespace-id "snapshot" :block-id "b" :style style
      :label-left "Neighbor" :body "untouched")
     :expanded t)
    (let* ((neighbor (dsh-emacs-ui-find-block "snapshot" "b"))
           (neighbor-text (buffer-substring (car neighbor) (cdr neighbor))))
      (dolist (body '("longer\nreplacement\nbody" "short" nil))
        (condition-case err
            (progn
              (dsh-emacs-ui-update-fragment
               (dsh-emacs-ui-make-fragment
                :namespace-id "snapshot" :block-id "a" :style style
                :body body))
              (let* ((block (dsh-emacs-ui-find-block "snapshot" "a"))
                     (state (get-text-property (car block) 'dsh-emacs-ui-state))
                     (next (dsh-emacs-ui-find-block "snapshot" "b")))
                (dsh-test-assert (format "fragment-snapshot-%s-%S" style body)
                  (equal (map-elt state :body) body)
                  (not (string-match-p "Original\\|Summary"
                                       (buffer-substring (car block) (cdr block))))
                  (= (cdr block) (car next))
                  (equal-including-properties
                   neighbor-text (buffer-substring (car next) (cdr next))))))
          (error (dsh-test-fail (format "fragment-snapshot-%s-%S" style body)
                                (error-message-string err))))))))

;; Nil clears flags/faces; ranges and the input marker survive replacements.
(with-temp-buffer
  (insert "Prompt: draft")
  (let ((input (copy-marker (point-min) t))
        (model (dsh-emacs-ui-make-fragment
                :namespace-id "flags" :block-id "a" :style 'minimal
                :label-left "Title" :label-right "Summary" :body "body"
                :non-foldable t :body-face 'bold :header-face 'italic)))
    (goto-char (point-max))
    (dsh-emacs-ui-update-fragment model :insert-before input)
    (goto-char (point-min))
    (dsh-emacs-ui-toggle-fragment)
    (dsh-test-assert "fragment-non-foldable-stays-visible"
      (not (map-elt (get-text-property (point-min) 'dsh-emacs-ui-state)
                    :collapsed))
      (string-match-p "body" (buffer-string)))
    (setq model (dsh-emacs-ui-make-fragment
                 :namespace-id "flags" :block-id "a" :style 'sharp
                 :label-left "New title" :body "replacement"))
    (goto-char (point-max))
    (let* ((range (dsh-emacs-ui-update-fragment model :insert-before input))
           (state (get-text-property (car range) 'dsh-emacs-ui-state)))
      (dsh-test-assert "fragment-clears-flags-style-and-faces"
        (eq (map-elt state :style) 'sharp)
        (not (map-elt state :non-foldable))
        (not (map-elt state :body-face))
        (not (map-elt state :header-face))
        (not (string-match-p "Summary" (buffer-string)))
        (= (cdr range) input)
        (= (point) (point-max))
        (equal (buffer-substring-no-properties input (point-max)) "Prompt: draft")
        (not (get-text-property input 'dsh-emacs-ui-state)))
      (goto-char (car range))
      (search-forward "replacement")
      (dsh-test-assert "fragment-old-face-removed-from-text"
        (not (get-text-property (1- (point)) 'face)))
      (goto-char (car range))
      (dsh-emacs-ui-toggle-fragment)
      (dsh-test-assert "fragment-cleared-non-foldable-can-collapse"
        (not (string-match-p "replacement" (buffer-string))))
      (dsh-emacs-ui-expand-all)
      (dsh-test-assert "fragment-expand-all-restores-snapshot"
        (string-match-p "replacement" (buffer-string)))
      (dsh-emacs-ui-collapse-all)
      (dsh-test-assert "fragment-collapse-all-hides-body"
        (not (string-match-p "replacement" (buffer-string)))))
    (set-marker input nil)))

;; Namespace and block ID are separate identity components, even with hyphens.
(with-temp-buffer
  (dsh-emacs-ui-update-fragment
   (dsh-emacs-ui-make-fragment
    :namespace-id "a-b" :block-id "c" :style 'minimal
    :label-left "First" :body "one") :expanded t)
  (dsh-emacs-ui-update-fragment
   (dsh-emacs-ui-make-fragment
    :namespace-id "a" :block-id "b-c" :style 'minimal
    :label-left "Second" :body "two") :expanded t)
  (dsh-test-assert "fragment-hyphenated-identities-do-not-collide"
    (equal (buffer-substring-no-properties (point-min) (point-max))
           "First\none\nSecond\ntwo\n"))
  (dsh-emacs-ui-update-fragment
   (dsh-emacs-ui-make-fragment
    :namespace-id "a-b" :block-id "c" :style 'minimal
    :label-left "Changed" :body "three"))
  (dsh-test-assert "fragment-update-isolated-by-both-identity-components"
    (equal (buffer-substring-no-properties (point-min) (point-max))
           "Changed\nthree\nSecond\ntwo\n")))

(with-temp-buffer
  (dsh-emacs-ui-update-fragment
   (dsh-emacs-ui-make-fragment
    :namespace-id "a-b" :block-id "c" :style 'minimal :label-left "First"))
  (dsh-emacs-ui-update-fragment
   (dsh-emacs-ui-make-fragment
    :namespace-id "a" :block-id "b-c" :style 'minimal :label-left "Second"))
  (dsh-test-assert "fragment-pair-lookup-selects-distinct-blocks"
    (= (car (dsh-emacs-ui-find-block "a-b" "c")) (point-min))
    (> (car (dsh-emacs-ui-find-block "a" "b-c")) (point-min)))
  (dsh-emacs-ui-delete-fragment "a-b" "c")
  (dsh-test-assert "fragment-pair-delete-keeps-other-identity"
    (not (dsh-emacs-ui-find-block "a-b" "c"))
    (equal (buffer-substring-no-properties (point-min) (point-max)) "Second\n")))

;; Local navigation and bulk folding must not scan by identity for every card.
(with-temp-buffer
  (dolist (name '("First" "Second" "Fixed"))
    (dsh-emacs-ui-update-fragment
     (dsh-emacs-ui-make-fragment
      :namespace-id "local" :block-id name :style 'minimal :label-left name
      :body (concat name " body") :non-foldable (equal name "Fixed"))
     :create-new t :expanded t))
  (let ((lookups 0)
        (find-block (symbol-function 'dsh-emacs-ui-find-block)))
    (cl-letf (((symbol-function 'dsh-emacs-ui-find-block)
               (lambda (&rest args)
                 (setq lookups (1+ lookups))
                 (apply find-block args))))
      (goto-char (point-min))
      (dsh-emacs-ui-forward-block)
      (dsh-test-assert "fragment-forward-reaches-adjacent-block"
        (looking-at-p "Second\n"))
      (dsh-emacs-ui-backward-block)
      (dsh-test-assert "fragment-backward-reaches-adjacent-block"
        (= (point) (point-min)))
      (dsh-emacs-ui-collapse-all)
      (dsh-test-assert "fragment-collapse-all-keeps-non-foldable"
        (equal (buffer-substring-no-properties (point-min) (point-max))
               "First\nSecond\nFixed\nFixed body\n"))
      (dsh-emacs-ui-expand-all)
      (dsh-test-assert "fragment-expand-all-restores-all-local-bodies"
        (equal (buffer-substring-no-properties (point-min) (point-max))
               "First\nFirst body\nSecond\nSecond body\nFixed\nFixed body\n")))
    (dsh-test-assert "fragment-local-actions-avoid-global-identity-scans"
      (= lookups 0))))

;; Header layout gives the title priority and measures geometry once.
(dolist (style '(minimal rounded sharp))
  (with-temp-buffer
    (let ((calls 0))
      (cl-letf (((symbol-function 'dsh-emacs-ui--box-width)
                 (lambda () (setq calls (1+ calls)) 20)))
        (dsh-emacs-ui-update-fragment
         (dsh-emacs-ui-make-fragment
          :namespace-id "layout" :block-id "a" :style style
          :label-left "Build result" :label-right (make-string 60 ?x)
          :body "body")
         :expanded t))
      (goto-char (point-min))
      (let ((header (buffer-substring-no-properties (point) (line-end-position))))
        (dsh-test-assert (format "fragment-title-priority-%s" style)
                         (string-match-p "Build result" header)
                         (<= (string-width header) (if (eq style 'minimal) 20 24))
                         (= calls 1)))
      (unless (eq style 'minimal)
        (let ((widths (mapcar #'string-width
                              (split-string (buffer-string) "\n" t))))
          (dsh-test-assert (format "fragment-border-widths-agree-%s" style)
                           (equal widths '(24 24 24))))))))

(with-temp-buffer
  (let ((window (selected-window)))
    (cl-letf (((symbol-function 'get-buffer-window) (lambda (&rest _) window))
              ((symbol-function 'window-text-width)
               (lambda (target)
                 (dsh-test-assert "fragment-measures-displaying-window"
                                  (eq target window))
                 12)))
      (dsh-test-assert "fragment-narrow-window-has-no-40-column-floor"
                       (= (dsh-emacs-ui--box-width) 8)))))

(dolist (width '(1 4 12))
  (dolist (style '(minimal rounded sharp))
    (with-temp-buffer
      (cl-letf (((symbol-function 'dsh-emacs-ui--box-width) (lambda () width)))
        (dsh-emacs-ui-update-fragment
         (dsh-emacs-ui-make-fragment
          :namespace-id "narrow" :block-id "a" :style style
          :label-left "A very long title" :label-right "summary"
          :body "hidden body")))
      (dsh-test-assert (format "fragment-narrow-header-and-placeholder-%s-%s"
                               style width)
                       (cl-every (lambda (line)
                                   (<= (string-width line)
                                       (+ width (if (eq style 'minimal) 0 4))))
                                 (split-string (buffer-string) "\n" t))))))

;; Embedded link/button keymaps take precedence over the fold default.
(with-temp-buffer
  (dsh-emacs-ui-mode 1)
  (let* ((map (make-sparse-keymap))
         (label (concat "Title "
                        (propertize "Open" 'keymap map 'help-echo "open details")))
         (model (dsh-emacs-ui-make-fragment
                 :namespace-id "actions" :block-id "a" :style 'minimal
                 :label-left label :body "body")))
    (define-key map (kbd "RET") #'ignore)
    (dsh-emacs-ui-update-fragment model)
    (dotimes (_ 2)
      (goto-char (point-min))
      (search-forward "Open")
      (dsh-test-assert "fragment-custom-header-action-preserved"
                       (eq (get-text-property (1- (point)) 'keymap) map)
                       (save-excursion
                         (backward-char)
                         (eq (key-binding (kbd "RET")) #'ignore))
                       (equal (get-text-property (1- (point)) 'help-echo) "open details")
                       (eq (get-text-property (point-min) 'keymap) dsh-emacs-ui-fragment-map))
      (goto-char (point-min))
      (dsh-emacs-ui-toggle-fragment))))

;; Rendering and insertion failures preserve text, properties and input markers.
(dolist (fault '(render insert))
  (dolist (operation '(update fold create))
    (with-temp-buffer
      (let ((model (dsh-emacs-ui-make-fragment
                    :namespace-id "failure" :block-id "a" :style 'minimal
                    :label-left "Original" :body "old body")))
        (dsh-emacs-ui-update-fragment model :expanded t)
        (let ((inhibit-read-only t)) (goto-char (point-max)) (insert "Prompt: draft"))
        (let ((before (buffer-substring (point-min) (point-max)))
              (anchor (copy-marker (- (point-max) 13) t))
              (original-end (point-max))
              (insert-function (symbol-function 'insert))
              (face-function (symbol-function 'add-face-text-property))
              caught)
          (goto-char (point-max))
          (condition-case err
              (cl-letf (((symbol-function 'add-face-text-property)
                         (lambda (&rest args)
                           (if (eq fault 'render)
                               (error "injected failure")
                             (apply face-function args))))
                        ((symbol-function 'insert)
                         (lambda (&rest args)
                           (apply insert-function args)
                           (when (eq fault 'insert)
                             (error "injected failure")))))
                (pcase operation
                  ('fold (goto-char (point-min)) (dsh-emacs-ui-toggle-fragment))
                  (_ (dsh-emacs-ui-update-fragment
                      (dsh-emacs-ui-make-fragment
                       :namespace-id "failure"
                       :block-id (if (eq operation 'create) "b" "a")
                       :style 'minimal :label-left "Replacement" :body "new body"
                       :body-face 'bold)
                      :insert-before anchor))))
            (error (setq caught (equal (error-message-string err)
                                       "injected failure"))))
          (dsh-test-assert (format "fragment-failed-%s-%s-rolls-back" operation fault)
                           caught
                           (= (point-max) original-end)
                           (equal-including-properties before (buffer-string))
                           (equal (buffer-substring-no-properties anchor (point-max)) "Prompt: draft"))
          (set-marker anchor nil))))))

;; --- Test 9: event renderer functions exist ---
(when (fboundp 'dsh-emacs-render-event)
  (dsh-test-pass "render-event function exists"))

(when (fboundp 'dsh-emacs-render-history-events)
  (dsh-test-pass "render-history-events function exists"))

(when (fboundp 'dsh-emacs-render-user-message)
  (dsh-test-pass "render-user-message function exists"))

(when (fboundp 'dsh-emacs-render-assistant-message)
  (dsh-test-pass "render-assistant-message function exists"))

(when (fboundp 'dsh-emacs-render-tool-call)
  (dsh-test-pass "render-tool-call function exists"))

(when (fboundp 'dsh-emacs-render-tool-result)
  (dsh-test-pass "render-tool-result function exists"))

;; --- Test 9: Mode-line functions exist ---
(when (fboundp 'dsh-emacs-modeline-format)
  (dsh-test-pass "mode-line-format function exists"))

(when (fboundp 'dsh-emacs-modeline-setup)
  (dsh-test-pass "mode-line-setup function exists"))

(when (fboundp 'dsh-emacs-modeline-update)
  (dsh-test-pass "mode-line-update function exists"))

(when (fboundp 'dsh-emacs-modeline-set-usage)
  (dsh-test-pass "mode-line-set-usage function exists"))

;; --- Test 10: session list functions exist ---
(when (fboundp 'dsh-emacs-session--render)
  (dsh-test-pass "session--render function exists"))

(when (fboundp 'dsh-emacs-session--shorten-cwd)
  (dsh-test-pass "session--shorten-cwd function exists"))

(when (fboundp 'dsh-emacs-open-session-at-point)
  (dsh-test-pass "open-session-at-point function exists"))

;; --- Test 11: Markdown functions exist ---
(when (fboundp 'dsh-emacs-markdown-render)
  (dsh-test-pass "markdown-render function exists"))

(let ((rendered (dsh-emacs-markdown-render "# title\n**bold** `code`")))
  (when (and (string= rendered "title\nbold code\n")
             (eq (get-text-property 0 'face rendered)
                 'dsh-emacs-markdown-header-1)
             (eq (get-text-property 6 'face rendered)
                 'dsh-emacs-markdown-bold)
             (eq (get-text-property 11 'face rendered)
                 'dsh-emacs-markdown-inline-code))
    (dsh-test-pass "markdown-render-applies-faces")))

(let ((rendered (dsh-emacs-markdown-render
                 "__bold__ _italic_ ~~gone~~ **_both_**")))
  (let ((both-face (get-text-property 17 'face rendered)))
    (when (and (string= rendered "bold italic gone both\n")
               (eq (get-text-property 0 'face rendered)
                   'dsh-emacs-markdown-bold)
               (eq (get-text-property 5 'face rendered)
                   'dsh-emacs-markdown-italic)
               (eq (get-text-property 12 'face rendered)
                   'dsh-emacs-markdown-strikethrough)
               (listp both-face)
               (memq 'dsh-emacs-markdown-bold both-face)
               (memq 'dsh-emacs-markdown-italic both-face))
      (dsh-test-pass "markdown-nested-and-alternate-markup"))))

(let ((rendered (dsh-emacs-markdown-render
                 "| Name | Value |\n| --- | ---: |\n| **foo** | `bar` |")))
  (when (and (string-match-p "│ Name │ Value │" rendered)
             (string-match-p "├" rendered)
             (string-match-p "foo" rendered)
             (not (string-match-p "\\*\\*" rendered))
             (not (string-match-p "`" rendered)))
    (dsh-test-pass "markdown-table-render")))

;; --- Test 12: main entry functions ---
(when (fboundp 'dsh-emacs)
  (dsh-test-pass "dsh-emacs main function exists"))

(when (fboundp 'dsh-emacs-new-session)
  (dsh-test-pass "dsh-emacs-new-session function exists"))

(when (fboundp 'dsh-emacs-open-session)
  (dsh-test-pass "dsh-emacs-open-session function exists"))

(when (fboundp 'dsh-emacs-health)
  (dsh-test-pass "dsh-emacs-health function exists"))

;; --- Test 13: RPC functions ---
(when (fboundp 'dsh-emacs--rpc-request)
  (dsh-test-pass "rpc-request function exists"))

(when (fboundp 'dsh-emacs--rpc-async)
  (dsh-test-pass "rpc-async function exists"))

;; --- Test 14: RPC JSON booleans and empty payload ---
(let ((request (dsh-emacs--wrap-request "session/list" nil)))
  (when (string-match-p "\"payload\":{\"args\":{}}" request)
    (dsh-test-pass "rpc-empty-payload-is-object")))

;; --- Test 14b: session/list carries the _request argument (real 0.1.2
;; descriptor) ---
;; In 0.1.2-rc.1 the sole argument of `session/list' is named `_request' (an empty
;; list request object), not `request' as in the other session methods. Sending
;; `{}' is rejected by the server (`missing "_request"'); args must carry the
;; `_request' key with value `{}'.
(let* ((args (dsh-emacs--session-list-args))
       (wrap (dsh-emacs--wrap-request "session/list" args)))
  (dsh-test-assert "session-list-args-carries-_request"
    (and (= 1 (length args))
         (eq '_request (car (car args)))))
  (dsh-test-assert "session-list-wrap-encodes-_request-object"
    (string-match-p "\"args\":{\"_request\":{}}" wrap)))

(let* ((response (json-read-from-string
                  "{\"result\":{\"ok\":false,\"error\":{\"code\":\"bad-request\"}}}"))
       (unwrapped (dsh-emacs--unwrap-response response)))
  (when (and (not (car unwrapped))
             (equal (cdr (assq 'code (cdr unwrapped))) "bad-request"))
    (dsh-test-pass "rpc-false-result-is-error")))

;; --- Test 15: JSON arrays and working directory ---
(when (and (equal '(a b) (dsh-emacs--sequence-list [a b]))
           (equal "assistant/message"
                  (dsh-emacs-render--aget "type"
                                           '((type . "assistant/message")))))
  (dsh-test-pass "json-array-and-symbol-keys-supported"))

(let ((dsh-emacs-default-cwd "~/"))
  (when (file-name-absolute-p (dsh-emacs--absolute-cwd nil))
    (dsh-test-pass "session-cwd-is-absolute")))

(when (stringp (dsh-emacs-session--compact-time (* (float-time) 1000)))
  (dsh-test-pass "session-time-formats-milliseconds"))

;; --- Test: session list time column alignment — padded by display width (CJK
;; takes 2 columns) ---
(let* ((ascii (dsh-emacs-session--pad-right "hello" 45))
       (cjk (dsh-emacs-session--pad-right "自动摘要名称" 45))
       (trunc (dsh-emacs-session--pad-right
               (make-string 60 ?x) 45)))
  (when (and (= 45 (string-width ascii))
             (= 45 (string-width cjk))
             (= 45 (string-width trunc))
             (not (equal ascii cjk)))
    (dsh-test-pass "session-pad-right-aligns-wide-characters")))

(when (and (stringp (dsh-emacs--client-time-zone))
           (not (string-empty-p (dsh-emacs--client-time-zone)))
           (dsh-emacs--valid-iana-time-zone-p
            (dsh-emacs--client-time-zone)))
  (dsh-test-pass "client-time-zone-is-iana"))

(let ((process-environment (copy-sequence process-environment)))
  (setenv "TZ" "CST")
  (when (dsh-emacs--valid-iana-time-zone-p
         (dsh-emacs--client-time-zone))
    (dsh-test-pass "ambiguous-time-zone-is-replaced")))

;; --- Test 16: buffer modes ---
(with-temp-buffer
  (dsh-emacs-mode)
  (when (eq major-mode 'dsh-emacs-mode)
    (dsh-test-pass "dsh-emacs-mode activates"))
  (when (local-variable-p 'dsh-emacs--input-marker)
    (dsh-test-pass "input-marker variable exists"))
  (when dsh-emacs--input-marker
    (dsh-test-pass "input-marker marker created")))

;; --- Test 17: input area is writable ---
(with-temp-buffer
  (dsh-emacs-mode)
  ;; New sessions install the structural end-of-buffer overlay after the input area.  Inserting at the
  ;; marker must still work even though the prompt itself is read-only.
  (dsh-emacs-modeline-setup)
  (goto-char dsh-emacs--input-marker)
  (condition-case err
      (progn
        (insert "test input")
        (if (and (string= (buffer-substring-no-properties
                           dsh-emacs--input-marker (point-max))
                          "test input\n")
                 (string= (dsh-emacs--get-input) "test input"))
            (dsh-test-pass "input-area-writable")
          (dsh-test-fail "input-area-writable"
                         "text was not inserted into the input area")))
    (error
     (dsh-test-fail "input-area-writable" (error-message-string err)))))

;; --- Test 17b: the input area does not inherit the prompt's accent face ---
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (let* ((pos (marker-position dsh-emacs--input-marker))
         (prompt-face (get-text-property (1- pos) 'face)))
    ;; Precondition: the ❯ prompt itself carries the accent face.
    (when prompt-face
      (dsh-test-pass "input-prompt-carries-face"))
    ;; Typing runs `insert-and-inherit' (Emacs 31 `self-insert-command'),
    ;; which copies the previous character's face.  The prompt's
    ;; `rear-nonsticky' list must exclude `face', otherwise manual input
    ;; turns blue while pasted/completed text stays default colored.
    (goto-char pos)
    (insert-and-inherit "t")
    (let ((typed-face (get-text-property pos 'face)))
      (if (null typed-face)
          (dsh-test-pass "input-rejects-prompt-face-inheritance")
        (dsh-test-fail "input-rejects-prompt-face-inheritance"
                       (format "typed text inherited prompt face %S"
                               typed-face))))))

;; --- Test 18: UTF-8 response decoding ---
(with-temp-buffer
  (set-buffer-multibyte nil)
  (insert (encode-coding-string "你好 😊" 'utf-8))
  (goto-char (point-min))
  (dsh-emacs--decode-response-body)
  (when (string= (buffer-string) "你好 😊")
    (dsh-test-pass "rpc-response-decodes-utf8")))

;; --- Test 19: assistant replies remain in history order ---
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (let ((first (json-read-from-string
                "{\"event\":{\"type\":\"assistant/message\",\"seq\":1,\"data\":{\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"reply-1\"}]}}}}"))
        (second (json-read-from-string
                 "{\"event\":{\"type\":\"assistant/message\",\"seq\":2,\"data\":{\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"reply-2\"}]}}}}")))
    (dsh-emacs-render-history-events (list first second))
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      (when (and (< (string-match "reply-1" text)
                    (string-match "reply-2" text))
                 (string-match "reply-1\n" text)
                 (string-match "reply-2\n" text))
        (dsh-test-pass "assistant-replies-keep-order")))))

;; --- Test 20: chat prefix and rendered Markdown ---
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (let ((user (json-read-from-string
               "{\"type\":\"user/message\",\"seq\":1,\"data\":{\"content\":[{\"type\":\"text\",\"text\":\"hello\"}]}}"))
        (assistant (json-read-from-string
                    "{\"type\":\"assistant/message\",\"seq\":2,\"data\":{\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"# title\\n**bold**\"}]}}}")))
    (dsh-emacs-render-event user)
    (dsh-emacs-render-event assistant)
    (let* ((text (buffer-substring (point-min) (point-max)))
           (title-pos (string-match "title" text))
           (bold-pos (string-match "bold" text))
           (title-face (and title-pos (get-text-property (1+ title-pos) 'face text)))
           (bold-face (and bold-pos (get-text-property (1+ bold-pos) 'face text))))
      (when (and (string-match "❯ hello" text)
                 (member 'dsh-emacs-markdown-header-1
                         (if (listp title-face) title-face (list title-face)))
                 (member 'dsh-emacs-markdown-bold
                         (if (listp bold-face) bold-face (list bold-face))))
        (dsh-test-pass "chat-prefix-and-markdown-render")))))

;; Streaming tables stay raw until their boundary; open fences only scan
;; newly arrived lines.  Finalization must still produce the complete body.
(with-temp-buffer
  (let* ((event '((data . ((turn . 1) (step . 1)))))
         (header "| A | B |\n|---|---|\n")
         (row "| alpha | beta |\n")
         (renders 0)
         (render (symbol-function 'dsh-emacs-markdown--render-table)))
    (cl-letf (((symbol-function 'dsh-emacs-markdown--render-table)
               (lambda (table) (cl-incf renders) (funcall render table))))
      (dsh-emacs-render--start-assistant-stream event header)
      (dotimes (_ 40)
        (dsh-emacs-render--start-assistant-stream event row)
        (dsh-emacs-render--flush-stream))
      (dsh-test-assert "stream-table-defers-reflow"
        (= renders 0)
        (string-match-p "| alpha | beta |" (buffer-string)))
      ;; The last timer has already fired: finalization still needs to render.
      (dsh-emacs-render--finish-assistant-stream
       event (concat header (apply #'concat (make-list 40 row))))
      (dsh-test-assert "stream-table-finalizes-once-without-pending-timer"
        (= renders 1)
        (string-match-p "alpha" (buffer-string))
        (text-property-not-all (point-min) (point-max)
                               'dsh-emacs-markdown-table-source nil)))))

(with-temp-buffer
  (let* ((event '((data . ((turn . 1) (step . 1)))))
         (header "```elisp\n")
         (row "(message \"**literal**\")\n")
         (scanned 0)
         (parses 0)
         (scan (symbol-function 'dsh-emacs-markdown--source-block-ranges)))
    ;; Opening the fence is the one call that renders: it writes the card
    ;; chrome before any body line exists, so the card is already on screen.
    (dsh-emacs-render--start-assistant-stream event header)
    (dsh-emacs-render--flush-stream)
    (dsh-test-assert "stream-open-fence-renders-card-at-opening-line"
      (not (string-match-p "```" (buffer-string)))
      (string-match-p "elisp ⧉" (buffer-string)))
    (cl-letf (((symbol-function 'dsh-emacs-markdown--source-block-ranges)
               (lambda ()
                 (cl-incf parses)
                 (cl-incf scanned (- (point-max) (point-min)))
                 (funcall scan))))
      (dotimes (_ 80)
        (dsh-emacs-render--start-assistant-stream event row)
        (dsh-emacs-render--flush-stream)))
    (dsh-test-assert "stream-open-fence-avoids-repeated-full-scans"
      (= scanned 0)
      (string-match-p (regexp-quote row) (buffer-string)))
    (dsh-test-assert "stream-open-fence-skips-empty-markdown-passes"
      (= parses 0))
    (dsh-emacs-render--start-assistant-stream event "```\n")
    (dsh-emacs-render--flush-stream)
    (dsh-test-assert "stream-closed-fence-renders-with-literal-body"
      (not (string-match-p "```" (buffer-string)))
      (string-match-p (regexp-quote "**literal**") (buffer-string))
      (text-property-not-all (point-min) (point-max)
                             'dsh-emacs-markdown-source-block-body nil))
    (dsh-emacs-render--finish-assistant-stream
     event (concat header (apply #'concat (make-list 80 row)) "```\n"))))

;; Regression: closing a text block must yield to pending keyboard input.
(with-temp-buffer
  (dsh-emacs-mode)
  (let* ((dsh-emacs-stream-markdown-limit 8)
         (event '((data . ((turn . 1) (step . 1)))))
         (state (dsh-emacs-render--start-assistant-stream event "**before**\n"))
         (runner (symbol-function 'dsh-emacs-render--run-markdown))
         (attempts 0)
         completed)
    (let ((unread-command-events '(?x)))
      ;; Bound a broken retry loop so the regression fails instead of hanging.
      (catch 'stalled
        (cl-letf (((symbol-function 'dsh-emacs-render--run-markdown)
                   (lambda (&rest args)
                     (if (> (cl-incf attempts) 2)
                         (throw 'stalled nil)
                       (apply runner args)))))
          (dsh-emacs-render--start-thinking-stream event "thinking"))
        (setq completed t))
      (dsh-test-assert "stream-block-close-yields-to-input"
        completed (equal unread-command-events '(?x))))
    (when completed
      (dsh-test-assert "stream-closed-block-keeps-deferred-work"
        (memq state dsh-emacs--markdown-pending))
      (dsh-emacs-render--run-markdown (current-buffer))
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (dsh-test-assert "stream-closed-block-formats-before-thinking"
          (string-match-p "before\n.*Think\nthinking" text)
          (not (string-match-p (regexp-quote "**before**") text)))))
    (dsh-emacs-render--cancel-markdown)))

;; A corrected final body cancels old deferred work and keeps nearby thinking.
(dolist (finish-early '(nil t))
  (with-temp-buffer
    (dsh-emacs-mode)
    (let* ((dsh-emacs-stream-markdown-limit 8)
           (dsh-emacs-thinking-expand-by-default t)
           (event '((data . ((turn . 1) (step . 1)))))
           (old (dsh-emacs-render--start-assistant-stream event "**wrong**\n")))
      (dsh-emacs-render--start-thinking-stream event "keep thinking")
      (when finish-early (dsh-emacs-render--run-markdown (current-buffer)))
      (dsh-emacs-render--start-assistant-stream event "old tail")
      (dsh-emacs-render--finish-assistant-stream event "**correct**\n")
      (dsh-test-assert "stream-repair-cancels-committed-job"
        (not (memq old dsh-emacs--markdown-pending)))
      (dsh-emacs-render--run-markdown (current-buffer))
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (dsh-test-assert "stream-repair-keeps-thinking-without-old-text"
          (string-match-p "correct" text)
          (string-match-p "keep thinking" text)
          (not (string-match-p "wrong\\|old tail\\|\\*\\*" text)))))))

;; Regression: Markdown after a streamed closing fence must still render.
(dolist (final '(nil t))
  (with-temp-buffer
    (dsh-emacs-mode)
    (let* ((event '((data . ((turn . 1) (step . 1)))))
           (first "```text\nx\n")
           (tail "```\n**BOLD**\n\n# TITLE\n\n```text\ny\n```\n")
           (source (concat first tail))
           (expected (dsh-emacs-markdown-render source))
           (state (dsh-emacs-render--start-assistant-stream event first))
           (start (copy-marker (plist-get state :start))))
      (dsh-emacs-render--flush-stream)
      (dsh-emacs-render--start-assistant-stream event tail)
      (unless final (dsh-emacs-render--flush-stream))
      (dsh-emacs-render--finish-assistant-stream event source)
      (dsh-test-assert "stream-fence-tail-matches-complete-markdown"
        (equal (substring-no-properties expected)
               (buffer-substring-no-properties
                start (+ start (length expected)))))
      (goto-char start)
      (search-forward "BOLD")
      (dsh-test-assert "stream-fence-tail-retains-bold-face"
        (memq 'dsh-emacs-markdown-bold
              (get-text-property (1- (point)) 'face))))))

;; A streamed code block is append-only: once its card chrome is written at
;; the opening fence, every later flush adds text at the tail and nothing the
;; user has already seen is rewritten (no line break is ever inserted into
;; shown text).  The renderer's trailing separator sits after the stream body,
;; so the body region is what must stay stable.
(defun dsh-test--stream-body-text ()
  (let ((end (plist-get dsh-emacs--streaming-assistant :end)))
    (buffer-substring-no-properties
     (point-min) (if (markerp end) (marker-position end) (point-max)))))

(with-temp-buffer
  (let* ((event '((data . ((turn . 1) (step . 1)))))
         (row "(message \"hi\")\n")
         previous)
    (dsh-emacs-render--start-assistant-stream event "Before.\n\n```elisp\n")
    (dsh-emacs-render--flush-stream)
    (dsh-emacs-render--start-assistant-stream event row)
    (dsh-emacs-render--flush-stream)
    (setq previous (dsh-test--stream-body-text))
    (dotimes (_ 20)
      (dsh-emacs-render--start-assistant-stream event row)
      (dsh-emacs-render--flush-stream)
      (let ((now (dsh-test--stream-body-text)))
        (dsh-test-assert "stream-open-fence-body-appends-without-rewriting"
          (string-prefix-p previous now))
        (setq previous now)))
    (dsh-emacs-render--start-assistant-stream event "```\nAfter.\n")
    (dsh-emacs-render--flush-stream)
    ;; Closing consumes the fence line and appends the panel's bottom line;
    ;; everything above the fence line is untouched.
    (dsh-test-assert "stream-close-appends-below-the-body"
      (string-prefix-p previous (dsh-test--stream-body-text)))))

;; A block whose chrome is written by the deferred (idle) render must hand its
;; open state to the live stream: otherwise the next pass re-reads the body as
;; markdown (`*x*' loses its asterisks) and leaves the closing fence raw.
(with-temp-buffer
  (dsh-emacs-mode)
  (let* ((dsh-emacs-stream-markdown-limit 8)
         (event '((data . ((turn . 1) (step . 1)))))
         (text "intro\n```text\n*x*\n| a | b |\n```\n")
         (expected (with-temp-buffer
                     (insert text)
                     (dsh-emacs-markdown-replace-markup
                      :base-face 'dsh-emacs-assistant-body-face)
                     (buffer-substring-no-properties (point-min) (point-max))))
         (state (dsh-emacs-render--start-assistant-stream
                 event "intro\n```text\n*x*\n"))
         body-start)
    (dsh-emacs-render--run-markdown (current-buffer))
    (dsh-test-assert "stream-deferred-open-fence-hands-over-the-block"
      (plist-get (plist-get state :markdown) :open-block))
    (dsh-emacs-render--start-assistant-stream event "| a | b |\n```\n")
    (dsh-emacs-render--flush-stream)
    (setq body-start (copy-marker (plist-get state :start)))
    (dsh-emacs-render--finish-assistant-stream event text)
    (while dsh-emacs--markdown-pending
      (dsh-emacs-render--run-markdown (current-buffer)))
    (dsh-test-assert "stream-deferred-open-fence-keeps-the-body-raw"
      (equal expected
             (buffer-substring-no-properties
              body-start (+ body-start (length expected)))))))

;; A repaired final body re-renders from scratch: `--reset-markdown-state' has
;; to drop the block it was streaming, or the queued final pass is skipped and
;; the body keeps its raw fences.
(with-temp-buffer
  (dsh-emacs-mode)
  (let* ((dsh-emacs-stream-markdown-limit 100)
         (event '((data . ((turn . 1) (step . 1)))))
         (final (concat "```text\n" (make-string 300 ?a) "\n```\n"))
         (state (dsh-emacs-render--start-assistant-stream event "```text\n"))
         body-start)
    (setq body-start (copy-marker (plist-get state :start)))
    (dsh-emacs-render--finish-assistant-stream event final)
    (while dsh-emacs--markdown-pending
      (dsh-emacs-render--run-markdown (current-buffer)))
    (dsh-test-assert "stream-forced-final-repair-formats-the-body"
      (not (string-match-p
            "```"
            (buffer-substring-no-properties body-start (point-max)))))))

;; A closer and the next opener in one flush must not leave the first block
;; looking open: both cards render, with no fence line left raw.
(with-temp-buffer
  (dsh-emacs-mode)
  (let* ((event '((data . ((turn . 1) (step . 1)))))
         (text "```a\nx\n```\n```b\ny\n```\n")
         (expected (with-temp-buffer
                     (insert text)
                     (dsh-emacs-markdown-replace-markup
                      :base-face 'dsh-emacs-assistant-body-face)
                     (buffer-substring-no-properties (point-min) (point-max))))
         (state (dsh-emacs-render--start-assistant-stream event "```a\nx\n"))
         body-start)
    (dsh-emacs-render--start-assistant-stream event "```\n```b\ny\n")
    (dsh-emacs-render--flush-stream)
    ;; The closer ends the first block and the remainder opens the next card
    ;; in the same flush: the live block must belong to b, not a.
    (dsh-test-assert "stream-closer-closes-before-the-next-opener"
      (equal "b" (plist-get (plist-get (plist-get state :markdown)
                                       :open-block)
                            :lang)))
    (dsh-emacs-render--start-assistant-stream event "```\n")
    (dsh-emacs-render--flush-stream)
    (setq body-start (copy-marker (plist-get state :start)))
    (dsh-emacs-render--finish-assistant-stream event text)
    (dsh-test-assert "stream-closer-and-next-opener-in-one-flush"
      (equal expected
             (buffer-substring-no-properties
              body-start (+ body-start (length expected)))))))

;; An open block never goes back to the idle queue: its flush only styles the
;; characters that just arrived, and deferring it would re-read code as
;; markdown in a temp buffer that cannot see the block.
(with-temp-buffer
  (dsh-emacs-mode)
  (let* ((dsh-emacs-stream-markdown-limit 8)
         (event '((data . ((turn . 1) (step . 1)))))
         (row "(message \"hi\")\n")
         (state (dsh-emacs-render--start-assistant-stream event "```text\n")))
    (dsh-emacs-render--flush-stream)
    (dotimes (_ 30)
      (dsh-emacs-render--start-assistant-stream event row)
      (dsh-emacs-render--flush-stream))
    (dsh-test-assert "stream-open-fence-never-defers"
      (plist-get (plist-get state :markdown) :open-block)
      (null (memq state dsh-emacs--markdown-pending)))
    (dsh-emacs-render--finish-assistant-stream
     event (concat "```text\n" (apply #'concat (make-list 30 row)) "```\n"))))

;; Reformatting a partial line must not accumulate the assistant base face.
(with-temp-buffer
  (dsh-emacs-mode)
  (let ((event '((data . ((turn . 1) (step . 1))))))
    (dotimes (_ 20)
      (dsh-emacs-render--start-assistant-stream event "**bold** text ")
      (dsh-emacs-render--flush-stream))
    (let* ((start (plist-get dsh-emacs--streaming-assistant :start))
           (face (get-text-property start 'face)))
      (dsh-test-assert "stream-partial-line-keeps-one-assistant-base-face"
        (equal face '(dsh-emacs-markdown-bold dsh-emacs-assistant-body-face))
        (equal (get-text-property start 'font-lock-face) face)))
    (dsh-emacs-render--flush-stream nil t)))

;; Replacement blocks must mirror the final face, including the base face.
(dolist (case '(("code" "```text\nbody\n```\n" "body")
                ("table" "| A | B |\n|---|---|\n| alpha | beta |\n" "alpha")))
  (pcase-let ((`(,kind ,text ,needle) case))
    (with-temp-buffer
      (dsh-emacs-mode)
      (dsh-emacs-render--start-assistant-stream
       '((data . ((turn . 1) (step . 1)))) text)
      (dsh-emacs-render--flush-stream nil t)
      (goto-char (point-min))
      (search-forward needle)
      (let* ((pos (- (point) (length needle)))
             (face (get-text-property pos 'face)))
        (dsh-test-assert (format "stream-%s-mirrors-complete-base-face" kind)
          (= (cl-count 'dsh-emacs-assistant-body-face
                       (if (listp face) face (list face))) 1)
          (equal face (get-text-property pos 'font-lock-face)))))))

;; Long partial lines stay visible without reparsing every subsequent delta.
(with-temp-buffer
  (dsh-emacs-mode)
  (let ((dsh-emacs-stream-markdown-limit 256)
        (event '((data . ((turn . 1) (step . 1)))))
        (formatter (symbol-function 'dsh-emacs-markdown-replace-markup))
        (scanned 0))
    (cl-letf (((symbol-function 'dsh-emacs-markdown-replace-markup)
               (lambda (&rest args)
                 (cl-incf scanned (- (point-max) (point-min)))
                 (apply formatter args))))
      (dotimes (_ 100)
        (dsh-emacs-render--start-assistant-stream event "**bold** text ")
        (dsh-emacs-render--flush-stream)))
    (dsh-test-assert "stream-long-partial-line-has-bounded-immediate-work"
      (< scanned 8000)
      (string-match-p (regexp-quote "**bold** text ") (buffer-string)))
    (let ((dsh-emacs-stream-markdown-limit nil))
      (dsh-emacs-render--flush-stream nil t))
    (dsh-test-assert "stream-long-partial-line-final-styling-is-complete"
      (equal (buffer-substring-no-properties
              (plist-get dsh-emacs--streaming-assistant :start)
              (plist-get dsh-emacs--streaming-assistant :end))
             (apply #'concat (make-list 100 "bold text "))))))

;; Large final blocks stay visible, then receive complete styling at idle.
(dolist (text '("```elisp\n(message \"hello\")\n```\n"
                "| A | B |\n|---|---|\n| **alpha** | beta |\n"))
  (with-temp-buffer
    (dsh-emacs-mode)
    (let* ((dsh-emacs-stream-markdown-limit 8)
           (event '((data . ((turn . 1) (step . 1)))))
           (expected (with-temp-buffer
                       (insert text)
                       (dsh-emacs-markdown-replace-markup
                        :base-face 'dsh-emacs-assistant-body-face)
                       (buffer-string)))
           state body-start)
      (setq state (dsh-emacs-render--start-assistant-stream event text))
      (setq body-start (marker-position (plist-get state :start)))
      (dsh-emacs-render--finish-assistant-stream event text)
      (dsh-test-assert (format "stream-large-block-is-deferred-%s" (substring text 0 3))
        (memq state dsh-emacs--markdown-pending)
        (and (marker-buffer (plist-get state :start))
             (equal (buffer-substring-no-properties
                     (plist-get state :start) (plist-get state :end)) text))
        (null dsh-emacs--streaming-assistant))
      (when (fboundp 'dsh-emacs-render--run-markdown)
        (dsh-emacs-render--run-markdown (current-buffer))
        (dsh-test-assert "stream-deferred-final-matches-synchronous-formatting"
          (equal (substring-no-properties expected)
                 (buffer-substring-no-properties
                  body-start (+ body-start (length expected))))
          (cl-loop for i below (length expected)
                   always (and (equal (get-text-property i 'face expected)
                                      (get-text-property (+ body-start i) 'face))
                               (equal (get-text-property i 'font-lock-face expected)
                                      (get-text-property (+ body-start i)
                                                         'font-lock-face))))
          (null dsh-emacs--markdown-pending)
          (null dsh-emacs--markdown-timer)
          (null (marker-buffer (plist-get state :start)))
          (null (marker-buffer (plist-get state :end))))))))

;; A large final-only/history message uses the same idle formatting path.
(with-temp-buffer
  (dsh-emacs-mode)
  (let ((dsh-emacs-stream-markdown-limit 8)
        (text "```text\nfrom history\n```"))
    (dsh-emacs-render-assistant-message
     `((seq . 7)
       (data . ((turn . 1) (step . 1)
                (message . ((content . [((type . "text") (text . ,text))])))))))
    (dsh-test-assert "assistant-final-only-message-defers-large-markdown"
      (= (length dsh-emacs--markdown-pending) 1)
      (string-match-p "```text" (buffer-string)))
    (when dsh-emacs--markdown-pending
      (let* ((state (car dsh-emacs--markdown-pending))
             (start (marker-position (plist-get state :start)))
             (event-id (plist-get state :event-id))
             (expected (dsh-emacs-markdown-render text)))
        (dsh-emacs-render--run-markdown (current-buffer))
        (dsh-test-assert "assistant-final-only-idle-result-retains-event-identity"
          (equal (buffer-substring-no-properties start (+ start (length expected)))
                 (substring-no-properties expected))
          (equal (get-text-property start 'dsh-emacs-event-block) event-id)
          (null dsh-emacs--markdown-pending))))))

;; Compatibility table probes must not invalidate the queued reply's snapshot.
(dolist (version '(27 30))
  (save-window-excursion
    (with-temp-buffer
      (dsh-emacs-mode)
      (set-window-buffer (selected-window) (current-buffer))
      (let ((dsh-emacs-stream-markdown-limit 8)
            (emacs-major-version version)
            (event '((data . ((turn . 1) (step . 1)))))
            (text "| A | B |\n|---|---|\n| alpha | beta |\n")
            (measurements 0))
        (dsh-emacs-render--start-assistant-stream event text)
        (dsh-emacs-render--finish-assistant-stream event text)
        (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                  ((symbol-function 'window-text-pixel-size)
                   (lambda (_window from to &rest _)
                     (cl-incf measurements)
                     (cons (* 10 (- to from)) 16)))
                  ((symbol-function 'buffer-text-pixel-size)
                   (lambda (buffer &rest _)
                     (cl-incf measurements)
                     (cons (* 10 (buffer-size buffer)) 16))))
          (dsh-emacs-render--run-markdown (current-buffer)))
        (dsh-test-assert (format "idle-table-completes-on-emacs-%s" version)
          (> measurements 0)
          (text-property-not-all (point-min) (point-max)
                                 'dsh-emacs-markdown-table-source nil)
          (null dsh-emacs--markdown-pending)
          (null dsh-emacs--markdown-timer))))))

;; Timer attempts wait for actual idleness, without repeatedly firing at an
;; expired idle deadline or preventing the command loop from consuming input.
(with-temp-buffer
  (dsh-emacs-mode)
  (let* ((dsh-emacs-stream-markdown-limit 8)
         (state (dsh-emacs-render--start-assistant-stream
                 '((data . ((turn . 1) (step . 1))))
                 "```text\nqueued text\n```\n"))
         (before (buffer-string)))
    (cl-letf (((symbol-function 'current-idle-time) (lambda () nil)))
      (dsh-emacs-render--run-markdown (current-buffer) t))
    (dsh-test-assert "stream-markdown-timer-yields-while-the-user-is-active"
      (equal-including-properties before (buffer-string))
      (memq state dsh-emacs--markdown-pending)
      (memq dsh-emacs--markdown-timer timer-list)
      (not (memq dsh-emacs--markdown-timer timer-idle-list)))
    (cl-letf (((symbol-function 'current-idle-time) (lambda () '(0 1 0 0))))
      (dsh-emacs-render--run-markdown (current-buffer) t))
    (dsh-test-assert "stream-markdown-timer-completes-when-idle"
      (null dsh-emacs--markdown-pending)
      (string-match-p "text ⧉" (buffer-string)))))

;; Input can discard a partly prepared result without touching the transcript.
(with-temp-buffer
  (dsh-emacs-mode)
  (let* ((dsh-emacs-stream-markdown-limit 8)
         (event '((data . ((turn . 1) (step . 1)))))
         (text "```elisp\n(message \"hello\")\n```\n")
         (state (dsh-emacs-render--start-assistant-stream event text))
         (before (buffer-string))
         (tick (buffer-chars-modified-tick)))
    (dsh-emacs-render--finish-assistant-stream event text)
    (cl-letf (((symbol-function 'dsh-emacs-markdown-replace-markup)
               (lambda (&rest _)
                 (insert "unfinished preparation")
                 (throw throw-on-input t))))
      (dsh-emacs-render--run-markdown (current-buffer)))
    (dsh-test-assert "stream-interrupted-preparation-never-publishes-partial-text"
      (equal-including-properties before (buffer-string))
      (= tick (buffer-chars-modified-tick))
      (memq state dsh-emacs--markdown-pending)
      (timerp dsh-emacs--markdown-timer))
    (dsh-emacs-render--run-markdown (current-buffer))
    (dsh-test-assert "stream-interrupted-preparation-retries-to-completion"
      (null dsh-emacs--markdown-pending)
      (string-match-p "elisp ⧉" (buffer-string))
      (not (string-match-p "unfinished preparation" (buffer-string))))))

;; Regression: streamed replies protect their trailing separators as well.
(dolist (limit '(8 100000))
  (dolist (chunks '(("hello" " world\nsecond line")
                    ("```elisp\n(message" " \"hello\")\n```\n**tail**")
                    ("| A | B |\n|---|---|\n" "| alpha | beta |\n")))
    (with-temp-buffer
      (dsh-emacs-mode)
      (goto-char (dsh-emacs--input-end))
      (insert "draft")
      (let* ((dsh-emacs-stream-markdown-limit limit)
             (event '((data . ((turn . 1) (step . 1)))))
             (state (dsh-emacs-render--start-assistant-stream
                     event (car chunks)))
             (start (copy-marker (plist-get state :start)))
             (end (copy-marker (+ 2 (plist-get state :end)))))
        (dolist (phase '(first append final idle))
          (pcase phase
            ('append
             (dsh-emacs-render--start-assistant-stream event (cadr chunks))
             (dsh-emacs-render--flush-stream))
            ('final
             (dsh-emacs-render--finish-assistant-stream
              event (apply #'concat chunks)))
            ('idle
             (dsh-emacs-render--run-markdown (current-buffer))))
          (let ((before (buffer-substring-no-properties start end)))
            (dsh-test-assert "stream-body-and-separators-are-read-only"
              (null (text-property-not-all start end 'read-only t)))
            (dolist (pos (list (- end 2) (1- end)))
              (goto-char pos)
              (dsh-test-assert "stream-separator-rejects-insertion"
                (condition-case nil
                    (progn (insert "\n") nil)
                  (text-read-only t)))
              (dsh-test-assert "stream-separator-rejects-deletion"
                (condition-case nil
                    (progn (delete-char 1) nil)
                  (text-read-only t))))
            (dsh-test-assert "stream-separators-survive-edit-attempts"
              (equal before (buffer-substring-no-properties start end))
              (equal "draft" (dsh-emacs--get-input)))))
        (goto-char (dsh-emacs--input-end))
        (insert " more")
        (dsh-test-assert "stream-separator-protection-keeps-input-editable"
          (equal "draft more" (dsh-emacs--get-input)))))))

;; A corrected final reply replaces the source of queued work.
(with-temp-buffer
  (dsh-emacs-mode)
  (let* ((dsh-emacs-stream-markdown-limit 8)
         (event '((data . ((turn . 1) (step . 1)))))
         (state (dsh-emacs-render--start-assistant-stream
                 event "```text\nobsolete\n```\n")))
    (dsh-emacs-render--finish-assistant-stream
     event "```text\ncorrected\n```\n")
    (dsh-test-assert "stream-deferred-correction-is-protected-immediately"
      (get-text-property (plist-get state :start) 'read-only)
      (equal (get-text-property (plist-get state :start) 'dsh-emacs-event-block)
             (plist-get state :event-id)))
    (dsh-emacs-render--run-markdown (current-buffer))
    (dsh-test-assert "stream-deferred-correction-cannot-publish-obsolete-text"
      (string-match-p "corrected" (buffer-string))
      (not (string-match-p "obsolete" (buffer-string)))
      (null dsh-emacs--markdown-pending))))

;; Completing an earlier job keeps later replies and the draft intact.
(with-temp-buffer
  (dsh-emacs-mode)
  (let ((dsh-emacs-stream-markdown-limit 8)
        (inhibit-read-only t))
    (goto-char (point-max))
    (insert "draft")
    (dolist (step '(1 2))
      (let ((event `((data . ((turn . 1) (step . ,step)))))
            (text (format "```text\nreply %s\n```\n" step)))
        (dsh-emacs-render--start-assistant-stream event text)
        (dsh-emacs-render--finish-assistant-stream event text)))
    (let ((first (car dsh-emacs--markdown-pending)))
      (dsh-test-assert "stream-queued-reply-does-not-expand-into-the-next-message"
        (equal (buffer-substring-no-properties
                (plist-get first :start) (plist-get first :end))
               "```text\nreply 1\n```\n")))
    (dsh-emacs-render--run-markdown (current-buffer))
    (dsh-test-assert "stream-idle-callback-finishes-one-reply-at-a-time"
      (= (length dsh-emacs--markdown-pending) 1))
    (let ((second (car dsh-emacs--markdown-pending)))
      (dsh-test-assert "stream-idle-publish-preserves-the-next-job-boundaries"
        (equal (buffer-substring-no-properties
                (plist-get second :start) (plist-get second :end))
               "```text\nreply 2\n```\n")))
    (dsh-emacs-render--run-markdown (current-buffer))
    (dsh-test-assert "stream-idle-results-preserve-order-and-draft"
      (< (string-match "reply 1" (buffer-string))
         (string-match "reply 2" (buffer-string)))
      (equal (dsh-emacs--get-input) "draft")
      (null dsh-emacs--markdown-pending))))

;; A completed idle job retains the partial-line frontier for later chunks.
(with-temp-buffer
  (dsh-emacs-mode)
  (let* ((dsh-emacs-stream-markdown-limit 16)
         (event '((data . ((turn . 1) (step . 1)))))
         (first "```text\nfirst block\n```\n\nafter **part")
         (last "ial**\nlast line")
         (state (dsh-emacs-render--start-assistant-stream event first))
         (start (marker-position (plist-get state :start)))
         (expected (dsh-emacs-markdown-convert (concat first last))))
    (dsh-emacs-render--run-markdown (current-buffer))
    (dsh-emacs-render--start-assistant-stream event last)
    (dsh-emacs-render--finish-assistant-stream event (concat first last))
    (when dsh-emacs--markdown-pending
      (dsh-emacs-render--run-markdown (current-buffer)))
    (dsh-test-assert "stream-resumes-markdown-after-a-midstream-idle-result"
      (equal (substring-no-properties expected)
             (buffer-substring-no-properties start (+ start (length expected))))
      (null dsh-emacs--markdown-pending))))

;; Internal preparation errors surface, leaving the raw reply intact.
(with-temp-buffer
  (dsh-emacs-mode)
  (let* ((dsh-emacs-stream-markdown-limit 8)
         (event '((data . ((turn . 1) (step . 1)))))
         (text "```text\nraw reply\n```\n")
         (state (dsh-emacs-render--start-assistant-stream event text))
         (before (buffer-string)) reported)
    (dsh-emacs-render--finish-assistant-stream event text)
    (cl-letf (((symbol-function 'dsh-emacs-markdown-replace-markup)
               (lambda (&rest _) (error "Broken formatter")))
              ((symbol-function 'message)
               (lambda (format &rest args)
                 (setq reported (apply #'format format args)))))
      (dsh-emacs-render--run-markdown (current-buffer)))
    (dsh-test-assert "stream-idle-errors-preserve-raw-text-and-report-failure"
      (equal-including-properties before (buffer-string))
      (string-match-p "Broken formatter" reported)
      (null dsh-emacs--markdown-pending)
      (null (marker-buffer (plist-get state :start))))))

;; Publishing markup preserves positions inside unchanged code content.
(with-temp-buffer
  (dsh-emacs-mode)
  (let* ((dsh-emacs-stream-markdown-limit 8)
         (event '((data . ((turn . 1) (step . 1)))))
         (text "```text\nalpha beta gamma\n```\n")
         marker)
    (dsh-emacs-render--start-assistant-stream event text)
    (save-excursion
      (goto-char (point-min))
      (search-forward "beta")
      (setq marker (copy-marker (- (point) 4))))
    (dsh-emacs-render--finish-assistant-stream event text)
    (dsh-emacs-render--run-markdown (current-buffer))
    (dsh-test-assert "stream-idle-publish-keeps-positions-in-unchanged-code"
      (and (<= (+ marker 4) (point-max))
           (equal (buffer-substring-no-properties marker (+ marker 4)) "beta")))
    (dsh-test-assert "stream-idle-publish-does-not-poison-coding-buffers"
      (equal (decode-coding-string (unibyte-string #xE1) 'iso-8859-1) "á"))
    (set-marker marker nil)))

;; Teardown releases pending jobs and their timers instead of publishing later.
(dolist (boundary '(reset kill mode))
  (let ((buffer (generate-new-buffer " *dsh-markdown-lifecycle*"))
        state timer stream-timer caught)
    (unwind-protect
        (with-current-buffer buffer
          (dsh-emacs-mode)
          (let ((dsh-emacs-stream-markdown-limit 8))
            (setq state (dsh-emacs-render--start-assistant-stream
                         '((data . ((turn . 1) (step . 1))))
                         "```text\nqueued\n```\n")
                  timer dsh-emacs--markdown-timer)
            (dsh-emacs-render--start-assistant-stream
             '((data . ((turn . 1) (step . 1)))) "pending delta")
            (setq stream-timer (plist-get state :timer)))
          (condition-case err
              (pcase boundary
                ('reset (dsh-emacs-render--reset-tool-tracking))
                ('kill (kill-buffer buffer))
                ('mode (fundamental-mode)))
            (error (setq caught err)))
          (dsh-test-assert (format "stream-idle-work-cancels-on-%s" boundary)
            (null caught)
            (timerp stream-timer)
            (not (memq stream-timer timer-list))
            (null (plist-get state :pending))
            (timerp timer)
            (not (memq timer timer-list))
            (null (marker-buffer (plist-get state :start)))
            (null (marker-buffer (plist-get state :end)))))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (setq dsh-emacs--streaming-assistant nil))
        (kill-buffer buffer)))))

;; Pixel paths use the target frame even when it is not the selected frame.
(let* ((window (selected-window))
       (frame (window-frame window)))
  (cl-letf (((symbol-function 'display-graphic-p)
             (lambda (&optional target) (eq target frame)))
            ((symbol-function 'dsh-emacs-markdown--table-measure-string)
             (lambda (str _window)
               (cond ((equal str " ") 10)
                     ((equal str "MMMMMMMMMM")
                      (if (get-text-property 0 'face str) 200 100))
                     (t 30)))))
    (dsh-test-assert "table-pixel-paths-use-the-destination-frame"
      (= (dsh-emacs-markdown--table-display-width :str "中" :window window) 3)
      (= (dsh-emacs-markdown--table-wrap-char-width
          (propertize "a" 'face 'bold) 0 window) 2.0)
      (equal (dsh-emacs-markdown--pad-table-string
              :str "中" :width 4 :window window) "中 "))))

;; Font measurements are shared within one table, never across renders.
(save-window-excursion
  (with-temp-buffer
    (let* ((window (split-window-right))
           (source (concat "| " (propertize "AAAA" 'face 'bold)
                           " | 中文 |\n|---|---|\n| plain | 中文 |\n"))
           (default-height 16)
           (spaces 0)
           (faces 0)
           height-windows first second)
      (set-window-buffer window (current-buffer))
      (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                ((symbol-function 'dsh-emacs-markdown--table-measure-line-height)
                 (lambda (win str)
                   (push win height-windows)
                   (if (equal str "A") default-height 20)))
                ((symbol-function 'dsh-emacs-markdown--table-measure-string)
                 (lambda (str _window)
                   (when (equal str " ") (cl-incf spaces))
                   (when (and (equal str "MMMMMMMMMM")
                              (get-text-property 0 'face str))
                     (cl-incf faces))
                   (* 10 (string-width str)))))
        (setq first (dsh-emacs-markdown--render-table-source
                     :source source :window window)
              default-height 18
              second (dsh-emacs-markdown--render-table-source
                      :source source :window window)))
      (dsh-test-assert "table-metrics-use-current-render-fonts"
        (equal (get-text-property (string-match "中" first) 'display first)
               '(height 0.8))
        (equal (get-text-property (string-match "中" second) 'display second)
               '(height 0.9))
        (= spaces 2)
        (= faces 2)
        (cl-every (lambda (win) (eq win window)) height-windows)))))

;; The compatibility pixel probe must measure beyond the window's width.
(save-window-excursion
  (with-temp-buffer
    (set-window-buffer (selected-window) (current-buffer))
    (let ((emacs-major-version 27)
          measured)
      (cl-letf (((symbol-function 'window-text-pixel-size)
                 (lambda (_window _from _to &optional x-limit &rest _)
                   (setq measured x-limit)
                   (cons (if (eq x-limit t) 3500 560) 10))))
        (dsh-test-assert "table-measure-full-width-on-emacs-27"
          (= (dsh-emacs-markdown--table-measure-string
              (make-string 500 ?W) (selected-window)) 3500)
          (eq measured t))))))

;; Emacs 31 can measure in the destination's font context without editing it.
(save-window-excursion
  (with-temp-buffer
    (insert "draft")
    (let* ((source (current-buffer))
           (window (split-window-right))
           (selected (selected-window))
           (tick (buffer-modified-tick))
           (emacs-major-version 31)
           measured)
      (set-window-buffer window source)
      (cl-letf (((symbol-function 'string-pixel-width)
                 (lambda (str buffer)
                   (setq measured (list str buffer (selected-window)))
                   3500)))
        (let ((width (dsh-emacs-markdown--table-measure-string
                      (make-string 500 ?W) window)))
          (dsh-test-assert "table-measure-without-destination-edits"
            (= width 3500)
            (equal measured (list (make-string 500 ?W) source window))
            (= tick (buffer-modified-tick))
            (eq selected (selected-window))))))))

;; Pixel measurement is temporary even when the display primitive fails.
(dolist (fail '(nil t))
  (dolist (modified '(nil t))
    (save-window-excursion
      (with-temp-buffer
        (buffer-enable-undo)
        (insert (propertize "draft 草稿" 'face 'italic))
        (goto-char 3)
        (setq-local face-remapping-alist '((default (:height 1.5) default)))
        (set-buffer-modified-p modified)
        (setq buffer-undo-list nil)
        (let* ((emacs-major-version 27)
               (selected (selected-window))
               (window (split-window-right))
               (source (current-buffer))
               (tick (buffer-chars-modified-tick))
               (before (buffer-string))
               (end (copy-marker (point-max) t))
               (buffer-read-only t)
               result caught)
          (set-window-buffer window (current-buffer))
          (cl-letf (((symbol-function 'window-text-pixel-size)
                     (lambda (_window from to &rest _)
                       (unless (and (not (eq (current-buffer) source))
                                    (equal face-remapping-alist
                                           (buffer-local-value
                                            'face-remapping-alist source))
                                    (equal (buffer-substring-no-properties from to)
                                           "probe 中文"))
                         (error "Wrong measurement range"))
                       (if fail (error "Measurement failed") '(42 . 10)))))
            (condition-case err
                (setq result (dsh-emacs-markdown--table-measure-string
                              "probe 中文" window))
              (error (setq caught err))))
          (dsh-test-assert (format "table-measure-result-%s-%s" fail modified)
            (if fail (equal caught '(error "Measurement failed"))
              (and (null caught) (= result 42))))
          (dsh-test-assert (format "table-measure-restores-draft-%s-%s" fail modified)
            (equal-including-properties before (buffer-string))
            (= tick (buffer-chars-modified-tick))
            (eq (window-buffer window) source)
            (eq (selected-window) selected)
            (= (point) 3)
            (= end (1+ (length before)))
            (eq (buffer-modified-p) modified)
            (null buffer-undo-list)
            buffer-read-only)
          (set-marker end nil))))))

;; Emphasis scanning can skip the prefix preceding its first delimiter.
(with-temp-buffer
  (dsh-emacs-mode)
  (let ((event '((data . ((turn . 1) (step . 1)))))
        (prefix (concat (make-string 3000 ?a) " "))
        (bold (symbol-function 'dsh-emacs-markdown--replace-bolds))
        (scanned 0))
    (dsh-emacs-render--start-assistant-stream event prefix)
    (cl-letf (((symbol-function 'dsh-emacs-markdown--replace-bolds)
               (lambda (&rest args)
                 (cl-incf scanned (- (point-max) (point-min)))
                 (apply bold args))))
      (dotimes (_ 20)
        (dsh-emacs-render--start-assistant-stream event "**bold** text ")
        (dsh-emacs-render--flush-stream)))
    (dsh-test-assert "stream-emphasis-skips-delimiter-free-prefix"
      (< scanned 1000)
      (equal (buffer-substring-no-properties
              (plist-get dsh-emacs--streaming-assistant :start)
              (plist-get dsh-emacs--streaming-assistant :end))
             (concat prefix (apply #'concat (make-list 20 "bold text ")))))
    (dsh-emacs-render--flush-stream nil t)))
(dolist (text '("word*literal*" "word_underscore_" "word**literal**"))
  (with-temp-buffer
    (insert text)
    (dsh-emacs-markdown-replace-markup)
    (dsh-test-assert (format "emphasis-keeps-real-left-context-%s" text)
      (equal (buffer-substring-no-properties (point-min) (point-max)) text))))

;; Plain text needs no emphasis passes, and repeated formatting is write-free.
(with-temp-buffer
  (insert "plain 中文 text\nnext line")
  (let ((calls 0))
    (cl-letf (((symbol-function 'dsh-emacs-markdown--replace-bolds)
               (lambda (&rest _) (cl-incf calls) nil))
              ((symbol-function 'dsh-emacs-markdown--replace-italics)
               (lambda (&rest _) (cl-incf calls) nil))
              ((symbol-function 'dsh-emacs-markdown--replace-strikethroughs)
               (lambda (&rest _) (cl-incf calls) nil)))
      (dsh-emacs-markdown-replace-markup))
    (dsh-test-assert "markdown-plain-text-skips-emphasis-passes"
      (= calls 0)
      (equal (buffer-substring-no-properties (point-min) (point-max))
             "plain 中文 text\nnext line")))
  (let ((tick (buffer-modified-tick)))
    (dsh-emacs-markdown-replace-markup)
    (dsh-test-assert "markdown-unchanged-plain-text-does-not-write"
      (= tick (buffer-modified-tick)))))
(let ((styled (with-temp-buffer
                (insert "**bold**")
                (dsh-emacs-markdown-replace-markup)
                (buffer-string))))
  (with-temp-buffer
    (insert-for-yank styled)
    (dsh-test-assert "markdown-yank-handler-inserts-plain-text"
      (equal (buffer-string) "bold")
      (null (text-properties-at (point-min))))))

;; Chunk boundaries do not change final Markdown text or its visual faces.
(cl-loop for (tag source) in
         '(("mixed" "**before**\n| A | B |\n|---|---|\n| `a|b` | **中** |\n\nafter\n")
           ("table-tail" "| A | B |\n|---|---|\n|x|y|")
           ("fence" "```elisp\n(message \"**literal**\")\n```")
           ("nested-fence" "````text\n```\nbody\n```\n````\n")
           ("inline-and-table" "`inline`\n|a|b|\n|c|d|\n\n```text\nraw\n```\n"))
         do
         (let ((expected (with-temp-buffer
                    (insert source)
                    (dsh-emacs-markdown-replace-markup)
                    (buffer-string))))
    (dolist (size '(1 2 7 31))
      (with-temp-buffer
        (let ((state (list :scan nil :pending nil :kind nil :watermark nil))
              (pos 0))
          (while (< pos (length source))
            (goto-char (point-max))
            (insert (substring source pos (min (+ pos size) (length source))))
            (setq pos (+ pos size))
            (dsh-emacs-markdown-replace-markup :stream-state state))
          (dsh-emacs-markdown-replace-markup :stream-state state :final t)
          (let ((actual (buffer-string)))
            (dsh-test-assert (format "stream-markdown-parity-%s-%s" tag size)
              (equal (substring-no-properties actual)
                     (substring-no-properties expected))
              (cl-loop for i below (min (length actual) (length expected))
                       always (equal (get-text-property i 'face actual)
                                     (get-text-property i 'face expected)))
              (null (plist-get state :scan))
              (null (plist-get state :pending))
              (null (plist-get state :watermark)))))))))

;; Teardown finalizes deferred markup even after the formatting timer fired.
(dolist (boundary '(turn-end disconnect reset switch))
  (with-temp-buffer
    (let ((event '((data . ((turn . 1) (step . 1)))))
          (table "|a|b|\n|c|d|\n"))
      (dsh-emacs-render--start-assistant-stream event table)
      (dsh-emacs-render--flush-stream)
      (pcase boundary
        ('turn-end (dsh-emacs-render-turn-end '((data . nil))))
        ('disconnect (dsh-emacs-events-disconnect))
        ('reset (dsh-emacs-render--reset-tool-tracking))
        ('switch (dsh-emacs-render--start-assistant-stream
                  '((data . ((turn . 2) (step . 1)))) "next")))
      (dsh-test-assert (format "stream-table-finalizes-on-%s" boundary)
        (text-property-not-all (point-min) (point-max)
                               'dsh-emacs-markdown-table-source nil))
      (dsh-emacs-render--flush-stream nil t))))

;; --- Test 21: assistant streaming incremental rendering ---
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (let ((chunk-1 (json-read-from-string
                  "{\"type\":\"assistant/chunk\",\"seq\":1,\"data\":{\"turn\":1,\"step\":1,\"chunk\":{\"type\":\"text-delta\",\"index\":1,\"text\":\"hello **bold\"}}}"))
        (chunk-2 (json-read-from-string
                  "{\"type\":\"assistant/chunk\",\"seq\":2,\"data\":{\"turn\":1,\"step\":1,\"chunk\":{\"type\":\"text-delta\",\"index\":1,\"text\":\" text**\"}}}"))
        (final (json-read-from-string
                "{\"type\":\"assistant/message\",\"seq\":3,\"data\":{\"turn\":1,\"step\":1,\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"hello **bold text**\"}]}}}")))
    (dsh-emacs-render-event chunk-1)
    (let ((partial (buffer-substring-no-properties (point-min) (point-max))))
      (when (string-match-p "hello \\*\\*bold" partial)
        (dsh-test-pass "assistant-stream-keeps-incomplete-markup")))
    (dsh-emacs-render-event chunk-2)
    (dsh-emacs-render--flush-stream)
    (let* ((text (buffer-string))
           (bold-pos (string-match "bold" text))
           (face (and bold-pos (get-text-property bold-pos 'face text))))
      (when (and (not (string-match-p "\\*\\*" (substring-no-properties text)))
                 (member 'dsh-emacs-markdown-bold
                         (if (listp face) face (list face))))
        (dsh-test-pass "assistant-stream-renders-completed-markup")))
    (dsh-emacs-render-event final)
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      (when (and (null dsh-emacs--streaming-assistant)
                 (= (cl-count ?b text)
                    1))
        (dsh-test-pass "assistant-stream-final-event-does-not-duplicate")))))

(let* ((input (concat (propertize "%中" 'face 'bold)
                      (propertize "%%" 'face 'italic)))
       (expected (concat (propertize "%%中" 'face 'bold)
                         (propertize "%%%%" 'face 'italic))))
  (string-match "b" "abc")
  (let ((saved (match-data)))
    (dsh-test-assert "modeline-percent-preserves-properties-and-match-data"
      (equal-including-properties
       (dsh-emacs-modeline--escape-percent input) expected)
      (equal saved (match-data))
      (equal (dsh-emacs-modeline--escape-percent "") "")
      (equal (dsh-emacs-modeline--escape-percent "plain") "plain"))))

;; --- Test 21b: thinking / reasoning stream rendering ---
;; Regression: live Think text is read-only before its final fragment exists.
(with-temp-buffer
  (dsh-emacs-mode)
  (goto-char (dsh-emacs--input-end))
  (insert "draft")
  (let ((event '((data . ((turn . 1) (step . 1))))))
    (dolist (chunk '("first" " second" "\nthird\n"))
      (let ((state (dsh-emacs-render--start-thinking-stream event chunk)))
        (dsh-emacs-render--flush-thinking)
        (let* ((start (marker-position (plist-get state :start)))
               (end (marker-position (plist-get state :end)))
               (body (save-excursion (goto-char start)
                                    (line-beginning-position 2)))
               (before (buffer-substring-no-properties start (1+ end))))
          (dsh-test-assert "thinking-live-header-body-and-separator-are-read-only"
            (null (text-property-not-all start (1+ end) 'read-only t)))
          (dolist (pos (list start body (1- end) end))
            (goto-char pos)
            (dsh-test-assert "thinking-live-block-rejects-insertion"
              (condition-case nil
                  (progn (insert "\n") nil)
                (text-read-only t)))
            (dsh-test-assert "thinking-live-block-rejects-deletion"
              (condition-case nil
                  (progn (delete-char 1) nil)
                (text-read-only t))))
          (dsh-test-assert "thinking-live-block-survives-edit-attempts"
            (equal before (buffer-substring-no-properties start (1+ end)))
            (equal "draft" (dsh-emacs--get-input))))))
    (goto-char (dsh-emacs--input-end))
    (insert " more")
    (dsh-test-assert "thinking-live-protection-keeps-input-editable"
      (equal "draft more" (dsh-emacs--get-input)))))

(with-temp-buffer
  (let ((icons 0)
        (event '((data . ((turn . 1) (step . 1))))))
    (cl-letf (((symbol-function 'dsh-emacs-render--think-icon)
               (lambda () (cl-incf icons) "✶")))
      (dotimes (_ 100)
        (dsh-emacs-render--start-thinking-stream event "x")))
    (dsh-test-assert "thinking-burst-defers-buffer-edits"
      (equal (buffer-string) "✶ Think\nx\n")
      (= (length (plist-get dsh-emacs--streaming-thinking :chunks)) 99))
    (let ((writes 0))
      (add-hook 'after-change-functions (lambda (&rest _) (cl-incf writes)) nil t)
      (dsh-emacs-render--flush-thinking)
      (dsh-test-assert "thinking-burst-flushes-one-edit"
        (= writes 1)
        (null (plist-get dsh-emacs--streaming-thinking :timer))))
    (dsh-test-assert "thinking-stream-builds-header-once"
      (= icons 1)
      (equal (buffer-string) (concat "✶ Think\n" (make-string 100 ?x) "\n")))))

(with-temp-buffer
  (save-window-excursion
    (switch-to-buffer (current-buffer))
    (insert "body\ninput")
    (goto-char (point-max))
    (set-window-start (selected-window) 1)
    (let ((writes 0))
      (cl-letf (((symbol-function 'dsh-emacs-render--input-anchor-pos)
                 (lambda () 6))
                ((symbol-function 'set-window-start)
                 (lambda (&rest _) (cl-incf writes))))
        (dotimes (_ 100) (dsh-emacs-render--follow-stream)))
      (dsh-test-assert "follow-keeps-unchanged-window-start"
        (= writes 0)))))

(with-temp-buffer
  (let ((event '((data . ((turn . 1) (step . 1))))))
    (dsh-emacs-render--start-thinking-stream event "first")
    (dsh-emacs-render--start-thinking-stream event " queued")
    (dsh-emacs-render--start-thinking-stream
     '((data . ((turn . 1) (step . 2)))) "second")
    (dsh-test-assert "thinking-switch-flushes-old-step"
      (string-match-p "first queued" (buffer-string)))
    (dsh-emacs-render--start-thinking-stream
     '((data . ((turn . 1) (step . 2)))) " tail")
    (dsh-emacs-render-event '((type . "unknown-boundary")))
    (dsh-test-assert "thinking-event-boundary-flushes"
      (string-match-p "second tail" (buffer-string))
      (null (plist-get dsh-emacs--streaming-thinking :timer)))
    (dsh-emacs-render--start-thinking-stream
     '((data . ((turn . 1) (step . 2)))) " disconnect")
    (dsh-emacs-render--flush-stream)
    (dsh-test-assert "thinking-teardown-flushes"
      (string-match-p "second tail disconnect" (buffer-string))
      (null (plist-get dsh-emacs--streaming-thinking :timer)))))

(when dsh-emacs-show-reasoning
  (dsh-test-pass "thinking-show-reasoning-defaults-on"))

(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (dsh-emacs-render-event
   (json-read-from-string
    "{\"type\":\"assistant/chunk\",\"seq\":1,\"data\":{\"turn\":1,\"step\":1,\"chunk\":{\"type\":\"block-start\",\"index\":0,\"blockType\":\"reasoning\"}}}"))
  (dsh-emacs-render-event
   (json-read-from-string
    "{\"type\":\"assistant/chunk\",\"seq\":2,\"data\":{\"turn\":1,\"step\":1,\"chunk\":{\"type\":\"reasoning-delta\",\"index\":0,\"text\":\"think step one\"}}}"))
  (dsh-emacs-render-event
   (json-read-from-string
    "{\"type\":\"assistant/chunk\",\"seq\":3,\"data\":{\"turn\":1,\"step\":1,\"chunk\":{\"type\":\"reasoning-delta\",\"index\":0,\"text\":\" then two\"}}}"))
  (dsh-emacs-render--flush-thinking)
  (let ((text (buffer-substring-no-properties (point-min) (point-max))))
    (when (and (string-match-p "✶ Think" text)
               (string-match-p "think step one then two" text))
      (dsh-test-pass "thinking-stream-renders-live-block"))))

(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (dsh-emacs-render-event
   (json-read-from-string
    "{\"type\":\"assistant/chunk\",\"seq\":1,\"data\":{\"turn\":1,\"step\":1,\"chunk\":{\"type\":\"reasoning-delta\",\"index\":0,\"text\":\"step\"}}}"))
  (dsh-emacs-render-event
   (json-read-from-string
    "{\"type\":\"assistant/message\",\"seq\":2,\"data\":{\"turn\":1,\"step\":1,\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"reasoning\",\"text\":\"final thinking\"},{\"type\":\"text\",\"text\":\"reply body\"}]}}}"))
  (let ((text (buffer-substring-no-properties (point-min) (point-max))))
    (when (and (string-match-p "✶ Think" text)
               (string-match-p "reply body" text)
               (null dsh-emacs--streaming-thinking)
               (= (cl-count ?✶ text) 1))
      (dsh-test-pass "thinking-final-replaces-stream-single-block"))))

(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (dsh-emacs-render-event
   (json-read-from-string
    "{\"type\":\"assistant/message\",\"seq\":1,\"data\":{\"turn\":1,\"step\":1,\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"reasoning\",\"text\":\"history think\"},{\"type\":\"text\",\"text\":\"history body\"}]}}}"))
  (let ((text (buffer-substring-no-properties (point-min) (point-max))))
    (when (and (string-match-p "✶ Think" text)
               (string-match-p "history body" text)
               (null dsh-emacs--streaming-thinking))
      (dsh-test-pass "thinking-history-renders-final-block"))))

(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (let ((dsh-emacs-show-reasoning nil))
    (dsh-emacs-render-event
     (json-read-from-string
      "{\"type\":\"assistant/chunk\",\"seq\":1,\"data\":{\"turn\":1,\"step\":1,\"chunk\":{\"type\":\"reasoning-delta\",\"index\":0,\"text\":\"should be hidden\"}}}"))
    (dsh-emacs-render-event
     (json-read-from-string
      "{\"type\":\"assistant/message\",\"seq\":2,\"data\":{\"turn\":1,\"step\":1,\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"reasoning\",\"text\":\"hidden\"},{\"type\":\"text\",\"text\":\"shown\"}]}}}"))
  (let ((text (buffer-substring-no-properties (point-min) (point-max))))
    (when (and (null dsh-emacs--streaming-thinking)
               (not (string-match-p "✶ Think" text))
               (string-match-p "shown" text))
      (dsh-test-pass "thinking-disabled-hides-block")))))

;; Regression: unchanged interleaved blocks keep their order at finalization.
(dolist (types '(("text" "reasoning" "text" "reasoning" "text")
                 ("reasoning" "text" "reasoning" "text" "reasoning")))
  (dolist (limit '(nil 8))
    (with-temp-buffer
      (dsh-emacs-mode)
      (let ((dsh-emacs-stream-markdown-limit limit)
            (dsh-emacs-thinking-expand-by-default t)
            (seq 0)
            content)
        (dolist (type types)
          (let ((text (format "%s-%d" type (cl-incf seq))))
            (push `((type . ,type) (text . ,text)) content)
            (dsh-emacs-render-event
             `((type . "assistant/chunk") (seq . ,seq)
               (data . ((turn . 1) (step . 1)
                        (chunk . ((type . ,(concat type "-delta"))
                                  (index . ,(1- seq)) (text . ,text))))))))
          (dsh-emacs-render--flush-stream)
          (dsh-emacs-render--flush-thinking))
        (dsh-emacs-render-event
         `((type . "assistant/message") (seq . 6)
           (data . ((turn . 1) (step . 1)
                    (message . ((role . "assistant")
                                (content . ,(vconcat (nreverse content)))))))))
        (dotimes (_ 6)
          (when dsh-emacs--markdown-pending
            (dsh-emacs-render--run-markdown (current-buffer))))
        (let ((text (buffer-substring-no-properties (point-min) (point-max)))
              (previous 0))
          (dsh-test-assert "stream-final-keeps-one-think-per-block"
            (= (cl-count ?✶ text) (cl-count "reasoning" types :test #'equal)))
          (cl-loop for type in types for index from 1
                   for pos = (string-match (format "%s-%d" type index) text)
                   do (dsh-test-assert "stream-final-keeps-block-order"
                        pos (> pos previous))
                   do (setq previous (or pos previous))))))))

;; A step can carry several protocol blocks.  Each owns its own transcript
;; region: the text stream's Markdown passes must never reach a reasoning body
;; that sits between two text blocks, and the authoritative message must not
;; re-render or delete a block that already streamed.
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (let ((dsh-emacs-thinking-expand-by-default t))
    (dsh-emacs-render-event
     (json-read-from-string
      "{\"type\":\"assistant/chunk\",\"seq\":1,\"data\":{\"turn\":1,\"step\":1,\"chunk\":{\"type\":\"text-delta\",\"index\":0,\"text\":\"first answer\\n\"}}}"))
    (dsh-emacs-render--flush-stream)
    (dsh-emacs-render-event
     (json-read-from-string
      "{\"type\":\"assistant/chunk\",\"seq\":2,\"data\":{\"turn\":1,\"step\":1,\"chunk\":{\"type\":\"reasoning-delta\",\"index\":1,\"text\":\"| a | b |\\n|---|---|\\n\"}}}"))
    (dsh-emacs-render--flush-thinking)
    (dsh-emacs-render-event
     (json-read-from-string
      "{\"type\":\"assistant/chunk\",\"seq\":3,\"data\":{\"turn\":1,\"step\":1,\"chunk\":{\"type\":\"text-delta\",\"index\":2,\"text\":\"second answer\\n\"}}}"))
    (dsh-emacs-render--flush-stream)
    (let* ((text (buffer-substring-no-properties (point-min) (point-max)))
           (first (string-match "first answer" text))
           (think (string-match "✶ Think" text))
           (second (string-match "second answer" text)))
      (dsh-test-assert "thinking-body-keeps-raw-markdown"
        (string-match-p (regexp-quote "| a | b |") text)
        (not (string-match-p "├───" text)))
      (dsh-test-assert "thinking-blocks-stack-in-arrival-order"
        (and first think second (< first think second))))
    (dsh-emacs-render-event
     (json-read-from-string
      "{\"type\":\"assistant/message\",\"seq\":4,\"data\":{\"turn\":1,\"step\":1,\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"first answer\\n\"},{\"type\":\"reasoning\",\"text\":\"| a | b |\\n|---|---|\\n\"},{\"type\":\"text\",\"text\":\"second answer\\n\"}]}}}"))
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      (dsh-test-assert "thinking-interleaved-final-keeps-every-block"
        (= (cl-count ?✶ text) 1)
        (string-match-p "first answer" text)
        (string-match-p "second answer" text)
        (not (string-match-p "├───" text))))))

;; A text block that ends before reasoning is a finished body: the final
;; message must not repaint it when it matches what streamed.
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (let ((dsh-emacs-thinking-expand-by-default t))
    (dsh-emacs-render-event
     (json-read-from-string
      "{\"type\":\"assistant/chunk\",\"seq\":1,\"data\":{\"turn\":1,\"step\":1,\"chunk\":{\"type\":\"text-delta\",\"index\":0,\"text\":\"only answer\\n\"}}}"))
    (dsh-emacs-render--flush-stream)
    (dsh-emacs-render-event
     (json-read-from-string
      "{\"type\":\"assistant/chunk\",\"seq\":2,\"data\":{\"turn\":1,\"step\":1,\"chunk\":{\"type\":\"reasoning-delta\",\"index\":1,\"text\":\"why\\n\"}}}"))
    (dsh-emacs-render--flush-thinking)
    (dsh-emacs-render-event
     (json-read-from-string
      "{\"type\":\"assistant/message\",\"seq\":3,\"data\":{\"turn\":1,\"step\":1,\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"only answer\\n\"},{\"type\":\"reasoning\",\"text\":\"why\\n\"}]}}}"))
    (let* ((text (buffer-substring-no-properties (point-min) (point-max)))
           (copies 0)
           (pos 0))
      (while (string-match "only answer" text pos)
        (setq copies (1+ copies)
              pos (match-end 0)))
      (dsh-test-assert "thinking-final-does-not-repaint-committed-text"
        (= (cl-count ?✶ text) 1)
        (= copies 1)
        (null dsh-emacs--streamed-step)))))

;; Two reasoning blocks around a text block: when the authoritative text
;; diverges and the middle body is dropped, neither Think block may go with it.
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (let ((dsh-emacs-thinking-expand-by-default t))
    (dsh-emacs-render-event
     (json-read-from-string
      "{\"type\":\"assistant/chunk\",\"seq\":1,\"data\":{\"turn\":1,\"step\":1,\"chunk\":{\"type\":\"reasoning-delta\",\"index\":0,\"text\":\"think A\\n\"}}}"))
    (dsh-emacs-render--flush-thinking)
    (dsh-emacs-render-event
     (json-read-from-string
      "{\"type\":\"assistant/chunk\",\"seq\":2,\"data\":{\"turn\":1,\"step\":1,\"chunk\":{\"type\":\"text-delta\",\"index\":1,\"text\":\"text one\\n\"}}}"))
    (dsh-emacs-render--flush-stream)
    (dsh-emacs-render-event
     (json-read-from-string
      "{\"type\":\"assistant/chunk\",\"seq\":3,\"data\":{\"turn\":1,\"step\":1,\"chunk\":{\"type\":\"reasoning-delta\",\"index\":2,\"text\":\"think B\\n\"}}}"))
    (dsh-emacs-render--flush-thinking)
    (dsh-emacs-render-event
     (json-read-from-string
      "{\"type\":\"assistant/message\",\"seq\":4,\"data\":{\"turn\":1,\"step\":1,\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"reasoning\",\"text\":\"think A\\nthink B\\n\"},{\"type\":\"text\",\"text\":\"text one.\"}]}}}"))
    (let* ((text (buffer-substring-no-properties (point-min) (point-max)))
           (a (string-match "think A" text))
           (b (string-match "think B" text)))
      (dsh-test-assert "thinking-two-blocks-survive-a-divergent-repair"
        (= (cl-count ?✶ text) 2)
        (and a b (< a b))
        (string-match-p "text one" text)))))


(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (let ((dsh-emacs-modeline-show-step t))
    (dsh-emacs-render-event
     (json-read-from-string
      "{\"type\":\"turn/start\",\"seq\":1,\"time\":900,\"data\":{\"turn\":1}}"))
    (dsh-emacs-render-event
     (json-read-from-string
      "{\"type\":\"step/start\",\"seq\":2,\"time\":1000,\"data\":{\"turn\":1,\"step\":2}}"))
    (dsh-test-assert "step-start-is-mode-line-only"
      (not (string-match-p "step"
                           (buffer-substring-no-properties (point-min) (point-max))))
      (equal "step 2" (dsh-emacs-modeline--step-indicator)))
    (dsh-emacs-render-event
     (json-read-from-string
      "{\"type\":\"step/end\",\"seq\":3,\"time\":3000,\"data\":{\"turn\":1,\"step\":2}}"))
    (dsh-test-assert "step-end-keeps-badge-without-fake-elapsed"
      (equal "step 2" (dsh-emacs-modeline--step-indicator)))
    (dsh-emacs-render-event
     (json-read-from-string
      "{\"type\":\"turn/end\",\"seq\":4,\"time\":4000,\"data\":{\"turn\":1,\"reason\":{\"kind\":\"completed\"}}}"))
    (dsh-test-assert "turn-end-clears-step-badge"
      (null dsh-emacs--modeline-step)
      (equal "" (dsh-emacs-modeline--step-indicator)))))

;; The option gates the badge: off (the default) leaves the mode line alone.
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (dsh-emacs-render-event
   (json-read-from-string
    "{\"type\":\"turn/start\",\"seq\":1,\"time\":900,\"data\":{\"turn\":1}}"))
  (dsh-emacs-render-event
   (json-read-from-string
    "{\"type\":\"step/start\",\"seq\":2,\"time\":1000,\"data\":{\"turn\":1,\"step\":2}}"))
  (dsh-test-assert "step-badge-off-by-default"
    (null dsh-emacs-modeline-show-step)
    (equal 2 (plist-get dsh-emacs--modeline-step :step))
    (equal "" (dsh-emacs-modeline--step-indicator)))
  (dsh-emacs-render-event
   (json-read-from-string
    "{\"type\":\"turn/end\",\"seq\":3,\"time\":3000,\"data\":{\"turn\":1,\"reason\":{\"kind\":\"completed\"}}}")))

;; The badge shows the elapsed wall-clock time of a step over a second.
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (let ((dsh-emacs-modeline-show-step t))
    (setq dsh-emacs--ml-busy t
          dsh-emacs--modeline-step (list :turn 1 :step 2 :start 100.0 :end 103.0))
    (dsh-test-assert "step-badge-shows-frozen-elapsed"
      (equal "step 2 · 3s" (dsh-emacs-modeline--step-indicator)))))

;; A step recorded while idle is not a status; the badge stays hidden.
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (let ((dsh-emacs-modeline-show-step t))
    (dsh-emacs-modeline-note-step 1 3 t)
    (dsh-test-assert "step-badge-hidden-when-idle"
      (null dsh-emacs--ml-busy)
      (equal "" (dsh-emacs-modeline--step-indicator)))))

;; A stray step/end for another step leaves the current badge alone.
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (dsh-emacs-modeline-note-step 1 2 t)
  (dsh-emacs-modeline-note-step 1 1 nil)
  (dsh-test-assert "step-end-only-closes-its-own-step"
    (equal 2 (plist-get dsh-emacs--modeline-step :step))
    (null (plist-get dsh-emacs--modeline-step :end))))

;; assistant/attempt: replay renders the collapsed diagnostic card.
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (dsh-emacs-render-event
   (json-read-from-string
    "{\"type\":\"assistant/attempt\",\"seq\":4,\"time\":1000,\"data\":{\"turn\":2,\"step\":3,\"stream\":[{\"type\":\"reasoning-chunks\",\"time0\":1,\"index\":0,\"dt\":[1],\"texts\":[\"why it failed\"]},{\"type\":\"text-chunks\",\"time0\":2,\"index\":1,\"dt\":[1],\"texts\":[\"partial reply\"]}]}}"))
  (let ((text (buffer-substring-no-properties (point-min) (point-max))))
    (dsh-test-assert "attempt-history-renders-collapsed-card"
      (string-match-p "Attempt (no committed reply)" text)
      (string-match-p "turn 2 step 3" text))))

;; Packed stream records reconstruct in order, tool calls included.
(dsh-test-assert "attempt-stream-text-reconstructs"
  (equal (dsh-emacs-render--assistant-stream-text
          (list (list (cons "type" "reasoning-chunks")
                      (cons "texts" (vector "think")))
                (list (cons "type" "tool-call-chunks")
                      (cons "name" "bash")
                      (cons "args" (vector "{\"command\":\"ls\"}")))
                (list (cons "type" "text-chunks")
                      (cons "texts" (vector "reply")))))
         "think\n→ bash {\"command\":\"ls\"}\nreply"))

(dsh-test-assert "attempt-stream-text-respects-reasoning-option"
  (let ((dsh-emacs-show-reasoning nil))
    (equal (dsh-emacs-render--assistant-stream-text
            (list (list (cons "type" "reasoning-chunks")
                        (cons "texts" (vector "hidden think")))))
           "")))

;; A live body the attempt settles is taken over, never painted twice.
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (dsh-emacs-render--start-assistant-stream
   '((data . ((turn . 1) (step . 1)))) "live partial")
  (dsh-emacs-render-event
   (json-read-from-string
    "{\"type\":\"assistant/attempt\",\"seq\":5,\"time\":2000,\"data\":{\"turn\":1,\"step\":1,\"stream\":[{\"type\":\"text-chunks\",\"time0\":1,\"index\":0,\"dt\":[1],\"texts\":[\"live partial\"]}]}}"))
  (let ((text (buffer-substring-no-properties (point-min) (point-max))))
    (dsh-test-assert "attempt-takes-over-live-body"
      (null dsh-emacs--streaming-assistant)
      (string-match-p "Attempt (no committed reply)" text)
      (= 2 (length (split-string text "live partial" nil))))))

;; session/end-seed: the restore boundary, marked when inherited.
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (dsh-emacs-render-event
   (json-read-from-string
    "{\"type\":\"session/end-seed\",\"seq\":7,\"data\":{\"inherited\":true}}"))
  (let ((text (buffer-substring-no-properties (point-min) (point-max))))
    (dsh-test-assert "seed-boundary-renders-divider"
      (string-match-p "seed boundary" text)
      (string-match-p "inherited history" text))))

(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (dsh-emacs-render-event
   (json-read-from-string
    "{\"type\":\"session/end-seed\",\"seq\":7,\"data\":{}}"))
  (let ((text (buffer-substring-no-properties (point-min) (point-max))))
    (dsh-test-assert "seed-boundary-marks-replay-without-inheritance"
      (string-match-p "seed boundary" text)
      (not (string-match-p "inherited history" text)))))

;; deliverables/presented: collected, rendered once at the turn's tail.
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (dsh-emacs-render-event
   (json-read-from-string
    "{\"type\":\"assistant/message\",\"seq\":1,\"data\":{\"turn\":1,\"step\":1,\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"closing reply\"}]}}}"))
  (dsh-emacs-render-event
   (json-read-from-string
    "{\"type\":\"deliverables/presented\",\"seq\":2,\"data\":{\"turn\":1,\"callId\":\"c1\",\"files\":[{\"path\":\"report.md\",\"description\":\"Final report\"},{\"path\":\"notes.txt\"}]}}"))
  (dsh-test-assert "deliverables-deferred-until-turn-end"
    (not (string-match-p "Deliverables"
                         (buffer-substring-no-properties (point-min) (point-max)))))
  (dsh-emacs-render-event
   (json-read-from-string
    "{\"type\":\"turn/end\",\"seq\":3,\"data\":{\"turn\":1,\"reason\":{\"kind\":\"completed\"}}}"))
  (let* ((full (buffer-string))
         (text (buffer-substring-no-properties (point-min) (point-max)))
         (reply (string-match "closing reply" full))
         (row (string-match "Deliverables" full)))
    (dsh-test-assert "deliverables-row-at-turn-tail-collapsed"
      (string-match-p "Deliverables · 2 files" text)
      (not (string-match-p "report.md" text))
      (and reply row (< reply row)))
    (dsh-test-assert "deliverables-row-leads-with-green-dot"
      (let ((dot (string-match "●" full)))
        (and dot
             (memq 'dsh-emacs-deliverable-dot-face
                   (ensure-list (get-text-property dot 'face full))))))
    (dsh-test-assert "deliverables-title-uses-own-face"
      (let ((title (string-match "Deliverables" full)))
        (and title
             (memq 'dsh-emacs-deliverable-text-face
                   (ensure-list (get-text-property title 'face full))))))
    ;; Expanding shows the file lines in the bash-card panel surface.
    (goto-char (point-min))
    (dsh-emacs-ui-toggle-fragment)
    (setq full (buffer-string)
          text (buffer-substring-no-properties (point-min) (point-max)))
    (let ((path (string-match (regexp-quote "report.md") full)))
      (dsh-test-assert "deliverables-expanded-shows-files"
        (string-match-p "Final report" text)
        (string-match-p "notes.txt" text))
      (dsh-test-assert "deliverables-path-is-clickable"
        (equal '(file . "report.md")
               (get-text-property path 'dsh-emacs-reference-ref full))
        (memq 'dsh-emacs-reference-face
              (ensure-list (get-text-property path 'face full)))))))

;; Repeated declaration of one path keeps one line, latest description.
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (dolist (json '("{\"type\":\"deliverables/presented\",\"seq\":1,\"data\":{\"turn\":4,\"callId\":\"a\",\"files\":[{\"path\":\"out.md\",\"description\":\"old\"}]}}"
                  "{\"type\":\"deliverables/presented\",\"seq\":2,\"data\":{\"turn\":4,\"callId\":\"b\",\"files\":[{\"path\":\"out.md\",\"description\":\"new\"}]}}"
                  "{\"type\":\"turn/end\",\"seq\":3,\"data\":{\"turn\":4,\"reason\":{\"kind\":\"completed\"}}}"))
    (dsh-emacs-render-event (json-read-from-string json)))
  (goto-char (point-min))
  (dsh-emacs-ui-toggle-fragment)
  (let ((text (buffer-substring-no-properties (point-min) (point-max))))
    (dsh-test-assert "deliverables-merge-last-wins"
      (string-match-p "Deliverables · 1 file" text)
      (string-match-p "new" text)
      (not (string-match-p "old" text))
      (= 2 (length (split-string text "out.md" nil))))))

;; A snapshot tail cut before turn/end still renders the row (batch end),
;; and the flush clears the state so a later turn/end cannot render twice.
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (dsh-emacs-render-history-events
   (list (list (cons "event"
                     (json-read-from-string
                      "{\"type\":\"deliverables/presented\",\"seq\":1,\"data\":{\"turn\":7,\"callId\":\"c\",\"files\":[{\"path\":\"out.txt\"}]}}"))))
   nil)
  (dsh-test-assert "deliverables-flushed-at-batch-end"
    (string-match-p "Deliverables · 1 file"
                    (buffer-substring-no-properties (point-min) (point-max))))
  (goto-char (point-min))
  (dsh-emacs-ui-toggle-fragment)
  (dsh-test-assert "deliverables-batch-row-expands"
    (string-match-p "out.txt"
                    (buffer-substring-no-properties (point-min) (point-max))))
  (dsh-emacs-render-event
   (json-read-from-string
    "{\"type\":\"turn/end\",\"seq\":2,\"data\":{\"turn\":7,\"reason\":{\"kind\":\"completed\"}}}"))
  (dsh-test-assert "deliverables-flush-does-not-double-render"
    (null dsh-emacs-render--turn-deliverables)
    (= 1 (cl-count ?● (buffer-substring-no-properties (point-min) (point-max))))))

;; A newline inside a model-written description cannot fake a second file.
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (dolist (json '("{\"type\":\"deliverables/presented\",\"seq\":1,\"data\":{\"turn\":1,\"callId\":\"c\",\"files\":[{\"path\":\"a.md\",\"description\":\"one\\ntwo\"}]}}"
                  "{\"type\":\"turn/end\",\"seq\":2,\"data\":{\"turn\":1,\"reason\":{\"kind\":\"completed\"}}}"))
    (dsh-emacs-render-event (json-read-from-string json)))
  (goto-char (point-min))
  (dsh-emacs-ui-toggle-fragment)
  (let ((text (buffer-substring-no-properties (point-min) (point-max))))
    (dsh-test-assert "deliverable-description-flattened"
      (string-match-p "a.md — one two" text))))

;; The reference module owns the clickable file-path presentation.
(dsh-test-assert "reference-file-link-propertizes"
  (let ((span (dsh-emacs-reference-file-link "a.md")))
    (and (equal '(file . "a.md")
                (get-text-property 0 'dsh-emacs-reference-ref span))
         (eq 'dsh-emacs-reference-face (get-text-property 0 'face span))))
  (equal "" (dsh-emacs-reference-file-link "")))

;; The row title carries its own hue: it must not blend into the green dot,
;; and must not read as a second link color next to the clickable paths.
(dsh-test-assert "deliverables-title-color-differs-from-dot"
  (let ((title (face-foreground 'dsh-emacs-deliverable-text-face nil t))
        (dot (face-foreground 'dsh-emacs-deliverable-dot-face nil t)))
    (and title dot (not (equal title dot)))))

(dsh-test-assert "deliverables-title-color-differs-from-link"
  (let ((title (face-foreground 'dsh-emacs-deliverable-text-face nil t))
        (link (face-foreground 'dsh-emacs-reference-face nil t)))
    (and title link (not (equal title link)))))

;; --- Test 22: messages still insert above the input box after the input marker
;; is lost ---
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  ;; Simulate the failure where the prompt marker is gone; message rendering
  ;; must relocate the anchor by face instead of appending below the input.
  (setq-local dsh-emacs--input-marker nil)
  (dsh-emacs-render-event
   (json-read-from-string
    (concat "{\"type\":\"assistant/message\",\"seq\":1,"
            "\"data\":{\"message\":{\"content\":[{\"type\":\"text\","
            "\"text\":\"reply-above-input\"}]}}}")))
  (let* ((anchor (or (dsh-emacs-render--input-anchor-pos) (point-max)))
         (text (buffer-substring-no-properties (point-min) (point-max)))
         (reply-pos (string-match "reply-above-input" text)))
    (when (and reply-pos
               (< reply-pos anchor)
               (save-excursion
                 (goto-char (point-min))
                 (re-search-forward "❯ " nil t)))
      (dsh-test-pass "assistant-below-input-fallback"))))

;; --- Test 23: streaming chunks also insert above the input box when the marker
;; is lost ---
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (setq-local dsh-emacs--input-marker nil)
  (dsh-emacs-render-event
   (json-read-from-string
    "{\"type\":\"assistant/chunk\",\"seq\":1,\"data\":{\"turn\":1,\"step\":1,\"chunk\":{\"type\":\"text-delta\",\"index\":1,\"text\":\"stream-above-input\"}}}"))
  (let* ((anchor (or (dsh-emacs-render--input-anchor-pos) (point-max)))
         (text (buffer-substring-no-properties (point-min) (point-max)))
         (stream-pos (string-match "stream-above-input" text)))
    (when (and stream-pos
               (< stream-pos anchor))
      (dsh-test-pass "assistant-stream-below-input-fallback"))))

;; --- Test 25: new messages auto-scroll-follow while at the bottom ---
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (pop-to-buffer (current-buffer))
  (let ((win (get-buffer-window (current-buffer) t)))
    ;; Fill enough content to overflow a small window.
    (dotimes (i 40)
      (dsh-emacs-render-event
       (json-read-from-string
        (format "{\"type\":\"assistant/message\",\"seq\":%d,\"data\":{\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"filler %d filler filler filler filler filler\"}]}}}" (1+ i) i))))
    ;; Pin the view to the bottom.
    (let ((anchor (or (dsh-emacs-render--input-anchor-pos) (point-max))))
      (save-excursion
        (goto-char anchor)
        (forward-line (- (1- (max 1 (window-text-height win)))))
        (set-window-start win (max (point-min) (point))))
      (let ((start-before (window-start win)))
        (dsh-emacs-render-event
         (json-read-from-string
          "{\"type\":\"assistant/message\",\"seq\":1000,\"data\":{\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"fresh follow message\"}]}}}"))
        (dsh-emacs-render--follow-stream)
        (when (> (window-start win) start-before)
          (dsh-test-pass "follow-scrolls-at-bottom"))))))

;; --- Test 26: not pulled back to the bottom while the user scrolls up ---
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (pop-to-buffer (current-buffer))
  (let ((win (get-buffer-window (current-buffer) t)))
    (dotimes (i 40)
      (dsh-emacs-render-event
       (json-read-from-string
        (format "{\"type\":\"assistant/message\",\"seq\":%d,\"data\":{\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"filler %d filler filler filler filler filler\"}]}}}" (1+ i) i))))
    (set-window-start win 1)          ; user scrolled to the top
    (dsh-emacs-render-event
     (json-read-from-string
      "{\"type\":\"assistant/message\",\"seq\":1000,\"data\":{\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"scrolled-away message\"}]}}}"))
    (dsh-emacs-render--follow-stream)
    (when (= (window-start win) 1)
      (dsh-test-pass "follow-does-not-yank-scrolled-window"))))

;; --- Test 27: same-buffer input mode (agent-shell style) ---
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (dsh-emacs-render-event
   (json-read-from-string
    "{\"type\":\"assistant/message\",\"seq\":1,\"data\":{\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"inline reply\"}]}}}"))
  (let* ((text (buffer-substring-no-properties (point-min) (point-max)))
         (reply-pos (string-match "inline reply" text))
         (prompt-pos (string-match "❯ " text))
         (marker-pos (marker-position dsh-emacs--input-marker)))
    (when (and reply-pos prompt-pos
               (< reply-pos prompt-pos)         ; reply above the prompt
               (goto-char marker-pos)
               (looking-back "❯ " (line-beginning-position)))
      (dsh-test-pass "inline-mode-single-buffer"))))

;; --- Test 27e: telega-style scroll discipline (chatbuf buffer-local) ---
(with-temp-buffer
  (dsh-emacs-mode)
  (when (and (local-variable-p 'scroll-conservatively (current-buffer))
             (= 101 scroll-conservatively)
             (= 0 (or next-screen-context-lines -1))
             scroll-error-top-bottom)
    (dsh-test-pass "chat-buffer-scroll-discipline")))

;; --- Test 27g: one blank line around user messages; assistant messages still
;; stay tight ---
(let ((buf (generate-new-buffer " *t27g-layout*")))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (dsh-emacs-modeline-setup)
        (dsh-emacs-render-event
         (json-read-from-string
          "{\"type\":\"assistant/message\",\"seq\":1,\"data\":{\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"a1\"}]}}}"))
        (dsh-emacs-render-event
         (json-read-from-string
          "{\"type\":\"assistant/message\",\"seq\":2,\"data\":{\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"a2\"}]}}}"))
        (dsh-emacs-render-event
         (json-read-from-string
          "{\"type\":\"user/message\",\"seq\":3,\"data\":{\"content\":[{\"type\":\"text\",\"text\":\"u1\"}]}}"))
        (dsh-emacs-render-event
         (json-read-from-string
          "{\"type\":\"assistant/message\",\"seq\":4,\"data\":{\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"a3\"}]}}}"))
        (let* ((user-line
                (save-excursion
                  (goto-char (point-min))
                  (when (search-forward "❯ u1" nil t)
                    (line-number-at-pos (line-beginning-position)))))
               (above-blank
                (and user-line
                     (save-excursion
                       (goto-char (point-min))
                       (forward-line (- user-line 2))
                       (looking-at-p "[ \t]*$"))))
               (below-blank
                (and user-line
                     (save-excursion
                       (goto-char (point-min))
                       (forward-line user-line)
                       (looking-at-p "[ \t]*$"))))
               (a1-line (save-excursion
                          (goto-char (point-min))
                          (when (search-forward "a1" nil t)
                            (line-number-at-pos (line-beginning-position)))))
               (a2-line (save-excursion
                          (goto-char (point-min))
                          (when (search-forward "a2" nil t)
                            (line-number-at-pos (line-beginning-position))))))
          (when (and above-blank below-blank)
            (dsh-test-pass "user-message-spaced-above-and-below"))
          ;; Adjacent assistant messages still stay tight (no blank line)
          (when (and a1-line a2-line (= a2-line (1+ a1-line)))
            (dsh-test-pass "assistant-messages-remain-flush"))))
    (kill-buffer buf)))

;; --- Test 28: frames after the WebSocket handshake are still consumed (live
;; fix) ---
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (setq dsh-emacs--current-session "s1")   ; match the test frame's sessionId
  (setq-local dsh-emacs--buffer-session "s1") ; ownership: a real open-session sets it
  (let ((fake-proc (start-process "dsh-test-proc" (current-buffer) "/usr/bin/true"))
        (dispatch-count 0))
    (accept-process-output fake-proc 1)
    (process-put fake-proc 'dsh-emacs-chat-buffer (current-buffer))
    (process-put fake-proc 'dsh-emacs-follow-stream-id "f1")
    (process-put fake-proc 'dsh-emacs-event-input "")
    (process-put fake-proc 'dsh-emacs-event-ready t)
    (advice-add 'dsh-emacs-events--dispatch-json :before
                (lambda (&rest _) (setq dispatch-count (1+ dispatch-count))))
    (unwind-protect
        (progn
          ;; A valid masked text frame carrying one session/follow item frame
          ;; (`item' wrapping an `event' value), arriving as a *separate*
          ;; chunk after the handshake.  Build it with the real frame encoder
          ;; (handles extended lengths like the server's real >125-byte
          ;; frames).
          (let* ((json (format "{\"type\":\"item\",\"streamId\":\"f1\",\"value\":{\"type\":\"event\",\"event\":{\"type\":\"assistant/message\",\"seq\":1,\"data\":{\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"hello ws\"}]}}}}}"))
                 (frame (dsh-emacs-events--frame 1
                                                  (encode-coding-string json 'utf-8 t))))
            ;; Simulate the post-handshake filter path: store the raw bytes
            ;; then consume them (frames must be parsed on every chunk).
            (process-put fake-proc 'dsh-emacs-event-input frame)
            (dsh-emacs-events--consume-frames fake-proc))
          (when (and (= dispatch-count 1)          ; exactly one frame dispatched
                     (string-empty-p (process-get fake-proc 'dsh-emacs-event-input))
                     (string-match-p "hello ws"
                                     (buffer-substring-no-properties (point-min) (point-max))))
            (dsh-test-pass "websocket-frames-consumed-after-handshake")))
      (delete-process fake-proc)
      (advice-remove 'dsh-emacs-events--dispatch-json
                     (lambda (&rest _) (setq dispatch-count (1+ dispatch-count)))))))

;; --- Test 24: the input anchor occupies its own line (before the bottom
;; structural line) ---
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  ;; The anchor prompt line always ends with a newline and sits right before
  ;; the end-of-buffer newline, so point-max never falls inside the editable input.
  (let ((mode-line-start (overlay-start dsh-emacs--modeline-overlay)))
    (when (and (eq (char-before mode-line-start) ?\n)
               ;; the anchor prompt is on its own line, before the end-of-buffer newline
               (save-excursion
                 (goto-char dsh-emacs--input-marker)
                 (eq (char-after (line-beginning-position)) ?❯)))
      (dsh-test-pass "input-anchor-keeps-own-line"))))

;; --- Test 29: dsh web style tool lines — variant icon + IN/OUT ioCard + status
;; dot ---
(defun dsh-emacs-test--tool-block-text (namespace-id block-id)
  "Return the UI block text for NAMESPACE-ID and BLOCK-ID, or nil."
  (when-let* ((b (dsh-emacs-ui-find-block namespace-id block-id)))
    (buffer-substring-no-properties (car b) (cdr b))))

(defun dsh-emacs-test--tool-call-event (seq call-id name args)
  "Build a `tool/call' event alist."
  (list (cons "type" "tool/call")
        (cons "seq" seq)
        (cons "data"
              (list (cons "callId" call-id)
                    (cons "name" name)
                    (cons "arguments" args)))))

(defun dsh-emacs-test--tool-result-event (seq call-id is-error exit-code text
                                              &optional error)
  "Build a `tool/result' event alist.
ERROR, when given, is the settled `data.error' alist (dsh 0.1.6's
optional `{name, code, reason?}')."
  (list (cons "type" "tool/result")
        (cons "seq" seq)
        (cons "data"
              (append
               (list (cons "message"
                           (list (cons "callId" call-id)
                                 (cons "content"
                                       (vector (list (cons "type" "tool-result")
                                                     (cons "isError" (if is-error t :json-false))
                                                     (cons "exitCode" exit-code)
                                                     (cons "content"
                                                           (vector (list (cons "type" "text")
                                                                         (cons "text" text))))))))))
               (and error (list (cons "error" error)))))))

(defun dsh-emacs-test--tool-result-event-meta (seq call-id text meta &optional is-error)
  "Build a `tool/result' event carrying TEXT and the settled result META."
  (list (cons "type" "tool/result")
        (cons "seq" seq)
        (cons "data"
              (list (cons "message"
                          (list (cons "callId" call-id)
                                (cons "content"
                                      (vector (list (cons "type" "tool-result")
                                                    (cons "isError" (if is-error t :json-false))
                                                    (cons "exitCode" (if is-error 1 0))
                                                    (cons "content"
                                                          (vector (list (cons "type" "text")
                                                                        (cons "text" text)))))))))
                    (cons "meta" meta)))))

(defun dsh-emacs-test--tool-result-event-bare (seq call-id content)
  "Build a `tool/result' event whose MESSAGE.CONTENT is CONTENT verbatim.
Lets a test drive a malformed content value through the result path."
  (list (cons "type" "tool/result")
        (cons "seq" seq)
        (cons "data"
              (list (cons "message"
                          (list (cons "callId" call-id)
                                (cons "content" content)))))))

(defun dsh-emacs-test--tool-result-event-source (seq call-id text)
  "Build a real dsh Web `tool/result' with MESSAGE.SOURCE.CALL-ID."
  (list (cons "type" "tool/result")
        (cons "seq" seq)
        (cons "data"
              (list (cons "message"
                          (list (cons "source" (list (cons "callId" call-id)))
                                (cons "content"
                                      (vector (list (cons "type" "tool-result")
                                                    (cons "isError" :json-false)
                                                    (cons "exitCode" 0)
                                                    (cons "content"
                                                          (vector (list (cons "type" "text")
                                                                        (cons "text" text)))))))))))))

(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (setq-local dsh-emacs-tool-expand-by-default t)
  ;; 1) tool call (running): keeps the bash variant icon + gear loading
  (dsh-emacs-render-tool-call
   (dsh-emacs-test--tool-call-event 1 "c1" "bash" "{\"description\":\"list files\",\"command\":\"ls -la\"}"))
  (let* ((ns (dsh-emacs-render--make-namespace))
         (block (dsh-emacs-test--tool-block-text ns "tool-c1")))
    (when (and block
               (string-match-p (regexp-quote "💻 ") block)
               ;; Keeps the variant icon while running; the animated spinner moved to the
               ;; mode-line progress bar
               (string-match-p "Bash" block))
      (dsh-test-pass "tool-running-keeps-variant-icon")))
  ;; 2) successful result: bash expands into a terminal card ($ prompt line +
  ;; output, no ✓ footer on a clean exit), no longer a generic IN/OUT ioCard
  (dsh-emacs-render-tool-result
   (dsh-emacs-test--tool-result-event 2 "c1" nil 0 "total 3\ndrwxr-xr-x"))
  (let* ((ns (dsh-emacs-render--make-namespace))
         (block (dsh-emacs-test--tool-block-text ns "tool-c1")))
    (when (and block
               (string-match-p (regexp-quote "💻 ") block)
               (string-match-p (regexp-quote "$ ls -la") block)
               (string-match-p "drwxr-xr-x" block)
               (not (string-match-p (regexp-quote "✓ exit 0") block))
               (not (string-match-p "IN" block))
               (not (string-match-p "OUT" block)))
      (dsh-test-pass "tool-bash-success-terminal-card")))
  ;; 3) expanded rows are unpadded: cards draw on the transcript background
  ;; with no surface band, so each row ends at its own content.
  (let* ((ns (dsh-emacs-render--make-namespace))
         (block (dsh-emacs-test--tool-block-text ns "tool-c1")))
    (dsh-test-assert "tool-bash-card-rows-are-unpadded"
      (and block
           (string-match-p "^  \\$ ls -la$" block)
           (string-match-p "^  drwxr-xr-x$" block))))
  ;; 3) error result: the leading marker becomes a red status dot ●
  (dsh-emacs-render-tool-call
   (dsh-emacs-test--tool-call-event 3 "c2" "edit" "{\"path\":\"/tmp/x\"}"))
  (dsh-emacs-render-tool-result
   (dsh-emacs-test--tool-result-event 4 "c2" nil 1 "segmentation fault"))
  (let* ((ns (dsh-emacs-render--make-namespace))
         (block (dsh-emacs-test--tool-block-text ns "tool-c2")))
    (when (and block
               (string-match-p (regexp-quote "● ") block)
               (string-match-p "segmentation fault" block))
      (dsh-test-pass "tool-error-state-dot-leading"))))

;; --- Test 29c: a file read expands into a line-numbered read card ---
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (setq-local dsh-emacs-tool-expand-by-default t)
  (dsh-emacs-render-tool-call
   (dsh-emacs-test--tool-call-event
    1 "r1" "read" "{\"file_path\":\"/a/b.el\",\"offset\":2,\"limit\":2}"))
  (dsh-emacs-render-tool-result
   (dsh-emacs-test--tool-result-event-meta
    2 "r1"
    "<path>/a/b.el</path>\n<type>file</type>\n<content>\n2: (b)\n3: (c)\n</content>"
    '((path . "/a/b.el") (offset . 2) (totalLines . 9) (lang . "emacs-lisp")
      (lines . [((number . 2) (text . "(b)"))
                ((number . 3) (text . "(c)"))]))))
  (let* ((ns (dsh-emacs-render--make-namespace))
         (full (buffer-string))
         (block (dsh-emacs-test--tool-block-text ns "tool-r1"))
         (num (string-match "2  (b)" full)))
    (dsh-test-assert "tool-read-card-numbers-the-window"
      (string-match-p "^  2  (b)$" block)
      (string-match-p "3  (c)" block)
      (string-match-p "Showing 2 of 9 lines · emacs-lisp" block)
      ;; the raw envelope and the argument JSON are both gone
      (not (string-match-p "<content>" block))
      (not (string-match-p "file_path" block)))
    (dsh-test-assert "tool-read-card-gutter-keeps-its-face"
      (and num
           (memq 'dsh-emacs-tool-meta-face
                 (ensure-list (get-text-property num 'face full)))))))

;; A read that covered the whole file prints no window footer.
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (setq-local dsh-emacs-tool-expand-by-default t)
  (dsh-emacs-render-tool-call
   (dsh-emacs-test--tool-call-event 1 "r2" "read" "{\"file_path\":\"/a/c.el\"}"))
  (dsh-emacs-render-tool-result
   (dsh-emacs-test--tool-result-event-meta
    2 "r2"
    "<path>/a/c.el</path>\n<type>file</type>\n<content>\n1: one\n2: \n</content>"
    '((path . "/a/c.el") (offset . 1) (totalLines . 2)
      (lines . [((number . 1) (text . "one"))
                ((number . 2) (text . ""))]))))
  (let* ((ns (dsh-emacs-render--make-namespace))
         (block (dsh-emacs-test--tool-block-text ns "tool-r2")))
    (dsh-test-assert "tool-read-card-whole-file-has-no-window-footer"
      (string-match-p "1  one" block)
      (not (string-match-p "Showing" block))
      (not (string-match-p "IN" block)))))

;; --- Test 29d: write/edit rows expand into a dsh web diff card ---
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (setq-local dsh-emacs-tool-expand-by-default t)
  ;; While the call runs the diff is the one the arguments intend.
  (dsh-emacs-render-tool-call
   (dsh-emacs-test--tool-call-event
    1 "d1" "edit"
    "{\"file_path\":\"src/x.el\",\"old_string\":\"(old a)\\n(old b)\",\"new_string\":\"(new a)\"}"))
  (let* ((ns (dsh-emacs-render--make-namespace))
         (running (dsh-emacs-test--tool-block-text ns "tool-d1")))
    (dsh-test-assert "tool-edit-running-shows-intended-diff"
      (string-match-p "- (old a)" running)
      (string-match-p "- (old b)" running)
      (string-match-p "+ (new a)" running)
      (string-match-p (regexp-quote "└ +1 -2 · 1 file") running)
      (not (string-match-p "old_string" running))))
  ;; Settled, the applied diffs from the result metadata win.
  (dsh-emacs-render-tool-result
   (dsh-emacs-test--tool-result-event-meta
    2 "d1" "The file src/x.el has been updated successfully."
    '((diffs . [((path . "src/x.el")
                 (oldText . "one\ntwo")
                 (newText . "ONE\ntwo\nthree"))]))))
  (let* ((ns (dsh-emacs-render--make-namespace))
         (full (buffer-string))
         (settled (dsh-emacs-test--tool-block-text ns "tool-d1"))
         (del (string-match "- one" full))
         (add (string-match "+ ONE" full)))
    (dsh-test-assert "tool-edit-settled-shows-applied-diff"
      (string-match-p "- two" settled)
      (string-match-p "+ three" settled)
      (string-match-p (regexp-quote "└ +3 -2 · 1 file") settled)
      (not (string-match-p "(old a)" settled)))
    (dsh-test-assert "tool-diff-lines-carry-state-faces"
      (and del add
           (memq 'dsh-emacs-tool-diff-del-face
                 (ensure-list (get-text-property del 'face full)))
           (memq 'dsh-emacs-tool-diff-add-face
                 (ensure-list (get-text-property add 'face full)))))
    ;; Expanded card rows are drawn on the transcript background and are not
    ;; padded to the box width, so each row ends at its own content.
    (dsh-test-assert "tool-diff-card-rows-are-unpadded"
      (string-match-p "^  - one$" settled)
      (string-match-p "^  \\+ three$" settled)
      (string-match-p "^  src/x\\.el$" settled))))

;; A write keeps its argument-derived whole-file diff when the result records
;; none, and repeated paths get a gap row instead of a second path row.
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (setq-local dsh-emacs-tool-expand-by-default t)
  (dsh-emacs-render-tool-call
   (dsh-emacs-test--tool-call-event
    1 "w1" "write" "{\"file_path\":\"new.txt\",\"content\":\"alpha\\nbeta\"}"))
  (dsh-emacs-render-tool-result
   (dsh-emacs-test--tool-result-event-meta 2 "w1" "created" nil))
  (let* ((ns (dsh-emacs-render--make-namespace))
         (block (dsh-emacs-test--tool-block-text ns "tool-w1")))
    (dsh-test-assert "tool-write-keeps-whole-file-diff"
      (string-match-p "+ alpha" block)
      (string-match-p "+ beta" block)
      (string-match-p (regexp-quote "└ +2 -0 · 1 file") block)
      (not (string-match-p "\"content\"" block))))
  (dsh-emacs-render-tool-call
   (dsh-emacs-test--tool-call-event
    3 "w2" "write" "{\"file_path\":\"a.txt\",\"content\":\"x\"}"))
  (dsh-emacs-render-tool-result
   (dsh-emacs-test--tool-result-event-meta
    4 "w2" "ok"
    '((diffs . [((path . "a.txt") (oldText . "x") (newText . "y"))
                ((path . "a.txt") (oldText . nil) (newText . "z"))
                ((path . "b.txt") (oldText . nil) (newText . "q"))]))))
  (let* ((ns (dsh-emacs-render--make-namespace))
         (block (dsh-emacs-test--tool-block-text ns "tool-w2")))
    (dsh-test-assert "tool-diff-multi-hunk-gap-and-file-count"
      (string-match-p "  ⋯" block)
      (string-match-p "b.txt" block)
      (string-match-p (regexp-quote "└ +3 -1 · 2 files") block))))

;; The diff card declines what dsh web's models decline: an edit that records
;; no diff, a failed call, and inconsistent read metadata all keep the ioCard.
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (setq-local dsh-emacs-tool-expand-by-default t)
  (dsh-emacs-render-tool-call
   (dsh-emacs-test--tool-call-event
    1 "e1" "edit" "{\"file_path\":\"src/y.el\",\"old_string\":\"a\",\"new_string\":\"b\"}"))
  (dsh-emacs-render-tool-result
   (dsh-emacs-test--tool-result-event-meta 2 "e1" "no match found" nil))
  (let* ((ns (dsh-emacs-render--make-namespace))
         (block (dsh-emacs-test--tool-block-text ns "tool-e1")))
    (dsh-test-assert "tool-edit-without-diffs-keeps-iocard"
      (string-match-p "no match found" block)
      (string-match-p "old_string" block)))
  (dsh-emacs-render-tool-call
   (dsh-emacs-test--tool-call-event
    3 "e2" "edit" "{\"file_path\":\"src/z.el\",\"old_string\":\"a\",\"new_string\":\"b\"}"))
  (dsh-emacs-render-tool-result
   (dsh-emacs-test--tool-result-event-meta
    4 "e2" "the file changed on disk" nil t))
  (let* ((ns (dsh-emacs-render--make-namespace))
         (block (dsh-emacs-test--tool-block-text ns "tool-e2")))
    (dsh-test-assert "tool-failed-edit-keeps-iocard"
      (string-match-p "the file changed on disk" block)
      (not (string-match-p "└ +" block))))
  (dsh-emacs-render-tool-call
   (dsh-emacs-test--tool-call-event 5 "r3" "read" "{\"file_path\":\"/a/d.el\"}"))
  (dsh-emacs-render-tool-result
   (dsh-emacs-test--tool-result-event-meta
    6 "r3"
    "<path>/a/d.el</path>\n<type>file</type>\n<content>\n1: a\n2: b\n</content>"
    '((path . "/a/d.el") (offset . 1) (totalLines . 2)
      (lines . [((number . 2) (text . "a"))
                ((number . 2) (text . "b"))]))))
  (let* ((ns (dsh-emacs-render--make-namespace))
         (block (dsh-emacs-test--tool-block-text ns "tool-r3")))
    (dsh-test-assert "tool-read-inconsistent-meta-keeps-iocard"
      (string-match-p "<content>" block)
      (not (string-match-p "Showing" block)))))

;; A failed or interrupted file call keeps its diagnostic output: a
;; specialized card may replace the result text only for a successful call.
;; The Host marks a failure with `isError' and, for an abort, an `interrupted'
;; failure code.
(dolist (case '((error nil) (stopped "interrupted")))
  (dolist (name '("read" "edit" "write"))
    (with-temp-buffer
      (dsh-emacs-mode)
      (setq-local dsh-emacs-tool-expand-by-default t)
      (let* ((state (car case))
             (code (cadr case))
             (meta (if (equal name "read")
                       '((path . "/a") (offset . 1) (totalLines . 1)
                         (lines . [((number . 1) (text . "preview"))]))
                     '((diffs . [((path . "/a") (oldText . "old")
                                  (newText . "preview"))]))))
             (text (if (equal name "read")
                       (concat "<path>/a</path>\n<type>file</type>\n"
                               "<content>\n1: diagnostic output\n</content>")
                     "diagnostic output"))
             (event (dsh-emacs-test--tool-result-event-meta
                     2 "failed-file" text meta t)))
        (when code
          (setf (alist-get "error" (alist-get "data" event nil nil #'equal)
                           nil nil #'equal)
                (list (cons "name" "ToolError") (cons "code" code))))
        (dsh-emacs-render-tool-call
         (dsh-emacs-test--tool-call-event
          1 "failed-file" name
          (concat "{\"file_path\":\"/a\",\"old_string\":\"old\","
                  "\"new_string\":\"preview\",\"content\":\"preview\"}")))
        (dsh-emacs-render-tool-result event)
        (let* ((body (dsh-emacs-test--tool-block-text
                      (dsh-emacs-render--make-namespace) "tool-failed-file"))
               (tracked (plist-get
                         (dsh-emacs-render--tool-state "failed-file") :state)))
          (dsh-test-assert (format "tool-%s-%s-keeps-diagnostics" name state)
            (eq state tracked)
            (string-match-p "diagnostic output" body)
            (string-match-p "file_path" body)
            (not (string-match-p (regexp-quote "└ +") body))
            (not (string-match-p "1  preview" body))))))))

;; dsh's shell renderer writes the exit status into the result text
;; (`[exit code: N]' / `[killed by signal: X]'), not the wire block: a failed
;; command must settle the row as failed, print its footer, and lose the
;; marker from the output instead of duplicating it.
(with-temp-buffer
  (dsh-emacs-mode)
  (setq-local dsh-emacs-tool-expand-by-default t)
  (dsh-emacs-render-tool-call
   (dsh-emacs-test--tool-call-event
    1 "b1" "bash" "{\"command\":\"make\",\"description\":\"build\"}"))
  (dsh-emacs-render-tool-result
   (dsh-emacs-test--tool-result-event
    2 "b1" nil nil "make: *** No rule\n[exit code: 2]"))
  (let ((body (dsh-emacs-test--tool-block-text
               (dsh-emacs-render--make-namespace) "tool-b1")))
    (dsh-test-assert "tool-bash-exit-marker-settles-error"
      (eq 'error (plist-get (dsh-emacs-render--tool-state "b1") :state))
      (string-match-p (regexp-quote "✗ exit 2") body)
      (not (string-match-p (regexp-quote "[exit code: 2]") body)))))

(with-temp-buffer
  (dsh-emacs-mode)
  (setq-local dsh-emacs-tool-expand-by-default t)
  (dsh-emacs-render-tool-call
   (dsh-emacs-test--tool-call-event
    1 "b2" "bash" "{\"command\":\"sleep 60\",\"description\":\"wait\"}"))
  (dsh-emacs-render-tool-result
   (dsh-emacs-test--tool-result-event
    2 "b2" nil nil "waiting\n[killed by signal: SIGTERM]"))
  (let ((body (dsh-emacs-test--tool-block-text
               (dsh-emacs-render--make-namespace) "tool-b2")))
    (dsh-test-assert "tool-bash-signal-marker-settles-error"
      (eq 'error (plist-get (dsh-emacs-render--tool-state "b2") :state))
      (string-match-p (regexp-quote "✗ signal SIGTERM") body)
      (not (string-match-p
            (regexp-quote "[killed by signal: SIGTERM]") body)))))

;; Background-job cards: the Host's trailing `[status: ...]' line becomes a
;; state-colored footer, `job_list' and `job_kill' render their result as
;; rows, and the argument JSON is never repeated (the row header already
;; carries the job id).
(with-temp-buffer
  (dsh-emacs-mode)
  (setq-local dsh-emacs-tool-expand-by-default t)
  (dsh-emacs-render-tool-call
   (dsh-emacs-test--tool-call-event
    1 "j1" "job_output" "{\"job_id\":\"bash-7\",\"wait\":true}"))
  (dsh-emacs-render-tool-result
   (dsh-emacs-test--tool-result-event
    2 "j1" nil nil "step one\nstep two\n[status: running]"))
  (let ((body (dsh-emacs-test--tool-block-text
               (dsh-emacs-render--make-namespace) "tool-j1")))
    (dsh-test-assert "tool-job-output-card"
      (eq 'success (plist-get (dsh-emacs-render--tool-state "j1") :state))
      (string-match-p "step one" body)
      (string-match-p (regexp-quote "[status: running]") body)
      (not (string-match-p "job_id" body))
      (not (string-match-p "^OUT$" body)))))

;; The Host calls an exited background command completed even when its exit
;; code is nonzero.  The footer must distinguish that failure from exit 0.
(dolist (case '(("completed, exit code: 0" dsh-emacs-tool-success-face)
                ("completed, exit code: 2" dsh-emacs-tool-error-face)
                ("completed, exit code: -1" dsh-emacs-tool-error-face)
                ("completed" dsh-emacs-tool-success-face)))
  (with-temp-buffer
    (dsh-emacs-mode)
    (setq-local dsh-emacs-tool-expand-by-default t)
    (dsh-emacs-render-tool-call
     (dsh-emacs-test--tool-call-event
      1 "job-exit" "job_output" "{\"job_id\":\"bash-7\"}"))
    (let ((footer (format "[status: %s]" (car case))))
      (dsh-emacs-render-tool-result
       (dsh-emacs-test--tool-result-event
        2 "job-exit" nil nil (concat "command output\n" footer)))
      (let* ((text (buffer-string))
             (pos (string-match (regexp-quote footer) text)))
        (dsh-test-assert (format "tool-job-output-footer-%s" (car case))
          (and pos
               (memq (cadr case)
                     (ensure-list (get-text-property pos 'face text)))))))))

(with-temp-buffer
  (dsh-emacs-mode)
  (setq-local dsh-emacs-tool-expand-by-default t)
  (dsh-emacs-render-tool-call
   (dsh-emacs-test--tool-call-event 1 "j2" "job_list" "{}"))
  (dsh-emacs-render-tool-result
   (dsh-emacs-test--tool-result-event
    2 "j2" nil nil
    (concat "bash-7 [bash] running — make build\n"
            "bash-2 [bash] completed — cat > x.sh <<'PY'\necho hi")))
  (let ((body (dsh-emacs-test--tool-block-text
               (dsh-emacs-render--make-namespace) "tool-j2")))
    (dsh-test-assert "tool-job-list-card"
      (string-match-p "bash-7 \\[bash\\] running — make build" body)
      (string-match-p "bash-2 \\[bash\\] completed — cat > x.sh" body)
      ;; A multi-line label stays indented under its job row.
      (string-match-p "^    echo hi$" body)
      (not (string-match-p "^OUT$" body)))))

(with-temp-buffer
  (dsh-emacs-mode)
  (setq-local dsh-emacs-tool-expand-by-default t)
  (dsh-emacs-render-tool-call
   (dsh-emacs-test--tool-call-event
    1 "j3" "job_kill" "{\"reason\":\"stale\",\"job_id\":\"bash-7\"}"))
  (dsh-test-assert "tool-job-kill-pending-summary-prefers-id"
    (equal "bash-7" (plist-get (dsh-emacs-render--tool-state "j3") :summary)))
  (dsh-emacs-render-tool-result
   (dsh-emacs-test--tool-result-event
    2 "j3" nil nil "requested cancellation of job bash-7"))
  (let ((body (dsh-emacs-test--tool-block-text
               (dsh-emacs-render--make-namespace) "tool-j3")))
    (dsh-test-assert "tool-job-kill-card"
      (string-match-p "requested cancellation of job bash-7" body)
      (string-match-p "bash-7" (dsh-emacs-render--first-line body))
      (not (string-match-p "reason" body))
      (not (string-match-p "^OUT$" body)))))

;; A `job_output' failure carries no status line; the generic card keeps the
;; diagnostic text and the argument JSON that names the job.
(with-temp-buffer
  (dsh-emacs-mode)
  (setq-local dsh-emacs-tool-expand-by-default t)
  (dsh-emacs-render-tool-call
   (dsh-emacs-test--tool-call-event
    1 "j4" "job_output" "{\"job_id\":\"nope\"}"))
  (dsh-emacs-render-tool-result
   (dsh-emacs-test--tool-result-event 2 "j4" t 1 "unknown job id nope"))
  (let ((body (dsh-emacs-test--tool-block-text
               (dsh-emacs-render--make-namespace) "tool-j4")))
    (dsh-test-assert "tool-job-output-without-status-keeps-iocard"
      (eq 'error (plist-get (dsh-emacs-render--tool-state "j4") :state))
      (string-match-p "unknown job id nope" body)
      (string-match-p "job_id" body)
      (string-match-p "^  OUT unknown job id nope$" body))))

;; A `present' row names the files it declared in the header (web PresentRow)
;; and shows the result text as its body; the argument JSON is never repeated.
(with-temp-buffer
  (dsh-emacs-mode)
  (setq-local dsh-emacs-tool-expand-by-default t)
  (dsh-emacs-render-tool-call
   (dsh-emacs-test--tool-call-event
    1 "p1" "present"
    (concat "{\"files\":[{\"path\":\"report.md\","
            "\"description\":\"Final report\"},{\"path\":\"notes.txt\"}]}")))
  (dsh-test-assert "tool-present-summary-names-paths"
    (equal "report.md, notes.txt"
           (plist-get (dsh-emacs-render--tool-state "p1") :summary)))
  (dsh-emacs-render-tool-result
   (dsh-emacs-test--tool-result-event
    2 "p1" nil nil "Presented report.md\nPresented notes.txt"))
  (let ((body (dsh-emacs-test--tool-block-text
               (dsh-emacs-render--make-namespace) "tool-p1")))
    (dsh-test-assert "tool-present-card"
      (string-match-p "Present files" body)
      (string-match-p "report.md, notes.txt" body)
      (string-match-p "Presented report.md" body)
      (string-match-p "Presented notes.txt" body)
      (not (string-match-p "\"files\"" body))
      (not (string-match-p "^OUT$" body)))))

;; A failed `present' keeps the Host's message and the declared-path summary.
(with-temp-buffer
  (dsh-emacs-mode)
  (setq-local dsh-emacs-tool-expand-by-default t)
  (dsh-emacs-render-tool-call
   (dsh-emacs-test--tool-call-event
    1 "p2" "present" "{\"files\":[{\"path\":\"missing.txt\"}]}"))
  (dsh-emacs-render-tool-result
   (dsh-emacs-test--tool-result-event
    2 "p2" t 1 "Cannot present missing.txt: not a regular file"))
  (let ((body (dsh-emacs-test--tool-block-text
               (dsh-emacs-render--make-namespace) "tool-p2")))
    (dsh-test-assert "tool-present-failure-keeps-diagnostic"
      (eq 'error (plist-get (dsh-emacs-render--tool-state "p2") :state))
      (string-match-p "Cannot present missing.txt" body)
      (string-match-p "missing.txt" (dsh-emacs-render--first-line body))
      (not (string-match-p "\"files\"" body))
      (not (string-match-p "^OUT$" body)))))

;; Metadata line numbers before the declared offset invalidate the window.
;; The raw output must survive rather than being replaced by unrelated lines.
(with-temp-buffer
  (dsh-emacs-mode)
  (setq-local dsh-emacs-tool-expand-by-default t)
  (dsh-emacs-render-tool-call
   (dsh-emacs-test--tool-call-event
    1 "bad-window" "read" "{\"file_path\":\"/a\",\"offset\":10}"))
  (dsh-emacs-render-tool-result
   (dsh-emacs-test--tool-result-event-meta
    2 "bad-window"
    "<path>/a</path>\n<type>file</type>\n<content>\n10: actual window\n</content>"
    '((path . "/a") (offset . 10) (totalLines . 20)
      (lines . [((number . 1) (text . "wrong window"))]))))
  (let ((body (dsh-emacs-test--tool-block-text
               (dsh-emacs-render--make-namespace) "tool-bad-window")))
    (dsh-test-assert "tool-read-before-offset-keeps-raw-output"
      (string-match-p "10: actual window" body)
      (string-match-p "file_path" body)
      (not (string-match-p "wrong window" body)))))

;; A host with a raised read byte cap can return a large, valid envelope.
;; Rendering must complete without consuming regexp stack per character.
(with-temp-buffer
  (dsh-emacs-mode)
  (setq-local dsh-emacs-tool-expand-by-default t)
  (let* ((line (make-string 1000 ?x))
         (lines (vconcat
                 (cl-loop for n from 1 to 150
                          collect (list (cons 'number n) (cons 'text line)))))
         (text (concat
                "<path>/large.txt</path>\n<type>file</type>\n<content>\n"
                (mapconcat (lambda (cell)
                             (format "%d: %s" (alist-get 'number cell)
                                     (alist-get 'text cell)))
                           lines "\n")
                "\n\n(End of file - total 150 lines)\n</content>"))
         (meta `((path . "/large.txt") (offset . 1) (totalLines . 150)
                 (lines . ,lines))))
    (dsh-emacs-render-tool-call
     (dsh-emacs-test--tool-call-event
      1 "large-read" "read" "{\"file_path\":\"/large.txt\"}"))
    (condition-case err
        (progn
          (dsh-emacs-render-tool-result
           (dsh-emacs-test--tool-result-event-meta 2 "large-read" text meta))
          (let ((body (dsh-emacs-test--tool-block-text
                       (dsh-emacs-render--make-namespace) "tool-large-read")))
            (dsh-test-assert "tool-large-read-completes-numbered-card"
              (eq 'success (plist-get
                            (dsh-emacs-render--tool-state "large-read") :state))
              (string-match-p (concat "  150  " line) body)
              (not (string-match-p "<content>" body)))))
      (error (dsh-test-fail "tool-large-read-completes-numbered-card"
                            (error-message-string err))))))

;; Checking the envelope ends separately still rejects non-file results,
;; truncated envelopes, trailing output, and overlapping opening/closing tags.
;; Cases carry a short label: interpolating the multi-line result itself would
;; break the one-line-per-assertion output.
(dolist (case '(("directory-type" . "<path>/a</path>\n<type>directory</type>\n<content>\nx\n</content>")
                ("no-path-tag" . "<type>file</type>\n<content>\nx\n</content>")
                ("truncated" . "<path>/a</path>\n<type>file</type>\n<content>\nx")
                ("trailing-output" . "<path>/a</path>\n<type>file</type>\n<content>\nx\n</content>extra")
                ("overlapping-tags" . "<path>/a</path>\n<type>file</type>\n<content>\n</content>")))
  (dsh-test-assert (format "tool-read-rejects-envelope-%s" (car case))
    (null (dsh-emacs-render--read-card-body
           "read" "{\"file_path\":\"/a\"}"
           '((path . "/a") (offset . 1) (totalLines . 1)
             (lines . [((number . 1) (text . "x"))]))
           (cdr case)))))

;; A malformed result body must not signal out of the renderer either: a
;; non-array `content', or an array whose members are not objects, settles the
;; call with no usable result text instead of raising `sequencep'.
(dolist (content '(42 "invalid" [42] [[]] t))
  (with-temp-buffer
    (dsh-emacs-mode)
    (setq-local dsh-emacs-tool-expand-by-default t)
    (dsh-emacs-render-tool-call
     (dsh-emacs-test--tool-call-event
      1 "bad-content" "bash" "{\"command\":\"ls\"}"))
    (let ((label (format "tool-malformed-content-%S" content)))
      (condition-case err
          (progn
            (dsh-emacs-render-tool-result
             (dsh-emacs-test--tool-result-event-bare 2 "bad-content" content))
            ;; The event carries no usable tool-result block, so the call still
            ;; settles, with no result text to show.
            (dsh-test-assert label
              (let ((state (dsh-emacs-render--tool-state "bad-content")))
                (and (eq 'success (plist-get state :state))
                     (equal "" (or (plist-get state :result) ""))))))
        (error (dsh-test-fail label (error-message-string err)))))))

;; Malformed metadata must not leave a completed tool pending.  Exercise
;; non-object metadata and non-object array members through the result path.
(dolist (name '("read" "edit" "write"))
  (dolist (bad '(42 t :json-false "invalid" [42]))
    (dolist (nested '(nil t))
      (with-temp-buffer
        (dsh-emacs-mode)
        (setq-local dsh-emacs-tool-expand-by-default t)
        (let* ((read-p (equal name "read"))
               (meta (if (not nested) bad
                       (if read-p
                           `((path . "/a.txt") (offset . 1) (totalLines . 1)
                             (lines . ,(vector bad)))
                         `((diffs . ,(vector bad))))))
               (text (if read-p
                         (concat "<path>/a.txt</path>\n<type>file</type>\n"
                                 "<content>\n1: actual\n</content>")
                       "completed mutation"))
               (label (format "tool-%s-malformed-meta-%S-nested-%S"
                              name bad nested)))
          (dsh-emacs-render-tool-call
           (dsh-emacs-test--tool-call-event
            1 "bad-meta" name
            (concat "{\"file_path\":\"/a.txt\",\"old_string\":\"old\","
                    "\"new_string\":\"new\",\"content\":\"written\"}")))
          (condition-case err
              (progn
                (dsh-emacs-render-tool-result
                 (dsh-emacs-test--tool-result-event-meta 2 "bad-meta" text meta))
                (let ((body (dsh-emacs-test--tool-block-text
                             (dsh-emacs-render--make-namespace) "tool-bad-meta")))
                  (dsh-test-assert label
                    (eq 'success (plist-get
                                  (dsh-emacs-render--tool-state "bad-meta") :state))
                    (if (equal name "write")
                        (string-match-p (regexp-quote "+ written") body)
                      (and (string-match-p
                            (if read-p "1: actual" "completed mutation") body)
                           (string-match-p "file_path" body))))))
            (error (dsh-test-fail label (error-message-string err)))))))))

;; A hunk's line split matches dsh web's `wo': one trailing newline is markup,
;; a further empty line is a real line.
(dsh-test-assert "diff-lines-drop-one-trailing-newline"
  (null (dsh-emacs-render--diff-lines ""))
  (equal '("a") (dsh-emacs-render--diff-lines "a\n"))
  (equal '("a" "") (dsh-emacs-render--diff-lines "a\n\n"))
  (equal '("a" "" "b") (dsh-emacs-render--diff-lines "a\n\nb")))

;; --- Test 30: blank tool results hide the OUT section ---
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (setq-local dsh-emacs-tool-expand-by-default t)
  (dsh-emacs-render-tool-call
   (dsh-emacs-test--tool-call-event 1 "c3" "read" "{\"path\":\"/a/b.txt\"}"))
  (dsh-emacs-render-tool-result
   (dsh-emacs-test--tool-result-event 2 "c3" nil 0 ""))
  (let* ((ns (dsh-emacs-render--make-namespace))
         (block (dsh-emacs-test--tool-block-text ns "tool-c3")))
    (when (and block
               (string-match-p "IN" block)
               (not (string-match-p "OUT" block)))
      (dsh-test-pass "tool-no-output-hides-OUT-section"))))

;; --- Test 31: collapsed tool lines are compact (no ellipsis/blank) + expanding
;; restores the bash terminal card ---
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  ;; Keeps the default collapsed state (expand-by-default is unbound)
  (dsh-emacs-render-tool-call
   (dsh-emacs-test--tool-call-event 1 "x1" "bash" "{\"description\":\"list\",\"command\":\"ls\"}"))
  (dsh-emacs-render-tool-result
   (dsh-emacs-test--tool-result-event 2 "x1" nil 0 "file-a"))
  (let* ((ns (dsh-emacs-render--make-namespace))
         (block (dsh-emacs-test--tool-block-text ns "tool-x1")))
    (when (and block
               ;; When collapsed it is a single line: it has the header, no ellipsis
               ;; placeholder,
               ;; no card body
               (string-match-p "Bash" block)
               (not (string-match-p (regexp-quote "$ ls") block))
               (not (string-match-p "IN" block))
               (not (string-match-p "OUT" block))
               (string-match-p "list" block))
      (dsh-test-pass "tool-collapsed-single-line"))
    ;; Expanding should restore the terminal card body ($ prompt line + output; no
    ;; ✓ footer on a clean exit), and collapsing again returns to a single line
    (dsh-emacs-ui-toggle-fragment)
    (let* ((expanded (dsh-emacs-test--tool-block-text ns "tool-x1")))
      (when (and expanded
                 (string-match-p (regexp-quote "$ ls") expanded)
                 (string-match-p "file-a" expanded)
                 (not (string-match-p (regexp-quote "✓ exit 0") expanded))
                 (not (string-match-p "IN" expanded)))
        (dsh-test-pass "tool-bash-expand-restores-terminal-card"))
      (dsh-emacs-ui-toggle-fragment)
      (let ((recollapsed (dsh-emacs-test--tool-block-text ns "tool-x1")))
        (when (and recollapsed
                   (not (string-match-p (regexp-quote "$ ls") recollapsed))
                   (string-match-p "Bash" recollapsed))
          (dsh-test-pass "tool-recollapse-single-line"))))))

;; --- Test 31b: the generic ioCard is one aligned block — both labels share a
;; column, the IN value is flattened to a single row, OUT keeps its lines
;; hanging at the text column under a content-sized divider, and a clean
;; success prints no status line ---
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (setq-local dsh-emacs-tool-expand-by-default t)
  (dsh-emacs-render-tool-call
   (dsh-emacs-test--tool-call-event 1 "g1" "my_tool" "{\"x\":\"1\"}"))
  (dsh-emacs-render-tool-result
   (dsh-emacs-test--tool-result-event 2 "g1" nil nil "ok\nsecond line"))
  (let ((block (dsh-emacs-test--tool-block-text
                (dsh-emacs-render--make-namespace) "tool-g1")))
    (dsh-test-assert "tool-io-in-is-one-row"
      (string-match-p "^  IN  { \"x\": \"1\" }$" block))
    (dsh-test-assert "tool-io-out-hangs-under-its-column"
      (string-match-p "^  OUT ok$" block)
      (string-match-p "^      second line$" block))
    (dsh-test-assert "tool-io-divider-and-success-has-no-status-line"
      (string-match-p "^  ─\\{4,\\}$" block)
      (not (string-match-p (regexp-quote "✓ exit 0") block)))))

;; --- Test 31c: a zero-argument generic call drops the empty IN section and
;; keeps its input out of the header entirely ---
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (setq-local dsh-emacs-tool-expand-by-default t)
  (dsh-emacs-render-tool-call
   (dsh-emacs-test--tool-call-event 1 "g2" "dev_injected_list" "{}"))
  (dsh-emacs-render-tool-result
   (dsh-emacs-test--tool-result-event 2 "g2" nil nil "（无注入记录）"))
  (let* ((block (dsh-emacs-test--tool-block-text
                 (dsh-emacs-render--make-namespace) "tool-g2"))
         (header (dsh-emacs-render--first-line block)))
    (dsh-test-assert "tool-io-empty-args-hide-IN"
      (not (string-match-p "^  IN" block)))
    (dsh-test-assert "tool-generic-header-hides-empty-input"
      (string-match-p "✨ Tool Call · dev_injected_list$" header)
      (not (string-match-p "{}" header))
      (string-match-p "^  OUT （无注入记录）$" block))))

;; --- Test 31e: a known-variant row whose arguments yield no summary still
;; falls back to the result preview in the header ---
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (dsh-emacs-render-tool-call
   (dsh-emacs-test--tool-call-event 1 "g4" "glob" "{}"))
  (dsh-emacs-render-tool-result
   (dsh-emacs-test--tool-result-event 2 "g4" nil nil "alpha.md\nbeta.md"))
  (let ((block (dsh-emacs-test--tool-block-text
                (dsh-emacs-render--make-namespace) "tool-g4")))
    (dsh-test-assert "tool-known-variant-result-preview-summary"
      (string-match-p "🔍 Glob · alpha.md …" block))))

;; --- Test 31d: a failed generic call keeps its status line above the block ---
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (setq-local dsh-emacs-tool-expand-by-default t)
  (dsh-emacs-render-tool-call
   (dsh-emacs-test--tool-call-event 1 "g3" "dev_plugin_status" "{}"))
  (dsh-emacs-render-tool-result
   (dsh-emacs-test--tool-result-event 2 "g3" t 1 "boom"))
  (let ((block (dsh-emacs-test--tool-block-text
                (dsh-emacs-render--make-namespace) "tool-g3")))
    (dsh-test-assert "tool-io-failure-keeps-status-line"
      (string-match-p (regexp-quote "✗ exit 1") block)
      (string-match-p "^  OUT boom$" block))))

;; --- Test 31f: an ask row renders dsh web's question card — the questions
;; and their numbered options with descriptions replace the argument JSON, and
;; the settled answers check the chosen options and carry free-text answers ---
(defconst dsh-emacs-test--ask-args
  (json-encode
   '((questions . [((id . "q1") (header . "Layout")
                    (question . "Which layout?")
                    (options . [((label . "Stacked")
                                 (description . "Classic rhythm."))
                                ((label . "Compact"))])
                    (multi_select . :json-false))
                   ((id . "q2") (question . "Which details?")
                    (options . [((label . "Chip"))])
                    (multi_select . t))])))
  "Wire arguments of a two-question `ask_user_question' call.")

(dsh-test-assert "ask-tool-uses-question-variant"
  (equal "question" (car (dsh-emacs-render--tool-variant "ask_user_question")))
  (equal "❓" (cdr (assoc "question" dsh-emacs--variant-icons)))
  (stringp (cdr (assoc "question" dsh-emacs--tool-icon-svgs))))

(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (setq-local dsh-emacs-tool-expand-by-default t)
  (dsh-emacs-render-tool-call
   (dsh-emacs-test--tool-call-event 1 "k1" "ask_user_question"
                                    dsh-emacs-test--ask-args))
  (let ((block (dsh-emacs-test--tool-block-text
                (dsh-emacs-render--make-namespace) "tool-k1")))
    (dsh-test-assert "ask-pending-card-shows-questionnaire"
      (string-match-p "Ask question · waiting" block)
      (string-match-p "^  Q1 · Layout — Which layout\\?$" block)
      (string-match-p "^  Q2 · Which details\\?$" block)
      (string-match-p "^   1\\.   Stacked$" block)
      (string-match-p "^        Classic rhythm\\.$" block)
      (string-match-p "^   1\\.   Chip$" block)
      (not (string-match-p "^  IN" block))
      (not (string-match-p "^  OUT" block)))))

(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (setq-local dsh-emacs-tool-expand-by-default t)
  (dsh-emacs-render-tool-call
   (dsh-emacs-test--tool-call-event 1 "k2" "ask_user_question"
                                    dsh-emacs-test--ask-args))
  (dsh-emacs-render-tool-result
   (dsh-emacs-test--tool-result-event
    2 "k2" nil 0
    (json-encode '((answers . [((id . "q1") (selected . ["Stacked"]))
                               ((id . "q2") (selected . [])
                                (custom . "and a summary"))])))))
  (let ((block (dsh-emacs-test--tool-block-text
                (dsh-emacs-render--make-namespace) "tool-k2")))
    (dsh-test-assert "ask-answered-card-marks-choices-and-free-text"
      (string-match-p "Ask question · 2/2 answered" block)
      (string-match-p "^   1\\. ✓ Stacked$" block)
      (string-match-p "^   2\\.   Compact$" block)
      (string-match-p "^  → and a summary$" block))))

(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (setq-local dsh-emacs-tool-expand-by-default t)
  (dsh-emacs-render-tool-call
   (dsh-emacs-test--tool-call-event 1 "k3" "ask_user_question"
                                    dsh-emacs-test--ask-args))
  (dsh-emacs-render-tool-result
   (dsh-emacs-test--tool-result-event
    2 "k3" nil 0
    (json-encode '((answers . [((id . "q1") (selected . []))])))))
  (let ((block (dsh-emacs-test--tool-block-text
                (dsh-emacs-render--make-namespace) "tool-k3")))
    (dsh-test-assert "ask-settled-empty-question-reads-not-answered"
      ;; The total is the answer document's own length, like dsh web.
      (string-match-p "Ask question · 0/1 answered" block)
      (string-match-p "^  Not answered$" block))))

;; An abandoned ask is the user's own decision: the row interrupts instead of
;; failing red, like dsh web's ASK_ABORTED state.
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (setq-local dsh-emacs-tool-expand-by-default t)
  (dsh-emacs-render-tool-call
   (dsh-emacs-test--tool-call-event 1 "k4" "ask_user_question"
                                    dsh-emacs-test--ask-args))
  (dsh-emacs-render-tool-result
   (dsh-emacs-test--tool-result-event
    2 "k4" t nil "Error: ask_user_question was aborted before the user answered"
    '((name . "UserQuestionError") (code . "ASK_ABORTED")
      (reason . "User abandoned the questions"))))
  (let ((block (dsh-emacs-test--tool-block-text
                (dsh-emacs-render--make-namespace) "tool-k4")))
    (dsh-test-assert "ask-aborted-row-interrupts-instead-of-failing"
      (string-match-p "◐ Ask question · interrupted" block)
      (string-match-p
       (regexp-quote
        "This question set was interrupted before answers were submitted.")
       block)
      (not (string-match-p (regexp-quote "✗ failed") block)))))

;; A dismissed ask (ASK_CANCELLED) is the user's own decision too: the row
;; settles green with the outcome, and the questionnaire stays as the record.
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (setq-local dsh-emacs-tool-expand-by-default t)
  (dsh-emacs-render-tool-call
   (dsh-emacs-test--tool-call-event 1 "k8" "ask_user_question"
                                    dsh-emacs-test--ask-args))
  (dsh-emacs-render-tool-result
   (dsh-emacs-test--tool-result-event
    2 "k8" t nil "the user cancelled ask_user_question"
    '((name . "UserQuestionError") (code . "ASK_CANCELLED")
      (reason . "the user cancelled ask_user_question"))))
  (let ((block (dsh-emacs-test--tool-block-text
                (dsh-emacs-render--make-namespace) "tool-k8")))
    (dsh-test-assert "ask-cancelled-row-settles-instead-of-failing"
      (string-match-p "Ask question · cancelled" block)
      (string-match-p "^  Q1 · Layout — Which layout\\?$" block)
      (string-match-p
       (regexp-quote
        "This question set was cancelled before answers were submitted.")
       block)
      (not (string-match-p (regexp-quote "✗ failed") block)))))

;; A malformed option element (a string or a number where the wire promised
;; an object) is dropped at the protocol boundary: the question still renders
;; and nothing signals out of the event stream.
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (setq-local dsh-emacs-tool-expand-by-default t)
  (dsh-emacs-render-tool-call
   (dsh-emacs-test--tool-call-event
    1 "k7" "ask_user_question"
    "{\"questions\":[{\"id\":\"q1\",\"header\":\"Layout\",\"question\":\"Which?\",\"options\":[\"Yes\",42,{\"label\":\"Stacked\"}]}]}"))
  (let ((block (dsh-emacs-test--tool-block-text
                (dsh-emacs-render--make-namespace) "tool-k7")))
    (dsh-test-assert "ask-malformed-option-elements-are-dropped"
      (string-match-p "Ask question · waiting" block)
      (string-match-p "^  Layout — Which\\?$" block)
      (string-match-p "^   1\\.   Stacked$" block)
      (not (string-match-p "Yes" block)))))

;; A call the ask card cannot describe (no usable questions) keeps the ioCard.
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (setq-local dsh-emacs-tool-expand-by-default t)
  (dsh-emacs-render-tool-call
   (dsh-emacs-test--tool-call-event 1 "k5" "ask_user_question" "{}"))
  (dsh-emacs-render-tool-result
   (dsh-emacs-test--tool-result-event 2 "k5" nil 0 "no questions given"))
  (let ((block (dsh-emacs-test--tool-block-text
                (dsh-emacs-render--make-namespace) "tool-k5")))
    (dsh-test-assert "ask-unusable-arguments-keep-the-iocard"
      (string-match-p "^  OUT no questions given$" block))))

;; A malformed question element (a string or a number where the wire promised
;; an object) must decline instead of signalling out of the event stream.
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (setq-local dsh-emacs-tool-expand-by-default t)
  (dsh-emacs-render-tool-call
   (dsh-emacs-test--tool-call-event 1 "k6" "ask_user_question"
                                    "{\"questions\":[\"oops\",42,null]}"))
  (let ((block (dsh-emacs-test--tool-block-text
                (dsh-emacs-render--make-namespace) "tool-k6")))
    (dsh-test-assert "ask-malformed-question-elements-keep-the-iocard"
      (string-match-p "Ask question" block)
      (string-match-p "oops" block)
      (not (string-match-p "Q1" block)))))

;; Collapsed snapshots retain complete content and faces across repeated folds.
(dolist (style '(minimal rounded sharp))
  (with-temp-buffer
    (let ((model (dsh-emacs-ui-make-fragment
                  :namespace-id "fold" :block-id "a" :style style
                  :label-left "Title" :body "before"
                  :body-face 'dsh-emacs-tool-success-face
                  :header-face 'dsh-emacs-thinking-face)))
      (dsh-emacs-ui-update-fragment model)
      (setf (alist-get :body model)
            (propertize "after\nsecond" 'face 'italic 'help-echo "body help"))
      (dsh-emacs-ui-update-fragment model :expanded t)
      (dsh-test-assert (format "fragment-update-preserves-fold-%s" style)
        (map-elt (get-text-property (point-min) 'dsh-emacs-ui-state) :collapsed)
        (not (string-match-p "second" (buffer-string))))
      (dotimes (_ 2)
        (goto-char (point-min))
        (dsh-emacs-ui-toggle-fragment)
        (goto-char (point-min))
        (search-forward "second")
        (let ((faces (get-text-property (1- (point)) 'face)))
          (dsh-test-assert (format "fragment-expand-content-faces-%s" style)
            (memq 'italic faces)
            (memq 'dsh-emacs-tool-success-face faces)
            (not (memq 'dsh-emacs-thinking-face faces))
            (equal (get-text-property (1- (point)) 'help-echo) "body help")
            (memq 'dsh-emacs-thinking-face
                  (get-text-property (+ (point-min) 3) 'face))))
        (goto-char (point-min))
        (dsh-emacs-ui-toggle-fragment)))))

;; Fragment faces are region-scoped: :header-face never reaches the expanded
;; body and :body-face never tints the header, for any border style.  This is
;; the general invariant behind the Think/tool-card body-tint fixes.
(dolist (style '(minimal rounded sharp))
  (with-temp-buffer
    (dsh-emacs-ui-update-fragment
     (dsh-emacs-ui-make-fragment
      :namespace-id "scope" :block-id (format "sc-%s" style) :style style
      :label-left "Head" :label-right "Sum" :body "Body line"
      :header-face 'underline :body-face 'italic)
     :create-new t :expanded t)
    (goto-char (point-min))
    (dsh-test-assert (format "fragment-header-face-scoped-%s" style)
      (and (search-forward "Head" nil t)
           (memq 'underline (dsh-test--faces-at (match-beginning 0)))
           (not (memq 'italic (dsh-test--faces-at (match-beginning 0))))
           ;; the left label is the title and keeps the title face
           (memq 'dsh-emacs-ui-label-face
                 (dsh-test--faces-at (match-beginning 0)))))
    ;; the right label is a summary: header face but never the title face
    (goto-char (point-min))
    (dsh-test-assert (format "fragment-summary-keeps-title-face-off-%s" style)
      (and (search-forward "Sum" nil t)
           (memq 'underline (dsh-test--faces-at (match-beginning 0)))
           (not (memq 'dsh-emacs-ui-label-face
                      (dsh-test--faces-at (match-beginning 0))))))
    (goto-char (point-min))
    (dsh-test-assert (format "fragment-body-face-scoped-%s" style)
      (and (search-forward "Body line" nil t)
           (memq 'italic (dsh-test--faces-at (match-beginning 0)))
           (not (memq 'underline (dsh-test--faces-at (match-beginning 0))))))
    ;; The border chrome is neither region: a face attribute on the body must
    ;; not reach the bottom rule either.
    (unless (eq style 'minimal)
      (goto-char (point-max))
      (dsh-test-assert (format "fragment-border-keeps-own-face-%s" style)
        (and (search-backward "─" nil t)
             (not (memq 'italic (dsh-test--faces-at (match-beginning 0)))))))))

;; --- Test 32: tool name decoupled from icon — same icon, different name ---
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (dsh-emacs-render-tool-call
   (dsh-emacs-test--tool-call-event 1 "g1" "grep" "{\"pattern\":\"foo\"}"))
  (let* ((ns (dsh-emacs-render--make-namespace))
         (block (dsh-emacs-test--tool-block-text ns "tool-g1")))
    (when (and block
               (string-match-p "🔍 Grep" block)      ; magnifier icon + real tool name
               (not (string-match-p "Search" block)) ; must no longer render as Search
               (not (string-match-p "· Search" block)))
      (dsh-test-pass "tool-grep-title-distinct-from-search"))))

(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (dsh-emacs-render-tool-call
   (dsh-emacs-test--tool-call-event 1 "w1" "web_search" "{\"query\":\"cats\"}"))
  (let* ((ns (dsh-emacs-render--make-namespace))
         (block (dsh-emacs-test--tool-block-text ns "tool-w1")))
    (when (and block
               (string-match-p "🌐 Web Search" block)
               (not (string-match-p "🌐 Search · cats" block)))
      (dsh-test-pass "tool-web-search-title-keeps-globe-icon"))))

;; web_search's SVG icon is overridden to a globe (harness WebRow: globe for web
;; search, magnifier family for grep/glob), and it differs from the search
;; variant's magnifier
(when (and (string= (cdr (assoc "web_search" dsh-emacs--tool-name-icon-keys)) "web")
           (string-match-p "fill-rule=\"evenodd\""
                           (dsh-emacs-render--tool-icon-svg "search" "#a78bfa" "web_search"))
           (not (string-equal
                 (dsh-emacs-render--tool-icon-svg "search" "#a78bfa" "web_search")
                 (dsh-emacs-render--tool-icon-svg "search" "#a78bfa"))))
  (dsh-test-pass "tool-web-search-globe-svg-override"))

(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (setq-local dsh-emacs-tool-expand-by-default t)
  (dsh-emacs-render-tool-call
   (dsh-emacs-test--tool-call-event 1 "u1" "my_tool" "{\"x\":\"1\"}"))
  (dsh-emacs-render-tool-result
   (dsh-emacs-test--tool-result-event 2 "u1" nil nil "ok"))
  (let* ((ns (dsh-emacs-render--make-namespace))
         (block (dsh-emacs-test--tool-block-text ns "tool-u1"))
         (header (dsh-emacs-render--first-line block)))
    (dsh-test-assert "tool-generic-header-is-tool-call-name"
      (string-match-p "✨ Tool Call · my_tool$" header)
      (not (string-match-p "{\"x\"" header)))
    (dsh-test-assert "tool-generic-input-only-when-expanded"
      (string-match-p "^  IN  { \"x\": \"1\" }$" block))))

;; A curated title still owns the row (present / job rows keep their documented
;; headers and summaries) and is not rewritten to the generic format.
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (let ((dsh-emacs-tool-titles '(("my_tool" . "Curated")))) ; defcustom override
    (dsh-emacs-render-tool-call
     (dsh-emacs-test--tool-call-event 1 "u2" "my_tool" "{\"x\":\"1\"}")))
  (let* ((ns (dsh-emacs-render--make-namespace))
         (block (dsh-emacs-test--tool-block-text ns "tool-u2")))
    (dsh-test-assert "tool-title-defcustom-override"
      (string-match-p "✨ Curated" block)
      (not (string-match-p "Tool Call" block)))))

;; --- Test 33: adjacent tool lines stack compactly (no extra blank lines) ---
(defun dsh-emacs-test--t32-call (seq id name args)
  (list (cons "type" "tool/call") (cons "seq" seq)
        (cons "data" (list (cons "callId" id) (cons "name" name)
                           (cons "arguments" args)))))
(defun dsh-emacs-test--t32-result (seq id text)
  (list (cons "type" "tool/result") (cons "seq" seq)
        (cons "data" (list (cons "message"
                                 (list (cons "callId" id)
                                       (cons "content"
                                             (vector (list (cons "type" "tool-result")
                                                           (cons "isError" :json-false)
                                                           (cons "exitCode" 0)
                                                           (cons "content"
                                                                 (vector (list (cons "type" "text")
                                                                               (cons "text" text)))))))))))))
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (dsh-emacs-render-tool-call
   (dsh-emacs-test--t32-call 1 "y1" "search" "{\"query\":\"*.md\"}"))
  (dsh-emacs-render-tool-result (dsh-emacs-test--t32-result 2 "y1" "a"))
  (dsh-emacs-render-tool-call
   (dsh-emacs-test--t32-call 3 "y2" "read" "{\"path\":\"/tmp/x\"}"))
  (dsh-emacs-render-tool-result (dsh-emacs-test--t32-result 4 "y2" "b"))
  (when-let* ((line-search (save-excursion
                             (goto-char (point-min))
                             (when (search-forward "Search" nil t)
                               (line-number-at-pos (match-beginning 0)))))
              (line-read (save-excursion
                           (goto-char (point-min))
                           (when (search-forward "Read" nil t)
                             (line-number-at-pos (match-beginning 0))))))
    ;; Two collapsed tools should occupy two adjacent lines (no blank line or ellipsis
    ;; placeholder in between)
    (when (= line-read (1+ line-search))
      (dsh-test-pass "tool-adjacent-stack-tight"))))

;; --- Test 33: cursor locked to the editable input area ---
(with-temp-buffer
  (dsh-emacs-mode)
  (let ((inhibit-read-only t))
    (save-excursion
      (goto-char (point-min))
      (insert "user  hello\n")
      (put-text-property (point-min) (1- (point)) 'read-only t)))
  (let ((dsh-emacs--current-buffer (current-buffer)))
    (dsh-emacs--ensure-input-marker)
    (let ((mpos (marker-position dsh-emacs--input-marker)))
      ;; Moving up into the read-only transcript to read → should be allowed (the cursor
      ;; stays put)
      (goto-char (point-min))
      (dsh-emacs--lock-cursor-to-input)
      (when (= (point) (point-min))
        (dsh-test-pass "cursor-can-move-up-into-history"))
      ;; Cursor trying to move below the input area → should be clamped to the input
      ;; area end
      (goto-char (point-max))
      (dsh-emacs--lock-cursor-to-input)
      (let ((input-end (dsh-emacs--input-end)))
        (when (>= (point) mpos)
          (dsh-test-pass "cursor-cannot-move-below-input"))))
    ;; Typing directly from the read-only history area → should be routed back to the
    ;; input area (avoids text-read-only)
    (let ((this-command 'self-insert-command))
      (goto-char (point-min))
      (dsh-emacs--route-typing-to-input)
      (when (= (point) (marker-position dsh-emacs--input-marker))
        (dsh-test-pass "typing-in-history-routes-to-input")))))

;; --- Test 33b: cursor clamped at the bottom of the input area — multi-line
;; input is unaffected, and it is independent of the global current-buffer (with
;; multiple sessions, that points at the last opened session) ---
(let* ((chat (get-buffer-create " *t33b-chat*"))
       (other (generate-new-buffer " *t33b-other*")))
  (unwind-protect
      (progn
        (with-current-buffer chat
          (dsh-emacs-mode)
          (dsh-emacs-modeline-setup)
          ;; Simulates multiple sessions: the global current-buffer points at another
          ;; session
          (setq dsh-emacs--current-buffer other))
        (with-current-buffer chat
          (let ((inhibit-read-only t))
            (goto-char dsh-emacs--input-marker)
            (insert "line one\nline two\nline three"))
          (let ((input-end (dsh-emacs--input-end)))
            ;; Out of bounds (M-> / clicking the bottom area) → clamped back to the input
            ;; area
            ;; end
            (goto-char (point-max))
            (dsh-emacs--lock-cursor-to-input)
            (when (= (point) input-end)
              (dsh-test-pass "cursor-clamped-at-input-area-end"))
            ;; Cursor position inside multi-line input does not move (unaffected)
            (goto-char dsh-emacs--input-marker)
            (forward-line 1)
            (let ((mid (point)))
              (dsh-emacs--lock-cursor-to-input)
              (when (= (point) mid)
                (dsh-test-pass "cursor-stays-inside-multi-line-input")))
            ;; Stopping exactly at the input area end → not falsely clamped
            (goto-char input-end)
            (dsh-emacs--lock-cursor-to-input)
            (when (= (point) input-end)
              (dsh-test-pass "cursor-at-input-end-not-moved")))))
    (kill-buffer chat)
    (kill-buffer other)))

;; --- Test 33c: no-stop zone at the input line (`❯ ' icon and to its left); the
;; cursor is pulled back to the edit start ---
(with-temp-buffer
  (dsh-emacs-mode)
  (let ((dsh-emacs--current-buffer (current-buffer)))
    (let* ((mpos (marker-position dsh-emacs--input-marker))
           (line-start (save-excursion
                         (goto-char mpos)
                         (line-beginning-position))))
      ;; Line start (where `C-a' lands, left of the icon) → pulled to the edit start
      (goto-char line-start)
      (dsh-emacs--lock-cursor-to-input)
      (dsh-test-assert "cursor-prompt-zone-line-start-clamped"
        (= (point) mpos))
      ;; The icon characters themselves (the two characters before the edit start) →
      ;; pulled to the edit start
      (goto-char (- mpos 2))
      (dsh-emacs--lock-cursor-to-input)
      (dsh-test-assert "cursor-prompt-glyph-clamped"
        (= (point) mpos))
      ;; Stopping exactly at the edit start → not falsely clamped
      (goto-char mpos)
      (dsh-emacs--lock-cursor-to-input)
      (dsh-test-assert "cursor-edit-start-not-moved"
        (= (point) mpos))
      ;; Transcript area (above the no-stop zone) → not falsely clamped
      (goto-char (point-min))
      (let ((p (point)))
        (dsh-emacs--lock-cursor-to-input)
        (dsh-test-assert "cursor-transcript-above-untouched"
          (= (point) p))))))

;; --- Test 33d: input marker repair locates by `❯ ' rather than a fixed skip ---
;; When the queue prefix shares the prompt face with the prompt, the anchor lands
;; at the start of the prefix; the repair must land after `❯ ', not blindly skip
;; forward 2 characters into the prefix.
(with-temp-buffer
  (dsh-emacs-mode)
  (let ((inhibit-read-only t))
    (goto-char (dsh-emacs-render--input-anchor-pos))
    (insert (propertize "[next: fix] " 'face 'dsh-emacs-input-prompt-face
                        'read-only t))
    (let ((expect (marker-position dsh-emacs--input-marker)))
      (dsh-test-assert "prompt-anchor-moves-to-prefix-start"
        (= (dsh-emacs-render--input-anchor-pos) (- expect 14)))
      (setq dsh-emacs--input-marker nil)
      (dsh-emacs--ensure-input-marker)
      (dsh-test-assert "marker-repaired-after-prompt-glyph"
        (= (marker-position dsh-emacs--input-marker) expect)))))

;; --- Test 33e: the input-area cursor must not land on a phantom line below the
;; input line (torn modeline overlay) ---
;; User report (split window): the cursor ran below the input line and could not be
;; moved back; the root cause is that when the modeline structural overlay is torn,
;; `dsh-emacs--input-end' falls back to point-max — and point-max is exactly the
;; phantom line below the input line (after the separating newline), so below-clamp
;; becomes a no-op and the cursor stays stuck below the input line until a reopen /
;; refresh rebuilds the overlay.
;; Invariant: even if the overlay disappears while the separating newline remains,
;; `dsh-emacs--input-end' must not equal point-max; when the cursor sits at
;; point-max (the phantom line), lock must pull it back to the input line.
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (goto-char dsh-emacs--input-marker)
  (insert "uuu123")
  ;; Tears the overlay but keeps the separating newline after it (simulating
  ;; split-window follow/overlay churn).
  (when dsh-emacs--modeline-overlay
    (delete-overlay dsh-emacs--modeline-overlay)
    (setq dsh-emacs--modeline-overlay nil))
  ;; The separating newline remains → the input end must not fall back to the
  ;; phantom-line point-max.
  (let* ((end (dsh-emacs--input-end))
         (pmax (point-max))
         (input-line (save-excursion
                       (goto-char (marker-position dsh-emacs--input-marker))
                       (line-number-at-pos))))
    (dsh-test-assert "input-end-torn-overlay-not-phantom"
      (and (< end pmax)
           (eq (char-after end) ?\n)))
    ;; Cursor sits at point-max (the phantom line) → lock must pull it back to the
    ;; input line.
    (goto-char pmax)
    (let ((below (line-number-at-pos (point))))
      (dsh-emacs--lock-cursor-to-input)
      (dsh-test-assert "cursor-torn-overlay-clamped-to-input-line"
        (and (= (point) end)
             (< (line-number-at-pos (point)) below)
             (= (line-number-at-pos (point)) input-line))))))

;; --- Test 34: running tools have no spinner animation (leading icon) + the line
;; does not vanish on completion ---
(with-temp-buffer
  (dsh-emacs-mode)
  (setq-local dsh-emacs-tool-expand-by-default t)
  (dsh-emacs-render-tool-call
   (dsh-emacs-test--tool-call-event 1 "c1" "bash" "{\"command\":\"ls -la\"}"))
  (let* ((st (dsh-emacs-render--tool-state "c1"))
         (ns (plist-get st :ns))
         (block-id (dsh-emacs-render--tool-call-block-id "c1")))
    ;; Initial render: the line starts with the variant icon (no spinner gear), no
    ;; trailing …
    (when-let* ((b (dsh-emacs-ui-find-block ns block-id)))
      (let ((txt (buffer-substring-no-properties (car b) (cdr b))))
        (when (and (string-match-p (regexp-quote "💻 ") txt)
                   (not (string-match-p "⚙" txt))
                   (not (string-match-p "…" txt)))
          (dsh-test-pass "running-tool-no-spinner"))))
    ;; After the tool completes the line still renders into the same block
    ;; (does not disappear): bash card contains the $ prompt + output
    (dsh-emacs-render-tool-result
     (dsh-emacs-test--tool-result-event 2 "c1" nil 0 "total 3\ndrwxrwxr-x"))
    (when-let* ((b (dsh-emacs-ui-find-block ns block-id)))
      (let ((txt (buffer-substring-no-properties (car b) (cdr b))))
        (when (and (string-match-p (regexp-quote "💻 ") txt)
                   (string-match-p (regexp-quote "$ ls -la") txt)
                   (string-match-p "drwxrwxr-x" txt))
          (dsh-test-pass "tool-row-not-lost-after-result"))))))

;; --- Test 34c: terminal card for bash nonzero exit / multi-line command ---
(with-temp-buffer
  (dsh-emacs-mode)
  (setq-local dsh-emacs-tool-expand-by-default t)
  (dsh-emacs-render-tool-call
   (dsh-emacs-test--tool-call-event 1 "x1" "bash"
     "{\"description\":\"build+test\",\"command\":\"make build\\nmake test\"}"))
  (dsh-emacs-render-tool-result
   (dsh-emacs-test--tool-result-event 2 "x1" nil 1 "make: *** No rule.  Stop."))
  (let* ((ns (dsh-emacs-render--make-namespace))
         (block (dsh-emacs-test--tool-block-text ns "tool-x1")))
    (when (and block
               ;; The command area is a single line (a multi-line command is flattened to
               ;; one
               ;; line with only one $ prompt); the error footer carries an exit code
               (string-match-p (regexp-quote "$ make build") block)
               (not (string-match-p (regexp-quote "$ make test") block))
               (string-match-p "make test" block)
               (string-match-p "make: \\*\\*\\* No rule" block)
               (string-match-p (regexp-quote "✗ exit 1") block))
      (dsh-test-pass "tool-bash-error-terminal-card"))))

;; --- Test 34d: bash command area single-line and elided when overlong ---
(let ((long-cmd (mapconcat #'identity
                           (make-list 8 "step --flag=very-long-option-name")
                           "\\n")))
  (with-temp-buffer
    (dsh-emacs-mode)
    (setq-local dsh-emacs-tool-expand-by-default t)
    (dsh-emacs-render-tool-call
     (dsh-emacs-test--tool-call-event 1 "d1" "bash"
       (concat "{\"description\":\"many steps\",\"command\":\"" long-cmd "\"}")))
    (dsh-emacs-render-tool-result
     (dsh-emacs-test--tool-result-event 2 "d1" nil 0 "ok"))
    (let* ((ns (dsh-emacs-render--make-namespace))
           (block (dsh-emacs-test--tool-block-text ns "tool-d1"))
           (occ (let ((n 0) (pos 0))
                  (while (string-match (regexp-quote "$ ") block pos)
                    (setq n (1+ n) pos (match-end 0)))
                  n)))
      (when (and block
                 (= occ 1)
                 (string-match-p "…" block))
        (dsh-test-pass "tool-bash-command-single-line-ellipsis")))))

;; --- Test 34b: tool line right after a user message: keep one blank line ---
(let ((buf (generate-new-buffer " *t34b-layout*")))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (dsh-emacs-modeline-setup)
        (setq-local dsh-emacs-tool-expand-by-default t)
        (dsh-emacs-render-event
         (json-read-from-string
          "{\"type\":\"user/message\",\"seq\":1,\"data\":{\"content\":[{\"type\":\"text\",\"text\":\"u2\"}]}}"))
        (dsh-emacs-render-tool-call
         (dsh-emacs-test--tool-call-event 2 "t1" "bash" "{\"command\":\"ls\"}"))
        (let* ((user-line
                (save-excursion
                  (goto-char (point-min))
                  (when (search-forward "❯ u2" nil t)
                    (line-number-at-pos (line-beginning-position)))))
               (tool-line
                (save-excursion
                  (goto-char (point-min))
                  (when (search-forward "💻 " nil t)
                    (line-number-at-pos (line-beginning-position))))))
          (when (and user-line tool-line (= tool-line (+ user-line 2)))
            (dsh-test-pass "tool-after-user-keeps-one-blank"))))
    (kill-buffer buf)))

;; --- Test 35: real historical tool/result uses message.source.callId ---
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (let ((call (dsh-emacs-test--tool-call-event
               10 "history-call" "bash" "{\"command\":\"pwd\"}"))
        (result (dsh-emacs-test--tool-result-event-source
                 11 "history-call" "/tmp/project")))
    (dsh-emacs-render-history-events
     (list (list (cons "event" call))
           (list (cons "event" result)))
     nil)
    (let ((state (dsh-emacs-render--tool-state "history-call")))
      (when (eq (plist-get state :state) 'success)
        (dsh-test-pass "history-tool-result-no-spinner")))))

;; --- Test 36: session buffer naming (matches the list + dsh prefix) ---
(let* ((item (list (cons 'sessionId "sess-title-1")
                   (cons 'blank :json-false)
                   (cons 'projections
                         (list (cons 'values
                                     (list (cons 'title "Emacs tweak")))))))
       (old dsh-emacs--sessions))
  (setq dsh-emacs--sessions
                (dsh-emacs-test--session-items (list item)))
  (when (string= "dsh-Emacs tweak" (dsh-emacs--chat-buffer-name "sess-title-1"))
    (dsh-test-pass "chat-buffer-name-with-title"))
  (setq dsh-emacs--sessions old))

(let ((old dsh-emacs--sessions))
  (setq dsh-emacs--sessions nil)
  (when (string= "dsh: sess-fallback" (dsh-emacs--chat-buffer-name "sess-fallback"))
    (dsh-test-pass "chat-buffer-name-fallback-without-title"))
  (setq dsh-emacs--sessions old))

;; --- Test 37: name sanitizing (% and newline) ---
(when (string= "进度50％完成" (dsh-emacs--sanitize-buffer-name "进度50%完成"))
  (dsh-test-pass "sanitize-percent-fullwidth"))

(when (string= "a b" (dsh-emacs--sanitize-buffer-name "a\nb"))
  (dsh-test-pass "sanitize-newline-flatten"))

(when (string= "" (dsh-emacs--sanitize-buffer-name "  "))
  (dsh-test-pass "sanitize-trims-whitespace"))

;; --- Test 38: title with % makes the buffer name use full-width % ---
(let* ((item (list (cons 'sessionId "sess-pct")
                   (cons 'blank :json-false)
                   (cons 'projections
                         (list (cons 'values
                                     (list (cons 'title "完成50%")))))))
       (old dsh-emacs--sessions))
  (setq dsh-emacs--sessions
                (dsh-emacs-test--session-items (list item)))
  (when (string= "dsh-完成50％" (dsh-emacs--chat-buffer-name "sess-pct"))
    (dsh-test-pass "chat-buffer-name-escape-percent"))
  (setq dsh-emacs--sessions old))

;; --- Test 39: same-title sessions get unique names (<N> suffix) ---
(let* ((item (list (cons 'sessionId "sess-dup-1")
                   (cons 'blank :json-false)
                   (cons 'projections
                         (list (cons 'values
                                     (list (cons 'title "dup-title")))))))
       (old dsh-emacs--sessions)
       (b1 (get-buffer-create "dsh-dup-title"))
       (b2 (get-buffer-create (generate-new-buffer-name "dsh-dup-title"))))
  (unwind-protect
      (progn
        (setq dsh-emacs--sessions
                (dsh-emacs-test--session-items (list item)))
        (when (string= "dsh-dup-title<2>" (buffer-name b2))
          (dsh-test-pass "chat-buffer-name-unique-suffix")))
    (setq dsh-emacs--sessions old)
    (when (buffer-live-p b1) (kill-buffer b1))
    (when (buffer-live-p b2) (kill-buffer b2))))

;; --- Test 40: sync live buffers on cache drift (rename + workspace dir) ---
(let* ((item (list (cons 'sessionId "sess-rename")
                   (cons 'blank :json-false)
                   (cons 'cwd "/tmp/proj")
                   (cons 'projections
                         (list (cons 'values
                                     (list (cons 'title "renamed")))))))
       (old dsh-emacs--sessions)
       (buf (get-buffer-create " *dsh-test-sync*")))
  (unwind-protect
      (progn
        (setq dsh-emacs--sessions
                (dsh-emacs-test--session-items (list item)))
        (with-current-buffer buf
          (setq dsh-emacs--buffer-session "sess-rename")
          (rename-buffer "old-name"))
        (puthash "sess-rename" buf dsh-emacs--chat-buffers)
        (dsh-emacs--chat-buffer-sync "sess-rename")
        (when (string= "dsh-renamed" (buffer-name buf))
          (dsh-test-pass "chat-buffer-sync-renames"))
        (when (and (stringp (buffer-local-value 'default-directory buf))
                   (string= "/tmp/proj/"
                            (buffer-local-value 'default-directory buf)))
          (dsh-test-pass "chat-buffer-sync-sets-default-directory"))
        (remhash "sess-rename" dsh-emacs--chat-buffers))
    (setq dsh-emacs--sessions old)
    (when (buffer-live-p buf) (kill-buffer buf))))

;; --- Test 40b: session workspace path source (cwd field of session/list) ---
(let* ((item (list (cons 'sessionId "sess-cwd")
                   (cons 'blank :json-false)
                   (cons 'cwd "/Users/ed/playground/dsh-emacs")
                   (cons 'projections
                         (list (cons 'values
                                     (list (cons 'title "some-session")))))))
       (old dsh-emacs--sessions))
  (setq dsh-emacs--sessions
                (dsh-emacs-test--session-items (list item)))
  (when (string= "/Users/ed/playground/dsh-emacs"
                 (dsh-emacs--chat-cwd "sess-cwd"))
    (dsh-test-pass "chat-cwd-from-session-item"))
  (when (null (dsh-emacs--chat-cwd "sess-unknown"))
    (dsh-test-pass "chat-cwd-nil-when-unknown"))
  (setq dsh-emacs--sessions old))

;; --- Test 41: title matches the list display ---
(let* ((item (list (cons 'sessionId "sess-match")
                   (cons 'blank :json-false)
                   (cons 'projections
                         (list (cons 'values
                                     (list (cons 'title "matches-list")))))))
       (old dsh-emacs--sessions))
  (setq dsh-emacs--sessions
                (dsh-emacs-test--session-items (list item)))
  (when (string= "matches-list" (dsh-emacs--chat-title "sess-match"))
    (dsh-test-pass "chat-title-matches-list"))
  (setq dsh-emacs--sessions old))

;; --- Test 42: format-spec customize type is checkbox-editable (round-trips) ---
(require 'cus-edit)
(let* ((spec (custom-variable-type 'dsh-emacs-modeline-format-spec))
       (buf (generate-new-buffer " *dsh-widget-test*")))
  (with-current-buffer buf
    (let ((w (widget-create spec)))
      (widget-value-set w '(:separator " • " :segments (model tokens)))
      (when (equal '(:separator " • " :segments (model tokens))
                   (widget-value w))
        (dsh-test-pass "mode-line-format-spec-widget-roundtrip"))
      ;; Unchecking a segment (subset) also round-trips
      (widget-value-set w '(:separator " " :segments (model)))
      (when (equal '(:separator " " :segments (model))
                   (widget-value w))
        (dsh-test-pass "mode-line-format-spec-widget-subset"))))
  (kill-buffer buf))

;; --- Test 43: first open of a session locates the workspace
;; (default-directory) ---
;; Regression: sync used to run before `setq-local dsh-emacs--buffer-session', so
;; the first-opened buffer was silently skipped by sync's guard, so
;; default-directory was never set, leaving magit unable to locate the project.
;; Here stubs mask network/rendering and the full open path runs.
(cl-letf (((symbol-function 'dsh-emacs-events-connect) (lambda (&rest _) nil))
          ((symbol-function 'pop-to-buffer) (lambda (&rest _) nil)))
  (let ((old-sessions dsh-emacs--sessions)
        (old-current-buffer dsh-emacs--current-buffer)
        (old-current-session dsh-emacs--current-session))
    (unwind-protect
        (progn
          (setq dsh-emacs--sessions
                (dsh-emacs-test--session-items
                 (list (list (cons 'sessionId "sess-open")
                             (cons 'blank :json-false)
                             (cons 'cwd "/tmp/ws")
                             (cons 'agentPreset "standard")
                             (cons 'projections
                                   (list (cons 'values
                                               (list (cons 'title "opening")))))))))
          (dsh-emacs-open-session "sess-open")
          (let ((buf dsh-emacs--current-buffer))
            (when (and (bufferp buf)
                       (string= "/tmp/ws/"
                                (buffer-local-value 'default-directory buf)))
              (dsh-test-pass "open-session-first-open-sets-default-directory"))
            (when (and (bufferp buf) (string= "dsh-opening" (buffer-name buf)))
              (dsh-test-pass "open-session-first-open-names-buffer"))))
      (setq dsh-emacs--sessions old-sessions
            dsh-emacs--current-buffer old-current-buffer
            dsh-emacs--current-session old-current-session)
      (dolist (b (buffer-list))
        (when (and (buffer-local-value 'dsh-emacs--buffer-session b)
                   (string= "sess-open"
                            (buffer-local-value 'dsh-emacs--buffer-session b)))
          (kill-buffer b)))
      (remhash "sess-open" dsh-emacs--chat-buffers))))

;; --- Test 43b: opening a new session no longer drops other sessions' streams
;; (multi-session realtime) ---
;; Regression: open-session used to unconditionally tear down the mux of the
;; previous current-buffer — opening B from A cut A's stream with nobody
;; reconnecting it, so A could only poll afterwards and misleading
;; "event stream connecting / switches back to realtime" messages appeared
;; (it never got back).
(let* ((buf-a (generate-new-buffer " *t43b-a*"))
       (disconnects nil)
       (connects nil)
       (old-sessions dsh-emacs--sessions)
       (old-current-buffer dsh-emacs--current-buffer)
       (old-current-session dsh-emacs--current-session))
  (unwind-protect
      (progn
        (with-current-buffer buf-a
          (setq-local dsh-emacs--buffer-session "sess-ka"))
        (setq dsh-emacs--current-buffer buf-a
              dsh-emacs--current-session "sess-ka")
        (setq dsh-emacs--sessions
              (dsh-emacs-test--session-items
               (list (list (cons 'sessionId "sess-ka")
                           (cons 'blank :json-false)
                           (cons 'agentPreset "standard"))
                     (list (cons 'sessionId "sess-kb")
                           (cons 'blank :json-false)
                           (cons 'agentPreset "standard")))))
        (cl-letf (((symbol-function 'dsh-emacs-events-connect)
                   (lambda (chat) (push (list 'connect chat) connects)))
                  ((symbol-function 'dsh-emacs-events-disconnect)
                   (lambda (&optional chat)
                     (push (list 'disconnect chat) disconnects)))
                  ((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (&rest _) nil))
                  ((symbol-function 'pop-to-buffer)
                   (lambda (&rest _) nil)))
          (dsh-emacs-open-session "sess-kb"))
        (let ((buf-b dsh-emacs--current-buffer))
          ;; The new session opens its own connection
          (when (and connects (eq (nth 1 (car connects)) buf-b))
            (dsh-test-pass "open-second-session-connects-its-own-stream"))
          ;; A's stream was not dropped
          (when (not (cl-some (lambda (d) (eq (nth 1 d) buf-a))
                              disconnects))
            (dsh-test-pass "open-second-session-keeps-previous-stream")))
        ;; Reopening the same session: still its own connection (connect drops its own
        ;; old stream internally)
        (setq disconnects nil connects nil)
        (cl-letf (((symbol-function 'dsh-emacs-events-connect)
                   (lambda (chat) (push (list 'connect chat) connects)))
                  ((symbol-function 'dsh-emacs-events-disconnect)
                   (lambda (&optional chat)
                     (push (list 'disconnect chat) disconnects)))
                  ((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (&rest _) nil))
                  ((symbol-function 'pop-to-buffer)
                   (lambda (&rest _) nil)))
          (dsh-emacs-open-session "sess-kb"))
        (when (and connects
                   (eq (nth 1 (car connects)) dsh-emacs--current-buffer))
          (dsh-test-pass "reopen-same-session-reconnects-itself")))
    (setq dsh-emacs--sessions old-sessions
          dsh-emacs--current-buffer old-current-buffer
          dsh-emacs--current-session old-current-session)
    (dolist (b (buffer-list))
      (let ((sid (buffer-local-value 'dsh-emacs--buffer-session b)))
        (when (member sid '("sess-ka" "sess-kb"))
          (kill-buffer b))))
    (remhash "sess-ka" dsh-emacs--chat-buffers)
    (remhash "sess-kb" dsh-emacs--chat-buffers)))

;; --- Test 43d: first open of a new session (cache miss) → refetch the list to
;; get a ctx snapshot ---
;; The new session is not in the `dsh-emacs--sessions' cache: the enhanced
;; guard of `dsh-emacs--link-session-preset' (triggered by either a missing
;; preset or a missing session) should lazily fetch session/list — in the
;; callback `dsh-emacs--chat-buffers-sync-all' (with context-sync) feeds the
;; contextPressure snapshot into the mode-line, so ctx% finally shows on first
;; open instead of staying empty forever.
(let* ((old-sessions dsh-emacs--sessions)
       (methods nil)
       (buf (generate-new-buffer " *t43d-chat*")))
  (unwind-protect
      (progn
        (setq dsh-emacs--sessions nil) ; Simulate a first open: empty cache
        (with-current-buffer buf
          (setq-local dsh-emacs--buffer-session "sess-first"))
        (puthash "sess-first" buf dsh-emacs--chat-buffers)
        (setq dsh-emacs--modeline-context-pressure nil)
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (method _params cb)
                     (push method methods)
                     (funcall cb t
                             (list (cons 'items
                                         (list (list (cons 'sessionId "sess-first")
                                                     (cons 'projections
                                                           (list (cons 'values
                                                                       (list (cons 'contextPressure
                                                                                   (list (cons 'pressureTokens 129946)
                                                                                         (cons 'contextWindow 262144)))))))))))))))
          (dsh-emacs--link-session-preset "sess-first"))
        (when (member "session/list" methods)
          (dsh-test-pass "first-open-fetches-session-list")))
    (setq dsh-emacs--sessions old-sessions)
    (remhash "sess-first" dsh-emacs--chat-buffers)
    (when (buffer-live-p buf) (kill-buffer buf))))

;; --- Test 43e: with a warm cache the mode-line ctx snapshot lands after
;; open-session ---
;; Regression: `dsh-emacs--chat-buffer-context-sync' used to run before
;; `dsh-emacs-mode', and the kill-all-local-variables of define-derived-mode
;; wiped the whole buffer-local snapshot that had been fed in → ctx% never
;; showed. Now sync runs after mode and mode-line-setup, so with a warm cache
;; it should land in one shot.
(let* ((old-sessions dsh-emacs--sessions)
       (item '((sessionId . "sess-ctxexist")
               (projections
                . ((values
                    . ((contextPressure
                        . ((pressureTokens . 129946)
                           (contextWindow . 262144))))))))))
  (unwind-protect
      (progn
        (setq dsh-emacs--sessions
              (list (dsh-protocol-session--from-alist item)))
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (_method _params cb)
                     ;; The preset chain is already cached → no fetch should happen; a
                     ;; fetch means
                     ;; the guard failed
                     (funcall cb t (list (cons 'items [])))))
                  ((symbol-function 'dsh-emacs-events-connect)
                   (lambda (&rest _) nil))
                  ((symbol-function 'pop-to-buffer)
                   (lambda (&rest _) nil)))
          (dsh-emacs-open-session "sess-ctxexist"))
        (let* ((buf (gethash "sess-ctxexist" dsh-emacs--chat-buffers))
               (pressure (and buf (buffer-local-value
                                    'dsh-emacs--modeline-context-pressure buf)))
               (window (and buf (buffer-local-value
                                 'dsh-emacs--modeline-context-window-server buf))))
          (when (and (= 129946 pressure) (= 262144 window))
            (dsh-test-pass "open-session-feeds-context-snapshot"))))
    (setq dsh-emacs--sessions old-sessions)
    (let ((b (gethash "sess-ctxexist" dsh-emacs--chat-buffers)))
      (remhash "sess-ctxexist" dsh-emacs--chat-buffers)
      (when (buffer-live-p b) (kill-buffer b)))))

;; --- Test 43f: after a model failure, a session/list row missing contextWindow
;; must not clear the ctx snapshot ---
;; Regression: `dsh-emacs--chat-buffer-context-sync' used to feed the row's
;; contextPressure into the mode-line unconditionally. The list projection
;; columns are partially filled (unmaterialized cache cells / a missing
;; contextWindow after a failed model run both come back as partial rows), and
;; writing (pressure . nil) / (nil . nil) into the buffer wiped the whole
;; already-correct ctx%. Fix: only land when (pressure, window) is a complete
;; pair; partial rows keep the old snapshot and wait for a live
;; session/projection frame to correct them.
(let* ((old-sessions dsh-emacs--sessions)
       (ghost (get-buffer-create " *t43f-chat*"))
       (good '((sessionId . "sess-ctxkeep")
               (projections
                . ((values
                    . ((contextPressure
                        . ((pressureTokens . 129946)
                           (contextWindow . 262144))))))))))
  (unwind-protect
      (progn
        (setq dsh-emacs--sessions
              (list (dsh-protocol-session--from-alist good)))
        (with-current-buffer ghost
          ;; An already-correct snapshot exists: the ctx% before the model failure (about
          ;; 49.6%)
          (setq-local dsh-emacs--modeline-context-pressure 129946)
          (setq-local dsh-emacs--modeline-context-window-server 262144))
        ;; List refresh: contextWindow missing after the model failure (partial
        ;; projections row)
        (setq dsh-emacs--sessions
              (list (dsh-protocol-session--from-alist
                     '((sessionId . "sess-ctxkeep")
                       (projections
                        . ((values
                            . ((contextPressure
                                . ((pressureTokens . 129946)))))))))))
        (dsh-emacs--chat-buffer-context-sync "sess-ctxkeep" ghost)
        (let ((p (buffer-local-value 'dsh-emacs--modeline-context-pressure ghost))
              (w (buffer-local-value 'dsh-emacs--modeline-context-window-server ghost)))
          (when (and (= 129946 p) (= 262144 w))
            (dsh-test-pass "model-error-row-keeps-ctx-snapshot")))
        ;; The list row does not even have a contextPressure projection → all the more
        ;; reason not to clear
        (setq dsh-emacs--sessions
              (list (dsh-protocol-session--from-alist
                     '((sessionId . "sess-ctxkeep")))))
        (dsh-emacs--chat-buffer-context-sync "sess-ctxkeep" ghost)
        (let ((p (buffer-local-value 'dsh-emacs--modeline-context-pressure ghost))
              (w (buffer-local-value 'dsh-emacs--modeline-context-window-server ghost)))
          (when (and (= 129946 p) (= 262144 w))
            (dsh-test-pass "projectionless-row-keeps-ctx-snapshot")))
        ;; A complete paired row still lands as usual (with a healthy model the list
        ;; refresh keeps correcting ctx%)
        (setq dsh-emacs--sessions
              (list (dsh-protocol-session--from-alist good)))
        (dsh-emacs--chat-buffer-context-sync "sess-ctxkeep" ghost)
        (let ((p (buffer-local-value 'dsh-emacs--modeline-context-pressure ghost))
              (w (buffer-local-value 'dsh-emacs--modeline-context-window-server ghost)))
          (when (and (= 129946 p) (= 262144 w))
            (dsh-test-pass "complete-row-still-updates-ctx-snapshot"))))
    (setq dsh-emacs--sessions old-sessions)
    (when (buffer-live-p ghost) (kill-buffer ghost))))

;; --- Test 43g: a zero-usage sample from a model failure (QUOTA) does not clear
;; the ctx snapshot ---
;; Regression: when the provider refuses (quota / rate limit) it reports an
;; assistant/chunk sample with usage 0/0, and the last-wins fold of token-meter
;; squeezes contextPressure to 0 — the live session/projection frame (and the
;; session/list rows that follow) carry {projectedTokens/pressureTokens 0,
;; contextWindow}. The setter used to land (0, window) verbatim, collapsing
;; ctx% from the correct pre-failure value (e.g. 66617/1000000 ≈ 6.7%) to 0%
;; (in all session logs the zero-usage sample only ever appears just before an
;; error completion, so it is a degenerate sample, not real usage). Fix: a
;; non-positive pressure keeps the previous snapshot until the next real usage
;; sample lands a new pair.
(let* ((old-sessions dsh-emacs--sessions)
       (buf (get-buffer-create " *t43g-chat*")))
  (unwind-protect
      (progn
        (with-current-buffer buf
          (setq-local dsh-emacs--buffer-session "sess-zero")
          ;; The server projection already gave the correct snapshot before the failure:
          ;; 66617 / 1000000 ≈ 6.7%
          (setq-local dsh-emacs--modeline-context-pressure 66617)
          (setq-local dsh-emacs--modeline-context-window-server 1000000))
        (puthash "sess-zero" buf dsh-emacs--chat-buffers)
        ;; Live projection frame: the zero-usage sample of a QUOTA failure (real event
        ;; shape)
        (dsh-emacs--events-apply-context-projection
         "sess-zero"
         '((projectedTokens . 0) (pressureTokens . 0)
           (contextWindow . 1000000)))
        (dsh-test-assert "zero-projection-frame-keeps-ctx-snapshot"
          (= 66617 (buffer-local-value 'dsh-emacs--modeline-context-pressure buf))
          (= 1000000 (buffer-local-value 'dsh-emacs--modeline-context-window-server buf)))
        ;; After the user submits input again the failed zero sample is still in the
        ;; fold (pressure 0), and the growing surface brings projectedTokens back to a
        ;; small positive value — that is not real usage, it is a derivation branch off
        ;; the whole {pressureTokens 0} pair. `projected ?? pressure' used to pick up
        ;; this small positive value and write it, collapsing ctx% from 6.7% to ≈0.1%
        ;; (observed by the user: after a model error, submitting one more user input
        ;; sent ctx usage back to 0).
        (dsh-emacs--events-apply-context-projection
         "sess-zero"
         '((projectedTokens . 1234) (pressureTokens . 0)
           (contextWindow . 1000000)))
        (dsh-test-assert "submit-after-error-keeps-ctx-snapshot"
          (= 66617 (buffer-local-value 'dsh-emacs--modeline-context-pressure buf))
          (= 1000000 (buffer-local-value 'dsh-emacs--modeline-context-window-server buf)))
        ;; The session/list row carries the same zero pair (pressureTokens 0 + a full
        ;; contextWindow)
        (setq dsh-emacs--sessions
              (list (dsh-protocol-session--from-alist
                     '((sessionId . "sess-zero")
                       (projections
                        . ((values
                            . ((contextPressure
                                . ((pressureTokens . 0)
                                   (contextWindow . 1000000)))))))))))
        (dsh-emacs--chat-buffer-context-sync "sess-zero" buf)
        (dsh-test-assert "zero-pressure-list-row-keeps-ctx-snapshot"
          (= 66617 (buffer-local-value 'dsh-emacs--modeline-context-pressure buf))
          (= 1000000 (buffer-local-value 'dsh-emacs--modeline-context-window-server buf)))
        ;; The next real usage sample lands as usual (the projection recovers after a
        ;; successful run)
        (dsh-emacs--events-apply-context-projection
         "sess-zero"
         '((projectedTokens . 70123) (pressureTokens . 70000)
           (contextWindow . 1000000)))
        (dsh-test-assert "positive-projection-still-updates-ctx-snapshot"
          (= 70123 (buffer-local-value 'dsh-emacs--modeline-context-pressure buf))
          (= 1000000 (buffer-local-value 'dsh-emacs--modeline-context-window-server buf))))
    (remhash "sess-zero" dsh-emacs--chat-buffers)
    (setq dsh-emacs--sessions old-sessions)
    (when (buffer-live-p buf) (kill-buffer buf))))

;; --- Test 43h: the `permissions' projection drives the mode-line segment ---
;; dsh 0.1.6 narrowed the projection to `{currentValue}'; the selectable
;; options moved to the permissionPresets/catalog Remote.  A configured key
;; and the derived `custom' both display; an absent/unknown value must not
;; clear the segment or guess.
(let ((buf (get-buffer-create " *t43h-chat*")))
  (unwind-protect
      (progn
        (with-current-buffer buf
          (setq-local dsh-emacs--buffer-session "sess-perm"))
        (puthash "sess-perm" buf dsh-emacs--chat-buffers)
        (dsh-emacs--events-apply-permission-projection
         "sess-perm" '((currentValue . "workspace-write")))
        (dsh-test-assert "permission-projection-sets-segment"
          (equal "workspace-write"
                 (buffer-local-value 'dsh-emacs--modeline-permission buf)))
        (dsh-emacs--events-apply-permission-projection
         "sess-perm" '((currentValue . "custom")))
        (dsh-test-assert "permission-projection-replaces-value"
          (equal "custom"
                 (buffer-local-value 'dsh-emacs--modeline-permission buf)))
        (dsh-emacs--events-apply-permission-projection
         "sess-perm" '((currentValue . "")))
        (dsh-emacs--events-apply-permission-projection
         "sess-perm" '((somethingElse . 1)))
        (dsh-test-assert "permission-projection-ignores-empty-and-unknown"
          (equal "custom"
                 (buffer-local-value 'dsh-emacs--modeline-permission buf))))
    (remhash "sess-perm" dsh-emacs--chat-buffers)
    (when (buffer-live-p buf) (kill-buffer buf))))

;; --- Test 43c: on send, a session with no stream reconnects first (self-heal);
;; no duplicate connect while the handshake is in flight ---
(let* ((chat (get-buffer-create " *t43c-chat*"))
       (connects nil)
       (old-current-session dsh-emacs--current-session))
  (unwind-protect
      (progn
        (with-current-buffer chat
          (dsh-emacs-mode)
          (setq-local dsh-emacs--buffer-session "sess-sh")
          (setq dsh-emacs--event-ready nil
                dsh-emacs--event-process nil))
        ;; Case 1: no stream at all (the process does not even exist) → reconnect
        ;; self-heals
        (with-current-buffer chat
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (_method _params cb)
                       (funcall cb t '((accepted . t)))))
                    ((symbol-function 'dsh-emacs--get-input)
                     (lambda () ""))
                    ((symbol-function 'dsh-emacs--ml-busy-set)
                     (lambda (&rest _) nil))
                    ((symbol-function 'dsh-emacs-events-connect)
                     (lambda (c) (push c connects)))
                    ((symbol-function 'dsh-emacs-events--watchdog-start)
                     (lambda () nil)))
            (dsh-emacs--submit-prompt "hi")))
        (when (eq (car connects) chat)
          (dsh-test-pass "submit-heals-streamless-buffer-with-reconnect"))
        ;; Case 2: handshake in flight (process alive but not ready) → no duplicate
        ;; connect
        (setq connects nil)
        (let ((proc (make-pipe-process :name " *t43c-proc*"
                                       :buffer " *t43c-proc*")))
          (unwind-protect
              (progn
                (with-current-buffer chat
                  (setq dsh-emacs--event-ready nil
                        dsh-emacs--event-process proc))
                (with-current-buffer chat
                  (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                             (lambda (_m _p cb)
                               (funcall cb t '((accepted . t)))))
                            ((symbol-function 'dsh-emacs--get-input)
                             (lambda () ""))
                            ((symbol-function 'dsh-emacs--ml-busy-set)
                             (lambda (&rest _) nil))
                            ((symbol-function 'dsh-emacs-events-connect)
                             (lambda (c) (push c connects)))
                            ((symbol-function 'dsh-emacs-events--watchdog-start)
                             (lambda () nil)))
                    (dsh-emacs--submit-prompt "hi")))
                (when (null connects)
                  (dsh-test-pass "submit-in-handshake-keeps-single-stream")))
            (delete-process proc))))
    (setq dsh-emacs--current-session old-current-session)
    (when (buffer-live-p chat) (kill-buffer chat))))

;; --- Test 44: a chat buffer never shows modified / closing never prompts to
;; save ---
(with-temp-buffer
  (dsh-emacs-mode)
  (insert "hello")
  (when (not (buffer-modified-p))
    (dsh-test-pass "chat-buffer-insert-keeps-unmodified")))

;; Transcript edits clear the modified flag without forcing mode-line layout.
(with-temp-buffer
  (dsh-emacs-mode)
  (let ((invalidations 0)
        (set-modified (symbol-function 'set-buffer-modified-p)))
    (cl-letf (((symbol-function 'set-buffer-modified-p)
               (lambda (flag)
                 (cl-incf invalidations)
                 (funcall set-modified flag))))
      (insert "hello")
      (put-text-property (- (point) 5) (point) 'face 'bold))
    (dsh-test-assert "chat-edits-do-not-invalidate-the-mode-line"
      (zerop invalidations)
      (not (buffer-modified-p)))))

(let ((buf (get-buffer-create " *dsh-mod-test*")))
  (unwind-protect
      (progn
        (with-current-buffer buf
          (dsh-emacs-mode)
          (insert "x"))
        ;; After external code force-marks the buffer modified, the kill query path
        ;; still lets it through. Contract: only a t from the query function allows the
        ;; kill (returning nil silently blocks it — that was the root cause of the
        ;; previous "cannot close" regression, see test 44b).
        (with-current-buffer buf
          (set-buffer-modified-p t)
          (let ((ret (dsh-emacs--chat-buffer-clear-modified)))
            (when (and (eq ret t) (not (buffer-modified-p)))
              (dsh-test-pass "kill-query-fn-clears-modified-allows-kill"))))
        ;; Restore the after-change invariant: insertions after a clear still leave the
        ;; buffer unmodified
        (with-current-buffer buf
          (insert "y")
          (when (not (buffer-modified-p))
            (dsh-test-pass "chat-buffer-reinsert-stays-clean"))))
    (when (buffer-live-p buf) (kill-buffer buf))))

;; --- Test 44b: the real kill path — the query returns t and the buffer really
;; gets killed ---
(let ((buf (get-buffer-create " *dsh-kill-test*")))
  (with-current-buffer buf
    (dsh-emacs-mode)
    (insert "x"))
  (let ((res (kill-buffer buf)))
    (when (and (eq res t) (not (buffer-live-p buf)))
      (dsh-test-pass "chat-buffer-kill-buffer-succeeds"))))

;; --- Test 45: the doom segment includes the busy animation (regression: the
;; animation used to exist only in the vanilla splice, and the doom-modeline
;; branch's segment missed it, so the animation never showed) ---
;; doom-segment requires a dsh-emacs-mode buffer + buffer-local modeline state,
;; and the segment content is decided by format-spec (no effort/preset by
;; default, they must be given explicitly) — otherwise the test never fires
;; and silently disappears.
(let ((txt (with-temp-buffer
             (dsh-emacs-mode)
             (let ((dsh-emacs-modeline-format-spec
                    '(:separator " " :segments (model effort preset))))
               (setq-local dsh-emacs--modeline-usage
                           (dsh-emacs-make-usage 100 50)
                           dsh-emacs--modeline-model "deepseek-v4-flash-0731"
                           dsh-emacs--modeline-effort "max"
                           dsh-emacs--modeline-preset "standard"
                           dsh-emacs--ml-busy t
                           dsh-emacs--ml-busy-index 4)
               (dsh-emacs-modeline--doom-segment)))))
  (dsh-test-assert "doom-segment-includes-busy-animation"
    (string-match-p "deepseek-v4-flash-0731" txt)
    (string-match-p "max" txt)
    (string-match-p "standard" txt)
    (string-match-p "████" txt)
    ;; The animation comes before the stats (right after the DSH mode name)
    (< (string-match "████" txt)
       (string-match "deepseek-v4" txt))))

(let ((dsh-emacs--ml-busy nil)
      (dsh-emacs--modeline-usage nil))
  ;; When idle the doom segment shows the model segment but no progress-bar
  ;; animation
  (when (not (string-match-p "█" (dsh-emacs-modeline--doom-segment)))
    (dsh-test-pass "doom-segment-idle-has-no-spinner")))

;; --- Test 46: send-or-stop interrupts when busy (session/cancel) and sends
;; when idle ---
(let ((buf (generate-new-buffer " *dsh-interrupt-test*"))
      (calls nil))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (setq dsh-emacs--current-session "sess-cancel")
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (method params _cb)
                     (push (list method params) calls))))
          ;; Busy → pressing C-c C-c again sends session/cancel instead of queueing a
          ;; new message
          (setq-local dsh-emacs--ml-busy t)
          (dsh-emacs-send-or-stop)
          (let* ((call (car calls))
                 (req (cdr (assq 'request (cadr call)))))
            (when (and (string= "session/cancel" (car call))
                       (string= "sess-cancel"
                                (cdr (assq 'sessionId req))))
              (dsh-test-pass "send-or-stop-busy-interrupts-via-cancel")))
          ;; Idle + text present → send session/prompt
          (setq-local dsh-emacs--ml-busy nil)
          (setq calls nil)
          (dsh-emacs--replace-input "hello there")
          (dsh-emacs-send-or-stop)
          (let* ((call (car calls))
                 (req (cdr (assq 'request (cadr call))))
                 (content (cdr (assq 'content req)))
                 (part (and content (aref content 0))))
            (when (and (string= "session/prompt" (car call))
                       (string= "hello there" (cdr (assq 'text part))))
              (dsh-test-pass "send-or-stop-idle-sends-prompt")))
          ;; Idle + empty text → no request is sent at all
          (setq calls nil)
          (dsh-emacs--replace-input "   ")
          (dsh-emacs-send-or-stop)
          (when (null calls)
            (dsh-test-pass "send-or-stop-idle-empty-noop"))))
    (kill-buffer buf)))

;; --- Test 47: model catalog expansion + sorting + selectModel call ---
(let* ((g1 '((id . "g1") (name . "DeepSeek")
             (models . [((id . "m1") (name . "Model One"))
                        ((id . "m2"))])))
       (g2 '((id . "g2") (name . "qwen-token-plan")
             (models . [((id . "m3") (name . "Qwen-M"))])))
       (cands (dsh-emacs--model-candidates `((groups . [,g1 ,g2])))))
  ;; Each entry carries (id provider group name), where provider is the id of the
  ;; owning group; the list sorts by provider name + model id (m1 < m2 within a
  ;; group, group names case-insensitive)
  (when (equal cands '(("m1" "g1" "DeepSeek" "Model One" nil)
                       ("m2" "g1" "DeepSeek" "m2" nil)
                       ("m3" "g2" "qwen-token-plan" "Qwen-M" nil)))
    (dsh-test-pass "model-candidates-flattened")))

;; Sorting: groups out of order + entries out of order → lexicographic order by
;; provider name + model id (case-insensitive)
(let* ((g1 '((id . "g1") (name . "Zeta")
             (models . [((id . "m1") (name . "beta"))
                        ((id . "m2") (name . "Alpha"))])))
       (g2 '((id . "g2") (name . "Alpha-Group")
             (models . [((id . "m3") (name . "gamma"))])))
       (cands (dsh-emacs--model-candidates `((groups . [,g1 ,g2])))))
  (when (equal cands '(("m3" "g2" "Alpha-Group" "gamma" nil)
                       ("m1" "g1" "Zeta" "beta" nil)
                       ("m2" "g1" "Zeta" "Alpha" nil)))
    (dsh-test-pass "model-candidates-sorted-provider-then-name")))

(let ((buf (generate-new-buffer " *dsh-model-test*"))
      (calls nil))
  (unwind-protect
      (with-current-buffer buf
        (setq dsh-emacs--current-session "sess-m")
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (method params cb)
                     (push (list method params) calls)
                     (when (string= method "session/modelCatalog")
                       (funcall cb
                                t
                                '((current . ((provider . "p1") (model . "m0")))
                                  (groups . [((id . "g1") (name . "DeepSeek")
                                              (models . [((id . "m1")
                                                          (name . "Model One"))]))]))))))
                  ((symbol-function 'completing-read)
                   ;; The key the user selects is the model row's full key (with the
                   ;; embedded
                   ;; provider, shaped like "m1 [g1|DeepSeek]"; invisible when rendered
                   ;; through
                   ;; the display property)
                   (lambda (&rest _)
                     "m1 [g1|DeepSeek]")))
          (dsh-emacs-select-model)
          (let* ((call (car calls))
                 (params (cadr call)))
            (when (and (string= "session/selectModel" (car call))
                       (string= "m1" (cdr (assq 'model (cdr (assq 'request params)))))
                       (string= "g1" (cdr (assq 'provider (cdr (assq 'request params)))))
                       (string= "sess-m" (cdr (assq 'sessionId
                                                    (cdr (assq 'request params))))))
              (dsh-test-pass "select-model-sends-selectModel")))))
    (kill-buffer buf)))

;; --- Test 47b: C-g in select-model cancels cleanly (the quit must not leak
;; into the process filter) ---
(let ((buf (generate-new-buffer " *dsh-model-quit-test*"))
      (leaked nil))
  (unwind-protect
      (with-current-buffer buf
        (setq dsh-emacs--current-session "sess-q")
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (&rest _) (signal 'quit nil))))
          (condition-case err
              (dsh-emacs--select-model-prompt
               "sess-q"
               '((current . ((provider . "p1") (model . "m0")))
                 (groups . [((id . "g1") (name . "DeepSeek")
                             (models . [((id . "m1") (name . "Model One"))]))])))
            (quit (setq leaked t)))))
    (kill-buffer buf))
  (when (not leaked)
    (dsh-test-pass "select-model-c-g-aborts-cleanly")))

;; --- Test 47c: neither an empty RET nor unknown input may trigger selectModel
;; (the implementation no longer passes DEF) ---
;; Empty RET ("") → keep the current model: no selectModel is sent, message
;; "Kept ..."
(let ((buf (generate-new-buffer " *dsh-model-empty-test*"))
      (calls nil)
      (msgs nil))
  (unwind-protect
      (with-current-buffer buf
        (setq dsh-emacs--current-session "sess-e")
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (method params cb)
                     (push (list method params) calls)
                     (when (string= method "session/modelCatalog")
                       (funcall
                        cb t
                        '((current . ((provider . "g1") (model . "m1")))
                          (groups . [((id . "g1") (name . "DeepSeek")
                                      (models . [((id . "m1")
                                                  (name . "Model One"))]))]))))))
                  ((symbol-function 'completing-read)
                   (lambda (&rest _) ""))
                  ((symbol-function 'message)
                   (lambda (fmt &rest args)
                     (push (apply #'format fmt args) msgs))))
          (dsh-emacs-select-model)
          (let ((methods (mapcar #'car calls)))
            (when (and (member "session/modelCatalog" methods)
                       (not (member "session/selectModel" methods))
                       (cl-some (lambda (m) (string-prefix-p "Kept" m))
                                msgs))
              (dsh-test-pass "select-model-empty-pick-keeps-current")))))
    (kill-buffer buf)))

;; Unknown string → rejected: no selectModel is sent, message "Unknown model"
(let ((buf (generate-new-buffer " *dsh-model-unknown-test*"))
      (calls nil)
      (msgs nil))
  (unwind-protect
      (with-current-buffer buf
        (setq dsh-emacs--current-session "sess-u")
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (method params cb)
                     (push (list method params) calls)
                     (when (string= method "session/modelCatalog")
                       (funcall
                        cb t
                        '((current . ((provider . "g1") (model . "m1")))
                          (groups . [((id . "g1") (name . "DeepSeek")
                                      (models . [((id . "m1")
                                                  (name . "Model One"))]))]))))))
                  ((symbol-function 'completing-read)
                   (lambda (&rest _) "bogus"))
                  ((symbol-function 'message)
                   (lambda (fmt &rest args)
                     (push (apply #'format fmt args) msgs))))
          (dsh-emacs-select-model)
          (let ((methods (mapcar #'car calls)))
            (when (and (member "session/modelCatalog" methods)
                       (not (member "session/selectModel" methods))
                       (cl-some (lambda (m) (string-prefix-p "Unknown" m))
                                msgs))
              (dsh-test-pass "select-model-unknown-pick-rejected")))))
    (kill-buffer buf)))

;; --- Test 47d: the picker's current comes from the session modelSelection
;; projection, not the catalog default ---
;; Regression: modelCatalog is session-independent and its current/default is
;; the host default; the model the session actually runs is in the cached row's
;; modelSelection.lastUsed projection (the same authoritative source as the
;; mode-line). The picker's "current" prompt and the "Kept current model" of an
;; empty RET must use the projection value (here the catalog default is m0 and
;; the projection is m9), otherwise the prompt disagrees with the model really
;; running.
(let* ((old-sessions dsh-emacs--sessions)
       (buf (get-buffer-create " *dsh-model-proj-test*"))
       (calls nil)
       (msgs nil)
       (prompts nil)
       (item (dsh-protocol-session--from-alist
              '((sessionId . "sess-proj")
                (projections . ((values
                                 . ((modelSelection
                                     . ((lastUsed
                                         . ((provider . "g1")
                                            (model . "m9")))))))))))))
  (unwind-protect
      (with-current-buffer buf
        (setq dsh-emacs--current-session "sess-proj")
        (setq dsh-emacs--sessions (list item))
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (method params cb)
                     (push (list method params) calls)
                     (when (string= method "session/modelCatalog")
                       (funcall
                        cb t
                        '((current . ((provider . "g1") (model . "m0")))
                          (groups . [((id . "g1") (name . "DeepSeek")
                                      (models . [((id . "m0") (name . "m0"))
                                                 ((id . "m1") (name . "Model One"))
                                                 ((id . "m9") (name . "m9"))]))]))))))
                  ((symbol-function 'completing-read)
                   (lambda (prompt &rest _)
                     (push prompt prompts)
                     ""))
                  ((symbol-function 'message)
                   (lambda (fmt &rest args)
                     (push (apply #'format fmt args) msgs))))
          (dsh-emacs-select-model)
          (let ((has-m9 (cl-some (lambda (p) (string-match-p "(current DeepSeek/m9)" p)) prompts))
                (has-m0 (cl-some (lambda (p) (string-match-p "(current DeepSeek/m0)" p)) prompts))
                (kept-m9 (cl-some (lambda (m) (string-match-p "Kept current model m9" m)) msgs)))
            (when (and has-m9 (not has-m0) kept-m9)
              (dsh-test-pass "select-model-current-from-session-projection")))))
    (setq dsh-emacs--sessions old-sessions)
    (kill-buffer buf)))

;; --- Test 47e: each provider shows once and its models are indented under it
;; (grouped display) ---
;; Row key = "id [provider-id|Provider Name]": the key embeds the provider id
;; and display name, so the same id across providers (m2 under Qwen and
;; Anthropic) yields two unique rows and an exact assoc hit; the key starts with
;; the id (prefix filtering works); when rendered the display property hides
;; [provider|Name] so the list only shows "  id" (prefix input still matches).
(let* ((cands '(("m1" "g1" "DeepSeek" "Model One")
                ("m2b" "g1" "DeepSeek" "Model Two")
                ("m0" "g2" "Qwen" "m0")
                ("m2" "g2" "Qwen" "Qwen-M")
                ("m2" "g3" "Anthropic" "Same-M")))
       (entries (dsh-emacs--model-entries cands))
       (key (lambda (id provider name) (format "%s [%s|%s]" id provider name)))
       (expect `(("DeepSeek" :header . "DeepSeek")
                 (,(funcall key "m1" "g1" "DeepSeek") . ("m1" "g1" "DeepSeek" "Model One"))
                 (,(funcall key "m2b" "g1" "DeepSeek") . ("m2b" "g1" "DeepSeek" "Model Two"))
                 ("Qwen" :header . "Qwen")
                 (,(funcall key "m0" "g2" "Qwen") . ("m0" "g2" "Qwen" "m0"))
                 (,(funcall key "m2" "g2" "Qwen") . ("m2" "g2" "Qwen" "Qwen-M"))
                 ("Anthropic" :header . "Anthropic")
                 (,(funcall key "m2" "g3" "Anthropic") . ("m2" "g3" "Anthropic" "Same-M"))))
       ;; Rendering: a unique id stays a bare "  id"; a duplicate id (same id across
       ;; providers) shows the provider name, because filtering drops the group header
       ;; and bare-id rows would be indistinguishable
       (shown (mapcar (lambda (e)
                        (if (eq :header (car (cdr e)))
                            (car e)
                          (get-text-property 0 'display (car e))))
                      entries))
       (shown-expect (list "DeepSeek" "  m1" "  m2b" "Qwen" "  m0"
                           "  m2 (Qwen)" "Anthropic" "  m2 (Anthropic)")))
  (when (and (equal entries expect)
             (equal shown shown-expect)
             ;; All model row keys are unique → the key returned by completion is
             ;; unambiguous
             (= (length entries)
                (length (cl-remove-duplicates (mapcar #'car entries)))))
    (dsh-test-pass "model-entries-groups-by-provider")))

;; --- Test 47e: selecting a provider header row → message instead of a switch
;; (no selectModel) ---
(let ((buf (generate-new-buffer " *dsh-model-header-test*"))
      (calls nil))
  (unwind-protect
      (with-current-buffer buf
        (setq dsh-emacs--current-session "sess-h")
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (method params cb)
                     (push (list method params) calls)
                     (when (string= method "session/modelCatalog")
                       (funcall cb
                                t
                                '((current . ((provider . "g1") (model . "m1")))
                                  (groups . [((id . "g1") (name . "DeepSeek")
                                              (models . [((id . "m1")
                                                          (name . "Model One"))]))]))))))
                  ((symbol-function 'completing-read)
                   (lambda (&rest _) "DeepSeek")))
          (dsh-emacs-select-model)
          (let ((methods (mapcar #'car calls)))
            (when (and (member "session/modelCatalog" methods)
                       (not (member "session/selectModel" methods)))
              (dsh-test-pass "select-model-header-pick-rejected")))))
    (kill-buffer buf)))

;; --- Test 47f: same id under several providers → the key embeds the provider,
;; so the selected row is the right provider ---
;; Row key = "m2 [g2|Qwen]" (invisible under the display property, the list
;; still shows "  m2"). The key returned by completing-read is the row the
;; user selected, and assoc hits the correct payload directly: choosing the Qwen
;; row → provider g2 and confirmation message "Dup-2 (Qwen)"; one selection
;; throughout, no second confirmation.
(let ((buf (generate-new-buffer " *dsh-model-dup-test*"))
      (calls nil)
      (msgs nil)
      (cr-count 0))
  (unwind-protect
      (with-current-buffer buf
        (setq dsh-emacs--current-session "sess-d")
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (method params cb)
                     ;; After a successful model switch the product follows with a
                     ;; session/list
                     ;; refresh (fetching the new model's contextPressure snapshot); it
                     ;; does not go
                     ;; into the calls used by the assertions, otherwise (car calls) would
                     ;; no longer
                     ;; point at selectModel.
                     (unless (string= method "session/list")
                       (push (list method params) calls))
                     (cond
                      ((string= method "session/modelCatalog")
                       (funcall
                        cb t
                        '((current . ((provider . "g1") (model . "m1")))
                          (groups . [((id . "g1") (name . "DeepSeek")
                                      (models . [((id . "m2")
                                                  (name . "Dup-1"))]))
                                     ((id . "g2") (name . "Qwen")
                                      (models . [((id . "m2")
                                                  (name . "Dup-2"))]))]))))
                      ((string= method "session/selectModel")
                       ;; The success callback triggers the confirmation message ("Model
                       ;; switched to
                       ;; ...")
                       (funcall cb t nil)))))
                  ;; The user picked the Qwen row: return that row's full key (with the
                  ;; hidden
                  ;; provider)
                  ((symbol-function 'completing-read)
                   (lambda (&rest _)
                     (setq cr-count (1+ cr-count))
                     "m2 [g2|Qwen]"))
                  ((symbol-function 'message)
                   (lambda (fmt &rest args)
                     (push (apply #'format fmt args) msgs))))
          (dsh-emacs-select-model)
          (let* ((call (car calls))
                 (params (cadr call)))
            (when (and (string= "session/selectModel" (car call))
                       (string= "m2" (cdr (assq 'model (cdr (assq 'request params)))))
                       (string= "g2" (cdr (assq 'provider (cdr (assq 'request params)))))
                       (= 1 cr-count)
                       (cl-some (lambda (m)
                                  (string-match-p (regexp-quote "Dup-2 (Qwen)") m))
                                msgs))
              (dsh-test-pass "select-model-dup-id-picks-own-provider")))))
    (kill-buffer buf)))

;; Pick the DeepSeek row (key "m2 [g1|DeepSeek]") → provider is g1 and the
;; confirmation message shows Dup-1
(let ((buf (generate-new-buffer " *dsh-model-dup2*"))
      (calls nil)
      (msgs nil))
  (unwind-protect
      (with-current-buffer buf
        (setq dsh-emacs--current-session "sess-d2")
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (method params cb)
                     (unless (string= method "session/list")
                       (push (list method params) calls))
                     (cond
                      ((string= method "session/modelCatalog")
                       (funcall
                        cb t
                        '((current . ((provider . "g1") (model . "m1")))
                          (groups . [((id . "g1") (name . "DeepSeek")
                                      (models . [((id . "m2")
                                                  (name . "Dup-1"))]))
                                     ((id . "g2") (name . "Qwen")
                                      (models . [((id . "m2")
                                                  (name . "Dup-2"))]))]))))
                      ((string= method "session/selectModel")
                       (funcall cb t nil)))))
                  ;; The user picked the DeepSeek row
                  ((symbol-function 'completing-read)
                   (lambda (&rest _) "m2 [g1|DeepSeek]"))
                  ((symbol-function 'message)
                   (lambda (fmt &rest args)
                     (push (apply #'format fmt args) msgs))))
          (dsh-emacs-select-model)
          (let* ((call (car calls))
                 (params (cadr call)))
            (when (and (string= "session/selectModel" (car call))
                       (string= "g1" (cdr (assq 'provider (cdr (assq 'request params)))))
                       (cl-some (lambda (m)
                                  (string-match-p (regexp-quote "Dup-1 (DeepSeek)") m))
                                msgs))
              (dsh-test-pass "select-model-dup-id-other-row-its-provider")))))
    (kill-buffer buf)))

;; --- Test 47g: vertico-group path → grouping is kept by group-function
;; metadata ---
;; Candidates are bare model rows (no :header candidates) and the row key
;; "  id [provider]" renders a bare id; the group-function metadata maps the
;; key back to the provider display name — so while filtering the framework
;; keeps each provider's group header. assoc still hits the selected row
;; exactly.
(let* ((cands '(("m1" "g1" "DeepSeek" "Model One")
                ("m2" "g2" "Qwen" "Qwen-M")
                ("m2" "g3" "Anthropic" "Same")))
       (pair (dsh-emacs--model-grouped-collection cands))
       (rows (cdr pair))
       (md (funcall (car pair) "" nil 'metadata))
       (gf (alist-get 'group-function (cdr md))))
  (when (and (eq 'dsh-model (alist-get 'category (cdr md)))
             (= 3 (length rows))
             (cl-every (lambda (e) (not (eq :header (car (cdr e))))) rows)
             (string= "DeepSeek" (funcall gf "m1 [g1|DeepSeek]" nil))
             (string= "Qwen" (funcall gf "m2 [g2|Qwen]" nil))
             (string= "Anthropic" (funcall gf "m2 [g3|Anthropic]" nil))

             ;; transform returns the visible string (id prefix + migrated match
             ;; highlight)
             ;; for vertico to render
             (string= "m2" (substring-no-properties
                             (funcall gf "m2 [g2|Qwen]" t)))
             (string= "  m2" (get-text-property 0 'display (car (nth 1 rows))))
             (string= "  m2" (get-text-property 0 'display (car (nth 2 rows)))))
    (dsh-test-pass "model-grouped-collection-keeps-group-metadata")))

;; --- Test 47h: the completion-table-with-metadata compatibility shim ---
;; Session/model pickers, ask multi-select and @ references all hand sort
;; metadata to the completion frontend through this table.  The built-in is
;; Emacs 31-only, so the 27.1 baseline must take the local fallback branch
;; with identical behavior: answer metadata verbatim, complete normally for
;; every other ACTION.  Removing the built-in forces that branch, which
;; otherwise never runs on Emacs 31.
(let ((saved (and (fboundp 'completion-table-with-metadata)
                  (symbol-function 'completion-table-with-metadata))))
  (unwind-protect
      (progn
        (when saved (fmakunbound 'completion-table-with-metadata))
        (let ((table (dsh-emacs--completion-table-with-metadata
                      '("alpha" "beta" "gamma")
                      '((display-sort-function . identity)
                        (cycle-sort-function . identity)
                        (category . dsh-test)))))
          (dsh-test-assert "completion-table-metadata-fallback"
            (equal '(metadata (display-sort-function . identity)
                              (cycle-sort-function . identity)
                              (category . dsh-test))
                   (funcall table "" nil 'metadata))
            (eq #'identity
                (completion-metadata-get
                 (completion-metadata "" table nil) 'display-sort-function))
            (eq 'dsh-test
                (completion-metadata-get
                 (completion-metadata "" table nil) 'category))
            (equal '("alpha" "beta" "gamma") (all-completions "" table nil))
            (equal "alpha" (try-completion "a" table nil))
            (equal '("beta") (all-completions "b" table nil)))))
    (when saved (fset 'completion-table-with-metadata saved))))

;; 47g2: modern vertico (native group-function metadata support, no
;; vertico-group-mode) → takes the grouped path and the selected row is the
;; right provider
(let ((buf (generate-new-buffer " *dsh-model-grouped*"))
      (calls nil)
      (msgs nil))
  (unwind-protect
      (with-current-buffer buf
        (setq dsh-emacs--current-session "sess-g")
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (method params cb)
                     (unless (string= method "session/list")
                       (push (list method params) calls))
                     (cond
                      ((string= method "session/modelCatalog")
                       (funcall
                        cb t
                        '((current . ((provider . "g1") (model . "m1")))
                          (groups . [((id . "g1") (name . "DeepSeek")
                                      (models . [((id . "m2")
                                                  (name . "Dup-1"))]))
                                     ((id . "g2") (name . "Qwen")
                                      (models . [((id . "m2")
                                                  (name . "Dup-2"))]))]))))
                      ((string= method "session/selectModel")
                       (funcall cb t nil)))))
                  ((symbol-function 'completing-read)
                   (lambda (&rest _) "m2 [g2|Qwen]"))
                  ((symbol-function 'message)
                   (lambda (fmt &rest args)
                     (push (apply #'format fmt args) msgs))))
          (let ((vertico-mode t) (vertico--groups nil))
            (dsh-emacs-select-model))
          (let* ((call (car calls))
                 (params (cadr call)))
            (when (and (string= "session/selectModel" (car call))
                       (string= "g2" (cdr (assq 'provider (cdr (assq 'request params)))))
                       (cl-some (lambda (m)
                                  (string-match-p (regexp-quote "Dup-2 (Qwen)") m))
                                msgs))
              (dsh-test-pass "model-grouped-pick-exact-provider")))))
    (kill-buffer buf)))

;; --- Test 47h: the key starts with the id → filtering still matches in the
;; default prefix-completion style ---
;; Key = "m2 [g2|Qwen]" (no leading space): in basic (prefix) style "m2"
;; matches; the key embeds the provider display name so substring style also
;; matches "qwen"; the display property still hides [provider|Name] and renders
;; "  m2".
(let* ((cands '(("m2" "g2" "Qwen" "Qwen-M")
                ("m2" "g3" "Anthropic" "Same")))
       (rows (mapcar (lambda (c) (dsh-emacs--model-row-entry c nil)) cands))
       (raw0 (substring-no-properties (car (nth 0 rows))))
       (raw1 (substring-no-properties (car (nth 1 rows)))))
  (when (and (string-prefix-p "m2" raw0)
             (string-match-p (regexp-quote "Qwen") raw0)
             (string= "  m2" (get-text-property 0 'display (car (nth 0 rows))))
             (string-prefix-p "m2" raw1)
             (string-match-p (regexp-quote "Anthropic") raw1)
             ;; All keys are unique → assoc hits unambiguously
             (= 2 (length (cl-remove-duplicates (mapcar #'car rows)))))
    (dsh-test-pass "model-row-prefix-filterable")))

;; --- Test 47i: locally style the vertico group header inside the picker (the
;; long separator is dropped by default) ---
(progn
  ;; The batch environment has no vertico, so simulate its global variables
  (defvar vertico-group-format "GLOBAL-FORMAT")
  (let ((buf (generate-new-buffer " *dsh-group-fmt*")))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs--model-select-setup-hook t)
          (when (and (equal (buffer-local-value 'vertico-group-format buf)
                            dsh-emacs-model-group-format)
                     ;; The global default is not polluted
                     (string= "GLOBAL-FORMAT"
                              (default-value 'vertico-group-format))
                     ;; The default format contains a %s placeholder
                     (string-match-p "%s" dsh-emacs-model-group-format))
            (dsh-test-pass "model-select-local-group-format")))
      (kill-buffer buf)))
  ;; When grouped is nil (no grouping UI) vertico-group-format is left alone
  (let ((buf (generate-new-buffer " *dsh-group-fmt2*")))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs--model-select-setup-hook nil)
          (unless (assq 'vertico-group-format (buffer-local-variables buf))
            (dsh-test-pass "model-select-nongrouped-leaves-format")))
      (kill-buffer buf))))

;; --- Test 47j: transform moves the match highlight to the id area of the
;; display string, so the row only highlights the id ---
;; Key = "m2 [g2|Qwen]" (display hides the [provider] part); with input "m2",
;; orderless/basic puts completion-match-face on the key's head [0,2). transform
;; returns "  m2" (no display property, the face lands on [2,4), the id area) —
;; neither a full-row background nor a lost highlight; assoc still hits by the
;; original key.
(let* ((pair (dsh-emacs--model-grouped-collection
              '(("m2" "g2" "Qwen" "Qwen-M"))))
       (md (funcall (car pair) "" nil 'metadata))
       (gf (alist-get 'group-function (cdr md)))
       (key (caar (cdr pair)))
       ;; Simulate the orderless/basic match highlight: the match area is at the key's
       ;; head ("m2")
       (hl (copy-sequence key))
       (shown (progn (add-face-text-property 0 2 'completion-match-face t hl)
                     (funcall gf hl t))))
  (when (and (string= "m2" (substring-no-properties shown))
             ;; The highlight moves to the id area [0,2) (no leading space)
             (get-text-property 0 'face shown)
             (null (get-text-property 2 'face shown))
             ;; The display text itself carries the display, no longer relying on a hidden
             ;; part
             (null (get-text-property 0 'display shown))
             ;; assoc still hits the original key (with properties)
             (assoc hl (cdr pair)))
    (dsh-test-pass "model-grouped-transform-keeps-id-highlight")))

;; --- Test 47k: category=dsh-model + identity affixation ---
;; nerd-icons-completion inserts an icon at the head of a candidate row (nil
;; category → right arrow); declaring category as a private symbol → the icon
;; table has no entry → empty string, clean row head;
;; --- Test 47k: metadata carries identity affixation → third-party annotation
;; injection is blocked ---
;; marginalia/cape and friends inject an affixation-function through metadata
;; advice and add an annotation at the end of the row (commonly "->"); we
;; declare identity affixation with no prefix/suffix in the metadata, and
;; vertico--affixate prefers it, so the row stays clean.
(let* ((pair (dsh-emacs--model-grouped-collection
              '(("m1" "g1" "DeepSeek" "Model One")
                ("m2" "g2" "Qwen" "Qwen-M"))))
       (md (funcall (car pair) "" nil 'metadata))
       (aff (alist-get 'affixation-function (cdr md)))
       ;; Simulate third-party injection: some affixation that adds a suffix comes
       ;; first
       (rows (funcall aff '("m1 [g1|DeepSeek]" "m2 [g2|Qwen]"))))
  (when (and aff
             ;; Every row has an empty prefix and suffix
             (cl-every (lambda (r) (and (string= "" (nth 1 r))
                                        (string= "" (nth 2 r))))
                       rows)
             (= 2 (length rows))
             (string= "m1 [g1|DeepSeek]" (car (nth 0 rows))))
    (dsh-test-pass "model-grouped-empty-affixation-blocks-annotations")))

;; --- Test 47l: effort catalog parsing + default precedence ---
(let* ((reasoning '((efforts . [((id . "off") (name . "Off"))
                                ((id . "high") (name . "High"))
                                ((id . "max") (name . "Max"))])
                    (defaultEffort . "high")))
       (choices (dsh-emacs--model-effort-choices reasoning)))
  (when (equal choices '(("Off" . "off")
                         ("High" . "high")
                         ("Max" . "max")))
    (dsh-test-pass "model-effort-choices-parses-options")))

(let* ((reasoning '((efforts . [((id . "off") (name . "Off"))
                                ((id . "high") (name . "High"))
                                ((id . "max") (name . "Max"))])
                    (defaultEffort . "high")))
       (prefer (dsh-emacs--model-effort-default-id reasoning "max"))
       (default (dsh-emacs--model-effort-default-id reasoning nil))
       (bogus (dsh-emacs--model-effort-default-id reasoning "low")))
  (when (and (string= "max" prefer)      ;; The current effort is valid → keep it
             (string= "high" default)     ;; Otherwise defaultEffort
             (string= "high" bogus))      ;; unknown current value → ignore
    (dsh-test-pass "model-effort-default-priority")))

;; An effort entry with no display name → fall back to showing the id
(let* ((reasoning '((efforts . [((id . "t0"))])))
       (choices (dsh-emacs--model-effort-choices reasoning)))
  (when (equal choices '(("t0" . "t0")))
    (dsh-test-pass "model-effort-choice-name-falls-back-to-id")))

;; --- Test 47m: selectModel carries reasoningEffort ---
;; Helper: simulate one round of model selection (completing-read is given
;; PICK2 on the second prompt) and returns reasoningEffort from the selectModel
;; request (:no-call when no request was sent)
(defun dsh-emacs-test--model-effort-run (dir pick2)
  (let ((buf (generate-new-buffer " *dsh-effort-*"))
        (calls nil)
        (cr-n 0))
    (unwind-protect
        (with-current-buffer buf
          (setq dsh-emacs--current-session "sess-t")
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method params cb)
                       (unless (string= method "session/list")
                         (push (list method params) calls)
                         ;; After a successful model switch a session/list refresh follows
                         ;; (fetching the
                         ;; new model's contextPressure snapshot): it is outside this
                         ;; test's assertions,
                         ;; so it neither goes into calls nor invokes the callback (the
                         ;; callback would
                         ;; empty the session cache and pollute the global state of later
                         ;; tests).
                         (funcall cb t
                                  (if (string= method "session/modelCatalog")
                                      dir
                                    '((selected . ((provider . "p1")
                                                   (model . "m1"))))))))))
            (cl-letf (((symbol-function 'completing-read)
                       (lambda (&rest _)
                         (setq cr-n (1+ cr-n))
                         (if (eq cr-n 1) "m1 [g1|DeepSeek]" pick2))))
              (dsh-emacs-select-model)
              (let* ((call (car calls))
                     (params (cadr call)))
                (if (and (string= "session/selectModel" (car call))
                         (string= "m1" (cdr (assq 'model (cdr (assq 'request params))))))
                    (cdr (assq 'reasoningEffort (cdr (assq 'request params))))
                  :no-call)))))
      (kill-buffer buf))))

;; Target model has reasoning: picking Max manually on the second level
;; (different from the default High) → pass max
(let* ((dir '((current . ((provider . "p1") (model . "m0")))
              (groups . [((id . "g1") (name . "DeepSeek")
                          (models . [((id . "m1") (name . "One")
                                      (reasoning . ((efforts . [((id . "off") (name . "Off"))
                                                                ((id . "high") (name . "High"))
                                                                ((id . "max") (name . "Max"))])
                                                    (defaultEffort . "high"))))]))])))
       (eff (dsh-emacs-test--model-effort-run dir "Max")))
  (when (string= "max" eff)
    (dsh-test-pass "select-model-sends-reasoning-effort")))

;; Empty input (RET) → completing-read returns the default → pass the default
;; effort (defaultEffort)
(let* ((dir '((current . ((provider . "p1") (model . "m0")))
              (groups . [((id . "g1") (name . "DeepSeek")
                          (models . [((id . "m1") (name . "One")
                                      (reasoning . ((efforts . [((id . "off") (name . "Off"))
                                                                ((id . "high") (name . "High"))
                                                                ((id . "max") (name . "Max"))])
                                                    (defaultEffort . "high"))))]))])))
       (eff (dsh-emacs-test--model-effort-run dir "")))
  (when (string= "high" eff)
    (dsh-test-pass "select-model-empty-effort-pick-default")))

;; Reselecting the current model (current.reasoningEffort=max, the m1 option
;; includes max) → keep max
(let* ((dir '((current . ((provider . "p1") (model . "m1") (reasoningEffort . "max")))
              (groups . [((id . "g1") (name . "DeepSeek")
                          (models . [((id . "m1") (name . "One")
                                      (reasoning . ((efforts . [((id . "off") (name . "Off"))
                                                                ((id . "max") (name . "Max"))])
                                                    (defaultEffort . "high"))))]))])))
       (eff (dsh-emacs-test--model-effort-run dir "")))
  (when (string= "max" eff)
    (dsh-test-pass "select-model-repick-keeps-current-effort")))

;; The target model has no reasoning option → the request has no
;; reasoningEffort key
(let* ((dir '((current . ((provider . "p1") (model . "m0")))
              (groups . [((id . "g1") (name . "DeepSeek")
                          (models . [((id . "m1") (name . "One"))]))])))
       (eff (dsh-emacs-test--model-effort-run dir "x")))
  (when (null eff)
    (dsh-test-pass "select-model-no-reasoning-omits-effort")))


;; --- Test 48: attachments (image base64 inlined into session/prompt) ---
(let ((png-file (make-temp-file "dsh-test-1px" nil ".png"))
      (calls nil)
      (buf (generate-new-buffer " *dsh-attach-test*")))
  (unwind-protect
      (progn
        (with-temp-file png-file
          (set-buffer-multibyte nil)
          (insert (base64-decode-string
                   "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")))
        (with-current-buffer buf
          (setq dsh-emacs--current-session "sess-a")
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method params _cb)
                       (push (list method params) calls))))
            (dsh-emacs-attach-file png-file "the pixel"))
          (let* ((call (car calls))
                 (params (cadr call))
                 (req (cdr (assq 'request params)))
                 (images (cdr (assq 'images params)))
                 (content (cdr (assq 'content req)))
                 (part (and content (aref content 0)))
                 (img (and content (> (length content) 1)
                           (aref content 1))))
            ;; Canonical wire shape (rpc.md §4.1): an image is a content
            ;; `{type:'image', mediaType, data, name}' block; there is no top-level images
            ;; field (the host schema strips it and the image never reaches the model).
            (when (and (string= "session/prompt" (car call))
                       (null images)
                       (string= "the pixel" (cdr (assq 'text part))))
              (dsh-test-pass "attach-sends-caption"))
            (when (and img
                       (string= "image" (cdr (assq 'type img)))
                       (string= "image/png" (cdr (assq 'mediaType img)))
                       (string-prefix-p "dsh-test-1px" (cdr (assq 'name img)))
                       (string-suffix-p ".png" (cdr (assq 'name img))))
              (dsh-test-pass "attach-sends-image-part"))
            (when (and img (stringp (cdr (assq 'data img)))
                       ;; The base64 of a 1x1 PNG is far longer than an empty string
                       (> (length (cdr (assq 'data img))) 20)
                       ;; No newlines: the wire base64 is one continuous string
                       (not (string-match-p "\n" (cdr (assq 'data img)))))
              (dsh-test-pass "attach-base64-data")))))
    (delete-file png-file)
    (kill-buffer buf)))

;; --- Test 48b: the image block of user/message renders as an [image]
;; placeholder (inline base64) ---
(let ((png-b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")
      (buf (generate-new-buffer " *dsh-image-inline*")))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (dsh-emacs-modeline-setup)
        (dsh-emacs-render-event
         (json-read-from-string
          (concat "{\"type\":\"user/message\",\"seq\":1,\"data\":{\"content\":["
                  "{\"type\":\"text\",\"text\":\"the pixel\"},"
                  "{\"type\":\"image\",\"mediaType\":\"image/png\","
                  "\"data\":\"" png-b64 "\",\"name\":\"pixel.png\"}]}}")))
        (let* ((text (buffer-substring (point-min) (point-max)))
               (pos (string-match "\\[image: pixel\\.png\\]" text))
               (stash (and pos (get-text-property
                                (1+ pos) 'dsh-emacs-image-data text)))
               (img-id (and pos (get-text-property
                                 (1+ pos) 'dsh-emacs-image-id text))))
          ;; No graphics display in batch mode: display is not set, but the bytes
          ;; must already be in the placeholder, so RET-open works; body and
          ;; placeholder each take a line.
          (when (and pos img-id
                     (string-match "the pixel\n\\[image: pixel.png\\]" text)
                     (equal stash (base64-decode-string png-b64)))
            (dsh-test-pass "image-inline-renders-placeholder"))))
    (kill-buffer buf)))

;; --- Test 48c: attachmentId reference block goes through
;; session/attachment backfill placeholder ---
(let ((png-b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")
      (buf (generate-new-buffer " *dsh-image-ref*"))
      (calls nil))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (dsh-emacs-modeline-setup)
        (setq dsh-emacs--buffer-session "sess-ref")
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (method params cb)
                     (push (list method params) calls)
                     (funcall cb t `((data . ,png-b64))))))
          (dsh-emacs-render-event
           (json-read-from-string
            (concat "{\"type\":\"user/message\",\"seq\":2,\"data\":{\"content\":["
                    "{\"type\":\"text\",\"text\":\"look\"},"
                    "{\"type\":\"image\",\"attachmentId\":\"att-1\","
                    "\"mediaType\":\"image/png\",\"name\":\"remote.png\"}]}}"))))
        (let* ((text (buffer-substring (point-min) (point-max)))
               (pos (string-match "\\[image: remote\\.png\\]" text))
               (call (car calls))
               (req (cdr (assq 'request (cadr call))))
               (stash (and pos (get-text-property
                                (1+ pos) 'dsh-emacs-image-data text))))
          (when (and (equal (car call) "session/attachment")
                     (equal (cdr (assq 'sessionId req)) "sess-ref")
                     (equal (cdr (assq 'attachmentId req)) "att-1")
                     (string-match "look\n\\[image: remote.png\\]" text)
                     (equal stash (base64-decode-string png-b64)))
            (dsh-test-pass "image-ref-fetched-via-session-attachment"))))
    (kill-buffer buf)))

;; --- Test 48d: optimistic echo inlines the local attachment as
;; an image block (shown immediately, no RPC needed) ---
(let ((png-b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")
      (buf (generate-new-buffer " *dsh-image-optimistic*")))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (dsh-emacs-modeline-setup)
        (setq dsh-emacs--buffer-session "sess-opt")
        (dsh-emacs--render-user-message-optimistic
         "the pixel"
         (list (list (cons 'mediaType "image/png")
                     (cons 'data png-b64)
                     (cons 'name "pixel.png"))))
        (let* ((text (buffer-substring (point-min) (point-max)))
               (pos (string-match "\\[image: pixel\\.png\\]" text))
               (stash (and pos (get-text-property
                                (1+ pos) 'dsh-emacs-image-data text))))
          (when (and (string-match "the pixel\n\\[image: pixel.png\\]" text)
                     (equal stash (base64-decode-string png-b64)))
            (dsh-test-pass "image-optimistic-echo-inline"))))
    (kill-buffer buf)))

;; --- Test 49: code block copy ---
(let ((buf (generate-new-buffer " *dsh-copy-block*")))
  (unwind-protect
      (with-current-buffer buf
        (insert "before\n```elisp\n(message \"hi\")\n```\nafter\n")
        (dsh-emacs-markdown-replace-markup :force t :highlight-blocks nil)
        ;; Point inside the code block body -> copy
        (goto-char (point-min))
        (when (search-forward "(message" nil t)
          (dsh-emacs-copy-code-block)
          (when (string= "(message \"hi\")" (car kill-ring))
            (dsh-test-pass "copy-code-block-copies-body")))
        ;; Point outside the block -> explicit error instead of silence
        (goto-char (point-min))
        (let ((err (condition-case e
                       (progn (dsh-emacs-copy-code-block) nil)
                     (error (error-message-string e)))))
          (when (and (stringp err)
                     (string-match-p "not inside" err))
            (dsh-test-pass "copy-code-block-errors-outside"))))
    (kill-buffer buf)))

;; The scan must stop at point-max: no code block there is not a code block.
(let ((buf (generate-new-buffer " *dsh-copy-block-max*")))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (insert "plain transcript text\n")
        (goto-char (point-max))
        (dsh-test-assert "copy-code-block-errors-at-point-max"
          (equal "Point is not inside a code block"
                 (condition-case e
                     (progn (dsh-emacs-copy-code-block) nil)
                   (user-error (error-message-string e))))))
    (kill-buffer buf)))

;; --- Test 49b: copy command (assistant message / dwim) ---
(let ((buf (generate-new-buffer " *dsh-copy-assistant*")))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (dsh-emacs-render-user-message
         '((seq . 1) (data . ((content . [((type . "text") (text . "ask me"))])))))
        (dsh-emacs-render-assistant-message
         '((seq . 2)
           (data . ((turn . 1) (step . 1)
                    (message . ((content . [((type . "text")
                                             (text . "First **reply**."))])))))))
        (dsh-emacs-render-tool-call
         '((type . "tool/call") (seq . 3)
           (data . ((callId . "c1") (name . "read")
                    (arguments . "{\"path\":\"/tmp/x\"}")))))
        (dsh-emacs-render-assistant-message
         '((seq . 4)
           (data . ((turn . 1) (step . 2)
                    (message . ((content . [((type . "text")
                                             (text . "Second reply."))])))))))
        (dsh-emacs-copy-assistant-message)
        (dsh-test-assert "copy-assistant-message-excludes-other-roles"
          (equal (car kill-ring) "First reply.\n\nSecond reply.")))
    (kill-buffer buf)))

(defun dsh-test--copy-dwim-fixture ()
  "Return a chat buffer with a user prompt, a reply and a fenced-code reply."
  (let ((buf (generate-new-buffer " *dsh-copy-dwim*")))
    (with-current-buffer buf
      (dsh-emacs-mode)
      (dsh-emacs-render-user-message
       '((seq . 1) (data . ((content . [((type . "text") (text . "ask me"))])))))
      (dsh-emacs-render-assistant-message
       '((seq . 2) (data . ((turn . 1) (step . 1)
                            (message . ((content . [((type . "text")
                                                      (text . "First reply."))])))))))
      (dsh-emacs-render-assistant-message
       '((seq . 3) (data . ((turn . 1) (step . 2)
                            (message . ((content . [((type . "text")
                                                      (text . "Code:\n\n```elisp\n(+ 1 2)\n```"))]))))))))
    buf))

;; copy-dwim: region > code block > message at point > all assistant messages.
(let ((buf (dsh-test--copy-dwim-fixture)))
  (unwind-protect
      (with-current-buffer buf
        (goto-char (point-min))
        (search-forward "(+ 1 2)")
        (goto-char (match-beginning 0))
        (dsh-emacs-copy-dwim)
        (dsh-test-assert "copy-dwim-prefers-code-block-at-point"
          (equal (car kill-ring) "(+ 1 2)"))
        (setq kill-ring nil)
        (goto-char (point-min))
        (search-forward "First reply.")
        (goto-char (match-beginning 0))
        (dsh-emacs-copy-dwim)
        (dsh-test-assert "copy-dwim-copies-message-at-point"
          (equal (car kill-ring) "First reply."))
        (setq kill-ring nil)
        (let ((transient-mark-mode t))
          (goto-char (point-min))
          (search-forward "ask me")
          (set-mark (match-beginning 0))
          (goto-char (match-end 0))
          (activate-mark)
          (dsh-emacs-copy-dwim))
        (dsh-test-assert "copy-dwim-copies-active-region"
          (equal (car kill-ring) "ask me"))
        (deactivate-mark)
        (setq kill-ring nil)
        (goto-char (point-max))
        (dsh-emacs-copy-dwim)
        (let ((last (car kill-ring)))
          (dsh-test-assert "copy-dwim-falls-back-to-last-assistant-message"
            (string-match-p "Code:" last)
            (string-match-p (regexp-quote "(+ 1 2)") last)
            (not (string-match-p "First reply" last))
            (not (string-match-p "ask me" last)))
          (setq kill-ring nil)
          (dsh-emacs-copy-last-assistant-message)
          (dsh-test-assert "copy-last-assistant-message-matches-dwim-fallback"
            (equal (car kill-ring) last)))
        (setq kill-ring nil)
        (dsh-emacs-copy-assistant-message)
        (dsh-test-assert "copy-assistant-message-keeps-every-reply"
          (string-match-p "First reply" (car kill-ring))
          (string-match-p "Code:" (car kill-ring)))
        (dsh-test-assert "copy-dwim-keybinding"
          (eq (lookup-key dsh-emacs-mode-map (kbd "C-c C-w"))
              #'dsh-emacs-copy-dwim)
          (null (lookup-key dsh-emacs-mode-map (kbd "C-c C-e")))
          (null (lookup-key dsh-emacs-mode-map (kbd "C-c C-k")))))
    (kill-buffer buf)))

(let ((buf (generate-new-buffer " *dsh-copy-assistant-empty*")))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (dsh-emacs-render-user-message
         '((seq . 1) (data . ((content . [((type . "text") (text . "hi"))])))))
        (dsh-test-assert "copy-assistant-message-errors-without-replies"
          (equal "No assistant messages in this transcript"
                 (condition-case e
                     (progn (dsh-emacs-copy-assistant-message) nil)
                   (user-error (error-message-string e))))))
    (kill-buffer buf)))

;; A live stream is tagged from its first delta, before its final message.
(let ((buf (generate-new-buffer " *dsh-copy-assistant-stream*")))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (dsh-emacs-render--start-assistant-stream
         '((data . ((turn . 1) (step . 1)))) "partial")
        (dsh-emacs-copy-assistant-message)
        (dsh-test-assert "copy-assistant-message-includes-live-stream"
          (equal (car kill-ring) "partial")))
    (kill-buffer buf)))

;; A timer flush appends to the same tagged run, even while Markdown is
;; deferred, so a copy mid-stream never returns only the first delta.
(let ((buf (generate-new-buffer " *dsh-copy-assistant-flush*")))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (let* ((dsh-emacs-stream-markdown-limit 1)
               (event '((data . ((turn . 1) (step . 1))))))
          (dsh-emacs-render--start-assistant-stream event "Hello ")
          (dsh-emacs-render--start-assistant-stream event "world")
          (dsh-emacs-render--flush-stream)
          (dsh-emacs-copy-last-assistant-message)
          (dsh-test-assert "copy-last-assistant-message-includes-flushed-deltas"
            (equal (car kill-ring) "Hello world"))))
    (kill-buffer buf)))

;; --- Test 50: fork session ---
(let ((opened nil)
      (listed nil)
      (calls nil))
  (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
             (lambda (method params cb)
               (push (list method params) calls)
               (when (string= method "session/fork")
                 (funcall cb t '((sessionId . "child-1"))))))
            ((symbol-function 'dsh-emacs-open-session)
             (lambda (sid) (setq opened sid)))
            ((symbol-function 'dsh-emacs-list-sessions)
             (lambda () (setq listed t))))
    (dsh-emacs-fork-session "parent-1")
    (let* ((call (car calls))
           (params (cadr call)))
      (when (and (string= "session/fork" (car call))
                 (string= "parent-1"
                          (cdr (assq 'sessionId
                                     (cdr (assq 'request params))))))
        (dsh-test-pass "fork-passes-session-id")))
    (when (string= "child-1" opened)
      (dsh-test-pass "fork-opens-child"))
    (when listed
      (dsh-test-pass "fork-refreshes-list"))))

;; --- Test 51: session list workspace filtering ---
(let* ((sessions (list (list (cons 'sessionId "s1") (cons 'updatedAt 100)
                            (cons 'projections
                                  (list (cons 'values (list (cons 'title "Alpha"))))))
                      (list (cons 'sessionId "s2") (cons 'updatedAt 200)
                            (cons 'projections
                                  (list (cons 'values (list (cons 'title "Beta"))))))
                      (list (cons 'sessionId "s3") (cons 'updatedAt 300)
                            (cons 'projections
                                  (list (cons 'values (list (cons 'title "Gamma"))))))))
      (workspaces (list (list (cons 'workspaceId "w1") (cons 'title "WS A")
                              (cons 'sessionIds ["s1" "s2"]))))
      (sessions-s (dsh-emacs-test--session-items sessions))
      (workspaces-s (mapcar #'dsh-protocol-workspace--from-alist workspaces)))
  ;; Filter to w1: only WS A members remain, Ungrouped bucket suppressed
  ;; Note: the `filtered' initializer must be evaluated after the filter
  ;; binding exists, hence let* here (let evaluates initializers before
  ;; binding, reading the old value)
  (let* ((dsh-emacs--archived-sessions nil)
         (dsh-emacs-session--filter-ws-id "w1")
         (filtered (dsh-emacs-session--group-sessions sessions-s workspaces-s)))
    (when (and (= 1 (length filtered))
               (equal "WS A" (plist-get (car filtered) :label))
               (= 2 (length (plist-get (car filtered) :sessions))))
      (dsh-test-pass "session-filter-restricts-workspace")))
  ;; No filter: both WS A and Ungrouped buckets present
  (let* ((dsh-emacs--archived-sessions nil)
         (dsh-emacs-session--filter-ws-id nil)
         (grouped (dsh-emacs-session--group-sessions sessions-s workspaces-s)))
    (when (and (= 2 (length grouped))
               (cl-some (lambda (g) (equal "WS A" (plist-get g :label))) grouped)
               (cl-some (lambda (g) (equal "Ungrouped" (plist-get g :label))) grouped))
      (dsh-test-pass "session-group-keeps-ungrouped")))
  ;; Render level: while filtering, other workspaces / ungrouped
  ;; sessions are not visible
  (let ((buf (generate-new-buffer " *dsh-filter-render*")))
    (unwind-protect
        (with-current-buffer buf
          (let ((dsh-emacs--sessions sessions-s)
                (dsh-emacs--workspaces workspaces-s)
                (dsh-emacs--archived-sessions nil)
                (dsh-emacs-session--filter-ws-id "w1")
                (dsh-emacs-session--filter-ws-title "WS A"))
            (dsh-emacs-session--render)
            (let ((txt (buffer-substring-no-properties
                           (point-min) (point-max))))
              ;; Rows sorted by recency (Beta before Alpha); match the whole span
              ;; to avoid order dependence
              (when (and (string-match-p "Filter: WS A" txt)
                         (string-match-p "Alpha" txt)
                         (string-match-p "Beta" txt)
                         (not (string-match-p "Gamma" txt)))
                (dsh-test-pass "session-filter-render-hides-other-sessions")))))
      (kill-buffer buf))))

;; --- Test 51b: session list workspace collapse survives redraw ---
(dsh-test-assert "workspace-fold-tab-keybinding"
  (eq (lookup-key dsh-emacs-session-mode-map (kbd "TAB"))
      #'dsh-emacs-session-toggle-workspace))

(let* ((sessions (dsh-emacs-test--session-items
                  (list (list (cons 'sessionId "s1") (cons 'updatedAt 100)
                              (cons 'projections
                                    (list (cons 'values
                                                (list (cons 'title "Alpha")))))))))
       (workspaces (list (dsh-protocol-workspace--from-alist
                          (list (cons 'workspaceId "w1")
                                (cons 'title "WS A")
                                (cons 'sessionIds ["s1"])))))
       (buf (generate-new-buffer " *dsh-workspace-fold*")))
  (unwind-protect
      (with-current-buffer buf
        (let ((dsh-emacs--sessions sessions)
              (dsh-emacs--workspaces workspaces)
              (dsh-emacs--archived-sessions nil))
          (dsh-emacs-session--render)
          (goto-char (point-min))
          (search-forward "WS A")
          (beginning-of-line)
          (dsh-emacs-session-toggle-workspace)
          (dsh-test-assert "workspace-fold-keeps-header-focused"
            (equal (dsh-emacs-workspace-id-at-point) "w1"))
          (let ((folded (buffer-substring-no-properties
                         (point-min) (point-max))))
            (dsh-test-assert "workspace-fold-hides-session"
              (and (string-match-p "▸ WS A  (1)" folded)
                   (not (string-match-p "Alpha" folded)))))
          (dsh-emacs-session--render)
          (let ((refreshed (buffer-substring-no-properties
                            (point-min) (point-max))))
            (dsh-test-assert "workspace-fold-survives-render"
              (and (string-match-p "▸ WS A  (1)" refreshed)
                   (not (string-match-p "Alpha" refreshed)))))
          (goto-char (point-min))
          (search-forward "WS A")
          (beginning-of-line)
          (dsh-emacs-open-session-at-point)
          (dsh-test-assert "workspace-ret-expands"
            (string-match-p "Alpha"
                            (buffer-substring-no-properties
                             (point-min) (point-max))))))
    (kill-buffer buf)))

(let* ((sessions (dsh-emacs-test--session-items
                  (list (list (cons 'sessionId "loose")
                              (cons 'updatedAt 100)
                              (cons 'projections
                                    (list (cons 'values
                                                (list (cons 'title
                                                            "Loose")))))))))
       (buf (generate-new-buffer " *dsh-ungrouped-fold*")))
  (unwind-protect
      (with-current-buffer buf
        (let ((dsh-emacs--sessions sessions)
              (dsh-emacs--workspaces nil)
              (dsh-emacs--archived-sessions nil))
          (dsh-emacs-session--render)
          (goto-char (point-min))
          (search-forward "Ungrouped")
          (beginning-of-line)
          (dsh-emacs-session-toggle-workspace)
          (let ((folded (buffer-substring-no-properties
                         (point-min) (point-max))))
            (dsh-test-assert "ungrouped-fold-hides-session"
              (and (string-match-p "▸ Ungrouped  (1)" folded)
                   (not (string-match-p "Loose" folded)))))))
    (kill-buffer buf)))

(let* ((sessions (dsh-emacs-test--session-items
                  (list (list (cons 'sessionId "default-loose")
                              (cons 'updatedAt 100)
                              (cons 'projections
                                    (list (cons 'values
                                                (list (cons 'title
                                                            "Default Loose")))))))))
       (buf (generate-new-buffer " *dsh-workspace-fold-default*")))
  (unwind-protect
      (with-current-buffer buf
        (let ((dsh-emacs--sessions sessions)
              (dsh-emacs--workspaces nil)
              (dsh-emacs--archived-sessions nil)
              (dsh-emacs-workspaces-collapsed-by-default t))
          (dsh-emacs-session--render)
          (dsh-test-assert "workspace-fold-default-collapsed"
            (not (string-match-p
                  "Default Loose"
                  (buffer-substring-no-properties (point-min) (point-max)))))
          (dsh-emacs-expand-workspaces)
          (dsh-test-assert "workspace-expand-workspaces-shows-session"
            (string-match-p
             "Default Loose"
             (buffer-substring-no-properties (point-min) (point-max))))
          (dsh-emacs-collapse-workspaces)
          (dsh-test-assert "workspace-collapse-workspaces-hides-session"
            (not (string-match-p
                  "Default Loose"
                  (buffer-substring-no-properties
                   (point-min) (point-max)))))))
    (kill-buffer buf)))

;; --- Test 52: input history M-p / M-n ---
;; Pinned to cross-session mode on purpose: this test exercises the browse
;; mechanics over the shared list (the new default is per-session; see 52b).
(let ((old-hist dsh-emacs--input-history)
      (old-pos dsh-emacs--input-history-pos)
      (old-pending dsh-emacs--input-history-pending)
      (dsh-emacs-input-history-cross-session t)
      (buf (generate-new-buffer " *dsh-hist-test*")))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (dsh-emacs--push-input-history "first")
        (dsh-emacs--push-input-history "second")
        (dsh-emacs--replace-input "typed")
        (dsh-emacs-input-history-back)          ; newest "second"
        (when (string= "second" (dsh-emacs--get-input))
          (dsh-test-pass "input-history-back-shows-newest"))
        (dsh-emacs-input-history-back)          ; older "first"
        (when (string= "first" (dsh-emacs--get-input))
          (dsh-test-pass "input-history-back-older"))
        (dsh-emacs-input-history-forward)       ; back to "second"
        (when (string= "second" (dsh-emacs--get-input))
          (dsh-test-pass "input-history-forward-newer"))
        (dsh-emacs-input-history-forward)       ; restores pre-browse "typed" input
        (when (string= "typed" (dsh-emacs--get-input))
          (dsh-test-pass "input-history-forward-restores-pending")))
    (kill-buffer buf)
    (setq dsh-emacs--input-history old-hist
          dsh-emacs--input-history-pos old-pos
          dsh-emacs--input-history-pending old-pending)))

;; --- Test 53: enters history after submit (submit pushes back +
;; state resets) ---
(let ((old-hist dsh-emacs--input-history)
      (old-pos dsh-emacs--input-history-pos)
      (buf (generate-new-buffer " *dsh-hist2-test*")))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (setq dsh-emacs--current-session "sess-h")
        (setq dsh-emacs--input-history-pos 0)   ; pretend to be in browsing state
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (method params cb) (funcall cb t '((accepted . t))))))
          (dsh-emacs--submit-prompt "submitted text"))
        (when (and (string= "submitted text" (car dsh-emacs--input-history))
                   (null dsh-emacs--input-history-pos))
          (dsh-test-pass "submit-prompt-records-history-and-resets")))
    (kill-buffer buf)
    (setq dsh-emacs--input-history old-hist
          dsh-emacs--input-history-pos old-pos)))

;; --- Test 52b: per-session history — with cross-session off, M-p/M-n only recall this session ---
;; Regression: history used to be a single global list, so M-p/M-n in any
;; session could surface other sessions' messages.  With
;; `dsh-emacs-input-history-cross-session' nil, recall is isolated per
;; session; every submit still lands in BOTH scopes (global + own session),
;; so toggling the option never loses history.
(let ((old-hist dsh-emacs--input-history)
      (old-opt dsh-emacs-input-history-cross-session)
      (buf-a (generate-new-buffer " *dsh-hist-a*"))
      (buf-b (generate-new-buffer " *dsh-hist-b*")))
  (unwind-protect
      (progn
        (setq dsh-emacs-input-history-cross-session nil)
        (with-current-buffer buf-a
          (dsh-emacs-mode)
          (setq-local dsh-emacs--buffer-session "sess-a")
          (dsh-emacs--push-input-history "a1")
          (dsh-emacs--push-input-history "a2"))
        (with-current-buffer buf-b
          (dsh-emacs-mode)
          (setq-local dsh-emacs--buffer-session "sess-b")
          (dsh-emacs--push-input-history "b1")
          ;; B sees only its own submissions: newest is b1, not the global a2
          (dsh-emacs-input-history-back)
          (dsh-test-assert "per-session-history-b-newest"
            (string= "b1" (dsh-emacs--get-input)))
          ;; Back again: B has nothing older — the input stays b1
          (dsh-emacs-input-history-back)
          (dsh-test-assert "per-session-history-b-exhausted"
            (string= "b1" (dsh-emacs--get-input))))
        ;; A's recall is still its own: newest is a2 (browsing B never
        ;; shifted A's browse position)
        (with-current-buffer buf-a
          (dsh-emacs-input-history-back)
          (dsh-test-assert "per-session-history-a-newest"
            (string= "a2" (dsh-emacs--get-input))))
        ;; Double-write: the shared global list still accumulates, so
        ;; switching back to cross-session mode recalls everything again.
        (dsh-test-assert "per-session-records-global-too"
          (string= "b1" (car dsh-emacs--input-history))))
    (setq dsh-emacs-input-history-cross-session old-opt)
    (setq dsh-emacs--input-history old-hist)
    (remhash "sess-a" dsh-emacs--input-history-by-session)
    (remhash "sess-b" dsh-emacs--input-history-by-session)
    (kill-buffer buf-a)
    (kill-buffer buf-b)))

;; --- Test 52c: cross-session mode recalls the shared history ---
(let ((old-hist dsh-emacs--input-history)
      (old-opt dsh-emacs-input-history-cross-session)
      (buf (generate-new-buffer " *dsh-hist-cross*")))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (setq-local dsh-emacs--buffer-session "sess-c")
        (setq dsh-emacs-input-history-cross-session t)
        (dsh-emacs--push-input-history "global-1")
        (dsh-emacs-input-history-back)
        (dsh-test-assert "cross-session-back-shows-shared-newest"
          (string= "global-1" (dsh-emacs--get-input))))
    (setq dsh-emacs-input-history-cross-session old-opt)
    (kill-buffer buf)))

;; --- Test 52d: first entry into a session recalls history (backfill) ---
;; Regression: per-session history only held prompts submitted in the
;; current Emacs run, so entering an existing session left M-p/M-n empty.
;; Fix: loading history backfills the session's recall list from the
;; user/message texts in the window (texts already present are skipped, so
;; reloading never duplicates; the shared cross-session list is untouched).
(let ((old-hist dsh-emacs--input-history)
      (old-opt dsh-emacs-input-history-cross-session)
      (buf (generate-new-buffer " *dsh-seed-test*")))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (setq-local dsh-emacs--buffer-session "sess-seed")
        (setq dsh-emacs-input-history-cross-session nil)
        ;; History window: old → assistant → newer (seq ascending, wire order)
        (dsh-emacs--seed-input-history
         '((("event" . ((type . "user/message") (seq . 1)
                        (data . ((content . [((type . "text") (text . "old"))]))))))
           (("event" . ((type . "assistant/message") (seq . 2)
                        (data . ((turn . 1))))))
           (("event" . ((type . "user/message") (seq . 3)
                        (data . ((content . [((type . "text") (text . "newer"))])))))))
         "sess-seed")
        (dsh-test-assert "seed-fills-per-session-newest-first"
          (equal '("newer" "old")
                 (gethash "sess-seed" dsh-emacs--input-history-by-session)))
        ;; Reloading the same window: texts already present are all skipped,
        ;; the list stays unchanged
        (dsh-emacs--seed-input-history
         '((("event" . ((type . "user/message") (seq . 1)
                        (data . ((content . [((type . "text") (text . "old"))]))))))
           (("event" . ((type . "user/message") (seq . 3)
                        (data . ((content . [((type . "text") (text . "newer"))])))))))
         "sess-seed")
        (dsh-test-assert "seed-idempotent-on-reload"
          (equal '("newer" "old")
                 (gethash "sess-seed" dsh-emacs--input-history-by-session)))
        ;; Seeding never touches the shared cross-session list
        (dsh-test-assert "seed-untouches-global-list"
          (null (member "old" dsh-emacs--input-history)))
        ;; Browsing: per-session M-p jumps straight to the newest recalled message
        (dsh-emacs-input-history-back)
        (dsh-test-assert "seed-recallable-via-M-p"
          (string= "newer" (dsh-emacs--get-input))))
    (remhash "sess-seed" dsh-emacs--input-history-by-session)
    (setq dsh-emacs-input-history-cross-session old-opt)
    (setq dsh-emacs--input-history old-hist)
    (kill-buffer buf)))

;; --- Test 52e: opening a session (follow snapshot) seeds recall for M-p/M-n ---
(let ((old-hist dsh-emacs--input-history)
      (old-opt dsh-emacs-input-history-cross-session)
      (buf (generate-new-buffer " *dsh-seed-load*")))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (setq-local dsh-emacs--buffer-session "sess-load")
        (setq dsh-emacs-input-history-cross-session nil)
        ;; The `session/follow' snapshot is the opening history seed now: it
        ;; renders the records and backfills the per-session M-p/M-n recall.
        (dsh-emacs-events--follow-snapshot
         (current-buffer)
         '((type . "snapshot")
           (cursor . 10)
           (records .
                    [((type . "event")
                      (event . ((type . "user/message") (seq . 10)
                                (data . ((content .
                                          [((type . "text")
                                            (text . "hist-1"))]))))))])))
        (dsh-emacs-input-history-back)
        (dsh-test-assert "follow-snapshot-seeds-recall"
          (and (string= "hist-1" (dsh-emacs--get-input))
               (equal '("hist-1")
                      (gethash "sess-load" dsh-emacs--input-history-by-session)))))
    (remhash "sess-load" dsh-emacs--input-history-by-session)
    (setq dsh-emacs-input-history-cross-session old-opt)
    (setq dsh-emacs--input-history old-hist)
    (kill-buffer buf)))

;; --- Test 52f: host-injected user messages never enter M-p recall ---
;; Regression: the host appends its own model-facing `user/message' copies
;; (workspace instructions, runtime-context snapshots, goal/subagent
;; notices) to the same surface, naming their origin in `data.source.kind'.
;; The transcript already hides them, but the history seeder took every
;; user/message, so M-p recalled a `<system-reminder>' wall of text the
;; user never typed.
(let ((old-hist dsh-emacs--input-history)
      (old-opt dsh-emacs-input-history-cross-session)
      (buf (generate-new-buffer " *dsh-seed-injected*")))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (setq-local dsh-emacs--buffer-session "sess-injected")
        (setq dsh-emacs-input-history-cross-session nil)
        (dsh-emacs--seed-input-history
         '((("event" . ((type . "user/message") (seq . 1)
                        (data . ((content . [((type . "text")
                                              (text . "real prompt"))]))))))
           (("event" . ((type . "user/message") (seq . 2)
                        (data . ((content .
                                          [((type . "text")
                                            (text . "<system-reminder>AGENTS.md</system-reminder>"))])
                                 (source . ((kind . "agent-instructions"))))))))
           (("event" . ((type . "user/message") (seq . 3)
                        (data . ((content .
                                          [((type . "text")
                                            (text . "Current runtime context."))])
                                 (source . ((kind . "plugin"))))))))
           (("event" . ((type . "user/message") (seq . 4)
                        (data . ((content . [((type . "text")
                                              (text . "legacy no-source"))])))))))
         "sess-injected")
        (dsh-test-assert "seed-skips-host-injected-user-messages"
          (equal '("legacy no-source" "real prompt")
                 (gethash "sess-injected" dsh-emacs--input-history-by-session)))
        ;; The reported symptom: M-p lands on the recalled prompt, never on
        ;; an injected reminder
        (dsh-emacs-input-history-back)
        (dsh-test-assert "seed-recall-never-offers-a-system-reminder"
          (and (string= "legacy no-source" (dsh-emacs--get-input))
               (null (cl-find-if
                      (lambda (entry)
                        (string-match-p "\\`<system-reminder>" entry))
                      (gethash "sess-injected"
                               dsh-emacs--input-history-by-session))))))
    (remhash "sess-injected" dsh-emacs--input-history-by-session)
    (setq dsh-emacs-input-history-cross-session old-opt)
    (setq dsh-emacs--input-history old-hist)
    (kill-buffer buf)))

;; Regression: undo immediately after sending restores the cleared draft.
(with-temp-buffer
  (dsh-emacs-mode)
  (setq-local dsh-emacs--buffer-session "undo-submit")
  (let ((dsh-emacs--current-session "undo-submit"))
    (goto-char dsh-emacs--input-marker)
    (insert "draft to send")
    (undo-boundary)
    (run-hooks 'pre-command-hook)
    (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
               (lambda (&rest _) nil)))
      (dsh-emacs--submit-plain "draft to send"))
    (undo-boundary)
    (let ((last-command 'dsh-emacs-send-or-stop) (this-command 'undo)
          (pending-undo-list nil)
          (undo-equiv-table (make-hash-table :test 'eq))
          (transcript (buffer-substring-no-properties
                       (point-min) dsh-emacs--input-marker)))
      (run-hooks 'pre-command-hook)
      (undo)
      (run-hooks 'post-command-hook)
      (dsh-test-assert "undo-send-restores-draft-without-changing-echo"
        (equal (dsh-emacs--get-input) "draft to send")
        (= (point) (dsh-emacs--input-end))
        (equal transcript (buffer-substring-no-properties
                           (point-min) dsh-emacs--input-marker))))))

;; --- Test 52g: undo/redo covers the input area, never the transcript ---
;; A chat buffer is a live view: rendered messages, tool cards and streamed
;; bodies must stay out of the undo history (undo binds `inhibit-read-only'
;; itself, so the transcript's read-only property cannot protect it), while
;; typing after `❯ ' stays undoable.
(let ((buf (generate-new-buffer " *dsh-undo*")))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        ;; A programmatic transcript write leaves no undo entry at all
        (dsh-emacs-render--insert-chat-message
         "agent reply" 'dsh-emacs-assistant-body-face
         (dsh-emacs-render--input-insert-point) nil 'assistant)
        (dsh-test-assert "undo-transcript-write-not-recorded"
          (null buffer-undo-list))
        ;; Typing in the input is recorded and undoable (the command loop
        ;; closes the group with an undo boundary after every command)
        (goto-char (dsh-emacs--input-end))
        (insert "draft")
        (undo-boundary)
        (dsh-test-assert "undo-input-edit-recorded"
          (consp buffer-undo-list))
        (let ((last-command nil) (this-command nil) (pending-undo-list nil)
              (undo-equiv-table (make-hash-table :test 'eq)))
          (undo)
          (dsh-test-assert "undo-clears-the-draft-not-the-transcript"
            (and (string= "" (dsh-emacs--get-input))
                 (string-match-p "agent reply" (buffer-string))))
          (if (fboundp 'undo-redo)
              (undo-redo)
            ;; Emacs 27 redoes by starting a new undo sequence.
            (undo-boundary)
            (let ((last-command nil)) (undo)))
          (dsh-test-assert "undo-redo-restores-the-draft"
            (and (string= "draft" (dsh-emacs--get-input))
                 (string-match-p "agent reply" (buffer-string))))))
    (kill-buffer buf)))

;; --- Test 52h: a transcript write rebuilds the input's undo history ---
;; Undo entries hold absolute positions that Emacs does not adjust when text
;; lands elsewhere, so a message rendered above the input leaves the records
;; made for the draft pointing at transcript text.  The stale flag is set by
;; `after-change-functions' and acted on by `pre-command-hook' before the
;; command can use such a record.
(let ((buf (generate-new-buffer " *dsh-undo-shift*")))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (goto-char (dsh-emacs--input-end))
        (insert "first draft")
        (dsh-emacs-render--insert-chat-message
         "streamed reply" 'dsh-emacs-assistant-body-face
         (dsh-emacs-render--input-insert-point) nil 'assistant)
        (dsh-test-assert "undo-stale-flagged-after-transcript-write"
          dsh-emacs--undo-stale)
        ;; `pre-command-hook' runs this before the command can use a record
        (run-hooks 'pre-command-hook)
        (dsh-test-assert "undo-history-rebuilt-around-the-input"
          (and (null dsh-emacs--undo-stale)
               (equal (list nil (cons (marker-position dsh-emacs--input-marker)
                                      (dsh-emacs--input-end)))
                      buffer-undo-list)))
        (let ((last-command nil) (this-command nil) (pending-undo-list nil)
              (undo-equiv-table (make-hash-table :test 'eq)))
          (undo)
          (dsh-test-assert "undo-after-transcript-write-spares-the-transcript"
            (and (string= "" (dsh-emacs--get-input))
                 (string-match-p "streamed reply" (buffer-string))))
          (run-hooks 'post-command-hook)
          ;; Undo removed the draft: point is its (now empty) end
          (dsh-test-assert "undo-leaves-point-at-the-input-start"
            (= (point) (marker-position dsh-emacs--input-marker)))
          ;; Repairing the draft must also move the cursor back for typing:
          ;; `undo' parks point at the restored region's start on its own.
          (if (fboundp 'undo-redo)
              (undo-redo)
            (undo-boundary)
            (let ((last-command nil)) (undo)))
          (run-hooks 'post-command-hook)
          (dsh-test-assert "redo-parks-point-after-the-restored-draft"
            (and (string= "first draft" (dsh-emacs--get-input))
                 (= (point) (dsh-emacs--input-end))))))
    (kill-buffer buf)))

;; --- Test 52i: typing after a rebuild is undoable step by step ---
(let ((buf (generate-new-buffer " *dsh-undo-steps*")))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (goto-char (dsh-emacs--input-end))
        (insert "draft")
        (dsh-emacs-render--insert-chat-message
         "reply" 'dsh-emacs-assistant-body-face
         (dsh-emacs-render--input-insert-point) nil 'assistant)
        (dsh-emacs--reset-undo-history)
        ;; Typing after the rebuild records normal granular entries
        (goto-char (dsh-emacs--input-end))
        (insert " more")
        (undo-boundary)
        (let ((last-command nil) (this-command nil) (pending-undo-list nil)
              (undo-equiv-table (make-hash-table :test 'eq)))
          (undo)
          (dsh-test-assert "undo-after-rebuild-drops-the-last-typing"
            (string= "draft" (dsh-emacs--get-input)))
          (run-hooks 'post-command-hook)
          (if (fboundp 'undo-redo)
              (undo-redo)
            (undo-boundary)
            (let ((last-command nil)) (undo)))
          (run-hooks 'post-command-hook)
          (dsh-test-assert "redo-parks-point-after-the-typing-it-restores"
            (and (string= "draft more" (dsh-emacs--get-input))
                 (= (point) (dsh-emacs--input-end))))))
    (kill-buffer buf)))

;; --- Test 55: thinking face has no explicit background (inherits
;; the theme background) ---
(let ((bg (face-attribute 'dsh-emacs-thinking-face :background nil)))
  (when (or (null bg)
            (memq bg '(unspecified unspecified-bg)))
    (dsh-test-pass "thinking-face-no-background")))

;; --- Test 56: in a think line only the label carries thinking-face;
;; preview and expanded body use the muted thinking-body-face
;; (regression: the whole block was covered by thinking-face, so
;; preview / body inherited the label's orange bold) ---
(let ((buf (generate-new-buffer " *dsh-think-face*"))
      (dsh-emacs-thinking-expand-by-default t))
  (unwind-protect
      (with-current-buffer buf
        (insert "###HEAD\n")
        (dsh-emacs-render--render-thinking-block
         "t" "b1" "first body line\nsecond body line" 1 (point-max))
        (goto-char (point-min))
        (dsh-test-assert "thinking-label-gets-thinking-face"
          (and (search-forward "Think" nil t)
               (memq 'dsh-emacs-thinking-face
                     (dsh-test--faces-at (match-beginning 0)))
               ;; the title keeps the fragment title face (bold)
               (memq 'dsh-emacs-ui-label-face
                     (dsh-test--faces-at (match-beginning 0)))))
        ;; The icon (start of the label line) likewise keeps thinking-face:
        ;; the terminal glyph fallback must not turn grey, and the graphical
        ;; SVG is already colored with the thinking color
        (goto-char (point-min))
        (dsh-test-assert "thinking-label-icon-gets-thinking-face"
          (and (search-forward "✶" nil t)
               (memq 'dsh-emacs-thinking-face
                     (dsh-test--faces-at (match-beginning 0)))))
        (goto-char (point-min))
        (dsh-test-assert "thinking-preview-uses-body-face"
          (and (search-forward "first body line" nil t)
               (memq 'dsh-emacs-thinking-body-face
                     (dsh-test--faces-at (match-beginning 0)))
               (not (memq 'dsh-emacs-thinking-face
                          (dsh-test--faces-at (match-beginning 0))))
               ;; the preview is a summary, not a title: it must not inherit
               ;; the title's bold weight
               (not (memq 'dsh-emacs-ui-label-face
                          (dsh-test--faces-at (match-beginning 0))))))
        ;; Same for expanded body lines: body face, not label face
        (goto-char (point-min))
        (dsh-test-assert "thinking-body-uses-body-face"
          (and (search-forward "second body line" nil t)
               (memq 'dsh-emacs-thinking-body-face
                     (dsh-test--faces-at (match-beginning 0)))
               (not (memq 'dsh-emacs-thinking-face
                          (dsh-test--faces-at (match-beginning 0)))))))
    (kill-buffer buf)))

;; The think body during streaming (waiting for a response) likewise
;; uses the muted body face; only the header label keeps thinking-face.
(with-temp-buffer
  (dsh-emacs-render--start-thinking-stream
   '((data . ((turn . 1) (step . 1)))) "live reasoning")
  (dsh-emacs-render--flush-thinking)
  (goto-char (point-min))
  (dsh-test-assert "thinking-stream-body-uses-body-face"
    (and (search-forward "live reasoning" nil t)
         (memq 'dsh-emacs-thinking-body-face
               (dsh-test--faces-at (match-beginning 0)))
         (not (memq 'dsh-emacs-thinking-face
                    (dsh-test--faces-at (match-beginning 0)))))))

;; --- Test 56b: tool card state coloring covers only the header line;
;; the expanded body (IN/OUT) must not inherit it (generic ioCard such
;; as Edit/Read; regression: the old whole-block face tinted the body
;; green/red bold too) ---
(dolist (case '(("read" "{\"path\":\"foo.el\"}" nil 0 "line one\nline two")
                ("edit" "{\"path\":\"bar.el\"}" t 1 "no match found")))
  (let ((buf (generate-new-buffer " *dsh-tool-face*")))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-mode)
          (dsh-emacs-modeline-setup)
          ;; The card must be expanded, otherwise the body range is empty and
          ;; the "body not tinted" assertion passes vacuously.
          (setq-local dsh-emacs-tool-expand-by-default t)
          (let* ((name (nth 0 case))
                 (args (nth 1 case))
                 (is-error (nth 2 case))
                 (exit-code (nth 3 case))
                 (out (nth 4 case))
                 (state-face (if is-error
                                 'dsh-emacs-tool-error-face
                               'dsh-emacs-tool-success-face)))
            (dsh-emacs-render-tool-call
             (dsh-emacs-test--tool-call-event 1 "c1" name args))
            (dsh-emacs-render-tool-result
             (dsh-emacs-test--tool-result-event 2 "c1" is-error exit-code out))
            (let* ((ns (dsh-emacs-render--make-namespace))
                   (block (dsh-emacs-ui-find-block ns "tool-c1"))
                   (header-end (and block
                                    (save-excursion
                                      (goto-char (car block))
                                      (line-end-position))))
                   (body-start (and block
                                    (save-excursion
                                      (goto-char (car block))
                                      (forward-line 1)
                                      (point)))))
              (dsh-test-assert (format "tool-%s-header-tinted" name)
                (and block header-end
                     (seq-every-p
                      (lambda (pos)
                        (memq state-face (dsh-test--faces-at pos)))
                      (number-sequence (car block) header-end))))
              ;; The body must really be expanded and contain the result text;
              ;; an empty range makes the assertion vacuous
              (dsh-test-assert (format "tool-%s-body-not-tinted" name)
                (and block body-start (< body-start (cdr block))
                     (string-match-p (regexp-quote (car (split-string out "\n")))
                                     (buffer-substring-no-properties
                                      body-start (cdr block)))
                     (seq-every-p
                      (lambda (pos)
                        (not (memq state-face (dsh-test--faces-at pos))))
                      (number-sequence body-start (1- (cdr block)))))))))
      (kill-buffer buf))))

;; --- Test 56c: a settled tool error shows `error.reason' (dsh 0.1.6) ---
;; The host keeps the raw user-facing reason OUTSIDE the model-facing
;; `message', so the card is the only place a refusal explains itself:
;; without it the ioCard/bash footer says just "✗ failed"/"✗ exit N".
(dolist (case '(("grep" "{\"pattern\":\"x\"}" nil "✗ failed — Auto review denied this call")
                ("bash" "{\"command\":\"rm -rf /\"}" 1 "✗ exit 1 — Auto review denied this call")))
  (let ((buf (generate-new-buffer " *dsh-tool-error-reason*")))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-mode)
          (dsh-emacs-modeline-setup)
          ;; The status line lives in the body, so expand it: a collapsed
          ;; card would make the assertion vacuous.
          (setq-local dsh-emacs-tool-expand-by-default t)
          (dsh-emacs-render-tool-call
           (dsh-emacs-test--tool-call-event 1 "r1" (nth 0 case) (nth 1 case)))
          (dsh-emacs-render-tool-result
           (dsh-emacs-test--tool-result-event
            2 "r1" t (nth 2 case) "refused"
            '((name . "AutoReview") (code . "denied")
              (reason . "Auto review denied this call"))))
          (let* ((ns (dsh-emacs-render--make-namespace))
                 (block (dsh-emacs-test--tool-block-text ns "tool-r1")))
            (dsh-test-assert (format "tool-%s-error-reason" (nth 0 case))
              (and block
                   (string-match-p (regexp-quote (nth 3 case)) block)))))
      (kill-buffer buf))))

;; --- Test 56d: a reason-less (or whitespace-only) reason keeps the old
;; status text: the 0.1.6 field is optional, and an absent `reason' must
;; not turn "✗ failed" into "✗ failed — " ---
(let ((i 0))
  (dolist (error '(nil ((name . "X") (code . "y"))
                       ((name . "X") (code . "y") (reason . "   "))))
    (dsh-test-assert (format "tool-status-no-reason-%d" i)
      (equal "✗ failed"
             (dsh-emacs-render--tool-status-text
              'error nil nil (cdr (assq 'reason error)))))
    (setq i (1+ i))))
(dsh-test-assert "tool-status-reason-newlines-collapse"
  (equal "✗ failed — line one line two"
         (dsh-emacs-render--tool-status-text 'error nil nil "line one\nline two")))
(dsh-test-assert "tool-status-reason-ignored-when-not-error"
  (equal "✓ exit 0"
         (dsh-emacs-render--tool-status-text 'success 0 nil "not a failure")))

;; --- Test 57: protocol layer workspace baseline / workspace-result
;; / model-selection-result ---
;; workspace/follow baseline top-level values: items array->list,
;; archivedSessionIds array->list
(let* ((value '((items . [((workspaceId . "w1") (title . "WS A")
                           (path . "/tmp/a") (sessionIds . ["s1" "s2"])
                           (createdAt . "2026-08-25T00:00:00Z")
                           (updatedAt . "2026-08-25T01:00:00Z"))
                          ((workspaceId . "w2") (title . "WS B")
                           (path . "/tmp/b") (sessionIds . []))])
                  (archivedSessionIds . ["s9"])))
       (wl (dsh-protocol-workspace-list--from-alist value))
       (items (dsh-protocol-workspace-list-items wl))
       (w1 (car items)))
  (when (and (= (length items) 2)
             (equal (dsh-protocol-workspace-list-archived-session-ids wl)
                    '("s9"))
             ;; items converted inline + arrays normalized to lists
             (dsh-protocol-workspace-p w1)
             (equal (dsh-protocol-workspace-session-ids w1) '("s1" "s2"))
             ;; WorkspaceView official fields complete
             (string= (dsh-protocol-workspace-title w1) "WS A")
             (string= (dsh-protocol-workspace-created-at w1)
                      "2026-08-25T00:00:00Z")
             (string= (dsh-protocol-workspace-updated-at w1)
                      "2026-08-25T01:00:00Z")
             (string= (dsh-protocol-workspace-path w1) "/tmp/a")
             (string= (dsh-protocol-workspace-workspace-id
                       (car (dsh-protocol-workspace-list-items
                             (dsh-protocol-workspace-list--from-alist
                              '((items . [((workspaceId . "w2"))]))))))
                      "w2"))
    (dsh-test-pass "protocol-workspace-list-conversion")))

;; workspace/create response: {workspace, created}
(let* ((value '((workspace . ((workspaceId . "w3") (title . "New")
                              (path . "/tmp/new") (sessionIds . [])
                              (createdAt . "x") (updatedAt . "y")))
                (created . t)))
       (r (dsh-protocol-workspace-result--from-alist value)))
  (when (and (dsh-protocol-workspace-p (dsh-protocol-workspace-result-workspace r))
             (eq (dsh-protocol-workspace-result-created r) t)
             (string= (dsh-protocol-workspace-title
                       (dsh-protocol-workspace-result-workspace r))
                      "New"))
    (dsh-test-pass "protocol-workspace-create-result")))

;; workspace/rename / insertSessionBefore response: only {workspace},
;; created is nil
(let* ((r (dsh-protocol-workspace-result--from-alist
           '((workspace . ((workspaceId . "w1") (title . "Renamed"))))))
       (d (dsh-protocol-workspace-result-created r)))
  (when (and (string= (dsh-protocol-workspace-title
                       (dsh-protocol-workspace-result-workspace r))
                      "Renamed")
             (null d))
    (dsh-test-pass "protocol-workspace-rename-result")))

;; session/selectModel response: {selected}
(let* ((r (dsh-protocol-model-selection-result--from-alist
           '((selected . ((provider . "deepseek")
                          (model . "deepseek-chat")
                          (reasoningEffort . "high"))))))
       (sel (dsh-protocol-model-selection-result-selected r)))
  (when (and (dsh-protocol-model-selection-p sel)
             (string= (dsh-protocol-model-selection-provider sel) "deepseek")
             (string= (dsh-protocol-model-selection-model sel) "deepseek-chat")
             (string= (dsh-protocol-model-selection-reasoning-effort sel)
                      "high"))
    (dsh-test-pass "protocol-model-selection-result")))

;; --- Test 58: archive session (workspace/archiveSession) ---
;; server has no session.delete, so archiving is the only removal
;; path; the response is the full archive set.
(let ((listed nil)
      (calls nil)
      (dsh-emacs--archived-sessions nil)
      (archived (dsh-emacs--normalize-archived '("s1" "s2"))))
  (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
             (lambda (method params cb)
               (push (list method params) calls)
               (when (string= method "workspace/archiveSession")
                 (funcall cb t '((archivedSessionIds . ["s1" "s2"]))))))
            ((symbol-function 'dsh-emacs-list-sessions)
             (lambda () (setq listed t))))
    (dsh-emacs-archive-session "s3")
    (let* ((call (car calls))
           (method (car call))
           (params (cadr call)))
      (when (and (string= "workspace/archiveSession" method)
                 (string= "s3"
                          (cdr (assq 'sessionId
                                     (cdr (assq 'request params))))))
        (dsh-test-pass "archive-passes-session-id")))
    (when (and (gethash "s1" dsh-emacs--archived-sessions)
               (gethash "s2" dsh-emacs--archived-sessions)
               (not (gethash "s3" dsh-emacs--archived-sessions)))
      (dsh-test-pass "archive-updates-archived-set"))
    (when listed
      (dsh-test-pass "archive-refreshes-list"))))

;; --- Test 58b: unarchive session (workspace/unarchiveSession, dsh 0.1.6) ---
;; The inverse of Test 58: the response is the complete remaining archive
;; set, so the cache is replaced wholesale (the host is idempotent for an
;; id it no longer holds archived).
(let ((listed nil)
      (calls nil)
      (dsh-emacs--archived-sessions (dsh-emacs--normalize-archived '("s1" "s2"))))
  (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
             (lambda (method params cb)
               (push (list method params) calls)
               (when (string= method "workspace/unarchiveSession")
                 (funcall cb t '((archivedSessionIds . ["s1"]))))))
            ((symbol-function 'dsh-emacs-list-sessions)
             (lambda () (setq listed t))))
    (dsh-emacs-unarchive-session "s2")
    (dsh-test-assert "unarchive-passes-session-id"
      (let* ((call (car calls))
             (params (cadr call)))
        (and (string= "workspace/unarchiveSession" (car call))
             (string= "s2"
                      (cdr (assq 'sessionId
                                 (cdr (assq 'request params))))))))
    (dsh-test-assert "unarchive-updates-archived-set"
      (and (gethash "s1" dsh-emacs--archived-sessions)
           (not (gethash "s2" dsh-emacs--archived-sessions))))
    (dsh-test-assert "unarchive-refreshes-list" listed)))

;; --- Test 58c: the unarchive picker offers only archived rows ---
;; `dsh-emacs--completing-session-id' grew an optional FILTER; an empty
;; candidate set must surface EMPTY-MESSAGE as a user-error rather than
;; letting `completing-read' fail on an empty collection.
(let ((dsh-emacs--sessions
       (list (dsh-protocol-session--from-alist '((sessionId . "live")
                                                 (title . "Live")))
             (dsh-protocol-session--from-alist '((sessionId . "gone")
                                                 (title . "Gone")))))
      (dsh-emacs--archived-sessions (dsh-emacs--normalize-archived '("gone")))
      (offered nil))
  (cl-letf (((symbol-function 'completing-read)
             (lambda (_prompt collection &rest _args)
               (setq offered (mapcar #'car collection))
               (caar collection))))
    (dsh-test-assert "unarchive-picker-offers-archived-only"
      (let ((picked (dsh-emacs--completing-session-id
                     "Unarchive session: " #'dsh-emacs--archived-session-p
                     "No archived session can be restored")))
        (and (= 1 (length offered))
             (string-match-p "gone" (car offered))
             (equal "gone" picked))))
    (let ((dsh-emacs--archived-sessions nil))
      (dsh-test-assert "unarchive-picker-empty-user-error"
        (equal "No archived session can be restored"
               (condition-case err
                   (dsh-emacs--completing-session-id
                    "Unarchive session: " #'dsh-emacs--archived-session-p
                    "No archived session can be restored")
                 (user-error (error-message-string err))))))))

;; --- Test 59: rename session at point ---
;; The r key in the list should act on the session at point like
;; archive (the D key), taking id + new title from the text property,
;; with no completing-read.
(let ((buf (generate-new-buffer " *dsh-rename-at-point*"))
      (calls nil))
  (unwind-protect
      (with-current-buffer buf
        (insert "Rename me\n")
        (put-text-property (point-min) (point-max) 'dsh-emacs-session-id "sid-1")
        (goto-char (point-min))
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (method params cb)
                     (push (list method params) calls)
                     (funcall cb t '((title . "renamed")))))
                  ((symbol-function 'read-string)
                   (lambda (&rest _args) "renamed"))
                  ;; The rename success callback refreshes the list; mock it out to
                  ;; avoid a second entry in calls
                  ((symbol-function 'dsh-emacs-list-sessions)
                   (lambda () nil)))
          (dsh-emacs-rename-session-at-point)
          (let* ((call (car calls))
                 (params (cadr call))
                 (req (cdr (assq 'request params))))
            (when (and (string= "session/rename" (car call))
                       (string= "sid-1" (cdr (assq 'sessionId req)))
                       (string= "renamed" (cdr (assq 'title req))))
              (dsh-test-pass "rename-at-point-uses-point-session")))))
    (kill-buffer buf)))

;; --- Test 59b: rename the session owned by the current chat buffer ---
;; The rename command inside a chat buffer must target that buffer's
;; session and prefill the current title; the session picker must not run.
(let ((buf (generate-new-buffer " *dsh-rename-chat*"))
      (old dsh-emacs--sessions)
      (calls nil)
      (prefill 'unset))
  (unwind-protect
      (progn
        (setq dsh-emacs--sessions
              (dsh-emacs-test--session-items
               (list (list (cons 'sessionId "sid-chat")
                           (cons 'blank :json-false)
                           (cons 'projections
                                 (list (cons 'values
                                             (list (cons 'title "Old title")))))))))
        (with-current-buffer buf
          (dsh-emacs-mode)
          (setq dsh-emacs--buffer-session "sid-chat")
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method params cb)
                       (push (list method params) calls)
                       (funcall cb t '((title . "New title")))))
                    ((symbol-function 'read-string)
                     (lambda (_prompt &optional initial &rest _)
                       (setq prefill initial)
                       "New title"))
                    ((symbol-function 'dsh-emacs-list-sessions)
                     (lambda () nil))
                    ((symbol-function 'dsh-emacs--completing-session-id)
                     (lambda (&rest _) (error "session picker must not run"))))
            (call-interactively #'dsh-emacs-rename-session)))
        (let* ((call (car calls))
               (req (cdr (assq 'request (cadr call)))))
          (dsh-test-assert "rename-chat-uses-buffer-session"
            (equal "session/rename" (car call))
            (equal "sid-chat" (cdr (assq 'sessionId req)))
            (equal "New title" (cdr (assq 'title req))))
          (dsh-test-assert "rename-chat-prefills-current-title"
            (equal "Old title" prefill))))
    (setq dsh-emacs--sessions old)
    (when (buffer-live-p buf) (kill-buffer buf))))

;; --- Test 60: subagent sessions do not enter a group ---
;; The server marks subagent sessions with origin: "subagent"; they
;; must not appear in the session list (including the Ungrouped bucket).
(let* ((dsh-emacs--archived-sessions nil)
       (sessions (dsh-emacs-test--session-items
                   (list (list (cons 'sessionId "s1")
                               (cons 'origin "subagent")
                               (cons 'updatedAt 100))
                         (list (cons 'sessionId "s2")
                               (cons 'updatedAt 200)))))
       (workspaces nil))
  ;; No workspace: subagent must be dropped, only s2 enters Ungrouped
  (let ((grouped (dsh-emacs-session--group-sessions sessions workspaces)))
    (let* ((ungrouped (cl-find-if (lambda (g) (equal "Ungrouped" (plist-get g :label))) grouped))
           (members (and ungrouped (plist-get ungrouped :sessions)))
           (ids (mapcar #'dsh-protocol-session-session-id members)))
      (when (and (= (length grouped) 1)
                 (equal ids '("s2")))
        (dsh-test-pass "subagent-session-hidden-from-list")))))

;; --- Test 61: blank sessions keep only the current session ---
;; dsh web's sessionVisible rule: not subagent, not archived,
;; and (not blank or is current). The three Untitled (blank) ones
;; should be hidden, but the currently open blank one is kept.
(let* ((dsh-emacs--archived-sessions nil)
       (dsh-emacs--current-session "s-blank-open")
       (sessions (dsh-emacs-test--session-items
                  (list (list (cons 'sessionId "s-a")
                              (cons 'blank :json-true)
                              (cons 'updatedAt 300))
                        (list (cons 'sessionId "s-blank-open")
                              (cons 'blank :json-true)
                              (cons 'updatedAt 200))
                        (list (cons 'sessionId "s-b")
                              (cons 'blank :json-false)
                              (cons 'updatedAt 100))))))
  (let* ((grouped (dsh-emacs-session--group-sessions sessions nil))
         (ungrouped (cl-find-if (lambda (g) (equal "Ungrouped"
                                                   (plist-get g :label)))
                                grouped))
         (members (and ungrouped (plist-get ungrouped :sessions)))
         (ids (sort (mapcar #'dsh-protocol-session-session-id members)
                    #'string<)))
    ;; s-a (blank, not current) is hidden; s-blank-open (blank but
    ;; current) and s-b (not blank) are kept
    (when (and (equal ids '("s-b" "s-blank-open"))
               (not (member "s-a" ids)))
      (dsh-test-pass "blank-hidden-except-current"))))

;; --- Test 62: an empty workspace stays visible and sessions can
;; be created from it ---
;; After blank filtering a workspace may have no members; an empty
;; group must still appear in the list (rendering the New Session
;; line), and `c' (dsh-emacs-new-session) on it should pass
;; workspaceId rather than cwd.
(let* ((dsh-emacs--archived-sessions nil)
       (dsh-emacs--current-session nil)
       (empty-ws (mapcar #'dsh-protocol-workspace--from-alist
                         (list (list (cons 'workspaceId "w-empty")
                                     (cons 'title "Empty WS")
                                     (cons 'path "/tmp/dsh-empty-ws")
                                     (cons 'sessionIds [])))))
       (sessions nil))
  ;; 1) Grouping: an empty workspace is still in the result
  (let* ((grouped (dsh-emacs-session--group-sessions sessions empty-ws))
         (ws-group (cl-find-if (lambda (g)
                                 (equal "w-empty"
                                        (plist-get g :workspace-id)))
                               grouped)))
    (when (and ws-group
               (equal "Empty WS" (plist-get ws-group :label))
               (null (plist-get ws-group :sessions)))
      (dsh-test-pass "empty-workspace-stays-visible")))
  ;; 2) Rendering: the empty group shows the New Session line, and
  ;; that line carries the workspace-id property
  (let ((buf (generate-new-buffer " *dsh-empty-ws-render*")))
    (unwind-protect
        (with-current-buffer buf
          (let ((dsh-emacs--sessions sessions)
                (dsh-emacs--workspaces empty-ws)
                (dsh-emacs--archived-sessions nil)
                (dsh-emacs-session--filter-ws-id nil)
                (dsh-emacs-session--filter-ws-title nil))
            (dsh-emacs-session--render)
            (let ((txt (buffer-substring-no-properties
                        (point-min) (point-max))))
              ;; Locate the New Session line of the empty workspace and check
              ;; that it carries workspace-id
              (goto-char (point-min))
              (let ((found nil))
                (while (and (not found)
                            (search-forward "New Session" nil t))
                  (when (dsh-emacs-workspace-id-at-point)
                    (setq found t))
                  (when (get-text-property (1- (point))
                                           'dsh-emacs-workspace-id)
                    (setq found t)))
                (when (and found (string-match-p "Empty WS" txt))
                  (dsh-test-pass "empty-workspace-renders-new-session"))))))
      (kill-buffer buf)))
  ;; 3) new-session on a workspace line should pass workspaceId, and
  ;; the new session's default-directory immediately aligns with the
  ;; workspace path (magit et al. locate the project this way).
  (let ((calls nil)
        (buf (generate-new-buffer " *dsh-empty-ws-create*")))
    (unwind-protect
        (with-current-buffer buf
          (insert "  New Session\n")
          (put-text-property (point-min) (point-max)
                             'dsh-emacs-workspace-id "w-empty")
          (goto-char (point-min))
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method params cb)
                       (push (list method params) calls)
                       (funcall cb t '((sessionId . "s-new")))))
                    ((symbol-function 'dsh-emacs-open-session)
                     (lambda (_sid) nil))
                    ((symbol-value 'dsh-emacs--current-buffer) buf)
                    (dsh-emacs--workspaces empty-ws))
            (call-interactively #'dsh-emacs-new-session)
            (let* ((call (car calls))
                   (params (cadr call)))
              (when (and (string= "session/create" (car call))
                         (string= "w-empty"
                                  (cdr (assq 'workspaceId (cdr (assq 'request params)))))
                         (null (assq 'cwd (cdr (assq 'request params)))))
                (dsh-test-pass "new-session-in-workspace-uses-workspace-id"))
              ;; The new session buffer's default-directory should be the workspace path
              (when (or (null (cdr (assq 'workspaceId (cdr (assq 'request params)))))
                        (string-suffix-p "/tmp/dsh-empty-ws"
                                         (directory-file-name
                                          default-directory)))
                (dsh-test-pass "new-workspace-session-sets-default-directory")))))
      (kill-buffer buf))))

  ;; 4) Non-workspace context: no workspaceId (ungrouped), only cwd
  ;; (automatic project attribution is covered separately in test 80b;
  ;; disabled here so the local repo is not detected as a project and
  ;; the assertions are not rewritten)
  (let ((calls nil)
        (buf (generate-new-buffer " *dsh-plain-create*"))
        (dsh-emacs-new-session-auto-project nil))
    (unwind-protect
        (with-current-buffer buf
          (insert "plain text\n")
          (goto-char (point-min))
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method params cb)
                       (push (list method params) calls)
                       (funcall cb t '((sessionId . "s-plain")))))
                    ((symbol-function 'dsh-emacs-open-session)
                     (lambda (_sid) nil)))
            (call-interactively #'dsh-emacs-new-session)
            (let* ((call (car calls))
                   (params (cadr call)))
              (when (and (string= "session/create" (car call))
                         (null (assq 'workspaceId (cdr (assq 'request params))))
                         (assq 'cwd (cdr (assq 'request params))))
                (dsh-test-pass "new-session-outside-workspace-ungrouped")))))
      (kill-buffer buf)))

  ;; 5) Called in a chat buffer (session): the new session belongs to
  ;; the workspace of the current session
  (let ((calls nil)
        (buf (generate-new-buffer " *dsh-chat-create*"))
        (w1 (dsh-protocol-workspace--from-alist
             (list (cons 'workspaceId "w-here")
                   (cons 'title "Here")
                   (cons 'path "/tmp/dsh-here")
                   (cons 'sessionIds ["s-here" "s-other"])
                   (cons 'createdAt "x") (cons 'updatedAt "x")))))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-mode)
          (setq-local dsh-emacs--buffer-session "s-here")
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method params cb)
                       (push (list method params) calls)
                       (funcall cb t '((sessionId . "s-child")))))
                    ((symbol-function 'dsh-emacs-open-session)
                     (lambda (_sid) nil))
                    (dsh-emacs--workspaces (list w1)))
            (call-interactively #'dsh-emacs-new-session)
            (let* ((call (car calls))
                   (params (cadr call)))
              (when (and (string= "session/create" (car call))
                         (string= "w-here"
                                  (cdr (assq 'workspaceId (cdr (assq 'request params)))))
                         (null (assq 'cwd (cdr (assq 'request params)))))
                (dsh-test-pass "new-session-in-chat-uses-session-workspace")))))
      (kill-buffer buf)))

  ;; 6) In a chat buffer, but the current session is in no workspace:
  ;; still cwd (ungrouped) (same as test 62-4: automatic project
  ;; attribution off, see test 80b)
  (let ((calls nil)
        (buf (generate-new-buffer " *dsh-chat-create-ungrouped*"))
        (dsh-emacs-new-session-auto-project nil))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-mode)
          (setq-local dsh-emacs--buffer-session "s-lonely")
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method params cb)
                       (push (list method params) calls)
                       (funcall cb t '((sessionId . "s-child2")))))
                    ((symbol-function 'dsh-emacs-open-session)
                     (lambda (_sid) nil))
                    (dsh-emacs--workspaces nil))
            (call-interactively #'dsh-emacs-new-session)
            (let* ((call (car calls))
                   (params (cadr call)))
              (when (and (string= "session/create" (car call))
                         (null (assq 'workspaceId (cdr (assq 'request params))))
                         (assq 'cwd (cdr (assq 'request params))))
                (dsh-test-pass "new-session-in-ungrouped-chat-uses-cwd")))))
      (kill-buffer buf)))

;; --- Test 62b: redraw keeps the session line under point (no jump
;; back to top between events/refreshes) ---
(let* ((dsh-emacs--archived-sessions nil)
       (dsh-emacs--current-session nil)
       (dsh-emacs-session--filter-ws-id nil)
       (dsh-emacs-session--filter-ws-title nil)
       (sessions (dsh-emacs-test--session-items
                  (list (list (cons 'sessionId "s-one")
                              (cons 'blank :json-false)
                              (cons 'cwd "/tmp/x")
                              (cons 'updatedAt 300))
                        (list (cons 'sessionId "s-two")
                              (cons 'blank :json-false)
                              (cons 'cwd "/tmp/y")
                              (cons 'updatedAt 200))
                        (list (cons 'sessionId "s-three")
                              (cons 'blank :json-false)
                              (cons 'cwd "/tmp/z")
                              (cons 'updatedAt 100)))))
       (old-sessions dsh-emacs--sessions)
       (old-ws dsh-emacs--workspaces)
       (buf (generate-new-buffer " *dsh-sess-restore*")))
  (unwind-protect
      (with-current-buffer buf
        (let ((dsh-emacs--sessions sessions)
              (dsh-emacs--workspaces nil))
          (dsh-emacs-session--render)
          ;; Put point on the s-two line
          (goto-char (point-min))
          (catch 'found
            (while (not (eobp))
              (when (equal "s-two" (dsh-emacs-session-id-at-point))
                (throw 'found t))
              (forward-line 1)))
          (let ((expect (dsh-emacs-session-id-at-point)))
            ;; After redraw point should still be on the same session line
            (dsh-emacs-session--render)
            (when (equal expect (dsh-emacs-session-id-at-point))
              (dsh-test-pass "session-render-keeps-focused-row")))))
    (kill-buffer buf))
  (setq dsh-emacs--sessions old-sessions
        dsh-emacs--workspaces old-ws))

;; --- Test 63: the session/title event updates the title live
;; (server auto-rename) ---
;; The server auto-renames after the first 1-2 dialogue turns (summary
;; title) and broadcasts a `session/title' event over the follow stream;
;; the emacs side should do it live: update the cached title-value,
;; rename the already-open chat buffer, redraw the session list --
;; without waiting for a session/list refresh.
(let* ((old-sessions dsh-emacs--sessions)
       (old-buffers dsh-emacs--chat-buffers)
       (item (list (cons 'sessionId "sess-title")
                   (cons 'blank :json-false)
                   (cons 'title "old title")
                   (cons 'projections
                         (list (cons 'values
                                     (list (cons 'title "old title")))))))
       (chat-buf (get-buffer-create " *dsh-test-title-chat*"))
       (list-buf (get-buffer-create "*dsh-sessions*"))
       (proc (make-pipe-process :name "t-title" :buffer nil))
       (old-sessions-buffer dsh-emacs-sessions-buffer)
       (json (concat "{\"type\":\"item\",\"streamId\":\"t1\","
                     "\"value\":{\"type\":\"event\","
                     "\"event\":{\"type\":\"session/title\","
                     "\"data\":{\"title\":\"auto summary title\"}}}}")))
  (unwind-protect
      (progn
        (setq dsh-emacs--sessions
              (dsh-emacs-test--session-items (list item)))
        (setq dsh-emacs--chat-buffers
              (let ((h (make-hash-table :test 'equal)))
                (puthash "sess-title" chat-buf h) h))
        ;; Bind the chat buffer to the session; avoid triggering the
        ;; history-loading drop branch.
        (with-current-buffer chat-buf
          (setq-local dsh-emacs--buffer-session "sess-title")
          (setq-local dsh-emacs--current-session "sess-title")
          (setq-local dsh-emacs--event-history-loading nil)
          (rename-buffer " *dsh-test-title-chat*" t)
          (dsh-emacs-mode))
        ;; Set the list buffer to the session list and render once (freeze
        ;; the old state).
        (with-current-buffer list-buf
          (let ((dsh-emacs--sessions dsh-emacs--sessions)
                (dsh-emacs--workspaces nil)
                (dsh-emacs--archived-sessions nil)
                (dsh-emacs-session--filter-ws-id nil)
                (dsh-emacs-session--filter-ws-title nil))
            (dsh-emacs-session--render))
          (setq dsh-emacs-sessions-buffer (buffer-name)))
        ;; Follow stream frames go through --dispatch-json: the process binds
        ;; follow-stream-id and chat-buf.
        (process-put proc 'dsh-emacs-follow-stream-id "t1")
        (process-put proc 'dsh-emacs-chat-buffer chat-buf)
        (dsh-emacs-events--dispatch-json proc json)
        ;; 1) The cached title-value is updated
        (let ((cached (cl-find-if
                       (lambda (s)
                         (equal "sess-title"
                                (dsh-protocol-session-session-id s)))
                       dsh-emacs--sessions)))
          (when (and cached
                     (equal "auto summary title"
                            (dsh-protocol-session-title-value cached)))
            (dsh-test-pass "title-event-updates-cache")))
        ;; 2) The list buffer line is redrawn with the new title
        (when (string-match-p "auto summary title"
                              (with-current-buffer list-buf
                                (buffer-string)))
          (dsh-test-pass "title-event-repaints-list"))
        ;; 3) The open chat buffer has been renamed
        (when (string-match-p "auto summary title" (buffer-name chat-buf))
          (dsh-test-pass "title-event-renames-chat-buffer")))
    (setq dsh-emacs--sessions old-sessions)
    (setq dsh-emacs--chat-buffers old-buffers)
    (setq dsh-emacs-sessions-buffer old-sessions-buffer)
    (when (buffer-live-p chat-buf) (kill-buffer chat-buf))
    (when (buffer-live-p list-buf) (kill-buffer list-buf))
    (when (process-live-p proc) (delete-process proc))))

;; --- Test 64: a new workspace session joins that workspace, and the
;; title event clears blank ---
;; Regression: the session/create callback used to only open the
;; session, so the new session did not enter the cache/workspace
;; session-ids -> grouping fell to ungrouped, and the session/title
;; event could not find the cached item, blank was not cleared ->
;; auto-rename never took effect.
(let* ((old-sessions dsh-emacs--sessions)
       (old-workspaces dsh-emacs--workspaces)
       (old-buffers dsh-emacs--chat-buffers)
       (ws (dsh-protocol-workspace--from-alist
            (list (cons 'workspaceId "w-empty")
                  (cons 'title "Empty WS")
                  (cons 'path "/tmp/dsh-empty-ws")
                  (cons 'sessionIds []))))
       (chat-buf (get-buffer-create " *dsh-test-ws-create*")))
  (unwind-protect
      (progn
        (setq dsh-emacs--workspaces (list ws))
        (setq dsh-emacs--sessions
              (dsh-emacs-test--session-items
               (list (list (cons 'sessionId "s-old")
                           (cons 'blank :json-false)))))
        (setq dsh-emacs--chat-buffers
              (let ((h (make-hash-table :test 'equal)))
                (puthash "s-new" chat-buf h) h))
        (with-current-buffer chat-buf
          (setq-local dsh-emacs--buffer-session "s-new")
          (setq-local dsh-emacs--current-session nil))
        ;; mock rpc-async: call back immediately on successful creation
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (_method params cb)
                     (funcall cb t '((sessionId . "s-new")))))
                  ((symbol-function 'dsh-emacs-open-session)
                   (lambda (_sid) nil))
                  ((symbol-value 'dsh-emacs--current-buffer) chat-buf))
          ;; Call directly with the workspace-id argument (equivalent to
          ;; pressing c on a workspace line)
          (dsh-emacs--cache-new-session "s-new" "w-empty"))
        ;; 1) The new session is in the cache
        (when (dsh-emacs--chat-session-item "s-new")
          (dsh-test-pass "new-session-cached-after-create"))
        ;; 2) workspace session-ids has absorbed the new session
        (let ((w (car dsh-emacs--workspaces)))
          (when (member "s-new" (dsh-protocol-workspace-session-ids w))
            (dsh-test-pass "new-session-attached-to-workspace")))
        ;; 3) Grouping: s-new lands in the Empty WS group rather than
        ;; Ungrouped (after creation the session is open, current-session
        ;; is it, so blank filtering will not hide it)
        (let* ((dsh-emacs--current-session "s-new")
               (grouped (dsh-emacs-session--group-sessions
                         dsh-emacs--sessions dsh-emacs--workspaces))
               (ws-group (cl-find-if
                          (lambda (g) (equal "w-empty"
                                             (plist-get g :workspace-id)))
                          grouped))
               (ungrouped (cl-find-if
                           (lambda (g) (equal "Ungrouped"
                                              (plist-get g :label)))
                           grouped)))
          (when (and ws-group
                     (member "s-new"
                             (mapcar #'dsh-protocol-session-session-id
                                     (plist-get ws-group :sessions)))
                     (not (member "s-new"
                                  (mapcar #'dsh-protocol-session-session-id
                                          (and ungrouped
                                               (plist-get ungrouped :sessions))))))
            (dsh-test-pass "new-session-grouped-in-workspace-not-ungrouped")))
        ;; 4) The title event arrives: blank is cleared + title-value
        ;; updated -> the displayed title is no longer
        ;;    "New Session"
        (dsh-emacs-events--apply-title chat-buf "s-new" "auto summary name")
        (let* ((item (dsh-emacs--chat-session-item "s-new"))
               (blank (dsh-protocol-session-blank item))
               (shown (dsh-emacs-session--display-title item)))
          (when (and item
                     (not (and blank (not (eq blank :json-false))))
                     (equal "auto summary name" shown))
            (dsh-test-pass "title-event-clears-blank-and-updates-title"))))
    (setq dsh-emacs--sessions old-sessions)
    (setq dsh-emacs--workspaces old-workspaces)
    (setq dsh-emacs--chat-buffers old-buffers)
    (when (buffer-live-p chat-buf) (kill-buffer chat-buf))))

;; --- Test 64b: the $events api-session/added arrives first (session
;; enters cache), then the RPC callback ---
;; Regression: cache-new-session used a single not-cached guard around
;; "enter cache + workspace attach". When the core stream (the
;; api-session/added emit of $events) arrived before the session/create
;; callback, the session was already in the cache -> the whole when was
;; skipped -> the workspace was not attached and the new session fell
;; into Ungrouped. Now attach runs independently of cache insertion
;; (idempotent), so the race window no longer loses ownership.
(let* ((old-sessions dsh-emacs--sessions)
       (old-workspaces dsh-emacs--workspaces)
       (old-sessions-buffer dsh-emacs-sessions-buffer)
       (ws (dsh-protocol-workspace--from-alist
            (list (cons 'workspaceId "w-race")
                  (cons 'title "Race WS")
                  (cons 'path "/tmp/race-ws")
                  (cons 'sessionIds []))))
       (list-buf (get-buffer-create " *dsh-race-list*")))
  (unwind-protect
      (progn
        (setq dsh-emacs--sessions nil)
        (setq dsh-emacs--workspaces (list ws))
        (setq dsh-emacs-sessions-buffer (buffer-name list-buf))
        ;; 1) The core event arrives first: api-session/added puts s-new into
        ;; the sessions cache (no owner)
        (dsh-emacs-events--host-dispatch
         'host-proc
         (concat "{\"type\":\"item\",\"streamId\":\"c1\","
                 "\"value\":{\"type\":\"emit\",\"event\":\"api-session/added\","
                 "\"args\":[{\"sessionId\":\"s-new\",\"blank\":true,"
                 "\"cwd\":\"/tmp/race-ws\"}]}}"))
        ;; 2) The RPC callback arrives afterwards: cache-new-session must
        ;; still attach to the workspace
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (_method params cb)
                     (funcall cb t '((sessionId . "s-new")))))
                  ((symbol-function 'dsh-emacs-open-session)
                   (lambda (_sid) nil)))
          (dsh-emacs--cache-new-session "s-new" "w-race"))
        ;; Assertion: the cache has exactly one row (the host event already
        ;; entered it, no duplicate)
        (when (= 1 (length dsh-emacs--sessions))
          (dsh-test-pass "host-first-cache-no-duplicate"))
        ;; Assertion: the workspace is attached (the race fix point)
        (let ((w (car dsh-emacs--workspaces)))
          (when (and w
                     (member "s-new"
                             (dsh-protocol-workspace-session-ids w)))
            (dsh-test-pass "host-first-still-attaches-to-workspace")))
        ;; Assertion: grouping lands in Race WS rather than Ungrouped
        (let* ((dsh-emacs--current-session "s-new")
               (grouped (dsh-emacs-session--group-sessions
                         dsh-emacs--sessions dsh-emacs--workspaces))
               (ws-group (cl-find-if
                          (lambda (g) (equal "w-race"
                                             (plist-get g :workspace-id)))
                          grouped))
               (ungrouped (cl-find-if
                           (lambda (g) (equal "Ungrouped"
                                              (plist-get g :label)))
                           grouped)))
          (when (and ws-group
                     (member "s-new"
                             (mapcar #'dsh-protocol-session-session-id
                                     (plist-get ws-group :sessions))))
            (dsh-test-pass "host-first-grouped-in-workspace"))))
    (setq dsh-emacs--sessions old-sessions)
    (setq dsh-emacs--workspaces old-workspaces)
    (setq dsh-emacs-sessions-buffer old-sessions-buffer)
    (when (buffer-live-p list-buf) (kill-buffer list-buf))))

;; --- Test 65: pressing c on any session line inside a workspace group
;; creates in that workspace ---
;; Regression: the workspace-id property was only added to the group
;; header / empty-group New Session line; actual session lines inside a
;; group lacked it -> pressing c on those lines took the cwd branch and
;; created an ungrouped session.
(let* ((old-sessions dsh-emacs--sessions)
       (old-workspaces dsh-emacs--workspaces)
       (ws (dsh-protocol-workspace--from-alist
            (list (cons 'workspaceId "w-mid")
                  (cons 'title "Mid WS")
                  (cons 'path "/tmp/dsh-mid-ws")
                  (cons 'sessionIds ["s-inside"]))))
       (s-inside (dsh-protocol-session--from-alist
                  (list (cons 'sessionId "s-inside")
                        (cons 'blank :json-false)
                        (cons 'projections
                              (list (cons 'values
                                          (list (cons 'title "existing"))))))))
       (buf (generate-new-buffer " *dsh-ws-row-create*")))
  (unwind-protect
      (progn
        (setq dsh-emacs--sessions (list s-inside))
        (setq dsh-emacs--workspaces (list ws))
        (with-current-buffer buf
          ;; Render the groups: the session lines of the Mid WS group should
          ;; carry the workspace-id property
          (let ((dsh-emacs--sessions dsh-emacs--sessions)
                (dsh-emacs--workspaces dsh-emacs--workspaces)
                (dsh-emacs--archived-sessions nil)
                (dsh-emacs--current-session nil)
                (dsh-emacs-session--filter-ws-id nil)
                (dsh-emacs-session--filter-ws-title nil))
            (dsh-emacs-session--render)
            ;; Find the session line (containing the title text) and check its
            ;; workspace-id
            (goto-char (point-min))
            (let ((row-ok nil))
              (while (and (not row-ok)
                          (search-forward "existing" nil t))
                (setq row-ok
                      (equal "w-mid"
                             (dsh-emacs-workspace-id-at-point))))
              (when row-ok
                (dsh-test-pass "session-row-carries-workspace-context"))))
          ;; Press c on that session line: creation should pass workspaceId
          ;; rather than cwd
          (let ((calls nil))
            (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                       (lambda (method params cb)
                         (push (list method params) calls)
                         (funcall cb t '((sessionId . "s-created")))))
                      ((symbol-function 'dsh-emacs-open-session)
                       (lambda (_sid) nil))
                      ((symbol-value 'dsh-emacs--current-buffer) buf))
              (goto-char (point-min))
              (search-forward "existing" nil t)
              (call-interactively #'dsh-emacs-new-session))
            (let* ((call (car calls))
                   (params (cadr call)))
              (when (and (string= "session/create" (car call))
                         (string= "w-mid"
                                  (cdr (assq 'workspaceId (cdr (assq 'request params)))))
                         (null (assq 'cwd (cdr (assq 'request params)))))
                (dsh-test-pass "new-session-on-workspace-session-row-uses-workspace-id"))))))
    (setq dsh-emacs--sessions old-sessions)
    (setq dsh-emacs--workspaces old-workspaces)
    (when (buffer-live-p buf) (kill-buffer buf))))

;; --- Test 66: the core stream ($events + workspace/follow) updates
;; the cache live ---
;; workspace/session/archive changes are broadcast over the core
;; connection (mirroring dsh web's WorkspaceBrowser live subscription).
;; Frame envelope: {type:'item', value:{...}} (the /api/remote.mux
;; logical stream frame, same as mux).
(let* ((old-sessions dsh-emacs--sessions)
       (old-workspaces dsh-emacs--workspaces)
       (old-archived dsh-emacs--archived-sessions)
       (old-sessions-buffer dsh-emacs-sessions-buffer)
       (list-buf (get-buffer-create " *dsh-host-test-list*")))
  (unwind-protect
      (progn
        (setq dsh-emacs--sessions nil)
        (setq dsh-emacs--workspaces nil)
        (setq dsh-emacs--archived-sessions nil)
        (with-current-buffer list-buf
          (erase-buffer)
          (insert "placeholder"))
        (setq dsh-emacs-sessions-buffer (buffer-name list-buf))

        ;; 1) workspace/follow upsert: a new workspace enters the cache
        ;; (including sessionIds)
        (dsh-emacs-events--host-dispatch
         'host-proc
         (concat "{\"type\":\"item\",\"streamId\":\"c1\","
                 "\"value\":{\"type\":\"upsert\","
                 "\"workspace\":{\"workspaceId\":\"w-live\","
                 "\"path\":\"/tmp/live\",\"title\":\"Live WS\","
                 "\"sessionIds\":[],\"createdAt\":\"2026-01-01\","
                 "\"updatedAt\":\"2026-01-01\"}}}"))
        (let ((ws (car dsh-emacs--workspaces)))
          (when (and ws
                     (equal "w-live" (dsh-protocol-workspace-workspace-id ws))
                     (equal "Live WS" (dsh-protocol-workspace-title ws)))
            (dsh-test-pass "host-workspace-changed-upserts")))
        ;; upsert also triggers a list redraw (the placeholder has been
        ;; overwritten by real content)
        (when (not (string-match-p "placeholder"
                                   (with-current-buffer list-buf
                                     (buffer-string))))
          (dsh-test-pass "host-workspace-changed-repaints"))

        ;; 2) workspace/follow upsert: replaces an existing workspace (members change)
        (dsh-emacs-events--host-dispatch
         'host-proc
         (concat "{\"type\":\"item\",\"streamId\":\"c1\","
                 "\"value\":{\"type\":\"upsert\","
                 "\"workspace\":{\"workspaceId\":\"w-live\","
                 "\"path\":\"/tmp/live\",\"title\":\"Live WS\","
                 "\"sessionIds\":[\"s-1\"],\"createdAt\":\"2026-01-01\","
                 "\"updatedAt\":\"2026-01-02\"}}}"))
        (let ((ws (car dsh-emacs--workspaces)))
          (when (and ws
                     (equal "w-live" (dsh-protocol-workspace-workspace-id ws))
                     (equal '("s-1")
                            (dsh-protocol-workspace-session-ids ws)))
            (dsh-test-pass "host-workspace-changed-replaces-members")))

        ;; 3) workspace/follow remove: deletes the cache entry
        (dsh-emacs-events--host-dispatch
         'host-proc
         (concat "{\"type\":\"item\",\"streamId\":\"c1\","
                 "\"value\":{\"type\":\"remove\",\"workspaceId\":\"w-live\"}}"))
        (when (null dsh-emacs--workspaces)
          (dsh-test-pass "host-workspace-removed-drops"))

        ;; 4) workspace/follow archived: replaces the archive set
        (setq dsh-emacs--sessions
              (dsh-emacs-test--session-items
               (list (list (cons 'sessionId "s-archive")
                           (cons 'blank :json-false)))))
        (dsh-emacs-events--host-dispatch
         'host-proc
         (concat "{\"type\":\"item\",\"streamId\":\"c1\","
                 "\"value\":{\"type\":\"archived\","
                 "\"archivedSessionIds\":[\"s-archive\"]}}"))
        (let ((archived dsh-emacs--archived-sessions))
          (when (and (hash-table-p archived)
                     (gethash "s-archive" archived))
            (dsh-test-pass "host-archived-sessions-changed")))

        ;; 5) $events api-session/added: the new session enters the cache
        ;; (blank placeholder)
        (setq dsh-emacs--sessions nil)
        (dsh-emacs-events--host-dispatch
         'host-proc
         (concat "{\"type\":\"item\",\"streamId\":\"c1\","
                 "\"value\":{\"type\":\"emit\",\"event\":\"api-session/added\","
                 "\"args\":[{\"sessionId\":\"s-new\",\"blank\":true,"
                 "\"cwd\":\"/tmp/new\"}]}}"))
        (let ((item (dsh-emacs--chat-session-item "s-new")))
          (when (and item (equal t (dsh-protocol-session-blank item)))
            (dsh-test-pass "host-session-added-caches")))
        ;; api-session/added is idempotent: broadcasting again produces no
        ;; duplicate row
        (dsh-emacs-events--host-dispatch
         'host-proc
         (concat "{\"type\":\"item\",\"streamId\":\"c1\","
                 "\"value\":{\"type\":\"emit\",\"event\":\"api-session/added\","
                 "\"args\":[{\"sessionId\":\"s-new\",\"blank\":true}]}}"))
        (when (= 1 (length dsh-emacs--sessions))
          (dsh-test-pass "host-session-added-idempotent"))

        ;; 6) $events api-session/status: updates the running flag and redraws
        (dsh-emacs-events--host-dispatch
         'host-proc
         (concat "{\"type\":\"item\",\"streamId\":\"c1\","
                 "\"value\":{\"type\":\"emit\",\"event\":\"api-session/status\","
                 "\"args\":[\"s-new\",true]}}"))
        (let ((item (dsh-emacs--chat-session-item "s-new")))
          (when (and item (equal t (dsh-protocol-session-running item)))
            (dsh-test-pass "host-session-status-updates")))

        ;; 7) $events api-session/removed: deletes the cache row
        (dsh-emacs-events--host-dispatch
         'host-proc
         (concat "{\"type\":\"item\",\"streamId\":\"c1\","
                 "\"value\":{\"type\":\"emit\",\"event\":\"api-session/removed\","
                 "\"args\":[\"s-new\"]}}"))
        (when (null dsh-emacs--sessions)
          (dsh-test-pass "host-session-removed-drops"))

        ;; 8) workspace/follow order: reorders to the server order
        (setq dsh-emacs--workspaces
              (list (dsh-protocol-workspace--from-alist
                     (list (cons 'workspaceId "w-a") (cons 'title "A")
                           (cons 'path "/a") (cons 'sessionIds [])))
                    (dsh-protocol-workspace--from-alist
                     (list (cons 'workspaceId "w-b") (cons 'title "B")
                           (cons 'path "/b") (cons 'sessionIds [])))))
        (dsh-emacs-events--host-dispatch
         'host-proc
         (concat "{\"type\":\"item\",\"streamId\":\"c1\","
                 "\"value\":{\"type\":\"order\","
                 "\"workspaceIds\":[\"w-b\",\"w-a\"]}}"))
        (let ((order (mapcar #'dsh-protocol-workspace-workspace-id
                             dsh-emacs--workspaces)))
          (when (equal '("w-b" "w-a") order)
            (dsh-test-pass "host-workspace-order-changed")))

        ;; 9) Unknown logical frame type (an unrecognized emit / other) is safely ignored
        (dsh-emacs-events--host-dispatch
         'host-proc
         (concat "{\"type\":\"item\",\"streamId\":\"c1\","
                 "\"value\":{\"type\":\"emit\",\"event\":\"some.event\","
                 "\"args\":[]}}"))
        (when (= 2 (length dsh-emacs--workspaces))
          (dsh-test-pass "host-unknown-frame-ignored"))

        ;; 10) Full dispatch-json gating: only the host-stream property goes
        ;; through host dispatch
        (setq dsh-emacs--sessions nil)
        (let ((host-props (list (cons 'dsh-emacs-host-stream t))))
          (cl-letf (((symbol-function 'processp)
                     (lambda (_p) t))
                    ((symbol-function 'process-get)
                     (lambda (_p prop)
                       (cdr (assq prop host-props))))
                    ;; Avoid a real connection: the host-lost reconnect logic tries
                    ;; open-network-stream
                    ((symbol-function 'dsh-emacs-events--host-lost)
                     (lambda (_p) nil)))
            (dsh-emacs-events--dispatch-json
             'host-proc
             (concat "{\"type\":\"item\",\"streamId\":\"c1\","
                     "\"value\":{\"type\":\"emit\",\"event\":\"api-session/added\","
                     "\"args\":[{\"sessionId\":\"s-gated\",\"blank\":true}]}}")))
          (when (dsh-emacs--chat-session-item "s-gated")
            (dsh-test-pass "host-dispatch-gated-by-property")))
    (setq dsh-emacs--sessions old-sessions)
    (setq dsh-emacs--workspaces old-workspaces)
    (setq dsh-emacs--archived-sessions old-archived)
    (setq dsh-emacs-sessions-buffer old-sessions-buffer)
    (when (buffer-live-p list-buf) (kill-buffer list-buf)))))

;; --- Test 66b: workspace/follow + session/control baseline frames
;; dispatch correctly by real nesting ---
;; Regression: the baseline frames of `workspace/follow' and
;; `session/control' differ from their incremental frames (upsert/order/
;; queue/projection put the fields at the top level of the frame) -- the
;; logical frame is `{type:'baseline', value:{...}}', with the payload
;; nested one level deeper (workspace/follow:
;; value.items + value.archivedSessionIds; session/control: value.queues/jobs/
;; projections). host-item used to look for `items' only at the frame
;; top level (always nil), so every baseline was misdispatched to
;; session/control and `dsh-emacs--workspaces' was never seeded -- the
;; session list was therefore not grouped by workspace (all landed in
;; Ungrouped).
(let* ((old-workspaces dsh-emacs--workspaces)
       (old-archived dsh-emacs--archived-sessions)
       (old-sessions-buffer dsh-emacs-sessions-buffer))
  (unwind-protect
      (progn
        (setq dsh-emacs--workspaces nil)
        (setq dsh-emacs--archived-sessions nil)
        (setq dsh-emacs-sessions-buffer nil) ; host-repaint skips without a list buffer
        ;; 1) workspace/follow baseline (real wire shape: payload under value)
        (dsh-emacs-events--host-dispatch
         'host-proc
         (concat "{\"type\":\"item\",\"streamId\":\"c1\","
                 "\"value\":{\"type\":\"baseline\",\"value\":{\"items\":"
                 "[{\"workspaceId\":\"w-b1\",\"path\":\"/x\","
                 "\"title\":\"B WS\",\"sessionIds\":[\"s1\",\"s2\"],"
                 "\"createdAt\":\"2026-01-01\",\"updatedAt\":\"2026-01-01\"}],"
                 "\"archivedSessionIds\":[\"s-arch\"]}}}"))
        (let ((ws (car dsh-emacs--workspaces)))
          (dsh-test-assert "host-workspace-baseline-seeds-workspaces"
            ws
            (equal "w-b1" (dsh-protocol-workspace-workspace-id ws))
            (equal '("s1" "s2") (dsh-protocol-workspace-session-ids ws))
            (equal "B WS" (dsh-protocol-workspace-title ws)))
          (dsh-test-assert "host-workspace-baseline-seeds-archived"
            (gethash "s-arch" dsh-emacs--archived-sessions)))
        ;; 2) session/control baseline (queues/jobs/projections) no longer
        ;; swallows the workspace baseline by mistake: the workspace cache
        ;; stays unchanged (not cleared/rewritten)
        (dsh-emacs-events--host-dispatch
         'host-proc
         (concat "{\"type\":\"item\",\"streamId\":\"c2\","
                 "\"value\":{\"type\":\"baseline\",\"value\":{\"queues\":{},"
                 "\"jobs\":{},\"projections\":{}}}}}"))
        (let ((ids (mapcar #'dsh-protocol-workspace-workspace-id
                           dsh-emacs--workspaces)))
          (dsh-test-assert "host-control-baseline-leaves-workspaces"
            (equal '("w-b1") ids))))
    (setq dsh-emacs--workspaces old-workspaces)
    (setq dsh-emacs--archived-sessions old-archived)
    (setq dsh-emacs-sessions-buffer old-sessions-buffer)))

;; --- Test 67: workspace ordering move-workspace (insertBefore) ---
;; The web side's drag-to-reorder calls workspace/insertBefore (always
;; RPC); emacs performs the same ordering with an M key command.
;; A missing beforeWorkspaceId = move to the end.
(let* ((old-workspaces dsh-emacs--workspaces)
       (old-sessions dsh-emacs--sessions)
       (ws-a (dsh-protocol-workspace--from-alist
              (list (cons 'workspaceId "w-a") (cons 'title "A WS")
                    (cons 'path "/tmp/a") (cons 'sessionIds []))))
       (ws-b (dsh-protocol-workspace--from-alist
              (list (cons 'workspaceId "w-b") (cons 'title "B WS")
                    (cons 'path "/tmp/b") (cons 'sessionIds []))))
       (ws-c (dsh-protocol-workspace--from-alist
              (list (cons 'workspaceId "w-c") (cons 'title "C WS")
                    (cons 'path "/tmp/c") (cons 'sessionIds [])))))
  (unwind-protect
      (progn
        (setq dsh-emacs--workspaces (list ws-a ws-b ws-c))
        (setq dsh-emacs--sessions nil)

        ;; 1) Move w-c before w-a: insertBefore carries beforeWorkspaceId
        (let ((calls nil))
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method params cb)
                       (push (list method params) calls)
                       (funcall cb t '((workspaceIds
                                        . ["w-c" "w-a" "w-b"])))))
                    ((symbol-function 'dsh-emacs-list-workspaces)
                     (lambda () nil)))
            (dsh-emacs-move-workspace "w-c" "w-a"))
          (let* ((call (car calls))
                 (params (cadr call)))
            (when (and (string= "workspace/insertBefore" (car call))
                       (string= "w-c" (cdr (assq 'workspaceId (cdr (assq 'request params)))))
                       (string= "w-a" (cdr (assq 'beforeWorkspaceId
                                                 (cdr (assq 'request params))))))
              (dsh-test-pass "move-workspace-sends-before-workspace-id")))
          ;; The callback reorders the cache by the response workspaceIds
          ;; (w-c to the top)
          (let ((order (mapcar #'dsh-protocol-workspace-workspace-id
                               dsh-emacs--workspaces)))
            (when (equal '("w-c" "w-a" "w-b") order)
              (dsh-test-pass "move-workspace-reorders-cache"))))

        ;; 2) Move to the end: no beforeWorkspaceId
        (let ((calls nil))
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method params cb)
                       (push (list method params) calls)
                       (funcall cb t '((workspaceIds
                                        . ["w-b" "w-c" "w-a"])))))
                    ((symbol-function 'dsh-emacs-list-workspaces)
                     (lambda () nil)))
            (dsh-emacs-move-workspace "w-a" nil))
          (let* ((call (car calls))
                 (params (cadr call)))
            (when (and (string= "workspace/insertBefore" (car call))
                       (string= "w-a" (cdr (assq 'workspaceId (cdr (assq 'request params)))))
                       (null (assq 'beforeWorkspaceId (cdr (assq 'request params)))))
              (dsh-test-pass "move-workspace-to-end-omits-before")))
          (let ((order (mapcar #'dsh-protocol-workspace-workspace-id
                               dsh-emacs--workspaces)))
            (when (equal '("w-b" "w-c" "w-a") order)
              (dsh-test-pass "move-workspace-to-end-reorders-cache")))))
    (setq dsh-emacs--workspaces old-workspaces)
    (setq dsh-emacs--sessions old-sessions)))

;; --- Test 68: a refresh snapshot does not roll back in-flight
;; host/mux frames (refreshFrames mirror) ---
;; dsh web records frames arriving during `refresh' and replays them on
;; top of the snapshot; emacs's list-sessions/list-workspaces responses
;; are snapshots taken at request time, so if frames advance the cache
;; while the response is in flight (another client renaming/archiving/
;; changing status), a plain whole setq rolls back. The begin/drain
;; pairing ensures that when the last refresh ends, all recorded frames
;; are replayed in arrival order.
(let* ((old-sessions dsh-emacs--sessions)
       (old-workspaces dsh-emacs--workspaces)
       (old-archived dsh-emacs--archived-sessions)
       (old-refresh-depth dsh-emacs--host-refresh-depth)
       (old-frames dsh-emacs--host-refresh-frames))
  (unwind-protect
      (progn
        ;; Baseline: two workspaces + one session
        (setq dsh-emacs--sessions
              (dsh-emacs-test--session-items
               (list (list (cons 'sessionId "s-a")
                           (cons 'blank :json-false)))))
        (setq dsh-emacs--workspaces
              (list (dsh-protocol-workspace--from-alist
                     (list (cons 'workspaceId "w1") (cons 'title "One")
                           (cons 'path "/one") (cons 'sessionIds ["s-a"])))
                    (dsh-protocol-workspace--from-alist
                     (list (cons 'workspaceId "w2") (cons 'title "Two")
                           (cons 'path "/two") (cons 'sessionIds [])))))

        ;; Scenario 1: the workspace/follow upsert/remove frames arrive while a
        ;; refresh is in flight; the late snapshot does not contain them -> after
        ;; drain the new workspace is still there and the deleted one does not
        ;; reappear.
        (setq dsh-emacs--host-refresh-depth 0
              dsh-emacs--host-refresh-frames nil)
        (dsh-emacs-events--host-refresh-begin)   ; list-workspaces dispatched
        ;; Frames arrive first: add w3 + remove w2
        (dsh-emacs-events--host-frame-record
         (list :upsert-workspace
               (dsh-protocol-workspace--from-alist
                (list (cons 'workspaceId "w3") (cons 'title "Three")
                      (cons 'path "/three") (cons 'sessionIds [])))))
        (dsh-emacs-events--host-frame-record
         (list :remove-workspace "w2"))
        ;; Late snapshot: still only w1, w2 (the request-time state) -- models the
        ;; wholesale setq of the list-workspaces callback.
        (setq dsh-emacs--workspaces
              (list (dsh-protocol-workspace--from-alist
                     (list (cons 'workspaceId "w1") (cons 'title "One")
                           (cons 'path "/one") (cons 'sessionIds ["s-a"])))
                    (dsh-protocol-workspace--from-alist
                     (list (cons 'workspaceId "w2") (cons 'title "Two")
                           (cons 'path "/two") (cons 'sessionIds [])))))
        (dsh-emacs-events--host-refresh-drain)
        (let ((ids (mapcar #'dsh-protocol-workspace-workspace-id
                           dsh-emacs--workspaces)))
          (when (and (equal '("w1" "w3") ids)
                     (null (member "w2" ids)))
            (dsh-test-pass "refresh-replays-workspace-frames")))

        ;; Scenario 2: session-status + title frames in flight; the late snapshot
        ;; rolls them back -> drain restores them
        (setq dsh-emacs--host-refresh-depth 0
              dsh-emacs--host-refresh-frames nil)
        (dsh-emacs-events--host-refresh-begin)
        (dsh-emacs-events--host-frame-record (list :session-status "s-a" t))
        (dsh-emacs-events--host-frame-record
         (list :apply-title "s-a" "renamed"))
        ;; Late snapshot (old running + old title)
        (setq dsh-emacs--sessions
              (dsh-emacs-test--session-items
               (list (list (cons 'sessionId "s-a")
                           (cons 'blank :json-false)
                           (cons 'running :json-false)))))
        (dsh-emacs-events--host-refresh-drain)
        (let ((item (dsh-emacs--chat-session-item "s-a")))
          (when (and item
                     (equal t (dsh-protocol-session-running item))
                     (equal "renamed" (dsh-protocol-session-title-value item)))
            (dsh-test-pass "refresh-replays-session-status-title")))

        ;; Scenario 3: nested refresh (list-workspaces called inside list-sessions)
        ;; -- no replay before depth reaches zero; only the final drain replays all
        ;; frames.
        (setq dsh-emacs--host-refresh-depth 0
              dsh-emacs--host-refresh-frames nil)
        (dsh-emacs-events--host-refresh-begin)   ; list-sessions
        (dsh-emacs-events--host-frame-record
         (list :upsert-workspace
               (dsh-protocol-workspace--from-alist
                (list (cons 'workspaceId "w9") (cons 'title "Nine")
                      (cons 'path "/nine") (cons 'sessionIds [])))))
        (dsh-emacs-events--host-refresh-begin)   ; Inner list-workspaces
        (dsh-emacs-events--host-refresh-drain)   ; Inner complete: depth 1, no replay
        (let ((ids-before (mapcar #'dsh-protocol-workspace-workspace-id
                                  dsh-emacs--workspaces)))
          (when (= dsh-emacs--host-refresh-depth 1)
            (dsh-test-pass "nested-refresh-holds-frames")))
        (dsh-emacs-events--host-refresh-drain)   ; Outer complete: replay
        (let ((ids (mapcar #'dsh-protocol-workspace-workspace-id
                           dsh-emacs--workspaces)))
          (when (member "w9" ids)
            (dsh-test-pass "nested-refresh-replays-at-outer-end")))

        ;; Scenario 4: a failed refresh (RPC error) also drains,
        ;; leaving no dangling depth
        (setq dsh-emacs--host-refresh-depth 0)
        (dsh-emacs-events--host-refresh-begin)
        (dsh-emacs-events--host-refresh-drain)
        (when (= dsh-emacs--host-refresh-depth 0)
          (dsh-test-pass "refresh-drain-always-restores-depth")))
    (setq dsh-emacs--sessions old-sessions)
    (setq dsh-emacs--workspaces old-workspaces)
    (setq dsh-emacs--archived-sessions old-archived)
    (setq dsh-emacs--host-refresh-depth old-refresh-depth)
    (setq dsh-emacs--host-refresh-frames old-frames)))

;; --- Test 69: with multiple sessions in parallel, transcript events
;; route by buffer ownership (the guard must not use the global
;; current-session) ---
;; After opening sessions A and B, the global dsh-emacs--current-session
;; points to B, the last opened one; when A's buffer follow stream receives
;; A's transcript event, the ownership check must consult the chat buffer
;; bound to that process (recorded per process at open-session), otherwise
;; A's live transcript would be swallowed by the global current-session
;; ("B"). Conversely: B's events reach only B.
(let* ((chat-a (let ((b (generate-new-buffer " *t69-a*")))
                 (with-current-buffer b
                   (setq-local dsh-emacs--buffer-session "sess-a"))
                 b))
       (chat-b (let ((b (generate-new-buffer " *t69-b*")))
                 (with-current-buffer b
                   (setq-local dsh-emacs--buffer-session "sess-b"))
                 b))
       (rendered-a nil)
       (rendered-b nil)
       (proc-a (make-pipe-process :name "t69-proc-a" :buffer nil))
       (proc-b (make-pipe-process :name "t69-proc-b" :buffer nil))
       (old-session dsh-emacs--current-session))
  (unwind-protect
      (progn
        (process-put proc-a 'dsh-emacs-chat-buffer chat-a)
        (process-put proc-a 'dsh-emacs-follow-stream-id "fa")
        (process-put proc-b 'dsh-emacs-chat-buffer chat-b)
        (process-put proc-b 'dsh-emacs-follow-stream-id "fb")
        (setq dsh-emacs--current-session "sess-b") ; Later-opened session
        (cl-letf (((symbol-function 'dsh-emacs-render-event)
                   (lambda (&rest _)
                     (if (eq (current-buffer) chat-a)
                         (setq rendered-a t)
                       (setq rendered-b t))))
                  ((symbol-function 'dsh-emacs-render--consume-pending-user-message)
                   (lambda (&rest _) nil)))
          ;; A's follow event -> must render into A
          ;; (not swallowed by the global "sess-b")
          (dsh-emacs-events--dispatch-json
           proc-a
           (json-encode
            '((type . "item")
              (streamId . "fa")
              (value . ((type . "event")
                        (event . ((type . "assistant/message")
                                  (sessionId . "sess-a"))))))))
          (when (and rendered-a (null rendered-b))
            (dsh-test-pass "parallel-sessions-mux-event-routes-to-owner"))
          ;; B's follow event -> still only B, unaffected
          ;; by global current-session changes
          (dsh-emacs-events--dispatch-json
           proc-b
           (json-encode
            '((type . "item")
              (streamId . "fb")
              (value . ((type . "event")
                        (event . ((type . "assistant/message")
                                  (sessionId . "sess-b"))))))))
          (when (and rendered-a rendered-b)
            (dsh-test-pass "parallel-sessions-both-streams-render"))))
    (setq dsh-emacs--current-session old-session)
    (kill-buffer chat-a)
    (kill-buffer chat-b)
    (delete-process proc-a)
    (delete-process proc-b)))

;; --- Test 70: an interactive command's target ownership follows the
;; command context (not the global current-session) ---
;; After opening session A and then B, the global
;; dsh-emacs--current-session="sess-b", current-buffer=buf-b; now the user
;; does switch-to-buffer back to A's chat buffer and presses C-c C-c
;; (send/interrupt) or C-c C-r (refresh); the target must be A -- ownership
;; is resolved from the buffer-local dsh-emacs--buffer-session, not from the
;; last-opened global value.
(let* ((buf-a (generate-new-buffer " *t70-a*"))
       (buf-b (generate-new-buffer " *t70-b*"))
       (sent nil)
       (old-session dsh-emacs--current-session)
       (old-buffer dsh-emacs--current-buffer))
  (unwind-protect
      (progn
        (with-current-buffer buf-a
          (dsh-emacs-mode)
          (setq-local dsh-emacs--buffer-session "sess-a"))
        (with-current-buffer buf-b
          (dsh-emacs-mode)
          (setq-local dsh-emacs--buffer-session "sess-b"))
        ;; The last opened is B (the global points to B)
        (setq dsh-emacs--current-session "sess-b")
        (setq dsh-emacs--current-buffer buf-b)
        ;; Scenario 1: switch to A now and send a message
        ;; -> the payload must carry sess-a
        (with-current-buffer buf-a
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method params cb)
                       (push (list method
                                   (cdr (assq 'sessionId
                                              (cdr (assq 'request params)))))
                             sent)
                       (funcall cb t '((accepted . t)))))
                    ((symbol-function 'dsh-emacs--get-input)
                     (lambda () "from A"))
                    ((symbol-function 'dsh-emacs--ml-busy-set)
                     (lambda (&rest _) nil)))
            (dsh-emacs--submit-prompt "from A"))
          (when (and sent
                     (equal (list "session/prompt" "sess-a") (car sent)))
            (dsh-test-pass "send-in-inactive-buffer-targets-its-own-session")))
        ;; Scenario 2: interrupt -> session/cancel likewise carries sess-a
        (with-current-buffer buf-a
          (setq sent nil)
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method params cb)
                       (push (list method
                                   (cdr (assq 'sessionId
                                              (cdr (assq 'request params)))))
                             sent)
                       (funcall cb t nil)))
                    ((symbol-function 'dsh-emacs--ml-busy-set)
                     (lambda (&rest _) nil)))
            (dsh-emacs-interrupt-turn))
          (when (and sent
                     (equal (list "session/cancel" "sess-a") (car sent)))
            (dsh-test-pass "interrupt-in-inactive-buffer-targets-own-session")))
        ;; Scenario 3: refresh -> disconnect and reconnect the current chat's
        ;; follow stream (snapshot seams)
        (with-current-buffer buf-a
          (setq sent nil)
          (cl-letf (((symbol-function 'dsh-emacs-events-disconnect)
                     (lambda () (push 'disconnect sent)))
                    ((symbol-function 'dsh-emacs-events-connect)
                     (lambda (target) (push (list "connect" target) sent))))
            (dsh-emacs-refresh))
          (when (and sent
                     (memq 'disconnect sent)
                     (equal (list "connect" buf-a) (car sent)))
            (dsh-test-pass "refresh-in-inactive-buffer-targets-own-session")))
        ;; Scenario 4: no ownership context (e.g. the *dsh-sessions* list buffer)
        ;; -> global fallback
        (with-temp-buffer
          (when (string= "sess-b" (dsh-emacs--active-session-id))
            (dsh-test-pass "active-session-falls-back-to-global"))))
    (setq dsh-emacs--current-session old-session)
    (setq dsh-emacs--current-buffer old-buffer)
    (kill-buffer buf-a)
    (kill-buffer buf-b)))

;; --- Test 70b: C-c C-r refresh in a chat buffer that is not the last
;; opened one -> reconnect the current buffer's stream ---
;; Regression: refresh once took the history render target from the global
;; `dsh-emacs--current-buffer' (only open-session updates it). After opening
;; A and then B the global points to B; the user does switch-to-buffer back
;; to A and presses C-c C-r: session-id is resolved from A's buffer-local
;; (correct), but the history was rendered into B's chat buffer -- A's text
;; showed up in another session. Since 0.1.2 refresh = disconnect and
;; reconnect the current buffer's own `session/follow' stream, so the target
;; must still be the current buffer.
(let* ((buf-a (generate-new-buffer " *t70b-a*"))
       (buf-b (generate-new-buffer " *t70b-b*"))
       (targets nil)
       (old-session dsh-emacs--current-session)
       (old-buffer dsh-emacs--current-buffer))
  (unwind-protect
      (progn
        (with-current-buffer buf-a
          (setq-local dsh-emacs--buffer-session "sess-a")
          (setq-local dsh-emacs--event-history-loading nil))
        (with-current-buffer buf-b
          (setq-local dsh-emacs--buffer-session "sess-b"))
        ;; The last opened is B (the global points to B)
        (setq dsh-emacs--current-session "sess-b")
        (setq dsh-emacs--current-buffer buf-b)
        (with-current-buffer buf-a
          (cl-letf (((symbol-function 'dsh-emacs-events-disconnect)
                     (lambda () (push 'disconnect targets)))
                    ((symbol-function 'dsh-emacs-events-connect)
                     (lambda (target) (push (list "connect" target) targets))))
            (dsh-emacs-refresh)))
        (dsh-test-assert "refresh-from-inactive-chat-renders-into-own-buffer"
          ;; The reconnect target is A, which initiated the refresh,
          ;; never the last-opened B
          (and targets
               (eq buf-a (cadr (car targets)))
               (memq 'disconnect targets))
          (null (memq (list "connect" buf-b) targets))))
    (setq dsh-emacs--current-session old-session)
    (setq dsh-emacs--current-buffer old-buffer)
    (kill-buffer buf-a)
    (kill-buffer buf-b)))

;; --- Test 71: pure-function coverage reinforcement (markdown tables /
;; render-trim / tokens / http hint) ---
;; Pure-logic blind spots exposed by the coverage report
;; (scripts/check-coverage.el): markdown table allocation, display width,
;; longest word, render--trim boundaries, format-cost branches, usage-p,
;; http-error-hint.
(let ((pass-n 0))
  ;; markdown table: width allocation (verbatim when there is slack)
  (when (equal '(5 5) (dsh-emacs-markdown--table-allocate-widths '(5 5) '(2 2) 18))
    (dsh-test-pass "table-allocate-keeps-when-no-shrink"))
  ;; when compression is needed, allocate by shrinkable ratio, never below
  ;; min-widths
  (when (equal '(3 3 3) (dsh-emacs-markdown--table-allocate-widths '(10 10 10) '(3 3 3) 20))
    (dsh-test-pass "table-allocate-shrinks-to-fit"))
  ;; return min-widths directly when the shrinkable amount is 0
  (when (equal '(10 3) (dsh-emacs-markdown--table-allocate-widths '(10 3) '(10 3) 10))
    (dsh-test-pass "table-allocate-min-bound"))
  ;; total width = each column + 3 (padding both sides + separator pipe),
  ;; plus the leading pipe
  (when (= 15 (dsh-emacs-markdown--table-total-width '(4 4)))
    (dsh-test-pass "table-total-width-counts-borders"))
  ;; longest word (no window: the string-width path)
  (when (= 9 (dsh-emacs-markdown--table-longest-word :str "alpha beta-long gamma"))
    (dsh-test-pass "table-longest-word-ascii"))
  ;; longest word of an empty string = 0
  (when (= 0 (dsh-emacs-markdown--table-longest-word :str ""))
    (dsh-test-pass "table-longest-word-empty"))
  ;; display width: ASCII goes through string-width; Chinese counted by character
  (when (and (= 7 (dsh-emacs-markdown--table-display-width :str "abc def"))
             (= 8 (dsh-emacs-markdown--table-display-width :str "中文测试")))
    (dsh-test-pass "table-display-width-char-count"))
  ;; render--trim: collapse whitespace + truncate with an ellipsis
  (when (equal "hello …" (dsh-emacs-render--trim "  hello   world  " 6))
    (dsh-test-pass "render-trim-folds-and-ellipsizes"))
  ;; render--trim: multi-line/tab collapsing
  (when (equal "…" (dsh-emacs-render--trim "a\nb\tc" 0))
    (dsh-test-pass "render-trim-folds-newlines"))
  ;; format-cost branches
  (when (and (equal "$0.000" (dsh-emacs-format-cost nil))
             (equal "<$0.001" (dsh-emacs-format-cost 0.0005))
             (equal "$0.000" (dsh-emacs-format-cost "x"))
             (equal "$1.234" (dsh-emacs-format-cost 1.234)))
    (dsh-test-pass "format-cost-branches"))
  ;; usage-p: valid plist detection (returns truthy), non-plist is nil
  (when (and (dsh-emacs-usage-p '(:input 1 :output 2))
             (null (dsh-emacs-usage-p '(a b))))
    (dsh-test-pass "usage-p-detects-plist"))
  ;; http-error-hint: 4xx/5xx hint that the RPC does not exist, other codes
  ;; short form, non-error empty
  (when (and (string-match-p "HTTP 404" (dsh-emacs--http-error-hint '(error http 404)))
             (string-match-p "HTTP 500" (dsh-emacs--http-error-hint '(error http 500)))
             (equal " (HTTP 302)" (dsh-emacs--http-error-hint '(error http 302)))
             (equal "" (dsh-emacs--http-error-hint nil)))
    (dsh-test-pass "http-error-hint-branches"))
  pass-n)

;; --- Test 72: markdown parsing layer pure-function reinforcement (coverage
;; report class A blind spots) ---
;; Target: deconstruct / highlight-code / table-min-widths / shorten-cwd /
;; insert-read-only / resolve-image-url / parse-local-link (needs temp files).
(let ((tmpdir (make-temp-file "dsh-cov" t)))
  (unwind-protect
      (progn
        ;; markdown--deconstruct: splitting into contiguous face runs
        (when (equal '(("my" (dsh-emacs-markdown-italic))
                       (" " nil)
                       ("text" (dsh-emacs-markdown-bold)))
                     (dsh-emacs-markdown--deconstruct
                      (dsh-emacs-markdown-convert "_my_ **text**")))
          (dsh-test-pass "markdown-deconstruct-splits-face-runs"))
        ;; highlight-code: a real mode (elisp) font-locks the face,
        ;; unknown language verbatim
        (let ((hl (dsh-emacs-markdown--highlight-code "(defun f () 1)" "elisp")))
          (when (and (string= hl "(defun f () 1)")
                     (get-text-property 1 'face hl))
            (dsh-test-pass "markdown-highlight-elisp-applies-face")))
        (when (equal "abc" (dsh-emacs-markdown--highlight-code "abc" "nolangxyz"))
          (dsh-test-pass "markdown-highlight-unknown-lang-pass-through"))
        ;; table-min-widths: longest word per column
        (when (equal '(6 3)
                     (dsh-emacs-markdown--table-min-widths
                      :processed-rows '(("hdr" "a b" "ccc")
                                        ("row" "longer" "dd"))))
          (dsh-test-pass "markdown-table-min-widths-longest-word"))
        ;; shorten-cwd: home prefix -> ~, deep path -> ../last two segments
        (when (equal "~/src/foo"
                     (dsh-emacs-session--shorten-cwd
                      (format "%s/src/foo" (expand-file-name "~"))))
          (dsh-test-pass "shorten-cwd-home-prefix"))
        (when (equal "../d/e" (dsh-emacs-session--shorten-cwd "/a/b/c/d/e"))
          (dsh-test-pass "shorten-cwd-deep-path"))
        ;; insert-read-only: text carries read-only + face properties
        (with-temp-buffer
          (dsh-emacs-render--insert-read-only "hi" 'dsh-emacs-test-face)
          (when (and (equal t (get-text-property 1 'read-only))
                     (eq 'dsh-emacs-test-face (get-text-property 1 'face)))
            (dsh-test-pass "render-insert-read-only-props")))
        ;; resolve-image-url: local file in its various forms,
        ;; nil when it does not exist
        (let ((f (expand-file-name "img.png" tmpdir)))
          (with-temp-file f)
          (when (equal f (dsh-emacs-markdown--resolve-image-url
                          (concat "file://" f)))
            (dsh-test-pass "resolve-image-url-file-uri"))
          (when (equal f (dsh-emacs-markdown--resolve-image-url f))
            (dsh-test-pass "resolve-image-url-absolute"))
          (when (null (dsh-emacs-markdown--resolve-image-url
                       (concat tmpdir "/missing.png")))
            (dsh-test-pass "resolve-image-url-missing-nil")))
        ;; parse-local-link: file:// URI, file: prefix,
        ;; relative path + line number, nil for non-local
        (let ((f (expand-file-name "foo.el" tmpdir)))
          (with-temp-file f)
          (let ((parsed (dsh-emacs-markdown--parse-local-link
                         (concat f "#L10"))))
            (when (and (equal (expand-file-name f) (car parsed))
                       (equal 10 (cdr parsed)))
              (dsh-test-pass "parse-local-link-hash-line")))
          (let ((parsed (dsh-emacs-markdown--parse-local-link
                         (concat "file://" f ":5"))))
            (when (and (equal (expand-file-name f) (car parsed))
                       (equal 5 (cdr parsed)))
              (dsh-test-pass "parse-local-link-file-colon")))
          (when (null (dsh-emacs-markdown--parse-local-link
                       "https://example.com/path"))
            (dsh-test-pass "parse-local-link-remote-nil"))))
    (delete-directory tmpdir t)))

;; --- Test 73: mode-line pure-logic reinforcement (shorten-cwd / branch
;; cache) ---
;; mode-line--shorten-cwd's ~ prefix, non-home paths verbatim; cached-branch's
;; freshness logic (keeps the old value within the cache window, re-queries
;; once stale). detect-branch goes through real git, so it is mocked here to
;; pin down the remaining branches.
(let ((old-cache dsh-emacs--modeline-branch-cache))
  (unwind-protect
      (progn
        ;; shorten-cwd: home prefix shortened to a ~ prefix
        ;; (home-dir cut, relative part kept)
        (when (equal (format "~%s" "proj")
                     (dsh-emacs-modeline--shorten-cwd
                      (format "%s/proj" (getenv "HOME"))))
          (dsh-test-pass "mode-line-shorten-cwd-home-prefix"))
        (when (equal "/opt/app" (dsh-emacs-modeline--shorten-cwd "/opt/app"))
          (dsh-test-pass "mode-line-shorten-cwd-non-home"))
        ;; cached-branch: keeps the old value while the cache is fresh
        ;; (even if the mock changed it)
        (setq dsh-emacs--modeline-branch-cache nil)
        (cl-letf (((symbol-function 'dsh-emacs-modeline--detect-branch)
                   (lambda () "feature/x"))
                  (dsh-emacs-modeline-branch-refresh-interval 60))
          (let ((b1 (dsh-emacs-modeline--cached-branch)))
            (cl-letf (((symbol-function 'dsh-emacs-modeline--detect-branch)
                       (lambda () "other")))
              (let ((b2 (dsh-emacs-modeline--cached-branch)))
                (when (and (equal "feature/x" b1)
                           (equal "feature/x" b2))
                  (dsh-test-pass "mode-line-cached-branch-fresh-keeps-value"))
                ;; cache stale -> re-query the new value
                (setf (cdr dsh-emacs--modeline-branch-cache)
                      (- (float-time) 999))
                (when (equal "other" (dsh-emacs-modeline--cached-branch))
                  (dsh-test-pass "mode-line-cached-branch-stale-refetches"))))))
        ;; segment-branch: a branch renders wrapped in parentheses
        (let ((dsh-emacs--modeline-branch "main"))
          (let ((seg (dsh-emacs-modeline--segment-branch)))
            (when (string-match-p "main" seg)
              (dsh-test-pass "mode-line-segment-branch-renders"))))
        ;; segment-cwd: propertize face
        (let ((seg (dsh-emacs-modeline--segment-cwd)))
          (when (get-text-property 0 'face seg)
            (dsh-test-pass "mode-line-segment-cwd-face"))))
    (setq dsh-emacs--modeline-branch-cache old-cache)))


;; --- Test 74: agentPresets/list protocol structs (thinking preset
;; candidates for a new session) ---
;; wire alist (presets array as a vector) -> struct: presets normalized to a
;; list, all fields read through accessors; broken/missing fields do not
;; break the conversion.
(let* ((v (dsh-protocol-agent-preset-list--from-alist
           '((presets . [((id . "standard") (trust . "system")
                          (isDefault . t) (name . "Standard mode"))
                         ((id . "broken-agent") (broken . "load failed"))])
             (authorable . t)
             (hasDocument . t))))
       (presets (dsh-protocol-agent-preset-list-presets v))
       (p0 (car presets))
       (p1 (cadr presets)))
  (when (and (dsh-protocol-agent-preset-p p0)
             (equal "standard" (dsh-protocol-agent-preset-id p0))
             (equal "system" (dsh-protocol-agent-preset-trust p0))
             (eq t (dsh-protocol-agent-preset-is-default p0))
             (equal "Standard mode" (dsh-protocol-agent-preset-name p0))
             (null (dsh-protocol-agent-preset-broken p0))
             (equal 2 (length presets))
             (equal "broken-agent" (dsh-protocol-agent-preset-id p1))
             (equal "load failed" (dsh-protocol-agent-preset-broken p1))
             (eq t (dsh-protocol-agent-preset-list-authorable v))
             (eq t (dsh-protocol-agent-preset-list-has-document v)))
    (dsh-test-pass "agent-preset-list-protocol-struct")))

;; --- Test 74b: preset / command `false' booleans normalize at the struct
;; --- boundary ---
;; `AgentPresetRow.isDefault' and the roster's `authorable' / `hasDocument'
;; are required JSON booleans, so `json-read' hands back the truthy
;; `:json-false' for every false value.  Kept raw, `isDefault' made
;; `dsh-emacs--preset-default-id' (a `cl-some' over the roster) return the
;; FIRST preset instead of the host's real default whenever
;; `dsh-emacs-default-preset' was unset.
(let* ((roster (dsh-protocol-agent-preset-list--from-alist
                '((presets . [((id . "alpha") (isDefault . :json-false))
                              ((id . "beta") (isDefault . t))])
                  (authorable . :json-false)
                  (hasDocument . :json-false))))
       (presets (dsh-protocol-agent-preset-list-presets roster)))
  (dsh-test-assert "agent-preset-wire-false-is-default-normalizes-to-nil"
    (null (dsh-protocol-agent-preset-is-default (car presets))))
  (dsh-test-assert "agent-preset-wire-true-is-default-normalizes-to-t"
    (eq t (dsh-protocol-agent-preset-is-default (cadr presets))))
  (dsh-test-assert "agent-preset-roster-wire-false-flags-normalize"
    (null (dsh-protocol-agent-preset-list-authorable roster))
    (null (dsh-protocol-agent-preset-list-has-document roster))))
(let ((input (dsh-protocol-command-input--from-alist
              '((hint . "<x>") (attachments . :json-false)))))
  (dsh-test-assert "command-input-wire-false-attachments-normalizes-to-nil"
    (null (dsh-protocol-command-input-attachments input))))

;; --- Test 75: new-session preset candidate table (web display name +
;; cached roster + built-in fallback) ---
;; Display names match web: a system built-in preset is named via web's
;; built-in key map ("Standard mode" and so on, the web name wins even if it
;; publishes its own name); a user preset uses its published name (id when
;; there is none); broken entries are dropped. No cache -> the web names of
;; the four built-ins.
(let ((old-cache dsh-emacs--agent-presets))
  (unwind-protect
      (progn
        (setq dsh-emacs--agent-presets nil)
        (when (equal '(("Standard mode" . "standard")
                       ("Minimal mode" . "minimal")
                       ("PTC mode" . "code")
                       ("Creator mode" . "cordis"))
                     (dsh-emacs--preset-choices))
          (dsh-test-pass "preset-choices-fallback-builtins"))
        (setq dsh-emacs--agent-presets
              (dsh-protocol-agent-preset-list--from-alist
               '((presets . [((id . "standard") (trust . "system"))
                             ((id . "minimal") (trust . "system")
                              (name . "Legacy name"))
                             ((id . "my-agent") (trust . "user")
                              (name . "My Agent"))
                             ((id . "broken-agent") (broken . "x"))]))))
        (when (equal '(("Standard mode" . "standard")
                       ("Minimal mode" . "minimal")
                       ("My Agent" . "my-agent"))
                     (dsh-emacs--preset-choices))
          (dsh-test-pass "preset-choices-web-names-and-roster"))
        ;; display-name boundaries: system unknown id -> name ?? id;
        ;; user without name -> id
        (when (and (equal "Future Mode"
                          (dsh-emacs--preset-display-name
                           (dsh-protocol-agent-preset--from-alist
                            '((id . "future") (trust . "system")
                              (name . "Future Mode")))))
                   (equal "my-raw"
                          (dsh-emacs--preset-display-name
                           (dsh-protocol-agent-preset--from-alist
                            '((id . "my-raw") (trust . "user"))))))
          (dsh-test-pass "preset-display-name-falls-back-name-or-id")))
    (setq dsh-emacs--agent-presets old-cache)))

;; --- Test 76: preset preselected id (config > roster isDefault > none) ---
(let ((old-cache dsh-emacs--agent-presets))
  (unwind-protect
      (progn
        (setq dsh-emacs--agent-presets
              (dsh-protocol-agent-preset-list--from-alist
               '((presets . [((id . "minimal") (isDefault . :json-false))
                             ((id . "standard") (isDefault . t))]))))
        (dsh-test-assert "preset-default-id-roster-is-default"
          (equal "standard" (dsh-emacs--preset-default-id nil)))
        (dsh-test-assert "preset-default-id-configured-wins"
          (equal "minimal" (dsh-emacs--preset-default-id "minimal")))
        (dsh-test-assert "preset-default-id-invalid-config-falls-back"
          (equal "standard" (dsh-emacs--preset-default-id "ghost"))))
    (setq dsh-emacs--agent-presets old-cache)))

;; --- Test 77: read-preset interactive read (candidates + preselect + host
;; default + C-g) ---
;; Pick by display name -> its id; empty RET accepts the preselect (models
;; completing-read returning DEF); with no preselect an empty RET -> nil
;; (host default, no agentPreset sent); C-g bubbles up to cancel the whole
;; creation (quit is not swallowed by read-preset). Every read triggers one
;; agentPresets/list refresh (rpc-async is captured by the mock).
(let ((old-cache dsh-emacs--agent-presets)
      (calls nil))
  (unwind-protect
      (progn
        (setq dsh-emacs--agent-presets
              (dsh-protocol-agent-preset-list--from-alist
               '((presets . [((id . "standard") (isDefault . t)
                              (name . "Standard mode"))
                             ((id . "minimal") (name . "Minimal mode"))]))))
        ;; pick by display name -> its id;
        ;; one roster refresh is also sent to the backend
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (&rest _) "Standard mode"))
                  ((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (method _params _cb)
                     (push method calls))))
          (when (and (equal "standard" (dsh-emacs--read-preset nil))
                     (member "agentPresets/list" calls))
            (dsh-test-pass "read-preset-pick-by-display-name")))
        ;; empty RET -> accept the preselected default
        ;; (roster isDefault = standard)
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (_prompt _table &optional _pred _req _init _hist
                                   def _inherit)
                     (or def "")))
                  ((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (&rest _) nil)))
          (when (equal "standard" (dsh-emacs--read-preset nil))
            (dsh-test-pass "read-preset-empty-ret-accepts-default")))
        ;; no isDefault and no config -> empty RET returns nil (host default)
        (setq dsh-emacs--agent-presets
              (dsh-protocol-agent-preset-list--from-alist
               '((presets . [((id . "standard")
                              (name . "Standard mode"))]))))
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (_prompt _table &optional _pred _req _init _hist
                                   def _inherit)
                     (or def "")))
                  ((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (&rest _) nil)))
          (when (null (dsh-emacs--read-preset nil))
            (dsh-test-pass "read-preset-no-default-keeps-host-default")))
        ;; C-g -> quit bubbles up to interactive (not swallowed by read-preset)
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (&rest _) (signal 'quit nil)))
                  ((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (&rest _) nil)))
          (condition-case err
              (dsh-emacs--read-preset nil)
            (quit (dsh-test-pass "read-preset-c-g-aborts-cleanly")))))
    (setq dsh-emacs--agent-presets old-cache)))

;; --- Test 78: a new session carries agentPreset ---
;; Calling directly with a preset -> the session/create params contain
;; agentPreset (both the cwd and workspaceId contexts); the agentPreset in
;; the response enters the placeholder cache row (immediately visible in the
;; list detail/footer); without a preset -> no agentPreset is sent.
(let* ((old-sessions dsh-emacs--sessions))
  (unwind-protect
      (progn
        (setq dsh-emacs--sessions nil)
        ;; with preset (cwd context)
        (let ((calls nil)
              (dsh-emacs-new-session-auto-project nil))
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method params cb)
                       (push (list method params) calls)
                       (funcall cb t '((sessionId . "s-preset")
                                       (agentPreset . "standard")))))
                    ((symbol-function 'dsh-emacs-open-session)
                     (lambda (_sid) nil)))
            (dsh-emacs-new-session nil nil "standard")
            (let* ((call (car calls))
                   (params (cadr call)))
              (when (and (string= "session/create" (car call))
                         (null (assq 'workspaceId (cdr (assq 'request params))))
                         (assq 'cwd (cdr (assq 'request params)))
                         (string= "standard"
                                  (cdr (assq 'agentPreset (cdr (assq 'request params))))))
                (dsh-test-pass "new-session-with-preset-sends-agent-preset")))
            ;; the placeholder cache row carries the preset
            ;; (written back from the response)
            (let ((item (dsh-emacs--chat-session-item "s-preset")))
              (when (and item
                         (string= "standard"
                                  (dsh-protocol-session-agent-preset item)))
                (dsh-test-pass "new-session-preset-cached-in-placeholder")))))
        ;; with preset (workspace context): workspaceId and agentPreset coexist
        (let ((calls nil))
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method params cb)
                       (push (list method params) calls)
                       (funcall cb t '((sessionId . "s-ws-preset")))))
                    ((symbol-function 'dsh-emacs-open-session)
                     (lambda (_sid) nil)))
            (dsh-emacs-new-session nil "w1" "code")
            (let* ((call (car calls))
                   (params (cadr call)))
              (when (and (string= "session/create" (car call))
                         (string= "w1" (cdr (assq 'workspaceId (cdr (assq 'request params)))))
                         (null (assq 'cwd (cdr (assq 'request params))))
                         (string= "code" (cdr (assq 'agentPreset (cdr (assq 'request params))))))
                (dsh-test-pass "new-session-workspace-with-preset")))))
        ;; no preset -> no agentPreset sent
        (let ((calls nil)
              (dsh-emacs-new-session-auto-project nil))
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method params cb)
                       (push (list method params) calls)
                       (funcall cb t '((sessionId . "s-plain2")))))
                    ((symbol-function 'dsh-emacs-open-session)
                     (lambda (_sid) nil)))
            (dsh-emacs-new-session nil nil nil)
            (let* ((call (car calls))
                   (params (cadr call)))
              (when (and (string= "session/create" (car call))
                         (null (assq 'agentPreset (cdr (assq 'request params)))))
                (dsh-test-pass "new-session-without-preset-omits-agent-preset"))))))
    (setq dsh-emacs--sessions old-sessions)))

;; --- Test 79: interactive with a prefix argument -> pick the preset first,
;; then create ---
;; call-interactively under C-u: the interactive spec reads a preset
;; (completing-read mock returns a display name), session/create carries its
;; id, and agentPresets/list was triggered.
(let* ((old-sessions dsh-emacs--sessions)
       (buf (generate-new-buffer " *dsh-prefix-create*"))
       (calls nil)
       (dsh-emacs-new-session-auto-project nil)
       (old-cache dsh-emacs--agent-presets))
  (unwind-protect
      (with-current-buffer buf
        (setq dsh-emacs--sessions nil)
        (setq dsh-emacs--agent-presets
              (dsh-protocol-agent-preset-list--from-alist
               '((presets . [((id . "minimal")
                              (name . "Minimal mode"))]))))
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (method params cb)
                     (push (list method params) calls)
                     (when (string= method "session/create")
                       (funcall cb t '((sessionId . "s-pfx"))))))
                  ((symbol-function 'dsh-emacs-open-session)
                   (lambda (_sid) nil))
                  ((symbol-function 'completing-read)
                   (lambda (&rest _) "Minimal mode"))
                  (current-prefix-arg '(4)))
          (call-interactively #'dsh-emacs-new-session))
        (let ((create (cl-find-if
                       (lambda (c) (string= "session/create" (car c)))
                       calls)))
          (when (and create
                     (string= "minimal"
                              (cdr (assq 'agentPreset
                                         (cdr (assq 'request (cadr create))))))
                     (member "agentPresets/list" (mapcar #'car calls)))
            (dsh-test-pass "new-session-prefix-asks-preset"))))
    (setq dsh-emacs--sessions old-sessions)
    (setq dsh-emacs--agent-presets old-cache)
    (when (buffer-live-p buf) (kill-buffer buf))))

;; --- Test 80: list key c = create immediately with the default preset, C =
;; pick a preset first ---
;; c -> dsh-emacs-new-session (no chooser; the session carries
;; dsh-emacs-default-preset, nil means host default, no agentPreset sent and
;; no roster fetched); C -> dsh-emacs-new-session-choose-preset (pick a
;; preset first, then create; the workspace context carries over and an
;; agentPresets/list refresh is triggered).
(when (eq (lookup-key dsh-emacs-session-mode-map "c")
          #'dsh-emacs-new-session)
  (dsh-test-pass "session-map-c-binds-plain-create"))
(when (eq (lookup-key dsh-emacs-session-mode-map "C")
          #'dsh-emacs-new-session-choose-preset)
  (dsh-test-pass "session-map-C-binds-preset-choose"))

;; c path: interactive without a prefix ->
;; only session/create is sent, with no agentPreset
(let* ((calls nil)
       (buf (generate-new-buffer " *dsh-c-default-create*"))
       (dsh-emacs-new-session-auto-project nil))
  (unwind-protect
      (with-current-buffer buf
        (insert "row text\n")
        (goto-char (point-min))
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (method params cb)
                     (push (list method params) calls)
                     (funcall cb t '((sessionId . "s-c-default")))))
                  ((symbol-function 'dsh-emacs-open-session)
                   (lambda (_sid) nil)))
          (call-interactively #'dsh-emacs-new-session))
        (let* ((call (car calls))
               (params (cadr call)))
          (when (and (string= "session/create" (car call))
                     (null (assq 'agentPreset (cdr (assq 'request params))))
                     (not (member "agentPresets/list" (mapcar #'car calls))))
            (dsh-test-pass "session-c-creates-without-preset-prompt"))))
    (when (buffer-live-p buf) (kill-buffer buf))))

;; C path: pick a preset first (completing-read mock returns a display name),
;; create in the workspace context -> session/create carries workspaceId +
;; agentPreset, and the roster was triggered.
(let* ((calls nil)
       (buf (generate-new-buffer " *dsh-C-preset-create*"))
       (old-cache dsh-emacs--agent-presets))
  (unwind-protect
      (with-current-buffer buf
        (insert "  workspace row")
        (put-text-property (point-min) (point-max)
                           'dsh-emacs-workspace-id "w-C")
        (goto-char (point-min))
        (setq dsh-emacs--agent-presets
              (dsh-protocol-agent-preset-list--from-alist
               '((presets . [((id . "code") (name . "PTC mode"))]))))
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (method params cb)
                     (push (list method params) calls)
                     (when (string= method "session/create")
                       (funcall cb t '((sessionId . "s-C"))))))
                  ((symbol-function 'dsh-emacs-open-session)
                   (lambda (_sid) nil))
                  ((symbol-function 'completing-read)
                   (lambda (&rest _) "PTC mode")))
          (call-interactively #'dsh-emacs-new-session-choose-preset))
        (let ((create (cl-find-if
                       (lambda (c) (string= "session/create" (car c)))
                       calls)))
          (when (and create
                     (string= "w-C" (cdr (assq 'workspaceId
                                               (cdr (assq 'request (cadr create))))))
                     (string= "code" (cdr (assq 'agentPreset
                                                (cdr (assq 'request (cadr create))))))
                     (member "agentPresets/list" (mapcar #'car calls)))
            (dsh-test-pass "session-C-creates-with-chosen-preset"))))
    (setq dsh-emacs--agent-presets old-cache)
    (when (buffer-live-p buf) (kill-buffer buf))))

;; --- Test 80b: new-session auto-detects the project and assigns its
;; workspace ---
;; The detection chain depends on project.el (built in since Emacs 28+); when
;; the require returns nil on 27 the whole section is skipped without
;; affecting the other tests. Layered coverage:
;;   1) `dsh-emacs--project-root': project.el first -> VC root -> .git walk;
;;      project → nil;
;;     2) `dsh-emacs--workspace-id-by-path': matched by the same canonical path
;;        as the server (trailing slash / symlinks both resolved);
;;     3) `dsh-emacs--new-session-project-workspace' orchestration: option
;;        on/off, local/remote server, cache hit skips RPC, a miss goes through
;;        the idempotent workspace/create and is cached immediately, RPC failure
;;        falls back to nil;
;;     4) end-to-end call-interactively: plain buffer -> session/create with
;;        workspaceId and no cwd; creation failure -> cwd is still sent.
(require 'project nil t)
(require 'vc nil t)
(when (and (fboundp 'project-current) (fboundp 'project-root)
           (fboundp 'vc-root-dir))
  ;; project.el branch first: returns its root
  ;; (plus `~' / trailing-slash normalization)
  (let ((root (directory-file-name (make-temp-file "dsh-pj1-" t)))
        (fake (list 'vc "fake-project")))
    (unwind-protect
        (cl-letf (((symbol-function 'project-current) (lambda (&rest _) fake))
                  ((symbol-function 'project-root) (lambda (_pr) root)))
          (when (equal (dsh-emacs--project-root
                        (expand-file-name "inside" root))
                       root)
            (dsh-test-pass "project-root-prefers-project-el")))
      (delete-directory root t)))
  ;; fallback chain: project.el no result + VC root no result
  ;; -> .git walk; all miss -> nil
  (let* ((root (directory-file-name (make-temp-file "dsh-pj2-" t)))
         (empty (make-temp-file "dsh-pj3-" t)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name ".git" root))
          (make-directory (expand-file-name "nested" root))
          (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil))
                    ((symbol-function 'project-root) (lambda (&rest _) nil))
                    ((symbol-function 'vc-root-dir) (lambda (&rest _) nil)))
            (when (equal (dsh-emacs--project-root
                          (expand-file-name "nested" root))
                         root)
              (dsh-test-pass "project-root-walks-git-marker"))
            (when (null (dsh-emacs--project-root empty))
              (dsh-test-pass "project-root-nil-outside-any-project"))))
      (delete-directory root t)
      (delete-directory empty t))))

;; workspace path matching (canonical): trailing slash,
;; symlink, different directory
(let* ((root (directory-file-name (make-temp-file "dsh-wsp-" t)))
       (sym (expand-file-name
             (format "dsh-link-%d" (random 99999))
             (directory-file-name temporary-file-directory)))
       (ws (dsh-protocol-workspace--from-alist
            (list (cons 'workspaceId "w-root")
                  (cons 'path root)
                  (cons 'sessionIds [])))))
  (unwind-protect
      (let ((dsh-emacs--workspaces (list ws)))
        (when (equal (dsh-emacs--workspace-id-by-path (concat root "/"))
                     "w-root")
          (dsh-test-pass "workspace-id-by-path-matches-trailing-slash"))
        (when (null (dsh-emacs--workspace-id-by-path
                     (expand-file-name "elsewhere" root)))
          (dsh-test-pass "workspace-id-by-path-misses-different-dir"))
        (ignore-errors (delete-file sym))
        (make-symbolic-link root sym)
        (when (equal (dsh-emacs--workspace-id-by-path sym) "w-root")
          (dsh-test-pass "workspace-id-by-path-resolves-symlink")))
    (ignore-errors (delete-file sym))
    (delete-directory root t)))

;; orchestration: cache hit skips RPC; a miss creates and caches; RPC
;; failure falls back to nil; option off skips detection; remote server is
;; skipped
(let* ((root (directory-file-name (make-temp-file "dsh-pjws-" t)))
       (dsh-emacs-new-session-auto-project t))
  (unwind-protect
      (progn
        (let ((dsh-emacs--workspaces
               (list (dsh-protocol-workspace--from-alist
                      (list (cons 'workspaceId "w-proj")
                            (cons 'path root)
                            (cons 'sessionIds [])))))
              (rpc-called nil))
          (cl-letf (((symbol-function 'dsh-emacs--server-local-host-p)
                     (lambda () t))
                    ((symbol-function 'dsh-emacs--project-root)
                     (lambda (_dir) root))
                    ((symbol-function 'dsh-emacs--rpc-request)
                     (lambda (&rest _) (setq rpc-called t) (cons nil "no"))))
            (when (equal (dsh-emacs--new-session-project-workspace root)
                         "w-proj")
              (dsh-test-pass "project-workspace-cache-hit-returns-id"))
            (when (null rpc-called)
              (dsh-test-pass "project-workspace-cache-hit-skips-create"))))
        (let ((dsh-emacs--workspaces nil)
              (created nil))
          (cl-letf (((symbol-function 'dsh-emacs--server-local-host-p)
                     (lambda () t))
                    ((symbol-function 'dsh-emacs--project-root)
                     (lambda (_dir) root))
                    ((symbol-function 'dsh-emacs--rpc-request)
                     (lambda (_method _params)
                       (setq created t)
                       (cons t (list (cons 'workspace
                                           (list (cons 'workspaceId "w-created")
                                                 (cons 'path root)
                                                 (cons 'sessionIds []))))))))
            (when (equal (dsh-emacs--new-session-project-workspace root)
                         "w-created")
              (dsh-test-pass "project-workspace-created-on-cache-miss"))
            (when (and created
                       (cl-find-if (lambda (w)
                                     (equal "w-created"
                                            (dsh-protocol-workspace-workspace-id w)))
                                   dsh-emacs--workspaces))
              (dsh-test-pass "project-workspace-created-upserts-cache"))))
        (let ((dsh-emacs--workspaces nil))
          (cl-letf (((symbol-function 'dsh-emacs--server-local-host-p)
                     (lambda () t))
                    ((symbol-function 'dsh-emacs--project-root)
                     (lambda (_dir) root))
                    ((symbol-function 'dsh-emacs--rpc-request)
                     (lambda (&rest _) (cons nil "boom"))))
            (when (null (dsh-emacs--new-session-project-workspace root))
              (dsh-test-pass "project-workspace-rpc-failure-returns-nil"))))
        (let ((dsh-emacs-new-session-auto-project nil)
              (rpc-called nil))
          (cl-letf (((symbol-function 'dsh-emacs--rpc-request)
                     (lambda (&rest _) (setq rpc-called t) nil)))
            (when (and (null (dsh-emacs--new-session-project-workspace root))
                       (null rpc-called))
              (dsh-test-pass "project-workspace-option-off-disables"))))
        (cl-letf (((symbol-function 'dsh-emacs--server-local-host-p)
                   (lambda () nil))
                  ((symbol-function 'dsh-emacs--project-root)
                   (lambda (_dir) root))
                  ((symbol-function 'dsh-emacs--rpc-request)
                   (lambda (&rest _) (error "remote must not RPC"))))
          (when (null (dsh-emacs--new-session-project-workspace root))
            (dsh-test-pass "project-workspace-remote-server-skipped"))))
    (delete-directory root t)))

;; end-to-end (call-interactively): plain buffer -> project hit
;; -> assigned to that workspace
(let* ((old-sessions dsh-emacs--sessions)
       (root (directory-file-name (make-temp-file "dsh-e2e-" t)))
       (calls nil)
       (buf (generate-new-buffer " *dsh-project-create*")))
  (unwind-protect
      (with-current-buffer buf
        (insert "plain text\n")
        (goto-char (point-min))
        (let ((dsh-emacs--workspaces
               (list (dsh-protocol-workspace--from-alist
                      (list (cons 'workspaceId "w-proj")
                            (cons 'path root)
                            (cons 'sessionIds []))))))
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method params cb)
                       (push (list method params) calls)
                       (funcall cb t '((sessionId . "s-proj")))))
                    ((symbol-function 'dsh-emacs-open-session)
                     (lambda (_sid) nil))
                    ((symbol-function 'dsh-emacs--project-root)
                     (lambda (_dir) root))
                    ((symbol-function 'dsh-emacs--server-local-host-p)
                     (lambda () t))
                    ((symbol-function 'dsh-emacs--rpc-request)
                     (lambda (&rest _) (cons nil "must-not-fire"))))
            (call-interactively #'dsh-emacs-new-session))
          (let* ((create (cl-find-if
                          (lambda (c) (string= "session/create" (car c)))
                          calls))
                 (params (and create (cadr create))))
            (when (and create
                       (string= "w-proj" (cdr (assq 'workspaceId (cdr (assq 'request params)))))
                       (null (assq 'cwd (cdr (assq 'request params)))))
              (dsh-test-pass
               "new-session-attaches-to-detected-project-workspace")))))
    (setq dsh-emacs--sessions old-sessions)
    (delete-directory root t)
    (when (buffer-live-p buf) (kill-buffer buf))))

;; end-to-end: cache miss -> idempotent workspace creation, then assigned
(let* ((old-sessions dsh-emacs--sessions)
       (old-ws dsh-emacs--workspaces)
       (root (directory-file-name (make-temp-file "dsh-e2e-" t)))
       (calls nil)
       (buf (generate-new-buffer " *dsh-project-create2*")))
  (unwind-protect
      (with-current-buffer buf
        (insert "plain text\n")
        (goto-char (point-min))
        (setq dsh-emacs--workspaces nil)
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (method params cb)
                     (push (list method params) calls)
                     (funcall cb t '((sessionId . "s-proj2")))))
                  ((symbol-function 'dsh-emacs-open-session)
                   (lambda (_sid) nil))
                  ((symbol-function 'dsh-emacs--project-root)
                   (lambda (_dir) root))
                  ((symbol-function 'dsh-emacs--server-local-host-p)
                   (lambda () t))
                  ((symbol-function 'dsh-emacs--rpc-request)
                   (lambda (_method _params)
                     (cons t (list (cons 'workspace
                                         (list (cons 'workspaceId "w-created2")
                                               (cons 'path root)
                                               (cons 'sessionIds []))))))))
          (call-interactively #'dsh-emacs-new-session))
        (let* ((create (cl-find-if
                        (lambda (c) (string= "session/create" (car c)))
                        calls))
               (params (and create (cadr create))))
          (when (and (string= "w-created2" (cdr (assq 'workspaceId (cdr (assq 'request params)))))
                     (null (assq 'cwd (cdr (assq 'request params)))))
            (dsh-test-pass
             "new-session-creates-project-workspace-on-first-use"))))
    (setq dsh-emacs--sessions old-sessions)
    (setq dsh-emacs--workspaces old-ws)
    (delete-directory root t)
    (when (buffer-live-p buf) (kill-buffer buf))))

;; end-to-end: project workspace creation fails
;; -> fall back to cwd (plain semantics)
(let* ((old-sessions dsh-emacs--sessions)
       (old-ws dsh-emacs--workspaces)
       (root (directory-file-name (make-temp-file "dsh-e2e-" t)))
       (calls nil)
       (buf (generate-new-buffer " *dsh-project-create3*")))
  (unwind-protect
      (with-current-buffer buf
        (insert "plain text\n")
        (goto-char (point-min))
        (setq dsh-emacs--workspaces nil)
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (method params cb)
                     (push (list method params) calls)
                     (funcall cb t '((sessionId . "s-proj3")))))
                  ((symbol-function 'dsh-emacs-open-session)
                   (lambda (_sid) nil))
                  ((symbol-function 'dsh-emacs--project-root)
                   (lambda (_dir) root))
                  ((symbol-function 'dsh-emacs--server-local-host-p)
                   (lambda () t))
                  ((symbol-function 'dsh-emacs--rpc-request)
                   (lambda (&rest _) (cons nil "create-failed"))))
          (call-interactively #'dsh-emacs-new-session))
        (let* ((create (cl-find-if
                        (lambda (c) (string= "session/create" (car c)))
                        calls))
               (params (and create (cadr create))))
          (when (and create
                     (null (assq 'workspaceId (cdr (assq 'request params))))
                     (assq 'cwd (cdr (assq 'request params))))
            (dsh-test-pass "new-session-project-create-failure-keeps-cwd"))))
    (setq dsh-emacs--sessions old-sessions)
    (setq dsh-emacs--workspaces old-ws)
    (delete-directory root t)
    (when (buffer-live-p buf) (kill-buffer buf))))

;; --- Test 80c: a new session's CWD follows the current buffer's
;; default-directory ---
;; When `dsh-emacs-new-session' is called from a dired/magit buffer and the
;; like, the working directory of the new session must be the current
;; buffer's default-directory (dired's browsed directory, magit's repo root,
;; the file's directory) -- both project detection and workspace/create are
;; based on it. Regression: it used to always take `dsh-emacs-default-cwd'
;; (a fixed value from load time, typically unset by users), so sessions
;; landed in the startup directory, the browsed project never entered
;; detection, and there was naturally no workspace. (The project-root mock
;; only passes dir through + normalizes: it pins the "dir delivered from the
;; buffer directory" link; the detection chain itself is covered by test 80b
;; and real probing.)
(let* ((proj (directory-file-name (make-temp-file "dsh-dired-proj-" t)))
       (flat (directory-file-name (make-temp-file "dsh-dired-flat-" t)))
       (old-ws dsh-emacs--workspaces)
       (old-sessions dsh-emacs--sessions)
       (calls nil)
       (created nil)
       (buf (generate-new-buffer " *dsh-dired-create*")))
  (unwind-protect
      (with-current-buffer buf
        (insert "dired listing\n")
        (goto-char (point-min))
        (setq-local default-directory (file-name-as-directory proj))
        (let ((dsh-emacs--workspaces nil)     ; no proj in cache -> take the creation path
              (dsh-emacs-default-cwd flat))   ; old code wrongly took this one
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method params cb)
                       (push (list method params) calls)
                       (funcall cb t '((sessionId . "s-dired")))))
                    ((symbol-function 'dsh-emacs-open-session)
                     (lambda (_sid) nil))
                    ((symbol-function 'dsh-emacs--server-local-host-p)
                     (lambda () t))
                    ((symbol-function 'dsh-emacs--project-root)
                     (lambda (dir)
                       ;; the real implementation normalizes
                       ;; (directory-file-name); dired's
                       ;; default-directory has a trailing slash;
                       ;; the mock keeps the same contract.
                       (directory-file-name (expand-file-name dir))))
                    ((symbol-function 'dsh-emacs--rpc-request)
                     (lambda (_method params)
                       (setq created params)
                       (cons t (list (cons 'workspace
                                           (list (cons 'workspaceId "w-dired")
                                                 (cons 'path proj)
                                                 (cons 'sessionIds []))))))))
            (call-interactively #'dsh-emacs-new-session)
            (let* ((create (cl-find-if
                            (lambda (c) (string= "session/create" (car c)))
                            calls))
                   (params (and create (cadr create))))
              (dsh-test-assert
               "new-session-cwd-follows-buffer-default-directory"
               (and created
                    (equal (cdr (assq 'path (cdr (assq 'request created))))
                           proj)))
              (dsh-test-assert
               "new-session-buffer-dir-workspace-used"
               (and create
                    (string= "w-dired" (cdr (assq 'workspaceId (cdr (assq 'request params)))))
                    (null (assq 'cwd (cdr (assq 'request params))))))))))
    (setq dsh-emacs--sessions old-sessions)
    (setq dsh-emacs--workspaces old-ws)
    (delete-directory proj t)
    (delete-directory flat t)
    (when (buffer-live-p buf) (kill-buffer buf))))

;; --- Test 80d: absolute-cwd precedence ---
;; cwd argument > current buffer default-directory > `dsh-emacs-default-cwd'.
(let ((flat (directory-file-name (make-temp-file "dsh-cwd-flat-" t))))
  (unwind-protect
      (dsh-test-assert
       "absolute-cwd-precedence"
       (let ((default-directory (concat flat "/buf/"))
             (dsh-emacs-default-cwd (concat flat "/cfg/")))
         (equal (expand-file-name (concat flat "/x/"))
                (dsh-emacs--absolute-cwd (concat flat "/x/")))
         (equal (expand-file-name (concat flat "/buf/"))
                (dsh-emacs--absolute-cwd nil)))
       (let ((default-directory nil)
             (dsh-emacs-default-cwd (concat flat "/cfg/")))
         (equal (expand-file-name (concat flat "/cfg/"))
                (dsh-emacs--absolute-cwd nil))))
    (delete-directory flat t)))


;; --- Test 81: user questions (user-questions/request) minibuffer selection
;; and answers ---
;; dsh's `ask' tool pushes a waterfall over the core connection's `$events'
;; stream (event name user-questions/request, with the host-dispatched
;; eventId + agentId + request.questions): each frame asks each question one
;; at a time in the minibuffer -- options are completion candidates (single
;; select one / multiple select several), with "Type answer..." appended for
;; custom text; once all are answered, a unary endpoint POST
;; /api/$events/result returns the outcome (value = {answers: ...}, clientId
;; from the $events ready, eventId echoing the waterfall). selected is always
;; an array ([] when custom-only), and label comparison uses equal. The
;; minibuffer is a single global resource: when several sessions ask at once,
;; frames go into a FIFO queue and are answered serially, with the prompt
;; carrying the owning session's identifier.

;; 1) $events/result answer envelope: a unary client-request, method
;; $events/result,
;; payload args {clientId, eventId, outcome:{kind:result, value:{answers}}}
(cl-letf (((symbol-function 'dsh-emacs--rpc-async)
           (lambda (method params cb)
             (dsh-test-assert "events-result-wire-envelope"
               (string= "$events/result" method)
               (let ((outcome (cdr (assq 'outcome params))))
                 (and (equal "c1" (cdr (assq 'clientId params)))
                      (equal "wf-1" (cdr (assq 'eventId params)))
                      (equal "result" (cdr (assq 'kind outcome)))
                      (equal '((answers . (((id . "q1")
                                            (selected "Yes")))))
                             (cdr (assq 'value outcome))))))
             (funcall cb t nil))))
  (dsh-emacs--events-result-async
   "c1" "wf-1"
   '((kind . "result")
     (value . ((answers . (((id . "q1") (selected "Yes")))))))
   (lambda (&rest _) nil)))

;; the question protocol preserves the description text
;; and the raw option labels,
;; and treats only JSON true as multiple select.
(let* ((wire '((id . "q-details") (question . "Which routes?")
               (header . "Routes") (detail . "Choose every required route.")
               (options . [((label . "A,B") (description . "Comma label."))
                           ((label . "C"))])
               (multiSelect . t)))
       (question (dsh-protocol-question--from-alist wire)))
  (dsh-test-assert "question-protocol-keeps-details-and-option-order"
    (equal "q-details" (dsh-protocol-question-id question))
    (equal "Which routes?" (dsh-protocol-question-text question))
    (equal "Routes" (dsh-protocol-question-header question))
    (equal "Choose every required route."
           (dsh-protocol-question-detail question))
    (listp (dsh-protocol-question-options question))
    (equal '("A,B" "C")
           (mapcar #'dsh-protocol-question-option-label
                   (dsh-protocol-question-options question)))
    (equal "Comma label."
           (dsh-protocol-question-option-description
            (car (dsh-protocol-question-options question))))
    (null (dsh-protocol-question-option-description
           (cadr (dsh-protocol-question-options question))))
    (dsh-protocol-question-multi-select question)
    (eq question (dsh-protocol--struct #'dsh-protocol-question-p
                                     #'dsh-protocol-question--from-alist
                                     question)))
  (dolist (false-value '(nil :json-false))
    (dsh-test-assert (format "question-protocol-single-for-%s" false-value)
      (not (dsh-protocol-question-multi-select
            (dsh-protocol-question--from-alist
             `((multiSelect . ,false-value))))))))

;; The ask tool's own arguments spell the flag `multi_select' where the ask
;; request spells it `multiSelect'; both decode to the same struct.
(dsh-test-assert "question-protocol-decodes-tool-argument-spelling"
  (dsh-protocol-question-multi-select
   (dsh-protocol-question--from-alist '((id . "q") (multi_select . t))))
  (not (dsh-protocol-question-multi-select
        (dsh-protocol-question--from-alist
         '((id . "q") (multi_select . :json-false))))))

;; A malformed option element declines at the wire boundary instead of
;; signalling out of the constructor's `assq'.
(dsh-test-assert "question-protocol-drops-malformed-option-elements"
  (equal '("Stacked")
         (mapcar #'dsh-protocol-question-option-label
                 (dsh-protocol-question-options
                  (dsh-protocol-question--from-alist
                   '((id . "q") (question . "Which?")
                     (options . ["oops" ((label . "Stacked")) 42])))))))

;; session identifier: prefer the active chat buffer's name; with no buffer
;; fall back to dsh: <id>, truncated; empty when there is no session-id (a
;; direct call in a test adds no prefix)
(let ((buf (get-buffer-create " *dsh-test-label-buf*")))
  (unwind-protect
      (progn
        (when (equal " *dsh-test-label-buf*"
                     (let ((dsh-emacs--chat-buffers
                            (make-hash-table :test 'equal)))
                       (puthash "sess-l" buf dsh-emacs--chat-buffers)
                       (dsh-emacs--question-session-label "sess-l")))
          (dsh-test-pass "question-session-label-uses-chat-buffer-name"))
        (when (equal (concat "dsh: " (make-string 32 ?x) "…")
                     (let ((dsh-emacs--chat-buffers
                            (make-hash-table :test 'equal))
                           (dsh-emacs--sessions nil))
                       (dsh-emacs--question-session-label
                        (make-string 50 ?x))))
          (dsh-test-pass "question-session-label-truncates-long"))
        (when (equal ""
                     (let ((dsh-emacs--chat-buffers
                            (make-hash-table :test 'equal)))
                       (dsh-emacs--question-session-label nil)))
          (dsh-test-pass "question-session-label-nil-id-empty")))
    (when (buffer-live-p buf) (kill-buffer buf))))

;; candidates: numbered from 1, all of them the options themselves (no extra
;; "type an answer" sentinel -- typing text directly is the answer). The
;; number belongs to the option, so a comma-separated answer may use either
;; numbers or labels.
(dsh-test-assert "question-candidates-are-numbered-options"
  (equal '("1. Yes" "2. No")
         (dsh-emacs--question-pick-labels '("Yes" "No"))))

;; answer values may be numeric candidates, bare labels,
;; or labels that already carry a numeric prefix;
;; all must be restored to the original label.
(let ((labels '("Yes" "2. Version" "[x] Literal" "A,B")))
  (dsh-test-assert "question-label-of-accepts-number-or-label"
    (equal "Yes" (dsh-emacs--question-label-of "1. Yes" labels))
    (equal "Yes" (dsh-emacs--question-label-of "Yes" labels))
    (equal "2. Version" (dsh-emacs--question-label-of "2. 2. Version" labels))
    (equal "2. Version" (dsh-emacs--question-label-of "2. Version" labels))
    (equal "[x] Literal" (dsh-emacs--question-label-of "3. [x] Literal" labels))
    (equal "A,B" (dsh-emacs--question-label-of "4. A,B" labels))
    ;; CRM may hand back unexpanded elements
    ;; (the bare number "2") -> resolve by position
    (equal "Yes" (dsh-emacs--question-label-of "1" labels))
    (equal "2. Version" (dsh-emacs--question-label-of "2" labels))
    (equal "[x] Literal" (dsh-emacs--question-label-of "3" labels))
    (null (dsh-emacs--question-label-of "0" labels))
    (null (dsh-emacs--question-label-of "9" labels))
    (null (dsh-emacs--question-label-of "9. Nope" labels))
    (null (dsh-emacs--question-label-of "Nope" labels))))

;; unexpanded prefix: parse only when it is uniquely decidable
;; (case-insensitive); an ambiguous prefix stays literal.
(dsh-test-assert "question-label-of-resolves-unambiguous-prefix"
  (equal "Alpha" (dsh-emacs--question-label-of "alph" '("Alpha" "Beta" "Gamma")))
  (equal "Alpha" (dsh-emacs--question-label-of "ALPH" '("Alpha" "Beta" "Gamma")))
  (equal "Beta" (dsh-emacs--question-label-of "be" '("Alpha" "Beta" "Gamma")))
  ;; ambiguous (Alpha / Alphabet) is not parsed -- better literal than mismatched
  (null (dsh-emacs--question-label-of "A" '("Alpha" "Alphabet")))
  (null (dsh-emacs--question-label-of "Al" '("Alpha" "Alphabet")))
  ;; exact match takes precedence over prefix
  (equal "Alpha" (dsh-emacs--question-label-of "Alpha" '("Alpha" "Alphabet")))
  ;; a bare number resolves to the "numbered candidate",
  ;; even when the label itself starts with a digit
  (equal "2" (dsh-emacs--question-label-of "1" '("2" "Version")))
  (equal "2" (dsh-emacs--question-label-of "2" '("2" "Version")))
  (equal "Version" (dsh-emacs--question-label-of "2" '("Alpha" "Version")))
  (equal "x" (dsh-emacs--question-label-of "10" (make-list 10 "x")))
  (null (dsh-emacs--question-label-of "0" '("Alpha" "Beta"))))

;; each candidate's description travels with the candidate
;; (annotation), no longer a tooltip that follows the highlight.
(let* ((dsh-emacs--question-current
        (dsh-protocol-question--from-alist
         '((id . "ann") (question . "Choose?")
           (options . [((label . "Alpha") (description . "Safe route."))
                       ((label . "Beta"))]))))
       (dsh-emacs--question-options
        (dsh-protocol-question-options dsh-emacs--question-current))
       (dsh-emacs--question-roster '("Alpha" "Beta")))
  (dsh-test-assert "question-annotation-carries-description"
    (equal "  Safe route." (dsh-emacs--question-annotation "1. Alpha"))
    (equal "  Safe route." (dsh-emacs--question-annotation "Alpha"))
    (equal "" (dsh-emacs--question-annotation "2. Beta"))
    (equal "" (dsh-emacs--question-annotation "something else"))
    ;; The suffix carries a face of its own: a frontend adds
    ;; `completions-annotations' only to an annotation that has none.
    (eq 'dsh-emacs-meta-face
        (get-text-property 0 'face (dsh-emacs--question-annotation "Alpha")))))

;; single select: likewise one read (CRM takes only one value),
;; numeric candidate -> original label.
(let ((reads '(("1. Yes"))))
  (cl-letf (((symbol-function 'completing-read-multiple)
             (lambda (&rest _) (or (pop reads) (error "Unexpected read")))))
    (dsh-test-assert "question-choice-single-label"
      (equal '((id . "q1") (selected "Yes"))
             (dsh-emacs--question-choice
              '((id . "q1") (question . "Proceed?")
                (options . (((label . "Yes")) ((label . "No"))))))))))

;; multiple select: the whole answer is read in one go; answers come back in
;; **the question's option order**, not input order (type 2 then 1 and A is
;; still first). Elements may be either a completed candidate or a bare
;; number CRM left unexpanded.
(let ((reads '(("3. Gamma" "1"))))
  (cl-letf (((symbol-function 'completing-read-multiple)
             (lambda (&rest _) (or (pop reads) (error "Unexpected read")))))
    (dsh-test-assert "question-choice-multi-follows-option-order"
      (equal '((id . "q2") (selected "Alpha" "Gamma"))
             (dsh-emacs--question-choice
              '((id . "q2") (question . "Pick?") (multiSelect . t)
                (options . (((label . "Alpha")) ((label . "Beta"))
                            ((label . "Gamma"))))))))))

;; empty input = skip that question; skipping does not depend on any candidate.
(let ((reads '(nil)))
  (cl-letf (((symbol-function 'completing-read-multiple)
             (lambda (&rest _) (pop reads))))
    (dsh-test-assert "question-choice-multi-empty-input-skips"
      (equal '((id . "q3") (selected . []))
             (dsh-emacs--question-choice
              '((id . "q3") (question . "Pick?") (multiSelect . t)
                (options . (((label . "A")) ((label . "B"))))))))))

;; no "type an answer" candidate: typing text directly is the answer, same
;; for multiple and single select, and there is only one read (no more
;; "choose Type answer... then read again" -- reads are taken only once).
(let ((served 0))
  (cl-letf (((symbol-function 'completing-read-multiple)
             (lambda (&rest _) (cl-incf served) '("my own note"))))
    (dsh-test-assert "question-choice-typed-text-is-the-answer"
      (equal '((id . "q4") (selected . []) (custom . "my own note"))
             (dsh-emacs--question-choice
              '((id . "q4") (question . "Pick?") (multiSelect . t)
                (options . (((label . "A")) ((label . "B")))))))
      (equal '((id . "q5") (selected . []) (custom . "my own note"))
             (dsh-emacs--question-choice
              '((id . "q5") (question . "Proceed?")
                (options . (((label . "Yes")) ((label . "No")))))))
      (= 2 served))))

;; partly parseable, partly not -> treat the whole input as text: never keep
;; only the parseable part and silently drop the rest (e.g. typing 2,3 when
;; only two options remain).
(dsh-test-assert "question-choice-partially-matched-input-stays-text"
  (equal '((id . "q6a") (selected . []) (custom . "2, 3"))
         (cl-letf (((symbol-function 'completing-read-multiple)
                    (lambda (&rest _) '("2" "3"))))
           (dsh-emacs--question-choice
            '((id . "q6a") (question . "Pick?") (multiSelect . t)
              (options . (((label . "Alpha")) ((label . "Beta"))))))))
  (equal '((id . "q6b") (selected . []) (custom . "1, nonsense"))
         (cl-letf (((symbol-function 'completing-read-multiple)
                    (lambda (&rest _) '("1" "nonsense"))))
           (dsh-emacs--question-choice
            '((id . "q6b") (question . "Pick?") (multiSelect . t)
              (options . (((label . "Alpha")) ((label . "Beta")))))))))

;; cannot recall the options, just type text -> that text is the answer (the
;; Emacs completion convention), rather than an error or a silent drop.
(dsh-test-assert "question-choice-unmatched-input-is-free-text"
  (equal '((id . "q6") (selected . []) (custom . "just do it"))
         (cl-letf (((symbol-function 'completing-read-multiple)
                    (lambda (&rest _) (list "just do it"))))
           (dsh-emacs--question-choice
            '((id . "q6") (question . "Pick?") (multiSelect . t)
              (options . (((label . "A")) ((label . "B"))))))))
  (equal '((id . "q6b") (selected . []) (custom . "one, two"))
         (cl-letf (((symbol-function 'completing-read-multiple)
                    (lambda (&rest _) (list "one" "two"))))
           (dsh-emacs--question-choice
            '((id . "q6b") (question . "Pick?") (multiSelect . t)
              (options . (((label . "A")) ((label . "B")))))))))

;; No-option questions are still free text: empty input = skip, non-empty = custom.
(let ((customs '("free text" "")))
  (cl-letf (((symbol-function 'read-string)
             (lambda (&rest _) (pop customs))))
    (dsh-test-assert "question-choice-no-options-custom"
      (equal '((id . "q7") (selected . []) (custom . "free text"))
             (dsh-emacs--question-choice
              '((id . "q7") (question . "Say?")))))
    (dsh-test-assert "question-choice-no-options-empty-skips"
      (equal '((id . "q7") (selected . []))
             (dsh-emacs--question-choice
              '((id . "q7") (question . "Say?")))))))

;; The Skip command hands the action straight back to the reader (triggered by
;; dsh-emacs-question-skip-key).
(dsh-test-assert "question-skip-command-returns-skip-action"
  (equal "Skip this question"
         (catch 'dsh-emacs--question-command
           (dsh-emacs--question-skip-command))))

;; reader-local keymap: default C-c C-s -> skip (a bare letter cannot be used, or
;; that letter could not be typed in the answer); rebinding takes effect; bare
;; letters stay typeable.
(with-temp-buffer
  (use-local-map (make-sparse-keymap))
  (use-local-map (dsh-emacs--question-reader-keymap))
  (dsh-test-assert "question-reader-binds-default-skip-key"
    (eq (lookup-key (current-local-map) (kbd "C-c C-s"))
        'dsh-emacs--question-skip-command)
    (null (lookup-key (current-local-map) (kbd "s")))
    (null (lookup-key (current-local-map) (kbd "t")))))

(let ((dsh-emacs-question-skip-key "C-c s"))
  (with-temp-buffer
    (use-local-map (make-sparse-keymap))
    (use-local-map (dsh-emacs--question-reader-keymap))
    (dsh-test-assert "question-reader-honors-rebound-skip-key"
      (eq (lookup-key (current-local-map) (kbd "C-c s"))
          'dsh-emacs--question-skip-command)
      (null (lookup-key (current-local-map) (kbd "C-c C-s"))))))

(let ((dsh-emacs-question-skip-key nil))
  (with-temp-buffer
    (use-local-map (make-sparse-keymap))
    (dsh-test-assert "question-reader-skip-key-can-be-disabled"
      ;; lookup-key on an unbound prefix key returns the sentinel 1, not nil
      (not (eq (lookup-key (dsh-emacs--question-reader-keymap)
                           (kbd "C-c C-s"))
               'dsh-emacs--question-skip-command)))))

;; reader setup: candidate annotations + question detail into the echo area (both
;; scoped to this minibuffer).
(let* ((dsh-emacs--question-current
        (dsh-protocol-question--from-alist
         '((id . "q8") (question . "Proceed?") (detail . "Context here")
           (options . [((label . "Yes") (description . "Go ahead"))
                       ((label . "No"))]))))
       (dsh-emacs--question-options
        (dsh-protocol-question-options dsh-emacs--question-current))
       (dsh-emacs--question-roster '("Yes" "No"))
       (echoed nil))
  (cl-letf (((symbol-function 'message)
             (lambda (fmt &rest args) (setq echoed (apply #'format fmt args)))))
    (with-temp-buffer
      (use-local-map (make-sparse-keymap))
      (dsh-emacs--question-reader-setup)
      (let ((annotation (plist-get completion-extra-properties
                                   :annotation-function)))
        (dsh-test-assert "question-reader-setup-annotations-and-echo"
          (equal "  Go ahead" (funcall annotation "1. Yes"))
          (equal "  Go ahead" (funcall annotation "Yes"))
          (equal "" (funcall annotation "2. No"))
          (equal "Context here" echoed))))))

;; the reader must preselect prompt, not the first item: a frontend preselecting the
;; first item inserts it into the input box, turning "empty input = skip" into
;; "accept the first item" (vertico-measured).
(let ((vertico-preselect 'first))
  (with-temp-buffer
    (use-local-map (make-sparse-keymap))
    (cl-letf (((symbol-function 'dsh-emacs--question-echo) #'ignore))
      (dsh-emacs--question-reader-setup))
    (dsh-test-assert "question-reader-preselects-the-prompt"
      (eq 'prompt vertico-preselect))))

;; The multi-select prompt carries a separator hint.
(let ((prompt nil))
  (cl-letf (((symbol-function 'completing-read-multiple)
             (lambda (p &rest _) (setq prompt p) '("1. Yes"))))
    (dsh-emacs--question-choice
     '((id . "q8b") (question . "Proceed?") (multiSelect . t)
       (options . (((label . "Yes") (description . "Go ahead"))
                   ((label . "No"))))))
    (dsh-test-assert "question-reader-multi-prompt-hint"
      (equal "Proceed? (2,3 or names, or your own text; empty = skip): "
             prompt))))

;; Single select also explains the meaning of empty input in the prompt.
(let ((prompt nil))
  (cl-letf (((symbol-function 'completing-read-multiple)
             (lambda (p &rest _) (setq prompt p) '("1. Yes"))))
    (dsh-emacs--question-choice
     '((id . "q9") (question . "Proceed?")
       (options . (((label . "Yes")) ((label . "No"))))))
    (dsh-test-assert "question-reader-single-prompt-hint"
      (equal "Proceed? (a name or your own text; empty = skip): "
             prompt))))

;; candidate order = the question's original option order: for numbered options
;; ("1. ...") the number is the order, and the completion frontend must not reorder.
;; Only an identity `display-sort-function'/`cycle-sort-function' on the collection
;; makes that possible -- otherwise vertico reorders by history/length/alphabet by
;; default (and across several questions the list order of the same question batch
;; even differs). CRM passes this metadata through `crm-completion-table' to the
;; frontend's collection (`crm--collection-fn'), so assertions must go through it
;; to cover the table the frontend actually sees.
(let ((seen 'unset))
  (cl-letf (((symbol-function 'completing-read-multiple)
             (lambda (_prompt collection &rest _)
               (setq seen collection)
               '("2. Alpha"))))
    (dsh-emacs--question-choice
     '((id . "q-order") (question . "Pick?") (multiSelect . t)
       (options . (((label . "Zulu")) ((label . "Alpha"))
                   ((label . "Mike"))))))
    (let* ((crm-completion-table seen)
           (metadata (completion-metadata "" #'crm--collection-fn nil)))
      (dsh-test-assert "question-reader-pins-option-order"
        (eq #'identity
            (completion-metadata-get metadata 'display-sort-function))
        (eq #'identity
            (completion-metadata-get metadata 'cycle-sort-function))
        (equal '("1. Zulu" "2. Alpha" "3. Mike")
               (all-completions "" #'crm--collection-fn nil))))))

;; The preview command demos a whole batch of questions (multi-select + single
;; select + no-option): each question goes through the same reader, answers are
;; collected in frame order, then echoed as a whole (local demo, no RPC).
(let ((option-reads 0)
      (echoed 'unset))
  (cl-letf (((symbol-function 'completing-read-multiple)
             (lambda (_prompt collection &rest _)
               (setq option-reads (1+ option-reads))
               (list (car (all-completions "" collection)))))
            ((symbol-function 'read-string)
             (lambda (&rest _) "my own addition"))
            ;; Capture only the preview's summary line: reader echo/cleanup also use
            ;; `message'.
            ((symbol-function 'message)
             (lambda (fmt &rest args)
               (when (equal fmt "Preview answers: %S")
                 (setq echoed (car args))))))
    (dsh-emacs-question-preview)
    (dsh-test-assert "question-preview-batch-covers-every-shape"
      (= 2 option-reads)
      (equal '("preview-1" "preview-2" "preview-3")
             (mapcar (lambda (answer) (cdr (assq 'id answer))) echoed))
      (equal '("UI")
             (cdr (assq 'selected (nth 0 echoed))))
      (equal "Run scripts/verify.sh"
             (cadr (assq 'selected (nth 1 echoed))))
      (equal "my own addition" (cdr (assq 'custom (nth 2 echoed)))))))

;; Frame level: one question answered + one skipped -> answers cover the frame
;; (the skipped question has an empty selected).
(let ((picks '(("1. Yes") nil)))
  (cl-letf (((symbol-function 'completing-read-multiple)
             (lambda (&rest _) (pop picks))))
    (dsh-test-assert "question-skip-covers-frame-with-empty-selected"
      (equal '(((id . "qa") (selected "Yes"))
               ((id . "qb") (selected . [])))
             (dsh-emacs--collect-question-answers
              '(((id . "qa") (question . "A?") (multiSelect . t)
                 (options . (((label . "Yes")))))
                ((id . "qb") (question . "B?") (multiSelect . t)
                 (options . (((label . "Only")))))))))))

;; 3b) frame dispatch: waterfall frame (user-questions/request) -> minibuffer answer
;; (no card rendered). Via `dsh-emacs-events--host-item' it goes through the full
;; `$events' dispatch surface: the host hands the waterfall with agentId to this
;; client, the events layer resolves the active chat buffer by agentId in
;; `dsh-emacs--chat-buffers' and then calls `dsh-emacs--question-requested'; the
;; answer goes back as a unary $events/result outcome (value = {answers: ...}, echoing
;; the eventId).
(let* ((chat (get-buffer-create " *dsh-test-question*"))
       (responds nil))
  (unwind-protect
      (let ((dsh-emacs--chat-buffers (make-hash-table :test 'equal))
            (dsh-emacs-events--client-id "c1")
            (dsh-emacs-enable-notifications nil))
        (puthash "sess-q" chat dsh-emacs--chat-buffers)
        (with-current-buffer chat
          (setq-local dsh-emacs--buffer-session "sess-q"))
        (cl-letf (((symbol-function 'dsh-emacs--events-result-async)
                   (lambda (client-id event-id outcome cb)
                     (push (list client-id event-id outcome) responds)
                     (funcall cb t nil)))
                  ((symbol-function 'completing-read-multiple)
                   (lambda (&rest _) '("Yes"))))
          (dsh-emacs-events--host-item
           'process
           '((type . "waterfall")
             (event . "user-questions/request")
             (eventId . "rpc-q")
             (agentId . "sess-q")
             (request . ((questions .
                          (((id . "q1") (question . "Proceed?")
                            (options . (((label . "Yes"))
                                        ((label . "No")))))))))))
          (let ((r (car responds)))
            (when (and (equal "c1" (nth 0 r))
                       (equal "rpc-q" (nth 1 r))
                       (equal '((kind . "result")
                                (value . ((answers .
                                           (((id . "q1")
                                             (selected "Yes")))))))
                              (nth 2 r)))
              (dsh-test-pass "question-frame-answers-with-result-outcome")))
          ;; No tab is inserted any more: after the answer the buffer has no question card
          (let ((text (with-current-buffer chat (buffer-string))))
            (when (not (string-match-p "❓ Question" text))
              (dsh-test-pass "question-frame-inserts-no-card")))))
    (when (buffer-live-p chat) (kill-buffer chat))))

;; 4) multi-question frame: sequential per-question minibuffer selection, only one
;; $events/result outcome sent after all answers
(let* ((chat (get-buffer-create " *dsh-test-question-multi*"))
       (responds nil)
       (queue '("1. Yes" "1. X")))
  (unwind-protect
      (let ((dsh-emacs--chat-buffers (make-hash-table :test 'equal))
            (dsh-emacs-events--client-id "c1")
            (dsh-emacs-enable-notifications nil))
        (puthash "sess-m" chat dsh-emacs--chat-buffers)
        (with-current-buffer chat
          (setq-local dsh-emacs--buffer-session "sess-m"))
        (cl-letf (((symbol-function 'dsh-emacs--events-result-async)
                   (lambda (client-id event-id outcome cb)
                     (push (list client-id event-id outcome) responds)
                     (funcall cb t nil)))
                  ((symbol-function 'completing-read-multiple)
                   (lambda (&rest _)
                     (let ((row (pop queue)))
                       (and row (list row))))))
          (dsh-emacs-events--host-item
           'process
           '((type . "waterfall")
             (event . "user-questions/request")
             (eventId . "rpc-m")
             (agentId . "sess-m")
             (request . ((questions .
                          (((id . "q1") (question . "One?")
                            (options . (((label . "Yes")) ((label . "No")))))
                           ((id . "q2") (question . "Two?")
                            (multiSelect . t)
                            (options . (((label . "X")) ((label . "Y")))))))))))
          (let ((r (car responds)))
            (dsh-test-assert "question-multi-answers-in-one-result"
              (= 1 (length responds))
              (equal "c1" (nth 0 r))
              (equal "rpc-m" (nth 1 r))
              (equal '((kind . "result")
                       (value . ((answers .
                                  (((id . "q1") (selected "Yes"))
                                   ((id . "q2") (selected "X")))))))
                     (nth 2 r))))
          ;; Still no card is inserted (pure minibuffer answering)
          (let ((text (with-current-buffer chat (buffer-string))))
            (when (not (string-match-p "❓ Question" text))
              (dsh-test-pass "question-multi-inserts-no-card")))))
    (when (buffer-live-p chat) (kill-buffer chat))))

;; 5) frame dispatch: C-g/ESC -> abandon the whole question group: answered with
;; outcome kind `rejected' + error body (name/message = the kept cancelled intent,
;; the same signal as dsh web's abandon); the host withdraws that ask as cancelled.
;; Regression: the old code never answered, the host stayed pending,
;; and the agent turn hung forever.
(let* ((chat (get-buffer-create " *dsh-test-question-cg*"))
       (responds nil))
  (unwind-protect
      (let ((dsh-emacs--chat-buffers (make-hash-table :test 'equal))
            (dsh-emacs-events--client-id "c1")
            (dsh-emacs-enable-notifications nil))
        (puthash "sess-qc" chat dsh-emacs--chat-buffers)
        (with-current-buffer chat
          (setq-local dsh-emacs--buffer-session "sess-qc"))
        (cl-letf (((symbol-function 'dsh-emacs--events-result-async)
                   (lambda (client-id event-id outcome cb)
                     (push (list client-id event-id outcome) responds)
                     (funcall cb t nil)))
                  ((symbol-function 'completing-read-multiple)
                   (lambda (&rest _) (signal 'quit nil))))
          (dsh-emacs-events--host-item
           'process
           '((type . "waterfall")
             (event . "user-questions/request")
             (eventId . "rpc-qc")
             (agentId . "sess-qc")
             (request . ((questions .
                          (((id . "q1") (question . "Proceed?")
                            (options . (((label . "Yes")))))))))))
          (dsh-test-assert "question-frame-c-g-declines-waterfall"
            (equal (list (list "c1" "rpc-qc"
                               '((kind . "rejected")
                                 (error . ((name . "cancelled")
                                           (message . "User abandoned the questions"))))))
                   responds))))
    (when (buffer-live-p chat) (kill-buffer chat))))

;; 6) frame dispatch: must answer while history is loading too (pending questions
;; replayed by the mux arrive when opened)
(let* ((chat (get-buffer-create " *dsh-test-question-load*"))
       (responds nil))
  (unwind-protect
      (let ((dsh-emacs--chat-buffers (make-hash-table :test 'equal))
            (dsh-emacs-events--client-id "c1")
            (dsh-emacs-enable-notifications nil))
        (puthash "sess-ql" chat dsh-emacs--chat-buffers)
        (with-current-buffer chat
          (setq-local dsh-emacs--buffer-session "sess-ql")
          (setq-local dsh-emacs--event-history-loading t))
        (cl-letf (((symbol-function 'dsh-emacs--events-result-async)
                   (lambda (_client-id event-id _outcome cb)
                     (push event-id responds)
                     (funcall cb t nil)))
                  ((symbol-function 'completing-read-multiple)
                   (lambda (&rest _) '("Yes"))))
          (dsh-emacs-events--host-item
           'process
           '((type . "waterfall")
             (event . "user-questions/request")
             (eventId . "rpc-ql")
             (agentId . "sess-ql")
             (request . ((questions .
                          (((id . "q1") (question . "Proceed?")
                            (options . (((label . "Yes")))))))))))
          (when (equal '("rpc-ql") responds)
            (dsh-test-pass "question-frame-during-history-load-answered"))))
    (when (buffer-live-p chat) (kill-buffer chat))))

;; 7) waterfall for a session with no open chat buffer (foreign / other client) ->
;; this client does not answer and does not prompt; the events layer just hands it to
;; the next taker (outcome kind `next'). Retirement semantics now live in the
;; `$events' cancel frame (see tests 10 and 78e).
(let* ((chat (get-buffer-create " *dsh-test-question-other*"))
       (responds nil)
       (prompted nil))
  (unwind-protect
      (let ((dsh-emacs--chat-buffers (make-hash-table :test 'equal))
            (dsh-emacs-events--client-id "c1")
            (dsh-emacs-enable-notifications nil))
        ;; Register only this client's session "mine"; the foreign session is absent (no
        ;; active chat buffer)
        (puthash "mine" chat dsh-emacs--chat-buffers)
        (with-current-buffer chat
          (setq-local dsh-emacs--buffer-session "mine"))
        (cl-letf (((symbol-function 'dsh-emacs--events-result-async)
                   (lambda (client-id event-id outcome cb)
                     (push (list client-id event-id outcome) responds)
                     (funcall cb t nil)))
                  ((symbol-function 'completing-read-multiple)
                   (lambda (&rest _) (setq prompted t) '("Yes")))
                  ((symbol-function 'dsh-emacs--approval-prompt)
                   (lambda (&rest _) (setq prompted t) t)))
          ;; Question waterfall for an unopened session -> handed to next taker, no prompt
          (dsh-emacs-events--host-item
           'process
           '((type . "waterfall")
             (event . "user-questions/request")
             (eventId . "rpc-o")
             (agentId . "other-session")
             (request . ((questions .
                          (((id . "q1") (question . "Proceed?")
                            (options . (((label . "Yes")))))))))))
          ;; Approval waterfall for an unopened session -> likewise next, no prompt
          (dsh-emacs-events--host-item
           'process
           '((type . "waterfall")
             (event . "approval/request")
             (eventId . "rpc-ao")
             (agentId . "other-session")
             (request . ((toolName . "fs") (reason . "outside")))))
          (dsh-test-assert "foreign-no-chat-waterfalls-handed-on"
            (null prompted)
            (= 2 (length responds))
            (cl-every (lambda (r)
                        (and (equal "c1" (nth 0 r))
                             (equal '((kind . "next")) (nth 2 r))))
                      responds)
            (equal '("rpc-ao" "rpc-o")
                   (mapcar (lambda (r) (nth 1 r)) responds)))))
    (when (buffer-live-p chat) (kill-buffer chat))))

;; 8) concurrent questions from several sessions: the minibuffer is one global resource,
;; so frames from other sessions arriving mid-answer must queue
;; (FIFO) and be answered serially, and the prompt must carry the owning session
;; identifier
(let* ((chat-a (get-buffer-create " *dsh-test-question-a*"))
       (chat-b (get-buffer-create " *dsh-test-question-b*"))
       (responds nil)
       (prompts nil)
       (b-pushed nil))
  (unwind-protect
      (let ((dsh-emacs--sessions nil)
            (dsh-emacs--chat-buffers (make-hash-table :test 'equal))
            (dsh-emacs-enable-notifications nil))
        (setq dsh-emacs--question-queue nil
              dsh-emacs--question-active nil)
        (with-current-buffer chat-a
          (setq-local dsh-emacs--buffer-session "sess-a"))
        (with-current-buffer chat-b
          (setq-local dsh-emacs--buffer-session "sess-b"))
        (cl-letf (((symbol-function 'dsh-emacs--events-result-async)
                   (lambda (_client-id event-id outcome cb)
                     (push (list event-id outcome) responds)
                     (funcall cb t nil)))
                  ((symbol-function 'completing-read-multiple)
                   (lambda (prompt candidates &rest _)
                     (push prompt prompts)
                     ;; While A's minibuffer waits, session B's question frame arrives: it
                     ;; must queue,
                     ;; not nest a prompt in the same minibuffer
                     (unless b-pushed
                       (setq b-pushed t)
                       (dsh-emacs--question-requested
                        chat-b "rpc-b" "sess-b"
                        (list (list (cons 'id "qb")
                                    (cons 'question "B asks?")
                                    (cons 'options
                                          (list (list (cons 'label "Only"))))))))
                     ;; COLLECTION is the completion table (read-order metadata); take the
                     ;; first item
                     ;; way the UI does, do not destructure directly.
                     (list (car (all-completions "" candidates))))))
          ;; A's frame arrives first (idle -> into the answer slot); while A is answering,
          ;; B's frame queues. questions shape matches the event dispatch: a list of
          ;; question
          ;; alists (an array on the wire, given directly as a list here).
          (dsh-emacs--question-requested
           chat-a "rpc-a" "sess-a"
           (list (list (cons 'id "qa")
                       (cons 'question "A asks?")
                       (cons 'options
                             (list (list (cons 'label "Yes")))))))
          ;; After A is answered B moves into the answer slot and continues;
          ;; $events/result
          ;; matches arrival order
          (let ((r2 (pop responds))
                (r1 (pop responds)))
            (dsh-test-assert "question-queue-serial-first"
              (equal (list "rpc-a"
                           '((kind . "result")
                             (value . ((answers .
                                        (((id . "qa")
                                          (selected "Yes"))))))))
                     r1))
            (dsh-test-assert "question-queue-serial-second"
              (equal (list "rpc-b"
                           '((kind . "result")
                             (value . ((answers .
                                        (((id . "qb")
                                          (selected "Only"))))))))
                     r2)))
          ;; Every prompt in the serial queue carries the Question N/M frame and its
          ;; question text
          (dsh-test-assert "question-serial-prompts-framed"
            (cl-some (lambda (p)
                       (string-match-p "Question 1/1 — A asks?" p))
                     prompts)
            (cl-some (lambda (p)
                       (string-match-p "Question 1/1 — B asks?" p))
                     prompts))
          ;; After answering ends both the answer slot and the queue are empty (no leak
          ;; into
          ;; later tests)
          (when (and (null dsh-emacs--question-active)
                     (null dsh-emacs--question-queue))
            (dsh-test-pass "question-queue-drained-clean"))))
    (when (buffer-live-p chat-a) (kill-buffer chat-a))
    (when (buffer-live-p chat-b) (kill-buffer chat-b))))

;; 9) duplicate frames for the same event-id (mux replay) must not ask again: while the
;; first frame is being answered, an arriving duplicate must be dropped, not
;; queued and not re-asked.
;; Regression: the same question used to be asked twice (after the first frame was
;; answered the copy entered the queue and popped up again).
(let* ((chat (get-buffer-create " *dsh-test-question-dup*"))
       (responds nil)
       (prompts 0)
       (dup-sent nil))
  (unwind-protect
      (let ((dsh-emacs--sessions nil)
            (dsh-emacs--chat-buffers (make-hash-table :test 'equal))
            (dsh-emacs-enable-notifications nil))
        (setq dsh-emacs--question-queue nil
              dsh-emacs--question-active nil)
        (with-current-buffer chat
          (setq-local dsh-emacs--buffer-session "sess-dup"))
        (cl-letf (((symbol-function 'dsh-emacs--events-result-async)
                   (lambda (_client-id event-id outcome cb)
                     (push (list event-id outcome) responds)
                     (funcall cb t nil)))
                  ((symbol-function 'completing-read-multiple)
                   (lambda (_prompt &rest _)
                     (setq prompts (1+ prompts))
                     ;; While the first frame is answered, a replay copy with the same
                     ;; event-id arrives
                     ;; -> must be dropped. The copy is injected once (pre-fix code
                     ;; answered it
                     ;; again and triggered this stub once more, a re-ask loop -- the very
                     ;; symptom
                     ;; this regression kills).
                     (unless dup-sent
                       (setq dup-sent t)
                       (dsh-emacs--question-requested
                        chat "rpc-dup" "sess-dup"
                        (list (list (cons 'id "qd")
                                    (cons 'question "Dup?")
                                    (cons 'options
                                          (list (list (cons 'label "Yes"))))))))
                     '("Yes"))))
          (dsh-emacs--question-requested
           chat "rpc-dup" "sess-dup"
           (list (list (cons 'id "qd")
                       (cons 'question "Dup?")
                       (cons 'options
                             (list (list (cons 'label "Yes")))))))
          (dsh-test-assert "question-replay-duplicate-asked-once"
            (= 1 prompts)
            (= 1 (length responds))
            (equal '("rpc-dup") (mapcar #'car responds)))
          (when (and (null dsh-emacs--question-active)
                     (null dsh-emacs--question-queue))
            (dsh-test-pass "question-replay-duplicate-drained-clean"))))
    (when (buffer-live-p chat) (kill-buffer chat))))

;; 10) cancel frame (host withdraws a waterfall) -> the queued frame with the same
;; eventId retires, and a replayed requested->cancel pair no longer re-asks a settled
;; question. Retirement semantics live in the `$events' cancel frame (eventId);
;; the wire has no question/resolved push-only envelope.
;; Regression: cancel was ignored and the queued copy kept popping up to the user.
(let* ((chat (get-buffer-create " *dsh-test-question-cancel*"))
       (responds nil)
       (prompted nil))
  (unwind-protect
      (let ((dsh-emacs--sessions nil)
            (dsh-emacs--chat-buffers (make-hash-table :test 'equal))
            (dsh-emacs-events--client-id "c1")
            (dsh-emacs-enable-notifications nil))
        (puthash "sess-res" chat dsh-emacs--chat-buffers)
        (setq dsh-emacs--question-queue nil
              dsh-emacs--question-active t)  ; another frame holds the answer slot
        (with-current-buffer chat
          (setq-local dsh-emacs--buffer-session "sess-res"))
        (cl-letf (((symbol-function 'dsh-emacs--events-result-async)
                   (lambda (_client-id _event-id _outcome cb)
                     (push t responds)
                     (funcall cb t nil)))
                  ((symbol-function 'completing-read-multiple)
                   (lambda (&rest _) (setq prompted t) '("Yes"))))
          ;; The copy arrives first (queued), then the host withdraws that eventId with a
          ;; cancel
          ;; frame (same replay order)
          (dsh-emacs-events--host-item
           'process
           '((type . "waterfall")
             (event . "user-questions/request")
             (eventId . "rpc-rs")
             (agentId . "sess-res")
             (request . ((questions .
                          (((id . "q1") (question . "Proceed?")
                            (options . (((label . "Yes")))))))))))
          (dsh-emacs-events--host-item
           'process
           '((type . "cancel") (eventId . "rpc-rs")))
          (dsh-test-assert "question-cancel-retires-queued-frame"
            (null dsh-emacs--question-queue))
          ;; After the answer slot is cleared the queue is empty too -> no more popping
          ;; up, no more answering
          (setq dsh-emacs--question-active nil)
          (dsh-emacs--question-drain)
          (dsh-test-assert "question-cancel-never-prompts"
            (null prompted)
            (null responds)
            (null dsh-emacs--question-queue))))
    (when (buffer-live-p chat) (kill-buffer chat))))

;; --- Test 78a: approval/request frame dispatch -> approval -> answer (incl. while
;; history is loading) ---
;; When a sandbox tool needs a file outside the workspace, the host pushes a waterfall
;; over the `$events' stream
;; (approval/request, eventId + agentId + request.toolName/reason/callId).
;; The client shows the approval, reads the decision, and posts the outcome to the
;; unary endpoint POST /api/$events/result (value = ApprovalOutcome string). Like
;; questions, approvals are not gated on history loading.
(let* ((chat (get-buffer-create " *dsh-test-approval-dispatch*"))
       (responds nil))
  (unwind-protect
      (let ((dsh-emacs--chat-buffers (make-hash-table :test 'equal))
            (dsh-emacs-events--client-id "c1")
            (dsh-emacs-enable-notifications nil))
        (puthash "sess-ap" chat dsh-emacs--chat-buffers)
        (with-current-buffer chat
          (setq-local dsh-emacs--buffer-session "sess-ap"))
        (cl-letf (((symbol-function 'dsh-emacs--approval-prompt)
                   (lambda (&rest _) t))
                  ((symbol-function 'dsh-emacs--events-result-async)
                   (lambda (client-id event-id outcome cb)
                     (push (list client-id event-id outcome) responds)
                     (funcall cb t nil))))
          (dsh-emacs-events--host-item
           'process
           '((type . "waterfall")
             (event . "approval/request")
             (eventId . "rpc-ap")
             (agentId . "sess-ap")
             (request . ((toolName . "fs")
                         (reason . "read outside workspace")
                         (callId . "call-x")))))
          (let ((entry (car responds)))
            (dsh-test-assert "approval-frame-answered"
              (and (equal "c1" (nth 0 entry))
                   (equal "rpc-ap" (nth 1 entry))
                   (equal '((kind . "result") (value . "allowed-once"))
                          (nth 2 entry)))))
          ;; Approvals must also be answered while history is loading (the mux replays
          ;; pending
          ;; approvals when opened)
          (with-current-buffer chat
            (setq-local dsh-emacs--event-history-loading t))
          (setq responds nil)
          (dsh-emacs-events--host-item
           'process
           '((type . "waterfall")
             (event . "approval/request")
             (eventId . "rpc-ap2")
             (agentId . "sess-ap")
             (request . ((toolName . "bash")))))
          (dsh-test-assert "approval-frame-during-history-load-answered"
            (and responds (equal "rpc-ap2" (nth 1 (car responds)))))))
    (when (buffer-live-p chat) (kill-buffer chat))))

;; --- Test 78a1: cancel closes a displayed question, no stale outcome sent back ---
(let ((chat (get-buffer-create " *dsh-test-question-active-cancel*"))
      (responds nil)
      (aborted nil))
  (unwind-protect
      (let ((dsh-emacs--question-queue nil)
            (dsh-emacs--question-active nil)
            (dsh-emacs--approval-queue nil)
            (dsh-emacs--approval-active nil)
            (dsh-emacs--waterfall-cancelled-event-id nil)
            (dsh-emacs-enable-notifications nil))
        (cl-letf (((symbol-function 'dsh-emacs--events-result-async)
                   (lambda (&rest args) (push args responds)))
                  ((symbol-function 'active-minibuffer-window)
                   (lambda () t))
                  ((symbol-function 'abort-recursive-edit)
                   (lambda () (setq aborted t) (signal 'quit nil)))
                  ((symbol-function 'completing-read-multiple)
                   (lambda (&rest _)
                     (dsh-emacs--question-cancelled "wf-active-q")
                     '("Yes"))))
          (dsh-emacs--question-requested
           chat "wf-active-q" "sess-q"
           '(((id . "q1") (question . "Proceed?")
              (options . (((label . "Yes")))))))
          (dsh-test-assert "question-active-cancel-closes-without-response"
            aborted
            (null responds)
            (null dsh-emacs--question-active)
            (null dsh-emacs--waterfall-cancelled-event-id))))
    (when (buffer-live-p chat) (kill-buffer chat))))

;; --- Test 78b: approval allow-once / reject decision -> $events/result outcome ---
(let* ((chat (get-buffer-create " *dsh-test-approval-decision*"))
       (responds nil))
  (unwind-protect
      (let ((dsh-emacs-enable-notifications nil))
        (with-current-buffer chat
          (setq-local dsh-emacs--buffer-session "sess-ad"))
        (cl-letf (((symbol-function 'dsh-emacs--approval-prompt)
                   (lambda (&rest _) t))
                  ((symbol-function 'dsh-emacs--events-result-async)
                   (lambda (_client-id event-id outcome cb)
                     (push (list event-id outcome) responds)
                     (funcall cb t nil))))
          (dsh-emacs--approval-requested
           chat "rpc-ad1" "sess-ad" "bash"
           "needs /etc/passwd" "call-1")
          (dsh-test-assert "approval-allow-once-outcome"
            (equal (list "rpc-ad1"
                         '((kind . "result") (value . "allowed-once")))
                   (car responds))))
        (setq responds nil)
        (cl-letf (((symbol-function 'dsh-emacs--approval-prompt)
                   (lambda (&rest _) nil))
                  ((symbol-function 'dsh-emacs--events-result-async)
                   (lambda (_client-id event-id outcome cb)
                     (push (list event-id outcome) responds)
                     (funcall cb t nil))))
          (dsh-emacs--approval-requested
           chat "rpc-ad2" "sess-ad" "fs"
           "write outside workspace" "call-2")
          (dsh-test-assert "approval-reject-outcome"
            (equal (list "rpc-ad2"
                         '((kind . "result") (value . "rejected")))
                   (car responds)))))
    (when (buffer-live-p chat) (kill-buffer chat))))

;; --- Test 78h: approval prompt over multiple lines: full justification + concrete
;; bash command ---
;; The prompt reads `dsh-emacs--tool-states' in the chat buffer context (the rendered
;; tool/call tracked by callId in the render layer), bash shows the real command line;
;; the justification is shown in full, untruncated, separated from the command by a
;; blank line. The two parts are colored separately: justification light orange
;; (dsh-emacs-approval-justification-face), command gray
;; (dsh-emacs-approval-command-face).
(let* ((chat (get-buffer-create " *dsh-test-approval-command*"))
       (captured nil)
       (just "the command reads /etc/hostname outside the workspace so we can identify this machine"))
  (unwind-protect
      (let ((dsh-emacs--approval-queue nil)
            (dsh-emacs--approval-active nil)
            (dsh-emacs-enable-notifications nil))
        (with-current-buffer chat
          (setq dsh-emacs--tool-states (make-hash-table :test 'equal))
          (puthash "call-1"
                   (list :state 'pending :variant "bash" :icon ">_"
                         :title "Bash" :summary "cat /etc/os-release"
                         :args "$ cat /etc/os-release" :call-time nil :ns nil)
                   dsh-emacs--tool-states))
        (cl-letf (((symbol-function 'y-or-n-p)
                   (lambda (prompt) (setq captured prompt) t))
                  ((symbol-function 'dsh-emacs--events-result-async)
                   (lambda (&rest _) nil)))
          ;; Read transcript state in the chat buffer context via drain
          (dsh-emacs--approval-requested
           chat "rpc-h" "sess-h" "bash" just "call-1")
          (dsh-test-assert "approval-prompt-full-justification-and-command"
            (equal (concat just "\n\n$ cat /etc/os-release")
                   (substring-no-properties captured)))
          (dsh-test-assert "approval-prompt-justification-face"
            (eq 'dsh-emacs-approval-justification-face
                (get-text-property 0 'face captured)))
          (dsh-test-assert "approval-prompt-command-face"
            (eq 'dsh-emacs-approval-command-face
                (get-text-property (+ 2 (length just)) 'face captured)))
          ;; callId not found (replay before the tool/call render) -> show justification
          ;; only
          (setq captured nil)
          (dsh-emacs--approval-requested
           chat "rpc-h2" "sess-h" "bash" just "call-unknown")
          (dsh-test-assert "approval-prompt-falls-back-to-justification"
            (equal just (substring-no-properties captured)))
          (dsh-test-assert "approval-prompt-fallback-still-colored"
            (eq 'dsh-emacs-approval-justification-face
                (get-text-property 0 'face captured)))))
    (when (buffer-live-p chat) (kill-buffer chat))))

;; --- Test 78c: approval aborted with C-g -> answered as default rejection (with no
;; answer the host blocks forever on the pending approval), slot and queue cleared ---
(let* ((chat (get-buffer-create " *dsh-test-approval-cg*"))
       (responds nil))
  (unwind-protect
      (let ((dsh-emacs-enable-notifications nil))
        (with-current-buffer chat
          (setq-local dsh-emacs--buffer-session "sess-cg"))
        (cl-letf (((symbol-function 'dsh-emacs--approval-prompt)
                   (lambda (&rest _) (signal 'quit nil)))
                  ((symbol-function 'dsh-emacs--events-result-async)
                   (lambda (_client-id event-id outcome cb)
                     (push (list event-id outcome) responds)
                     (funcall cb t nil))))
          (dsh-emacs--approval-requested
           chat "rpc-cg" "sess-cg" "bash" nil nil)
          (when (and (equal responds
                            (list (list "rpc-cg"
                                        '((kind . "result")
                                          (value . "rejected")))))
                     (null dsh-emacs--approval-active)
                     (null dsh-emacs--approval-queue))
            (dsh-test-pass "approval-c-g-answers-rejected"))))
    (when (buffer-live-p chat) (kill-buffer chat))))

;; --- Test 78d: mux replays the same approval (same eventId) -> ask only once ---
(let* ((chat (get-buffer-create " *dsh-test-approval-dedup*")))
  (unwind-protect
      (let ((dsh-emacs--approval-queue
             (list (list chat "wf-d0" "sess-d" "bash" "reason" nil)))
            (dsh-emacs--approval-active
             (list chat "wf-d1" "sess-d" "bash" "reason" nil)))
        ;; mux replay of the same eventId: already queued -> not enqueued again
        (dsh-emacs--approval-requested
         chat "wf-d0" "sess-d" "bash" "reason" nil)
        ;; same eventId currently being answered -> not enqueued either
        (dsh-emacs--approval-requested
         chat "wf-d1" "sess-d" "bash" "reason" nil)
        (when (= 1 (length dsh-emacs--approval-queue))
          (dsh-test-pass "approval-replay-dedup-single-prompt")))
    (kill-buffer chat)))

;; --- Test 78e: cancel frame withdraws the same queued approval frame ---
(let* ((chat (get-buffer-create " *dsh-test-approval-cancel*")))
  (unwind-protect
      (progn
        (setq dsh-emacs--approval-queue
              (list (list chat "wf-e1" "sess-e" "bash" "reason" nil)
                    (list chat "wf-e2" "sess-e" "fs" "r" nil)))
        (dsh-emacs--approval-cancelled "wf-e1")
        (when (and (= 1 (length dsh-emacs--approval-queue))
                   (equal "wf-e2" (nth 1 (car dsh-emacs--approval-queue))))
          (dsh-test-pass "approval-cancel-drops-only-matching-frame")))
    (setq dsh-emacs--approval-queue nil)
    (when (buffer-live-p chat) (kill-buffer chat))))

;; --- Test 78e1: cancel closes a displayed approval, no stale reject sent back ---
(let ((chat (get-buffer-create " *dsh-test-approval-active-cancel*"))
      (responds nil)
      (aborted nil))
  (unwind-protect
      (let ((dsh-emacs--question-queue nil)
            (dsh-emacs--question-active nil)
            (dsh-emacs--approval-queue nil)
            (dsh-emacs--approval-active nil)
            (dsh-emacs--waterfall-cancelled-event-id nil)
            (dsh-emacs-enable-notifications nil))
        (cl-letf (((symbol-function 'dsh-emacs--events-result-async)
                   (lambda (&rest args) (push args responds)))
                  ((symbol-function 'active-minibuffer-window)
                   (lambda () t))
                  ((symbol-function 'abort-recursive-edit)
                   (lambda () (setq aborted t) (signal 'quit nil)))
                  ((symbol-function 'dsh-emacs--approval-prompt)
                   (lambda (&rest _)
                     (dsh-emacs--approval-cancelled "wf-active-a")
                     t)))
          (dsh-emacs--approval-requested
           chat "wf-active-a" "sess-a" "bash" "reason" nil)
          (dsh-test-assert "approval-active-cancel-closes-without-response"
            aborted
            (null responds)
            (null dsh-emacs--approval-active)
            (null dsh-emacs--waterfall-cancelled-event-id))))
    (when (buffer-live-p chat) (kill-buffer chat))))

;; --- Test 78f: approvals and questions share one minibuffer slot (question first ->
;; approval queues and takes over) ---
;; An approval frame arriving while a question occupies the slot must queue (never
;; nest y-or-n-p in a running completing-read); only after the question queue is
;; empty does drain take over the approval frame.
(let* ((chat (get-buffer-create " *dsh-test-approval-slot-qfirst*"))
       (trace nil))
  (unwind-protect
      (let ((dsh-emacs--question-queue nil)
            (dsh-emacs--question-active t)      ; simulate a question being answered
            (dsh-emacs--approval-queue nil)
            (dsh-emacs--approval-active nil)
            (dsh-emacs-enable-notifications nil))
        (cl-letf (((symbol-function 'dsh-emacs--approval-prompt)
                   (lambda (&rest _) (push :approval-prompt trace) t))
                  ((symbol-function 'completing-read-multiple)
                   (lambda (&rest _) (push :question-prompt trace) '("Yes")))
                  ((symbol-function 'dsh-emacs--events-result-async)
                   (lambda (_client-id event-id _outcome cb)
                     (push (list :respond event-id) trace)
                     (funcall cb t nil))))
          ;; An approval arriving during a question -> only enqueued, no prompt
          (dsh-emacs--approval-requested
           chat "rpc-ap" "sess-s" "bash" "outside" nil)
          (when (and (null trace)
                     (= 1 (length dsh-emacs--approval-queue)))
            (dsh-test-pass "approval-queued-while-question-active"))
          ;; Question finished (queue empty) -> handoff takes over the queued approval
          (setq dsh-emacs--question-active nil)
          (setq dsh-emacs--question-queue
                (list (list chat "rpc-q" "sess-q"
                            (list (list (cons 'id "q1")
                                        (cons 'question "Proceed?")
                                        (cons 'options
                                              (list (list (cons 'label "Yes")))))))))
          (dsh-emacs--question-drain)
          (dsh-test-assert "approval-handoff-after-question-drain"
            (equal '(:question-prompt
                     (:respond "rpc-q")
                     :approval-prompt
                     (:respond "rpc-ap"))
                   (nreverse trace)))))
    (when (buffer-live-p chat) (kill-buffer chat))))

;; --- Test 78g: approvals and questions share one minibuffer slot (approval first ->
;; question queues and takes over) ---
(let* ((chat (get-buffer-create " *dsh-test-approval-slot-afirst*"))
       (trace nil))
  (unwind-protect
      (let ((dsh-emacs--question-queue nil)
            (dsh-emacs--question-active nil)
            (dsh-emacs--approval-queue nil)
            (dsh-emacs--approval-active
             (list chat "rpc-ax" "sess-x" "bash" nil nil)) ; an approval is being answered
            (dsh-emacs-enable-notifications nil))
        (cl-letf (((symbol-function 'dsh-emacs--approval-prompt)
                   (lambda (&rest _) (push :approval-prompt trace) t))
                  ((symbol-function 'completing-read-multiple)
                   (lambda (&rest _) (push :question-prompt trace) '("Yes")))
                  ((symbol-function 'dsh-emacs--events-result-async)
                   (lambda (_client-id event-id _outcome cb)
                     (push (list :respond event-id) trace)
                     (funcall cb t nil))))
          ;; A question arriving during an approval -> only enqueued, no prompt
          (dsh-emacs--question-requested
           chat "rpc-qx" "sess-qx"
           (list (list (cons 'id "q1")
                       (cons 'question "Proceed?")
                       (cons 'options (list (list (cons 'label "Yes")))))))
          (when (and (null trace)
                     (= 1 (length dsh-emacs--question-queue)))
            (dsh-test-pass "question-queued-while-approval-active"))
          ;; Approval answered -> handoff takes over the queued question
          (setq dsh-emacs--approval-active nil)
          (dsh-emacs--approval-drain)
          (dsh-test-assert "question-handoff-after-approval-drain"
            (equal '(:question-prompt (:respond "rpc-qx"))
                   (nreverse trace)))))
    (when (buffer-live-p chat) (kill-buffer chat))))

;; --- Test 78i: desktop notification for questions/approvals (turn-finish style) ---
;; Notify once, when the frame enters the queue; replay copies (dropped as
;; duplicates) do not notify again. The notification body carries the question text /
;; the command line that triggered the call, to help decide while away from the
;; minibuffer.
(let* ((chat (get-buffer-create " *dsh-test-interaction-notify*"))
       (posted nil))
  (unwind-protect
      (let ((dsh-emacs--sessions nil)
            (dsh-emacs--chat-buffers (make-hash-table :test 'equal)))
        (setq dsh-emacs--question-queue nil
              dsh-emacs--question-active nil
              dsh-emacs--approval-queue nil
              dsh-emacs--approval-active nil)
        (with-current-buffer chat
          (setq-local dsh-emacs--buffer-session "sess-nt"))
        (cl-letf (((symbol-function 'dsh-emacs-notify--post)
                   (lambda (_session body _buffer) (push body posted)))
                  ((symbol-function 'dsh-emacs--events-result-async)
                   (lambda (&rest _) nil))
                  ((symbol-function 'completing-read-multiple)
                   (lambda (_prompt candidates &rest _)
                     (list (car (all-completions "" candidates)))))
                  ((symbol-function 'read-string)
                   (lambda (&rest _) "free answer"))
                  ((symbol-function 'dsh-emacs--approval-prompt)
                   (lambda (&rest _) t)))
          ;; Question frame accepted into the queue -> one notification, body carries its
          ;; text
          (dsh-emacs--question-requested
           chat "rpc-n1" "sess-nt"
           (list (list (cons 'id "q1")
                       (cons 'question "Which dir?")
                       (cons 'options (list (list (cons 'label "a")))))))
          (dsh-test-assert "question-notify-on-accept"
            (equal '("Question: Which dir?") posted))
          ;; A copy with the same event-id is still queued (mux replay) -> dropped, no
          ;; notify
          (setq posted nil)
          (setq dsh-emacs--question-queue
                (list (list chat "rpc-n1" "sess-nt"
                            (list (list (cons 'id "q1")
                                        (cons 'question "Which dir?"))))))
          (dsh-emacs--question-requested
           chat "rpc-n1" "sess-nt"
           (list (list (cons 'id "q1") (cons 'question "Which dir?"))))
          (dsh-test-assert "question-notify-replay-dropped"
            (null posted))
          ;; Approval frame -> notification body carries the triggering command line
          ;; (the chat buffer's transcript)
          (setq posted nil)
          (with-current-buffer chat
            (setq dsh-emacs--tool-states (make-hash-table :test 'equal))
            (puthash "call-n"
                     (list :state 'pending :variant "bash" :icon ">_"
                           :title "Bash" :summary "cat x"
                           :args "$ cat /etc/hostname" :call-time nil :ns nil)
                     dsh-emacs--tool-states))
          (dsh-emacs--approval-requested
           chat "rpc-n2" "sess-nt" "bash" "needs outside" "call-n")
          (dsh-test-assert "approval-notify-body-carries-command"
            (equal '("Approval: $ cat /etc/hostname") posted))
          ;; A copy with the same event-id is still queued -> dropped, no notify
          (setq posted nil)
          (setq dsh-emacs--approval-queue
                (list (list chat "rpc-n3" "sess-nt" "bash" "x" nil)))
          (dsh-emacs--approval-requested
           chat "rpc-n3" "sess-nt" "bash" "needs outside" "call-n")
          (dsh-test-assert "approval-notify-replay-dropped"
            (null posted))))
    (when (buffer-live-p chat) (kill-buffer chat))))

;; --- Test 78j: $events ready -> capture clientId; generation change retires pending
;; waterfalls ---
;; `$events' sends ready(clientId) first per generation (each reconnect); this
;; client answers waterfalls with that clientId, and after a generation change the old
;; generation's pending frames (result now a no-op) are retired as a whole.
(let ((dsh-emacs--chat-buffers (make-hash-table :test 'equal))
      (dsh-emacs--question-queue nil)
      (dsh-emacs--approval-queue nil))
  (setq dsh-emacs-events--client-id nil)
  ;; first generation ready -> capture clientId
  (dsh-emacs-events--host-item
   'process '((type . "ready") (clientId . "gen-1")))
  (dsh-test-assert "events-ready-captures-client-id"
    (equal "gen-1" dsh-emacs-events--client-id))
  ;; replay with the same clientId -> no retirement (same generation)
  (setq dsh-emacs--question-queue
        (list (list (get-buffer-create " *t-gen-q*")
                    "e-1" "sess-g" '((id . "q1")))))
  (dsh-emacs-events--host-item
   'process '((type . "ready") (clientId . "gen-1")))
  (dsh-test-assert "events-ready-same-generation-keeps-pending"
    (= 1 (length dsh-emacs--question-queue)))
  ;; new generation ready -> the old generation's pending frames retire (question +
  ;; approval both cleared)
  (setq dsh-emacs--approval-queue
        (list (list (get-buffer-create " *t-gen-a*")
                    "e-2" "sess-g" "bash" "reason" nil)))
  (dsh-emacs-events--host-item
   'process '((type . "ready") (clientId . "gen-2")))
  (dsh-test-assert "events-new-generation-retires-pending"
    (equal "gen-2" dsh-emacs-events--client-id)
    (null dsh-emacs--question-queue)
    (null dsh-emacs--approval-queue))
  (setq dsh-emacs-events--client-id nil))

;; --- Test 78k: $events cancel -> retire matching pending waterfalls by eventId ---
;; A host cancellation (session end / withdraw) sends cancel(eventId); only frames of
;; the same eventId retire, other pending frames are kept.
(let ((chat (get-buffer-create " *t-cancel-chat*")))
  (unwind-protect
      (let ((dsh-emacs--chat-buffers (make-hash-table :test 'equal))
            (dsh-emacs--question-queue
             (list (list chat "q-cancel" "sess-q" '((id . "qa")))
                   (list chat "q-keep" "sess-q" '((id . "qb")))))
            (dsh-emacs--approval-queue
             (list (list chat "a-cancel" "sess-q" "fs" "r" nil)
                   (list chat "a-keep" "sess-q" "bash" "r" nil))))
        (dsh-emacs-events--host-item
         'process '((type . "cancel") (eventId . "q-cancel")))
        (dsh-test-assert "events-cancel-retires-matching-question"
          (= 1 (length dsh-emacs--question-queue))
          (equal "q-keep" (nth 1 (car dsh-emacs--question-queue)))
          (= 2 (length dsh-emacs--approval-queue)))
        (dsh-emacs-events--host-item
         'process '((type . "cancel") (eventId . "a-cancel")))
        (dsh-test-assert "events-cancel-retires-matching-approval"
          (= 1 (length dsh-emacs--approval-queue))
          (equal "a-keep" (nth 1 (car dsh-emacs--approval-queue)))
          (= 1 (length dsh-emacs--question-queue))))
    (when (buffer-live-p chat) (kill-buffer chat))))

(when (featurep 'dsh-emacs-server)
  (dsh-test-pass "dsh-emacs-server loaded"))

;; --- Test 79: server bootstrap: base-url -> (host . port) parsing ---
(let ((dsh-emacs-base-url "http://127.0.0.1:3080"))
  (let ((hp (dsh-emacs--server-host-port)))
    (when (and (equal "127.0.0.1" (car hp)) (= 3080 (cdr hp)))
      (dsh-test-pass "server-host-port-parses-default-url"))))
(let ((dsh-emacs-base-url "http://localhost:9999"))
  (let ((hp (dsh-emacs--server-host-port)))
    (when (and (equal "localhost" (car hp)) (= 9999 (cdr hp)))
      (dsh-test-pass "server-host-port-parses-custom-host-port"))))
(let ((dsh-emacs-base-url "http://127.0.0.1"))
  (when (= 80 (cdr (dsh-emacs--server-host-port)))
    (dsh-test-pass "server-host-port-defaults-to-80")))

;; --- Test 80: alive probe has a short cache (no re-probe within the TTL) ---
(let ((probes 0))
  (setq dsh-emacs--server-alive-check nil)
  (cl-letf (((symbol-function 'dsh-emacs--server-probe)
             (lambda () (setq probes (1+ probes)) t)))
    (dsh-emacs--server-alive-p)
    (dsh-emacs--server-alive-p)
    (when (= 1 probes)
      (dsh-test-pass "server-alive-cached-within-ttl"))
    (dsh-emacs--server-invalidate-alive)
    (dsh-emacs--server-alive-p)
    (when (= 2 probes)
      (dsh-test-pass "server-alive-invalidate-reprobes")))
  (setq dsh-emacs--server-alive-check nil))

;; --- Test 81: ensure is always a no-op under batch (noninteractive) ---
(let ((started 0)
      (noninteractive t))
  (cl-letf (((symbol-function 'dsh-emacs--server-alive-p) (lambda () nil))
            ((symbol-function 'dsh-emacs-server-start)
             (lambda (&optional _wait) (setq started (1+ started)))))
    (dsh-emacs-server-ensure))
  (when (= 0 started)
    (dsh-test-pass "server-ensure-noop-in-batch")))

;; --- Test 82: ensure interactive path: server already ready -> do not start ---
(let ((started 0)
      (noninteractive nil))
  (cl-letf (((symbol-function 'dsh-emacs--server-alive-p) (lambda () t))
            ((symbol-function 'dsh-emacs--server-auth-ensure-interactive)
             ;; Test only ensure's start control flow: auth gating is tested separately,
             ;; avoiding
             ;; a connection to a real 401 server
             (lambda () t))
            ((symbol-function 'dsh-emacs-server-start)
             (lambda (&optional _wait) (setq started (1+ started)))))
    (dsh-emacs-server-ensure))
  (when (= 0 started)
    (dsh-test-pass "server-ensure-alive-skips-start")))

;; --- Test 83: ensure interactive path: down + auto-start -> start is called ---
(let ((started 0)
      (noninteractive nil))
  (cl-letf (((symbol-function 'dsh-emacs--server-alive-p) (lambda () nil))
            ((symbol-function 'dsh-emacs-server-start)
             (lambda (&optional _wait) (setq started (1+ started)))))
    (dsh-emacs-server-ensure))
  (when (= 1 started)
    (dsh-test-pass "server-ensure-down-starts-server")))

;; --- Test 84: ensure interactive path: auto-start nil -> user-error with guidance ---
(let ((dsh-emacs-server-auto-start nil)
      (noninteractive nil))
  (cl-letf (((symbol-function 'dsh-emacs--server-alive-p) (lambda () nil)))
    (condition-case err
        (dsh-emacs-server-ensure)
      (user-error
       (when (string-match-p "not reachable" (error-message-string err))
         (dsh-test-pass "server-ensure-auto-start-nil-errors"))))))

;; --- Test 84b: remote base-url + down -> no start / no CLI install, report
;; unreachable ---
(let* ((dsh-emacs-base-url "http://dsh-remote.example:3080")
       (noninteractive nil)
       (started 0))
  (cl-letf (((symbol-function 'dsh-emacs--server-alive-p) (lambda () nil))
            ((symbol-function 'dsh-emacs-server-start)
             (lambda (&optional _wait) (setq started (1+ started)))))
    (condition-case err
        (dsh-emacs-server-ensure)
      (user-error
       (when (and (= 0 started)   ; A remote host never goes through local startup
                  (string-match-p "not reachable" (error-message-string err))
                  (string-match-p "remote" (error-message-string err)))
         (dsh-test-pass "server-ensure-remote-no-start"))))))

;; --- Test 84c: local/remote host determination ---
(let ((dsh-emacs-base-url "http://127.0.0.1:3080")
      (noninteractive nil))
  (when (dsh-emacs--server-local-host-p)
    (dsh-test-pass "server-local-host-loopback")))
(let ((dsh-emacs-base-url "http://localhost:3080")
      (noninteractive nil))
  (when (dsh-emacs--server-local-host-p)
    (dsh-test-pass "server-local-host-localhost")))
(let ((dsh-emacs-base-url "http://dsh-remote.example:3080")
      (noninteractive nil))
  (when (not (dsh-emacs--server-local-host-p))
    (dsh-test-pass "server-local-host-remote-false")))
;; IPv6 loopback: url-host carries brackets ("[::1]"), host-name strips them, local
(let ((dsh-emacs-base-url "http://[::1]:3080")
      (noninteractive nil))
  (when (and (equal "::1" (dsh-emacs--server-host-name))
             (dsh-emacs--server-local-host-p))
    (dsh-test-pass "server-local-host-ipv6-loopback")))
;; Private network IP: non-loopback host -> judged remote
(let ((dsh-emacs-base-url "http://192.168.1.100:3080")
      (noninteractive nil))
  (when (not (dsh-emacs--server-local-host-p))
    (dsh-test-pass "server-local-host-private-ip-remote")))

;; --- Test 84d: remote base-url + start-on-init -> do not spawn a local server ---
(let ((dsh-emacs-base-url "http://dsh-remote.example:3080")
      (dsh-emacs-server-start-on-init t)
      (spawned 0))
  (cl-letf (((symbol-function 'dsh-emacs--server-alive-p) (lambda () nil))
            ((symbol-function 'dsh-emacs--server-bin) (lambda () "/usr/bin/dsh"))
            ((symbol-function 'dsh-emacs--server-launch)
             (lambda (&rest _) (setq spawned (1+ spawned))))
            ((symbol-function 'run-at-time)
             ;; Run the timer body immediately so the spawn decision completes
             ;; synchronously
             (lambda (_delay _repeat fn &rest args)
               (apply fn args))))
    (dsh-emacs-server--maybe-start-on-init))
  (when (= 0 spawned)
    (dsh-test-pass "server-remote-init-no-spawn")))

;; --- Test 84e: nginx basic auth -- auth header when base-url carries
;; userinfo ---
(let ((dsh-emacs-base-url "http://alice:secret@dsh-remote.example:3080"))
  (let ((hdr (dsh-emacs-server--basic-auth-header)))
    (when (and (equal "Authorization" (car hdr))
               (equal (concat "Basic "
                              (base64-encode-string "alice:secret" t))
                      (cdr hdr)))
      (dsh-test-pass "server-basic-auth-header-built"))))
(let ((dsh-emacs-base-url "http://dsh-remote.example:3080"))
  (when (null (dsh-emacs-server--basic-auth-header))
    (dsh-test-pass "server-no-auth-header-without-userinfo")))

;; --- Test 84f: WebSocket handshake carries the Basic auth header (nginx basic auth) ---
(let ((dsh-emacs-base-url "http://alice:secret@127.0.0.1:3080")
      (sent nil))
  (cl-letf (((symbol-function 'dsh-emacs-events--random-mask)
             (lambda () (apply #'unibyte-string (list 1 2 3 4))))
            ((symbol-function 'process-send-string)
             (lambda (_proc string) (setq sent string))))
    (dsh-emacs-events--send-handshake
     (make-pipe-process :name "ws-test" :buffer (get-buffer-create " *ws*"))))
  (when (and sent
             (string-match-p "Authorization: Basic [A-Za-z0-9+/=]+" sent))
    (dsh-test-pass "server-websocket-handshake-carries-basic-auth")))

;; --- Test 84g: HTTPS base-url probe goes through the url library (TLS) path ---
(let ((dsh-emacs-base-url "https://probe.example:443")
      (noninteractive nil))
  (cl-letf (((symbol-function 'dsh-emacs--server-probe-https)
             (lambda () t))
            ((symbol-function 'dsh-emacs--server-probe-plain)
             (lambda () (error "plain probe must not run for https"))))
    (when (dsh-emacs--server-probe)
      (dsh-test-pass "server-probe-https-dispatch"))))
(let ((dsh-emacs-base-url "http://probe.example:3080")
      (noninteractive nil))
  (cl-letf (((symbol-function 'dsh-emacs--server-probe-https)
             (lambda () (error "https probe must not run for http")))
            ((symbol-function 'dsh-emacs--server-probe-plain)
             (lambda () t)))
    (when (dsh-emacs--server-probe)
      (dsh-test-pass "server-probe-http-dispatch"))))

;; --- Test 84h: https probe has a bounded timeout; empty return keeps the buffer ---
;;
;; When url-retrieve-synchronously returns nil (timeout/refusal), the probe returns
;; nil, and must not delete the caller's current buffer via (kill-buffer nil).
(let ((dsh-emacs-base-url "https://probe.example:443")
      (victim (generate-new-buffer " *probe-victim*")))
  (unwind-protect
      (with-current-buffer victim
        (cl-letf (((symbol-function 'url-retrieve-synchronously)
                   (lambda (&rest _) nil)))   ; Simulate a timeout returning nil
          (let ((result (condition-case e
                            (dsh-emacs--server-probe-https)
                          (error (list :err e)))))
            (when (and (null result)
                       (eq (current-buffer) victim)
                       (buffer-live-p victim))
              (dsh-test-pass "server-probe-https-timeout-nil-safe")))))
    (kill-buffer victim)))

;; --- Test 84i: HTTPS probe does not ask Basic credentials on a 401 before the
;; token exchange ---
;; Use url's real auth handling: dsh has no WWW-Authenticate, so url falls back to Basic.
(require 'url-http)
(require 'url-auth)
(dolist (status '("200" "401"))
  (let ((dsh-emacs-base-url "https://probe.example:443")
        (dsh-emacs-server-auth-token "ConfiguredToken")
        (url-request-noninteractive nil)
        (url-registered-auth-schemes nil)
        (challenges nil)
        (response nil))
    (url-register-auth-scheme "basic" nil 4)
    (cl-letf (((symbol-function 'url-get-authentication)
               (lambda (_url _realm type prompt &rest _)
                 (push (list type prompt (url-interactive-p)) challenges)
                 nil))
              ((symbol-function 'url-retrieve-synchronously)
               (lambda (url &rest _)
                 (setq response (generate-new-buffer " *probe-http*"))
                 (with-current-buffer response
                   (insert (format "HTTP/1.1 %s X\r\nContent-Length: 0\r\n\r\n"
                                   status))
                   (when (equal status "401")
                     (setq-local url-current-object (url-generic-parse-url url))
                     (setq-local url-http-extra-headers nil)
                     (setq-local url-http-noninteractive url-request-noninteractive)
                     (url-http-handle-authentication nil))
                   response))))
      (unwind-protect
          (dsh-test-assert
              (format "server-probe-https-%s-alive-without-basic-prompt" status)
            (dsh-emacs--server-probe-https)
            (equal challenges (and (equal status "401") '(("basic" t nil))))
            (not (buffer-live-p response)))
        (when (buffer-live-p response) (kill-buffer response))))))

;; --- Test 85: install flow: accept -> run the install and return the dsh path ---
(cl-letf (((symbol-function 'dsh-emacs--server-bin) (lambda () nil))
          ((symbol-function 'y-or-n-p) (lambda (_prompt) t))
          ((symbol-function 'dsh-emacs--server-run-install)
           (lambda () "/usr/bin/dsh")))
  (when (equal "/usr/bin/dsh" (dsh-emacs--server-ensure-installed))
    (dsh-test-pass "server-install-accepted-runs-install")))

;; --- Test 86: install flow: decline -> user-error with manual guidance ---
(cl-letf (((symbol-function 'dsh-emacs--server-bin) (lambda () nil))
          ((symbol-function 'y-or-n-p) (lambda (_prompt) nil)))
  (condition-case err
      (dsh-emacs--server-ensure-installed)
    (user-error
     (when (string-match-p "manually" (error-message-string err))
       (dsh-test-pass "server-install-declined-errors")))))

;; --- Test 87: server-start: already ready -> do not launch a process ---
(let ((commands nil))
  (cl-letf (((symbol-function 'dsh-emacs--server-alive-p) (lambda () t))
            ((symbol-function 'dsh-emacs--server-auth-ensure-interactive)
             ;; Test only server-start's start control flow; auth gating is tested
             ;; separately.
             (lambda () t))
            ((symbol-function 'make-process)
             (lambda (&rest args) (push args commands) 'fake-proc)))
    (dsh-emacs-server-start))
  (when (null commands)
    (dsh-test-pass "server-start-alive-does-not-spawn")))

;; --- Test 88: server-start: down -> launch dsh web at base-url's host/port ---
(let ((commands nil)
      (waits 0)
      (dsh-emacs-base-url "http://127.0.0.1:3080"))
  (setq dsh-emacs--server-process nil)
  (cl-letf (((symbol-function 'dsh-emacs--server-alive-p) (lambda () nil))
            ((symbol-function 'dsh-emacs--server-bin) (lambda () "/usr/bin/dsh"))
            ((symbol-function 'make-process)
             (lambda (&rest args) (push args commands) 'fake-proc))
            ((symbol-function 'set-process-query-on-exit-flag)
             (lambda (&rest _) nil))
            ((symbol-function 'dsh-emacs--server-wait-ready)
             (lambda () (setq waits (1+ waits)) t)))
    ;; wait=t: server-start calls wait-ready only when explicitly asked (interactive
    ;; defaults to not waiting); previously waits was never 1, so the test never
    ;; fired
    (dsh-emacs-server-start t))
  (dsh-test-assert "server-start-spawns-dsh-web-with-base-url-args"
    (= 1 waits)
    (equal '("/usr/bin/dsh" "web" "--host" "127.0.0.1"
             "--port" "3080" "--no-open")
           (plist-get (car commands) :command)))
  (setq dsh-emacs--server-process nil))

;; --- Test 89: wait-ready: server already ready -> return t immediately ---
(cl-letf (((symbol-function 'dsh-emacs--server-alive-p) (lambda () t)))
  (when (eq t (dsh-emacs--server-wait-ready))
    (dsh-test-pass "server-wait-ready-alive-returns-t")))

;; --- Test 89b: list-sessions polls for the grace period a blocking start
;; would use, not a fixed few seconds ---
;; A cold `dsh web' boot composes the profile and loads the whole plugin tree
;; (measured ~4.5 s here), so a hardcoded 5 s window loses the race.  The
;; deadline must derive from `dsh-emacs-server-wait-seconds'.
(let ((dsh-emacs-server-wait-seconds 30)
      (deadline nil)
      (dsh-emacs--server-process nil))
  (cl-letf (((symbol-function 'dsh-emacs-server-start) (lambda (&optional _) nil))
            ((symbol-function 'dsh-emacs-events--host-refresh-begin)
             (lambda () nil))
            ((symbol-function 'float-time) (lambda () 1000.0))
            ((symbol-function 'dsh-emacs-list-sessions--fetch-when-ready)
             (lambda (arg) (setq deadline arg))))
    (dsh-emacs-list-sessions))
  (dsh-test-assert "list-sessions-waits-the-configured-grace-period"
    (equal deadline 1030.0)))

;; --- Test 89c: the non-blocking poll keeps retrying while the deadline
;; remains, and reports the timeout instead of scheduling once it passed ---
(let ((scheduled 0)
      (now 10.0)
      (reported nil))
  (cl-letf (((symbol-function 'dsh-emacs--server-alive-p) (lambda () nil))
            ((symbol-function 'dsh-emacs-list-sessions--fetch)
             (lambda () (setq reported "fetched")))
            ((symbol-function 'float-time) (lambda () now))
            ((symbol-function 'run-at-time)
             (lambda (&rest _) (setq scheduled (1+ scheduled))))
            ((symbol-function 'message)
             (lambda (fmt &rest args) (setq reported (apply #'format fmt args)))))
    ;; 10 s in with a 30 s deadline: still polling (the old window had ended).
    (dsh-emacs-list-sessions--fetch-when-ready 30.0)
    (dsh-test-assert "server-ready-poll-keeps-waiting-past-five-seconds"
      (= 1 scheduled)
      (null reported))
    ;; Past the deadline: report, do not schedule another attempt.
    (setq scheduled 0
          now 31.0
          reported nil)
    (dsh-emacs-list-sessions--fetch-when-ready 30.0)
    (dsh-test-assert "server-ready-poll-reports-the-timeout"
      (= 0 scheduled)
      (and (stringp reported)
           (string-match-p "did not become ready" reported)))))

;; --- Test 90: clean up the managed process when Emacs exits ---
(when (memq 'dsh-emacs-server--teardown kill-emacs-hook)
  (dsh-test-pass "server-teardown-registered-on-kill-emacs-hook"))

;; --- Test 91: command-body guardrail -- error with guidance when the server is
;; unreachable ---
;; The guardrail is in `dsh-emacs-server-ensure' (the entry point of commands such as
;; switch-session): list-sessions takes `dsh-emacs-server-start's auto-start path and
;; does not error, so this tests ensure's real behavior (it previously tested
;; list-sessions and never triggered).
(let ((dsh-emacs-server-auto-start nil)
      (noninteractive nil))
  (cl-letf (((symbol-function 'dsh-emacs--server-alive-p) (lambda () nil)))
    (condition-case err
        (dsh-emacs-server-ensure)
      (user-error
       (dsh-test-assert "list-sessions-guard-fails-with-guidance"
         (string-match-p "not reachable" (error-message-string err))
         (string-match-p "M-x dsh-emacs-server-start"
                         (error-message-string err)))))))

;; --- Test 92: open-web opens dsh web (base-url; settings is a popup, no subroute) ---
(let ((dsh-emacs-base-url "http://127.0.0.1:3080")
      (opened nil))
  (cl-letf (((symbol-function 'browse-url)
             (lambda (url) (setq opened url))))
    (dsh-emacs-open-web))
  (when (equal "http://127.0.0.1:3080" opened)
    (dsh-test-pass "open-web-opens-web-ui-root")))

;; --- Test 93: open-web is likewise protected by the server guardrail ---
(let ((dsh-emacs-server-auto-start nil)
      (noninteractive nil))
  (cl-letf (((symbol-function 'dsh-emacs--server-alive-p) (lambda () nil)))
    (condition-case err
        (dsh-emacs-open-web)
      (user-error
       (when (string-match-p "not reachable" (error-message-string err))
         (dsh-test-pass "open-web-guard-fails-with-guidance"))))))

;; --- Test 93bis: browser session auth -- capture launch token from *dsh-server* ---
(let ((dsh-emacs--server-auth-captured-token nil)
      (buf (get-buffer-create "*dsh-server*")))
  (unwind-protect
      (progn
        (with-current-buffer buf
          (erase-buffer)
          (insert "dsh web: http://127.0.0.1:3080/?token=CapturedTok123 (LAN: http://192.168.1.5:3080/?token=CapturedTok123)\n"))
        (dsh-test-assert "auth-token-captured-from-server-output"
          (equal "CapturedTok123"
                 (dsh-emacs--server-auth-token))))
    (kill-buffer buf))
  (setq dsh-emacs--server-auth-captured-token nil))

;; --- Test 93c: launch token extracted from the base-url token query parameter ---
(dsh-test-assert "auth-token-from-url-single"
  (equal "AbC_-D"
         (dsh-emacs--server-auth-token-from-url
          "http://127.0.0.1:3080/?token=AbC_-D")))
(dsh-test-assert "auth-token-from-url-clean-is-nil"
  (null (dsh-emacs--server-auth-token-from-url "http://127.0.0.1:3080")))

;; --- Test 93c2: a ?token= query in base-url is stripped when building request URLs ---
;; When the user puts the full URL printed by dsh web (including ?token=) into
;; dsh-emacs-base-url, RPC/probe/open-web path building must not splice the query
;; in (otherwise the URL becomes ...?token=X/api/...) -- the cleaned base drops the
;; query and the trailing slash, and the token is extracted separately.
(let ((dsh-emacs-base-url "http://127.0.0.1:3080/?token=Xy-9_"))
  (dsh-test-assert "auth-base-url-strips-token-query-for-url-building"
    (and (equal "http://127.0.0.1:3080"
                (dsh-emacs--server-base-url))
         (equal "http://127.0.0.1:3080/api/session/list"
                (format "%s/api/session/list"
                        (dsh-emacs--server-base-url)))
         (equal "http://127.0.0.1:3080/"
                (concat (dsh-emacs--server-base-url) "/"))))
  (dsh-test-assert "auth-base-url-raw-still-carries-token"
    (equal "Xy-9_"
           (dsh-emacs--server-auth-token-from-url
            (dsh-emacs--server-base-url-raw)))))

;; --- Test 93d: token → cookie exchange parses Set-Cookie and caches it, no
;; repeated mint ---
;; exchange goes through `dsh-emacs--server-auth-exchange-plain' (raw TCP): dsh's
;; successful exchange is 303 + Set-Cookie, so the first 303's headers must be
;; read and redirects must not be followed (url-retrieve follows to / and drops
;; the header). The unit test feeds a real 303 response through a mock socket.
(let ((dsh-emacs-base-url "http://alice:secret@127.0.0.1:3080")
      (filter nil)
      (sent nil)
      (cookie-header "Set-Cookie: dsh-auth-HASH=eyJ2MSJ9.sig; Path=/\r\n"))
  (cl-letf (((symbol-function 'open-network-stream)
             (lambda (&rest _) 'fake-sock))
            ((symbol-function 'set-process-query-on-exit-flag)
             (lambda (&rest _) nil))
            ((symbol-function 'set-process-filter)
             (lambda (_proc f) (setq filter f)))
            ((symbol-function 'process-send-string)
             (lambda (_proc string) (setq sent string)))
            ((symbol-function 'accept-process-output)
             (lambda (&rest _)
               (funcall filter 'fake-sock
                (concat "HTTP/1.1 303 See Other\r\nLocation: /\r\n"
                        "Set-Cookie: proxy-route=backend-1; Path=/\r\n"
                        cookie-header "\r\n"))))
            ((symbol-function 'process-live-p) (lambda (&rest _) t))
            ((symbol-function 'delete-process) (lambda (&rest _) nil)))
    (let ((cookie (dsh-emacs--server-auth-exchange-plain
                   "http://127.0.0.1:3080/?token=TokD")))
      (dsh-test-assert "auth-raw-exchange-hits-token-query"
        (string-match-p "GET /\\?token=TokD HTTP/1.0" sent))
      (dsh-test-assert "auth-raw-exchange-carries-configured-basic-auth"
        (string-match-p
         (concat "Authorization: Basic " (base64-encode-string "alice:secret" t)
                 "\r\n")
         sent))
      (dsh-test-assert "auth-raw-exchange-parses-303-set-cookie"
        (equal "dsh-auth-HASH=eyJ2MSJ9.sig" cookie)))
    (setq cookie-header "")
    (dsh-test-assert "auth-raw-exchange-rejects-unrelated-cookie"
      (null (dsh-emacs--server-auth-exchange-plain
             "http://127.0.0.1:3080/?token=TokD")))))

;; --- Test 93d2: for an https base the token exchange goes through url-retrieve
;; and parses the 303 Set-Cookie ---
;; https needs TLS, so it can only go through the url library; the implementation
;; uses `url-max-redirections 0' to make url-retrieve stop at the first 303 and
;; read the Set-Cookie (instead of following to /). On-demand mint inside an RPC
;; must not inherit the outer POST, request body, or auth headers.
(let ((dsh-emacs-base-url "https://auth.example:3080")
      (url-request-method "POST")
      (url-request-data "outer-rpc-body")
      (url-request-extra-headers '(("Cookie" . "outer-cookie")))
      (url-request-noninteractive nil)
      (request-context nil)
      (redirs-unbounded nil))
  (cl-letf (((symbol-function 'url-retrieve-synchronously)
             (lambda (&rest _)
               (setq request-context
                     (list url-request-method url-request-data
                           url-request-extra-headers url-request-noninteractive))
               (setq redirs-unbounded (and (boundp 'url-max-redirections)
                                           (= url-max-redirections 0)))
               (with-current-buffer (generate-new-buffer " *dsh-https-mint*")
                 (insert "HTTP/1.1 303 See Other\r\nLocation: /\r\n"
                         "Set-Cookie: dsh-auth-ABC=v1.body.sig; Path=/; HttpOnly; SameSite=Strict\r\n\r\n")
                 (current-buffer)))))
    (let ((cookie (dsh-emacs--server-auth-exchange "https://auth.example:3080"
                                                   "TokH")))
      (dsh-test-assert "auth-https-exchange-disables-redirects"
        redirs-unbounded)
      (dsh-test-assert "auth-https-exchange-isolates-get-from-rpc-context"
        (equal '("GET" nil nil t) request-context))
      (dsh-test-assert "auth-https-exchange-preserves-outer-rpc-context"
        (equal '("POST" "outer-rpc-body" (("Cookie" . "outer-cookie")) nil)
               (list url-request-method url-request-data
                     url-request-extra-headers url-request-noninteractive)))
      (dsh-test-assert "auth-https-exchange-parses-303-set-cookie"
        (equal "dsh-auth-ABC=v1.body.sig" cookie)))))

;; --- Test 93d3: ensure end-to-end --- a known token exchanges for a cookie and
;; caches it ---
(let ((dsh-emacs-base-url "http://127.0.0.1:3080")
      (dsh-emacs-server-auth-token "TokE")
      (filter nil)
      (dsh-emacs--server-auth-cookie nil))
  (cl-letf (((symbol-function 'open-network-stream)
             (lambda (&rest _) 'fake-sock))
            ((symbol-function 'set-process-query-on-exit-flag)
             (lambda (&rest _) nil))
            ((symbol-function 'set-process-filter)
             (lambda (_proc f) (setq filter f)))
            ((symbol-function 'process-send-string) (lambda (&rest _) nil))
            ((symbol-function 'accept-process-output)
             (lambda (&rest _)
               (funcall filter 'fake-sock
                (concat "HTTP/1.1 303 See Other\r\nLocation: /\r\n"
                        "Set-Cookie: dsh-auth-EEE=v1.sig; Path=/; HttpOnly; SameSite=Strict\r\n\r\n"))))
            ((symbol-function 'process-live-p) (lambda (&rest _) t))
            ((symbol-function 'delete-process) (lambda (&rest _) nil)))
    (let ((cookie (dsh-emacs--server-auth-ensure)))
      (dsh-test-assert "auth-ensure-mints-from-token-and-caches"
        (and (equal "dsh-auth-EEE=v1.sig" cookie)
             (equal "dsh-auth-EEE=v1.sig" dsh-emacs--server-auth-cookie)))))
  (setq dsh-emacs--server-auth-cookie nil
        dsh-emacs-server-auth-token nil))

;; --- Test 93d3b: cookie-header normalizes a cookie carrying the multibyte flag
;; to unibyte ---
;; Regression: the cookie is captured with `match-string' from the network
;; response buffer, so it carries the multibyte flag even when its content is
;; pure ASCII. Emacs `url' errors on concatenating a "multibyte header + unibyte
;; request body" --- Bug#23750 ("Multibyte text in HTTP request") --- sending
;; Chinese makes the request body unibyte UTF-8 bytes, and the concatenation
;; crashes. cookie-header must return a genuinely unibyte byte string, keeping
;; both RPC requests and the WS handshake single-byte (the cookie is a
;; `dsh-auth-<name>=v1.<body>.<sig>' ASCII token, so the normalization is
;; lossless).
(let ((old dsh-emacs--server-auth-cookie))
  (unwind-protect
      (let* ((cookie (string-as-multibyte "dsh-auth-MB=v1.body.sig"))
             (dsh-emacs--server-auth-cookie cookie))
        (dsh-test-assert "auth-cookie-multibyte-flag-normalized"
          (let ((out (dsh-emacs--server-auth-cookie-header)))
            (and (stringp out)
                 (equal "dsh-auth-MB=v1.body.sig"
                        (decode-coding-string out 'utf-8))
                 (not (multibyte-string-p out)))))
        (dsh-test-assert "auth-cookie-already-unibyte-passthrough"
          (let ((dsh-emacs--server-auth-cookie "dsh-auth-UB=v1.sig"))
            (equal "dsh-auth-UB=v1.sig"
                   (dsh-emacs--server-auth-cookie-header))))
        (dsh-test-assert "auth-cookie-nil-returns-nil"
          (let ((dsh-emacs--server-auth-cookie nil))
            (null (dsh-emacs--server-auth-cookie-header)))))
    (setq dsh-emacs--server-auth-cookie old)))

;; --- Test 93d3c: a stale cookie after an external server restart is cleared on
;; 401 ---
;; Regression: a user-managed external `dsh web' issues a new per-process token
;; on every restart, invalidating the old cookie cached on this side; the client
;; cannot tell that the token changed, so it keeps sending the dead cookie and
;; every RPC 401s until Emacs restarts. On a "401 carrying our cookie" it should
;; clear the cache (the next call mints again / asks again).
(let ((dsh-emacs--server-auth-cookie "dsh-auth-STALE=v1.old"))
  (dsh-test-assert "auth-http-401-p-detects-http-401"
    (dsh-emacs--server-auth-http-401-p '(error http 401))
    (not (dsh-emacs--server-auth-http-401-p '(error http 404)))
    (not (dsh-emacs--server-auth-http-401-p nil)))
  (dsh-emacs--server-auth-maybe-expire)
  (dsh-test-assert "auth-stale-cookie-cleared-on-401"
    (null dsh-emacs--server-auth-cookie))
  ;; Without a cookie, maybe-expire stays as-is (it must not wrongly clear state in
  ;; the no-cookie case)
  (dsh-emacs--server-auth-maybe-expire)
  (dsh-test-assert "auth-maybe-expire-with-no-cookie"
    (null dsh-emacs--server-auth-cookie)))

;; --- Test 93d3d: the three raw-socket HTTP requests stay byte-exact under a
;; DOS-EOL ambient process coding system ---
;; Regression (reported on Windows): `default-process-coding-system''s ENCODING
;; cdr is a `-dos' coding system there (`locale-coding-system' carries DOS line
;; endings), and Emacs applies it to every new process unless the socket says
;; otherwise.  `process-send-string' then rewrites each `\n' of the hand-written
;; "GET ... \r\n\r\n" as `\r\n', so the socket receives "\r\r\n" and dsh's HTTP
;; parser answers 400 Bad Request; the probe only accepts 200/401, so a live
;; server reads as down — `*dsh-sessions*' stays empty and `new-session' waits
;; out "did not become ready".  All three raw HTTP sockets (probe, auth probe,
;; token exchange) must pin binary (byte-exact) coding, like the WebSocket
;; sockets.
;; The corruption happens inside `process-send-string''s C-level coding, which a
;; mocked `process-send-string' cannot observe: this drives a real loopback
;; listener and inspects the bytes it actually receives.
(let ((default-process-coding-system '(utf-8-unix . utf-8-dos))
      (dsh-emacs-base-url nil))
  (cl-labels
      ((raw-socket-server (response fn)
         "Call FN against a loopback HTTP server replying RESPONSE.
Return (REQUEST . RESULT): REQUEST is the exact byte string the server
received, RESULT is FN's return value."
         (let* ((request "")
                (server (make-network-process
                         :name "dsh-raw-socket-test" :server t
                         :host "127.0.0.1" :service 0 :family 'ipv4 :noquery t
                         ;; Binary on the listener too, so the assertion reads
                         ;; the request bytes rather than a decoded view of them.
                         :coding 'binary
                         :filter (lambda (proc string)
                                   (setq request (concat request string))
                                   (when (string-match-p "\r\n\r\n" request)
                                     (process-send-string proc response)))))
                (result nil))
           (unwind-protect
               (progn
                 (setq dsh-emacs-base-url
                       (format "http://127.0.0.1:%d"
                               (process-contact server :service)))
                 (setq result (funcall fn))
                 (cons request result))
             (delete-process server)))))
    (pcase-let ((`(,probe-request . ,probe-alive)
                 (raw-socket-server
                  "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
                  #'dsh-emacs--server-probe-plain)))
      (dsh-test-assert "raw-probe-request-keeps-crlf-under-dos-coding"
        (string-match-p "GET / HTTP/1.0\r\nHost: 127\\.0\\.0\\.1:[0-9]+\r\n\r\n"
                        probe-request)
        (not (string-match-p "\r\r\n" probe-request)))
      (dsh-test-assert "raw-probe-alive-under-dos-coding"
        probe-alive))
    (pcase-let ((`(,auth-request . ,auth-required)
                 (raw-socket-server
                  "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n"
                  #'dsh-emacs--server-auth-required-plain)))
      (dsh-test-assert "raw-auth-probe-request-keeps-crlf-under-dos-coding"
        (not (string-match-p "\r\r\n" auth-request)))
      (dsh-test-assert "raw-auth-probe-detects-401-under-dos-coding"
        auth-required))
    (pcase-let ((`(,exchange-request . ,exchange-cookie)
                 (raw-socket-server
                  (concat "HTTP/1.1 303 See Other\r\nLocation: /\r\n"
                          "Set-Cookie: dsh-auth-HASH=v1.body.sig; Path=/; HttpOnly\r\n"
                          "\r\n")
                  (lambda ()
                    (dsh-emacs--server-auth-exchange-plain
                     (concat dsh-emacs-base-url "/?token=TokDos"))))))
      (dsh-test-assert "raw-exchange-request-keeps-crlf-under-dos-coding"
        (string-match-p "GET /\\?token=TokDos HTTP/1.0" exchange-request)
        (not (string-match-p "\r\r\n" exchange-request)))
      (dsh-test-assert "raw-exchange-mints-cookie-under-dos-coding"
        (equal "dsh-auth-HASH=v1.body.sig" exchange-cookie)))))

;; --- Test 93d4: interactive auth gate --- with a known cookie, no prompting ---
(let ((dsh-emacs-base-url "http://127.0.0.1:3080")
      (dsh-emacs--server-auth-cookie "dsh-auth-HASH=ok.sig")
      (noninteractive nil)
      (asked 0))
  (cl-letf (((symbol-function 'read-string)
             (lambda (&rest _) (setq asked (1+ asked)) "Tok")))
    (dsh-emacs--server-auth-ensure-interactive))
  (when (= 0 asked)
    (dsh-test-pass "auth-gate-cookie-present-asks-nothing"))
  (setq dsh-emacs--server-auth-cookie nil))

;; --- Test 93d5: interactive auth gate --- known token → mint directly, no
;; prompting ---
(let ((dsh-emacs-base-url "http://127.0.0.1:3080")
      (dsh-emacs-server-auth-token "TokKnown")
      (dsh-emacs--server-auth-cookie nil)
      (noninteractive nil)
      (asked 0)
      (filter nil))
  (cl-letf (((symbol-function 'read-string)
             (lambda (&rest _) (setq asked (1+ asked)) "x"))
            ((symbol-function 'open-network-stream)
             (lambda (&rest _) 'fake-sock))
            ((symbol-function 'set-process-query-on-exit-flag)
             (lambda (&rest _) nil))
            ((symbol-function 'set-process-filter)
             (lambda (_proc f) (setq filter f)))
            ((symbol-function 'process-send-string) (lambda (&rest _) nil))
            ((symbol-function 'accept-process-output)
             (lambda (&rest _)
               (funcall filter 'fake-sock
                (concat "HTTP/1.1 303 See Other\r\nLocation: /\r\n"
                        "Set-Cookie: dsh-auth-KNOWN=v1.sig; Path=/; HttpOnly; SameSite=Strict\r\n\r\n"))))
            ((symbol-function 'process-live-p) (lambda (&rest _) t))
            ((symbol-function 'delete-process) (lambda (&rest _) nil)))
    (dsh-emacs--server-auth-ensure-interactive))
  (dsh-test-assert "auth-gate-known-token-mints-silently"
    (and (= 0 asked)
         (equal "dsh-auth-KNOWN=v1.sig" dsh-emacs--server-auth-cookie)))
  (setq dsh-emacs--server-auth-cookie nil
        dsh-emacs-server-auth-token nil))

;; --- Test 93d6: interactive auth gate --- server needs no cookie → passes
;; without prompting ---
(let ((dsh-emacs-base-url "http://127.0.0.1:3080")
      (dsh-emacs--server-auth-cookie nil)
      (noninteractive nil)
      (asked 0))
  (cl-letf (((symbol-function 'dsh-emacs--server-auth-required-p)
             (lambda () nil))
            ((symbol-function 'read-string)
             (lambda (&rest _) (setq asked (1+ asked)) "x")))
    (dsh-emacs--server-auth-ensure-interactive))
  (when (= 0 asked)
    (dsh-test-pass "auth-gate-no-auth-needed-asks-nothing")))

;; --- Test 93d7: interactive auth gate --- external auth-required server →
;; prompt for a token and mint ---
(let ((dsh-emacs-base-url "http://127.0.0.1:3080")
      (dsh-emacs--server-auth-cookie nil)
      (dsh-emacs-server-auth-token nil)
      (noninteractive nil)
      (filter nil)
      (asked 0))
  (cl-letf (((symbol-function 'dsh-emacs--server-auth-required-p)
             (lambda () t))
            ((symbol-function 'customize-save-variable)
             (lambda (&rest _) nil))
            ((symbol-function 'read-string)
             (lambda (_prompt) (setq asked (1+ asked)) "UserTok"))
            ((symbol-function 'open-network-stream)
             (lambda (&rest _) 'fake-sock))
            ((symbol-function 'set-process-query-on-exit-flag)
             (lambda (&rest _) nil))
            ((symbol-function 'set-process-filter)
             (lambda (_proc f) (setq filter f)))
            ((symbol-function 'process-send-string) (lambda (&rest _) nil))
            ((symbol-function 'accept-process-output)
             (lambda (&rest _)
               (funcall filter 'fake-sock
                (concat "HTTP/1.1 303 See Other\r\nLocation: /\r\n"
                        "Set-Cookie: dsh-auth-USERT=v1.sig; Path=/; HttpOnly; SameSite=Strict\r\n\r\n"))))
            ((symbol-function 'process-live-p) (lambda (&rest _) t))
            ((symbol-function 'delete-process) (lambda (&rest _) nil)))
    (dsh-emacs--server-auth-ensure-interactive))
  (dsh-test-assert "auth-gate-external-auth-asks-and-mints"
    (and (= 1 asked)
         (equal "dsh-auth-USERT=v1.sig" dsh-emacs--server-auth-cookie)
         (equal dsh-emacs-server-auth-token "UserTok"))) ; remembered for reuse
  (setq dsh-emacs--server-auth-cookie nil
        dsh-emacs-server-auth-token nil))

;; --- Test 93d8: interactive auth gate --- empty user input → user-error
;; guidance ---
(let ((dsh-emacs-base-url "http://127.0.0.1:3080")
      (dsh-emacs--server-auth-cookie nil)
      (noninteractive nil))
  (cl-letf (((symbol-function 'dsh-emacs--server-auth-required-p)
             (lambda () t))
            ((symbol-function 'read-string)
             (lambda (&rest _) "")))
    (condition-case err
        (dsh-emacs--server-auth-ensure-interactive)
      (user-error
       (when (string-match-p "dsh-emacs-server-auth-token"
                             (error-message-string err))
         (dsh-test-pass "auth-gate-empty-token-errors-with-guidance"))))))

;; --- Test 93d8b: empty input, a wrong token, and C-g can all be retried on the
;; next call ---
(dolist (first-input '("" "WrongTok" quit))
  (let ((dsh-emacs-base-url "http://127.0.0.1:3080")
        (dsh-emacs--server-auth-cookie nil)
        (dsh-emacs--server-process nil)
        (dsh-emacs-server-auth-token nil)
        (noninteractive nil)
        (asked 0)
        (exchanged nil)
        (first-result nil)
        (retry-result nil))
    (cl-letf (((symbol-function 'dsh-emacs--server-auth-token)
               (lambda () nil))
              ((symbol-function 'dsh-emacs--server-auth-required-p)
               (lambda () t))
              ((symbol-function 'customize-save-variable)
               (lambda (&rest _) nil))
              ((symbol-function 'read-string)
               (lambda (&rest _)
                 (setq asked (1+ asked))
                 (if (> asked 1) "CorrectTok"
                   (if (eq first-input 'quit) (signal 'quit nil)
                     first-input))))
              ((symbol-function 'dsh-emacs--server-auth-ensure)
               (lambda (token)
                 (push token exchanged)
                 (when (equal token "CorrectTok")
                   (setq dsh-emacs--server-auth-cookie "dsh-auth-RETRY=ok")))))
      (setq first-result
            (condition-case err
                (dsh-emacs--server-auth-ensure-interactive)
              ((user-error quit) (car err))))
      (dsh-test-assert (format "auth-gate-failed-attempt-blocks-%s" first-input)
        (eq first-result (if (eq first-input 'quit) 'quit 'user-error))
        (null dsh-emacs--server-auth-cookie)
        (= asked 1))
      (setq retry-result
            (condition-case err
                (dsh-emacs--server-auth-ensure-interactive)
              (user-error (car err))))
      (dsh-test-assert (format "auth-gate-retry-succeeds-%s" first-input)
        (eq retry-result t)
        (= asked 2)
        (equal dsh-emacs--server-auth-cookie "dsh-auth-RETRY=ok")
        (equal (reverse exchanged)
               (if (equal first-input "WrongTok")
                   '("WrongTok" "CorrectTok") '("CorrectTok")))))))

;; --- Test 93d9: interactive auth gate --- on success cache the cookie and do
;; not ask again ---
(let ((dsh-emacs-base-url "http://127.0.0.1:3080")
      (dsh-emacs--server-auth-cookie nil)
      (noninteractive nil)
      (dsh-emacs-server-auth-token nil)
      (asked 0)
      (filter nil))
  (cl-letf (((symbol-function 'dsh-emacs--server-auth-required-p)
             (lambda () t))
            ((symbol-function 'customize-save-variable)
             (lambda (&rest _) nil))
            ((symbol-function 'read-string)
             (lambda (_prompt) (setq asked (1+ asked)) "TokA"))
            ((symbol-function 'open-network-stream)
             (lambda (&rest _) 'fake-sock))
            ((symbol-function 'set-process-query-on-exit-flag)
             (lambda (&rest _) nil))
            ((symbol-function 'set-process-filter)
             (lambda (_proc f) (setq filter f)))
            ((symbol-function 'process-send-string) (lambda (&rest _) nil))
            ((symbol-function 'accept-process-output)
             (lambda (&rest _)
               (funcall filter 'fake-sock
                (concat "HTTP/1.1 303 See Other\r\nLocation: /\r\n"
                        "Set-Cookie: dsh-auth-A=v1.sig; Path=/; HttpOnly; SameSite=Strict\r\n\r\n"))))
            ((symbol-function 'process-live-p) (lambda (&rest _) t))
            ((symbol-function 'delete-process) (lambda (&rest _) nil)))
    ;; The first mint succeeds, the cookie is cached → the second call does not ask
    ;; again.
    (dsh-emacs--server-auth-ensure-interactive)
    (dsh-emacs--server-auth-ensure-interactive))
  (dsh-test-assert "auth-gate-cookie-cached-skips-repeat-ask"
    (and (= 1 asked)
         (equal "dsh-auth-A=v1.sig" dsh-emacs--server-auth-cookie)
         (equal dsh-emacs-server-auth-token "TokA"))) ; remembered for reuse
  (setq dsh-emacs--server-auth-cookie nil
        dsh-emacs-server-auth-token nil))

;; --- Test 93d9b: a remembered token is persisted only when its value changes
;; (anti-churn) ---
(let ((dsh-emacs-server-auth-token nil) (saved nil))
  (cl-letf (((symbol-function 'customize-save-variable)
             (lambda (var val) (push (list var val) saved))))
    (dsh-emacs--server-auth-remember-token "tokX")
    (let ((after-first saved))
      (dsh-emacs--server-auth-remember-token "tokX")
      (dsh-test-assert "auth-remember-saves-and-skips-churn"
        (and (equal dsh-emacs-server-auth-token "tokX")
             (equal after-first
                    (list (list 'dsh-emacs-server-auth-token "tokX")))
             (equal saved after-first)))))
  (setq dsh-emacs-server-auth-token nil))

;; --- Test 93e: the WebSocket handshake carries the browser session cookie ---
(dolist (case '(("http://127.0.0.1:3080" "127.0.0.1:3080")
                ("http://127.0.0.1:80" "127.0.0.1")
                ("http://127.0.0.1:443" "127.0.0.1:443")
                ("https://127.0.0.1:443" "127.0.0.1")))
  (pcase-let ((`(,dsh-emacs-base-url ,authority) case))
    (let ((sent nil)
          (dsh-emacs--server-auth-cookie "dsh-auth-HASH=ok.sig"))
      (cl-letf (((symbol-function 'process-send-string)
                 (lambda (_proc string) (setq sent string))))
        (dsh-emacs-events--send-handshake 'fake-sock))
      (dsh-test-assert (format "websocket-auth-authority-%s" dsh-emacs-base-url)
        (string-match-p "Cookie: dsh-auth-HASH=ok\\.sig\r\n" sent)
        (string-match-p (regexp-quote (format "Host: %s\r\n" authority)) sent)
        (string-match-p
         (regexp-quote
          (format "Origin: %s://%s\r\n"
                  (url-type (url-generic-parse-url dsh-emacs-base-url)) authority))
         sent)))))

;; --- Test 93g: /api/remote.mux open message and downstream frame envelope ---
(let* ((json (dsh-emacs-events--open-message
              "follow-1" "session/follow"
              '((request . ((address . ((kind . "session")
                                        (sessionId . "s1"))))))))
       (msg (json-read-from-string json)))
  (dsh-test-assert "mux-open-message-shape"
    (equal "open" (dsh-emacs-render--aget "type" msg))
    (equal "follow-1" (dsh-emacs-render--aget "streamId" msg))
    (equal "session/follow" (dsh-emacs-render--aget "endpoint" msg))
    (equal "s1"
           (dsh-emacs-render--aget
            "sessionId"
            (dsh-emacs-render--aget
             "address"
             (dsh-emacs-render--aget "request"
                                     (dsh-emacs-render--aget "args"
                                                             (dsh-emacs-render--aget "payload" msg))))))))

(let* ((json (dsh-emacs-events--open-message "events-1" "$events" nil))
       (msg (json-read-from-string json))
       (args (assq 'args (dsh-emacs-render--aget "payload" msg))))
  ;; An empty object decodes to nil in json-read: the wire frame must still
  ;; carry the `args' key (a `{}' value), never drop it.
  (when (and args (null (cdr args)))
    (dsh-test-pass "mux-open-no-args-encodes-empty-object")))

(dsh-test-assert "mux-frame-parses-item-error-other"
  (let ((item (dsh-emacs-events--message-frame
               "{\"type\":\"item\",\"streamId\":\"f1\",\"value\":{\"type\":\"event\",\"event\":{}}}")))
    (and (equal "item" (plist-get item :type))
         (equal "f1" (plist-get item :stream-id))
         (listp (plist-get item :value))))
  (let ((err (dsh-emacs-events--message-frame
              "{\"type\":\"error\",\"streamId\":\"f1\",\"error\":{\"code\":\"x\"}}")))
    (and (equal "error" (plist-get err :type))
         (equal "x" (dsh-emacs-render--aget "code" (plist-get err :error)))))
  (let ((ready (dsh-emacs-events--message-frame
                "{\"type\":\"ready\",\"clientId\":\"c1\"}")))
    (equal "ready" (plist-get ready :type))))


;; --- Test 93f: http-error-hint gives auth guidance for 401 ---
(dsh-test-assert "http-error-hint-401-mentions-auth"
  (string-match-p "401"
                  (dsh-emacs--http-error-hint '(error http 401))))

;; RPC auth failure does not enter Basic interaction; the sync path must read the
;; HTTP status rather than parse the error page. Async responses are dispatched
;; after the request's dynamic bindings have exited, mimicking url's buffer-local
;; configuration.
(dolist (mode '(sync async))
  (dolist (status '(200 401 403))
    (let ((dsh-emacs-base-url "http://rpc.example:3080")
          (dsh-emacs--server-auth-cookie "dsh-auth-RPC=cached")
          (url-request-noninteractive nil)
          (url-registered-auth-schemes nil)
          (response nil)
          (pending nil)
          (request-headers nil)
          (inhibited-cookies nil)
          (challenges nil)
          (result 'not-called))
      (url-register-auth-scheme "basic" nil 4)
      (cl-labels
          ((make-response (url)
             (setq request-headers url-request-extra-headers
                   response (generate-new-buffer " *dsh-rpc-auth-test*"))
             (with-current-buffer response
               (setq-local url-http-response-status status)
               (setq-local url-current-object (url-generic-parse-url url))
               (setq-local url-http-extra-headers request-headers)
               (setq-local url-http-noninteractive url-request-noninteractive)
               (insert (format "HTTP/1.1 %d Test\n\n" status)
                       (if (= status 200)
                           "{\"result\":{\"ok\":true,\"value\":\"accepted\"}}"
                         "Authentication failed")))
             response)
           (authenticate ()
             (when (= status 401)
               (with-current-buffer response
                 (url-http-handle-authentication nil)))))
        (cl-letf (((symbol-function 'url-get-authentication)
                   (lambda (_url _realm type prompt &rest _)
                     (push (list type prompt (url-interactive-p)) challenges)
                     nil))
                  ((symbol-function 'url-retrieve-synchronously)
                   (lambda (url &optional _silent inhibit-cookies &rest _)
                     (setq inhibited-cookies inhibit-cookies)
                     (make-response url)
                     (authenticate)
                     response))
                  ((symbol-function 'url-retrieve)
                   (lambda (url callback &optional _args _silent inhibit-cookies)
                     (setq pending callback
                           inhibited-cookies inhibit-cookies)
                     (make-response url))))
          (unwind-protect
              (progn
                (if (eq mode 'sync)
                    (setq result (dsh-emacs--rpc-request "session/list" nil))
                  (dsh-emacs--rpc-async
                   "session/list" nil
                   (lambda (ok value) (setq result (cons ok value))))
                  (authenticate)
                  (with-current-buffer response
                    (funcall pending (when (>= status 400)
                                       (list :error (list 'error 'http status))))))
                (dsh-test-assert (format "rpc-%s-http-%s-auth-result" mode status)
                  (equal result (if (= status 200) '(t . "accepted") '(nil)))
                  (equal (cdr (assoc "Cookie" request-headers))
                         "dsh-auth-RPC=cached")
                  (eq inhibited-cookies t)
                  (equal challenges (and (= status 401) '(("basic" t nil))))
                  (equal dsh-emacs--server-auth-cookie
                         (unless (= status 401) "dsh-auth-RPC=cached"))
                  (not (buffer-live-p response))))
            (when (buffer-live-p response) (kill-buffer response))))))))

;; --- Test 93f2: --frame still produces unibyte when encoding a multibyte
;; payload in a unibyte buffer ---
;; Regression: `dsh-emacs-events--frame' used to encode with
;; `(encode-coding-string p 'utf-8 t)', where `t' is nocopy; in a unibyte process
;; buffer the string from json-encode is multibyte, and nocopy encoding returns
;; multibyte as-is → the later aset mask then stuffs bytes into a multibyte
;; string and throws "Attempt to store non-ASCII char into multibyte string"
;; (connecting the core/chat streams crashes). Now encoding is followed by a
;; forced string-to-unibyte, producing a pure byte string whether or not the
;; current buffer is unibyte.
(with-temp-buffer
  (set-buffer-multibyte nil)          ; reproduce the process-buffer environment
  (let ((payload (string-make-multibyte
                  "{\"type\":\"open\",\"streamId\":\"s1\",\"x\":\"中文\"}")))
    (when (multibyte-string-p payload)
      (let ((frame (condition-case err
                       (dsh-emacs-events--frame 1 payload)
                     (error (list :err err)))))
        (dsh-test-assert "frame-encodes-multibyte-payload-in-unibyte-buffer"
          (and (not (and (consp frame) (eq (car frame) :err)))
               (not (multibyte-string-p frame))
               (stringp frame)))))))

;; --- Test 94: slash command parsing (admission syntax matching the dsh
;; registry) ---
(let ((cases '(("/compact" "compact" "")
               ("/goal set x" "goal" " set x")
               ("/plan\toff" "plan" "\toff")       ; TAB boundaries are separators too
               ("  /compact  " "compact" "")
               ("/goal-set_x run" "goal-set_x" " run")
               ("/compactx" "compactx" "")))
      (ok t))
  (dolist (c cases)
    (let ((parsed (dsh-emacs-command-parse (car c))))
      (unless (and (string= (car parsed) (nth 1 c))
                   (string= (cdr parsed) (nth 2 c)))
        (setq ok nil))))
  (when ok (dsh-test-pass "command-parse-admits-slash-lines")))

(let ((not-commands '("/" "" "hello" "/usr/local" "/Compact" "//" "/2025"
                      "http://x" nil)))
  (when (cl-every (lambda (s) (null (dsh-emacs-command-parse s)))
                  not-commands)
    (dsh-test-pass "command-parse-rejects-non-commands")))

;; --- Test 95: commands.execute payload and on-done semantics ---
(let ((calls nil)
      (done nil))
  (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
             (lambda (method params cb)
               (push (list method params) calls)
               (funcall cb t '((commandId . "c1")
                               (result . ((kind . "success")
                                          (text . "ok"))))))))
    (dsh-emacs-command-execute
     "sess-exec" "/compact" nil
     (lambda (ok ex _err) (setq done (list ok ex))))
    (let* ((call (car calls))
           (params (cadr call))
           (submitted (cdr (assq 'submittedAttachments params))))
      (when (and (string= "commands/execute" (car call))
                 (string= "/compact" (cdr (assq 'line params)))
                 (string= "sess-exec" (cdr (assq 'agentId params)))
                 ;; 0.1.5 host field: `images' is rejected as an unexpected
                 ;; argument, and the value must be the tagged array.
                 (null (assq 'images params))
                 (vectorp submitted) (zerop (length submitted))
                 (equal done
                        (list t (dsh-protocol-command-execution--from-alist
                                 '((commandId . "c1")
                                   (result . ((kind . "success")
                                              (text . "ok"))))))))
        (dsh-test-pass "command-execute-wire-and-on-done")))))

(let ((missed nil))
  (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
             (lambda (_m _p cb) (funcall cb t nil))))
    (dsh-emacs-command-execute "s" "/nope" nil
                               (lambda (ok ex _err)
                                 (setq missed (list ok ex)))))
  (when (equal missed '(t nil))
    (dsh-test-pass "command-execute-miss-reports-nil")))

(let* ((att '((mediaType . "image/png") (data . "x")))
       (h (dsh-emacs-command--submitted-attachments att))
       (calls nil))
  ;; The helper takes ONE attachment alist (nil = none) and tags it.
  (dsh-test-assert "command-submitted-attachments-shape"
    (vectorp h)
    (= (length h) 1)
    (equal (aref h 0)
           '((type . "image") (mediaType . "image/png") (data . "x")))
    (equal (dsh-emacs-command--submitted-attachments nil) []))
  (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
             (lambda (m p cb)
               (push (list m p) calls)
               (funcall cb t nil))))
    (dsh-emacs-command-execute "s" "/goal" att nil))
  (let ((params (cadr (car calls))))
    (dsh-test-assert "command-execute-passes-attachments"
      (null (assq 'images params))
      (equal (append (cdr (assq 'submittedAttachments params)) nil)
             '(((type . "image") (mediaType . "image/png") (data . "x")))))))

;; --- Test 95b: permissionPresets/catalog parses and the switch runs the
;; `/permission' slash command (dsh 0.1.6; the namespace has no write Remote) ---
(let* ((catalog (dsh-protocol-permission-catalog--from-alist
                 '((options . [((value . "workspace-write")
                                (name . "Workspace write")
                                (description . "Write inside the workspace"))
                               ((value . "danger-full-access")
                                (name . "Full access"))]))))
       (options (dsh-protocol-permission-catalog-options catalog)))
  (dsh-test-assert "permission-catalog-parses-options"
    (= 2 (length options))
    (equal "workspace-write" (dsh-protocol-permission-option-value (car options)))
    (equal "Workspace write" (dsh-protocol-permission-option-name (car options)))
    (equal "Write inside the workspace"
           (dsh-protocol-permission-option-description (car options)))
    (null (dsh-protocol-permission-option-description (cadr options)))))

(let ((offered nil)
      (executed nil))
  (cl-letf (((symbol-function 'completing-read)
             (lambda (_prompt collection &rest _args)
               (setq offered (mapcar #'car collection))
               (caar collection)))
            ((symbol-function 'dsh-emacs-command-execute)
             (lambda (session-id line _attachment _on-done)
               (setq executed (list session-id line)))))
    (dsh-emacs--set-permission-prompt
     "sess-perm"
     '((options . [((value . "workspace-write") (name . "Workspace write")
                    (description . "Write inside the workspace"))
                   ((value . "danger-full-access") (name . "Full access"))]))))
  (dsh-test-assert "permission-prompt-offers-catalog-options"
    (= 2 (length offered))
    (string-match-p "Workspace write" (car offered))
    (string-match-p "Write inside the workspace" (car offered))
    ;; A missing description keeps the bare label (no separator/dash).
    (equal "Full access" (cadr offered)))
  (dsh-test-assert "permission-prompt-runs-permission-command"
    (equal '("sess-perm" "/permission workspace-write") executed)))

(let ((methods nil)
      (executed nil)
      (buf (generate-new-buffer " *dsh-permission-cmd*")))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (setq-local dsh-emacs--buffer-session "sess-perm")
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (method _params cb)
                     (push method methods)
                     (funcall cb t '((options . [((value . "workspace-write")
                                                  (name . "Workspace write"))])))))
                  ((symbol-function 'completing-read)
                   (lambda (_prompt collection &rest _args) (caar collection)))
                  ((symbol-function 'dsh-emacs-command-execute)
                   (lambda (_session-id line _attachment _on-done)
                     (setq executed line))))
          (dsh-emacs-set-permission)))
    (when (buffer-live-p buf) (kill-buffer buf)))
  (dsh-test-assert "permission-set-fetches-catalog-and-switches"
    (equal '("permissionPresets/catalog") methods)
    (equal "/permission workspace-write" executed)))

;; --- Test 96: submit-prompt dispatches slash commands ---
(let ((buf (generate-new-buffer " *dsh-slash-submit*"))
      (calls nil))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (setq dsh-emacs--current-session "sess-slash")
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (method params cb)
                     (push (list method params) calls)
                     (if (string= method "commands/execute")
                         (let ((line (cdr (assq 'line params))))
                           (if (equal line "/frobnicate")
                               (funcall cb t nil)
                             (funcall cb t '((commandId . "c9")
                                             (result . ((kind . "success")
                                                        (text . "done")))))))
                       (funcall cb t '((accepted . t))))))
                  ((symbol-function 'dsh-emacs--ml-busy-set)
                   (lambda (&rest _) nil))
                  ((symbol-function 'dsh-emacs-events-connect)
                   (lambda (_c) nil))
                  ((symbol-function 'dsh-emacs-events--watchdog-start)
                   (lambda () nil)))
          ;; Plain message → session/prompt (the original path is unchanged)
          (dsh-emacs--submit-prompt "hi")
          (let* ((call (car calls))
                 (content (cdr (assq 'content
                                     (cdr (assq 'request (cadr call))))))
                 (part (and content (aref content 0))))
            (when (and (string= "session/prompt" (car call))
                       (string= "hi" (cdr (assq 'text part))))
              (dsh-test-pass "submit-plain-sends-session-prompt")))
          ;; Known command → commands.execute, and session/prompt is no longer sent
          (setq calls nil)
          (dsh-emacs--submit-prompt "/compact")
          (let* ((call (car calls))
                 (params (cadr call)))
            (when (and (string= "commands/execute" (car call))
                       (string= "/compact" (cdr (assq 'line params)))
                       ;; Attachment-less command still carries the required
                       ;; 0.1.5 field as an empty tagged array.
                       (equal (cdr (assq 'submittedAttachments params)) [])
                       (null (assq 'images params))
                       (= (length calls) 1))
              (dsh-test-pass "submit-slash-routes-to-execute")))
          ;; Slash command with attachments: the attachments go into the tagged
          ;; `submittedAttachments', not into session/prompt's content (the caption text
          ;; still stays in the command line).
          (setq calls nil)
          (dsh-emacs--submit-prompt "/compact"
                                    '((mediaType . "image/png") (data . "eA==")))
          (let* ((call (car calls))
                 (params (cadr call)))
            (dsh-test-assert "submit-slash-carries-tagged-attachment"
              (string= "commands/execute" (car call))
              (= (length calls) 1)
              (equal (append (cdr (assq 'submittedAttachments params)) nil)
                     '(((type . "image") (mediaType . "image/png")
                        (data . "eA=="))))))
          ;; Not found in the registry → falls back to a plain message (same semantics as
          ;; the browser)
          (setq calls nil)
          (dsh-emacs--submit-prompt "/frobnicate")
          (let* ((prompt-call (car calls))
                 (content (cdr (assq 'content
                                     (cdr (assq 'request (cadr prompt-call))))))
                 (part (and content (aref content 0))))
            (when (and (= (length calls) 2)
                       (string= "session/prompt" (car prompt-call))
                       (string= "commands/execute" (car (cadr calls)))
                       (string= "/frobnicate" (cdr (assq 'text part))))
              (dsh-test-pass "submit-unknown-slash-falls-back-to-plain")))))
    (kill-buffer buf)))

;; --- Test 96b: a slash submit clears the input area immediately (without
;; waiting for the RPC round trip) ---
(let ((buf (generate-new-buffer " *dsh-slash-clear*"))
      (old-hist dsh-emacs--input-history)
      (old-pos dsh-emacs--input-history-pos))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (setq dsh-emacs--current-session "sess-clear")
        (setq dsh-emacs--input-history-pos 0)   ; pretend to be in browse state
        (goto-char (point-max))
        (insert "/compact ")
        ;; the rpc never calls back (the real url-retrieve round trip never returns /
        ;; offline): the input must still be cleared and the history recorded ---
        ;; clearing no longer depends on the callback.
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (_m _p _cb) nil)))
          (dsh-emacs--submit-prompt (dsh-emacs--get-input)))
        (when (and (string-empty-p (dsh-emacs--get-input))
                   (string= "/compact " (car dsh-emacs--input-history))
                   (null dsh-emacs--input-history-pos))
          (dsh-test-pass "submit-slash-clears-and-records-immediately")))
    (kill-buffer buf)
    (setq dsh-emacs--input-history old-hist
          dsh-emacs--input-history-pos old-pos)))

;; --- Test 96c: slash transport failure → restore the original text (and do not
;; overwrite new input) ---
(let ((buf (generate-new-buffer " *dsh-slash-fail*"))
      (captured nil)
      (old-hist dsh-emacs--input-history)
      (old-pos dsh-emacs--input-history-pos))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (setq dsh-emacs--current-session "sess-fail")
        (goto-char (point-max))
        (insert "/compact")
        ;; Transport failure (ok=nil): the input area is still empty → restore the
        ;; original text for an easy retry
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (_m _p cb) (setq captured cb)
                     (funcall cb nil "boom"))))
          (dsh-emacs--submit-prompt "/compact"))
        (when (string= "/compact" (dsh-emacs--get-input))
          (dsh-test-pass "submit-slash-restores-on-transport-failure"))
        ;; The callback arrives late, after the user typed new content → do not overwrite
        (goto-char (point-max))
        (insert "/new-typed")
        (funcall captured nil "boom")
        (when (string-match-p "new-typed" (dsh-emacs--get-input))
          (dsh-test-pass "submit-slash-failure-keeps-new-typing")))
    (kill-buffer buf)
    (setq dsh-emacs--input-history old-hist
          dsh-emacs--input-history-pos old-pos)))

;; --- Test 96d: slash submit history is recorded only once (both the miss
;; fallback and the accepted path) ---
(let ((buf (generate-new-buffer " *dsh-slash-hist*"))
      (old-hist dsh-emacs--input-history)
      (old-pos dsh-emacs--input-history-pos))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (setq dsh-emacs--current-session "sess-hist")
        ;; Not found in the registry → falls back to a plain message: history is recorded
        ;; once only, at submit time
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (method _p cb)
                     (if (string= method "commands/execute")
                         (funcall cb t nil)
                       (funcall cb t '((accepted . t)))))))
          (dsh-emacs--submit-prompt "/frobnicate"))
        (when (= 1 (cl-count "/frobnicate" dsh-emacs--input-history
                             :test #'string=))
          (dsh-test-pass "submit-slash-miss-records-history-once"))
        (setq dsh-emacs--input-history nil)
        ;; Accepted: history is likewise recorded only once (at submit time)
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (method _p cb)
                     (if (string= method "commands/execute")
                         (funcall cb t '((commandId . "c9")
                                         (result . ((kind . "success")))))
                       (funcall cb t '((accepted . t)))))))
          (dsh-emacs--submit-prompt "/compact"))
        (when (= 1 (cl-count "/compact" dsh-emacs--input-history
                             :test #'string=))
          (dsh-test-pass "submit-slash-admit-records-history-once")))
    (kill-buffer buf)
    (setq dsh-emacs--input-history old-hist
          dsh-emacs--input-history-pos old-pos)))

;; --- Test 96e: a `!' line ⇒ local execution (bypassing session/prompt /
;; commands/execute) ---
(let ((buf (generate-new-buffer " *dsh-shell-submit*"))
      (runs nil)
      (calls nil)
      (parse-count 0)
      (parse-function (symbol-function 'dsh-emacs-shell-parse))
      (old-hist dsh-emacs--input-history)
      (old-pos dsh-emacs--input-history-pos))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (setq dsh-emacs--current-session "sess-shell")
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (method params cb)
                     (push (list method params) calls)
                     (funcall cb t '((accepted . t)))))
                  ((symbol-function 'dsh-emacs--ml-busy-set)
                   (lambda (&rest _) nil))
                  ((symbol-function 'dsh-emacs-events-connect)
                   (lambda (_c) nil))
                  ((symbol-function 'dsh-emacs-events--watchdog-start)
                   (lambda () nil))
                  ((symbol-function 'dsh-emacs-shell-parse)
                   (lambda (line)
                     (setq parse-count (1+ parse-count))
                     (funcall parse-function line)))
                  ((symbol-function 'dsh-emacs-shell-run)
                   (lambda (command buffer)
                     (push (list command buffer) runs))))
          ;; `!command' line → run locally, zero RPC; `! <cmd>' is accepted too
          (dsh-emacs--submit-prompt "!echo hi")
          (dsh-test-assert "submit-shell-runs-locally"
            (equal "echo hi" (caar runs))
            (eq buf (nth 1 (car runs)))
            (= parse-count 1)
            (null calls))
          (dsh-test-assert "submit-shell-records-history-once"
            (= 1 (cl-count "!echo hi" dsh-emacs--input-history
                           :test #'string=)))
          (setq calls nil runs nil parse-count 0)
          (dsh-emacs--replace-input "! ls -la")
          (dsh-emacs-send-or-stop)
          (dsh-test-assert "interactive-shell-tolerates-space-and-parses-once"
            (equal "ls -la" (caar runs))
            (= parse-count 1)
            (equal "! ls -la" (car dsh-emacs--input-history))
            (null calls))
          ;; A bare `!' is a plain message (no command to execute)
          (setq calls nil runs nil dsh-emacs--input-history nil)
          (dsh-emacs--submit-prompt "!")
          (dsh-test-assert "submit-bare-bang-is-plain-message"
            (null runs)
            (equal "session/prompt" (caar calls)))
          ;; Submitting while busy (queue/steer) also executes locally and does not enter
          ;; the inbox
          (setq calls nil runs nil)
          (cl-letf (((symbol-function 'dsh-emacs--busy-p)
                     (lambda (&rest _) t)))
            (dsh-emacs--submit-prompt "!ls" nil 'queue))
          (dsh-test-assert "submit-shell-runs-while-busy"
            (equal "ls" (caar runs))
            (null calls))))
    (kill-buffer buf)
    (setq dsh-emacs--input-history old-hist
          dsh-emacs--input-history-pos old-pos)))

;; A ! caption with attachments is still model input; idle, queued, and steer all
;; keep the images.
(dolist (mode '(nil queue steer))
  (with-temp-buffer
    (dsh-emacs-mode)
    (let ((dsh-emacs--current-session "shell-caption")
          (images '(((mediaType . "image/png") (data . "cGljdHVyZQ==")
                     (name . "picture.png"))))
          calls runs)
      (cl-letf (((symbol-function 'dsh-emacs--busy-p) (lambda () (not (null mode))))
                ((symbol-function 'dsh-emacs--rpc-async)
                 (lambda (method params _cb) (push (list method params) calls)))
                ((symbol-function 'dsh-emacs-shell-run)
                 (lambda (&rest args) (push args runs))))
        (dsh-emacs--submit-prompt "!describe this image" images mode)
        (let ((request (alist-get 'request (cadar calls))))
          (dsh-test-assert
           (format "shell-caption-keeps-attachment-%s" mode)
           (null runs)
           (= (length calls) 1)
           (equal (caar calls) "session/prompt")
           (equal (alist-get 'mode request) (if (eq mode 'steer) "steer" "queue"))
           (equal (alist-get 'content request)
                  [((type . "text") (text . "!describe this image"))
                   ((type . "image") (mediaType . "image/png")
                    (data . "cGljdHVyZQ==") (name . "picture.png"))])))))))

;; A refused confirmation keeps the draft, history, and old process; an accepted
;; confirmation and the default no-confirm path submit only once.
(dolist (answer '(decline accept immediate))
  (with-temp-buffer
    (dsh-emacs-mode)
    (let ((dsh-emacs-shell-require-confirm (not (eq answer 'immediate)))
          (dsh-emacs--input-history '("older"))
          (dsh-emacs--input-history-pos 1)
          (dsh-emacs--input-history-pending "saved draft")
          prompts runs killed)
      (dsh-emacs--replace-input "!printf accepted")
      (cl-letf (((symbol-function 'y-or-n-p)
                 (lambda (prompt)
                   (push prompt prompts)
                   (eq answer 'accept)))
                ((symbol-function 'dsh-emacs-shell-run)
                 (lambda (command buffer) (push (list command buffer) runs)))
                ((symbol-function 'dsh-emacs-shell--kill-previous)
                 (lambda () (setq killed t))))
        (dsh-emacs-shell-submit (dsh-emacs--get-input) "printf accepted")
        (dsh-test-assert
         (format "shell-confirm-prompt-%s" answer)
         (equal prompts (unless (eq answer 'immediate)
                          '("Run shell command: printf accepted? "))))
        (if (eq answer 'decline)
            (dsh-test-assert
             "shell-confirm-decline-preserves-input-and-history"
             (equal (dsh-emacs--get-input) "!printf accepted")
             (equal dsh-emacs--input-history '("older"))
             (equal dsh-emacs--input-history-pos 1)
             (equal dsh-emacs--input-history-pending "saved draft")
             (null runs)
             (null killed))
          (dsh-test-assert
           (format "shell-confirm-submits-once-%s" answer)
           (equal runs (list (list "printf accepted" (current-buffer))))
           (equal (dsh-emacs--get-input) "")
           (equal dsh-emacs--input-history '("!printf accepted" "older"))
           (null dsh-emacs--input-history-pos)
           (null dsh-emacs--input-history-pending)
           killed))))))

;; The interactive entry point must recognize local commands before the server
;; probe and the busy-stop branch.
(let ((dsh-emacs-busy-enter-behavior 'stop)
      (current-prefix-arg nil))
  (dolist (busy '(nil t))
    (let (runs calls failure)
      (cl-letf (((symbol-function 'dsh-emacs-server-ensure)
                 (lambda ()
                   (push 'server calls)
                   (user-error "Server offline")))
                ((symbol-function 'dsh-emacs--busy-p) (lambda () busy))
                ((symbol-function 'dsh-emacs--get-input)
                 (lambda () "!printf local"))
                ((symbol-function 'dsh-emacs-interrupt-turn)
                 (lambda () (push 'cancel calls)))
                ((symbol-function 'dsh-emacs-shell-submit)
                 (lambda (line command) (push (list line command) runs))))
        (condition-case err
            (dsh-emacs-send-or-stop)
          (error (setq failure err)))
        (dsh-test-assert (format "shell-interactive-offline-busy-%s" busy)
          (null failure)
          (null calls)
          (equal runs '(("!printf local" "printf local")))))))
  (let (runs calls)
    (cl-letf (((symbol-function 'dsh-emacs-server-ensure)
               (lambda () (push 'server calls)))
              ((symbol-function 'dsh-emacs--busy-p) (lambda () t))
              ((symbol-function 'dsh-emacs--get-input)
               (lambda () "!printf local"))
              ((symbol-function 'dsh-emacs-interrupt-turn)
               (lambda () (push 'cancel calls)))
              ((symbol-function 'dsh-emacs-shell-submit)
               (lambda (line command) (push (list line command) runs))))
      (dsh-emacs-send-or-stop)
      (dsh-test-assert "shell-interactive-bypasses-busy-stop"
        (null calls)
        (equal runs '(("!printf local" "printf local")))))))

;; --- Test 96f: `!' line parsing (pure function) ---
(dsh-test-assert "shell-parse-admission"
  (equal "echo hi" (dsh-emacs-shell-parse "!echo hi"))
  (equal "ls -la" (dsh-emacs-shell-parse "!   ls -la"))
  (equal "ls -la" (dsh-emacs-shell-parse " ! ls -la  "))
  (equal "git status" (dsh-emacs-shell-parse "!git status"))
  (null (dsh-emacs-shell-parse "!"))
  (null (dsh-emacs-shell-parse "!   "))
  (null (dsh-emacs-shell-parse "/compact"))
  (null (dsh-emacs-shell-parse "hi"))
  (null (dsh-emacs-shell-parse nil)))

(dsh-test-assert "shell-parse-preserves-multiline-command"
  (equal "printf first\nprintf second"
         (dsh-emacs-shell-parse "!printf first\nprintf second"))
  (equal "cat <<'EOF'\n  indented body\nEOF"
         (dsh-emacs-shell-parse "! cat <<'EOF'\n  indented body\nEOF")))

;; --- Test 96g: real async execution of a `!' line: exit code + merged
;; stdout/stderr rendering ---
(let ((buf (generate-new-buffer " *dsh-shell-run*"))
      (done nil))
  (unwind-protect
      (progn
        (with-current-buffer buf
          (dsh-emacs-mode)
          (setq dsh-emacs--current-session "sess-run"))
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (_m _p _cb) nil))  ; mask a leftover directory-prefetch timer
                  ((symbol-function 'dsh-emacs--rpc-request)
                   (lambda (&rest _) (cons nil nil)))
                  ((symbol-function 'dsh-emacs-render-shell-start)
                   (lambda (_command) "test-shell-id"))
                  ((symbol-function 'dsh-emacs-render-shell-done)
                   (lambda (id ok exit-code signal output)
                     (setq done (list id ok exit-code signal output)))))
          ;; exit 3 → ok=nil; stdout/stderr merged into the same body
          (let* ((proc (with-current-buffer buf
                         (dsh-emacs-shell-run
                          (dsh-emacs-shell-parse
                           (concat "!printf SHELLOK\ncat <<'EOF'\nSHELLDOC\n"
                                   "EOF\nprintf SHELLERR >&2\nexit 3"))
                          buf)))
                 (deadline (time-add (current-time) (seconds-to-time 8))))
            (while (and (null done)
                        (time-less-p (current-time) deadline))
              (accept-process-output proc 0.2))
            (dsh-test-assert "shell-run-finished-output-and-exit"
              (equal "test-shell-id" (car done))
              (null (nth 1 done))
              (equal 3 (nth 2 done))
              (null (nth 3 done))
              (equal "SHELLOKSHELLDOC\nSHELLERR" (nth 4 done))))
          ;; exit 0 + very long output → truncated (max-output is bound before the run)
          (let ((dsh-emacs-shell-max-output 8))
            (setq done nil)
            (let* ((proc2 (with-current-buffer buf
                            (dsh-emacs-shell-run "printf abcdefghij" buf)))
                   (deadline (time-add (current-time) (seconds-to-time 8))))
              (while (and (null done)
                          (time-less-p (current-time) deadline))
                (accept-process-output proc2 0.2))
              (dsh-test-assert "shell-run-success-truncates-output"
                (eq t (nth 1 done))
                (equal 0 (nth 2 done))
                (and (string-prefix-p "abcdefgh" (nth 4 done))
                     (string-match-p "truncated" (nth 4 done))))))))
    (when (buffer-live-p buf) (kill-buffer buf))))

;; stop/continue notifications do not mean exit: output, timeout, and tracking
;; are kept until it actually finishes.
(with-temp-buffer
  (let ((shell-file-name "/bin/sh")
        (dsh-emacs-shell-null-stdin nil)
        (dsh-emacs-shell-timeout 60)
        proc out-buffer timer done)
    (unwind-protect
        (cl-letf (((symbol-function 'dsh-emacs-render-shell-start)
                   (lambda (_) "id-stop-resume"))
                  ((symbol-function 'dsh-emacs-render-shell-done)
                   (lambda (&rest args) (push args done))))
          (setq proc (dsh-emacs-shell-run "printf before; kill -STOP $$; cat")
                out-buffer (process-buffer proc)
                timer (process-get proc 'dsh-emacs-shell-timer))
          (let ((deadline (+ (float-time) 5)))
            (while (and (eq (process-status proc) 'run)
                        (< (float-time) deadline))
              (accept-process-output proc 0.1)))
          (dsh-test-assert "shell-stopped-process-retains-resources"
            (eq (process-status proc) 'stop)
            (null done)
            (eq proc (cdr (assoc "id-stop-resume" dsh-emacs--shell-procs)))
            (buffer-live-p out-buffer)
            (memq timer timer-list))
          (continue-process proc)
          (accept-process-output proc 0.1)
          (dsh-test-assert "shell-continued-process-retains-resources"
            (eq (process-status proc) 'run)
            (null done)
            (eq proc (cdr (assoc "id-stop-resume" dsh-emacs--shell-procs)))
            (buffer-live-p out-buffer)
            (memq timer timer-list))
          (process-send-string proc "after")
          (process-send-eof proc)
          (let ((deadline (+ (float-time) 5)))
            (while (and (process-live-p proc) (< (float-time) deadline))
              (accept-process-output proc 0.1)))
          (dsh-test-assert "shell-resumed-process-finishes-once"
            (equal done '(("id-stop-resume" t 0 nil "beforeafter")))
            (null dsh-emacs--shell-procs)
            (not (buffer-live-p out-buffer))
            (not (memq timer timer-list))))
      (when (and proc (process-live-p proc)) (delete-process proc))
      (when timer (cancel-timer timer))
      (when (buffer-live-p out-buffer) (kill-buffer out-buffer)))))

;; --- Test 96h: `!' line rendering (start → done status coloring + body) ---
(let ((buf (generate-new-buffer " *dsh-shell-render*")))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (dsh-emacs-modeline-setup)
        (let* ((id (dsh-emacs-render-shell-start "echo hello"))
               (entry (gethash id dsh-emacs--command-blocks))
               (block (and entry (dsh-emacs-ui-find-block (nth 0 entry)
                                                          (nth 1 entry)))))
          ;; pending coloring rides the snapshot's :header-face (no longer a separate
          ;; restyle channel), consistent with command/run rows; a pending row has no
          ;; body,
          ;; so the header is the whole block.
          (dsh-test-assert "shell-row-tints-pending-header"
            (and block
                 (seq-every-p
                  (lambda (pos)
                    (memq 'dsh-emacs-tool-pending-face
                          (ensure-list (get-text-property pos 'face))))
                  (number-sequence (car block) (1- (cdr block))))))
          (dsh-emacs-render-shell-done id t 0 nil "nested output")
          (let ((text (buffer-substring-no-properties (point-min)
                                                      (point-max))))
            (dsh-test-assert "shell-row-renders-outcome"
              (string-match-p "echo hello" text)
              (string-match-p "✓ exit 0" text)
              (string-match-p "nested output" text)))
          (let* ((done-block (dsh-emacs-ui-find-block (nth 0 entry)
                                                      (nth 1 entry)))
                 (body-start (and done-block
                                  (save-excursion
                                    (goto-char (car done-block))
                                    (forward-line 1)
                                    (point)))))
            ;; Success coloring lands only on the header line and the output body must not
            ;; inherit it (the body must genuinely exist)
            (dsh-test-assert "shell-row-tints-success-header-only"
              (and done-block body-start (< body-start (cdr done-block))
                   (string-match-p "nested output"
                                   (buffer-substring-no-properties
                                    body-start (cdr done-block)))
                   (seq-every-p
                    (lambda (pos)
                      (memq 'dsh-emacs-tool-success-face
                            (dsh-test--faces-at pos)))
                    (number-sequence (car done-block)
                                     (save-excursion
                                       (goto-char (car done-block))
                                       (line-end-position))))
                   (seq-every-p
                    (lambda (pos)
                      (not (memq 'dsh-emacs-tool-success-face
                                 (dsh-test--faces-at pos))))
                    (number-sequence body-start (1- (cdr done-block))))))))
        ;; Failure path: non-zero exit → red status
        (let ((bad-id (dsh-emacs-render-shell-start "false")))
          (dsh-emacs-render-shell-done bad-id nil 1 nil "boom")
          (let ((text (buffer-substring-no-properties (point-min)
                                                      (point-max))))
            (dsh-test-assert "shell-row-renders-failure"
              (string-match-p "✗ exit 1" text)))))
    (kill-buffer buf)))

;; Both an explicit cancel command and kill-buffer after explicitly installing
;; cleanup hooks release the process resources.
(dolist (action '(interrupt kill-buffer))
  (let ((buf (generate-new-buffer " *dsh-shell-kill*"))
        (dsh-emacs-shell-null-stdin nil)
        (dsh-emacs-shell-timeout 60)
        proc out-buffer timer done)
    (unwind-protect
        (cl-letf (((symbol-function 'dsh-emacs-render-shell-start)
                   (lambda (_) "id-kill"))
                  ((symbol-function 'dsh-emacs-render-shell-done)
                   (lambda (&rest args) (push args done))))
          (with-current-buffer buf
            (dsh-emacs-shell-mode-setup)
            (setq proc (dsh-emacs-shell-run "cat")
                  out-buffer (process-buffer proc)
                  timer (process-get proc 'dsh-emacs-shell-timer)))
          (if (eq action 'interrupt)
              (with-current-buffer buf (dsh-emacs-shell-process-kill))
            (kill-buffer buf))
          (let ((deadline (+ (float-time) 3)))
            (while (and (null done) (< (float-time) deadline))
              (accept-process-output proc 0.1)))
          (dsh-test-assert
           (format "shell-process-cleanup-%s" action)
           (not (process-live-p proc))
           (not (buffer-live-p out-buffer))
           (not (memq timer timer-list))
           (= (length done) 1)
           (equal (caar done) "id-kill")
           (null (nth 1 (car done)))
           (null (nth 2 (car done)))
           (integerp (nth 3 (car done))))
          (when (eq action 'interrupt)
            (with-current-buffer buf
              (let (notice)
                (cl-letf (((symbol-function 'message)
                           (lambda (format-string &rest args)
                             (setq notice (apply #'format format-string args)))))
                  (dsh-emacs-shell-process-kill))
                (dsh-test-assert
                 "shell-process-kill-idle-reports-no-command"
                 (null dsh-emacs--shell-procs)
                 (equal notice "No running shell command in this buffer"))))))
      (when (and proc (process-live-p proc)) (delete-process proc))
      (when timer (cancel-timer timer))
      (when (buffer-live-p buf) (kill-buffer buf))
      (when (buffer-live-p out-buffer) (kill-buffer out-buffer)))))

;; Reopening the chat calls mode again; switching mode must also clean up the
;; local process first.
(dolist (mode '(dsh-emacs-mode fundamental-mode))
  (with-temp-buffer
    (dsh-emacs-mode)
    (let ((dsh-emacs-shell-null-stdin nil)
          (dsh-emacs-shell-timeout 60)
          proc out-buffer timer)
      (unwind-protect
          (cl-letf (((symbol-function 'dsh-emacs-render-shell-start)
                     (lambda (_) "id-mode-cleanup"))
                    ((symbol-function 'dsh-emacs-render-shell-done) #'ignore))
            (setq proc (dsh-emacs-shell-run "cat")
                  out-buffer (process-buffer proc)
                  timer (process-get proc 'dsh-emacs-shell-timer))
            (funcall mode)
            (dsh-test-assert (format "shell-mode-cleanup-%s" mode)
              (not (process-live-p proc))
              (not (buffer-live-p out-buffer))
              (not (memq timer timer-list))
              (null dsh-emacs--shell-procs)))
        (when (and proc (process-live-p proc)) (delete-process proc))
        (when timer (cancel-timer timer))
        (when (buffer-live-p out-buffer) (kill-buffer out-buffer))))))

;; Even if the exit notification arrives after the chat buffer is destroyed, the
;; process resources must be released.
(let ((buf (generate-new-buffer " *dsh-shell-dead-chat*"))
      (dsh-emacs-shell-null-stdin nil)
      (dsh-emacs-shell-timeout 60)
      proc out-buffer timer rendered)
  (unwind-protect
      (cl-letf (((symbol-function 'dsh-emacs-render-shell-start)
                 (lambda (_) "id-dead-chat"))
                ((symbol-function 'dsh-emacs-render-shell-done)
                 (lambda (&rest args) (push args rendered))))
        (setq proc (dsh-emacs-shell-run "cat" buf)
              out-buffer (process-buffer proc)
              timer (process-get proc 'dsh-emacs-shell-timer))
        (kill-buffer buf)
        (delete-process proc)
        (dsh-test-assert
         "shell-dead-chat-releases-process-resources"
         (not (buffer-live-p out-buffer))
         (not (memq timer timer-list))
         (null rendered)))
    (when (and proc (process-live-p proc)) (delete-process proc))
    (when timer (cancel-timer timer))
    (when (buffer-live-p buf) (kill-buffer buf))
    (when (buffer-live-p out-buffer) (kill-buffer out-buffer))))

;; --- Test 96i: closing stdin makes cat exit immediately, without relying on
;; shell redirection syntax ---
(dolist (shell (delete-dups
               (delq nil (mapcar #'executable-find
                                 '("sh" "bash" "zsh" "csh" "tcsh" "fish")))))
  (with-temp-buffer
    (let ((shell-file-name shell)
          (dsh-emacs-shell-null-stdin t)
          proc out-buffer done)
      (unwind-protect
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async) #'ignore)
                    ((symbol-function 'dsh-emacs--rpc-request)
                     (lambda (&rest _) (cons nil nil)))
                    ((symbol-function 'dsh-emacs-render-shell-start)
                     (lambda (_) "id-cat"))
                    ((symbol-function 'dsh-emacs-render-shell-done)
                     (lambda (&rest args) (setq done args))))
            (setq proc (dsh-emacs-shell-run "cat")
                  out-buffer (process-buffer proc))
            (let ((deadline (+ (float-time) 3)))
              (while (and (null done) (< (float-time) deadline))
                (accept-process-output proc 0.1)))
            (dsh-test-assert (format "shell-null-stdin-eof-%s" shell)
              (equal done '("id-cat" t 0 nil ""))
              (not (process-live-p proc))))
        (when (and proc (process-live-p proc)) (delete-process proc))
        (when (buffer-live-p out-buffer) (kill-buffer out-buffer))))))

;; --- Test 96j: submitting a new `!' command automatically terminates the
;; previous running command ---
(let ((buf (generate-new-buffer " *dsh-shell-multi*"))
      (done (make-hash-table :test 'equal))
      (next-id 0))
  (unwind-protect
      (progn
        (with-current-buffer buf
          (dsh-emacs-mode)
          (setq dsh-emacs--current-session "sess-multi"))
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (_m _p _cb) nil))  ; mask a leftover directory-prefetch timer
                  ((symbol-function 'dsh-emacs--rpc-request)
                   (lambda (&rest _) (cons nil nil)))
                  ((symbol-function 'dsh-emacs-render-shell-start)
                   (lambda (_command)
                     (prog1 (format "id-%d" next-id)
                       (setq next-id (1+ next-id)))))
                  ((symbol-function 'dsh-emacs-render-shell-done)
                   (lambda (id ok exit-code signal _output)
                     (puthash id (list ok exit-code signal) done))))
          (with-current-buffer buf
            (dsh-emacs--submit-prompt "!sleep 30"))
          (with-current-buffer buf
            (dsh-emacs--submit-prompt "!true"))
          (let ((deadline (time-add (current-time) (seconds-to-time 8))))
            (while (and (< (hash-table-count done) 2)
                        (time-less-p (current-time) deadline))
              (accept-process-output nil 0.2)))
          (dsh-test-assert "shell-new-command-stops-previous"
            (and (gethash "id-0" done) (null (car (gethash "id-0" done))))
            (equal (list t 0 nil) (gethash "id-1" done)))))
    (when (buffer-live-p buf) (kill-buffer buf))))

;; A nil command is a caller error and must be rejected before any submit side
;; effect.
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs--replace-input "!draft")
  (let ((dsh-emacs-shell-require-confirm t)
        (dsh-emacs--input-history '("older"))
        (dsh-emacs--input-history-pos 1)
        (dsh-emacs--input-history-pending "saved draft")
        effects failure)
    (cl-letf (((symbol-function 'y-or-n-p)
               (lambda (_) (push 'confirm effects) t))
              ((symbol-function 'dsh-emacs-shell--kill-previous)
               (lambda () (push 'kill effects)))
              ((symbol-function 'dsh-emacs-shell-run)
               (lambda (&rest _) (push 'run effects))))
      (condition-case err
          (dsh-emacs-shell-submit "!draft" nil)
        (error (setq failure err)))
      (dsh-test-assert
       "shell-submit-rejects-nil-before-side-effects"
       (equal failure '(error "Shell command must be non-nil"))
       (null effects)
       (equal (dsh-emacs--get-input) "!draft")
       (equal dsh-emacs--input-history '("older"))
       (equal dsh-emacs--input-history-pos 1)
       (equal dsh-emacs--input-history-pending "saved draft")))))

;; The timeout Custom type and both execution entry points reject non-positive
;; integers and do not clear the input.
(require 'wid-edit)
(let ((widget (widget-convert (get 'dsh-emacs-shell-timeout 'custom-type))))
  (dsh-test-assert
   "shell-timeout-custom-type"
   (widget-apply widget :match nil)
   (widget-apply widget :match 1)
   (not (widget-apply widget :match 0))
   (not (widget-apply widget :match -1))
   (not (widget-apply widget :match 1.5))))
(dolist (value '(0 -1 1.5 "invalid"))
  (dolist (entry '(dsh-emacs-shell-submit dsh-emacs-shell-run))
    (let ((dsh-emacs-shell-timeout value)
          effects rejected)
      (cl-letf (((symbol-function 'dsh-emacs--push-input-history)
                 (lambda (_) (push 'history effects)))
                ((symbol-function 'dsh-emacs--clear-input)
                 (lambda () (push 'clear effects)))
                ((symbol-function 'dsh-emacs-shell--kill-previous)
                 (lambda () (push 'kill effects)))
                ((symbol-function 'dsh-emacs-render-shell-start)
                 (lambda (_) (push 'row effects) "id-invalid-timeout"))
                ((symbol-function 'dsh-emacs-render-shell-done)
                 (lambda (&rest _) (push 'done effects)))
                ((symbol-function 'make-process)
                 (lambda (&rest _) (push 'spawn effects) (error "Unexpected spawn"))))
        (condition-case nil
            (if (eq entry 'dsh-emacs-shell-submit)
                (dsh-emacs-shell-submit "!true" "true")
              (dsh-emacs-shell-run "true"))
          (user-error (setq rejected t)))
        (dsh-test-assert
         (format "shell-invalid-timeout-%s-%s" entry value)
         rejected
         (null effects))))))

;; --- Test 96k: timeout force-terminates (dsh-emacs-shell-timeout) ---
(let ((buf (generate-new-buffer " *dsh-shell-timeout*"))
      (done nil))
  (unwind-protect
      (progn
        (with-current-buffer buf
          (dsh-emacs-mode)
          (setq dsh-emacs--current-session "sess-timeout"))
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (_m _p _cb) nil))  ; mask a leftover directory-prefetch timer
                  ((symbol-function 'dsh-emacs--rpc-request)
                   (lambda (&rest _) (cons nil nil)))
                  ((symbol-function 'dsh-emacs-render-shell-start)
                   (lambda (_command) "id-timeout"))
                  ((symbol-function 'dsh-emacs-render-shell-done)
                   (lambda (id ok exit-code signal output)
                     (setq done (list id ok exit-code signal output)))))
          (let* ((dsh-emacs-shell-timeout 1)
                 (proc (dsh-emacs-shell-run "sleep 30" buf))
                 (deadline (time-add (current-time) (seconds-to-time 10))))
            (while (and (null done)
                        (time-less-p (current-time) deadline))
              (accept-process-output proc 0.2))
            (dsh-test-assert "shell-timeout-kills-and-notes"
              (null (nth 1 done))
              (string-match-p "timed out after 1 seconds"
                              (nth 4 done))))))
    (when (buffer-live-p buf) (kill-buffer buf))))

(let* ((cmd (dsh-protocol-command--from-alist
             '((name . "compact") (description . "Compact history")))))
  (when (and (string= "compact" (dsh-protocol-command-name cmd))
             (string= "Compact history"
                      (dsh-protocol-command-description cmd))
             (null (dsh-protocol-command-input cmd)))
    (dsh-test-pass "command-from-alist-bare")))

(let* ((cmd (dsh-protocol-command--from-alist
             '((name . "goal") (description . "goal ops")
               (input . ((hint . "[<objective>]") (attachments . t))))))
       (input (dsh-protocol-command-input cmd)))
  (when (and (string= "[<objective>]" (dsh-protocol-command-input-hint input))
             (dsh-protocol-command-input-attachments input))
    (dsh-test-pass "command-from-alist-with-input")))

(let ((sid "sess-cat")
      (rpc-calls 0)
      (old dsh-emacs--command-catalogs))
  (unwind-protect
      (cl-letf (((symbol-function 'dsh-emacs--rpc-request)
                 (lambda (_m _p)
                   (setq rpc-calls (1+ rpc-calls))
                   (cons t [((name . "compact") (description . "c"))
                            ((name . "goal") (description . "g"))]))))
        (let ((items (dsh-emacs-command-catalog-sync sid))
              (again (dsh-emacs-command-catalog-sync sid)))
          (when (and (= (length items) 2)
                     (string= "goal"
                              (dsh-protocol-command-name (cadr items)))
                     (= rpc-calls 1)
                     (equal again items))
            (dsh-test-pass "command-catalog-sync-caches"))))
    (setq dsh-emacs--command-catalogs old)))

(let ((sid "sess-async")
      (fetched nil)
      (old dsh-emacs--command-catalogs))
  (unwind-protect
      (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                 (lambda (_m _p cb)
                   (funcall cb t [((name . "plan") (description . "p"))]))))
        (dsh-emacs-command-catalog-fetch sid
                                         (lambda (items)
                                           (setq fetched items)))
        (when (and fetched
                   (string= "plan"
                            (dsh-protocol-command-name (car fetched))))
          (dsh-test-pass "command-catalog-fetch-async")))
    (setq dsh-emacs--command-catalogs old)))

;; After several fetches for the same session, the cache may hold only one entry
;; for that session (assoc-delete-all fix: with assq-delete-all the string keys
;; compare by eq, so old entries are never deleted and the alist grows without
;; bound)
(let ((sid "sess-dedup")
      (old dsh-emacs--command-catalogs))
  (unwind-protect
      (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                 (lambda (_m _p cb)
                   (funcall cb t [((name . "a") (description . "A"))]))))
        ;; Two independent fetches (the previous one already finished, inflight cleared)
        (dsh-emacs-command-catalog-fetch sid)
        (dsh-emacs-command-catalog-fetch sid)
        (let* ((entries (cl-remove-if-not
                         (lambda (e) (string= sid (car e)))
                         dsh-emacs--command-catalogs)))
          (when (= (length entries) 1)
            (dsh-test-pass "command-catalog-single-entry-per-session"))))
    (setq dsh-emacs--command-catalogs old)))

;; Idle prefetch when a session is opened: schedule an idle timer; do not
;; schedule again when the directory is already cached
(let ((sid "sess-prefetch")
      (old dsh-emacs--command-catalogs)
      (old-pref dsh-emacs-command-prefetch)
      (old-delay dsh-emacs-command-prefetch-delay)
      (timers nil))
  (unwind-protect
      (progn
        (setq dsh-emacs-command-prefetch t
              dsh-emacs-command-prefetch-delay 0.05)
        (let ((timer (dsh-emacs-command-catalog-prefetch sid)))
          (when timer (push timer timers))
          (when (timerp timer)
            (dsh-test-pass "command-catalog-prefetch-schedules-idle")))
        ;; Already cached → the guard refuses to schedule again
        (dsh-emacs-command--cache-catalog
         sid (list (dsh-protocol-command--from-alist '((name . "x")))))
        (let ((before (length timer-list)))
          (dsh-emacs-command-catalog-prefetch sid)
          (when (= (length timer-list) before)
            (dsh-test-pass "command-catalog-prefetch-skips-when-cached"))))
    (mapc #'cancel-timer timers)
    (setq dsh-emacs--command-catalogs old
          dsh-emacs-command-prefetch old-pref
          dsh-emacs-command-prefetch-delay old-delay)))

;; Manual refresh: drop the stale cache and refetch from the server
(let ((sid "sess-refresh")
      (calls 0)
      (old dsh-emacs--command-catalogs)
      (old-inflight dsh-emacs--command-fetch-inflight))
  (unwind-protect
      (progn
        ;; Pre-seed one stale cache entry
        (dsh-emacs-command--cache-catalog
         sid (list (dsh-protocol-command--from-alist '((name . "old")))))
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (_m _p cb)
                     (setq calls (1+ calls))
                     (funcall cb t [((name . "new") (description . "N"))]))))
          (dsh-emacs-command-catalog-refresh sid)
          (let ((items (dsh-emacs-command-catalog sid)))
            (when (and (= calls 1)
                       items
                       (string= "new" (dsh-protocol-command-name (car items))))
              (dsh-test-pass "command-catalog-refresh-replaces-cache")))))
    (setq dsh-emacs--command-catalogs old
          dsh-emacs--command-fetch-inflight old-inflight)))

;; --- Test 98: command/run + command/done rendering ---
(let ((buf (generate-new-buffer " *dsh-cmd-render*")))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (let* ((run-seq (dsh-emacs-render-event
                         '((type . "command/run") (seq . 10)
                           (data . ((commandId . "c1") (name . "goal")
                                    (args . " set x"))))))
               (done-seq (dsh-emacs-render-event
                          '((type . "command/done") (seq . 11)
                            (data . ((commandId . "c1")
                                     (kind . "success")
                                     (text . "goal snapshot"))))))
               (txt (buffer-string))
               (above-input (buffer-substring (point-min)
                                              dsh-emacs--input-marker)))
          (let* ((ns (dsh-emacs-render--make-namespace))
                 (block-id "cmd-c1")
                 (blk (dsh-emacs-ui-find-block ns block-id))
                 (state (and blk (get-text-property (car blk) 'dsh-emacs-ui-state))))
            (when (and (= run-seq 10) (= done-seq 11)
                       ;; label = "goal" (args stripped, no / prefix) + short status
                       (string-match-p "goal" txt)
                       (string-match-p "done" txt)
                       ;; The result is folded into the body: not shown in the buffer, but
                       ;; kept in the
                       ;; fragment state
                       (not (string-match-p "goal snapshot" txt))
                       state
                       (equal (map-elt state :body) "goal snapshot")
                       (map-elt state :collapsed)
                       ;; The node must be inserted above the input area (the ❯ line), not
                       ;; at the end of
                       ;; the buffer
                       (string-match-p "goal" above-input)
                       (string-match-p "done" above-input))
              (dsh-test-pass "command-render-run-and-done"))))
        ;; The error kind renders too (● prefix + ✗ failed + body)
        (dsh-emacs-render-event
         '((type . "command/run") (seq . 12)
           (data . ((commandId . "c2") (name . "permission")
                    (args . "")))))
        (dsh-emacs-render-event
         '((type . "command/done") (seq . 13)
           (data . ((commandId . "c2") (kind . "error")
                    (text . "unknown preset")))))
        (let* ((txt (buffer-string))
               (ns (dsh-emacs-render--make-namespace))
               (block-id "cmd-c2")
               (blk (dsh-emacs-ui-find-block ns block-id))
               (state (and blk (get-text-property (car blk) 'dsh-emacs-ui-state))))
          (when (and (string-match-p "● permission" txt)
                     (string-match-p "failed" txt)
                     ;; Error results are likewise folded into the body
                     (not (string-match-p "unknown preset" txt))
                     state
                     (equal (map-elt state :body) "unknown preset")
                     (map-elt state :collapsed))
            (dsh-test-pass "command-render-error-kind"))))
    (kill-buffer buf)))

(when (and (string= "compact" (dsh-emacs-render-command-label "compact" ""))
           (string= "goal" (dsh-emacs-render-command-label
                             "goal" " set x"))
           (string= "goal" (dsh-emacs-render-command-label "goal" nil)))
  (dsh-test-pass "command-render-label"))

;; The result body of command/done must likewise not inherit success/error
;; coloring (after expanding, check the whole body; regression: the old
;; whole-block face turned the body green/red).
(dolist (case '(("ok1" "success" "compacted history" dsh-emacs-tool-success-face)
                ("bad1" "error" "unknown preset" dsh-emacs-tool-error-face)))
  (let ((buf (generate-new-buffer " *dsh-cmd-body-face*")))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-mode)
          (dsh-emacs-render-event
           `((type . "command/run") (seq . 40)
             (data . ((commandId . ,(nth 0 case)) (name . "compact")))))
          (dsh-emacs-render-event
           `((type . "command/done") (seq . 41)
             (data . ((commandId . ,(nth 0 case))
                      (kind . ,(nth 1 case))
                      (text . ,(nth 2 case))))))
          (let* ((ns (dsh-emacs-render--make-namespace))
                 (block (dsh-emacs-ui-find-block
                         ns (format "cmd-%s" (nth 0 case)))))
            (when block
              (goto-char (car block))
              (dsh-emacs-ui-toggle-fragment))
            (setq block (dsh-emacs-ui-find-block
                         ns (format "cmd-%s" (nth 0 case))))
            (let ((body-start (and block
                                   (save-excursion
                                     (goto-char (car block))
                                     (forward-line 1)
                                     (point)))))
              ;; The body must actually be expanded and contain the result text; an empty
              ;; range
              ;; would make the assertion vacuous
              (dsh-test-assert (format "command-done-body-not-tinted-%s"
                                       (nth 1 case))
                (and block body-start (< body-start (cdr block))
                     (string-match-p (regexp-quote (nth 2 case))
                                     (buffer-substring-no-properties
                                      body-start (cdr block)))
                     (seq-every-p
                      (lambda (pos)
                        (not (memq (nth 3 case) (dsh-test--faces-at pos))))
                      (number-sequence body-start (1- (cdr block)))))))))
      (kill-buffer buf))))

;; --- Test 98a: command row styling --- result prefix + spinner lifecycle ---
(let ((buf (generate-new-buffer " *dsh-cmd-prefix*"))
      (old-spinners dsh-emacs--command-spinners))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (setq dsh-emacs--command-spinners (make-hash-table :test 'equal))
        (dsh-emacs-render-event
         '((type . "command/run") (seq . 20)
           (data . ((commandId . "pfx1") (name . "compact") (args . "")))))
        (dsh-emacs-render-event
         '((type . "command/done") (seq . 21)
           (data . ((commandId . "pfx1") (kind . "success")
                    (text . "Compacted 174 history items")))))
        (let* ((txt (buffer-string))
               (ns (dsh-emacs-render--make-namespace))
               (block-id "cmd-pfx1")
               (blk (dsh-emacs-ui-find-block ns block-id))
               (state (and blk (get-text-property (car blk) 'dsh-emacs-ui-state))))
          (when (and (string-match-p "compact" txt)
                     (string-match-p "done" txt)
                     ;; The result is folded into the body
                     (not (string-match-p "Compacted 174 history items" txt))
                     state
                     (equal (map-elt state :body) "Compacted 174 history items")
                     (map-elt state :collapsed)
                     ;; done stopped the spinner (hash cleared + no leftover timer)
                     (null (gethash "pfx1" dsh-emacs--command-spinners)))
            (dsh-test-pass "command-result-prefix-and-spinner-stopped"))))
    (setq dsh-emacs--command-spinners old-spinners)
    (kill-buffer buf)))

(let ((buf (generate-new-buffer " *dsh-cmd-spin*"))
      (old-spinners dsh-emacs--command-spinners))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (setq dsh-emacs--command-spinners (make-hash-table :test 'equal))
        (dsh-emacs-render-event
         '((type . "command/run") (seq . 30)
           (data . ((commandId . "spin1") (name . "goal")))))
        ;; run started the animation: the timer is running
        (when (and (gethash "spin1" dsh-emacs--command-spinners)
                   (timerp (nth 1 (gethash "spin1" dsh-emacs--command-spinners))))
          (dsh-test-pass "command-spinner-starts"))
        ;; Push 2 frames manually: the index advances and the label changes frame (timers
        ;; do not fire automatically in batch)
        (dsh-emacs--command-spinner-tick (current-buffer) "spin1")
        (dsh-emacs--command-spinner-tick (current-buffer) "spin1")
        (when (= 2 (nth 2 (gethash "spin1" dsh-emacs--command-spinners)))
          (dsh-test-pass "command-spinner-advances"))
        ;; done stops the clock: hash cleared
        (dsh-emacs-render-event
         '((type . "command/done") (seq . 31)
           (data . ((commandId . "spin1") (kind . "success")
                    (text . "ok")))))
        (when (null (gethash "spin1" dsh-emacs--command-spinners))
          (dsh-test-pass "command-spinner-done-stops")))
    (setq dsh-emacs--command-spinners old-spinners)
    (kill-buffer buf)))

(let ((buf (generate-new-buffer " *dsh-cmd-clear*"))
      (old-spinners dsh-emacs--command-spinners))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (setq dsh-emacs--command-spinners (make-hash-table :test 'equal))
        (dsh-emacs-render-event
         '((type . "command/run") (seq . 40)
           (data . ((commandId . "clear1") (name . "goal") (args . "")))))
        (dsh-emacs-render-event
         '((type . "command/run") (seq . 41)
           (data . ((commandId . "clear2") (name . "goal") (args . "")))))
        (dsh-emacs--command-spinner-clear-all)
        (when (= 0 (hash-table-count dsh-emacs--command-spinners))
          (dsh-test-pass "command-spinner-clear-all")))
    (setq dsh-emacs--command-spinners old-spinners)
    (kill-buffer buf)))

;; --- Test 98c: a running command row matches a tool row --- header line pending
;; coloring ---
(let ((buf (generate-new-buffer " *dsh-cmd-tint*"))
      (old-spinners dsh-emacs--command-spinners))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (setq dsh-emacs--command-spinners (make-hash-table :test 'equal))
        (dsh-emacs-render-event
         '((type . "command/run") (seq . 60)
           (data . ((commandId . "tint1") (name . "goal")))))
        (let* ((ns (dsh-emacs-render--make-namespace))
               (block-id "cmd-tint1")
               (blk (dsh-emacs-ui-find-block ns block-id))
               (tinted (and blk
                            (seq-every-p
                             (lambda (pos)
                               (memq 'dsh-emacs-tool-pending-face
                                     (ensure-list (get-text-property pos 'face))))
                             (number-sequence (car blk) (1- (cdr blk)))))))
          (when tinted
            (dsh-test-pass "command-running-tints-header")))
        ;; The spinner tick rebuilds the whole line on every frame; the coloring must not
        ;; be lost
        (dsh-emacs--command-spinner-tick (current-buffer) "tint1")
        (let* ((ns (dsh-emacs-render--make-namespace))
               (block-id "cmd-tint1")
               (blk (dsh-emacs-ui-find-block ns block-id)))
          (when (and blk
                     (seq-every-p
                      (lambda (pos)
                        (memq 'dsh-emacs-tool-pending-face
                              (ensure-list (get-text-property pos 'face))))
                      (number-sequence (car blk) (1- (cdr blk)))))
            (dsh-test-pass "command-running-tint-survives-tick"))))
    (setq dsh-emacs--command-spinners old-spinners)
    (kill-buffer buf)))

;; --- Test 98d: an optimistic command row also carries header line pending
;; coloring ---
(let ((buf (generate-new-buffer " *dsh-cmd-opt-tint*"))
      (old-spinners dsh-emacs--command-spinners))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (let ((dsh-emacs-show-commands t)
              (dsh-emacs--command-blocks (make-hash-table :test 'equal))
              (dsh-emacs--pending-command nil)
              (dsh-emacs--command-spinners (make-hash-table :test 'equal)))
          (dsh-emacs-render-command-optimistic "/compact")
          (let* ((entry (gethash "pending-compact" dsh-emacs--command-blocks))
                 (blk (and entry
                           (dsh-emacs-ui-find-block (nth 0 entry) (nth 1 entry)))))
            (when (and blk
                       (seq-every-p
                        (lambda (pos)
                          (memq 'dsh-emacs-tool-pending-face
                                (ensure-list (get-text-property pos 'face))))
                        (number-sequence (car blk) (1- (cdr blk)))))
              (dsh-test-pass "command-optimistic-tints-header")))))
    (setq dsh-emacs--command-spinners old-spinners)
    (kill-buffer buf)))

;; --- Test 98e: the leading icon of a command row is the bash terminal (same as
;; tool rows) ---
(let ((buf (generate-new-buffer " *dsh-cmd-bash-icon*"))
      (old-spinners dsh-emacs--command-spinners))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (setq dsh-emacs--command-spinners (make-hash-table :test 'equal))
        (dsh-emacs-render-event
         '((type . "command/run") (seq . 70)
           (data . ((commandId . "bash1") (name . "goal")))))
        (let ((txt (buffer-string)))
          (when (string-match-p "💻" txt)
            (dsh-test-pass "command-leading-icon-is-bash")))
        ;; The bash icon is still kept after done
        (dsh-emacs--command-spinner-tick (current-buffer) "bash1")
        (dsh-emacs-render-event
         '((type . "command/done") (seq . 71)
           (data . ((commandId . "bash1") (kind . "success")
                    (text . "ok")))))
        (let ((txt (buffer-string)))
          (when (string-match-p "💻" txt)
            (dsh-test-pass "command-done-keeps-bash-icon"))))
    (setq dsh-emacs--command-spinners old-spinners)
    (kill-buffer buf)))

;; In batch (non-graphical) the icon table gives a bash emoji fallback; the SVG
;; template exists for GUI rendering
(when (equal (cdr (assoc "bash" dsh-emacs--variant-icons)) "💻")
  (dsh-test-pass "command-bash-icon-emoji-fallback"))
(when (assoc "bash" dsh-emacs--tool-icon-svgs)
  (dsh-test-pass "command-bash-icon-svg-template"))

;; --- Test 98f: after a stream reconnect (disconnect+connect) revive a command
;; spinner that is still running ---
(let ((buf (generate-new-buffer " *dsh-cmd-revive*"))
      (old-spinners dsh-emacs--command-spinners))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (setq dsh-emacs--command-spinners (make-hash-table :test 'equal))
        (dsh-emacs-render-event
         '((type . "command/run") (seq . 50)
           (data . ((commandId . "rv1") (name . "goal")))))
        ;; Simulate disconnect (reconnect/switch session) clearing all animations
        (dsh-emacs--command-spinner-clear-all)
        (when (= 0 (hash-table-count dsh-emacs--command-spinners))
          (dsh-test-pass "command-spinner-revive-clear-all"))
        ;; connect revives it: the row is still there in the same chat buffer and the
        ;; status is still pending
        (dsh-emacs--command-spinner-revive)
        (when (and (gethash "rv1" dsh-emacs--command-spinners)
                   (timerp (nth 1 (gethash "rv1" dsh-emacs--command-spinners))))
          (dsh-test-pass "command-spinner-revive-restarts"))
        ;; After revival it advances frames as usual
        (dsh-emacs--command-spinner-tick (current-buffer) "rv1")
        (dsh-emacs--command-spinner-tick (current-buffer) "rv1")
        (when (= 2 (nth 2 (gethash "rv1" dsh-emacs--command-spinners)))
          (dsh-test-pass "command-spinner-revive-advances")))
    (setq dsh-emacs--command-spinners old-spinners)
    (kill-buffer buf)))

;; done already replaced the row with the success color (status != tool-pending):
;; revival must not restart it
(let ((buf (generate-new-buffer " *dsh-cmd-revive-done*"))
      (old-spinners dsh-emacs--command-spinners))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (setq dsh-emacs--command-spinners (make-hash-table :test 'equal))
        (dsh-emacs-render-event
         '((type . "command/run") (seq . 52)
           (data . ((commandId . "rv2") (name . "goal")))))
        (dsh-emacs-render-event
         '((type . "command/done") (seq . 53)
           (data . ((commandId . "rv2") (kind . "success")
                    (text . "ok")))))
        (dsh-emacs--command-spinner-clear-all)
        (dsh-emacs--command-spinner-revive)
        (when (null (gethash "rv2" dsh-emacs--command-spinners))
          (dsh-test-pass "command-spinner-revive-skips-settled")))
    (setq dsh-emacs--command-spinners old-spinners)
    (kill-buffer buf)))

;; The row has already been deleted (the entry remains): revival must not restart
;; the animation
(let ((buf (generate-new-buffer " *dsh-cmd-revive-gone*"))
      (old-spinners dsh-emacs--command-spinners))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (setq dsh-emacs--command-spinners (make-hash-table :test 'equal))
        (dsh-emacs-render-event
         '((type . "command/run") (seq . 54)
           (data . ((commandId . "rv3") (name . "goal")))))
        (when-let* ((entry (gethash "rv3" dsh-emacs--command-blocks))
                    (ns (nth 0 entry))
                    (block-id (nth 1 entry))
                    (blk (dsh-emacs-ui-find-block ns block-id)))
          (let ((inhibit-read-only t))
            (delete-region (car blk) (cdr blk))))
        (dsh-emacs--command-spinner-clear-all)
        (dsh-emacs--command-spinner-revive)
        (when (null (gethash "rv3" dsh-emacs--command-spinners))
          (dsh-test-pass "command-spinner-revive-skips-missing-block")))
    (setq dsh-emacs--command-spinners old-spinners)
    (kill-buffer buf)))

;; 98f2: events-connect (which reconnects also go through) really calls revive
(let ((buf (generate-new-buffer " *dsh-cmd-connect-revive*"))
      (revives 0)
      (old-spinners dsh-emacs--command-spinners))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (setq dsh-emacs--command-spinners (make-hash-table :test 'equal))
        (cl-letf (((symbol-function 'open-network-stream)
                   (lambda (&rest _) (prog1 :fake-proc)))
                  ((symbol-function 'set-process-query-on-exit-flag)
                   (lambda (&rest _) nil))
                  ((symbol-function 'set-process-coding-system)
                   (lambda (&rest _) nil))
                  ((symbol-function 'process-put)
                   (lambda (&rest _) nil))
                  ((symbol-function 'set-process-filter)
                   (lambda (&rest _) nil))
                  ((symbol-function 'set-process-sentinel)
                   (lambda (&rest _) nil))
                  ((symbol-function 'dsh-emacs--command-spinner-revive)
                   (lambda () (setq revives (1+ revives)))))
          (dsh-emacs-events-connect buf)
          (dsh-emacs-events--health-stop))
        (when (> revives 0)
          (dsh-test-pass "command-spinner-revive-wired-in-connect")))
    (setq dsh-emacs--command-spinners old-spinners)
    (kill-buffer buf)))

;; --- Test 98g: reconnect (connect→disconnect→restore) does not lose the
;; mode-line busy flag ---
;; Regression: the stream drops while switching away and back, and on reconnect
;; the disconnect clears the busy flag --- yet the busy flag is exactly the
;; switch for the C-c C-c interrupt (session/cancel): lose it and you get "cannot
;; interrupt, please enter a message".
(let ((buf (generate-new-buffer " *dsh-ml-reconnect-busy*")))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        ;; Simulate a turn in flight: the busy flag is lit by the send path (timer
        ;; included)
        (dsh-emacs--ml-busy-set t)
        (cl-letf (((symbol-function 'open-network-stream)
                   (lambda (&rest _) (prog1 :fake-proc)))
                  ((symbol-function 'set-process-query-on-exit-flag)
                   (lambda (&rest _) nil))
                  ((symbol-function 'set-process-coding-system)
                   (lambda (&rest _) nil))
                  ((symbol-function 'process-put)
                   (lambda (&rest _) nil))
                  ((symbol-function 'set-process-filter)
                   (lambda (&rest _) nil))
                  ((symbol-function 'set-process-sentinel)
                   (lambda (&rest _) nil)))
          ;; Reconnect (connect internally disconnects first, clearing busy, then restores
          ;; per was-busy)
          (dsh-emacs-events-connect buf)
          (dsh-emacs-events--health-stop))
        (when (and dsh-emacs--ml-busy
                   (timerp dsh-emacs--ml-busy-timer))
          (dsh-test-pass "reconnect-keeps-busy-flag"))
        (dsh-emacs--ml-busy-clear))
    (kill-buffer buf)))

;; --- Test 98h: reconnect while idle/settled does not light busy --- no ghost
;; spinner may appear ---
(let ((buf (generate-new-buffer " *dsh-ml-reconnect-idle*")))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (dsh-emacs--ml-busy-clear)
        (cl-letf (((symbol-function 'open-network-stream)
                   (lambda (&rest _) (prog1 :fake-proc)))
                  ((symbol-function 'set-process-query-on-exit-flag)
                   (lambda (&rest _) nil))
                  ((symbol-function 'set-process-coding-system)
                   (lambda (&rest _) nil))
                  ((symbol-function 'process-put)
                   (lambda (&rest _) nil))
                  ((symbol-function 'set-process-filter)
                   (lambda (&rest _) nil))
                  ((symbol-function 'set-process-sentinel)
                   (lambda (&rest _) nil)))
          (dsh-emacs-events-connect buf)
          (dsh-emacs-events--health-stop))
        (when (null dsh-emacs--ml-busy)
          (dsh-test-pass "reconnect-idle-keeps-busy-off")))
    (kill-buffer buf)))

;; --- Test 98j: event stream decides busy --- turn/start lights it up,
;; turn/end turns it off ---
;; When reopening a session / refetching history, an unclosed turn
;; (turn/start with no turn/end) must also light the spinner.
(let ((buf (generate-new-buffer " *dsh-turn-open*")))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (dsh-emacs--ml-busy-clear)
        (dsh-emacs-render-event '((type . "turn/start") (seq . 1)))
        (when (and dsh-emacs--ml-busy
                   (timerp dsh-emacs--ml-busy-timer))
          (dsh-test-pass "turn-start-lights-busy"))
        (dsh-emacs-render-event '((type . "turn/end") (seq . 2)))
        (when (null dsh-emacs--ml-busy)
          (dsh-test-pass "turn-end-extinguishes-busy")))
    (kill-buffer buf)))

;; --- Test 98j2: the opening follow snapshot completes even while input is
;; --- pending --- a dropped tail wedges the mode-line spinner ---
;; Regression: the snapshot seed ran inside `while-no-input', whose early exit
;; drops the whole batch whenever input is pending (fast typing while a session
;; opens from the list).  The snapshot caller still advanced
;; `dsh-emacs--anchor-seq' to the snapshot cursor afterwards, so the dropped
;; records were never re-delivered — a dropped trailing `turn/end' left the
;; mode-line running animation lit with no later event to stop it.
(let ((buf (generate-new-buffer " *dsh-snapshot-input*")))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (setq-local dsh-emacs--buffer-session "sess-snapshot-input")
        (dsh-emacs--ml-busy-clear)
        (setq dsh-emacs--anchor-seq 0)
        (let ((unread-command-events (list ?x)))
          (dsh-emacs-events--follow-snapshot
           (current-buffer)
           (list (cons "type" "snapshot")
                 (cons "cursor" 3)
                 (cons "records"
                       (vector
                        (list (cons "type" "event")
                              (cons "event"
                                    '((type . "turn/start") (seq . 1))))
                        (list (cons "type" "event")
                              (cons "event"
                                    '((type . "user/message") (seq . 2)
                                      (data . ((content
                                                . [((type . "text")
                                                    (text . "hello"))]))))))
                        (list (cons "type" "event")
                              (cons "event"
                                    '((type . "turn/end") (seq . 3))))))
                 (cons "hasMore" :json-false))))
        (when (string-match "hello" (buffer-substring-no-properties
                                     (point-min) (point-max)))
          (dsh-test-pass "snapshot-completes-with-input-pending"))
        (when (null dsh-emacs--ml-busy)
          (dsh-test-pass "snapshot-turn-end-extinguishes-busy"))
        (when (= 3 dsh-emacs--anchor-seq)
          (dsh-test-pass "snapshot-anchor-lands-on-cursor"))
        (dsh-emacs--ml-busy-clear))
    (remhash "sess-snapshot-input" dsh-emacs--input-history-by-session)
    (kill-buffer buf)))

;; --- Test 98k: multi-session concurrency --- busy / command spinner
;; state is per-buffer ---
;; Regression: the ml-busy timer and command-spinners were once global ---
;; while session A was generating, session B's turn/end (rendered as usual
;; in a hidden buffer) cancelled the global timer and cut off A's spinner;
;; the two buffers' optimistic command rows (pending-<name> with the same
;; key) also overwrote each other.
(let ((buf-a (generate-new-buffer " *dsh-multi-a*"))
      (buf-b (generate-new-buffer " *dsh-multi-b*")))
  (unwind-protect
      (progn
        (with-current-buffer buf-a
          (dsh-emacs-mode)
          (dsh-emacs--ml-busy-set t)
          (when (and dsh-emacs--ml-busy (timerp dsh-emacs--ml-busy-timer))
            (dsh-test-pass "multi-session-busy-a-lit")))
        (with-current-buffer buf-b
          (dsh-emacs-mode)
          (dsh-emacs--ml-busy-set t)
          (when (and dsh-emacs--ml-busy (timerp dsh-emacs--ml-busy-timer))
            (dsh-test-pass "multi-session-busy-b-lit"))
          ;; B ends: only B's own spinner goes dark
          (dsh-emacs--ml-busy-set nil)
          (when (null dsh-emacs--ml-busy)
            (dsh-test-pass "multi-session-busy-b-cleared")))
        ;; Key point: B's turn/end must not cut off A's spinner too
        (with-current-buffer buf-a
          (when (and dsh-emacs--ml-busy (timerp dsh-emacs--ml-busy-timer))
            (dsh-test-pass "multi-session-busy-a-survives-b-clear"))
          (dsh-emacs--ml-busy-clear))
        ;; command spinner: same-key optimistic rows do not overwrite each other
        ;; across buffers
        (with-current-buffer buf-a
          (setq dsh-emacs--show-commands t
                dsh-emacs--command-blocks (make-hash-table :test 'equal)
                dsh-emacs--pending-command nil
                dsh-emacs--command-spinners (make-hash-table :test 'equal))
          (dsh-emacs-render-command-optimistic "/compact")
          (when (eq (nth 0 (gethash "pending-compact"
                                    dsh-emacs--command-spinners))
                    buf-a)
            (dsh-test-pass "multi-session-command-spinner-a")))
        (with-current-buffer buf-b
          (setq dsh-emacs--show-commands t
                dsh-emacs--command-blocks (make-hash-table :test 'equal)
                dsh-emacs--pending-command nil
                dsh-emacs--command-spinners (make-hash-table :test 'equal))
          (dsh-emacs-render-command-optimistic "/compact")
          (when (eq (nth 0 (gethash "pending-compact"
                                    dsh-emacs--command-spinners))
                    buf-b)
            (dsh-test-pass "multi-session-command-spinner-b"))
          (dsh-emacs--command-spinner-clear-all))
        (with-current-buffer buf-a
          (when (eq (nth 0 (gethash "pending-compact"
                                    dsh-emacs--command-spinners))
                    buf-a)
            (dsh-test-pass "multi-session-command-spinner-a-survives-b"))
          (dsh-emacs--command-spinner-clear-all)))
    (kill-buffer buf-a)
    (kill-buffer buf-b)))

;; --- Test 98l: optimistic user echo is not duplicated --- mux delivers
;; user/message before the HTTP callback ---
;; Regression: pending was originally registered in session/prompt's HTTP
;; callback, but the mux stream can deliver the same user/message first
;; (pending is empty then → one real message is rendered), and the callback
;; then renders the optimistic echo again → "occasionally two user input
;; messages are rendered". Fix: pending is registered before the RPC is
;; sent, so an event arriving at any moment can be consumed by the dedup
;; gate.
(let ((buf (generate-new-buffer " *dsh-submit-race*")))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (setq dsh-emacs--current-session "sess-race")
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (_method _params cb)
                     ;; Simulate the mux stream delivering the same user/message before
                     ;; the
                     ;; HTTP response callback
                     (dsh-emacs-events--dispatch-event
                      (current-buffer)
                      '((type . "user/message") (seq . 42)
                        (data . ((content . [((type . "text")
                                              (text . "race-msg"))])))))
                     (funcall cb t '((ok . t))))))
          (dsh-emacs--submit-plain "race-msg" nil t))
        (let ((n (1- (length (split-string
                              (buffer-substring-no-properties (point-min)
                                                              (point-max))
                              "race-msg")))))
          (when (= 1 n)
            (dsh-test-pass "user-echo-no-duplicate-when-stream-wins")))
        (when (null dsh-emacs--pending-user-messages)
          (dsh-test-pass "user-pending-consumed-by-stream-event"))
        (dsh-emacs--ml-busy-clear)
        (dsh-emacs-events--watchdog-stop))
    (kill-buffer buf)))

;; --- Test 98p: a fast run's turn/end arriving before the prompt HTTP callback
;; --- must not make the callback re-light the spinner ---
;; Regression: the send path lights the mode-line busy flag inside the
;; session/prompt HTTP callback.  A fast run (very short reply, model
;; rejected immediately e.g. 429) can start AND end on the mux before that
;; callback runs — an unconditional `dsh-emacs--ml-busy-set t' would then
;; re-light an already-finished turn and the spinner would never stop until
;; the next turn/end or a stream teardown.  Fix: the callback lights the
;; spinner only while `dsh-emacs--turn-awaiting' is still t (the submitted
;; run has not seen its turn/end yet).
(let ((buf (generate-new-buffer " *dsh-fast-run-race*")))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (setq-local dsh-emacs--buffer-session "sess-fast")
        (setq dsh-emacs--current-session "sess-fast")
        (dsh-emacs--ml-busy-clear)
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (_method _params cb)
                     ;; The mux delivers turn/start + turn/end before the HTTP callback
                     (dsh-emacs-events--dispatch-event
                      (current-buffer)
                      '((type . "turn/start") (seq . 50)))
                     (dsh-emacs-events--dispatch-event
                      (current-buffer)
                      '((type . "turn/end") (seq . 51)))
                     (funcall cb t '((accepted . t)))))
                  ((symbol-function 'dsh-emacs-events-connect)
                   (lambda (_c) nil))
                  ((symbol-function 'dsh-emacs-events--watchdog-start)
                   (lambda () nil)))
          (dsh-emacs--submit-plain "fast" nil t))
        (dsh-test-assert "fast-run-end-before-callback-keeps-spinner-off"
          (null dsh-emacs--ml-busy)
          (null dsh-emacs--ml-busy-timer))
        (dsh-emacs-events--watchdog-stop))
    (kill-buffer buf)))

;; Control: while the turn/end has NOT arrived, the callback still lights
;; the spinner — a pending run must always show progress.
(let ((buf (generate-new-buffer " *dsh-normal-run-lights*")))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (setq-local dsh-emacs--buffer-session "sess-normal")
        (setq dsh-emacs--current-session "sess-normal")
        (dsh-emacs--ml-busy-clear)
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (_method _params cb)
                     (funcall cb t '((accepted . t)))))
                  ((symbol-function 'dsh-emacs-events-connect)
                   (lambda (_c) nil))
                  ((symbol-function 'dsh-emacs-events--watchdog-start)
                   (lambda () nil)))
          (dsh-emacs--submit-plain "normal" nil t))
        (dsh-test-assert "pending-run-callback-lights-spinner"
          (and dsh-emacs--ml-busy (timerp dsh-emacs--ml-busy-timer)))
        (dsh-emacs--ml-busy-clear)
        (dsh-emacs-events--watchdog-stop))
    (kill-buffer buf)))

(defun dsh-emacs-test--buffer-copies (needle)
  "Count non-overlapping occurrences of NEEDLE in the current buffer."
  (let ((n 0) (text (buffer-substring-no-properties (point-min) (point-max))))
    (while (string-search needle text)
      (setq n (1+ n)
            text (substring text (+ (string-search needle text)
                                    (length needle)))))
    n))

(defun dsh-emacs-test--user-echo-count (needle)
  "Count transcript user blocks whose body contains NEEDLE.
Blocks are located by the `dsh-emacs-user-message' property, so a restored
input-area draft (which carries no such property) is not counted."
  (let ((prop 'dsh-emacs-user-message)
        (pos (point-min))
        (n 0))
    (while (< pos (point-max))
      (let ((start (if (get-text-property pos prop)
                       pos
                     (next-single-property-change pos prop nil (point-max)))))
        (if (or (null start) (>= start (point-max)))
            (setq pos (point-max))
          (let ((end (or (next-single-property-change start prop nil (point-max))
                         (point-max))))
            (when (string-match-p
                   (regexp-quote needle)
                   (buffer-substring-no-properties start end))
              (setq n (1+ n)))
            (setq pos end)))))
    n))

;; --- Test 98o: mux reconnect replaying the full backlog must not render
;; twice ---
;; Regression: the protocol has no baseline-sync, so mux replays the whole
;; global event stream for every new connection (including a mid-session
;; reconnect); drops while a session is open are caught by
;; `dsh-emacs--event-history-loading', but on a **mid-session reconnect**
;; that flag is already cleared, so replayed old-seq events all flood into
;; the live dispatch path --- `dsh-emacs-events--dispatch-event' originally
;; had no seq gate (the history/probe path does, see
;; `dsh-emacs-render-history-events'), so user/message and
;; assistant/message were rendered in full once more. User symptom: after
;; C-c C-c the user message appears twice, the agent reply is rendered
;; twice, layout is a mess; reopening the session restores normal. Fix:
;; dispatch drops replayed frames with seq <= `dsh-emacs--anchor-seq' per
;; that anchor; new events from the disconnected period (seq > anchor) are
;; still rendered as usual to fill the gap.
(let ((chat (get-buffer-create " *dsh-replay-dedup*")))
  (unwind-protect
      (with-current-buffer chat
        (dsh-emacs-mode)
        (setq-local dsh-emacs--buffer-session "sess-replay")
        (setq dsh-emacs--anchor-seq 0)
        ;; First round: normal live streaming, each rendered once
        (dsh-emacs-events--dispatch-event
         chat '((type . "user/message") (seq . 1)
                (data . ((content . [((type . "text")
                                      (text . "replay-msg"))])))))
        (dsh-emacs-events--dispatch-event
         chat '((type . "assistant/message") (seq . 2)
                (data . ((turn . 1) (step . 1)
                         (message . ((content . [((type . "text")
                                                  (text . "replay-reply"))])))))))
        (dsh-test-assert "replay-live-pass-renders-once"
          (= 1 (dsh-emacs-test--buffer-copies "replay-msg"))
          (= 1 (dsh-emacs-test--buffer-copies "replay-reply"))
          (= 2 dsh-emacs--anchor-seq))
        ;; Second round: full mux replay after reconnect (same seqs) --- must not
        ;; render again
        (dsh-emacs-events--dispatch-event
         chat '((type . "user/message") (seq . 1)
                (data . ((content . [((type . "text")
                                      (text . "replay-msg"))])))))
        (dsh-emacs-events--dispatch-event
         chat '((type . "assistant/message") (seq . 2)
                (data . ((turn . 1) (step . 1)
                         (message . ((content . [((type . "text")
                                                  (text . "replay-reply"))])))))))
        (dsh-test-assert "reconnect-replay-does-not-duplicate"
          (= 1 (dsh-emacs-test--buffer-copies "replay-msg"))
          (= 1 (dsh-emacs-test--buffer-copies "replay-reply"))
          (= 2 dsh-emacs--anchor-seq))
        ;; Same gate on the streaming path: a replayed assistant/chunk must not
        ;; open a second stream
        (dsh-emacs-events--dispatch-event
         chat '((type . "assistant/chunk") (seq . 3)
                (data . ((turn . 2) (step . 1)
                         (chunk . ((type . "text-delta") (index . 1)
                                   (text . "replay-chunk")))))))
        (dsh-test-assert "replay-chunk-live-renders-once"
          (= 1 (dsh-emacs-test--buffer-copies "replay-chunk"))
          (= 3 dsh-emacs--anchor-seq))
        (dsh-emacs-events--dispatch-event
         chat '((type . "assistant/chunk") (seq . 3)
                (data . ((turn . 2) (step . 1)
                         (chunk . ((type . "text-delta") (index . 1)
                                   (text . "replay-chunk")))))))
        (dsh-test-assert "replay-chunk-replay-does-not-duplicate"
          (= 1 (dsh-emacs-test--buffer-copies "replay-chunk"))
          (= 3 dsh-emacs--anchor-seq))
        ;; Fill the gap: events produced while disconnected (seq > anchor) are
        ;; rendered once
        (dsh-emacs-events--dispatch-event
         chat '((type . "user/message") (seq . 4)
                (data . ((content . [((type . "text")
                                      (text . "during-outage"))])))))
        (dsh-test-assert "reconnect-catchup-renders-new-events"
          (= 1 (dsh-emacs-test--buffer-copies "during-outage"))
          (= 4 dsh-emacs--anchor-seq)))
    (when (buffer-live-p chat) (kill-buffer chat))))

;; --- Test 98o: after reconnect the follow snapshot reseed does not
;; duplicate, gap fill as usual ---
;; A reconnect (`session/follow' reopened) delivers a new snapshot. Its
;; records carry the ORIGINAL seq --- those with seq <=
;; `dsh-emacs--anchor-seq' were already rendered locally, so the reseed
;; must drop them and not redraw the whole transcript; only new content
;; with seq > anchor (produced while disconnected) is rendered once to fill
;; the gap. This is exactly spec-m4 §Part1-2's follow-snapshot backfill:
;; previously only dispatch-event and first open (anchor=0) were covered by
;; tests, here we feed "existing anchor + reconnect snapshot" directly.
(let ((chat (get-buffer-create " *dsh-snapshot-reseed*")))
  (unwind-protect
      (with-current-buffer chat
        (dsh-emacs-mode)
        (setq-local dsh-emacs--buffer-session "sess-reseed")
        ;; Open for a long time: anchor has advanced to 6, the earlier content is
        ;; all on screen.
        (setq dsh-emacs--anchor-seq 6)
        ;; Reconnect snapshot: records are the same old history (seq 4/5 <=
        ;; anchor 6), cursor also only reaches 6 → must not render again.
        (dsh-emacs-events--follow-snapshot
         (current-buffer)
         '((type . "snapshot")
           (cursor . 6)
           (records .
                    [((type . "event")
                      (event . ((type . "user/message") (seq . 4)
                                (data . ((content . [((type . "text")
                                                      (text . "reseed-old-msg"))]))))))
                     ((type . "event")
                      (event . ((type . "assistant/message") (seq . 5)
                                (data . ((turn . 1) (step . 1)
                                         (message . ((content .
                                                      [((type . "text")
                                                        (text . "reseed-old-reply"))]))))))))])))
        (dsh-test-assert "snapshot-reseed-no-duplicate"
          (= 0 (dsh-emacs-test--buffer-copies "reseed-old-msg"))
          (= 0 (dsh-emacs-test--buffer-copies "reseed-old-reply"))
          (= 6 dsh-emacs--anchor-seq))
        ;; New events produced while disconnected (seq > anchor) are backfilled
        ;; once via the live path.
        (dsh-emacs-events--dispatch-event
         chat '((type . "user/message") (seq . 7)
                (data . ((content . [((type . "text")
                                      (text . "reseed-catchup"))])))))
        (dsh-test-assert "snapshot-reseed-catchup-renders-new"
          (= 1 (dsh-emacs-test--buffer-copies "reseed-catchup"))
          (= 7 dsh-emacs--anchor-seq)))
    (when (buffer-live-p chat) (kill-buffer chat))))

;; --- Regression: when host normalizes the sent canonical session mention
;; to `@label' on echo, the optimistic pending entry must still be consumed
;; (otherwise the same message is rendered twice, once canonical and once
;; as label)
(let ((canon "@[实现dsh web的@指令](dsh-session:InNlc3Npb24tYWU0NGZlYTUtYmY2Ny00YmE5LWIzZGEtNTk5OTAzODMyOTMzIg)")
      (echo "@实现dsh web的@指令 summary"))
  (let ((dsh-emacs--pending-user-messages (list (concat canon " summary"))))
    (dsh-test-assert "consume-pending-matches-normalized-session-echo"
      (and (dsh-emacs-render--consume-pending-user-message
            `((type . "user/message")
              (data . ((content . [((type . "text") (text . ,echo))])))))
           (null dsh-emacs--pending-user-messages)))))

(defun dsh-emacs-test--input-text ()
  "Return the current editable input text (or \"\" when no input area)."
  (condition-case nil
      (or (dsh-emacs--get-input) "")
    (error "")))

;; --- Test 98p: the plain send path clears the input area on submit,
;; failure restores the draft, no double send on repeated presses ---
;; Regression: `dsh-emacs--submit-plain' originally cleared the input area
;; only in the RPC success callback --- pressing C-c C-c again during the
;; RPC round trip (busy still nil) would send the same message again
;; verbatim (double send), and the success callback's clear would wipe a
;; draft typed during the round trip. Fix: clear on submit (same feel as
;; the command/deferred paths), on transport failure restore the original
;; text only when the input area is still empty, and success no longer
;; touches the input area.
(let ((buf (generate-new-buffer " *dsh-plain-submit-clear*"))
      (cb nil))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (setq dsh-emacs--current-session "sess-plain-clear")
        (setq-local dsh-emacs--buffer-session "sess-plain-clear")
        (dsh-emacs--ml-busy-clear)
        ;; Scenario 1: clear on submit (without waiting for the RPC to return);
        ;; on failure with the input area still empty → restore the original text
        (goto-char dsh-emacs--input-marker)
        (insert "draft one")
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (_method _params callback) (setq cb callback))))
          (dsh-emacs--submit-plain "draft one"))
        (dsh-test-assert "plain-submit-clears-input-immediately"
          (string-empty-p (dsh-emacs-test--input-text)))
        (dsh-test-assert "plain-submit-echoes-before-rpc"
          (= 1 (dsh-emacs-test--user-echo-count "draft one")))
        (funcall cb nil '((error . "boom")))
        (dsh-test-assert "plain-submit-failure-restores-draft"
          (string= "draft one" (dsh-emacs-test--input-text)))
        (dsh-test-assert "plain-submit-failure-rolls-back-echo"
          (= 0 (dsh-emacs-test--user-echo-count "draft one")))
        (dsh-test-assert "plain-submit-failure-drops-pending"
          (null dsh-emacs--pending-user-messages))
        (dsh-test-assert "plain-submit-failure-drops-echo-entry"
          (null dsh-emacs--pending-user-echoes))
        ;; Scenario 2: failure must not overwrite a draft typed during the round
        ;; trip
        (dsh-emacs--clear-input)
        (setq cb nil)
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (_method _params callback) (setq cb callback))))
          (dsh-emacs--submit-plain "draft two"))
        (insert "newer draft")
        (funcall cb nil '((error . "boom")))
        (dsh-test-assert "plain-submit-failure-keeps-newer-draft"
          (string= "newer draft" (dsh-emacs-test--input-text)))
        (dsh-test-assert "plain-submit-failure-rolls-back-echo-two"
          (= 0 (dsh-emacs-test--user-echo-count "draft two")))
        ;; Scenario 3: the success path leaves the echo on screen (the
        ;; canonical `user/message' consumes the pending entry) and never
        ;; touches a draft typed during the round trip
        (dsh-emacs--clear-input)
        (setq cb nil)
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (_method _params callback) (setq cb callback))))
          (dsh-emacs--submit-plain "draft three"))
        (insert "typed during flight")
        (funcall cb t '((ok . t)))
        (dsh-test-assert "plain-submit-success-keeps-newer-draft"
          (string= "typed during flight" (dsh-emacs-test--input-text)))
        (dsh-test-assert "plain-submit-success-keeps-echo"
          (= 1 (dsh-emacs-test--user-echo-count "draft three")))
        (dsh-emacs--ml-busy-clear))
    (when (buffer-live-p buf) (kill-buffer buf))))

;; --- Test 98p2: a consumed echo is never rolled back by a later same-text
;; --- failure ---
;; Once the canonical `user/message' takes over an optimistic echo, its
;; rollback record must retire with the pending entry.  A stale record left
;; behind made a later FAILED re-send of the same text delete the accepted
;; block instead of its own echo.
(let ((buf (generate-new-buffer " *dsh-echo-consume*"))
      (cbs nil))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (setq-local dsh-emacs--buffer-session "sess-echo-consume")
        (dsh-emacs--ml-busy-clear)
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (_m _p callback) (push callback cbs))))
          (dsh-emacs--submit-plain "dup"))
        (dsh-test-assert "echo-consume-setup"
          (= 1 (dsh-emacs-test--user-echo-count "dup"))
          (= 1 (length dsh-emacs--pending-user-echoes)))
        ;; The canonical event takes over: pending + rollback record retire,
        ;; the block stays on screen.
        (dsh-emacs-events--dispatch-event
         buf '((type . "user/message") (seq . 1)
               (data . ((content . [((type . "text") (text . "dup"))])))))
        (dsh-test-assert "echo-consume-drops-rollback-record"
          (null dsh-emacs--pending-user-messages)
          (null dsh-emacs--pending-user-echoes)
          (= 1 (dsh-emacs-test--user-echo-count "dup")))
        ;; Re-send the same text under its OWN callback capture — the first
        ;; submit's callback belongs to the consumed entry — and fail it: it
        ;; deletes its own echo and leaves the accepted block untouched.
        (setq cbs nil)
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (_m _p callback) (push callback cbs))))
          (dsh-emacs--submit-plain "dup"))
        (dsh-test-assert "echo-consume-second-echo"
          (= 2 (dsh-emacs-test--user-echo-count "dup")))
        (funcall (car cbs) nil '((error . "boom")))
        (dsh-test-assert "echo-consume-failure-deletes-own-echo-only"
          (= 1 (dsh-emacs-test--user-echo-count "dup"))
          (null dsh-emacs--pending-user-echoes)
          (null dsh-emacs--pending-user-messages))
        (dsh-emacs--ml-busy-clear))
    (when (buffer-live-p buf) (kill-buffer buf))))

;; --- Test 98p2b: a failed duplicate submit rolls back its OWN echo ---
;; Two in-flight submits of the same text are only distinguishable by the
;; rollback entries they own: the pending list matches by identity while the
;; echo list was looked up by text (`assoc'/`equal'), so when the NEWER submit
;; failed first the older block was deleted and the newer rollback record was
;; left pointing at a live block.
(let ((buf (generate-new-buffer " *dsh-echo-identity*"))
      (cbs nil)
      (first-entry nil)
      (second-entry nil))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (setq-local dsh-emacs--buffer-session "sess-echo-identity")
        (dsh-emacs--ml-busy-clear)
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (_m _p callback) (push callback cbs))))
          (dsh-emacs--submit-plain "dup")
          (setq first-entry (car dsh-emacs--pending-user-echoes))
          (dsh-emacs--submit-plain "dup")
          (setq second-entry (cadr dsh-emacs--pending-user-echoes)))
        (dsh-test-assert "echo-identity-setup"
          (= 2 (length dsh-emacs--pending-user-echoes))
          (= 2 (dsh-emacs-test--user-echo-count "dup")))
        ;; `cbs' is newest-first, so the second submit's callback fails first.
        (funcall (car cbs) nil '((error . "boom")))
        (dsh-test-assert "echo-identity-failure-rolls-back-own-entry"
          (memq first-entry dsh-emacs--pending-user-echoes)
          (null (memq second-entry dsh-emacs--pending-user-echoes))
          (= 1 (dsh-emacs-test--user-echo-count "dup")))
        (dsh-emacs--ml-busy-clear))
    (when (buffer-live-p buf) (kill-buffer buf))))

;; --- Test 98p3: wire `false' booleans never read as running ---
;; `json-read' decodes JSON false as the truthy symbol `:json-false'.  Keeping
;; it in the session struct made `dsh-emacs--busy-p' report an IDLE session as
;; running, so every idle `C-c C-c' was routed to the queue path — the message
;; showed first as the blue Next Message preview and only then entered the
;; transcript, instead of the plain send's immediate transcript echo.
(let* ((idle (dsh-protocol-session--from-alist
              '((sessionId . "s-idle") (running . :json-false)
                (blank . :json-false))))
       (busy (dsh-protocol-session--from-alist
              '((sessionId . "s-run") (running . t) (blank . t)))))
  (dsh-test-assert "session-wire-false-normalizes-to-nil"
    (null (dsh-protocol-session-running idle))
    (null (dsh-protocol-session-blank idle)))
  (dsh-test-assert "session-wire-true-normalizes-to-t"
    (eq t (dsh-protocol-session-running busy))))
(let ((buf (generate-new-buffer " *dsh-busy-false*")))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (setq-local dsh-emacs--buffer-session "s-idle")
        (dsh-emacs--ml-busy-clear)
        (setq dsh-emacs--sessions
              (list (dsh-protocol-session--from-alist
                     '((sessionId . "s-idle") (running . :json-false)))))
        (dsh-test-assert "idle-row-is-not-busy"
          (null (dsh-emacs--busy-p)))
        (setf (dsh-protocol-session-running (car dsh-emacs--sessions)) t)
        (dsh-test-assert "running-row-is-busy"
          (dsh-emacs--busy-p)))
    (when (buffer-live-p buf) (kill-buffer buf))))

;; --- Test 98n: a socket-creation error on reconnect must not leave the
;; session permanently deaf ---
;; Regression: `dsh-emacs-events-connect' first tears down the old stream
;; with disconnect (cancelling the reconnect timer along with it), and only
;; then creates the new socket; if `open-network-stream' throws
;; synchronously (DNS resolution failure, invalid base-url, etc.), the
;; exception escapes from the 1s reconnect timer and nobody schedules the
;; reconnect again --- the session has neither a socket nor renders any
;; further reply. With multiple sessions each session has its own stream
;; and the others render as usual, so the symptom is "some session
;; suddenly stops rendering server replies". connect now wraps connection
;; setup in condition-case: on failure it schedules another reconnect
;; (`dsh-emacs-events--schedule-reconnect').
(let ((buf (generate-new-buffer " *dsh-connect-throw*")))
  (unwind-protect
      (progn
        (with-current-buffer buf
          (dsh-emacs-mode)
          (setq dsh-emacs--current-session "sess-cthrow"
                dsh-emacs--event-ready nil
                dsh-emacs--event-reconnect-timer nil))
        (cl-letf (((symbol-function 'open-network-stream)
                   (lambda (&rest _) (error "sync dns failure"))))
          (let ((threw (condition-case err
                           (progn (dsh-emacs-events-connect buf) nil)
                         (error err))))
            (with-current-buffer buf
              (when (null threw)
                (dsh-test-pass "connect-throw-is-contained"))
              (when (timerp dsh-emacs--event-reconnect-timer)
                (dsh-test-pass "connect-throw-schedules-reconnect"))))))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (when (timerp dsh-emacs--event-reconnect-timer)
          (cancel-timer dsh-emacs--event-reconnect-timer))
        (setq dsh-emacs--event-reconnect-timer nil))
      (kill-buffer buf))))

;; --- Test 98m: turn/end with reason.kind=error (model failure such as
;; 429) renders a visible error line ---
(let ((buf (generate-new-buffer " *dsh-turn-error*")))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (dsh-emacs--ml-busy-clear)
        (dsh-emacs-render-event
         '((type . "turn/start") (seq . 1) (data . ((turn . 1)))))
        (when (and dsh-emacs--ml-busy (timerp dsh-emacs--ml-busy-timer))
          (dsh-test-pass "turn-error-lights-busy-before-end"))
        ;; Model failure: turn/end + data.reason.kind = "error"
        (dsh-emacs-render-event
         '((type . "turn/end") (seq . 2) (data . ((turn . 1)
           (reason . ((kind . "error")
                      (error . ((code . "insufficient_quota")
                                (message . "Allocated quota exceeded")))))))))
        (let ((text (buffer-substring-no-properties (point-min) (point-max))))
          (when (and (null dsh-emacs--ml-busy)
                     (string-match-p "insufficient_quota" text)
                     (string-match-p "Allocated quota exceeded" text))
            (dsh-test-pass "turn-error-renders-visible-row"))))
    (kill-buffer buf)))

;; --- Test 98n: a successful / interrupted turn/end does not render an
;; error line ---
(let ((buf (generate-new-buffer " *dsh-turn-ok*")))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (dsh-emacs-render-event
         '((type . "turn/end") (seq . 1)
           (data . ((turn . 1) (reason . ((kind . "completed")))))))
        ;; Successful end: no error line
        (when (not (string-match-p "✗ Model error"
                                   (buffer-substring-no-properties
                                    (point-min) (point-max))))
          (dsh-test-pass "turn-success-no-error-row"))
        ;; Interrupted (reason.kind=cancelled): likewise no error line
        (dsh-emacs-render-event
         '((type . "turn/end") (seq . 2)
           (data . ((turn . 2) (reason . ((kind . "cancelled")))))))
        (when (not (string-match-p "✗ Model error"
                                   (buffer-substring-no-properties
                                    (point-min) (point-max))))
          (dsh-test-pass "turn-cancelled-no-error-row")))
    (kill-buffer buf)))

;; --- Test 98o: a non-envelope failure response (vendor error body passed
;; through) unwraps into a message ---
(let* ((response (json-read-from-string
                  "{\"message\":\"Allocated quota exceeded, please increase your quota limit.\",\"code\":\"insufficient_quota\"}"))
       (unwrapped (dsh-emacs--unwrap-response response)))
  (when (and (null (car unwrapped))
             (string-match-p "Allocated quota exceeded" (cdr unwrapped)))
    (dsh-test-pass "unwrap-leaked-error-body-surfaces-message")))

;; --- Test 98a: optimistic command row rendering ---
(let ((buf (generate-new-buffer " *dsh-cmd-opt*")))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (let ((dsh-emacs-show-commands t)
              (dsh-emacs--command-blocks (make-hash-table :test 'equal))
              (dsh-emacs--pending-command nil)
              (dsh-emacs--command-spinners (make-hash-table :test 'equal)))
          (dsh-emacs-render-command-optimistic "/compact")
          ;; temp entry stored in command-blocks
          (let ((entry (gethash "pending-compact"
                                dsh-emacs--command-blocks)))
            (when (and entry
                       dsh-emacs--pending-command
                       (equal (car dsh-emacs--pending-command) "pending-compact"))
              (dsh-test-pass "command-optimistic-creates-temp-entry")))))
    (kill-buffer buf)))

;; --- Test 98b: command/run replaces the optimistic row ---
(let ((buf (generate-new-buffer " *dsh-cmd-opt-repl*")))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (let ((dsh-emacs-show-commands t)
              (dsh-emacs--command-blocks (make-hash-table :test 'equal))
              (dsh-emacs--pending-command nil)
              (dsh-emacs--command-spinners (make-hash-table :test 'equal)))
          ;; Step 1: optimistic render
          (dsh-emacs-render-command-optimistic "/compact")
          (when (gethash "pending-compact" dsh-emacs--command-blocks)
            ;; Step 2: real command/run event arrives
            (dsh-emacs-render-command
             '((type . "command/run") (seq . 10)
               (data . ((commandId . "real-123")
                        (name . "/compact") (args . "")))))
            ;; temp entry removed, real entry present
            (when (and (null (gethash "pending-compact"
                                      dsh-emacs--command-blocks))
                       (gethash "real-123"
                                dsh-emacs--command-blocks)
                       (null dsh-emacs--pending-command))
              (dsh-test-pass "command-run-replaces-optimistic")))))
    (kill-buffer buf)))
(let ((calls nil)
      (read-called nil)
      (dsh-emacs--current-session "sess-menu"))
  (cl-letf (((symbol-function 'dsh-emacs--rpc-request)
             (lambda (_m _p)
               (cons t [((name . "goal") (description . "goal ops")
                         (input . ((hint . "[<objective>]"))))
                        ((name . "compact") (description . "compact"))])))
            ((symbol-function 'completing-read)
             (lambda (&rest _) "/goal"))
            ((symbol-function 'read-string)
             (lambda (&rest _) (setq read-called t) "set x"))
            ((symbol-function 'dsh-emacs--rpc-async)
             (lambda (method params cb)
               (push (list method params) calls)
               (funcall cb t '((commandId . "c3")
                               (result . ((kind . "success")
                                          (text . "t"))))))))
    (dsh-emacs-command)
    (let* ((call (car calls))
           (params (cadr call)))
      (when (and (string= "commands/execute" (car call))
                 (string= "/goal set x" (cdr (assq 'line params)))
                 read-called)
        (dsh-test-pass "command-menu-hint-prompts-args")))))

(let ((calls nil)
      (read-called nil)
      (dsh-emacs--current-session "sess-menu2"))
  (cl-letf (((symbol-function 'dsh-emacs--rpc-request)
             (lambda (_m _p)
               (cons t [((name . "compact") (description . "compact"))])))
            ((symbol-function 'completing-read)
             (lambda (&rest _) "/compact"))
            ((symbol-function 'read-string)
             (lambda (&rest _) (setq read-called t) "x"))
            ((symbol-function 'dsh-emacs--rpc-async)
             (lambda (method params cb)
               (push (list method params) calls)
               (funcall cb t '((commandId . "c4")
                               (result . ((kind . "success")
                                          (text . "t"))))))))
    (dsh-emacs-command)
    (let* ((call (car calls))
           (params (cadr call)))
      (when (and (string= "commands/execute" (car call))
                 (string= "/compact" (cdr (assq 'line params)))
                 (null read-called))
        (dsh-test-pass "command-menu-bare-no-args")))))

;; --- Test 100: input area /name completion ---
(let ((buf (generate-new-buffer " *dsh-capf*"))
      (old dsh-emacs--command-catalogs))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (dsh-emacs-command--cache-catalog
         "sess-cap"
         (list (dsh-protocol-command--from-alist
                '((name . "goal") (description . "d")))
               (dsh-protocol-command--from-alist
                '((name . "compact") (description . "d")))))
        (setq dsh-emacs--current-session "sess-cap")
        ;; A bare "/" also returns the whole directory (web's trigger behavior)
        (goto-char dsh-emacs--input-marker)
        (insert "/")
        (let* ((comp (dsh-emacs-command-completion-at-point))
               (cands (nth 2 comp)))
          (when (and comp
                     (member "/goal " cands)
                     (member "/compact " cands))
            (dsh-test-pass "command-capf-bare-slash-lists-all")))
        ;; After clearing, the "/go" prefix still returns all candidates
        ;; (filtering is left to the completion framework)
        (delete-region dsh-emacs--input-marker (point-max))
        (goto-char dsh-emacs--input-marker)
        (insert "/go")
        (let* ((comp (dsh-emacs-command-completion-at-point))
               (cands (nth 2 comp)))
          (when (and comp
                     (member "/goal " cands)
                     (member "/compact " cands))
            (dsh-test-pass "command-capf-completes-prefix")))
        (goto-char dsh-emacs--input-marker)
        (insert "/goal ")
        (when (null (dsh-emacs-command-completion-at-point))
          (dsh-test-pass "command-capf-off-after-space"))
        (goto-char (point-min))
        (when (null (dsh-emacs-command-completion-at-point))
          (dsh-test-pass "command-capf-off-in-transcript")))
    (setq dsh-emacs--command-catalogs old)
    (kill-buffer buf)))

;; Candidates are plain strings, descriptions go through standard metadata
;; (annotation-function / company-kind): the corfu popup lays out at real
;; width (same style as other modes), no display property to pad the width
(let ((buf (generate-new-buffer " *dsh-capf-meta*"))
      (old dsh-emacs--command-catalogs))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (dsh-emacs-command--cache-catalog
         "sess-cap-meta"
         (list (dsh-protocol-command--from-alist
                '((name . "goal") (description . "Set and track goals.")))
               (dsh-protocol-command--from-alist
                '((name . "compact") (description . "Condense context.")))
               (dsh-protocol-command--from-alist
                '((name . "export") (description . "Export this session.")))))
        (setq dsh-emacs--current-session "sess-cap-meta")
        (goto-char dsh-emacs--input-marker)
        (insert "/")
        (let* ((comp (dsh-emacs-command-completion-at-point))
               (cands (nth 2 comp))
               (meta (nthcdr 3 comp))
               (ann (plist-get meta :annotation-function)))
          (when (and comp
                     (= 3 (length cands))
                     (cl-every (lambda (c) (null (text-properties-at 0 c)))
                               cands)
                     (functionp ann)
                     (string= "Set and track goals." (funcall ann "/goal "))
                     (string= "Condense context." (funcall ann "/compact "))
                     ;; `:company-kind' is a "candidate → kind symbol" function
                     ;; (nerd-icons-corfu's kindfunc convention, a bare symbol gets
                     ;; funcalled)
                     (let ((kindf (plist-get meta :company-kind)))
                       (and (functionp kindf)
                            (eq 'command (funcall kindf "/goal ")))))
            (dsh-test-pass "command-capf-metadata-annotation-kind"))))
    (setq dsh-emacs--command-catalogs old)
    (kill-buffer buf)))

;; When the directory is not cached, the first trigger also fills it
;; synchronously (otherwise "/" pops an empty list)
(let ((buf (generate-new-buffer " *dsh-capf-sync*"))
      (old dsh-emacs--command-catalogs)
      (rpc-calls 0))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (setq dsh-emacs--current-session "sess-sync")
        (cl-letf (((symbol-function 'dsh-emacs--rpc-request)
                   (lambda (_m _p)
                     (setq rpc-calls (1+ rpc-calls))
                     (cons t [((name . "compact") (description . "c"))
                              ((name . "goal") (description . "g"))]))))
          (goto-char dsh-emacs--input-marker)
          (insert "/")
          (let* ((comp (dsh-emacs-command-completion-at-point))
                 (cands (nth 2 comp)))
            (when (and comp
                       (= rpc-calls 1)
                       (member "/goal " cands)
                       (member "/compact " cands))
              (dsh-test-pass "command-capf-sync-fetches-uncached-catalog")))))
    (setq dsh-emacs--command-catalogs old)
    (kill-buffer buf)))

;; TAB in a chat buffer must land on completion-at-point (the keyboard
;; entry for slash completion)
(when (eq (lookup-key dsh-emacs-mode-map (kbd "TAB"))
          #'completion-at-point)
  (dsh-test-pass "chat-mode-tab-bound-to-completion-at-point"))

;; Cooperative "/" auto-trigger: dsh-emacs-mode adds "/" to the buffer-local
;; `corfu-auto-trigger' only when the user already enabled corfu-auto, letting
;; corfu's own engine pop the list.  dsh-emacs never enables corfu-auto itself
;; and never hooks corfu-auto--post-command into post-command-hook (that hook is
;; corfu-mode's job when corfu-auto is on; dsh-emacs only contributes a trigger).
(let ((buf (generate-new-buffer " *dsh-corfu-coop*")))
  (unwind-protect
      (with-current-buffer buf
        (defvar corfu-auto)
        (defvar corfu-auto-trigger)
        (setq corfu-auto t
              corfu-auto-trigger "")
        (cl-letf (((symbol-function 'require) (lambda (&rest _) t)))
          (dsh-emacs-mode)
          (dsh-test-assert "slash-auto-corfu-coop-trigger-added"
            ;; The cooperative mode contributes both "/" (slash) and "@"
            ;; (reference) to corfu-auto-trigger; neither sets corfu-auto nor
            ;; hooks corfu-auto--post-command.
            (string-match-p "/" (buffer-local-value 'corfu-auto-trigger buf))
            (string-match-p "@" (buffer-local-value 'corfu-auto-trigger buf))
            (not (memq 'corfu-auto--post-command
                       (buffer-local-value 'post-command-hook buf))))))
    (kill-buffer buf)))

;; corfu-auto off (user did not enable auto): no trigger contributed (TAB-only)
(let ((buf (generate-new-buffer " *dsh-corfu-coop-off*")))
  (unwind-protect
      (with-current-buffer buf
        (defvar corfu-auto)
        (defvar corfu-auto-trigger)
        (setq corfu-auto nil
              corfu-auto-trigger "")
        (cl-letf (((symbol-function 'require) (lambda (&rest _) t)))
          (dsh-emacs-mode)
          (dsh-test-assert "slash-auto-corfu-coop-off-no-trigger"
            (string= "" (buffer-local-value 'corfu-auto-trigger buf)))))
    (kill-buffer buf)))

;; all auto options off: nothing contributed even when corfu-auto is on
(let ((buf (generate-new-buffer " *dsh-corfu-coop-offopt*")))
  (unwind-protect
      (with-current-buffer buf
        (defvar corfu-auto)
        (defvar corfu-auto-trigger)
        (setq corfu-auto t
              corfu-auto-trigger "")
        (cl-letf (((symbol-function 'require) (lambda (&rest _) t))
                  (dsh-emacs-slash-auto-complete nil)
                  (dsh-emacs-reference-auto-complete nil))
          (dsh-emacs-mode)
          (dsh-test-assert "slash-auto-corfu-coop-off-when-options-off"
            (string= "" (buffer-local-value 'corfu-auto-trigger buf)))))
    (kill-buffer buf)))

;; idempotent: running setup again does not append "/" twice
(let ((buf (generate-new-buffer " *dsh-corfu-coop-idem*")))
  (unwind-protect
      (with-current-buffer buf
        (defvar corfu-auto)
        (defvar corfu-auto-trigger)
        (setq corfu-auto t
              corfu-auto-trigger "")
        (cl-letf (((symbol-function 'require) (lambda (&rest _) t)))
          (dsh-emacs-command-auto-trigger-setup)
          (dsh-emacs-command-auto-trigger-setup)
          (dsh-test-assert "slash-auto-corfu-coop-idempotent"
            (string= "/" (buffer-local-value 'corfu-auto-trigger buf)))))
    (kill-buffer buf)))

;; --- Test 101: todo plan row --- parse / one row per event (like a tool
;; card) / collapse ---
;; 101a: full snapshot collapse: drop empty content, unknown status
;; defaults to pending, counts are correct
(let ((l (dsh-emacs-render--todo-parse
          "{\"todos\":[{\"content\":\"a\",\"status\":\"pending\"},{\"content\":\"b\",\"status\":\"in_progress\"},{\"content\":\"c\",\"status\":\"completed\"},{\"content\":\"\",\"status\":\"completed\"},{\"content\":\"d\"}]}")))
  (when (and (= (length l) 4)
             (equal (dsh-emacs-render--todo-counts l) '(1 1 2))
             (string-match-p "1/4 completed" (dsh-emacs-render--todo-summary l)))
    (dsh-test-pass "todo-parse-drops-invalid-defaults-status")))

;; 101b: the first todo_write renders **one** todo row (with
;; progress/pending glyphs), it does not create an ordinary tool card
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (setq-local dsh-emacs-todo-expand-by-default t)
  (dsh-emacs-render-tool-call
   (dsh-emacs-test--tool-call-event 1 "t1" "todo_write"
    "{\"todos\":[{\"content\":\"A\",\"status\":\"in_progress\"},{\"content\":\"B\",\"status\":\"pending\"}]}"))
  (let ((txt (buffer-string)))
    (when (and (dsh-emacs-ui-find-block dsh-emacs--todo-namespace "t1")
               ;; items are ☐ checkboxes (in_progress/pending) with status words
               (string-match-p (regexp-quote "☐") txt)
               (string-match-p "in progress" txt)
               (string-match-p "pending" txt)
               ;; Leading icon is the dsh-web checklist icon (fallback "▤" in
               ;; non-graphical Emacs), not the old "☑".
               (string-match-p (regexp-quote "▤") txt)
               (not (string-match-p (regexp-quote "☑") txt))
               (not (string-match-p "tool-t1" txt)))
      (dsh-test-pass "todo-row-renders-on-write-no-card"))))

;; 101c: every todo_write renders a new row (like a tool card),
;; accumulating with the conversation, no overwriting
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (setq-local dsh-emacs-todo-expand-by-default t)
  (dsh-emacs-render-tool-call
   (dsh-emacs-test--tool-call-event 1 "t1" "todo_write"
    "{\"todos\":[{\"content\":\"A\",\"status\":\"in_progress\"},{\"content\":\"B\",\"status\":\"pending\"}]}"))
  (dsh-emacs-render-tool-call
   (dsh-emacs-test--tool-call-event 2 "t2" "todo_write"
    "{\"todos\":[{\"content\":\"A\",\"status\":\"completed\"},{\"content\":\"B\",\"status\":\"in_progress\"},{\"content\":\"C\",\"status\":\"pending\"}]}"))
  (let ((txt (buffer-string)))
    (when (and (dsh-emacs-ui-find-block dsh-emacs--todo-namespace "t1")
               (dsh-emacs-ui-find-block dsh-emacs--todo-namespace "t2")
               (string-match-p "1/3 completed" txt)
               (string-match-p (regexp-quote "C") txt)
               (string-match-p (regexp-quote "☑") txt))
      (dsh-test-pass "todo-each-write-renders-new-row"))))

;; 101d: resetting the session clears the latest todo snapshot state
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (dsh-emacs-render-tool-call
   (dsh-emacs-test--tool-call-event 1 "t1" "todo_write"
    "{\"todos\":[{\"content\":\"A\",\"status\":\"pending\"}]}"))
  (dsh-emacs-render--reset-tool-tracking)
  (when (null dsh-emacs--todo-list)
    (dsh-test-pass "todo-reset-clears-list")))

;; 101e: a todo row can be collapsed/expanded (default collapsed: header
;; only, checklist hidden)
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (setq-local dsh-emacs-todo-expand-by-default nil)
  (dsh-emacs-render-tool-call
   (dsh-emacs-test--tool-call-event 1 "t1" "todo_write"
    "{\"todos\":[{\"content\":\"Alpha\",\"status\":\"in_progress\"},{\"content\":\"Beta\",\"status\":\"pending\"}]}"))
  (let* ((b (dsh-emacs-ui-find-block dsh-emacs--todo-namespace "t1"))
         (blk (and b (buffer-substring-no-properties (car b) (cdr b)))))
    (when (and b (string-match-p "Todo" blk)
               (not (string-match-p (regexp-quote "Alpha") (buffer-string))))
      (dsh-test-pass "todo-row-collapsed-by-default"))
    ;; Expand: the checklist appears (with status glyphs)
    (goto-char (car b))
    (dsh-emacs-ui-toggle-fragment)
    (let ((txt (buffer-string)))
      (when (and (string-match-p (regexp-quote "Alpha") txt)
                 (string-match-p (regexp-quote "☐") txt))
        (dsh-test-pass "todo-row-expands-on-toggle")))
    ;; Collapse again: the checklist is hidden again
    (goto-char (car b))
    (dsh-emacs-ui-toggle-fragment)
    (when (not (string-match-p (regexp-quote "Alpha") (buffer-string)))
      (dsh-test-pass "todo-row-recollapses-on-toggle"))))

;; 101f: summary-only mode: show only counts/progress, hide checklist
;; details and the collapse toggle
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (setq-local dsh-emacs-todo-summary-only t)
  (dsh-emacs-render-tool-call
   (dsh-emacs-test--tool-call-event 1 "t1" "todo_write"
    "{\"todos\":[{\"content\":\"Alpha\",\"status\":\"in_progress\"},{\"content\":\"Beta\",\"status\":\"pending\"},{\"content\":\"Gamma\",\"status\":\"completed\"}]}"))
  (let* ((b (dsh-emacs-ui-find-block dsh-emacs--todo-namespace "t1"))
         (blk (and b (buffer-substring-no-properties (car b) (cdr b)))))
    (when (and b
               (string-match-p "1/3 completed" (buffer-string))
               (not (string-match-p (regexp-quote "Alpha") (buffer-string)))
               (not (string-match-p (regexp-quote "Beta") (buffer-string)))
               (not (string-match-p (regexp-quote "Gamma") (buffer-string))))
      (dsh-test-pass "todo-summary-only-hides-details"))
    ;; Text segment (title) in green `dsh-emacs-todo-text-face' (not italic)
    (when (and b
               (let ((m (string-match "Todo" blk)))
                 (and m
                      (let ((f (get-text-property (+ (car b) m) 'face)))
                        (or (eq f 'dsh-emacs-todo-text-face)
                            (memq 'dsh-emacs-todo-text-face
                                  (if (listp f) f (list f))))))))
      (dsh-test-pass "todo-row-text-green"))
    ;; Leading icon in tool purple `dsh-emacs-tool-icon-face'
    (when (and b
               (let ((f (get-text-property (car b) 'face)))
                 (or (eq f 'dsh-emacs-tool-icon-face)
                     (memq 'dsh-emacs-tool-icon-face
                           (if (listp f) f (list f))))))
      (dsh-test-pass "todo-icon-purple-face"))
    ;; The collapse toggle should have no effect: repeated toggling must not
    ;; reveal the checklist
    (goto-char (car b))
    (dsh-emacs-ui-toggle-fragment)
    (dsh-emacs-ui-toggle-fragment)
    (when (not (string-match-p (regexp-quote "Alpha") (buffer-string)))
      (dsh-test-pass "todo-summary-only-no-toggle"))))

;; imenu: user message index
(with-temp-buffer
  (let ((inhibit-read-only t))
    (insert "dsh  DeepSeek Harness\n\n")
    (insert "\u276f hello world\n")
    (insert "\u276f second message here\n")
    ;; Simulate the user-message property
    (let ((start1 (string-match "\u276f hello" (buffer-string)))
          (start2 (string-match "\u276f second" (buffer-string))))
      (when start1
        (put-text-property (+ (point-min) start1) (+ (point-min) start1 12)
                           'dsh-emacs-user-message t))
      (when start2
        (put-text-property (+ (point-min) start2) (+ (point-min) start2 20)
                           'dsh-emacs-user-message t))))
  (let ((index (dsh-emacs-imenu-create-user-index)))
    (when (and (= (length index) 2)
               (string-match-p "hello world" (car (car index)))
               (string-match-p "second" (car (cadr index))))
      (dsh-test-pass "imenu-user-index"))))

;; --- Test 102: dsh-emacs--workspace-sessions ---
(let ((s1 (dsh-protocol-session--from-alist
         (list (cons 'sessionId "s1") (cons 'title "First")
               (cons 'updatedAt 2000) (cons 'blank :json-false))))
      (s2 (dsh-protocol-session--from-alist
         (list (cons 'sessionId "s2") (cons 'title "Second")
               (cons 'updatedAt 1000) (cons 'blank :json-false))))
      (s3 (dsh-protocol-session--from-alist
         (list (cons 'sessionId "s3") (cons 'title "Blank")
               (cons 'blank t))))
      (s4 (dsh-protocol-session--from-alist
         (list (cons 'sessionId "s4") (cons 'title "Stray")
               (cons 'blank :json-false))))
      (s5 (dsh-protocol-session--from-alist
         (list (cons 'sessionId "s5") (cons 'title "Subagent")
               (cons 'origin "subagent") (cons 'blank :json-false))))
      (w1 (dsh-protocol-workspace--from-alist
         (list (cons 'workspaceId "w1") (cons 'title "MyWS")
               (cons 'path "/tmp/ws")
               (cons 'sessionIds ["s1" "s2" "s3" "s5"])
               (cons 'createdAt "x") (cons 'updatedAt "x")))))
  (setq dsh-emacs--workspaces (list w1)
        dsh-emacs--sessions (list s1 s2 s3 s4 s5)
        dsh-emacs--archived-sessions nil)
  (let ((result (dsh-emacs--workspace-sessions "w1")))
    (when (and (= (length result) 2)
               (string= "s1" (dsh-protocol-session-session-id (car result)))
               (string= "s2" (dsh-protocol-session-session-id (cadr result))))
      (dsh-test-pass "workspace-sessions-filters-and-sorts"))))
;; --- Test 103: dsh-emacs--workspace-sessions empty workspace ---
(let* ((w-empty (dsh-protocol-workspace--from-alist
              (list (cons 'workspaceId "empty-ws")
                    (cons 'title "Empty")
                    (cons 'path "/tmp/empty")
                    (cons 'sessionIds [])
                    (cons 'createdAt "x")
                    (cons 'updatedAt "x"))))
       (sessions (list (dsh-protocol-session--from-alist
                        (list (cons 'sessionId "s99")
                              (cons 'title "Stray")
                              (cons 'blank :json-false)))))
       (workspaces (list w-empty)))
  (setq dsh-emacs--workspaces workspaces
        dsh-emacs--sessions sessions
        dsh-emacs--archived-sessions nil)
  (when (null (dsh-emacs--workspace-sessions "empty-ws"))
    (dsh-test-pass "workspace-sessions-empty-returns-nil")))
;; --- Test 104: dsh-emacs--workspace-sessions unknown workspace ---
(let* ((w1 (dsh-protocol-workspace--from-alist
           (list (cons 'workspaceId "w1")
                 (cons 'title "WS")
                 (cons 'path "/tmp/ws")
                 (cons 'sessionIds ["s1"])
                 (cons 'createdAt "x")
                 (cons 'updatedAt "x"))))
       (sessions (list (dsh-protocol-session--from-alist
                        (list (cons 'sessionId "s1")
                              (cons 'title "One")
                              (cons 'blank :json-false)))))
       (workspaces (list w1)))
  (setq dsh-emacs--workspaces workspaces
        dsh-emacs--sessions sessions
        dsh-emacs--archived-sessions nil)
  (when (null (dsh-emacs--workspace-sessions "unknown-ws"))
    (dsh-test-pass "workspace-sessions-unknown-returns-nil")))
;; --- Test 105: dsh-emacs-switch-workspace-session excludes the current
;; session ---
(defun dsh-test-completion-items (coll)
  "Return COLL's completion strings (text properties stripped).
COLL is a completion table (possibly metadata-wrapped), so extract
candidates as the UI would via `all-completions', not by destructuring."
  (mapcar #'substring-no-properties (all-completions "" coll)))
(let* ((w1 (dsh-protocol-workspace--from-alist
           (list (cons 'workspaceId "w1")
                 (cons 'title "WS")
                 (cons 'path "/tmp/ws")
                 (cons 'sessionIds ["s1" "s2"])
                 (cons 'createdAt "x")
                 (cons 'updatedAt "x"))))
       (s1 (dsh-protocol-session--from-alist
            (list (cons 'sessionId "s1") (cons 'title "Cur")
                  (cons 'blank :json-false))))
       (s2 (dsh-protocol-session--from-alist
            (list (cons 'sessionId "s2") (cons 'title "Other")
                  (cons 'blank :json-false))))
       (collection nil)
       (opened nil))
  (setq dsh-emacs--workspaces (list w1)
        dsh-emacs--sessions (list s1 s2)
        dsh-emacs--archived-sessions nil
        dsh-emacs--current-session "s1")
  (cl-letf (((symbol-function 'completing-read)
             (lambda (_prompt coll &rest _)
               (setq collection coll)
               ;; Choose the first candidate (after the current session is excluded only
               ;; s2 remains)
               (car (dsh-test-completion-items coll))))
            ((symbol-function 'dsh-emacs-open-session)
             (lambda (sid) (setq opened sid))))
    (dsh-emacs-switch-workspace-session))
  (when (and (equal opened "s2")
             (= (length (dsh-test-completion-items collection)) 1))
    (dsh-test-pass "switch-session-excludes-current")))
;; --- Test 106: dsh-emacs-switch-workspace-session shows a prompt when
;; there are no other sessions ---
(let* ((w1 (dsh-protocol-workspace--from-alist
           (list (cons 'workspaceId "w1")
                 (cons 'title "WS")
                 (cons 'path "/tmp/ws")
                 (cons 'sessionIds ["s1"])
                 (cons 'createdAt "x")
                 (cons 'updatedAt "x"))))
       (s1 (dsh-protocol-session--from-alist
            (list (cons 'sessionId "s1") (cons 'title "Solo")
                  (cons 'blank :json-false))))
       (prompted nil)
       (msgs nil))
  (setq dsh-emacs--workspaces (list w1)
        dsh-emacs--sessions (list s1)
        dsh-emacs--archived-sessions nil
        dsh-emacs--current-session "s1")
  (cl-letf (((symbol-function 'completing-read)
             (lambda (&rest _) (setq prompted t) nil))
            ((symbol-function 'message)
             (lambda (fmt &rest args)
               (push (apply #'format fmt args) msgs))))
    (dsh-emacs-switch-workspace-session))
  (when (and (not prompted)
             (member "No other sessions in this workspace" msgs))
    (dsh-test-pass "switch-session-no-others-message")))
;; --- Test 107: dsh-emacs-switch-workspace-session candidates sorted by
;; activity time (ungrouped fallback) ---
(let ((s-old (dsh-protocol-session--from-alist
              (list (cons 'sessionId "s-old") (cons 'title "Old")
                    (cons 'updatedAt 1000) (cons 'blank :json-false))))
      (s-new (dsh-protocol-session--from-alist
              (list (cons 'sessionId "s-new") (cons 'title "New")
                    (cons 'updatedAt 2000) (cons 'blank :json-false))))
      (collection nil)
      (opened nil))
  (setq dsh-emacs--workspaces nil
        dsh-emacs--sessions (list s-old s-new) ; Cache order ≠ activity order
        dsh-emacs--archived-sessions nil
        dsh-emacs--current-session "s-cur")
  (cl-letf (((symbol-function 'completing-read)
             (lambda (_prompt coll &rest _)
               (setq collection coll)
               ;; Choose the first item; sorted by activity time it should be s-new
               (car (dsh-test-completion-items coll))))
            ((symbol-function 'dsh-emacs-open-session)
             (lambda (sid) (setq opened sid))))
    (dsh-emacs-switch-workspace-session))
  (when (and (equal opened "s-new") ; first after sorting = s-new (larger updatedAt)
             (= (length (dsh-test-completion-items collection)) 2))
    (dsh-test-pass "switch-session-sorts-by-recency")))
;; --- Test 108: switch-session completion carries order-preserving
;; metadata (framework-independent) ---
(let ((s1 (dsh-protocol-session--from-alist
           (list (cons 'sessionId "s1") (cons 'title "One")
                 (cons 'updatedAt 1000) (cons 'blank :json-false))))
      (sort-fn 'unset))
  (setq dsh-emacs--workspaces nil
        dsh-emacs--sessions (list s1)
        dsh-emacs--archived-sessions nil
        dsh-emacs--current-session "s0")
  (cl-letf (((symbol-function 'completing-read)
             (lambda (_prompt coll &rest _)
               (setq sort-fn (completion-metadata-get
                              (completion-metadata "" coll nil)
                              'display-sort-function))
               "s1")))
    (dsh-emacs-switch-workspace-session))
  (when (eq sort-fn 'identity)
    (dsh-test-pass "switch-session-attaches-preserve-order-metadata")))
;; --- Test 109: switch-session disables ivy sorting under ivy-mode ---
(let ((s1 (dsh-protocol-session--from-alist
           (list (cons 'sessionId "s1") (cons 'title "One")
                 (cons 'updatedAt 1000) (cons 'blank :json-false))))
      (ivy-alist-seen 'unset))
  (setq dsh-emacs--workspaces nil
        dsh-emacs--sessions (list s1)
        dsh-emacs--archived-sessions nil
        dsh-emacs--current-session "s0"
        ivy-mode t) ; Simulate the user enabling ivy
  (cl-letf (((symbol-function 'completing-read)
             (lambda (_prompt _coll &rest _)
               (setq ivy-alist-seen ivy-sort-functions-alist)
               "s1")))
    (dsh-emacs-switch-workspace-session))
  (setq ivy-mode nil)
  (when (and (consp ivy-alist-seen)
             (eq (car (car ivy-alist-seen)) t)
             (null (cdr (car ivy-alist-seen))))
    (dsh-test-pass "switch-session-disables-ivy-sort")))
;; --- Test 110: dsh-emacs-session--visible-p visible-session rules ---
(let ((h-arch (make-hash-table :test 'equal)))
  (puthash "s-arch" t h-arch)
  (let ((s-ok (dsh-protocol-session--from-alist
               (list (cons 'sessionId "s-ok") (cons 'blank :json-false))))
        (s-archived (dsh-protocol-session--from-alist
                     (list (cons 'sessionId "s-arch") (cons 'blank :json-false))))
        (s-sub (dsh-protocol-session--from-alist
                (list (cons 'sessionId "s-sub") (cons 'origin "subagent")
                      (cons 'blank :json-false))))
        (s-blank (dsh-protocol-session--from-alist
                  (list (cons 'sessionId "s-blank") (cons 'blank t))))
        (s-blank-cur (dsh-protocol-session--from-alist
                      (list (cons 'sessionId "s-blank-cur") (cons 'blank t)))))
    (let ((dsh-emacs--archived-sessions h-arch)
          (dsh-emacs--current-session "s-blank-cur"))
      (when (and (dsh-emacs-session--visible-p s-ok)
                 (not (dsh-emacs-session--visible-p s-archived))
                 (not (dsh-emacs-session--visible-p s-sub))
                 (not (dsh-emacs-session--visible-p s-blank))
                 ;; blank but currently open → visible
                 (dsh-emacs-session--visible-p s-blank-cur))
        (dsh-test-pass "visible-p-mirrors-dsh-web-rule")))))
;; --- Test 110b: group-sessions follows visible-p to pick members
;; (regression) ---
;; `unless' and `when' were once swapped: the list only collected
;; archived/subagent/blank sessions and dropped normal sessions. This case
;; asserts group membership directly, so a wrong direction disappears
;; silently.
(let* ((h-arch (make-hash-table :test 'equal))
       (ws (list (dsh-protocol-workspace--from-alist
                  (list (cons 'workspaceId "w1")
                        (cons 'title "WS1")
                        (cons 'path "/tmp/ws1")
                        (cons 'sessionIds
                              ["s-ok" "s-arch" "s-sub" "s-blank" "s-blank-cur"])
                        (cons 'createdAt "x")
                        (cons 'updatedAt "x")))))
       (sessions (list (dsh-protocol-session--from-alist
                        (list (cons 'sessionId "s-ok")
                              (cons 'blank :json-false)))
                       (dsh-protocol-session--from-alist
                        (list (cons 'sessionId "s-arch")
                              (cons 'blank :json-false)))
                       (dsh-protocol-session--from-alist
                        (list (cons 'sessionId "s-sub")
                              (cons 'origin "subagent")
                              (cons 'blank :json-false)))
                       (dsh-protocol-session--from-alist
                        (list (cons 'sessionId "s-blank")
                              (cons 'blank t)))
                       (dsh-protocol-session--from-alist
                        (list (cons 'sessionId "s-blank-cur")
                              (cons 'blank t)))))
       (dsh-emacs--archived-sessions (progn (puthash "s-arch" t h-arch) h-arch))
       (dsh-emacs--current-session "s-blank-cur")
       (grouped (dsh-emacs-session--group-sessions sessions ws))
       (group (cl-find-if (lambda (g)
                            (equal "WS1" (plist-get g :label)))
                          grouped))
       (ids (sort (mapcar (lambda (s)
                            (dsh-protocol-session-session-id s))
                          (plist-get group :sessions))
                  #'string<)))
  (when (equal ids '("s-blank-cur" "s-ok"))
    (dsh-test-pass "group-sessions-filters-by-visible-rule")))
;; --- Test 111: dsh-emacs-switch-session candidates across all workspaces ---
(let* ((w1 (dsh-protocol-workspace--from-alist
            (list (cons 'workspaceId "w1") (cons 'title "WS1")
                  (cons 'path "/tmp/ws1")
                  (cons 'sessionIds ["s1" "s2" "s-arch"])
                  (cons 'createdAt "x") (cons 'updatedAt "x"))))
       (w2 (dsh-protocol-workspace--from-alist
            (list (cons 'workspaceId "w2") (cons 'title "WS2")
                  (cons 'path "/tmp/ws2")
                  (cons 'sessionIds ["s3"])
                  (cons 'createdAt "x") (cons 'updatedAt "x"))))
       (s1 (dsh-protocol-session--from-alist
            (list (cons 'sessionId "s1")
                  (cons 'projections
                        (list (cons 'values (list (cons 'title "Cur")))))
                  (cons 'updatedAt 4000) (cons 'blank :json-false))))
       (s2 (dsh-protocol-session--from-alist
            (list (cons 'sessionId "s2")
                  (cons 'projections
                        (list (cons 'values (list (cons 'title "In W1")))))
                  (cons 'updatedAt 3000) (cons 'blank :json-false))))
       (s3 (dsh-protocol-session--from-alist
            (list (cons 'sessionId "s3")
                  (cons 'projections
                        (list (cons 'values (list (cons 'title "In W2")))))
                  (cons 'updatedAt 2000) (cons 'blank :json-false))))
       (s4 (dsh-protocol-session--from-alist
            (list (cons 'sessionId "s4")
                  (cons 'projections
                        (list (cons 'values (list (cons 'title "Ungrouped")))))
                  (cons 'updatedAt 1000) (cons 'blank :json-false))))
       (s-arch (dsh-protocol-session--from-alist
                (list (cons 'sessionId "s-arch") (cons 'title "Archived")
                      (cons 'updatedAt 3500) (cons 'blank :json-false))))
       (s-sub (dsh-protocol-session--from-alist
               (list (cons 'sessionId "s-sub") (cons 'title "Sub")
                     (cons 'origin "subagent") (cons 'updatedAt 3800)
                     (cons 'blank :json-false))))
       (s-blank (dsh-protocol-session--from-alist
                 (list (cons 'sessionId "s-blank") (cons 'title "Blank")
                       (cons 'blank t))))
       (h-arch (make-hash-table :test 'equal))
       (collection nil)
       (opened nil)
       (label-by-title nil))
  (puthash "s-arch" t h-arch)
  (setq dsh-emacs--workspaces (list w1 w2)
        dsh-emacs--sessions (list s1 s2 s3 s4 s-arch s-sub s-blank)
        dsh-emacs--archived-sessions h-arch
        dsh-emacs--current-session "s1")
  (cl-letf (((symbol-function 'completing-read)
             (lambda (_prompt coll &rest _)
               (setq collection coll)
               ;; Record each candidate label, pick the first item (most recent activity
               ;; = s2)
               (dolist (item (dsh-test-completion-items coll))
                 (when (string-search "In W1" item)
                   (setq label-by-title item)))
               (car (dsh-test-completion-items coll))))
            ((symbol-function 'dsh-emacs-open-session)
             (lambda (sid) (setq opened sid))))
    (dsh-emacs-switch-session))
  (when (and (equal opened "s2")
              ;; Candidates = all visible sessions except the current one (across
              ;; workspaces + Ungrouped), archived / subagent / blank do not appear;
              ;; workspace does not participate in the label or filtering.
              (= (length (dsh-test-completion-items collection)) 3)
              (equal (mapcar #'substring-no-properties
                             (dsh-test-completion-items collection))
                     (list "In W1" "In W2" "Ungrouped"))
              (string-search "In W1" (or label-by-title "")))
    (dsh-test-pass "switch-session-all-spans-workspaces")))
;; --- Test 112: dsh-emacs-switch-workspace-session prefix argument = all
;; workspaces ---
(let* ((w1 (dsh-protocol-workspace--from-alist
            (list (cons 'workspaceId "w1") (cons 'title "WS1")
                  (cons 'path "/tmp/ws1")
                  (cons 'sessionIds ["s1"])
                  (cons 'createdAt "x") (cons 'updatedAt "x"))))
       (w2 (dsh-protocol-workspace--from-alist
            (list (cons 'workspaceId "w2") (cons 'title "WS2")
                  (cons 'path "/tmp/ws2")
                  (cons 'sessionIds ["s2"])
                  (cons 'createdAt "x") (cons 'updatedAt "x"))))
       (s1 (dsh-protocol-session--from-alist
            (list (cons 'sessionId "s1") (cons 'title "Cur")
                  (cons 'updatedAt 2000) (cons 'blank :json-false))))
       (s2 (dsh-protocol-session--from-alist
            (list (cons 'sessionId "s2") (cons 'title "Elsewhere")
                  (cons 'updatedAt 1000) (cons 'blank :json-false))))
       (opened nil))
  (setq dsh-emacs--workspaces (list w1 w2)
        dsh-emacs--sessions (list s1 s2)
        dsh-emacs--archived-sessions nil
        dsh-emacs--current-session "s1")
  (cl-letf (((symbol-function 'completing-read)
             (lambda (_prompt coll &rest _)
               (car (dsh-test-completion-items coll))))
            ((symbol-function 'dsh-emacs-open-session)
             (lambda (sid) (setq opened sid))))
    ;; C-u C-c C-s: sessions outside the workspace (w2) should also appear
    ;; among the candidates
    (dsh-emacs-switch-workspace-session t))
  (when (equal opened "s2")
    (dsh-test-pass "switch-session-prefix-arg-covers-all-workspaces")))
;; --- Test 113: switch-session-all is bound in the chat keymap ---
(let ((keys (where-is-internal 'dsh-emacs-switch-session
                               dsh-emacs-mode-map)))
  (when (and keys (equal (car keys) (kbd "C-c M-s")))
    (dsh-test-pass "switch-session-all-keybinding")))
;; --- Test 114: with no candidates at all, the all scope gives a
;; dedicated prompt ---
(let ((s1 (dsh-protocol-session--from-alist
           (list (cons 'sessionId "s1") (cons 'title "Solo")
                 (cons 'blank :json-false))))
      (prompted nil)
      (msgs nil))
  (setq dsh-emacs--workspaces nil
        dsh-emacs--sessions (list s1)
        dsh-emacs--archived-sessions nil
        dsh-emacs--current-session "s1")
  (cl-letf (((symbol-function 'completing-read)
             (lambda (&rest _) (setq prompted t) nil))
            ((symbol-function 'message)
             (lambda (fmt &rest args)
               (push (apply #'format fmt args) msgs))))
    (dsh-emacs-switch-session))
  (when (and (not prompted)
             (member "No other sessions" msgs))
    (dsh-test-pass "switch-session-all-no-others-message")))
;; --- Integrity gate: every pass name declared in the source must be
;; registered at least once ---
;; The pass-only style (when/unless + dsh-test-pass) records no result when
;; the assertion does not hold, which once made 4+ cases silently vanish
;; without a FAIL. Compare against all dsh-test-pass calls in this file's
;; source (with literal names); if not registered, the test is judged to
;; have silently not fired.
(let ((declared (make-hash-table :test 'equal)))
  (when (or load-file-name buffer-file-name)
    (with-temp-buffer
      (insert-file-contents (or load-file-name buffer-file-name))
      ;; `;' comments and examples inside strings need the lisp syntax table to
      ;; be recognized by syntax-ppss
      (when (boundp 'emacs-lisp-mode-syntax-table)
        (set-syntax-table emacs-lisp-mode-syntax-table))
      (goto-char (point-min))
      (while (re-search-forward
              "(dsh-test-pass[ \t\n]*\"\\([^\"]+\\)\"" nil t)
        ;; Skip matches inside comments/strings
        (unless (nth 8 (save-excursion
                         (goto-char (match-beginning 0))
                         (syntax-ppss)))
          (puthash (match-string 1) t declared))))
    (dolist (r dsh-test-results)
      (remhash (car r) declared))
    (maphash (lambda (name _)
               (dsh-test-fail
                name
                "no result recorded (pass-only assertion never ran)"))
             declared)))
;; --- Test 115: switch candidate list bounded on empty input (rg-style
;; consumption, recency first) ---
(let* ((vec (vconcat (cl-loop for i below 300 collect
                              (cons (format "Session %d title" i)
                                    (format "s-%d" i)))))
       (table (dsh-emacs--switch-table vec 100))
       (items (all-completions "" table)))
  (dsh-test-assert "switch-table-bounds-empty-input"
    (= 100 (length items))
    (equal (car items) "Session 0 title")
    (equal (nth 99 items) "Session 99 title")))

;; --- Test 116: with input, give the full universe, narrowing does not
;; drop old sessions ---
(let* ((vec (vconcat (cl-loop for i below 300 collect
                              (cons (format "Session %d title" i)
                                    (format "s-%d" i)))))
       (table (dsh-emacs--switch-table vec 100))
       (all-str (all-completions "Session" table))
       (narrowed (all-completions "Session 25" table)))
  (dsh-test-assert "switch-table-full-universe-on-input"
    (= 300 (length all-str))
    (cl-every (lambda (s)
                (string-prefix-p "Session 25" s))
              narrowed)
    (> (length narrowed) 0)))

;; --- Test 117: the chosen label can find the session id back ---
(let* ((vec (vconcat (list (cons "In W1 · WS1" "s1")
                           (cons "Ungrouped" "s2"))))
       (id-table (dsh-emacs--switch-id-table vec)))
  (dsh-test-assert "switch-id-table-roundtrip"
    (equal "s1" (gethash "In W1 · WS1" id-table))
    (equal "s2" (gethash "Ungrouped" id-table))))

;; --- Test 118: workspace does not participate in filtering, only
;; duplicate titles use workspace for disambiguation ---
(let* ((w1 (dsh-protocol-workspace--from-alist
            (list (cons 'workspaceId "w1") (cons 'title "WS1")
                  (cons 'path "/tmp/ws1")
                  (cons 'sessionIds ["s-uniq" "s-dup1"])
                  (cons 'createdAt "x") (cons 'updatedAt "x"))))
       (w2 (dsh-protocol-workspace--from-alist
            (list (cons 'workspaceId "w2") (cons 'title "WS2")
                  (cons 'path "/tmp/ws2")
                  (cons 'sessionIds ["s-dup2"])
                  (cons 'createdAt "x") (cons 'updatedAt "x"))))
       (dsh-emacs--workspaces (list w1 w2))
       (dsh-emacs--sessions
        (list (dsh-protocol-session--from-alist
               (list (cons 'sessionId "s-uniq")
                     (cons 'projections
                           (list (cons 'values
                                       (list (cons 'title "Unique one")))))
                     (cons 'blank :json-false)))
              (dsh-protocol-session--from-alist
               (list (cons 'sessionId "s-dup1")
                     (cons 'projections
                           (list (cons 'values
                                       (list (cons 'title "Shared")))))
                     (cons 'blank :json-false)))
              (dsh-protocol-session--from-alist
               (list (cons 'sessionId "s-dup2")
                     (cons 'projections
                           (list (cons 'values
                                       (list (cons 'title "Shared")))))
                     (cons 'blank :json-false)))))
       (index (dsh-emacs--sessions-index))
       (ws-idx (dsh-emacs--workspaces-by-session))
       (cache (make-hash-table :test 'equal))
       (ws-label (lambda (wid)
                   (or (gethash wid cache)
                       (puthash wid (dsh-emacs--workspace-label wid) cache))))
       (entries (dsh-emacs--switch-entry-labels
                 dsh-emacs--sessions index ws-idx ws-label))
       (labels (mapcar #'car entries))
       (table (dsh-emacs--switch-table (vconcat entries) 200)))
  (dsh-test-assert "switch-labels-workspace-free-filtering"
    ;; A unique title is shown bare, with no workspace attached
    (member "Unique one" labels)
    ;; Duplicate titles use workspace for disambiguation (entry-label's
    ;; parenthesis format)
    (member "Shared (WS1)" labels)
    (member "Shared (WS2)" labels)
    ;; Each row can still find the session id back
    (equal "s-uniq" (cdr (assoc "Unique one" entries)))
    (equal "s-dup2" (cdr (assoc "Shared (WS2)" entries)))
    ;; A workspace name typed into the filter matches no candidate
    (null (all-completions "WS1" table))
    (null (all-completions "Workspace" table))))
;;; ---------------------------------------------------------------------------
;;; Queue/steering (session/queue): protocol conversion, mirror diff,
;;; management helpers
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-test--queue-item (id placement text &optional kind)
  "Build one wire-shaped `session/queue' frame item for tests."
  (list (cons 'id id)
        (cons 'placement placement)
        (cons 'message (list (cons 'id id)
                             (cons 'role "user")
                             (cons 'content
                                   (if text
                                       (vector (list (cons 'type "text")
                                                     (cons 'text text)))
                                     []))
                             (cons 'source (list (cons 'kind
                                                       (or kind "user"))))))))

;; Protocol layer: wire alist → struct (field names appear only in the
;; constructor)
(let ((item (dsh-protocol-queue-item--from-alist
             (dsh-emacs-test--queue-item "m1" "steering" "fix the bug"))))
  (dsh-test-assert "queue-protocol-item-extracts-fields"
    (equal "m1" (dsh-protocol-queue-item-id item))
    (eq 'steering (dsh-protocol-queue-item-placement item))
    (equal "fix the bug" (dsh-protocol-queue-item-text item))
    (equal "user" (dsh-protocol-queue-item-kind item))))

;; Protocol layer: frame value (items is a vector) → struct list; missing
;; items is safely empty
(let ((items (dsh-protocol-queue-items-from-alist
              (list (cons 'items
                          (vector (dsh-emacs-test--queue-item
                                   "a" "queued" "first")
                                  (dsh-emacs-test--queue-item
                                   "b" "context" nil "system-summary")))))))
  (dsh-test-assert "queue-protocol-frame-value-normalized"
    (= 2 (length items))
    (equal "first" (dsh-protocol-queue-item-text (nth 0 items)))
    (eq 'context (dsh-protocol-queue-item-placement (nth 1 items))))
  (dsh-test-assert "queue-protocol-frame-value-missing-items-empty"
    (null (dsh-protocol-queue-items-from-alist nil))
    (null (dsh-protocol-queue-items-from-alist '((other . 1))))))

;; Counts: context placement does not enter the Q/S tally (aligned with
;; dsh web QueueDock)
(dsh-test-assert "queue-counts-ignores-context"
  (equal '(2 . 1)
         (dsh-emacs-queue--counts-of
          (list (dsh-protocol-queue-item--from-alist
                 (dsh-emacs-test--queue-item "1" "queued" "a"))
                (dsh-protocol-queue-item--from-alist
                 (dsh-emacs-test--queue-item "2" "queued" "b"))
                (dsh-protocol-queue-item--from-alist
                 (dsh-emacs-test--queue-item "3" "steering" "c"))
                (dsh-protocol-queue-item--from-alist
                 (dsh-emacs-test--queue-item "4" "context" "d"))))))

;; Preview: take the first line, truncate when overlong
(dsh-test-assert "queue-preview-first-line-and-truncation"
  (equal "one" (dsh-emacs-queue-preview "one\ntwo"))
  (equal "abcdefghij" (dsh-emacs-queue-preview "abcdefghij"))
  (equal 40 (length (dsh-emacs-queue-preview
                     (make-string 100 ?x))))
  (string-suffix-p "..." (dsh-emacs-queue-preview (make-string 100 ?x))))

;; diff: consume (disappear), newly queued, newly steering, promote
(let* ((old (list (dsh-protocol-queue-item--from-alist
                   (dsh-emacs-test--queue-item "keep" "queued" "kept"))
                  (dsh-protocol-queue-item--from-alist
                   (dsh-emacs-test--queue-item "gone" "queued" "consumed one")))
                 )
       (new (list (dsh-protocol-queue-item--from-alist
                   (dsh-emacs-test--queue-item "keep" "queued" "kept"))
                  (dsh-protocol-queue-item--from-alist
                   (dsh-emacs-test--queue-item "newq" "queued" "lined up"))
                  (dsh-protocol-queue-item--from-alist
                   (dsh-emacs-test--queue-item "news" "steering" "steered in"))))
       (events (dsh-emacs-queue--diff-events old new nil)))
  (dsh-test-assert "queue-diff-events-consume-queue-steer"
    (member (cons 'running "consumed one") events)
    (member (cons 'queued "lined up") events)
    (member (cons 'steering "steered in") events)
    (= 3 (length events))))

;; diff: an id deleted locally produces no running feedback (deletion
;; confirmed ≠ consumed)
(let* ((item (dsh-protocol-queue-item--from-alist
              (dsh-emacs-test--queue-item "del" "queued" "deleted one")))
       (events (dsh-emacs-queue--diff-events (list item) nil '("del"))))
  (dsh-test-assert "queue-diff-events-suppresses-deleted"
    (null events))
  (dsh-test-assert "queue-diff-events-foreign-disappearance-is-consumption"
    (equal '((running . "deleted one"))
           (dsh-emacs-queue--diff-events (list item) nil nil))))

;; diff: queued→steering promotion (initiated by the other side) reports
;; steering
(let* ((old (list (dsh-protocol-queue-item--from-alist
                   (dsh-emacs-test--queue-item "p" "queued" "promoted"))))
       (new (list (dsh-protocol-queue-item--from-alist
                   (dsh-emacs-test--queue-item "p" "steering" "promoted"))))
       (events (dsh-emacs-queue--diff-events old new nil)))
  (dsh-test-assert "queue-diff-events-promotion-is-steering"
    (equal '((steering . "promoted")) events)))

;; Frame application: the connection's first frame seeds silently (no
;; replay of historical feedback), later frames update the mirror
(let ((buf (get-buffer-create " *t-queue-apply*")))
  (unwind-protect
      (progn
        (with-current-buffer buf
          (dsh-emacs-mode)
          (dsh-emacs-queue-apply buf 'proc-1
                                 (list (cons 'items
                                             (vector (dsh-emacs-test--queue-item
                                                      "s1" "queued" "seeded")))))
          (dsh-test-assert "queue-apply-seeds-first-frame-silently"
            (= 1 (length dsh-emacs--queue-items))
            (equal "seeded" (dsh-protocol-queue-item-text
                             (car dsh-emacs--queue-items))))
          ;; Second frame of the same connection: full mirror replacement
          (dsh-emacs-queue-apply buf 'proc-1
                                 (list (cons 'items
                                             (vector (dsh-emacs-test--queue-item
                                                      "s1" "queued" "seeded")
                                                     (dsh-emacs-test--queue-item
                                                      "s2" "steering" "added")))))
          (dsh-test-assert "queue-apply-replaces-mirror"
            (= 2 (length dsh-emacs--queue-items))
            (eq 'steering (dsh-protocol-queue-item-placement
                           (cadr dsh-emacs--queue-items))))))
    (when (buffer-live-p buf) (kill-buffer buf))))

;; --- Empty-queue submit transient never flashes the echo area (the
;; "C-c C-c flash next message" fix) ---
;; Regression: the protocol only knows queue/steer prompt modes, so a
;; message sent with NOTHING PENDING — idle, or queued behind a running
;; turn — is appended to the host inbox and claimed at the turn start
;; (one `session/queue' frame each, observed live: 10ms apart).  72dbca0
;; added the seq gate only to the session/event path; the queue frame
;; path's diff still surfaced this transient as user events, flashing
;; "queued: …" then "running: …".  Fix: the submit paths arm
;; dsh-emacs--queue-submit-suppress when the mirror is empty; the mirror
;; updates silently meanwhile, and the settling empty frame (the claim)
;; disarms it.  Genuine queueing (items parked) keeps its feedback.
(let ((chat (get-buffer-create " *t-queue-submit-suppress*"))
      (proc (make-pipe-process :name "t-queue-suppress" :buffer nil))
      (announced nil))
  (unwind-protect
      (progn
        (process-put proc 'dsh-emacs-chat-buffer chat)
        (with-current-buffer chat
          (dsh-emacs-mode)
          (setq-local dsh-emacs--buffer-session "sess-sup")
          (cl-letf (((symbol-function 'dsh-emacs-queue--announce)
                     (lambda (_events) (setq announced t)))
                    ((symbol-function 'run-at-time) (lambda (&rest _) t)))
            (setq-local dsh-emacs--queue-submit-suppress t)
            ;; Frame 1: our message is spliced in → mirror updates, no
            ;; flash, the flag survives.  Queue mirrors arrive on the core
            ;; connection's `session/control' stream; `dsh-emacs-queue-apply'
            ;; is the dispatcher's consumer.
            (dsh-emacs-queue-apply
             chat proc
             (list (cons 'items
                         (vector (dsh-emacs-test--queue-item
                                  "x1" "queued" "hello")))))
            (dsh-test-assert "queue-submit-suppress-swallows-splice-in"
              (null announced)
              (= 1 (length dsh-emacs--queue-items))
              (equal "hello" (dsh-protocol-queue-item-text
                              (car dsh-emacs--queue-items)))
              dsh-emacs--queue-submit-suppress)
            (setq announced nil)
            ;; Frame 2: the item is claimed → mirror empty, flag
            ;; disarmed, still no flash
            (dsh-emacs-queue-apply chat proc (list (cons 'items [])))
            (dsh-test-assert "queue-submit-suppress-settles-and-unarms"
              (null announced)
              (null dsh-emacs--queue-items)
              (null dsh-emacs--queue-submit-suppress))
            ;; Reconnect seed frame: the transient stays silent across the
            ;; connection (on a fresh open the splice-in frame IS the
            ;; seed) — the seed seeds silently and keeps the flag, the
            ;; claim frame then disarms it
            (setq-local dsh-emacs--queue-submit-suppress t)
            (dsh-emacs-queue-apply
             chat 'proc-2
             (list (cons 'items
                         (vector (dsh-emacs-test--queue-item
                                  "r1" "queued" "replay")))))
            (dsh-test-assert "queue-submit-suppress-seed-keeps-flag"
              (= 1 (length dsh-emacs--queue-items))
              (null announced)
              dsh-emacs--queue-submit-suppress)
            (dsh-emacs-queue-apply chat 'proc-2 (list (cons 'items [])))
            (dsh-test-assert "queue-submit-suppress-claim-settles-after-seed"
              (null dsh-emacs--queue-items)
              (null announced)
              (null dsh-emacs--queue-submit-suppress)))))
    (when (buffer-live-p chat) (kill-buffer chat))
    (delete-process proc)))

(defun dsh-test-composer-next-row ()
  "Return the displayed Next Message row in this buffer, or nil."
  (when-let* ((beg (text-property-any (point-min) (point-max)
                                    'dsh-emacs-composer-next-row t)))
    (buffer-substring beg (next-single-property-change
                          beg 'dsh-emacs-composer-next-row nil (point-max)))))

;; Preview gating: while the self-submit transient lives (mirror holds only
;; our own message, suppress armed) the `Next: …' row must not paint —
;; a preview would flash the input line on every submit (the literal
;; "flash next message" symptom); once disarmed it paints from the mirror
;; normally.  The mode-line Q/S counts are not gated and still reflect
;; the queue.
(let ((buf (get-buffer-create " *t-queue-next-row-gate*")))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (setq-local dsh-emacs--buffer-session "sess-pfx")
        (setq-local dsh-emacs--queue-submit-suppress t)
        (setq dsh-emacs--queue-items
              (list (dsh-protocol-queue-item--from-alist
                     (dsh-emacs-test--queue-item "g1" "queued" "gated"))))
        (dsh-emacs-composer-render)
        (dsh-test-assert "queue-submit-suppress-gates-next-row"
          (null (dsh-test-composer-next-row)))
        (dsh-emacs-queue--submit-suppress-clear)
        (dsh-emacs-composer-render)
        (dsh-test-assert "queue-submit-suppress-ungates-next-row"
          (dsh-test-composer-next-row)))
    (when (buffer-live-p buf) (kill-buffer buf))))

;; Disarming triggers a repaint: when the timeout lifts the flag while the
;; message is STILL queued (a long busy turn), the `Next: …' preview must
;; come back — frames are the only repaint trigger, the flag change alone
;; is not, so without this the row would stay gone until the next frame
;; arrives.
(let ((buf (get-buffer-create " *t-queue-next-row-restore*"))
      (paints nil))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (setq-local dsh-emacs--buffer-session "sess-pfx2")
        (cl-letf (((symbol-function 'run-at-time)
                   (lambda (_delay _repeat fn) (push fn paints) t)))
          (setq-local dsh-emacs--queue-submit-suppress t)
          (setq dsh-emacs--queue-items
                (list (dsh-protocol-queue-item--from-alist
                       (dsh-emacs-test--queue-item "g2" "queued" "still queued"))))
          (dsh-emacs-composer-render)
          (dsh-test-assert "queue-submit-suppress-holds-row-hidden"
            (null (dsh-test-composer-next-row)))
          (dsh-emacs-queue--submit-suppress-clear)
          (dsh-test-assert "queue-submit-suppress-clear-schedules-repaint"
            (consp paints))
          (dolist (fn paints) (funcall fn))
          (dsh-test-assert "queue-submit-suppress-timeout-restores-row"
            (dsh-test-composer-next-row))))
    (when (buffer-live-p buf) (kill-buffer buf))))

;; The parked case is revealed by STATE, not by a timer: a submit made while
;; a turn is already running can only be claimed at the turn end, so its
;; `Next: …' preview must show even though the submit-suppression is still
;; armed — the old timer-only reveal is what made a queued message appear
;; ~2s late.  The discriminator is the submit-time busy state captured by
;; `dsh-emacs-queue--mark-submit-suppress', not the live spinner.
(let ((buf (get-buffer-create " *t-queue-next-row-busy-reveal*")))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (setq-local dsh-emacs--buffer-session "sess-busy")
        (setq-local dsh-emacs--ml-busy t)
        (dsh-emacs-queue--mark-submit-suppress)
        (setq dsh-emacs--queue-items
              (list (dsh-protocol-queue-item--from-alist
                     (dsh-emacs-test--queue-item "pb" "queued" "parked"))))
        (dsh-emacs-composer-render)
        (dsh-test-assert "queue-submit-suppress-busy-reveals-parked"
          (dsh-test-composer-next-row)
          dsh-emacs--queue-submit-suppress
          dsh-emacs-queue--submit-parked-p)
        (dsh-emacs-queue--submit-suppress-clear))
    (when (buffer-live-p buf) (kill-buffer buf))))

;; A queued submit previews in the Next Message row immediately, before the
;; host's own `session/queue' frame: that frame is one RPC round trip away,
;; and waiting for it made the queued send feel sticky.  The optimistic item
;; is the only local preview state; the host frame (or a failed submit)
;; retires it.
(let ((buf (get-buffer-create " *t-queue-optimistic-submit*"))
      (proc (make-pipe-process :name "t-queue-opt" :buffer nil))
      (cbs nil))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (setq-local dsh-emacs--buffer-session "sess-opt-submit")
        (setq dsh-emacs--queue-items nil
              dsh-emacs--queue-process nil)
        (setq-local dsh-emacs--ml-busy t)
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (_m _p callback) (push callback cbs))))
          (dsh-emacs--submit-deferred "queued now" nil nil))
        (dsh-test-assert "queued-submit-previews-before-host-frame"
          (let ((item (dsh-emacs-queue-next-item)))
            (and item
                 (string= "queued now" (dsh-protocol-queue-item-text item))
                 (eq 'queued (dsh-protocol-queue-item-placement item))))
          (dsh-test-composer-next-row))
        ;; The host's own frame carries the real item: the local preview retires.
        (dsh-emacs-queue-apply
         buf proc
         (list (cons 'items
                     (vector (dsh-emacs-test--queue-item
                              "real" "queued" "queued now")))))
        (dsh-test-assert "queued-submit-preview-cleared-by-host-frame"
          (null dsh-emacs-queue--optimistic-submit)
          (string= "queued now"
                   (dsh-protocol-queue-item-text (dsh-emacs-queue-next-item))))
        ;; A rejected submit drops the local preview with the suppression.
        (dsh-emacs--submit-deferred "queued lost" nil nil)
        (dsh-test-assert "queued-submit-preview-shown-again"
          dsh-emacs-queue--optimistic-submit)
        (funcall (car cbs) nil '((code . "down")))
        (dsh-test-assert "queued-submit-preview-cleared-on-failure"
          (null dsh-emacs-queue--optimistic-submit)))
    (when (process-live-p proc) (delete-process proc))
    (when (buffer-live-p buf) (kill-buffer buf))))

;; An IDLE submit is NOT parked: the host claims it at the turn START, and
;; the send path lights the optimistic spinner on acceptance — both before
;; the claim frame arrives.  The busy reveal must therefore key on whether a
;; turn was ALREADY running when the submit was made, not on the current
;; spinner: keying on the spinner paints our own message on the splice frame
;; and clears it on the claim frame (the flash on `C-c C-c').
(let ((buf (get-buffer-create " *t-queue-next-row-idle-submit*")))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (setq-local dsh-emacs--buffer-session "sess-idle-submit")
        (setq-local dsh-emacs--ml-busy nil)
        (setq dsh-emacs--queue-items nil)
        ;; Idle submit (mirror empty) arms the suppression while NOT busy…
        (dsh-emacs-queue--mark-submit-suppress)
        ;; …then the RPC is accepted and the optimistic spinner lights.
        (setq-local dsh-emacs--ml-busy t)
        ;; The splice frame carries our own just-submitted message.
        (setq dsh-emacs--queue-items
              (list (dsh-protocol-queue-item--from-alist
                     (dsh-emacs-test--queue-item "own" "queued" "hello"))))
        (dsh-emacs-composer-render)
        (dsh-test-assert "queue-idle-submit-splice-does-not-flash-next-row"
          (null (dsh-test-composer-next-row))
          dsh-emacs--queue-submit-suppress)
        (dsh-emacs-queue--submit-suppress-clear))
    (when (buffer-live-p buf) (kill-buffer buf))))

;; A fresh session's queue mirror is seeded by the connection's FIRST frame,
;; which can be EMPTY and arrive between the arm and the splice.  That seed
;; is a baseline, not the claim: treating any empty frame as the claim
;; disarmed the suppression early, so the next frame — our own splice —
;; painted the row and the claim cleared it again (the flash on the first
;; `C-c C-c' in a newly opened session).  The suppression must end only at
;; the empty frame that FOLLOWS our own item.
(let ((buf (get-buffer-create " *t-queue-next-row-empty-seed*"))
      (proc (make-pipe-process :name "t-queue-empty-seed" :buffer nil))
      (announced nil))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (setq-local dsh-emacs--buffer-session "sess-empty-seed")
        (setq-local dsh-emacs--ml-busy nil)
        (setq dsh-emacs--queue-items nil
              dsh-emacs--queue-process nil)
        (cl-letf (((symbol-function 'dsh-emacs-queue--announce)
                   (lambda (events) (setq announced events))))
          (dsh-emacs-queue--mark-submit-suppress)
          ;; Connection seed: empty queue, first frame on this process.
          (dsh-emacs-queue-apply buf proc
                                 (list (cons 'sessionId "sess-empty-seed")
                                       (cons 'items [])))
          (dsh-test-assert "queue-empty-seed-keeps-submit-suppression"
            dsh-emacs--queue-submit-suppress
            (null dsh-emacs-queue--submit-seen-p)
            (null announced))
          ;; Our own splice frame: still suppressed, so no row appears.
          (dsh-emacs-queue-apply
           buf proc
           (list (cons 'sessionId "sess-empty-seed")
                 (cons 'items
                       (vector (dsh-emacs-test--queue-item
                                "own" "queued" "hello")))))
          (dsh-emacs-composer-render)
          (dsh-test-assert "queue-empty-seed-splice-does-not-flash-next-row"
            (null (dsh-test-composer-next-row))
            dsh-emacs-queue--submit-seen-p
            dsh-emacs--queue-submit-suppress
            (null announced))
          ;; The claim frame that follows the splice then disarms.
          (dsh-emacs-queue-apply buf proc
                                 (list (cons 'sessionId "sess-empty-seed")
                                       (cons 'items [])))
          (dsh-test-assert "queue-empty-seed-claim-disarms"
            (null dsh-emacs--queue-submit-suppress)
            (null dsh-emacs--queue-items)
            (null announced)))
        (dsh-emacs-queue--submit-suppress-clear))
    (when (buffer-live-p buf) (kill-buffer buf))
    (delete-process proc)))

;; Submit-path arming/disarming: armed whenever the mirror is EMPTY at
;; submit time — idle (plain path) or behind a running turn (deferred
;; path) — with the defensive disarm timer; parked items keep the flag
;; off (genuine queue/steer feedback must survive); the failure branch
;; disarms (no settling frame will ever arrive).
(let ((buf (get-buffer-create " *t-queue-suppress-arm*"))
      (cbs nil))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (setq-local dsh-emacs--buffer-session "sess-arm")
        (setq dsh-emacs--current-session "sess-arm")
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (_method _params cb) (push cb cbs))))
          ;; Plain path, idle + empty mirror → armed (with the timer)
          (dsh-emacs--ml-busy-clear)
          (dsh-emacs--submit-plain "hello idle")
          (dsh-test-assert "submit-plain-arms-suppress"
            dsh-emacs--queue-submit-suppress
            (timerp dsh-emacs-queue--submit-suppress-timer))
          (dsh-test-assert "submit-plain-idle-submit-is-not-parked"
            (null dsh-emacs-queue--submit-parked-p))
          (dsh-emacs-queue--submit-suppress-clear)
          ;; Plain path, items parked → not armed: "queued:" is genuine
          (setq dsh-emacs--queue-items
                (list (dsh-protocol-queue-item--from-alist
                       (dsh-emacs-test--queue-item "p" "queued" "parked"))))
          (dsh-emacs--submit-plain "hello parked")
          (dsh-test-assert "submit-plain-parked-keeps-announce"
            (null dsh-emacs--queue-submit-suppress))
          (setq dsh-emacs--queue-items nil)
          ;; Deferred path (busy), empty mirror → armed: the running
          ;; turn's submit must not flash "queued:"/"running:" either
          (dsh-emacs--ml-busy-set t)
          (dsh-emacs--submit-deferred "hello busy" nil nil)
          (dsh-test-assert "submit-deferred-arms-when-empty"
            dsh-emacs--queue-submit-suppress
            (timerp dsh-emacs-queue--submit-suppress-timer))
          (dsh-test-assert "submit-deferred-busy-submit-is-parked"
            dsh-emacs-queue--submit-parked-p)
          (dsh-emacs-queue--submit-suppress-clear)
          ;; Deferred path, items parked → not armed
          (setq dsh-emacs--queue-items
                (list (dsh-protocol-queue-item--from-alist
                       (dsh-emacs-test--queue-item "q" "queued" "parked2"))))
          (dsh-emacs--submit-deferred "hello parked busy" nil nil)
          (dsh-test-assert "submit-deferred-parked-keeps-announce"
            (null dsh-emacs--queue-submit-suppress))
          (setq dsh-emacs--queue-items nil)
          (dsh-emacs--ml-busy-clear)
          ;; Failure branch (plain): no splice/claim frames will ever
          ;; settle the transient, so the submit path disarms directly
          (dsh-emacs--submit-plain "hello fail")
          (dsh-test-assert "submit-plain-failure-arms"
            dsh-emacs--queue-submit-suppress)
          (funcall (car cbs) nil '((code . "down")))
          (dsh-test-assert "submit-plain-failure-clears-suppress"
            (null dsh-emacs--queue-submit-suppress))
          (dsh-test-assert "submit-plain-failure-clears-timer"
            (null dsh-emacs-queue--submit-suppress-timer))
          ;; Failure branch (deferred): same disarm
          (dsh-emacs--ml-busy-set t)
          (dsh-emacs--submit-deferred "hello fail busy" nil nil)
          (dsh-test-assert "submit-deferred-failure-arms"
            dsh-emacs--queue-submit-suppress)
          (funcall (car cbs) nil '((code . "down")))
          (dsh-test-assert "submit-deferred-failure-clears-suppress"
            (null dsh-emacs--queue-submit-suppress))
          (dsh-test-assert "submit-deferred-failure-clears-timer"
            (null dsh-emacs-queue--submit-suppress-timer))))
    (when (buffer-live-p buf) (kill-buffer buf))))

;; Multi-session concurrency: the suppression flag, mirror, and timer are
;; isolated per chat buffer — A's transient silence never mutes B's
;; genuine queue feedback, and B's frames never touch A's mirror
;; (queue mirrors arrive on the core connection's `session/control' stream
;; and `dsh-emacs-events--host-item' routes each `queue' item by session-id
;; to that session's live chat buffer, leaving other buffers untouched).
(let* ((old-chats dsh-emacs--chat-buffers)
       (chat-a (get-buffer-create " *t-queue-multi-a*"))
       (chat-b (get-buffer-create " *t-queue-multi-b*"))
       (proc-a (make-pipe-process :name "t-queue-multi-a" :buffer nil))
       (proc-b (make-pipe-process :name "t-queue-multi-b" :buffer nil))
       (announced nil))
  (unwind-protect
      (progn
        (setq dsh-emacs--chat-buffers
              (let ((h (make-hash-table :test 'equal)))
                (puthash "sess-multi-a" chat-a h)
                (puthash "sess-multi-b" chat-b h)
                h))
        (with-current-buffer chat-a
          (dsh-emacs-mode)
          (setq-local dsh-emacs--buffer-session "sess-multi-a"))
        (with-current-buffer chat-b
          (dsh-emacs-mode)
          (setq-local dsh-emacs--buffer-session "sess-multi-b"))
        (cl-letf (((symbol-function 'dsh-emacs-queue--announce)
                   (lambda (_events) (setq announced t)))
                  ((symbol-function 'run-at-time) (lambda (&rest _) t)))
          ;; A's empty-queue submit arms its suppression (B unaffected)
          (with-current-buffer chat-a
            (dsh-emacs-queue--mark-submit-suppress))
          (dsh-test-assert "queue-submit-suppress-buffer-isolated"
            (with-current-buffer chat-a dsh-emacs--queue-submit-suppress)
            (null (with-current-buffer chat-b dsh-emacs--queue-submit-suppress)))
          ;; A session-B queue item → B echoes normally; A's mirror and
          ;; suppression stay untouched.  B's mirror is seeded with an
          ;; empty baseline first (the first frame is the connect snapshot
          ;; by design), so the next frame is a real diff.
          (dsh-emacs-queue-apply chat-b proc-b (list (cons 'items [])))
          (dsh-emacs-events--host-item
           proc-b
           (list (cons 'type "queue")
                 (cons 'sessionId "sess-multi-b")
                 (cons 'items (vector (dsh-emacs-test--queue-item
                                       "b1" "queued" "b-real")))))
          (dsh-test-assert "queue-submit-suppress-multi-session"
            announced
            (with-current-buffer chat-b
              (equal "b-real" (dsh-protocol-queue-item-text
                               (car dsh-emacs--queue-items))))
            (null (with-current-buffer chat-a dsh-emacs--queue-items))
            (with-current-buffer chat-a dsh-emacs--queue-submit-suppress))))
    (setq dsh-emacs--chat-buffers old-chats)
    (when (buffer-live-p chat-a) (kill-buffer chat-a))
    (when (buffer-live-p chat-b) (kill-buffer chat-b))
    (delete-process proc-a)
    (delete-process proc-b)))

;; Event-dispatch level: session/control's `queue' item (value with an
;; items array) is routed by `dsh-emacs-events--host-item' via session-id
;; to that session's chat buffer's dsh-emacs-queue-apply --- the mirror and
;; the [next] preview row update immediately; a queue item for another
;; session finds no open chat buffer (falls back to current-buffer) and
;; does not touch this mirror.
(let* ((old-chats dsh-emacs--chat-buffers)
       (chat (get-buffer-create " *t-queue-dispatch*"))
       (proc (make-pipe-process :name "t-queue-proc" :buffer nil))
       (neutral (get-buffer-create " *t-queue-neutral*"))
       (paints nil))
  (unwind-protect
      (progn
        (setq dsh-emacs--chat-buffers
              (let ((h (make-hash-table :test 'equal)))
                (puthash "sess-q" chat h)
                h))
        (with-current-buffer chat
          (dsh-emacs-mode)
          (setq-local dsh-emacs--buffer-session "sess-q"))
        (with-current-buffer neutral (dsh-emacs-mode))
        (cl-letf (((symbol-function 'run-at-time)
                   (lambda (_delay _repeat fn) (push fn paints) t)))
          ;; A queue item matching the session → routed to that session chat
          ;; buffer's queue-apply; after one redraw at burst end the preview row is
          ;; visible
          (dsh-emacs-events--host-item
           proc
           (list (cons 'type "queue")
                 (cons 'sessionId "sess-q")
                 (cons 'items (vector (dsh-emacs-test--queue-item
                                       "q1" "queued" "dispatched")))))
          (funcall (car paints))
          (setq paints nil)
          (with-current-buffer chat
            (dsh-test-assert "queue-frame-dispatch-routes-to-chat"
              (= 1 (length dsh-emacs--queue-items))
              (equal "dispatched"
                     (dsh-protocol-queue-item-text (car dsh-emacs--queue-items)))
              (dsh-test-composer-next-row)))
          ;; Another session's queue item (no open chat buffer) → lands in
          ;; current-buffer, this mirror and preview row stay as they were
          (with-current-buffer neutral
            (dsh-emacs-events--host-item
             proc
             (list (cons 'type "queue")
                   (cons 'sessionId "sess-other")
                   (cons 'items []))))
          (with-current-buffer chat
            (dsh-test-assert "queue-frame-dispatch-filters-foreign-session"
              (= 1 (length dsh-emacs--queue-items))
              (equal "dispatched"
                     (dsh-protocol-queue-item-text (car dsh-emacs--queue-items)))
              (dsh-test-composer-next-row)))))
    (setq dsh-emacs--chat-buffers old-chats)
    (when (buffer-live-p chat) (kill-buffer chat))
    (when (buffer-live-p neutral) (kill-buffer neutral))
    (when (process-live-p proc) (delete-process proc))))

;; Mode-line indicator: hidden for an empty queue, shows [Qn Sm] when
;; non-empty, context not counted
(let ((buf (get-buffer-create " *t-queue-indicator*")))
  (unwind-protect
      (progn
        (with-current-buffer buf
          (dsh-emacs-mode)
          (dsh-test-assert "queue-indicator-hidden-when-empty"
            (string-empty-p (dsh-emacs-modeline--queue-indicator)))
          (setq dsh-emacs--queue-items
                (list (dsh-protocol-queue-item--from-alist
                       (dsh-emacs-test--queue-item "1" "queued" "a"))
                      (dsh-protocol-queue-item--from-alist
                       (dsh-emacs-test--queue-item "2" "queued" "b"))
                      (dsh-protocol-queue-item--from-alist
                       (dsh-emacs-test--queue-item "3" "steering" "c"))))
          (let ((ind (dsh-emacs-modeline--queue-indicator)))
            (dsh-test-assert "queue-indicator-shows-counts"
              (string-match-p "\\[Q2 S1\\]" ind)
              (eq 'dsh-emacs-modeline-queue-face
                  (get-text-property 0 'face ind)))
            (dsh-test-assert "queue-indicator-reuses-text-and-keymap"
              (eq ind (dsh-emacs-modeline--queue-indicator))
              (eq (lookup-key (get-text-property 0 'local-map ind)
                              [mode-line mouse-1])
                  #'dsh-emacs-list-queue)))
          (setq dsh-emacs--queue-items (cdr dsh-emacs--queue-items))
          (dsh-test-assert "queue-indicator-updates-cached-counts"
            (string-match-p "\\[Q1 S1\\]"
                            (dsh-emacs-modeline--queue-indicator))))
        ;; A non-dsh buffer does not touch the mode line
        (with-temp-buffer
          (dsh-test-assert "queue-indicator-outside-chat-empty"
            (string-empty-p (dsh-emacs-modeline--queue-indicator)))))
    (when (buffer-live-p buf) (kill-buffer buf))))

;; next preview = the next item in the host's actual send order: in-flight
;; steering (next-step, injected into the running agent's next step) takes
;; precedence over queued (next-turn); context is host-injected content and
;; is never previewed. That is, "whichever one is steered, next shows that
;; one (when it becomes the next-step)"
(let* ((steer-two (mapcar (lambda (x) (dsh-protocol-queue-item--from-alist x))
                          (list (dsh-emacs-test--queue-item "a" "steering" "Alpha")
                                (dsh-emacs-test--queue-item "c" "steering" "Charlie")
                                (dsh-emacs-test--queue-item "b" "queued" "Beta"))))
       (mixed (list (dsh-protocol-queue-item--from-alist
                     (dsh-emacs-test--queue-item "a" "steering" "Alpha"))
                    (dsh-protocol-queue-item--from-alist
                     (dsh-emacs-test--queue-item "b" "queued" "Beta"))))
       (queued-only (list (dsh-protocol-queue-item--from-alist
                           (dsh-emacs-test--queue-item "b" "queued" "Beta"))))
       (context-first (list (dsh-protocol-queue-item--from-alist
                             (dsh-emacs-test--queue-item "x" "context" "X"))
                            (dsh-protocol-queue-item--from-alist
                             (dsh-emacs-test--queue-item "b" "queued" "Beta"))
                            (dsh-protocol-queue-item--from-alist
                             (dsh-emacs-test--queue-item "a" "steering" "Alpha")))))
  (let ((dsh-emacs--queue-items steer-two))
    (dsh-test-assert "queue-next-item-steering-led"
      (equal "Alpha" (dsh-protocol-queue-item-text
                      (dsh-emacs-queue-next-item)))))
  (let ((dsh-emacs--queue-items mixed))
    (dsh-test-assert "queue-next-item-steering-over-queued"
      (equal "Alpha" (dsh-protocol-queue-item-text
                      (dsh-emacs-queue-next-item)))))
  (let ((dsh-emacs--queue-items queued-only))
    (dsh-test-assert "queue-next-item-falls-back-to-queued"
      (equal "Beta" (dsh-protocol-queue-item-text
                     (dsh-emacs-queue-next-item)))))
  (let ((dsh-emacs--queue-items context-first))
    (dsh-test-assert "queue-next-item-skips-context"
      (equal "Alpha" (dsh-protocol-queue-item-text
                      (dsh-emacs-queue-next-item)))))
  (let ((dsh-emacs--queue-items nil))
    (dsh-test-assert "queue-next-item-empty-nil"
      (null (dsh-emacs-queue-next-item)))))

;; Next Message uses the same prompt color as the historical next-preview prefix.
(let ((item (dsh-protocol-queue-item--from-alist
             (dsh-emacs-test--queue-item "a" "queued" "Alpha"))))
  (cl-letf (((symbol-function 'image-type-available-p) (lambda (_type) t))
            ((symbol-function 'create-image)
             (lambda (_data _type _data-p &rest props) (cons 'image props))))
    (let ((row (dsh-emacs-composer--render-next-row item)))
      (dsh-test-assert "composer-next-icon-is-chrome"
        (equal "   Alpha" (substring-no-properties row))
        (eq 'image (car (get-text-property 0 'display row)))
        (eq 'dsh-emacs-input-prompt-face (get-text-property 0 'face row)))))
  (cl-letf (((symbol-function 'image-type-available-p) (lambda (_type) nil)))
    (let ((row (dsh-emacs-composer--render-next-row item)))
      (dsh-test-assert "composer-next-text-fallback-is-chrome"
        (equal "Next: Alpha" (substring-no-properties row))
        (eq 'dsh-emacs-input-prompt-face (get-text-property 0 'face row))))))

;; Integration regression: after steering one item, the server first
;; pushes a remove frame (mirror cleared), then a next-step frame (the
;; entry returns as steering) --- in the host's send order the in-flight
;; steering is the next item, so after reinsert the next preview shows that
;; entry. Preview-row redraws are merged per frame burst (run-at-time 0):
;; when remove+reinsert land in the same burst only the final state is
;; drawn, and the momentary blank window caused by remove never appears on
;; screen.
(let ((buf (get-buffer-create " *t-queue-next-row-clear*"))
      (paints nil))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (cl-letf (((symbol-function 'run-at-time)
                   (lambda (_delay _repeat fn) (push fn paints) t))
                  ;; The echo self-clear timer goes through run-with-timer (internally
                  ;; also
                  ;; run-at-time), take it over as well so the flash closure does not mix
                  ;; into paints
                  ((symbol-function 'run-with-timer)
                   (lambda (&rest _) t)))
          ;; Burst 1: seed frame → one redraw at burst end
          (dsh-emacs-queue-apply
           buf 'proc
           (list (cons 'items
                       (vector (dsh-emacs-test--queue-item
                                "a" "queued" "Alpha")))))
          (funcall (car paints))
          (setq paints nil)
          (dsh-test-assert "queue-next-row-steer-before-shows-next"
            (and (dsh-test-composer-next-row)
                 (let ((plain (substring-no-properties
                               (dsh-test-composer-next-row))))
                   (and (string-search "Alpha" plain)
                        ;; SVG available: the icon preview line starts with icon(space);
                        ;; otherwise fall back to the text form
                        (if (image-type-available-p 'svg)
                            (string-prefix-p " " plain)
                          (string-search "Next:" plain))))))
          ;; Burst 2: remove frame (mirror cleared immediately, preview line not
          ;; redrawn yet) + steering regression frame
          (dsh-emacs-queue-apply buf 'proc (list (cons 'items [])))
          (dsh-test-assert "queue-mirror-clears-on-steer-remove"
            (null dsh-emacs--queue-items)
            (null (dsh-emacs-queue-next-item)))
          (dsh-emacs-queue-apply
           buf 'proc
           (list (cons 'items
                       (vector (dsh-emacs-test--queue-item
                                "a" "steering" "Alpha")))))
          ;; Two frames combine into one redraw
          (dsh-test-assert "queue-burst-remove-reinsert-single-paint"
            (= 1 (length paints)))
          (funcall (car paints))
          (setq paints nil)
          (dsh-test-assert "queue-next-row-steer-reinsert-shows-inflight"
            (and (dsh-test-composer-next-row)
                 (string-search "Alpha"
                                (substring-no-properties
                                 (dsh-test-composer-next-row)))))))
    (when (buffer-live-p buf) (kill-buffer buf))))

;; Flash regression: when the host splices in an item and instantly claims it
;; (item→empty two frames land in the same burst), the [next] preview line
;; must not hit the screen — the merged redraw only looks at the final mirror
;; after the burst ends (empty → no preview line).
;; Control: an item that truly stays (still present after the burst) → shown
;; normally after the redraw.
(let ((buf (get-buffer-create " *t-queue-burst*"))
      (paints nil))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (setq-local dsh-emacs--buffer-session "sess-burst")
        (cl-letf (((symbol-function 'run-at-time)
                   (lambda (_delay _repeat fn) (push fn paints) t))
                  ((symbol-function 'run-with-timer)
                   (lambda (&rest _) t)))
          ;; Same burst: enqueue frame + claim frame
          (dsh-emacs-queue-apply
           buf 'proc
           (list (cons 'items
                       (vector (dsh-emacs-test--queue-item
                                "b1" "queued" "bursty")))))
          (dsh-emacs-queue-apply buf 'proc (list (cons 'items [])))
          (dsh-test-assert "queue-burst-transient-single-paint-scheduled"
            (= 1 (length paints)))
          (funcall (car paints))
          (setq paints nil)
          (dsh-test-assert "queue-burst-claimed-item-never-paints"
            (null (dsh-test-composer-next-row))
            (null dsh-emacs--queue-items))
          ;; Control: the item truly stays (still present after the burst) → the preview
          ;; line shows after the redraw
          (dsh-emacs-queue-apply
           buf 'proc
           (list (cons 'items
                       (vector (dsh-emacs-test--queue-item
                                "b2" "queued" "parked")))))
          (funcall (car paints))
          (setq paints nil)
          (dsh-test-assert "queue-burst-parked-item-paints"
            (and (dsh-test-composer-next-row)
                 (string-search "parked"
                                (substring-no-properties
                                 (dsh-test-composer-next-row)))))))
    (when (buffer-live-p buf) (kill-buffer buf))))

;; Deferred submit: mode resolution (explicit / behavior fallback) and the
;; payload mode field
(let ((buf (get-buffer-create " *t-queue-deferred*"))
      (calls nil))
  (unwind-protect
      (progn
        (with-current-buffer buf
          (setq-local dsh-emacs--buffer-session "sess-q")
          (setq dsh-emacs--input-marker nil))
        (let ((dsh-emacs-busy-enter-behavior 'queue))
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method params _cb)
                       (push (list method params) calls))))
            ;; Explicit steer
            (with-current-buffer buf
              (dsh-emacs--submit-deferred "redirect now" nil 'steer))
            ;; behavior=queue fallback
            (with-current-buffer buf
              (dsh-emacs--submit-deferred "line up" nil nil))
            (let ((dsh-emacs-busy-enter-behavior 'steer))
              (with-current-buffer buf
                (dsh-emacs--submit-deferred "wake up" nil nil)))
            (dsh-test-assert "queue-deferred-mode-resolution"
              (= 3 (length calls))
              (equal "session/prompt" (car (nth 2 calls)))
              (equal "steer"
                     (cdr (assq 'mode
                                (cdr (assq 'request (cadr (nth 2 calls)))))))
              (equal "queue"
                     (cdr (assq 'mode
                                (cdr (assq 'request (cadr (nth 1 calls)))))))
              (equal "steer"
                     (cdr (assq 'mode
                                (cdr (assq 'request (cadr (nth 0 calls))))))))
            (dsh-test-assert "queue-deferred-payload-shape"
              (equal "sess-q"
                     (cdr (assq 'sessionId
                                (cdr (assq 'request (cadr (nth 0 calls)))))))
              (equal "wake up"
                     (cdr (assq 'text
                                (aref (cdr (assq 'content
                                                 (cdr (assq 'request
                                                            (cadr (nth 0 calls))))))
                                      0))))))))
    (when (buffer-live-p buf) (kill-buffer buf))))

;; C-c C-c dispatch: busy + behavior semantics (stop=interrupt, empty input
;; =interrupt, queue/steer=deferred submit)
(let ((buf (get-buffer-create " *t-send-or-stop*"))
      (interrupted nil)
      (submitted nil))
  (unwind-protect
      (let ((dsh-emacs-busy-enter-behavior 'queue))
        (cl-letf (((symbol-function 'dsh-emacs-server-ensure) #'ignore)
                  ((symbol-function 'dsh-emacs--busy-p) (lambda (&rest _) t))
                  ((symbol-function 'dsh-emacs--get-input)
                   (lambda (&rest _) "the next thing"))
                  ((symbol-function 'dsh-emacs-interrupt-turn)
                   (lambda (&rest _) (setq interrupted t)))
                  ((symbol-function 'dsh-emacs--submit-prompt)
                   (lambda (message &optional images mode)
                     (setq submitted (list message mode)))))
          ;; busy + queue + text → deferred submit (mode queue)
          (with-current-buffer buf
            (dsh-emacs-send-or-stop))
          (dsh-test-assert "send-or-stop-busy-queue-submits"
            (null interrupted)
            (equal '("the next thing" queue) submitted))
          ;; C-u explicit steer
          (setq submitted nil current-prefix-arg '(4))
          (with-current-buffer buf
            (dsh-emacs-send-or-stop))
          (dsh-test-assert "send-or-stop-prefix-steers-from-queue"
            (equal '("the next thing" steer) submitted))
          ;; With the default steer, C-u is still steer and does not flip to queue
          (setq submitted nil)
          (let ((dsh-emacs-busy-enter-behavior 'steer))
            (with-current-buffer buf
              (dsh-emacs-send-or-stop)))
          (dsh-test-assert "send-or-stop-prefix-steers-from-steer"
            (equal '("the next thing" steer) submitted))
          ;; busy + empty input → interrupt
          (setq submitted nil current-prefix-arg nil)
          (cl-letf (((symbol-function 'dsh-emacs--get-input)
                     (lambda (&rest _) "")))
            (with-current-buffer buf
              (dsh-emacs-send-or-stop)))
          (dsh-test-assert "send-or-stop-busy-empty-interrupts"
            interrupted
            (null submitted))
          ;; behavior=stop → interrupt (byte-level legacy behavior)
          (setq interrupted nil submitted nil)
          (let ((dsh-emacs-busy-enter-behavior 'stop)
                (current-prefix-arg nil))
            (with-current-buffer buf
              (dsh-emacs-send-or-stop)))
          (dsh-test-assert "send-or-stop-stop-behavior-interrupts"
            interrupted
            (null submitted))
          ;; Even with the default stop, C-u is still explicit steer
          (setq interrupted nil submitted nil current-prefix-arg '(4))
          (let ((dsh-emacs-busy-enter-behavior 'stop))
            (with-current-buffer buf
              (dsh-emacs-send-or-stop)))
          (dsh-test-assert "send-or-stop-prefix-steers-from-stop"
            (null interrupted)
            (equal '("the next thing" steer) submitted))
          ;; Even when local busy state has not lit up yet, C-u is still explicit steer:
          ;; it must not degrade to a plain queue submit (which would also wrongly
          ;; optimistically render the user line).
          (setq interrupted nil submitted nil)
          (cl-letf (((symbol-function 'dsh-emacs--busy-p) (lambda (&rest _) nil)))
            (with-current-buffer buf
              (dsh-emacs-send-or-stop)))
          (dsh-test-assert "send-or-stop-prefix-steers-when-local-idle"
            (null interrupted)
            (equal '("the next thing" steer) submitted))
          ;; idle + no prefix → plain submit (no mode)
          (setq submitted nil current-prefix-arg nil)
          (cl-letf (((symbol-function 'dsh-emacs--busy-p) (lambda (&rest _) nil)))
            (with-current-buffer buf
              (dsh-emacs-send-or-stop)))
          (dsh-test-assert "send-or-stop-idle-submits-plain"
            (null interrupted)
            (equal '("the next thing" nil) submitted))))
    (when (buffer-live-p buf) (kill-buffer buf))))

;; The core session-status projection can lead the chat's turn/start frame.
;; Plain C-c C-c must honor that authoritative running bit instead of taking
;; the optimistic plain-submit path and rendering a premature user row.
(let ((buf (get-buffer-create " *t-send-host-running*"))
      (submitted nil)
      (dsh-emacs--sessions
       (dsh-emacs-test--session-items
        '(((sessionId . "host-running") (running . t))))))
  (unwind-protect
      (cl-letf (((symbol-function 'dsh-emacs-server-ensure) #'ignore)
                ((symbol-function 'dsh-emacs--get-input)
                 (lambda () "queue behind host turn"))
                ((symbol-function 'dsh-emacs--submit-prompt)
                 (lambda (message &optional _images mode)
                   (setq submitted (list message mode)))))
        (with-current-buffer buf
          (setq-local dsh-emacs--buffer-session "host-running"
                      dsh-emacs--ml-busy nil)
          (let ((current-prefix-arg nil)
                (dsh-emacs-busy-enter-behavior 'queue))
            (dsh-emacs-send-or-stop)))
        (dsh-test-assert "send-or-stop-host-running-uses-deferred-queue"
          (equal '("queue behind host turn" queue) submitted)))
    (when (buffer-live-p buf) (kill-buffer buf))))

;; updateQueue action: wire shape of remove/steer/edit
(let ((buf (get-buffer-create " *t-queue-actions*"))
      (calls nil))
  (unwind-protect
      (progn
        (with-current-buffer buf
          (setq-local dsh-emacs--buffer-session "sess-a")
          (let ((item (dsh-protocol-queue-item--from-alist
                       (dsh-emacs-test--queue-item "it1" "queued" "x"))))
            (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                       (lambda (method params _cb)
                         (push (list method params) calls))))
              (dsh-emacs-queue--delete item)
              (dsh-emacs-queue--steer item)
              (dsh-emacs-queue--edit item "rewritten")
              (let* ((ordered (nreverse (copy-sequence calls)))
                     (reqs (mapcar (lambda (call)
                                     (cdr (assq 'request (cadr call))))
                                   ordered))
                     (actions (mapcar (lambda (req)
                                        (cdr (assq 'action req)))
                                      reqs)))
                (dsh-test-assert "queue-update-wire-actions"
                  (= 3 (length ordered))
                  (equal "session/updateQueue" (car (car ordered)))
                  (equal '((kind . "remove")) (nth 0 actions))
                  (equal '((kind . "steer")) (nth 1 actions))
                  (equal "it1" (cdr (assq 'itemId (car reqs))))
                  (equal "sess-a" (cdr (assq 'sessionId (car reqs))))
                  (equal "rewritten"
                         (cdr (assq 'text
                                    (aref (cdr (assq 'content (nth 2 actions))) 0)))))))))
        ;; Rollback on failed delete: consumption feedback is not swallowed
        (with-current-buffer buf
          (setq dsh-emacs--queue-deleted '("it1"))
          (let ((item (dsh-protocol-queue-item--from-alist
                       (dsh-emacs-test--queue-item "it1" "queued" "x"))))
            (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                       (lambda (_method _params cb) (funcall cb nil '((code . "x"))))))
              (dsh-emacs-queue--delete item))
            (dsh-test-assert "queue-delete-rollback-on-error"
              (null dsh-emacs--queue-deleted)))))
    (when (buffer-live-p buf) (kill-buffer buf))))

;; A successful local operation optimistically updates the mirror: steer is
;; visible immediately (placement → steering + deleted suppresses the temporary
;; remove frame), without waiting for the session/queue frame round trip
(let ((buf (get-buffer-create " *t-queue-steer-opt*")))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (setq-local dsh-emacs--buffer-session "sess-opt")
        (setq dsh-emacs--queue-items
              (list (dsh-protocol-queue-item--from-alist
                     (dsh-emacs-test--queue-item "o1" "queued" "origin"))))
        (let ((cb nil))
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (_method _params callback) (setq cb callback))))
            (dsh-emacs-queue--steer (car dsh-emacs--queue-items))
            (dsh-test-assert "queue-steer-before-success-unchanged"
              (eq 'queued (dsh-protocol-queue-item-placement
                           (car dsh-emacs--queue-items))))
            (funcall cb t nil)
            (dsh-test-assert "queue-steer-success-marks-steering-optimistically"
              (eq 'steering (dsh-protocol-queue-item-placement
                             (car dsh-emacs--queue-items)))
              (member "o1" dsh-emacs--queue-deleted)))))
    (when (buffer-live-p buf) (kill-buffer buf))))

;; Edit succeeds: mirror text optimistically replaced, prefix preview immediately
;; reflects the new text
(let ((buf (get-buffer-create " *t-queue-edit-opt*")))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (setq-local dsh-emacs--buffer-session "sess-opt")
        (setq dsh-emacs--queue-items
              (list (dsh-protocol-queue-item--from-alist
                     (dsh-emacs-test--queue-item "o2" "queued" "old text"))))
        (let ((cb nil))
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (_method _params callback) (setq cb callback))))
            (dsh-emacs-queue--edit (car dsh-emacs--queue-items) "new text")
            (funcall cb t nil)
            (dsh-test-assert "queue-edit-success-updates-text-optimistically"
              (equal "new text"
                     (dsh-protocol-queue-item-text
                      (car dsh-emacs--queue-items)))))))
    (when (buffer-live-p buf) (kill-buffer buf))))

;; Delete succeeds: the entry is removed from the mirror immediately
(let ((buf (get-buffer-create " *t-queue-delete-opt*")))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (setq-local dsh-emacs--buffer-session "sess-opt")
        (setq dsh-emacs--queue-items
              (list (dsh-protocol-queue-item--from-alist
                     (dsh-emacs-test--queue-item "o3" "queued" "gone"))))
        (let ((cb nil))
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (_method _params callback) (setq cb callback))))
            (dsh-emacs-queue--delete (car dsh-emacs--queue-items))
            (funcall cb t nil)
            (dsh-test-assert "queue-delete-success-removes-optimistically"
              (null dsh-emacs--queue-items)))))
    (when (buffer-live-p buf) (kill-buffer buf))))

;; User-visible contract regression: successful steer/delete optimistically
;; refreshes the [next] prefix (without waiting for the session/queue frame)
;; — the mirror is only necessary, not sufficient; assert directly that the
;; input-line prefix text changed.
;; In host send order: steer the second entry → next immediately shows the
;; steered one (in-flight steering leads queued); after that entry is consumed
;; it falls back to the queue head; delete the queue head → moves to the next
;; item; delete all → cleared; steer the queue head → the text stays the head
;; (it is the next one).
(let ((buf (get-buffer-create " *t-prefix-opt-steer*"))
      (calls nil))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (setq-local dsh-emacs--buffer-session "sess-pfx")
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (_method _params callback) (push callback calls))))
          (dsh-emacs-queue-apply
           buf 'proc
           (list (cons 'items
                       (vector (dsh-emacs-test--queue-item "p1" "queued" "First")
                               (dsh-emacs-test--queue-item "p2" "queued" "Second")))))
          ;; steer the second entry (not the queue head): next immediately flips to the
          ;; steered Second
          (let ((item (cl-find "p2" dsh-emacs--queue-items
                               :key (lambda (i) (dsh-protocol-queue-item-id i))
                               :test #'string=)))
            (dsh-emacs-queue--steer item)
            (let ((cb (car calls))) (setq calls (cdr calls)) (funcall cb t nil)))
          (dsh-test-assert "queue-next-row-optimistic-steer-second-flips"
            (and (dsh-test-composer-next-row)
                 (string-search "Second"
                                (substring-no-properties (dsh-test-composer-next-row)))
                 (not (string-search "First"
                                     (substring-no-properties
                                      (dsh-test-composer-next-row))))))
          ;; That in-flight entry is consumed (deleted): next falls back to the queue head
          ;; First
          (let ((item (cl-find "p2" dsh-emacs--queue-items
                               :key (lambda (i) (dsh-protocol-queue-item-id i))
                               :test #'string=)))
            (dsh-emacs-queue--delete item)
            (let ((cb (car calls))) (setq calls (cdr calls)) (funcall cb t nil)))
          (dsh-test-assert "queue-next-row-optimistic-steered-consumed-falls-back"
            (and (dsh-test-composer-next-row)
                 (string-search "First"
                                (substring-no-properties (dsh-test-composer-next-row)))
                 (not (string-search "Second"
                                     (substring-no-properties
                                      (dsh-test-composer-next-row))))))))
    (when (buffer-live-p buf) (kill-buffer buf))))

(let ((buf (get-buffer-create " *t-prefix-opt-delete*"))
      (calls nil))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (setq-local dsh-emacs--buffer-session "sess-pfx")
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (_method _params callback) (push callback calls))))
          (dsh-emacs-queue-apply
           buf 'proc
           (list (cons 'items
                       (vector (dsh-emacs-test--queue-item "p3" "queued" "Third")
                               (dsh-emacs-test--queue-item "p4" "queued" "Fourth")))))
          (let ((item (cl-find "p3" dsh-emacs--queue-items
                               :key (lambda (i) (dsh-protocol-queue-item-id i))
                               :test #'string=)))
            (dsh-emacs-queue--delete item)
            (let ((cb (car calls))) (setq calls (cdr calls)) (funcall cb t nil)))
          (dsh-test-assert "queue-next-row-optimistic-delete-first-flips"
            (and (dsh-test-composer-next-row)
                 (string-search "Fourth"
                                (substring-no-properties (dsh-test-composer-next-row)))
                 (not (string-search "Third"
                                     (substring-no-properties
                                      (dsh-test-composer-next-row))))))
          (let ((item (cl-find "p4" dsh-emacs--queue-items
                               :key (lambda (i) (dsh-protocol-queue-item-id i))
                               :test #'string=)))
            (dsh-emacs-queue--delete item)
            (let ((cb (car calls))) (setq calls (cdr calls)) (funcall cb t nil)))
          (dsh-test-assert "queue-next-row-optimistic-delete-only-clears"
            (null (dsh-test-composer-next-row)))))
    (when (buffer-live-p buf) (kill-buffer buf))))

(let ((buf (get-buffer-create " *t-prefix-opt-head*"))
      (calls nil))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (setq-local dsh-emacs--buffer-session "sess-pfx")
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (_method _params callback) (push callback calls))))
          (dsh-emacs-queue-apply
           buf 'proc
           (list (cons 'items
                       (vector (dsh-emacs-test--queue-item "p5" "queued" "Fifth")
                               (dsh-emacs-test--queue-item "p6" "queued" "Sixth")))))
          (let ((item (cl-find "p5" dsh-emacs--queue-items
                               :key (lambda (i) (dsh-protocol-queue-item-id i))
                               :test #'string=)))
            (dsh-emacs-queue--steer item)
            (let ((cb (car calls))) (setq calls (cdr calls)) (funcall cb t nil)))
          ;; steer the queue head: next stays the queue head (it is the host's next one,
          ;; just changed to in-flight state)
          (dsh-test-assert "queue-next-row-optimistic-steer-head-keeps-head"
            (and (dsh-test-composer-next-row)
                 (string-search "Fifth"
                                (substring-no-properties (dsh-test-composer-next-row)))
                 (not (string-search "Sixth"
                                     (substring-no-properties
                                      (dsh-test-composer-next-row))))))))
    (when (buffer-live-p buf) (kill-buffer buf))))

;; Queue manager: a single C-g at any layer exits cleanly (no residue, no error)
(let ((buf (get-buffer-create " *t-queue-quit*"))
      (completed nil))
  (unwind-protect
      (progn
        (with-current-buffer buf
          (dsh-emacs-mode)
          (setq-local dsh-emacs--buffer-session "sess-q")
          (setq dsh-emacs--queue-items
                (list (dsh-protocol-queue-item--from-alist
                       (dsh-emacs-test--queue-item "i1" "queued" "one")))))
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (&rest _) (signal 'quit nil))))
          (with-current-buffer buf
            (condition-case nil
                (progn (dsh-emacs-list-queue) (setq completed t))
              ((error quit) (setq completed nil)))))
        (dsh-test-assert "queue-manager-one-c-g-cancels"
          completed))
    (when (buffer-live-p buf) (kill-buffer buf))))

;; Queue menu: menu keys act on entry resolution (vertico highlight > typed
;; exact/prefix > queue-head fallback)
(let* ((a (dsh-protocol-queue-item--from-alist
           (dsh-emacs-test--queue-item "a" "queued" "fix the bug")))
       (b (dsh-protocol-queue-item--from-alist
           (dsh-emacs-test--queue-item "b" "steering" "steered now")))
       (table (list (cons "[Q] fix the bug" a)
                    (cons "[S] steered now" b)))
       (dsh-emacs--queue-pick-table table))
  (cl-letf (((symbol-function 'minibuffer-contents)
             (lambda () "fix")))
    (dsh-test-assert "queue-menu-item-resolves-first"
      (equal a (dsh-emacs-queue--menu-item))))
  (cl-letf (((symbol-function 'minibuffer-contents)
             (lambda () "[S] steered now")))
    (dsh-test-assert "queue-menu-item-resolves-typed"
      (equal b (dsh-emacs-queue--menu-item))))
  (cl-letf (((symbol-function 'minibuffer-contents)
             (lambda () "")))
    (dsh-test-assert "queue-menu-item-resolves-first-fallback"
      (equal a (dsh-emacs-queue--menu-item)))))

;; Queue menu: vertico highlight path — reads vertico--index/vertico--candidates
;; directly (the old accessor `vertico--current' no longer exists, and a string
;; assoc fails and falls back to the queue head, so the old implementation is
;; bound to fail). equal ignores text properties, so faces on candidates do not
;; affect matching
(let ((buf (get-buffer-create " *t-queue-vertico*")))
  (unwind-protect
      (with-current-buffer buf
        (defvar vertico-mode)                     ; batch does not load vertico
        (defvar-local vertico--index -1)
        (defvar-local vertico--candidates nil)
        (setq vertico-mode t)
        (setq vertico--index 1)
        (setq vertico--candidates
              (list (propertize "[Q] fix the bug" 'face 'completions-common-part)
                    (propertize "[S] steered now" 'face 'vertico-current)))
        (let* ((a (dsh-protocol-queue-item--from-alist
                   (dsh-emacs-test--queue-item "a" "queued" "fix the bug")))
               (b (dsh-protocol-queue-item--from-alist
                   (dsh-emacs-test--queue-item "b" "steering" "steered now")))
               (dsh-emacs--queue-pick-table
                (list (cons "[Q] fix the bug" a)
                      (cons "[S] steered now" b))))
          (cl-letf (((symbol-function 'minibuffer-contents)
                     (lambda () "")))
            (dsh-test-assert "queue-menu-item-vertico-highlight-wins"
              (equal b (dsh-emacs-queue--menu-item))))
          (setq vertico--index 0)
          (dsh-test-assert "queue-menu-item-vertico-index-0"
            (equal a (dsh-emacs-queue--menu-item)))))
    (when (buffer-live-p buf) (kill-buffer buf))))

;; Queue menu command: actions are deferred via run-at-time until after the
;; minibuffer closes, then run in the chat buffer that opened the menu. In the
;; real environment exit-minibuffer is (throw 'exit nil), so code after exit in
;; the command never runs — actions must be scheduled as a timer before exit.
;; The test simulates the real throw (catch 'exit wraps the command), asserting
;; the RPC is not executed inline and can only fire via the deferred timer.
(let ((calls nil)
      (deferred nil)
      (chat (get-buffer-create " *t-queue-chat*"))
      (table (list (cons "[Q] first"
                         (dsh-protocol-queue-item--from-alist
                          (dsh-emacs-test--queue-item "m1" "queued" "first")))
                   (cons "[Q] second"
                         (dsh-protocol-queue-item--from-alist
                          (dsh-emacs-test--queue-item "m2" "queued" "second"))))))
  (unwind-protect
      (with-current-buffer chat
        (setq-local dsh-emacs--buffer-session "sess-q")
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (method params _cb)
                     (let* ((req (cdr (assq 'request params)))
                            (action (cdr (assq 'action req))))
                       (push (list method
                                   (cdr (assq 'itemId req))
                                   (cdr (assq 'kind action)))
                             calls))))
                  ((symbol-function 'minibuffer-contents)
                   (lambda () ""))
                  ((symbol-function 'run-at-time)
                   (lambda (_delay _repeat fn) (push fn deferred)))
                  ((symbol-function 'minibuffer-selected-window)
                   (lambda () (selected-window))))
          (let ((dsh-emacs--queue-pick-table table))
            (catch 'exit
              (dsh-emacs-queue--menu-delete)))
          ;; exit already threw: the rest of the command is skipped, RPC not run inline
          (dsh-test-assert "queue-menu-action-not-inline-after-exit"
            (null calls))
          ;; The action can only fire via the timer registered before exit
          (dolist (fn (nreverse deferred)) (funcall fn))
          (dsh-test-assert "queue-menu-delete-runs-in-chat-buffer"
            (equal '("session/updateQueue" "m1" "remove")
                   (car (nreverse calls))))))
    (when (buffer-live-p chat) (kill-buffer chat))))

;; x key deletes the whole queue: likewise register the timer first, then exit,
;; and RPC each entry one by one after confirmation
(let ((calls nil)
      (deferred nil)
      (chat (get-buffer-create " *t-queue-chat*"))
      (table (list (cons "[Q] first"
                         (dsh-protocol-queue-item--from-alist
                          (dsh-emacs-test--queue-item "x1" "queued" "first")))
                   (cons "[Q] second"
                         (dsh-protocol-queue-item--from-alist
                          (dsh-emacs-test--queue-item "x2" "queued" "second"))))))
  (unwind-protect
      (with-current-buffer chat
        (setq-local dsh-emacs--buffer-session "sess-q")
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (method params _cb)
                     (push (cdr (assq 'itemId
                                      (cdr (assq 'request params))))
                           calls)))
                  ((symbol-function 'y-or-n-p)
                   (lambda (_prompt) t))
                  ((symbol-function 'run-at-time)
                   (lambda (_delay _repeat fn) (push fn deferred)))
                  ((symbol-function 'minibuffer-selected-window)
                   (lambda () (selected-window))))
          (let ((dsh-emacs--queue-pick-table table))
            (catch 'exit
              (dsh-emacs-queue--menu-delete-all)))
          (dsh-test-assert "queue-delete-all-schedules-before-exit"
            (null calls))
          (dolist (fn (nreverse deferred)) (funcall fn))
          (dsh-test-assert "queue-delete-all-confirms-and-deletes-both"
            (equal '("x1" "x2")
                   (sort (copy-sequence calls) #'string<)))))
    (when (buffer-live-p chat) (kill-buffer chat))))

;; Queue menu key installation: question-isomorphic use-local-map (copy the
;; current local map + the single key)
(let ((buf (get-buffer-create " *t-queue-keymap*")))
  (unwind-protect
      (with-current-buffer buf
        (use-local-map minibuffer-local-completion-map)
        (dsh-emacs-queue--chooser-setup-hook)
        (dsh-test-assert "queue-menu-keys-bound-via-local-map"
          (eq (key-binding (kbd "e")) #'dsh-emacs-queue--menu-edit)
          (eq (key-binding (kbd "s")) #'dsh-emacs-queue--menu-steer)
          (eq (key-binding (kbd "d")) #'dsh-emacs-queue--menu-delete)
          (eq (key-binding (kbd "x")) #'dsh-emacs-queue--menu-delete-all)
          (eq (key-binding (kbd "RET")) #'dsh-emacs-queue--menu-send)))
    (when (buffer-live-p buf) (kill-buffer buf))))

;; ---------------------------------------------------------------------------
;; @ reference (dsh-emacs-reference.el)
;; ---------------------------------------------------------------------------

(defun dsh-test-reference-reset ()
  "Reset the buffer-local @ reference cache state (current buffer)."
  (setq-local dsh-emacs--reference-candidates nil
              dsh-emacs--reference-query nil
              dsh-emacs--reference-requested nil
              dsh-emacs--reference-inflight nil
              dsh-emacs--reference-fetch-gen 0
              dsh-emacs--reference-files nil
              dsh-emacs--reference-sessions nil
              dsh-emacs--reference-pop-token nil))

;; A short @ token must not copy the entire preceding draft on each keypress.
(with-temp-buffer
  (dsh-emacs-mode)
  (insert (make-string 100000 ?x) " @src/file")
  (let ((copied 0)
        (substring (symbol-function 'buffer-substring-no-properties)))
    (cl-letf (((symbol-function 'buffer-substring-no-properties)
               (lambda (start end)
                 (setq copied (+ copied (- end start)))
                 (funcall substring start end))))
      (dsh-test-assert "active-token-copies-only-the-token"
        (equal (dsh-emacs-reference--active-token)
               '("@src/file" "src/file" nil))
        (<= copied 20)))))

;; --- syntax: at-token aligned with web grammar.ts activeAtToken ---
(dolist (case '(("bare-at" "@" ("@" "" nil))
                ("after-whitespace" "hi @fo" ("@fo" "fo" nil))
                ("quoted-path" "@\"my dir/te" ("@\"my dir/te" "my dir/te" t))
                ("dir-trailing-slash" "a @src/" ("@src/" "src/" nil))
                ("email-not-a-trigger" "mail@example" nil)
                ("mid-word-not-a-trigger" "foo/bar" nil)
                ("trailing-space-closes-token" "@done " nil)
                ("quoted-at-is-path-text" "@\"a @b" ("@\"a @b" "a @b" t))
                ("quote-in-other-token" "x@\"a @b" ("@b" "b" nil))
                ("multiline-quoted-path" "@\"a\nb" ("@\"a\nb" "a\nb" t))
                ("last-quote-opens-token" "@\"a @\"b" ("@\"b" "b" t))
                ("closed-quote-falls-back" "@\"done\"" ("@\"done\"" "\"done\"" nil))
                ("empty-input" "" nil)))
  (pcase-let ((`(,name ,text ,expected) case))
    (with-temp-buffer
      (insert "@\"outside-input ")
      (let ((start (point)))
        (insert text)
        (let ((end (point)))
          (insert " after-cursor")
          (goto-char start)
          (dsh-test-assert (concat "at-token-" name)
            (equal (dsh-emacs-reference--at-token start end) expected)
            (= (point) start)))))))

;; --- syntax: formatFileMention aligned with web formatFileMention ---
(let ((cases
       '(("README.md" "file" nil "@README.md")
         ("src" "directory" nil "@src/")
         ("my dir/a b" "file" nil "@\"my dir/a b\"")
         ("src" "directory" t "@\"src/")
         ("a b" "file" t "@\"a b\""))))
  (dsh-test-assert "format-file-mention-cases"
    (cl-every
     (lambda (c)
       (string= (apply #'dsh-emacs-reference--format-file-mention
                       (butlast c))
                (car (last c))))
     cases)))

(dsh-test-assert "format-file-mention-rejects-control"
  (null (dsh-emacs-reference--format-file-mention "a\x01b" "file")))
(dsh-test-assert "format-file-mention-rejects-quote"
  (null (dsh-emacs-reference--format-file-mention "a\"b" "file")))

;; --- collect-files: wire array → cache entries, unrepresentable paths skipped;
;; the host sorts directories before files (kindRank directory=0), the client
;; stably groups files first, directories after
(let ((entries
       (dsh-emacs-reference--collect-files
        [((path . "src") (kind . "directory"))
         ((path . "README.md") (kind . "file"))
         ((path . "docs") (kind . "directory"))
         ((path . "bad\x01name") (kind . "file"))])))
  (dsh-test-assert "collect-files-texts-and-kinds"
    (equal (mapcar #'car entries)
           '("@README.md" "@src/" "@docs/"))
    (equal (plist-get (cdr (assoc "@src/" entries)) :kind) 'directory)
    (equal (plist-get (cdr (assoc "@README.md" entries)) :path)
           "README.md")
    ;; Within a group the host order is kept: two directories in wire order src → docs
    (equal (mapcar (lambda (e) (plist-get (cdr e) :path))
                   (cl-remove-if-not
                    (lambda (e) (eq (plist-get (cdr e) :kind) 'directory))
                    entries))
           '("src" "docs"))))

;; --- collect-sessions: mention is the main text, candidates without a mention
;; are skipped ---
(let ((entries
       (dsh-emacs-reference--collect-sessions
        [((sessionId . "s1")
          (label . "My Talk")
          (cwd . "/work/a")
          (sameWorkspace . t)
          (createdAt . 123)
          (mention . "@[My Talk](dsh-session:cyJpZCI6InMxIn0)"))
         ((sessionId . "s2") (label . "x"))])))
  (dsh-test-assert "collect-sessions-mention-and-drop"
    (equal (mapcar #'car entries)
           '("@[My Talk](dsh-session:cyJpZCI6InMxIn0)"))
    (equal (plist-get (cdr (car entries)) :label) "My Talk")
    (equal (plist-get (cdr (car entries)) :session-id) "s1")
    (equal (plist-get (cdr (car entries)) :same-workspace) t)))

;; --- combine: by default keep all files and sessions returned by the host ---
(let* ((dsh-emacs-reference-max-files nil)
       (dsh-emacs-reference-max-sessions nil)
       (files (list (cons "@a" '(:kind file))
                    (cons "@b" '(:kind directory))
                    (cons "@c" '(:kind file))))
       (sessions (list (cons "@s1" '(:kind session))
                       (cons "@s2" '(:kind session)))))
  (dsh-test-assert "combine-default-keeps-all-candidates"
    (= 5 (length (dsh-emacs-reference--combine files sessions)))))

;; --- combine: files first, sessions after, each truncated to its cap ---
(let* ((dsh-emacs-reference-max-files 2)
       (dsh-emacs-reference-max-sessions 1)
       (files (list (cons "@a" '(:kind file :path "a"))
                    (cons "@b" '(:kind file :path "b"))
                    (cons "@c" '(:kind file :path "c"))))
       (sessions (list (cons "@[s1](dsh-session:x)" '(:kind session))
                       (cons "@[s2](dsh-session:y)" '(:kind session))))
       (combined (dsh-emacs-reference--combine files sessions)))
  (dsh-test-assert "combine-order-and-caps"
    (equal (mapcar #'car combined)
           '("@a" "@b" "@[s1](dsh-session:x)"))))

;; --- M-x menu: use the ordered completion helper so the framework does not
;; reorder by text ---
(let (collection)
  (with-temp-buffer
    (dsh-test-reference-reset)
    (setq dsh-emacs--reference-query ""
          dsh-emacs--reference-candidates
          (list (cons "@file.txt" '(:kind file :path "file.txt"))
                (cons "@dir/" '(:kind directory :path "dir"))
                (cons "@[Session](dsh-session:s)" '(:kind session
                                                       :label "Session"))))
    (cl-letf (((symbol-function 'dsh-emacs-server-ensure) (lambda () nil))
              ((symbol-function 'dsh-emacs--active-session-id)
               (lambda () "sess"))
              ((symbol-function 'dsh-emacs--completing-read-ordered)
               (lambda (_prompt coll &rest _args)
                 (setq collection coll)
                 nil)))
      (dsh-emacs-reference))
    (dsh-test-assert "reference-menu-preserves-file-dir-session-order"
      (equal (dsh-test-completion-items collection)
             '("file.txt" "dir/" "Session")))))

;; --- Corfu active popup: async refresh must not restart native completion ---
(let ((buf (generate-new-buffer " *t-ref-corfu-refresh*"))
      (completed nil)
      (native-refreshed nil))
  (unwind-protect
      (with-current-buffer buf
        (insert "@")
        (setq-local dsh-emacs--input-marker (copy-marker (point-min))
                    dsh-emacs--reference-requested ""
                    dsh-emacs--reference-query "")
        (cl-letf (((symbol-function 'get-buffer-window)
                   (lambda (&rest _args) t))
                  ((symbol-function 'run-with-idle-timer)
                   (lambda (_delay _repeat function &rest _args)
                     (funcall function)))
                  ((symbol-function 'completion-at-point)
                   (lambda () (setq completed t)))
                  ((symbol-function 'corfu-auto--complete-deferred)
                   (lambda (&optional _tick) (setq native-refreshed t))))
          (let ((corfu-auto t)
                (completion-in-region-mode t))
            (dsh-emacs-reference--schedule-popup-refresh))
          (dsh-test-assert "reference-refresh-leaves-active-corfu-alone"
            (null completed)
            (null native-refreshed))
          (let ((corfu-auto t)
                (completion-in-region-mode nil))
            (dsh-emacs-reference--schedule-popup-refresh))
          (dsh-test-assert "reference-refresh-does-not-reopen-nondirectory-corfu"
            (null native-refreshed)
            (null completed))
          (let ((corfu-auto nil)
                (completion-in-region-mode nil))
            (dsh-emacs-reference--schedule-popup-refresh))
          ;; Non-corfu has no auto channel (cooperative, like slash): an async
          ;; refresh never opens the completion UI itself — that stays on TAB.
          (dsh-test-assert "reference-refresh-never-opens-noncorfu"
            (null completed))))
    (when (buffer-live-p buf) (kill-buffer buf))))

;; --- Corfu native table: edit/backspace only filters current candidates, does
;; not start a remote refresh ---
(let ((buf (generate-new-buffer " *t-ref-corfu-native-table*"))
      (fetched nil)
      (opened nil)
      (prefetched nil)
      (delay-seen nil))
  (unwind-protect
      (with-current-buffer buf
        (insert "@")
        (setq-local dsh-emacs--input-marker (copy-marker (point-min))
                    dsh-emacs--reference-query "old"
                    dsh-emacs--reference-requested nil
                    dsh-emacs--reference-pop-token nil)
        (cl-letf (((symbol-function 'dsh-emacs--active-session-id)
                   (lambda () "sess"))
                  ((symbol-function 'dsh-emacs-reference--require-cache)
                   (lambda (_session _query) t))
                  ((symbol-function 'dsh-emacs-reference--fetch-query)
                   (lambda (session-id query)
                     (setq fetched (list session-id query))))
                  ((symbol-function 'dsh-emacs-reference--schedule-popup-refresh)
                   (lambda () (setq prefetched t)))
                  ((symbol-function 'completion-at-point)
                   (lambda () (setq opened t)))
                  ((symbol-function 'run-with-idle-timer)
                   (lambda (delay _repeat function &rest _args)
                     (setq delay-seen delay)
                     (funcall function)))
                  ((symbol-function 'get-buffer-window)
                   (lambda (&rest _args) t)))
          (let ((corfu-auto t)
                (dsh-emacs-reference-fetch-delay 0.15))
            (dsh-emacs-reference--auto-complete)
            (dsh-emacs-reference-prefetch "sess"))
          (dsh-test-assert "reference-corfu-refreshes-query-without-restarting"
            (equal fetched '("sess" ""))
            (null opened)
            (null prefetched))
          ;; A trailing slash is the one Corfu edit that drills remotely.
          (goto-char (point-max))
          (insert "src/")
          (dsh-emacs-reference--auto-complete)
          (dsh-test-assert "reference-corfu-slash-fetches-directory"
            (equal fetched '("sess" "src/"))
            (= delay-seen 0))))
    (when (buffer-live-p buf) (kill-buffer buf))))

;; --- fetch-query: two remotes concurrently, install the cache after both
;; slices land ---
(let ((rpc-calls nil))
  (with-temp-buffer
    (dsh-test-reference-reset)
    (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
               (lambda (method params cb)
                 (push (list method params) rpc-calls)
                 (cond
                  ((string= method "fileReferences/list")
                   (funcall cb t [((path . "README.md") (kind . "file"))]))
                  ((string= method "sessionReferenceResolver/candidates")
                   (funcall cb t [((sessionId . "s1") (label . "T")
                                   (mention
                                    . "@[T](dsh-session:cyJpZCI6InMxIn0)"))]))
                  (t (funcall cb nil nil))))))
      (setq dsh-emacs--reference-requested "re")
      (dsh-emacs-reference--fetch-query "sess" "re"))
    (dsh-test-assert "fetch-query-both-remotes-called"
      (= 2 (length rpc-calls))
      (cl-every (lambda (m) (member m '("fileReferences/list"
                                        "sessionReferenceResolver/candidates")))
                (mapcar #'car rpc-calls)))
    (dsh-test-assert "fetch-query-wire-args-flat"
      ;; The params of `dsh-emacs--rpc-async' are exactly the contents of payload.args:
      ;; fields are flattened (agentId/query present directly), with no extra args
      ;; wrapper (rpc.md §1.2 / §4.3 / §4.13; the server replies
      ;; gateway/arguments-invalid for extra fields)
      (let ((params (cadr (assoc "fileReferences/list" rpc-calls))))
        (and (null (assq 'args params))
             (string= (cdr (assq 'agentId params)) "sess")
             (string= (cdr (assq 'query params)) "re"))))
    (dsh-test-assert "fetch-query-installs-cache"
      (equal dsh-emacs--reference-query "re")
      (null dsh-emacs--reference-inflight)
      (equal (mapcar #'car dsh-emacs--reference-candidates)
             '("@README.md" "@[T](dsh-session:cyJpZCI6InMxIn0)")))))

;; --- require-cache: first sync fetch; a stale cache keeps answering and does not
;; fetch again ---
(let ((rpc-requests nil))
  (with-temp-buffer
    (dsh-test-reference-reset)
    (cl-letf (((symbol-function 'dsh-emacs--rpc-request)
               (lambda (method params)
                 (push (list method params) rpc-requests)
                 (cond
                  ((string= method "fileReferences/list")
                   (cons t [((path . "F") (kind . "file"))]))
                  ((string= method "sessionReferenceResolver/candidates")
                   (cons t []))
                  (t (cons nil nil))))))
      (let ((ok (dsh-emacs-reference--require-cache "sess" "")))
        (dsh-test-assert "require-cache-first-trigger-sync"
          ok
          (= 2 (length rpc-requests))
          (equal dsh-emacs--reference-query "")
          (equal (mapcar #'car dsh-emacs--reference-candidates) '("@F"))
          ;; The sync path likewise flattens args (no extra args wrapper)
          (equal (cadr (assoc "fileReferences/list" rpc-requests))
                 '((agentId . "sess") (query . "")))))
      (setq dsh-emacs--reference-requested "F2")
      (let ((stale-len (length rpc-requests)))
        (dsh-test-assert "require-cache-stale-answers-without-fetch"
          (dsh-emacs-reference--require-cache "sess" "F2")
          (= (length rpc-requests) stale-len))))))

;; --- after finishing a reference (fetch state already reset), typing @ again: no
;; longer eats the narrowed cache, re-fetches the full set. Otherwise the next @
;; would only see the single candidate left by the previous query.
(let ((rpc-requests nil))
  (with-temp-buffer
    (dsh-test-reference-reset)
    ;; Simulate "just finished a reference": query/requested have been cleared by the
    ;; reset, but the cache still holds the result of the previous narrowed query
    ;; (just one freshly selected candidate).
    (setq-local dsh-emacs--reference-query nil
                dsh-emacs--reference-requested nil
                dsh-emacs--reference-candidates
                (list (cons "@just-picked.ts"
                            '(:kind file :path "just-picked.ts"))))
    (cl-letf (((symbol-function 'dsh-emacs--rpc-request)
               (lambda (method _params)
                 (push method rpc-requests)
                 (cond
                  ((string= method "fileReferences/list")
                   (cons t [((path . "a.ts") (kind . "file"))
                            ((path . "b.ts") (kind . "file"))]))
                  ((string= method "sessionReferenceResolver/candidates")
                   (cons t []))
                  (t (cons nil nil))))))
      (dsh-test-assert "post-completion-reopen-refetches-full-list"
        (dsh-emacs-reference--require-cache "sess" "")
        (equal (mapcar #'car dsh-emacs--reference-candidates)
               '("@a.ts" "@b.ts"))))))

;; --- require-cache: a stale cache keeps answering while in-flight (the popup does
;; not disappear) ---
(let ((rpc-requests nil))
  (with-temp-buffer
    (dsh-test-reference-reset)
    (setq dsh-emacs--reference-query "re"
          dsh-emacs--reference-candidates
          (list (cons "@README.md" '(:kind file :path "README.md"))))
    (cl-letf (((symbol-function 'dsh-emacs--rpc-request)
               (lambda (method _params)
                 (push method rpc-requests)
                 (cons nil nil))))
      (dsh-test-assert "require-cache-stale-answers-while-inflight"
        (let ((dsh-emacs--reference-inflight t))
          (and (dsh-emacs-reference--require-cache "sess" "re2")
               ;; Stale cache retained, no new fetch started
               (null rpc-requests))))
      (dsh-test-assert "require-cache-no-cache-while-inflight-nil"
        (let ((dsh-emacs--reference-inflight t)
              (dsh-emacs--reference-query nil)
              (dsh-emacs--reference-candidates nil))
          (null (dsh-emacs-reference--require-cache "sess" "re2")))))))

;; --- session-rows: session row short label + duplicate-name disambiguation
;; (mention stays in the cache) ---
(let ((dsh-emacs--reference-candidates
       (list (cons "@README.md" '(:kind file :path "README.md"))
             (cons "@[My Talk](dsh-session:cyJpZCI6InMxIn0)"
                   '(:kind session :label "My Talk" :session-id "s1"))
             (cons "@[My Talk](dsh-session:cyJpZCI6InMyIn0)"
                   '(:kind session :label "My Talk" :session-id "s2")))))
  (dsh-test-assert "session-rows-short-and-unique"
    (equal (dsh-emacs-reference--session-rows)
           '(("@My Talk" . "@[My Talk](dsh-session:cyJpZCI6InMxIn0)")
             ("@My Talk #2" . "@[My Talk](dsh-session:cyJpZCI6InMyIn0)")))))
;; --- affixate: file/directory rows get a leading type-icon column (consult-buffer
;; style) ---
(let ((dsh-emacs--reference-candidates
       (list (cons "@a.ts" '(:kind file :path "src/a.ts"))
             (cons "@sub/" '(:kind directory :path "sub"))
             (cons "@[T](dsh-session:x)"
                   '(:kind session :label "T" :cwd "/w"
                           :same-workspace t)))))
  (cl-letf (((symbol-function 'dsh-emacs-reference--row-icon)
             (lambda (path kind)
               (pcase kind
                 ('file "F")
                 ('directory "D")
                 ('session "R")
                 (_ nil)))))
    (dsh-test-assert "affixate-icon-column-shape"
      (equal (dsh-emacs-reference--affixate
              '("@a.ts" "@sub/" "@[T](dsh-session:x)"))
             '(("@a.ts" "F " "")
               ("@sub/" "D " "")
               ("@[T](dsh-session:x)" "R " "")))))
  (dsh-test-assert "affixate-without-provider-text-only"
    (cl-letf (((symbol-function 'dsh-emacs-reference--row-icon)
               (lambda (_path _kind) nil)))
      (equal (dsh-emacs-reference--affixate '("@a.ts" "@sub/"))
             '(("@a.ts" "" "")
               ("@sub/" "" "")))))
  (dsh-test-assert "affixate-inline-icons-off"
    (let ((dsh-emacs-reference-inline-icons nil))
      (equal (dsh-emacs-reference--affixate '("@a.ts"))
             '(("@a.ts" "" "")))))
  ;; --row-icon: a non-graphical frame outputs no nerd-font PUA glyphs (terminal
  ;; tofu blocks); a graphical frame with the provider available returns the
  ;; file/directory/session icon by kind
  (dsh-test-assert "row-icon-gated-off-on-non-graphic"
    (cl-letf (((symbol-function 'display-graphic-p) (lambda () nil))
              ((symbol-function 'featurep)
               (lambda (f &optional _sub) (eq f 'nerd-icons)))
              ((symbol-function 'fboundp)
               (lambda (s)
                 (memq s '(nerd-icons-icon-for-file nerd-icons-icon-for-dir)))))
      (and (null (dsh-emacs-reference--row-icon "src/a.ts" 'file))
           (null (dsh-emacs-reference--row-icon nil 'session)))))
  (dsh-test-assert "row-icon-graphic-uses-provider"
    (cl-letf (((symbol-function 'display-graphic-p) (lambda () t))
              ((symbol-function 'featurep)
               (lambda (f &optional _sub) (eq f 'nerd-icons)))
              ((symbol-function 'fboundp)
               (lambda (s)
                 (memq s '(nerd-icons-icon-for-file nerd-icons-icon-for-dir))))
              ((symbol-function 'nerd-icons-icon-for-file) (lambda (_f) "F"))
              ((symbol-function 'nerd-icons-icon-for-dir) (lambda (_d) "D"))
              ((symbol-function 'nerd-icons-codicon) (lambda (_n) "R")))
      (and (string= (dsh-emacs-reference--row-icon "src/a.ts" 'file) "F")
           (string= (dsh-emacs-reference--row-icon "src" 'directory) "D")
           ;; Session rows use codicon references glyphs (path ignored)
           (string= (dsh-emacs-reference--row-icon nil 'session) "R")))))

;; --- icon data is snapshotted when the completion table is built: a background
;; fetch then replaces `dsh-emacs--reference-candidates' with the results of a
;; new query, and the still-open corfu popup (holding the old snapshot table)
;; re-affixes with the snapshot map instead of the mutable cache → icons are not
;; pulled away (regression: after a new fetch some rows had no icon when
;; filtering)
(let* ((dsh-emacs--reference-candidates
        (list (cons "@a.ts" '(:kind file :path "src/a.ts"))
              (cons "@sub/" '(:kind directory :path "sub"))))
       (rows (dsh-emacs-reference--session-rows))
       (map (dsh-emacs-reference--snapshot-affix '("@a.ts" "@sub/") rows)))
  ;; A narrower fetch lands, replacing the global cache
  (setq dsh-emacs--reference-candidates
        (list (cons "@fresh.md" '(:kind file :path "fresh.md"))))
  (dsh-test-assert "affix-snapshot-survives-cache-swap"
    (cl-letf (((symbol-function 'dsh-emacs-reference--row-icon)
               (lambda (_path kind) (symbol-name kind))))
      (equal (dsh-emacs-reference--affixate-with map '("@a.ts" "@sub/"))
             '(("@a.ts" "file " "")
               ("@sub/" "directory " ""))))))

;; --- rendering: a completed @ reference → colored clickable link (session
;; collapsed to @label) ---
(let ((spans (dsh-emacs-reference--link-spans
              "see @src/a.ts and @[My Talk](dsh-session:ab1_-2) done")))
  (dsh-test-assert "link-spans-file-and-session"
    (equal (mapcar (lambda (s) (list (nth 2 s) (nth 3 s)))
                   spans)
           '((file "src/a.ts") (session "ab1_-2"))))
  (dsh-test-assert "link-spans-not-email"
    (null (dsh-emacs-reference--link-spans "contact mail@example.com now")))
  ;; A bare @word (including extensionless files such as @LICENSE) is always a file
  ;; reference link; only emails and a lone @ are excluded
  (dsh-test-assert "link-spans-bare-atword-is-file"
    (equal (mapcar (lambda (s) (nth 3 s))
                   (dsh-emacs-reference--link-spans
                    "note @LICENSE and @src/a.ts and @README.md"))
           '("LICENSE" "src/a.ts" "README.md")))
  (dsh-test-assert "link-spans-lone-at-not-file"
    (null (dsh-emacs-reference--link-spans "an @ alone and @ here"))))

(let ((out (dsh-emacs-reference-fontify
            "see @src/ui/button.tsx then @[My Talk](dsh-session:ab1_-2), mail@example ok")))
  (dsh-test-assert "fontify-session-collapses-to-label"
    (string= (substring-no-properties out)
             "see @src/ui/button.tsx then @My Talk, mail@example ok"))
  (dsh-test-assert "fontify-spans-carry-session-id"
    (equal (get-text-property (string-match "@My Talk" out)
                              'dsh-emacs-reference-ref out)
           '(session . "ab1_-2"))))

(let ((out (dsh-emacs-reference-fontify "note @\"my dir/a.ts\" here")))
  (dsh-test-assert "fontify-quoted-file-path-linked"
    (let ((i (string-match "@\"my dir/a.ts\"" out)))
      (equal (get-text-property i 'dsh-emacs-reference-ref out)
             '(file . "my dir/a.ts")))))

;; The `@[label' prefix of a session mention is not treated as a file link
(let ((out (dsh-emacs-reference-fontify
            "@[T](dsh-session:xyz) @[Q](dsh-session:uvw)")))
  (dsh-test-assert "fontify-two-sessions-and-no-file-prefix"
    (string= (substring-no-properties out) "@T @Q")))

;; RET/mouse open: a session reference jumps via `dsh-emacs-open-session'
(let ((opened nil) (buf (generate-new-buffer " *t-ref-open*")))
  (unwind-protect
      (with-current-buffer buf
        (insert (dsh-emacs-reference-fontify
                 "@[Sess](dsh-session:target1)"))
        (goto-char (point-min))
        (cl-letf (((symbol-function 'dsh-emacs-open-session)
                   (lambda (id) (setq opened id))))
          (dsh-emacs-reference-open-at-point))
        (dsh-test-assert "open-at-point-jumps-to-session"
          (equal opened "target1")))
    (when (buffer-live-p buf) (kill-buffer buf))))

;; --- reseed/reopen: when the server persists a reference message it collapses the
;; canonical mention into a readable @label (the id is stripped), and the real
;; sessionId+label appears only in the immediately following session-reference
;; recall event — rendering with REFERENCES ((LABEL . SESSION-ID)) is what
;; restores the readable @label into a session chip with the real id, while plain
;; @file still links as usual.
(let ((out (dsh-emacs-reference-fontify
            "see @dsh-emacs如何通过转发接入Codex与Claude 和 @src/a.ts"
            '(("dsh-emacs如何通过转发接入Codex与Claude" . "session-abc-123")))))
  (let ((label-pos (string-match "@dsh-emacs如何通过转发接入Codex与Claude" out))
        (file-pos (string-match "@src/a.ts" out)))
    (dsh-test-assert "reseed-readable-label-links-as-session-with-real-id"
      (and label-pos file-pos
           (equal (get-text-property label-pos 'dsh-emacs-reference-ref out)
                  '(session . "session-abc-123"))
           (equal (get-text-property file-pos 'dsh-emacs-reference-ref out)
                  '(file . "src/a.ts")))))
  (dsh-test-assert "reseed-readable-label-text-preserved"
    (string= (substring-no-properties out)
             "see @dsh-emacs如何通过转发接入Codex与Claude 和 @src/a.ts")))
;; After the readable @label is restored to a chip it can still jump to the real
;; session
(let ((opened nil) (buf (generate-new-buffer " *t-reseed-open*")))
  (unwind-protect
      (with-current-buffer buf
        (insert (dsh-emacs-reference-fontify
                 "关于 @dsh-emacs如何通过转发接入Codex与Claude 的事"
                 '(("dsh-emacs如何通过转发接入Codex与Claude" . "session-abc-123"))))
        (goto-char (1+ (string-match "@dsh-emacs" (buffer-string))))
        (cl-letf (((symbol-function 'dsh-emacs-open-session)
                   (lambda (id) (setq opened id))))
          (dsh-emacs-reference-open-at-point))
        (dsh-test-assert "reseed-label-open-jumps-to-real-session"
          (equal opened "session-abc-123")))
    (when (buffer-live-p buf) (kill-buffer buf))))
;; A readable @word that matches no reference still goes through the file link
;; (not polluted)
(let ((out (dsh-emacs-reference-fontify
            "mention @unrelated now"
            '(("known-label" . "session-k")))))
  (dsh-test-assert "reseed-nonmatching-label-stays-file"
    (equal (get-text-property (string-match "@unrelated" out)
                              'dsh-emacs-reference-ref out)
           '(file . "unrelated"))))

;; --- reseed/reopen: reference message + the immediately following
;; session-reference recall event ---
;; The server stores the reference message as a readable @label (id stripped),
;; and the real sessionId+label appears only in the immediately following
;; session-reference recall event. When history reseed renders these two
;; user/message entries in one batch, render-history-events should associate the
;; recall's references back to the preceding message's seq and render @label as a
;; jumpable session chip.

(let ((buf (generate-new-buffer " *dsh-reseed-session-ref*"))
      (opened nil))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (dsh-emacs-modeline-setup)
        (setq dsh-emacs--buffer-session "sess-reseed")
        (let* ((label "实现dsh web的@指令")
               (sid "session-ae44fea5-bf67-4ba9-b3da-599903832933")
               (ref-msg
                (json-read-from-string
                 (concat "{\"type\":\"user/message\",\"seq\":40,"
                         "\"data\":{\"source\":{\"kind\":\"user\"},"
                         "\"content\":[{\"type\":\"text\","
                         "\"text\":\"from @实现dsh web的@指令 please look\"}]}}")))
               (recall
                (json-read-from-string
                 (concat "{\"type\":\"user/message\",\"seq\":41,"
                         "\"data\":{\"source\":{\"kind\":\"session-reference\","
                         "\"form\":\"recall\","
                         "\"references\":[{\"sessionId\":\"session-ae44fea5-bf67-4ba9-b3da-599903832933\","
                         "\"label\":\"实现dsh web的@指令\"}]},"
                         "\"content\":[{\"type\":\"text\",\"text\":\"# refs\"}]}}")))
               (label-token (concat "@" label)))
          (dsh-emacs-render-history-events
           (list (list (cons "event" ref-msg))
                 (list (cons "event" recall)))
           nil)
          (let* ((text (buffer-substring-no-properties (point-min) (point-max)))
                 (pos (string-match label-token text))
                 (prop (buffer-substring (point-min) (point-max)))
                 (ref (and pos (get-text-property pos 'dsh-emacs-reference-ref prop))))
            (dsh-test-assert "reseed-render-links-readable-label-to-session"
              (and pos (equal ref (cons 'session sid)))))))
    (kill-buffer buf)))

;; --- composer atomic chip: the buffer stores a short @label + canonical text
;; properties, and sending expands it back to the full mention
(let ((canon "@[My Talk](dsh-session:ab12_CD)"))
  (with-temp-buffer
    (setq-local dsh-emacs--input-marker (point-min-marker))
    (insert "@My Talk")
    (dsh-test-assert "chip-keeps-short-label-and-canonical"
      (and (dsh-emacs-reference--session-chip (point-min) (point) canon)
           (string= (buffer-substring-no-properties (point-min) (point))
                    "@My Talk")
           (string= (get-text-property (point-min)
                                       'dsh-emacs-reference-canonical)
                    canon)
           (equal (get-text-property (point-min) 'dsh-emacs-reference-ref)
                  '(session . "ab12_CD"))
           (get-text-property (point-min) 'dsh-emacs-reference-chip)))
    ;; no `display' folding: visible text is exactly the short label in the buffer
    (dsh-test-assert "chip-has-no-display-folding"
      (null (get-text-property (point-min) 'display)))
    ;; expansion back to the full mention, via both the raw span reader and
    ;; `dsh-emacs--get-input' (the send / history path)
    (dsh-test-assert "chip-expands-to-full-mention"
      (string= (dsh-emacs-reference--expanded-text (point-min) (point-max))
               canon)
      (string= (dsh-emacs--get-input) canon))
    ;; self-insert while point sits on the chip hops to its end first
    (goto-char (+ (point-min) 5))
    (let ((this-command 'self-insert-command))
      (dsh-emacs-reference--chip-guard-before))
    (dsh-test-assert "chip-guard-hops-out-of-interior"
      (= (point) (point-max)))
    ;; backspace at the trailing edge deletes the whole chip (atomic unit)
    (goto-char (point-max))
    (delete-backward-char 1)
    (dsh-test-assert "chip-backspace-deletes-whole-span"
      (string= (buffer-substring-no-properties (point-min) (point-max)) ""))
    ;; typing after the chip must not inherit its link/face style
    (insert "@My Talk")
    (dsh-emacs-reference--session-chip (point-min) (point) canon)
    (insert " tail")
    (dsh-test-assert "chip-typed-after-stays-plain"
      (let ((p (- (point) 5)))
        (and (null (get-text-property p 'face))
             (null (get-text-property p 'dsh-emacs-reference-chip)))))))

;; --- C-k on a chip deletes the whole chip atomically (not just its tail) ---
;; Regression: the chip guard used to hop every edit that started on a chip
;; character to the chip's end, so C-k starting on the chip's leading edge or
;; interior only killed what followed it and the chip itself could never be
;; deleted.  Now kill-line on a chip pulls the cursor back to the chip's start
;; so C-k removes the whole chip as one atomic unit.
(let ((canon "@[My Talk](dsh-session:ab12_CD)"))
  (with-temp-buffer
    (setq-local dsh-emacs--input-marker (point-min-marker))
    (insert "@My Talk tail")
    (dsh-emacs-reference--session-chip (point-min) (+ (point-min) 8) canon)
    ;; cursor on the chip's leading edge -> C-k deletes the whole chip + tail
    (goto-char (point-min))
    (let ((this-command 'kill-line))
      (dsh-emacs-reference--chip-guard-before))
    (kill-line)
    (dsh-test-assert "kill-line-on-chip-removes-whole-chip"
      (string-empty-p
       (buffer-substring-no-properties (point-min) (point-max))))
    ;; cursor on plain text AFTER the chip -> only the tail is killed, chip kept
    (insert "@My Talk tail")
    (dsh-emacs-reference--session-chip (point-min) (+ (point-min) 8) canon)
    (goto-char (+ (point-min) 9))
    (let ((this-command 'kill-line))
      (dsh-emacs-reference--chip-guard-before))
    (kill-line)
    (dsh-test-assert "kill-line-after-chip-keeps-chip"
      (string= (buffer-substring-no-properties (point-min) (point-max))
               "@My Talk "))))

;; --- C-k (kill-line) in the input keeps standard semantics: only deletes
;; after point, never the structural newline ---
;; Regression: C-k was once made to clear the whole input regardless of point,
;; which is not Emacs semantics.  Now C-k only deletes from point to the end of
;; the input; with the cursor at the end there is nothing to delete (and the
;; structural newline / cursor stranding are not touched) — the separator is
;; held by the composer `kill-region' boundary guard (kill-line routes through
;; kill-region; see `dsh-emacs--composer-delete-guard-install').
(dsh-emacs--composer-delete-guard-install)
(let ((canon "@[My Talk](dsh-session:ab12_CD)"))
  (with-temp-buffer
    (setq-local dsh-emacs--input-marker (point-min-marker))
    (setq-local dsh-emacs--modeline-overlay nil)
    ;; Cursor at the input end: nothing to delete, so input and chip stay and
    ;; the separator newline survives
    (insert "@My Talk")
    (dsh-emacs-reference--session-chip (point-min) (point) canon)
    (insert "\n")                   ; structural separator newline (mode-line)
    (goto-char (1- (point-max)))
    (kill-line)
    (dsh-test-assert "kill-line-at-input-end-deletes-nothing"
      (and (string= (buffer-substring-no-properties (point-min) (point-max))
                    "@My Talk\n")
           (get-text-property (point-min) 'dsh-emacs-reference-chip)))
    ;; Cursor mid-input: C-k deletes only after point ("ay @My Talk"), keeping
    ;; the "s" before the cursor
    (erase-buffer)
    (insert "say ")
    (let ((chip-start (point)))
      (insert "@My Talk")
      (dsh-emacs-reference--session-chip chip-start (point) canon))
    (insert "\n")
    (goto-char (1+ (point-min)))    ; cursor inside "say " (after 's')
    (kill-line)
    (dsh-test-assert "kill-line-at-input-middle-keeps-point-prefix"
      (and (string= (buffer-substring-no-properties (point-min) (point-max))
                    "s\n")
           (eq (char-before (point-max)) ?\n)))))

;; --- M-d (kill-word) / C-d at the input end must not eat the structural
;; separator newline ---
;; Root cause: the structural newline at the input's end is deletable text; a
;; forward `kill-word' / `C-d' at the end removed it, input-end fell back to
;; point-max, the phantom line became the "editable end", the below-clamp
;; stopped working and the cursor was stranded below the input line.
;; `dsh-emacs--composer-delete-guard-install' clips forward deletes at the
;; input boundary (kill-region clip / delete-forward-char cap), so no delete
;; command crosses the newline.
;; Invariant: a forward word/char delete at the input end never removes the
;; separator newline and the cursor locks back onto the input line.
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (goto-char dsh-emacs--input-marker)
  (insert "hello world")
  (let ((assert-end (lambda (label)
                      (let ((sep (eq (char-before (point-max)) ?\n)))
                        (dsh-emacs--lock-cursor-to-input)
                        (dsh-test-assert label
                          (and sep
                               (= (point) (dsh-emacs--input-end))))))))
    (goto-char (dsh-emacs--input-end))
    (condition-case nil (kill-word 1) (error nil))
    (funcall assert-end "word-kill-at-input-end-keeps-separator")
    (goto-char (dsh-emacs--input-end))
    (condition-case nil (delete-forward-char 1) (error nil))
    (funcall assert-end "delete-forward-at-input-end-keeps-separator")
    ;; normal editing still works: forward kill-word from the start of the last
    ;; word must delete only that word and leave the separator newline intact.
    (goto-char (- (dsh-emacs--input-end) (length "world")))
    (kill-word 1)
    (dsh-test-assert "word-kill-mid-last-word-keeps-separator"
      (and (string= (buffer-substring-no-properties
                     (marker-position dsh-emacs--input-marker) (point-max))
                    "hello \n")
           (eq (char-before (point-max)) ?\n)))))

;; --- composer file reference: stays editable, but with link style and jumping
(with-temp-buffer
  (insert "@src/a.ts")
  (let ((e (point)))
    (dsh-emacs-reference--composer-file-chip (- e 9) e "src/a.ts")
    (dsh-test-assert "composer-file-chip-styled"
      (equal (get-text-property (- e 9) 'dsh-emacs-reference-ref)
             '(file . "src/a.ts")))
    (dsh-test-assert "composer-file-chip-is-atomic"
      (get-text-property (- e 9) 'dsh-emacs-reference-chip))))

;; A completed file reference is a chip: with the cursor at its end it must not be
;; treated as a new active @ token (otherwise the data watcher re-fetches along
;; that path and re-narrows the candidate cache — the next @ would only hold the
;; previous one's candidates). Only after the cursor moves away, then space + @,
;; is it a new token.
(let ((buf (generate-new-buffer " *t-ref-active-chip*")))
  (unwind-protect
      (with-current-buffer buf
        (setq-local dsh-emacs--input-marker (point-min-marker))
        (insert "@src/a.ts")
        (dsh-emacs-reference--composer-file-chip
         (- (point) (length "@src/a.ts")) (point) "src/a.ts")
        (dsh-test-assert "active-token-ignores-completed-file-chip"
          (null (dsh-emacs-reference--active-token)))
        (insert " @x")
        (dsh-test-assert "active-token-after-space-and-at-is-new"
          (equal (dsh-emacs-reference--active-token)
                 '("@x" "x" nil))))
    (when (buffer-live-p buf) (kill-buffer buf))))

;; --- active-token / capf: input-area token → completion region and candidates ---
(let ((buf (generate-new-buffer " *t-ref-capf*")))
  (unwind-protect
      (with-current-buffer buf
        (insert "hi @re")
        (setq-local dsh-emacs--input-marker (point-min-marker))
        (goto-char (point-max))
        ;; The token ends exactly before point → completion returns (start end candidates)
        (let ((dsh-emacs--reference-query "re")
              (dsh-emacs--reference-candidates
               (list (cons "@README.md"
                           '(:kind file :path "README.md")))))
          (cl-letf (((symbol-function 'dsh-emacs--active-session-id)
                     (lambda () "sess")))
            (dsh-test-assert "active-token-at-point"
              (equal (dsh-emacs-reference--active-token)
                     '("@re" "re" nil)))
            (let* ((res (dsh-emacs-reference-completion-at-point))
                   (start (nth 0 res))
                   (end (nth 1 res))
                   (cands (nth 2 res))
                   (props (nthcdr 3 res)))
              (dsh-test-assert "capf-region-and-candidates"
                (= start (- (point-max) 3))
                (= end (point-max))
                (equal (dsh-test-completion-items cands)
                       '("@README.md")))
              ;; The icon column is always drawn by :affixation-function itself, and the
              ;; capf
              ;; result never provides :company-kind (the :fn-style file/folder glyphs of
              ;; nerd-icons-corfu / kind-icon strip the nerd-font font family → garbled
              ;; symbols)
              (dsh-test-assert "capf-plist-no-company-kind"
                (functionp (plist-get props :affixation-function))
                (functionp (plist-get props :exit-function))
                (null (plist-get props :company-kind)))
              (dsh-test-assert "capf-reopens-bare-at-after-backspace"
                (eq (plist-get props :company-prefix-length) t))
              (dsh-test-assert "capf-preserves-reference-order"
                (eq (plist-get props :display-sort-function) #'identity)
                (eq (completion-metadata-get
                     (completion-metadata "" cands nil)
                     'display-sort-function)
                    #'identity)
                (eq (completion-metadata-get
                     (completion-metadata "" cands nil)
                     'cycle-sort-function)
                    #'identity)))
            ;; Point outside the input area (read-only region) → nil
            (goto-char (point-min))
            (dsh-test-assert "capf-outside-input-nil"
              (null (dsh-emacs-reference-completion-at-point))))))
    (when (buffer-live-p buf) (kill-buffer buf))))

;; --- capf session rows: short-label candidates + exit-function rewrites to the
;; canonical mention ---
(let ((buf (generate-new-buffer " *t-ref-exit*")))
  (unwind-protect
      (with-current-buffer buf
        (insert "hi @M")
        (setq-local dsh-emacs--input-marker (point-min-marker))
        (goto-char (point-max))
        (let ((dsh-emacs--reference-query "")
              (dsh-emacs--reference-candidates
               (list (cons "@[My Talk](dsh-session:cyJpZCI6InMxIn0)"
                           '(:kind session :label "My Talk"
                                   :session-id "s1")))))
          (cl-letf (((symbol-function 'dsh-emacs--active-session-id)
                     (lambda () "sess")))
            (let* ((res (dsh-emacs-reference-completion-at-point))
                   (cands (nth 2 res))
                   (exit (plist-get (nthcdr 3 res) :exit-function)))
              (dsh-test-assert "capf-session-row-short"
                (equal (dsh-test-completion-items cands)
                       '("@My Talk")))
              ;; Simulate the frontend inserting the row text then calling exit: short
              ;; @label
              ;; text kept + canonical properties
              (delete-region (- (point) 2) (point))
              (insert "@My Talk")
              (dsh-test-assert "capf-exit-keeps-short-label-chip"
                (progn
                  (funcall exit "@My Talk" 'finished)
                  (string= (buffer-substring-no-properties
                            (point-min) (point-max))
                           "hi @My Talk")
                  (string= (get-text-property
                            (- (point) (length "@My Talk"))
                            'dsh-emacs-reference-canonical)
                           "@[My Talk](dsh-session:cyJpZCI6InMxIn0)")
                  ;; Send/history input reads expand back to the full mention
                  (string= (dsh-emacs--get-input)
                           "hi @[My Talk](dsh-session:cyJpZCI6InMxIn0)")))
              ;; Completion consumes that @ token: clear the narrowed fetch state so the
              ;; next @
              ;; restores the full set
              (dsh-test-assert "capf-exit-resets-fetch-state"
                (and (null dsh-emacs--reference-query)
                     (null dsh-emacs--reference-requested)))))))
    (when (buffer-live-p buf) (kill-buffer buf))))

;; --- directory candidates: after selection immediately request the next level so
;; Corfu can keep expanding ---
(let ((buf (generate-new-buffer " *t-ref-directory-drill*"))
      (requested nil))
  (unwind-protect
      (with-current-buffer buf
        (insert "hi @src/")
        (setq-local dsh-emacs--reference-query "src/"
                    dsh-emacs--reference-candidates
                    (list (cons "@src/" '(:kind directory :path "src"))))
        (cl-letf (((symbol-function 'dsh-emacs--active-session-id)
                   (lambda () "sess"))
                  ((symbol-function 'dsh-emacs-reference--fetch-query)
                   (lambda (session-id query)
                     (setq requested (list session-id query))))
                  ((symbol-function 'dsh-emacs-reference--schedule-popup-refresh)
                   #'ignore))
          (dsh-emacs-reference--exit "@src/" 'finished nil))
        (dsh-test-assert "directory-pick-fetches-next-level"
          (equal requested '("sess" "src/"))
          (null dsh-emacs--reference-query)))
    (when (buffer-live-p buf) (kill-buffer buf))))

;; --- insert: the active token before point is replaced; with no token, insert at
;; point ---
(let ((buf (generate-new-buffer " *t-ref-insert*")))
  (unwind-protect
      (with-current-buffer buf
        (insert "see @old")
        (setq-local dsh-emacs--input-marker (point-min-marker))
        (goto-char (point-max))
        (dsh-emacs-reference--insert-at-point
         "@[New](dsh-session:cyJpZCI6InMxIn0)")
        ;; Session mention: the buffer stores a short @label, canonical goes on text
        ;; properties
        (dsh-test-assert "insert-replaces-token-keeps-short-label"
          (string= (buffer-substring-no-properties (point-min) (point-max))
                   "see @New")
          (string= (get-text-property
                    (- (point-max) (length "@New"))
                    'dsh-emacs-reference-canonical)
                   "@[New](dsh-session:cyJpZCI6InMxIn0)"))
        (goto-char (point-max))
        (dsh-emacs-reference--insert-at-point "@tail.md")
        (dsh-test-assert "insert-no-token-inserts-at-point"
          (string= (buffer-substring-no-properties (point-min) (point-max))
                   "see @New@tail.md"))
        ;; Reading the input expands the short chip back to the full mention (file @path
        ;; is identical)
        (dsh-test-assert "insert-expands-to-full-mention"
          (string= (dsh-emacs--get-input)
                   "see @[New](dsh-session:cyJpZCI6InMxIn0)@tail.md")))
    (when (buffer-live-p buf) (kill-buffer buf))))

;; --- active-token: a completed canonical mention (with label escapes) no longer
;; triggers completion ---
(let ((buf (generate-new-buffer " *t-ref-done*")))
  (unwind-protect
      (with-current-buffer buf
        (insert "@[My Talk](dsh-session:cyJpZCI6InMxIn0)")
        (setq-local dsh-emacs--input-marker (point-min-marker))
        (goto-char (point-max))
        (dsh-test-assert "active-token-completed-plain-nil"
          (null (dsh-emacs-reference--active-token)))
        ;; The host escapes `\` and `]` in the label as `\\` / `\]` (see the harness's
        ;; formatSessionReferenceMention), so the completion check must keep up
        (erase-buffer)
        (insert "@[My\\]Talk](dsh-session:cyJpZCI6InMxIn0)")
        (goto-char (point-max))
        (dsh-test-assert "active-token-completed-escaped-bracket-nil"
          (null (dsh-emacs-reference--active-token)))
        (erase-buffer)
        (insert "@[a\\\\b](dsh-session:cyJpZCI6InMxIn0)")
        (goto-char (point-max))
        (dsh-test-assert "active-token-completed-escaped-backslash-nil"
          (null (dsh-emacs-reference--active-token)))
        (erase-buffer)
        (insert "hi @re")
        (goto-char (point-max))
        (dsh-test-assert "active-token-in-progress-still-triggers"
          (equal (dsh-emacs-reference--active-token) '("@re" "re" nil))))
    (when (buffer-live-p buf) (kill-buffer buf))))
;; Performance regressions: callbacks must retain their owning buffer.
(let ((owner (generate-new-buffer " *dsh-spinner-owner*")) timer)
  (unwind-protect
      (progn
        (with-current-buffer owner
          (dsh-emacs-render--reset-tool-tracking)
          (dsh-emacs--command-spinner-start "perf" owner)
          (setq timer (nth 1 (gethash "perf" dsh-emacs--command-spinners))))
        (with-temp-buffer
          (apply (timer--function timer) (timer--args timer)))
        (dsh-test-assert "spinner-callback-stops-missing-row-from-other-buffer"
          (not (memq timer timer-list)))
        (with-current-buffer owner
          (dsh-emacs--command-spinner-start "perf" owner)
          (setq timer (nth 1 (gethash "perf" dsh-emacs--command-spinners)))
          (dsh-emacs-render--reset-tool-tracking))
        (dsh-test-assert "spinner-reset-cancels-old-timer"
          (not (memq timer timer-list))))
    (when timer (cancel-timer timer))
    (when (buffer-live-p owner) (kill-buffer owner))))
;; An idle application stream is healthy when the WebSocket answers pings.
(with-temp-buffer
  (let ((process (make-pipe-process :name "dsh-watchdog-test"
                                    :buffer (current-buffer) :noquery t))
        sent deleted)
    (unwind-protect
        (progn
          (setq-local dsh-emacs--event-process process
                      dsh-emacs--event-ready t
                      dsh-emacs--ml-busy t
                      dsh-emacs--ws-last-event-time 90
                      dsh-emacs--ws-last-probe-time nil
                      dsh-emacs--ws-probe-inflight nil)
          (process-put process 'dsh-emacs-chat-buffer (current-buffer))
          (cl-letf (((symbol-function 'float-time) (lambda (&rest _) 100.0))
                    ((symbol-function 'process-send-string)
                     (lambda (_process data) (setq sent data)))
                    ((symbol-function 'delete-process)
                     (lambda (_process) (setq deleted t))))
            (dsh-emacs-events--watchdog-tick (current-buffer)))
          (dsh-test-assert "watchdog-probes-before-disconnecting"
            sent (not deleted)
            (= 9 (or (car (and sent (dsh-emacs-events--read-frame sent))) -1)))
          (when sent
            (let ((payload (nth 2 (dsh-emacs-events--read-frame sent))))
              (process-put process 'dsh-emacs-event-input
                           (dsh-emacs-events--frame 10 "wrong-probe"))
              (dsh-emacs-events--consume-frames process)
              (dsh-test-assert "watchdog-ignores-unmatched-pong"
                dsh-emacs--ws-probe-inflight)
              (process-put process 'dsh-emacs-event-input
                           (dsh-emacs-events--frame 10 payload))
              (dsh-emacs-events--consume-frames process)
              (dsh-test-assert "watchdog-pong-clears-probe"
                (not dsh-emacs--ws-probe-inflight))))
          (setq dsh-emacs--ws-probe-inflight "unanswered"
                dsh-emacs--ws-last-probe-time 90
                deleted nil)
          (cl-letf (((symbol-function 'float-time) (lambda (&rest _) 100.0))
                    ((symbol-function 'delete-process)
                     (lambda (_process) (setq deleted t))))
            (dsh-emacs-events--watchdog-tick (current-buffer)))
          (dsh-test-assert "watchdog-disconnects-unanswered-probe" deleted))
      (delete-process process))))

;; A chat socket receives its first frame immediately, then batches reads.
(dolist (ending '(resume alternate disconnect lost))
  (with-temp-buffer
    (let* ((owner (current-buffer))
           (process (make-pipe-process :name "dsh-read-batch-test"
                                       :buffer owner :noquery t))
           (filter (if (eq ending 'alternate) #'ignore
                     dsh-emacs-events--filter-fn))
           (frame (dsh-emacs-events--frame 1 "second"))
           received timer)
      (unwind-protect
          (progn
            (setq-local dsh-emacs--event-process process)
            (process-put process 'dsh-emacs-chat-buffer owner)
            (process-put process 'dsh-emacs-event-ready t)
            (set-process-filter process filter)
            (cl-letf (((symbol-function 'dsh-emacs-events--dispatch-json)
                       (lambda (_process text) (push text received))))
              (dsh-emacs-events--filter
               process (concat (dsh-emacs-events--frame 1 "first")
                               (substring frame 0 3)))
              (setq timer (process-get process 'dsh-emacs-event-read-timer))
              (dsh-test-assert (format "socket-read-batch-%s-first" ending)
                (equal received '("first"))
                (eq (process-filter process) t)
                (eq (process-get process 'dsh-emacs-event-read-filter) filter)
                (timerp timer)
                (equal (process-get process 'dsh-emacs-event-input)
                       (substring frame 0 3)))
              (pcase ending
                ((or 'resume 'alternate)
                 (when (timerp timer)
                   ;; Timer callbacks need no current-buffer assumption.
                   (with-temp-buffer
                     (apply (timer--function timer) (timer--args timer))))
                 (dsh-test-assert
                     (format "socket-read-batch-%s-restores-filter" ending)
                   (eq (process-filter process) filter)
                   (null (process-get process 'dsh-emacs-event-read-timer))
                   (null (process-get process 'dsh-emacs-event-read-filter))
                   (not (memq timer timer-list)))
                 (dsh-emacs-events--filter
                  process (concat (substring frame 3)
                                  (dsh-emacs-events--frame 1 "third")))
                 (dsh-test-assert
                     (format "socket-read-batch-%s-keeps-fragments-and-order"
                             ending)
                   (equal (reverse received) '("first" "second" "third"))
                   (timerp (process-get process 'dsh-emacs-event-read-timer))))
                ('disconnect (dsh-emacs-events-disconnect owner))
                ('lost
                 (cl-letf (((symbol-function 'dsh-emacs-events--schedule-reconnect)
                            #'ignore))
                   (dsh-emacs-events--lost process))))
              (unless (memq ending '(resume alternate))
                (dsh-test-assert (format "socket-read-batch-%s-cleans-timer" ending)
                  (null (process-get process 'dsh-emacs-event-read-timer))
                  (null (process-get process 'dsh-emacs-event-read-filter))
                  (not (memq timer timer-list))))))
        (when-let* ((pending (process-get process 'dsh-emacs-event-read-timer)))
          (cancel-timer pending))
        (when (timerp timer) (cancel-timer timer))
        (delete-process process)))))

;; Host waterfalls keep their input path immediately readable.
(with-temp-buffer
  (let ((process (make-pipe-process :name "dsh-host-read-test"
                                    :buffer (current-buffer) :noquery t)))
    (unwind-protect
        (progn
          (process-put process 'dsh-emacs-host-stream t)
          (process-put process 'dsh-emacs-event-ready t)
          (set-process-filter process dsh-emacs-events--filter-fn)
          (dsh-emacs-events--filter process "")
          (dsh-test-assert "host-stream-does-not-pause-for-chat-batching"
            (eq (process-filter process) dsh-emacs-events--filter-fn)
            (null (process-get process 'dsh-emacs-event-read-timer))))
      (delete-process process))))

;; Pending text will redraw the busy indicator without an extra forced pass.
(dolist (kind '(assistant thinking))
  (with-temp-buffer
    (let ((owner (current-buffer))
          (redraws 0))
      (unwind-protect
          (progn
            (dsh-emacs--ml-busy-set t)
            (set (make-local-variable
                  (if (eq kind 'assistant) 'dsh-emacs--streaming-assistant
                    'dsh-emacs--streaming-thinking))
                 (list :timer 'pending))
            (cl-letf (((symbol-function 'get-buffer-window)
                       (lambda (&rest _) (selected-window)))
                      ((symbol-function 'force-mode-line-update)
                       (lambda (&rest _) (cl-incf redraws))))
              (with-temp-buffer (dsh-emacs--ml-busy-tick owner))
              (dsh-test-assert (format "busy-%s-shares-text-redraw" kind)
                (= dsh-emacs--ml-busy-index 1)
                (zerop redraws))
              (setq dsh-emacs--streaming-assistant nil
                    dsh-emacs--streaming-thinking nil)
              (dsh-emacs--ml-busy-tick owner)
              (dsh-test-assert (format "busy-%s-redraws-during-text-silence" kind)
                (= dsh-emacs--ml-busy-index 2)
                (= redraws 1))))
        (dsh-emacs--ml-busy-clear)))))

;; A burst writes once per flush; finalization reuses the painted body.
(with-temp-buffer
  (dsh-emacs-mode)
  (let ((event '((data . ((turn . 1) (step . 1)))))
        (calls 0) (forced 0) (writes 0) (anchors 0)
        (anchor (symbol-function 'dsh-emacs-render--input-anchor-pos))
        (render (symbol-function 'dsh-emacs-markdown-replace-markup)))
    (cl-letf (((symbol-function 'dsh-emacs-markdown-replace-markup)
               (lambda (&rest args)
                 (setq calls (1+ calls))
                 (when (plist-get args :force) (setq forced (1+ forced)))
                 (apply render args)))
              ((symbol-function 'dsh-emacs-render--input-anchor-pos)
               (lambda () (setq anchors (1+ anchors)) (funcall anchor))))
      (dsh-emacs-render--start-assistant-stream event "hello")
      (add-hook 'after-change-functions
                (lambda (&rest _) (setq writes (1+ writes))) nil t)
      (dotimes (_ 10)
        (dsh-emacs-render--start-assistant-stream event " world")
        (dsh-emacs-render--follow-stream))
      (dsh-test-assert "stream-coalesces-markdown-burst" (= calls 1))
      (let* ((state dsh-emacs--streaming-assistant)
             (end (marker-position (plist-get state :end))))
        (dsh-test-assert "stream-burst-defers-writes-and-follow"
          (equal (buffer-substring-no-properties
                  (plist-get state :start) end) "hello")
          (= writes 0) (= anchors 0)
          (get-text-property (1- end) 'read-only)))
      (dsh-emacs-render--finish-assistant-stream
       event (concat "hello" (apply #'concat (make-list 10 " world"))))
      (dsh-test-assert "stream-final-flushes-without-full-rewrite"
        (= calls 2) (= forced 0) (null dsh-emacs--streaming-assistant)
        (string-match-p (concat "hello" (apply #'concat (make-list 10 " world")))
                        (buffer-string))))))

;; Table wrapping must measure each character once, retaining layout and faces.
(dolist (case '(("alpha beta gamma" 8 ("alpha" "beta" "gamma"))
                ("你好世界 hello" 5 ("你好" "世界" "hello"))
                ("a⚠️ b" 3 ("a⚠️" "b"))
                ("abcdefgh" 3 ("abc" "def" "gh"))
                ("a\tb" 4 ("a" "b"))
                ("á b" 2 ("á" "b"))
                ("ab  " 10 ("ab  "))
                ("界" 1 ("界"))
                ("" 4 (""))))
  (pcase-let ((`(,text ,width ,expected) case))
    (let ((calls 0)
          (measure (symbol-function 'dsh-emacs-markdown--table-wrap-char-width)))
      (cl-letf (((symbol-function 'dsh-emacs-markdown--table-wrap-char-width)
                 (lambda (&rest args)
                   (setq calls (1+ calls))
                   (apply measure args))))
        (dsh-test-assert (format "table-wrap-single-measure-%S" text)
          (equal (dsh-emacs-markdown--table-wrap-text text width) expected)
          (= calls (length text)))))))
(let* ((styled (propertize "WW" 'face 'bold))
       (text (concat styled " xx")))
  (cl-letf (((symbol-function 'dsh-emacs-markdown--table-wrap-char-width)
             (lambda (str pos &optional _window)
               (if (get-text-property pos 'face str) 2 1))))
    (dsh-test-assert "table-wrap-preserves-face-dependent-width-and-properties"
      (equal-including-properties
       (dsh-emacs-markdown--table-wrap-text text 4)
       (list styled "xx")))))

;; The renderer owns and reuses the Markdown frontier across real flushes.
(with-temp-buffer
  (dsh-emacs-mode)
  (let ((event '((data . ((turn . 1) (step . 1)))))
        (scanned 0)
        (stream-end (symbol-function 'dsh-emacs-markdown--stream-end)))
    (cl-letf (((symbol-function 'dsh-emacs-markdown--stream-end)
               (lambda (state)
                 (setq scanned
                       (+ scanned (- (point-max)
                                     (or (plist-get state :scan) (point-min)))))
                 (funcall stream-end state))))
      (dsh-emacs-render--start-assistant-stream event "```text\n")
      (let* ((markdown (plist-get dsh-emacs--streaming-assistant :markdown))
             (scan (plist-get markdown :scan)))
        (dotimes (_ 20)
          (dsh-emacs-render--start-assistant-stream event "row\n")
          (dsh-emacs-render--flush-stream))
        (dsh-test-assert "stream-renderer-retains-incremental-frontier"
          (= scanned (+ 8 (* 20 4)))
          (markerp scan)
          (eq markdown (plist-get dsh-emacs--streaming-assistant :markdown))
          (eq scan (plist-get markdown :scan)))
        (dsh-emacs-render--finish-assistant-stream
         event (concat "```text\n" (apply #'concat (make-list 20 "row\n")) "```"))
        (dsh-test-assert "stream-corrected-final-releases-frontier"
          (null (plist-get markdown :scan))
          (null (plist-get markdown :pending))
          (text-property-not-all (point-min) (point-max)
                                 'dsh-emacs-markdown-frozen nil))))))

;; Advancing the live frontier must not rewrite the stable reply prefix.
(with-temp-buffer
  (dsh-emacs-mode)
  (let ((event '((data . ((turn . 1) (step . 1)))))
        (put (symbol-function 'put-text-property))
        (prefix-writes 0))
    (dsh-emacs-render--start-assistant-stream event "**stable**\n")
    (let* ((state dsh-emacs--streaming-assistant)
           (markdown (plist-get state :markdown))
           (start (marker-position (plist-get state :start)))
           (stable (buffer-substring start (plist-get state :end))))
      (cl-letf (((symbol-function 'put-text-property)
                 (lambda (beg end prop value &optional object)
                   (when (and (not object) (= beg start))
                     (cl-incf prefix-writes))
                   (funcall put beg end prop value object))))
        (dotimes (_ 10)
          (dsh-emacs-render--start-assistant-stream event "next\n")
          (dsh-emacs-render--flush-stream)))
      (dsh-test-assert "stream-frontier-does-not-invalidate-stable-prefix"
        (= prefix-writes 0)
        (equal-including-properties
         stable (buffer-substring start (+ start (length stable)))))
      (let ((watermark (plist-get markdown :watermark)))
        (dsh-test-assert "stream-frontier-tracks-rendered-tail"
          (markerp watermark)
          (equal watermark (plist-get state :end)))
        (dsh-emacs-render--finish-assistant-stream
         event (concat "**stable**\n" (apply #'concat (make-list 10 "next\n"))))
        (dsh-test-assert "stream-final-releases-render-frontier"
          (null (plist-get markdown :watermark))
          (or (not (markerp watermark)) (null (marker-buffer watermark))))))))

;; Timer callbacks write to their owner once, preserving draft and properties.
(with-temp-buffer
  (dsh-emacs-mode)
  (goto-char (point-max))
  (insert "draft\n草稿")
  (let ((owner (current-buffer))
        (event '((data . ((turn . 1) (step . 1)))))
        (insertions 0))
    (dsh-emacs-render--start-assistant-stream event "你好")
    (dsh-emacs-render--start-assistant-stream event " world")
    (let ((timer (plist-get dsh-emacs--streaming-assistant :timer)))
      (dsh-emacs-render--start-assistant-stream event "\n下一行")
      (dsh-test-assert "stream-burst-keeps-one-timer"
        (eq timer (plist-get dsh-emacs--streaming-assistant :timer)))
      (add-hook 'after-change-functions
                (lambda (start end old)
                  (when (and (zerop old) (< start end))
                    (setq insertions (1+ insertions)))) nil t)
      (with-temp-buffer
        (insert "other buffer")
        (apply (timer--function timer) (timer--args timer))
        (dsh-test-assert "stream-timer-does-not-write-to-current-buffer"
          (equal (buffer-string) "other buffer")))
      (let* ((state dsh-emacs--streaming-assistant)
             (end (marker-position (plist-get state :end)))
             (text (buffer-substring-no-properties (plist-get state :start) end)))
        (dsh-test-assert "stream-timer-inserts-once-with-transcript-properties"
          (eq owner (current-buffer)) (= insertions 1)
          (equal text "你好 world\n下一行")
          (get-text-property (1- end) 'read-only)
          (equal (get-text-property (1- end) 'dsh-emacs-event-block)
                 (plist-get state :event-id))
          (not (memq timer timer-list))
          (null (plist-get state :timer))
          (equal (buffer-substring-no-properties dsh-emacs--input-marker
                                                (point-max))
                 "draft\n草稿")))
      (dsh-emacs-render--flush-stream nil t))))

;; Event dispatch must flush text at boundaries without unbatching reasoning.
(with-temp-buffer
  (dsh-emacs-mode)
  (let ((text-event '((type . "assistant/chunk")
                      (data . ((turn . 1) (step . 1)
                               (chunk . ((type . "text-delta") (text . "answer")))))))
        (think-event '((type . "assistant/chunk")
                       (data . ((turn . 1) (step . 1)
                                (chunk . ((type . "reasoning-delta") (text . "think"))))))))
    (dsh-emacs-render-event text-event)
    (dsh-emacs-render-event text-event)
    (dsh-emacs-render-event think-event)
    (dsh-test-assert "stream-boundary-publishes-text-before-reasoning"
      (null (plist-get dsh-emacs--streaming-assistant :timer))
      (string-match-p "answeranswer" (buffer-string)))
    (dsh-emacs-render-event think-event)
    (dsh-emacs-render-event think-event)
    (dsh-test-assert "stream-dispatch-preserves-reasoning-batching"
      (= (length (plist-get dsh-emacs--streaming-thinking :chunks)) 2))
    (dsh-emacs-render-event text-event)
    (dsh-test-assert "stream-text-publishes-pending-reasoning"
      (null (plist-get dsh-emacs--streaming-thinking :timer))
      (string-match-p "thinkthinkthink" (buffer-string)))
    (dsh-emacs-render--finish-assistant-stream text-event "corrected")
    (dsh-test-assert "stream-correction-discards-unpainted-text"
      (string-match-p "corrected" (buffer-string))
      (not (string-match-p "answer" (buffer-string)))
      (null dsh-emacs--streaming-assistant))))

;; Cursor parsing retains a partial tail and handles masks/extended lengths.
(dolist (size '(0 3 126 65536))
  (let* ((payload (make-string size ?x))
         (wire (dsh-emacs-events--frame 1 payload))
         (input (concat "prefix" wire wire))
         (first (dsh-emacs-events--read-frame input 6))
         (second (dsh-emacs-events--read-frame input (nth 3 first))))
    (dsh-test-assert (format "websocket-cursor-roundtrip-%d" size)
      (= (nth 0 first) 1) (nth 1 first)
      (equal (nth 2 first) payload)
      (equal (nth 2 second) payload)
      (= (nth 3 second) (length input))
      (null (dsh-emacs-events--read-frame (substring wire 0 -1))))))
(with-temp-buffer
  (let* ((process (make-pipe-process :name "dsh-frame-test"
                                     :buffer (current-buffer) :noquery t))
         (first (concat (unibyte-string 129 3) "one"))
         (second (concat (unibyte-string 129 3) "two"))
         delivered)
    (unwind-protect
        (cl-letf (((symbol-function 'dsh-emacs-events--dispatch-json)
                   (lambda (_process json) (push json delivered))))
          (process-put process 'dsh-emacs-event-input
                       (concat first (substring second 0 3)))
          (dsh-emacs-events--consume-frames process)
          (dsh-test-assert "websocket-consume-preserves-partial-tail"
            (equal delivered '("one"))
            (equal (process-get process 'dsh-emacs-event-input)
                   (substring second 0 3)))
          (process-put process 'dsh-emacs-event-input
                       (concat (process-get process 'dsh-emacs-event-input)
                               (substring second 3)))
          (dsh-emacs-events--consume-frames process)
          (dsh-test-assert "websocket-consume-completes-partial-tail"
            (equal delivered '("two" "one"))
            (equal (process-get process 'dsh-emacs-event-input) "")))
      (delete-process process))))

;; Pending Markdown timers must not outlive their transcript.
(with-temp-buffer
  (dsh-emacs-mode)
  (let ((event '((data . ((turn . 1) (step . 1))))) timer)
    (dsh-emacs-render--start-assistant-stream event "hello ")
    (dsh-emacs-render--start-assistant-stream event "**world**")
    (setq timer (plist-get dsh-emacs--streaming-assistant :timer))
    (dsh-emacs-events-disconnect)
    (dsh-test-assert "stream-disconnect-flushes-and-cancels-timer"
      (timerp timer) (not (memq timer timer-list))
      (not (string-match-p "\\*\\*" (buffer-string))))))

(with-temp-buffer
  (dsh-emacs-mode)
  (let ((event '((data . ((turn . 1) (step . 1)))))
        spinner formatting)
    (unwind-protect
        (progn
          (dsh-emacs--command-spinner-start "mode-reset" (current-buffer))
          (setq spinner (nth 1 (gethash "mode-reset" dsh-emacs--command-spinners)))
          (dsh-emacs-render--start-assistant-stream event "hello ")
          (dsh-emacs-render--start-assistant-stream event "world")
          (setq formatting (plist-get dsh-emacs--streaming-assistant :timer))
          (dsh-emacs-mode)
          (dsh-test-assert "mode-reinitialization-cancels-owned-timers"
            (not (memq spinner timer-list))
            (not (memq formatting timer-list))))
      (when spinner (cancel-timer spinner))
      (when formatting (cancel-timer formatting)))))

;; --- Composer Goal Row: parse the goal projection ---
(let* ((proj (list (cons 'goal
                         (list (cons 'id "g1")
                               (cons 'revision 3)
                               (cons 'objective "Improve model picker")
                               (cons 'phase "active")
                               (cons 'blockedReason nil)
                               (cons 'maxGoalRounds 10)))))
       (goal (dsh-emacs-composer-goal-from-projection proj)))
  (dsh-test-assert "composer-goal-from-projection-parses"
    (dsh-protocol-goal-p goal)
    (equal (dsh-protocol-goal-objective goal) "Improve model picker")
    (equal (dsh-protocol-goal-phase goal) "active")
    (equal (dsh-protocol-goal-revision goal) 3)
    (equal (dsh-protocol-goal-id goal) "g1"))
  (dsh-test-assert "composer-goal-nil-projection-is-nil"
    (null (dsh-emacs-composer-goal-from-projection nil))
    (null (dsh-emacs-composer-goal-from-projection '((nope . 1))))))

;; --- Composer Goal Row: render read-only chrome above the input ---
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (dsh-emacs-composer-set-goal-from-projection
   (list (cons 'goal (list (cons 'objective "Ship the refactor")
                           (cons 'phase "active")))))
  (let ((txt (buffer-substring-no-properties (point-min) (point-max))))
    (dsh-test-assert "composer-goal-row-rendered-above-input"
      (string-match-p "Ship the refactor" txt)
      (string-match-p "active" txt)
      (markerp dsh-emacs--composer-top-marker)
      ;; The goal row must precede the `❯' input.
      (let ((g (string-match "Ship the refactor" txt))
            (p (string-match "❯" txt)))
        (and g p (< g p))))))

;; --- Composer Goal Row: leading dartboard SVG display image ---
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (dsh-emacs-composer-set-goal-from-projection
   (list (cons 'goal (list (cons 'objective "Icon lead")
                           (cons 'phase "active")))))
  (let ((beg (marker-position dsh-emacs--composer-top-marker)))
    (dsh-test-assert "composer-goal-row-leads-with-svg-icon"
      (when (image-type-available-p 'svg)
        (get-text-property beg 'display))
      ;; The icon cell carries both the chrome tag and read-only property.
      (get-text-property beg 'dsh-emacs-composer-goal-row)
      (get-text-property beg 'read-only))))

;; --- Composer Goal Row: ellipsize long objectives to one line ---
(let* ((long "this objective is far longer than any chat window could ever hope to fit on a single physical line without wrapping so it must be ellipsized")
       (goal (dsh-emacs-composer-goal-from-projection
              (list (cons 'goal (list (cons 'objective long)
                                      (cons 'phase "active")))))))
  (dsh-test-assert "composer-goal-fit-objective-ellipsizes"
    (let ((row (dsh-emacs-composer--render-row goal))
          (txt (dsh-emacs-composer--objective-text goal)))
      (and (string-match-p "…" row)
           ;; The truncated row excludes the original tail and cannot wrap.
           (not (string-match-p (substring txt (- (length txt) 20)) row)))))
  ;; Preserve short objectives unchanged.
  (let ((goal2 (dsh-emacs-composer-goal-from-projection
                (list (cons 'goal (list (cons 'objective "short")
                                        (cons 'phase "active")))))))
    (dsh-test-assert "composer-goal-fit-objective-keeps-short"
      (string-match-p "short" (dsh-emacs-composer--render-row goal2))
      (null (string-match-p "…" (dsh-emacs-composer--render-row goal2))))))

;; External clients may create multiline objectives; chrome remains one line
;; and clearing it must not leave later objective lines in the transcript.
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (dsh-emacs-composer-set-goal-from-projection
   (list (cons 'goal (list (cons 'objective "line one\r\nline two\nline three")
                           (cons 'phase "active")))))
  (let* ((region (dsh-emacs-composer--region))
         (row (buffer-substring-no-properties (car region) (cdr region))))
    (dsh-test-assert "composer-goal-multiline-objective-folds-to-one-row"
      (string-match-p "line one line two line three" row)
      (= (cl-count ?\n row) 1)
      (null (string-match-p "\r" row))))
  (dsh-emacs-composer-set-goal-from-projection nil)
  (dsh-test-assert "composer-goal-multiline-clear-leaves-no-orphan"
    (null (string-match-p "line one\\|line two\\|line three"
                          (buffer-substring-no-properties
                           (point-min) (point-max))))))

;; Fallback glyphs must fit even when the window is narrower than fixed chrome.
(let ((goal (dsh-emacs-composer-goal-from-projection
             (list (cons 'goal (list (cons 'objective "narrow objective")
                                     (cons 'phase "active")))))))
  (cl-letf (((symbol-function 'dsh-emacs-composer--row-width) (lambda () 8))
            ((symbol-function 'dsh-emacs-composer--goal-icon) (lambda () nil))
            ((symbol-function 'dsh-emacs-composer--action-image)
             (lambda (_svg) nil)))
    (dsh-test-assert "composer-goal-narrow-fallback-fits-width"
      (<= (string-width (dsh-emacs-composer--render-row goal)) 8))))

;; Use the narrowest width when several windows display the same buffer.
(cl-letf (((symbol-function 'get-buffer-window-list)
           (lambda (&rest _) '(wide narrow)))
          ((symbol-function 'window-text-width)
           (lambda (window) (if (eq window 'wide) 90 23))))
  (dsh-test-assert "composer-goal-width-uses-narrowest-window"
    (= (dsh-emacs-composer--row-width) 23)))

;; --- Composer Goal Row: read-only chrome without the prompt face ---
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (dsh-emacs-composer-set-goal-from-projection
   (list (cons 'goal (list (cons 'objective "Readonly row")
                           (cons 'phase "paused")))))
  (let* ((pos (save-excursion
                (goto-char (point-min))
                (and (search-forward "Readonly row" nil t)
                     (1- (point))))))
    (dsh-test-assert "composer-goal-row-is-readonly-chrome"
      (and pos
           (get-text-property pos 'read-only)
           (get-text-property pos 'dsh-emacs-composer-goal-row)
           ;; The objective uses the body face and never inherits the prompt face.
           (memq 'dsh-emacs-composer-goal-body-face
                 (if (listp (get-text-property pos 'face))
                     (get-text-property pos 'face)
                   (list (get-text-property pos 'face))))
           (null (memq 'dsh-emacs-input-prompt-face
                       (if (listp (get-text-property pos 'face))
                           (get-text-property pos 'face)
                         (list (get-text-property pos 'face)))))))))

;; --- Composer Goal Row: transcript inserts above the row ---
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (dsh-emacs-composer-set-goal-from-projection
   (list (cons 'goal (list (cons 'objective "Seam check")
                           (cons 'phase "active")))))
  ;; With a composer marker, the insertion seam resolves to the row start.
  (let ((insert-pt (dsh-emacs-render--input-insert-point)))
    (dsh-test-assert "composer-insert-point-lands-at-goal-row"
      (and insert-pt
           (= insert-pt (marker-position dsh-emacs--composer-top-marker)))))
  ;; Messages stack above the Goal Row and retain their order.
  (dsh-emacs-render-event
   (list (cons 'type "assistant/message") (cons 'seq 1)
         (cons 'data (list (cons 'message
                                 (list (cons 'content
                                             (vector (list (cons 'type "text")
                                                           (cons 'text "msg-one"))))))))))
  (dsh-emacs-render-event
   (list (cons 'type "assistant/message") (cons 'seq 2)
         (cons 'data (list (cons 'message
                                 (list (cons 'content
                                             (vector (list (cons 'type "text")
                                                           (cons 'text "msg-two"))))))))))
  (let ((txt (buffer-substring-no-properties (point-min) (point-max)))
        (goal-sig "Seam check"))
    (dsh-test-assert "composer-messages-stay-above-goal-row"
      (let ((g1 (string-match "msg-one" txt))
            (g2 (string-match "msg-two" txt))
            (g (string-match goal-sig txt)))
        (and g1 g2 g (< g1 g2) (< g2 g)))
      ;; The Goal Row stays adjacent to the input with no message between them.
      (let ((g (string-match goal-sig txt))
            (p (string-match "❯" txt)))
        (and g p (< g p))))))

;; --- Composer Goal Row: a nil projection removes chrome, not transcript ---
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (dsh-emacs-composer-set-goal-from-projection
   (list (cons 'goal (list (cons 'objective "To clear")
                           (cons 'phase "active")))))
  (dsh-emacs-render-event
   (list (cons 'type "assistant/message") (cons 'seq 1)
         (cons 'data (list (cons 'message
                                 (list (cons 'content
                                             (vector (list (cons 'type "text")
                                                           (cons 'text "keep-me"))))))))))
  (dsh-emacs-composer-set-goal-from-projection nil)
  (let ((txt (buffer-substring-no-properties (point-min) (point-max))))
    (dsh-test-assert "composer-goal-clear-removes-row-keeps-transcript"
      (null (markerp dsh-emacs--composer-top-marker))
      (null (string-match-p "To clear" txt))
      (string-match-p "keep-me" txt))))

;; --- Composer Goal Row: idempotent text and in-place projection updates ---
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (dsh-emacs-composer-set-goal-from-projection
   (list (cons 'goal (list (cons 'objective "v1") (cons 'phase "active")))))
  (let ((first-marker (copy-marker (marker-position dsh-emacs--composer-top-marker))))
    ;; Reapplying identical text is idempotent and does not move the marker.
    (dsh-emacs-composer-set-goal-from-projection
     (list (cons 'goal (list (cons 'objective "v1") (cons 'phase "active")))))
    (dsh-test-assert "composer-goal-idempotent-same-text"
      (= (marker-position first-marker)
         (marker-position dsh-emacs--composer-top-marker)))
    ;; Replacing the objective updates the same single row.
    (dsh-emacs-composer-set-goal-from-projection
     (list (cons 'goal (list (cons 'objective "v2 now") (cons 'phase "paused")))))
    (let ((txt (buffer-substring-no-properties (point-min) (point-max))))
      (dsh-test-assert "composer-goal-update-replaces-row"
        (null (string-match-p "v1" txt))
        (string-match-p "v2 now" txt)
        (string-match-p "paused" txt)
        (markerp dsh-emacs--composer-top-marker)))))

;; --- Composer Goal Row: route event projections to the live chat buffer ---
(let* ((session-id "sess-composer-1")
       (goal-proj (list (cons 'goal (list (cons 'objective "route me")
                                          (cons 'phase "active")))))
       (chat (generate-new-buffer " *t-composer-chat*")))
  (unwind-protect
      (progn
        (puthash session-id chat dsh-emacs--chat-buffers)
        (with-current-buffer chat
          (dsh-emacs-mode)
          (dsh-emacs-modeline-setup))
        (dsh-emacs-events--apply-goal-projection session-id goal-proj)
        (with-current-buffer chat
          (dsh-test-assert "composer-projection-routes-to-chat"
            (string-match-p "route me"
                            (buffer-substring-no-properties
                             (point-min) (point-max)))
            (markerp dsh-emacs--composer-top-marker)))
        ;; A null projection clears that session's Goal Row.
        (dsh-emacs-events--apply-goal-projection session-id nil)
        (with-current-buffer chat
          (dsh-test-assert "composer-projection-null-clears"
            (null (string-match-p "route me"
                                  (buffer-substring-no-properties
                                   (point-min) (point-max)))))))
    (remhash session-id dsh-emacs--chat-buffers)
    (when (buffer-live-p chat) (kill-buffer chat))))

;; --- Composer Goal Row: nil in a control baseline is a clear tombstone ---
(let* ((session-id "sess-composer-baseline-nil")
       (chat (generate-new-buffer " *t-composer-baseline-nil*")))
  (unwind-protect
      (progn
        (puthash session-id chat dsh-emacs--chat-buffers)
        (with-current-buffer chat
          (dsh-emacs-mode)
          (dsh-emacs-modeline-setup)
          (dsh-emacs-composer-set-goal-from-projection
           (list (cons 'goal (list (cons 'objective "stale baseline goal")
                                   (cons 'phase "active"))))))
        (dsh-emacs-events--host-control-baseline
         nil
         (list (cons 'projections
                     (list (cons session-id
                                 (list (cons 'values
                                             (list (cons 'goal nil)))))))))
        (with-current-buffer chat
          (dsh-test-assert "composer-control-baseline-nil-clears"
            (null dsh-emacs--composer-goal)
            (null (string-match-p
                   "stale baseline goal"
                   (buffer-substring-no-properties (point-min) (point-max)))))))
    (remhash session-id dsh-emacs--chat-buffers)
    (when (buffer-live-p chat) (kill-buffer chat))))

;; --- Composer Goal Row: hide complete goals, matching dsh web ---
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (dsh-emacs-composer-set-goal-from-projection
   (list (cons 'goal (list (cons 'objective "Shown active")
                           (cons 'phase "active")))))
  ;; Active goals are visible.
  (dsh-test-assert "composer-goal-active-shown"
    (string-match-p "Shown active"
                    (buffer-substring-no-properties (point-min) (point-max)))
    (markerp dsh-emacs--composer-top-marker))
  ;; A complete projection hides the row.
  (dsh-emacs-composer-set-goal-from-projection
   (list (cons 'goal (list (cons 'objective "Shown active")
                           (cons 'phase "complete")))))
  (dsh-test-assert "composer-goal-complete-hidden"
    (null (markerp dsh-emacs--composer-top-marker))
    (null (string-match-p "Shown active"
                          (buffer-substring-no-properties (point-min) (point-max))))))

;; --- Composer Goal Row: a goal already complete is never shown ---
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (dsh-emacs-composer-set-goal-from-projection
   (list (cons 'goal (list (cons 'objective "Never shown")
                           (cons 'phase "complete")))))
  (dsh-test-assert "composer-goal-complete-never-shown"
    (null (markerp dsh-emacs--composer-top-marker))
    (null (string-match-p "Never shown"
                          (buffer-substring-no-properties (point-min) (point-max))))))

;; --- Composer Goal Row: reflow the same goal after a width change ---
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (let ((row-width 80))
    (cl-letf (((symbol-function 'dsh-emacs-composer--row-width)
               (lambda () row-width)))
      (dsh-emacs-composer-set-goal-from-projection
       (list (cons 'goal
                   (list (cons 'objective
                               "A long objective whose rendered width must change")
                         (cons 'phase "active")))))
      (let ((wide (buffer-substring-no-properties (point-min) (point-max))))
        (setq row-width 40)
        (dsh-emacs-composer--window-configuration-change)
        (let ((narrow (buffer-substring-no-properties (point-min) (point-max))))
          (dsh-test-assert "composer-goal-reflows-after-window-change"
            (not (equal wide narrow))
            (string-match-p "…" narrow)))))))

;; --- Composer Goal Row: paused and blocked goals remain visible ---
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (dsh-emacs-composer-set-goal-from-projection
   (list (cons 'goal (list (cons 'objective "Paused goal")
                           (cons 'phase "paused")))))
  (dsh-test-assert "composer-goal-paused-shown"
    (markerp dsh-emacs--composer-top-marker)
    (string-match-p "Paused goal"
                    (buffer-substring-no-properties (point-min) (point-max)))))

;; --- Goal actions: pause wire payload and CAS ref ---
(let ((sent nil))
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-modeline-setup)
    (setq-local dsh-emacs--buffer-session "sess-gact")
    (dsh-emacs-composer-set-goal-from-projection
     (list (cons 'goal (list (cons 'id "goal-1")
                             (cons 'revision 7)
                             (cons 'objective "Active goal")
                             (cons 'phase "active")))))
    (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
               (lambda (method params cb)
                 (push (list method params) sent)
                 (funcall cb t
                         (list (cons 'id "goal-1")
                               (cons 'revision 8)
                               (cons 'objective "Active goal")
                               (cons 'phase "paused"))))))
      (dsh-emacs-goal-pause))
    (let ((call (car sent)))
      (dsh-test-assert "goal-pause-payload-ref-cas"
        (equal (nth 0 call) "goals/pause")
        (equal (cdr (assq 'agentId (nth 1 call))) "sess-gact")
        (equal (cdr (assq 'revision (cdr (assq 'ref (nth 1 call))))) 7)
        (equal (cdr (assq 'id (cdr (assq 'ref (nth 1 call))))) "goal-1")))
    ;; A successful callback optimistically updates the row to paused.
    (dsh-test-assert "goal-pause-optimistic-view"
      (string-match-p "paused"
                      (buffer-substring-no-properties (point-min) (point-max))))))

;; --- Goal actions: pause is gated to the active phase ---
(let ((sent nil))
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-modeline-setup)
    (setq-local dsh-emacs--buffer-session "sess-gpaused")
    (dsh-emacs-composer-set-goal-from-projection
     (list (cons 'goal (list (cons 'id "g-paused")
                             (cons 'revision 2)
                             (cons 'objective "Paused g")
                             (cons 'phase "paused")))))
    (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
               (lambda (_m _p _cb) (push t sent))))
      (dsh-emacs-goal-pause))
    (dsh-test-assert "goal-pause-gated-on-active"
      (null sent))))

;; --- Goal actions: an active goal cannot resume ---
(let ((sent nil))
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-modeline-setup)
    (setq-local dsh-emacs--buffer-session "sess-gactive")
    (dsh-emacs-composer-set-goal-from-projection
     (list (cons 'goal (list (cons 'id "g-active")
                             (cons 'revision 4)
                             (cons 'objective "Active g")
                             (cons 'phase "active")))))
    (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
               (lambda (_m _p _cb) (push t sent))))
      (dsh-emacs-goal-resume))
    (dsh-test-assert "goal-resume-gated-on-paused"
      (null sent))))

;; --- Goal actions: resume moves paused to active ---
(let ((sent nil))
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-modeline-setup)
    (setq-local dsh-emacs--buffer-session "sess-gresume")
    (dsh-emacs-composer-set-goal-from-projection
     (list (cons 'goal (list (cons 'id "g2") (cons 'revision 3)
                             (cons 'objective "Paused goal")
                             (cons 'phase "paused")))))
    (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
               (lambda (method _params cb)
                 (push method sent)
                 (funcall cb t
                         (list (cons 'id "g2")
                               (cons 'revision 4)
                               (cons 'objective "Paused goal")
                               (cons 'phase "active"))))))
      (dsh-emacs-goal-resume))
    (dsh-test-assert "goal-resume-payload"
      (equal (car sent) "goals/resume")
      (string-match-p "active"
                      (buffer-substring-no-properties (point-min) (point-max))))))

;; --- Goal actions: edit reads and sends request.objective ---
(let ((sent nil)
      (edit-result nil))
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-modeline-setup)
    (setq-local dsh-emacs--buffer-session "sess-gedit")
    (dsh-emacs-composer-set-goal-from-projection
     (list (cons 'goal (list (cons 'id "g3") (cons 'revision 5)
                             (cons 'objective "old objective")
                             (cons 'phase "active")))))
    (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
               (lambda (method params cb)
                 (push (list method params) sent)
                 (funcall cb t
                         (list (cons 'id "g3")
                               (cons 'revision 6)
                               (cons 'objective "new objective")
                               (cons 'phase "active"))))))
      ;; Stub `read-string' because batch mode has no minibuffer input.
      (cl-letf (((symbol-function 'read-string)
                 (lambda (&rest _) "new objective")))
        (setq edit-result (dsh-emacs-goal-edit))))
    (let ((call (car sent)))
      (dsh-test-assert "goal-edit-request-objective"
        (equal (nth 0 call) "goals/edit")
        (equal (cdr (assq 'objective
                          (cdr (assq 'request (nth 1 call)))))
               "new objective")
        (equal (cdr (assq 'revision (cdr (assq 'ref (nth 1 call))))) 5)))
    (dsh-test-assert "goal-edit-optimistic-view"
      (string-match-p "new objective"
                      (buffer-substring-no-properties (point-min) (point-max))))))

;; --- Goal actions: clear sends a tombstone and removes the row ---
(let ((sent nil))
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-modeline-setup)
    (setq-local dsh-emacs--buffer-session "sess-gclear")
    (dsh-emacs-composer-set-goal-from-projection
     (list (cons 'goal (list (cons 'id "g4") (cons 'revision 9)
                             (cons 'objective "Clear me")
                             (cons 'phase "active")))))
    (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
               (lambda (method params cb)
                 (push (list method params) sent)
                 (funcall cb t (list (cons 'id "g4") (cons 'revision 10)))))
              ((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
      (dsh-emacs-goal-clear))
    (let ((call (car sent)))
      (dsh-test-assert "goal-clear-payload"
        (equal (nth 0 call) "goals/clear")
        (equal (cdr (assq 'revision (cdr (assq 'ref (nth 1 call))))) 9)))
    (dsh-test-assert "goal-clear-removes-row"
      (null (markerp dsh-emacs--composer-top-marker))
      (null (string-match-p "Clear me"
                            (buffer-substring-no-properties (point-min) (point-max)))))))

;; --- Goal actions: RPC failure reports an error and preserves the row ---
(let ((sent nil))
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-modeline-setup)
    (setq-local dsh-emacs--buffer-session "sess-gerr")
    (dsh-emacs-composer-set-goal-from-projection
     (list (cons 'goal (list (cons 'id "g-error")
                             (cons 'revision 4)
                             (cons 'objective "Keep me")
                             (cons 'phase "active")))))
    (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
               (lambda (_m _p cb)
                 (push t sent)
                 (funcall cb nil '((message . "stale revision"))))))
      (dsh-emacs-goal-pause))
    (dsh-test-assert "goal-action-error-keeps-row"
      ;; Failure leaves both the marker and row text intact.
      (markerp dsh-emacs--composer-top-marker)
      (string-match-p "Keep me"
                      (buffer-substring-no-properties (point-min) (point-max))))))

;; --- Goal actions: the pending guard prevents a second CAS ---
(let ((sent 0))
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-modeline-setup)
    (setq-local dsh-emacs--buffer-session "sess-gpend")
    (dsh-emacs-composer-set-goal-from-projection
     (list (cons 'goal (list (cons 'id "g-pending")
                             (cons 'revision 1)
                             (cons 'objective "Once")
                             (cons 'phase "active")))))
    (setq dsh-emacs--composer-goal-pending t)
    (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
               (lambda (_m _p _cb) (cl-incf sent))))
      (dsh-emacs-goal-pause)
      (dsh-emacs-goal-resume))
    (dsh-test-assert "goal-action-pending-guard"
      (zerop sent))))

;; --- Goal actions: an older HTTP response cannot regress a newer projection ---
(let (callback)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-modeline-setup)
    (setq-local dsh-emacs--buffer-session "sess-grace")
    (dsh-emacs-composer-set-goal-from-projection
     (list (cons 'goal (list (cons 'id "g-race")
                             (cons 'revision 7)
                             (cons 'objective "Before")
                             (cons 'phase "active")))))
    (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
               (lambda (_method _params cb) (setq callback cb))))
      (dsh-emacs-goal-pause))
    ;; The authoritative stream advances twice before the rev-8 HTTP response.
    (dsh-emacs-composer-set-goal-from-projection
     (list (cons 'goal (list (cons 'id "g-race")
                             (cons 'revision 9)
                             (cons 'objective "Newer projection")
                             (cons 'phase "active")))))
    (funcall callback t
             (list (cons 'id "g-race")
                   (cons 'revision 8)
                   (cons 'objective "Older response")
                   (cons 'phase "paused")))
    (dsh-test-assert "goal-action-stale-response-keeps-newer-projection"
      (equal (dsh-protocol-goal-revision dsh-emacs--composer-goal) 9)
      (equal (dsh-protocol-goal-objective dsh-emacs--composer-goal)
             "Newer projection")
      (null dsh-emacs--composer-goal-pending))))

;; A callback from before a reset must not clear a newer request's guard.
(let (callback)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-modeline-setup)
    (setq-local dsh-emacs--buffer-session "sess-glate")
    (dsh-emacs-composer-set-goal-from-projection
     (list (cons 'goal (list (cons 'id "g-late")
                             (cons 'revision 2)
                             (cons 'objective "Still current")
                             (cons 'phase "active")))))
    (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
               (lambda (_method _params cb) (setq callback cb))))
      (dsh-emacs-goal-pause))
    (let ((newer-token (list "edit" '((id . "g-late") (revision . 2)))))
      (setq dsh-emacs--composer-goal-pending newer-token)
      (funcall callback t
               (list (cons 'id "g-late")
                     (cons 'revision 3)
                     (cons 'objective "Late response")
                     (cons 'phase "paused")))
      (dsh-test-assert "goal-action-late-callback-keeps-newer-pending-guard"
        (eq dsh-emacs--composer-goal-pending newer-token)
        (equal (dsh-protocol-goal-objective dsh-emacs--composer-goal)
               "Still current")))))

;; --- Goal actions: the strip exposes the phase-appropriate toggle ---
;; Assert keymap properties rather than glyph text because SVG cells use images.
(defun dsh-test-goal-strip-binds (strip cmd)
  "Return non-nil when some char in STRIP binds CMD on its mouse-1 keymap."
  (let ((i 0) (ok nil))
    (while (and (not ok) (< i (length strip)))
      (let* ((map (get-text-property i 'keymap strip))
             (bound (and map (lookup-key map [mouse-1]))))
        (when (eq bound cmd) (setq ok t)))
      (setq i (1+ i)))
    ok))

(dsh-test-assert "goal-strip-active-offers-pause"
  (let* ((goal (dsh-emacs-composer-goal-from-projection
                (list (cons 'goal (list (cons 'objective "A")
                                        (cons 'phase "active"))))))
         (strip (car (dsh-emacs-composer--goal-action-strip goal))))
    (and strip
         (dsh-test-goal-strip-binds strip 'dsh-emacs-goal-pause)
         (not (dsh-test-goal-strip-binds strip 'dsh-emacs-goal-resume)))))
(dsh-test-assert "goal-strip-paused-offers-resume"
  (let* ((goal (dsh-emacs-composer-goal-from-projection
                (list (cons 'goal (list (cons 'objective "A")
                                        (cons 'phase "paused"))))))
         (strip (car (dsh-emacs-composer--goal-action-strip goal))))
    (and strip
         (dsh-test-goal-strip-binds strip 'dsh-emacs-goal-resume)
         (not (dsh-test-goal-strip-binds strip 'dsh-emacs-goal-pause)))))
;; Blocked/complete goals have no toggle but retain edit and clear.
(dolist (phase '("blocked" "complete"))
  (let ((goal (dsh-emacs-composer-goal-from-projection
               (list (cons 'goal (list (cons 'objective "A")
                                       (cons 'phase phase)))))))
    (let ((strip (car (dsh-emacs-composer--goal-action-strip goal))))
      (dsh-test-assert "goal-strip-nontoggle-still-edit-clear"
        (and strip
             (not (dsh-test-goal-strip-binds strip 'dsh-emacs-goal-pause))
             (not (dsh-test-goal-strip-binds strip 'dsh-emacs-goal-resume))
             (dsh-test-goal-strip-binds strip 'dsh-emacs-goal-edit)
             (dsh-test-goal-strip-binds strip 'dsh-emacs-goal-clear))))))

;; --- Goal actions: C-c C-g prefix bindings ---
(dsh-test-assert "goal-keymap-binds-verbs"
  (eq (lookup-key dsh-emacs-goal-map (kbd "p")) #'dsh-emacs-goal-pause)
  (eq (lookup-key dsh-emacs-goal-map (kbd "r")) #'dsh-emacs-goal-resume)
  (eq (lookup-key dsh-emacs-goal-map (kbd "e")) #'dsh-emacs-goal-edit)
  (eq (lookup-key dsh-emacs-goal-map (kbd "d")) #'dsh-emacs-goal-clear)
  (eq (lookup-key dsh-emacs-goal-map (kbd "a")) #'dsh-emacs-goal-actions-toggle))

;; --- Goal actions: row keymaps point to the correct commands ---
;; Find the edit-bound cell by keymap because SVG cells have no fallback text.
(defun dsh-test-goal-row-edit-cell ()
  "Return the buffer position whose cell binds `dsh-emacs-goal-edit', or nil."
  (let ((i (point-min)) (found nil))
    (while (and (not found) (< i (point-max)))
      (let ((map (get-text-property i 'keymap)))
        (when (and map (eq (lookup-key map [mouse-1]) 'dsh-emacs-goal-edit))
          (setq found i)))
      (setq i (1+ i)))
    found))
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (dsh-emacs-composer-set-goal-from-projection
   (list (cons 'goal (list (cons 'objective "clickable")
                           (cons 'phase "active")))))
  (let ((edit-pos (dsh-test-goal-row-edit-cell)))
    (dsh-test-assert "goal-row-action-click-region"
      (and edit-pos
           (eq (lookup-key (get-text-property edit-pos 'keymap) [mouse-1])
               'dsh-emacs-goal-edit)
           (eq (lookup-key (get-text-property edit-pos 'keymap) (kbd "RET"))
               'dsh-emacs-goal-edit)
           (get-text-property edit-pos 'mouse-face)
           ;; SVG uses a display image; fallback text retains the same keymap.
           (if (image-type-available-p 'svg)
               (get-text-property edit-pos 'display)
             t)))))

;; --- Goal actions: disabling inline actions yields an empty strip ---
(let ((goal (dsh-emacs-composer-goal-from-projection
             (list (cons 'goal (list (cons 'objective "A")
                                     (cons 'phase "active")))))))
  (let ((dsh-emacs-composer-goal-actions nil))
    (dsh-test-assert "goal-actions-option-off-hides-strip"
      (null (dsh-emacs-composer--goal-action-strip goal))))
  (let ((dsh-emacs-composer-goal-actions t))
    (dsh-test-assert "goal-actions-option-on-shows-strip"
      (dsh-emacs-composer--goal-action-strip goal))))

;; --- Goal actions: the option and toggle repaint inline actions ---
(let ((buf (generate-new-buffer " *t-goal-toggle*"))
      (default-before (default-value 'dsh-emacs-composer-goal-actions)))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (dsh-emacs-modeline-setup)
        (dsh-emacs-composer-set-goal-from-projection
         (list (cons 'goal (list (cons 'objective "toggle me")
                                 (cons 'phase "active")))))
        (dsh-test-assert "goal-toggle-renders-actions-on"
          (not (null (dsh-test-goal-row-edit-cell))))
        ;; Disable and repaint: no action cells remain.
        (setq-local dsh-emacs-composer-goal-actions nil)
        (dsh-emacs-composer-refresh)
        (dsh-test-assert "goal-toggle-refresh-hides-actions"
          (null (dsh-test-goal-row-edit-cell)))
        ;; The interactive command toggles and repaints.
        (dsh-emacs-goal-actions-toggle)
        (dsh-test-assert "goal-actions-toggle-turns-back-on"
          dsh-emacs-composer-goal-actions
          (local-variable-p 'dsh-emacs-composer-goal-actions)
          (eq (default-value 'dsh-emacs-composer-goal-actions) default-before)
          (not (null (dsh-test-goal-row-edit-cell)))))
    (when (buffer-live-p buf) (kill-buffer buf))))

;; --- Goal actions: toggling outside chat creates no local override ---
(with-temp-buffer
  (let ((errored nil))
    (condition-case nil
        (dsh-emacs-goal-actions-toggle)
      (user-error (setq errored t)))
    (dsh-test-assert "goal-actions-toggle-outside-chat-errors-cleanly"
      errored
      (not (local-variable-p 'dsh-emacs-composer-goal-actions)))))
;; Editing must preserve the source objective, including embedded newlines.
(with-temp-buffer
  (dsh-emacs-mode)
  (setq-local dsh-emacs--buffer-session "goal-edit-source")
  (dsh-emacs-composer-set-goal-from-projection
   '((goal . ((id . "g") (revision . 1) (phase . "active")
              (objective . "first\nsecond")))))
  (let (initial sent)
    (cl-letf (((symbol-function 'read-string)
               (lambda (_prompt value &rest _args)
                 (setq initial value) value))
              ((symbol-function 'dsh-emacs--rpc-async)
               (lambda (_method params _callback) (setq sent params))))
      (dsh-emacs-goal-edit))
    (dsh-test-assert "goal-edit-preserves-source-objective"
      (equal initial "first\nsecond")
      (equal (cdr (assq 'objective (cdr (assq 'request sent))))
             "first\nsecond"))))

;; Pending state must be visible immediately and disappear on failure.
(with-temp-buffer
  (dsh-emacs-mode)
  (setq-local dsh-emacs--buffer-session "goal-pending-feedback")
  (dsh-emacs-composer-set-goal-from-projection
   '((goal . ((id . "g") (revision . 1) (phase . "active")
              (objective . "Work")))))
  (let (callback)
    (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
               (lambda (_method _params cb) (setq callback cb))))
      (dsh-emacs-goal-pause))
    (dsh-test-assert "goal-pending-visible-without-actions"
      (string-match-p "Pausing" (buffer-string))
      (null (dsh-test-goal-row-edit-cell)))
    (funcall callback nil "offline")
    (dsh-test-assert "goal-pending-failure-restores-controls"
      (not (string-match-p "Pausing" (buffer-string)))
      (dsh-test-goal-row-edit-cell))))

;; Full details remain reachable even when the compact row is truncated.
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-composer-set-goal-from-projection
   '((goal . ((id . "details") (revision . 2) (phase . "blocked")
              (objective . "First line\nSecond line")
              (blockedReason . "Needs approval")))))
  (save-window-excursion
    (dsh-emacs-goal-describe)
    (with-current-buffer "*dsh goal*"
      (dsh-test-assert "goal-details-preserve-objective-and-explain-block"
        (string-match-p "First line\nSecond line" (buffer-string))
        (string-match-p "Phase: blocked" (buffer-string))
        (string-match-p "Blocked: Needs approval" (buffer-string))
        buffer-read-only)))
  (dsh-emacs-composer-set-goal-from-projection
   '((goal . ((id . "details") (revision . 3) (phase . "blocked")
              (objective . "First line\nSecond line")
              (blockedReason . "Needs credentials")))))
  (dsh-test-assert "goal-reason-only-change-refreshes-tooltip"
    (cl-loop for pos from (point-min) below (point-max)
             thereis (let ((help (get-text-property pos 'help-echo)))
                       (and (stringp help)
                            (string-match-p "Needs credentials" help)))))
  (dsh-test-assert "goal-details-key"
    (eq (lookup-key dsh-emacs-goal-map (kbd "?"))
        #'dsh-emacs-goal-describe)))

(let ((goal (dsh-emacs-composer-goal-from-projection
             '((goal . ((objective . "A long objective")
                        (phase . "blocked")))))))
  (cl-letf (((symbol-function 'dsh-emacs-composer--row-width) (lambda () 24)))
    (let ((row (dsh-emacs-composer--render-row goal)))
      (dsh-test-assert "goal-compact-row-prioritizes-status"
        (string-match-p "blocked" row)
        (<= (string-width row) 24)
        (not (dsh-test-goal-strip-binds row 'dsh-emacs-goal-edit))))))

;; Both SVGs must fit their backing text even in a frame with tiny cells.
(cl-letf (((symbol-function 'image-type-available-p) (lambda (_type) t))
          ((symbol-function 'get-buffer-window-list) (lambda (&rest _args) nil))
          ((symbol-function 'frame-char-width) (lambda (&optional _frame) 5))
          ((symbol-function 'create-image)
           (lambda (_data _type _data-p &rest props) (cons 'image props))))
  (let* ((icon (dsh-emacs-composer--goal-icon))
         (action (dsh-emacs-composer--goal-action-cell
                  "⏸" dsh-emacs-composer--pause-svg #'dsh-emacs-goal-pause)))
    (dsh-test-assert "goal-svg-fits-reserved-columns"
      (= (plist-get (cdr (get-text-property 0 'display icon)) :width) 10)
      (= (plist-get (cdr (get-text-property 0 'display action)) :width) 10)
      (= (string-width icon) 2)
      (= (string-width action) 2))))

;; Composer owns both rows; queue state must never become prompt text.
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs--replace-input "draft\nsecond line")
  (goto-char (+ dsh-emacs--input-marker 3))
  (setq dsh-emacs--queue-items
        (list (dsh-protocol-queue-item--from-alist
               (dsh-emacs-test--queue-item "next" "queued" "Queued work"))))
  (dsh-emacs-composer-set-goal-from-projection
   '((goal . ((objective . "Current goal") (phase . "active")))))
  (dsh-emacs-queue--paint-after-burst)
  (dsh-test-assert "composer-next-has-own-row-and-preserves-draft-point"
    (dsh-test-composer-next-row)
    (equal (dsh-emacs--get-input) "draft\nsecond line")
    (= (- (point) dsh-emacs--input-marker) 3)
    (equal (buffer-substring-no-properties
            (dsh-emacs-render--input-anchor-pos) dsh-emacs--input-marker)
           "❯ ")
    (string-match-p "Current goal.*\n.*Queued work.*\n❯ draft"
                    (buffer-string)))
  ;; Use the actual transcript insertion seam while both chrome rows exist.
  (save-excursion
    (goto-char (dsh-emacs-render--input-insert-point))
    (let ((inhibit-read-only t)) (insert "STREAMED\n")))
  (dsh-emacs-composer-set-goal nil)
  (dsh-test-assert "composer-goal-clear-keeps-next-and-transcript"
    (markerp dsh-emacs--composer-top-marker)
    (dsh-test-composer-next-row)
    (string-match-p "STREAMED\n.*Queued work.*\n❯ draft" (buffer-string))
    (not (string-match-p "Current goal" (buffer-string)))
    (equal (dsh-emacs--get-input) "draft\nsecond line"))
  (setq dsh-emacs--queue-items nil)
  (dsh-emacs-queue--paint-after-burst)
  (dsh-test-assert "composer-last-row-removal-clears-only-chrome"
    (null dsh-emacs--composer-top-marker)
    (null (dsh-test-composer-next-row))
    (string-match-p "STREAMED\n❯ draft" (buffer-string))
    (equal (dsh-emacs--get-input) "draft\nsecond line")))

(with-temp-buffer
  (dsh-emacs-mode)
  (setq dsh-emacs--queue-items
        (list (dsh-protocol-queue-item--from-alist
               (dsh-emacs-test--queue-item
                "wide" "queued"
                "First line\nSecond line with a long continuation 中文中文中文"))))
  (let ((width 60))
    (cl-letf (((symbol-function 'dsh-emacs-composer--row-width)
               (lambda () width)))
      (dsh-emacs-queue--paint-after-burst)
      (let ((wide (dsh-test-composer-next-row)))
        (setq width 18)
        (dsh-emacs-composer--window-configuration-change)
        (let ((narrow (dsh-test-composer-next-row)))
          (dsh-test-assert "composer-next-reflows-without-goal"
            (and wide narrow
                 (> (string-width (string-trim-right wide))
                    (string-width (string-trim-right narrow)))
                 (<= (string-width (string-trim-right narrow)) 18)
                 (= (cl-count ?\n narrow) 1)
                 (get-text-property 0 'read-only narrow))))))))

;; Removing Next Message must leave the goal intact.  Rebuilding the input
;; invalidates geometry but not the mirrored data or the ability to repaint.
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (setq dsh-emacs--queue-items
        (list (dsh-protocol-queue-item--from-alist
               (dsh-emacs-test--queue-item "row" "queued" "Pending work"))))
  (dsh-emacs-composer-set-goal-from-projection
   '((goal . ((objective . "Keep goal") (phase . "active")))))
  (let ((top dsh-emacs--composer-top-marker)
        (end dsh-emacs--composer-end-marker)
        (tick (buffer-chars-modified-tick)))
    (dsh-emacs-composer-render)
    (dsh-test-assert "composer-unchanged-rows-do-not-rewrite-buffer"
      (eq top dsh-emacs--composer-top-marker)
      (eq end dsh-emacs--composer-end-marker)
      (= tick (buffer-chars-modified-tick))))
  (dsh-emacs-render-event
   '((type . "assistant/message") (seq . 1)
     (data . ((message . ((content . [((type . "text")
                                     (text . "Rendered transcript"))])))))))
  (setq dsh-emacs--queue-items nil)
  (dsh-emacs-queue--paint-after-burst)
  (dsh-test-assert "composer-next-clear-keeps-goal-and-rendered-transcript"
    (null (dsh-test-composer-next-row))
    (string-match-p "Keep goal.*\n❯ " (buffer-string))
    (string-match-p "Rendered transcript" (buffer-string))
    (dsh-emacs-composer--region))
  (dsh-emacs--setup-input-area)
  (dsh-emacs-composer-render)
  (dsh-test-assert "composer-rebuild-replaces-collapsed-markers"
    (dsh-emacs-composer--region)
    (string-match-p "DeepSeek Harness" (buffer-string))
    (string-match-p "Keep goal.*\n❯ " (buffer-string)))
  (dsh-emacs-composer-set-goal nil)
  (dsh-test-assert "composer-all-markers-release-when-empty"
    (null dsh-emacs--composer-top-marker)
    (null dsh-emacs--composer-end-marker)))


;; --- Test 119: dsh 0.1.5 in-process assistant-stream frames drive live text ---
;; `assistant/chunk' is no longer a durable Session event (dsh 0.1.5); the
;; process-local `assistant-stream' frames are the only incremental source.
;; A follow client must opt in with `assistantStream: true' and consume
;; `chunk' frames through the incremental renderer.
(let ((buf (generate-new-buffer " *dsh-stream-frame*")))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (setq-local dsh-emacs--buffer-session "sess-frame")
        ;; A durable-event watermark the process-local frames must not move.
        (setq-local dsh-emacs--anchor-seq 7)
        (dsh-emacs-events--follow-item
         (current-buffer)
         '((type . "assistant-stream")
           (frame . ((type . "start") (attemptId . "a1") (revision . 1)
                     (startedAfterSeq . 4) (turn . 1) (step . 1)))))
        (dsh-emacs-events--follow-item
         (current-buffer)
         '((type . "assistant-stream")
           (frame . ((type . "chunk") (attemptId . "a1") (revision . 1)
                     (index . 1) (time . 5)
                     (chunk . ((type . "text-delta") (index . 1)
                               (text . "live-")))))))
        (dsh-emacs-events--follow-item
         (current-buffer)
         '((type . "assistant-stream")
           (frame . ((type . "chunk") (attemptId . "a1") (revision . 1)
                     (index . 2) (time . 6)
                     (chunk . ((type . "text-delta") (index . 1)
                               (text . "reply")))))))
        ;; Flush what the burst timer still owes so the assertion does not
        ;; race it.
        (dsh-emacs-render--flush-stream (current-buffer) t)
        (dsh-test-assert "follow-assistant-stream-renders-live-text"
          (string-match-p "live-reply" (buffer-string))
          ;; Process-local frames are not durable: they carry no seq, so the
          ;; dedup anchor must stay exactly where it was.
          (= dsh-emacs--anchor-seq 7)))
    (when (buffer-live-p buf) (kill-buffer buf))))

;; --- Test 119b: assistant-stream frames with an old revision are dropped ---
;; A reconnect bumps `revision' and replays the accumulated attempt in the
;; opening snapshot; accepting an older generation would interleave two
;; revisions into one live body.
(let ((buf (generate-new-buffer " *dsh-stream-revision*")))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (setq-local dsh-emacs--buffer-session "sess-frame")
        (dsh-emacs-events--assistant-stream-frame
         (current-buffer)
         '((type . "start") (revision . 2) (turn . 1) (step . 1)))
        (dsh-emacs-events--assistant-stream-frame
         (current-buffer)
         '((type . "chunk") (revision . 2)
           (chunk . ((type . "text-delta") (text . "new-gen")))))
        (dsh-emacs-events--assistant-stream-frame
         (current-buffer)
         '((type . "chunk") (revision . 1)
           (chunk . ((type . "text-delta") (text . "stale-gen")))))
        (dsh-emacs-render--flush-stream (current-buffer) t)
        (dsh-test-assert "follow-assistant-stream-drops-stale-revision"
          (= 2 dsh-emacs--assistant-stream-revision)
          (string-match-p "new-gen" (buffer-string))
          (not (string-match-p "stale-gen" (buffer-string)))))
    (when (buffer-live-p buf) (kill-buffer buf))))

;; --- Test 119c: the follow snapshot's assistantStream baseline continues an
;; in-progress stream ---
;; A reconnect that lands mid-attempt replays the accumulated process-local
;; stream in the opening snapshot, so the live body continues instead of
;; starting empty; the replay must not move the dedup anchor.
(let ((buf (generate-new-buffer " *dsh-stream-baseline*")))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (setq-local dsh-emacs--buffer-session "sess-frame")
        (dsh-emacs-events--follow-snapshot
         (current-buffer)
         '((type . "snapshot")
           (cursor . 42)
           (records . [])
           (assistantStream . ((revision . 3)
                               (activeAttempt . ((attemptId . "a1")
                                                 (startedAfterSeq . 40)
                                                 (turn . 2) (step . 1)
                                                 (nextIndex . 3)
                                                 (stream . [((type . "text-delta")
                                                             (text . "half-"))
                                                            ((type . "text-delta")
                                                             (text . "done"))])))))))
        (dsh-emacs-render--flush-stream (current-buffer) t)
        (dsh-test-assert "follow-snapshot-seeds-active-assistant-stream"
          (= dsh-emacs--assistant-stream-revision 3)
          (equal dsh-emacs--assistant-stream-position '(2 . 1))
          (string-match-p "half-done" (buffer-string))
          (= dsh-emacs--anchor-seq 42)
          ;; A frame from before the reconnect generation is stale.
          (progn
            (dsh-emacs-events--assistant-stream-frame
             (current-buffer)
             '((type . "chunk") (revision . 2)
               (chunk . ((type . "text-delta") (text . "stale")))))
            (not (string-match-p "stale" (buffer-string))))))
    (when (buffer-live-p buf) (kill-buffer buf))))

;; --- Test 119d: the follow open request declares assistantStream ---
;; Without the opt-in the host never sends the process-local frames, and a
;; reply would only appear once its durable `assistant/message' settles.
(let ((proc (start-process "dsh-test-followopen" (generate-new-buffer " *fo*")
                           "/bin/cat"))
      (sent nil))
  (unwind-protect
      (progn
        (accept-process-output proc 1)
        (when (process-live-p proc)
          (process-put proc 'dsh-emacs-follow-session "sess-open")
          (cl-letf (((symbol-function 'dsh-emacs-events--frame)
                     (lambda (_op payload) (setq sent payload) ""))
                    ((symbol-function 'dsh-emacs-events--chat)
                     (lambda (_p) nil)))
            (dsh-emacs-events--follow-open proc))
          (dsh-test-assert "follow-open-opts-into-assistant-stream"
            (and sent
                 (string-match-p "\"assistantStream\"" sent)
                 (string-match-p "\"session/follow\"" sent)
                 (string-match-p "\"sess-open\"" sent)))))
    (when (process-live-p proc) (delete-process proc))))

;; --- Test 120: session state comes from the running flag, do not invent an
;; interactive state from the wire ---
;; `projections.values.sessionStats.pendingInteraction' does not exist on the
;; session-list wire (never did in 0.1.2 either), so a session that waits on a
;; tool approval must NOT be reported as approval/pending from session data:
;; the only honest list state is running vs idle.
(let* ((with-bogus (dsh-protocol-session--from-alist
                    '((sessionId . "s-status")
                      (running . :json-false)
                      (projections . ((values . ((sessionStats . ((pendingInteraction . "approval"))))))))))
       (running (dsh-protocol-session--from-alist
                 '((sessionId . "s-status2") (running . t)))))
  (dsh-test-assert "session-status-ignores-absent-interaction-projection"
    (eq (dsh-emacs-session--compute-status with-bogus nil) 'idle)
    (eq (dsh-emacs-session--compute-status running t) 'running)
    ;; The lying accessor is gone entirely.
    (not (fboundp 'dsh-protocol-session-pending-interaction))))

;; --- Test 121: model-only surface replacement copies do not enter the human
;; record ---
;; A surface event is either `append' (entered the transcript at its own log
;; position) or `{op:"replace"}' (shadows an existing range so the MODEL sees
;; the newer copy). Replacements are the wrong source for a human transcript:
;; dsh compaction checkpoints are `user/message' copies already skipped by the
;; source-kind filter, but a pruned `tool/result' shares its `callId' with the
;; record it shadows and has no source filter, so without this check the same
;; tool card is painted twice.
(dsh-test-assert "render-replacement-predicate"
  (dsh-emacs-render--replacement-p
   '((type . "tool/result")
     (surfaceOp . ((op . "replace") (startSeq . 2) (endSeq . 2)))))
  (not (dsh-emacs-render--replacement-p
        '((type . "tool/result") (surfaceOp . "append"))))
  (not (dsh-emacs-render--replacement-p '((type . "tool/result")))))

(let ((buf (generate-new-buffer " *dsh-replacement*")))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (setq-local dsh-emacs-tool-expand-by-default t)
        (dsh-emacs-render-tool-call
         '(("type" . "tool/call") ("seq" . 1)
           ("data" . (("turn" . 1) ("step" . 1) ("callId" . "c-rep")
                      ("name" . "bash")
                      ("arguments" . "{\"command\":\"echo original\"}")))))
        (dsh-emacs-events--dispatch-event
         (current-buffer)
         (list (cons "type" "tool/result") (cons "seq" 2)
               (cons "surfaceOp" (list (cons "op" "replace")
                                       (cons "startSeq" 2) (cons "endSeq" 2)))
               (cons "data"
                     (list (cons "message"
                                 (list (cons "source" (list (cons "callId" "c-rep")))
                                       (cons "content"
                                             (vector (list (cons "type" "tool-result")
                                                           (cons "isError" :json-false)
                                                           (cons "exitCode" 0)
                                                           (cons "content"
                                                                 (vector (list (cons "type" "text")
                                                                               (cons "text" "PRUNED-COPY")))))))))))))
        (dsh-test-assert "render-skips-replacement-tool-result"
          ;; The human card keeps the record the user already saw...
          (not (string-search "PRUNED-COPY" (buffer-string)))
          (string-search "echo original" (buffer-string))
          ;; ...while the replacement still counts as consumed, so the dedup
          ;; anchor advances and a replay cannot re-render it.
          (= dsh-emacs--anchor-seq 2))
        ;; Control: an append-origin result on another call still paints.
        (dsh-emacs-render-tool-call
         '(("type" . "tool/call") ("seq" . 3)
           ("data" . (("turn" . 1) ("step" . 1) ("callId" . "c-app")
                      ("name" . "bash")
                      ("arguments" . "{\"command\":\"echo second\"}")))))
        (dsh-emacs-events--dispatch-event
         (current-buffer)
         (list (cons "type" "tool/result") (cons "seq" 4)
               (cons "surfaceOp" "append")
               (cons "data"
                     (list (cons "message"
                                 (list (cons "source" (list (cons "callId" "c-app")))
                                       (cons "content"
                                             (vector (list (cons "type" "tool-result")
                                                           (cons "isError" :json-false)
                                                           (cons "exitCode" 0)
                                                           (cons "content"
                                                                 (vector (list (cons "type" "text")
                                                                               (cons "text" "APPEND-COPY")))))))))))))
        (dsh-test-assert "render-keeps-append-tool-result"
          (string-search "APPEND-COPY" (buffer-string))
          (= dsh-emacs--anchor-seq 4)))
    (when (buffer-live-p buf) (kill-buffer buf))))

;; --- Test: load earlier history forward (session/page prepend) ---
;; Record the assistant body as markdown so render order can be asserted by
;; position:
;;   index: 1=USER-1 2=ASSIST-1 3=ASSIST-2 4=ASSIST-3 5=USER-2 6=ASSIST-4
;;   initial session window = seq 3~6 (anchor already at 6), the earlier page =
;; seq 1~2.
(defun dsh-test--history-fixture (type seq text)
  "One wire-shaped history record \"{type:event, event:{TYPE,SEQ …}}\".
TYPE is `user/message' or `assistant/message'; TEXT is its body."
  (list (cons "type" "event")
        (cons "event" (dsh-test--history-event type seq text))))

(defun dsh-test--history-event (type seq text)
  "One wire-shaped event of TYPE at SEQ carrying TEXT.
Content blocks are vectors, exactly as `json-read' decodes a JSON array."
  (let ((blocks (vector (list (cons "type" "text") (cons "text" text)))))
    (if (equal type "user/message")
        (list (cons "type" type) (cons "seq" seq)
              (cons "data" (list (cons "content" blocks))))
      (list (cons "type" type) (cons "seq" seq)
            (cons "data" (list (cons "message"
                                     (list (cons "content" blocks)))))))))

(defun dsh-test--history-text-pos (needle)
  "Position of NEEDLE in the current buffer, or nil."
  (save-excursion
    (goto-char (point-min))
    (when (search-forward needle nil t)
      (match-beginning 0))))

(defun dsh-test--history-event-record (type seq data)
  "One wire-shaped history record for TYPE at SEQ carrying DATA.
DATA is the raw `data' alist, for event types beyond user/assistant
messages (e.g. `command/done')."
  (list (cons "type" "event")
        (cons "event" (list (cons "type" type) (cons "seq" seq)
                            (cons "data" data)))))

;; 100: prepend inserts the earlier page above the old content and does not move
;; the anchor.
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (let ((newer (list (dsh-test--history-fixture "assistant/message" 3 "ASSIST-2")
                     (dsh-test--history-fixture "assistant/message" 4 "ASSIST-3")
                     (dsh-test--history-fixture "user/message" 5 "USER-2")
                     (dsh-test--history-fixture "assistant/message" 6 "ASSIST-4")))
        (older (list (dsh-test--history-fixture "user/message" 1 "USER-1")
                     (dsh-test--history-fixture "assistant/message" 2 "ASSIST-1"))))
    (dsh-emacs-render-history-events newer)
    (let ((marker (dsh-emacs-render--history-prepend-marker)))
      (setq dsh-emacs--history-insert-marker marker)
      (unwind-protect
          (dsh-emacs-render-history-events
           older nil 3 :insert-before (marker-position marker) :follow-p nil)
        (set-marker marker nil)
        (setq dsh-emacs--history-insert-marker nil))
      (let ((text (buffer-substring-no-properties (point-min) (point-max)))
            (p1 (dsh-test--history-text-pos "ASSIST-1"))
            (p3 (dsh-test--history-text-pos "ASSIST-2"))
            (p6 (dsh-test--history-text-pos "ASSIST-4")))
        (dsh-test-assert "history-prepend-orders-old-above-new"
          p1 p3 p6 (< p1 p3 p6)
          (string-match "USER-1" text)
          (< (dsh-test--history-text-pos "USER-1") p1)))
      (dsh-test-assert "history-prepend-keeps-live-anchor"
        (= dsh-emacs--anchor-seq 6)))))

;; 101: prepend does not render events above the cap (updates) in a batch.
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (let ((marker (progn (insert "HEADER\n")
                       (dsh-emacs-render-event
                        (dsh-test--history-event "user/message" 1 "NEWER"))
                       (copy-marker (point-min) nil))))
    (setq dsh-emacs--history-insert-marker marker)
    (unwind-protect
        (dsh-emacs-render-history-events
         (list (dsh-test--history-fixture "assistant/message" 0 "OLD")
               (dsh-test--history-fixture "assistant/message" 5 "BEYOND"))
         nil 5 :insert-before (marker-position marker) :follow-p nil)
      (set-marker marker nil)
      (setq dsh-emacs--history-insert-marker nil))
    (dsh-test-assert "history-prepend-respects-seq-cap"
      (string-match "OLD" (buffer-string))
      (not (string-match "BEYOND" (buffer-string))))))

;; 102: the prepend marker points above the oldest fragment (skipping the blank
;; line and welcome area above it).
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (insert "WELCOME\n")
  (dsh-emacs-render-event
   (dsh-test--history-event "assistant/message" 1 "FIRST-REPLY"))
  (let ((marker (dsh-emacs-render--history-prepend-marker)))
    (dsh-test-assert "history-prepend-marker-above-oldest"
      (markerp marker)
      (<= (marker-position marker) (dsh-test--history-text-pos "FIRST-REPLY")))
    (when (markerp marker) (set-marker marker nil))))

;; 103: the follow snapshot records the pagination frontier (oldest seq + hasMore).
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-modeline-setup)
  (dsh-emacs-render--note-history-window
   (list (dsh-test--history-fixture "user/message" 4 "A")
         (dsh-test--history-fixture "assistant/message" 5 "B"))
   :json-false)
  (dsh-test-assert "history-window-records-frontier"
    (= dsh-emacs--history-earliest-seq 4)
    (null dsh-emacs--history-has-more))
  (dsh-emacs-render--note-history-window
   (list (dsh-test--history-fixture "user/message" 1 "A")) t)
  (dsh-test-assert "history-window-records-has-more"
    (= dsh-emacs--history-earliest-seq 1)
    (eq dsh-emacs--history-has-more t))
  ;; A reconnect snapshot whose tail starts later must not move the cursor
  ;; past pages this buffer already loaded.
  (dsh-emacs-render--note-history-window
   (list (dsh-test--history-fixture "user/message" 9 "A")) t)
  (dsh-test-assert "history-window-frontier-only-moves-earlier"
    (= dsh-emacs--history-earliest-seq 1)))

;; 104: `dsh-emacs-load-older-history' pulls one page and prepends it, advancing
;; the cursor.
(let ((buf (generate-new-buffer " *dsh-history-load*")))
  (unwind-protect
      (progn
        (with-current-buffer buf
          (dsh-emacs-mode)
          (dsh-emacs-modeline-setup)
          (setq-local dsh-emacs--buffer-session "session-history")
          (dsh-emacs-render-history-events
           (list (dsh-test--history-fixture "assistant/message" 3 "ASSIST-2")
                 (dsh-test--history-fixture "user/message" 4 "USER-2")))
          (setq-local dsh-emacs--history-earliest-seq 3)
          (setq-local dsh-emacs--history-has-more t)
          ;; The follow snapshot's inclusive cursor; `throughSeq' must carry a
          ;; real seq (the wire's -1 reads an empty page on the server).
          (setq-local dsh-emacs--history-cursor 4))
        (let ((captured nil)
              (callback nil))
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (_method params cb)
                       (setq captured params callback cb))))
            (with-current-buffer buf
              (dsh-emacs-load-older-history)))
          (dsh-test-assert "load-older-history-request"
            captured
            (integerp (cdr (assq 'throughSeq
                                 (cdr (assq 'request captured)))))
            ;; Regression: the wire's -1 collapses the server's slice to an
            ;; empty page, so a real session cursor must be sent instead.
            (not (equal -1 (cdr (assq 'throughSeq
                                      (cdr (assq 'request captured))))))
            (equal 4 (cdr (assq 'throughSeq
                                (cdr (assq 'request captured))))))
          (dsh-test-assert "load-older-history-params"
            (equal "session-history"
                   (cdr (assq 'sessionId
                              (cdr (assq 'address
                                         (cdr (assq 'request captured)))))))
            (= 3 (cdr (assq 'beforeSeq (cdr (assq 'request captured)))))
            (= dsh-emacs-history-window
               (cdr (assq 'maxMessages (cdr (assq 'request captured))))))
          (funcall callback t
                   (list (cons "records"
                               (vector
                                (dsh-test--history-fixture "user/message" 1 "USER-1")
                                (dsh-test--history-fixture
                                 "assistant/message" 2 "ASSIST-1")))
                         (cons "hasMore" :json-false)))
          (with-current-buffer buf
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (dsh-test-assert "load-older-history-prepends"
                (string-match "ASSIST-1" text)
                (string-match "USER-1" text)
                (< (dsh-test--history-text-pos "USER-1")
                   (dsh-test--history-text-pos "ASSIST-1")
                   (dsh-test--history-text-pos "ASSIST-2"))))
            (dsh-test-assert "load-older-history-advances-cursor"
              (= dsh-emacs--history-earliest-seq 1)
              (null dsh-emacs--history-has-more)
              (null dsh-emacs--history-loading)))))
    (when (buffer-live-p buf) (kill-buffer buf))))

;; 105: no request is sent when hasMore=nil.
(let ((buf (generate-new-buffer " *dsh-history-nomore*")))
  (unwind-protect
      (progn
        (with-current-buffer buf
          (dsh-emacs-mode)
          (dsh-emacs-modeline-setup)
          (setq-local dsh-emacs--buffer-session "session-history")
          (setq-local dsh-emacs--history-earliest-seq 1)
          (setq-local dsh-emacs--history-has-more nil))
        (let ((called nil))
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (&rest _) (setq called t))))
            (with-current-buffer buf
              (dsh-emacs-load-older-history)))
          (dsh-test-assert "load-older-history-stops-at-start" (null called))))
    (when (buffer-live-p buf) (kill-buffer buf))))

;; 106: calling it outside a chat buffer is a user-error.
(let ((other (generate-new-buffer " *dsh-nonchat*")))
  (unwind-protect
      (with-current-buffer other
        (dsh-test-assert "load-older-history-requires-chat"
          (condition-case nil
              (progn (dsh-emacs-load-older-history) nil)
            (user-error t))))
    (when (buffer-live-p other) (kill-buffer other))))

;; Older pages use real stateful renderers, but cannot change the live turn.
(dolist (busy '(nil t))
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-modeline-setup)
    (setq-local dsh-emacs--buffer-session "history-isolation")
    (dsh-emacs-render-history-events
     (list (dsh-test--history-fixture "assistant/message" 20 "RECENT")))
    (setq dsh-emacs--history-earliest-seq 20
          dsh-emacs--modeline-model "current-model"
          dsh-emacs--modeline-step '(7 8)
          dsh-emacs--turn-awaiting t
          dsh-emacs--todo-list '(("Current plan" . "pending")))
    (dsh-emacs--ml-busy-set busy)
    (let* ((step dsh-emacs--modeline-step)
           (todo dsh-emacs--todo-list)
           (notifications 0)
           (stream (dsh-emacs-render--start-assistant-stream
                    '((data . ((turn . 7) (step . 8)))) "LIVE-BODY"))
           (start (marker-position (plist-get stream :start)))
           (timer (progn
                    (dsh-emacs-render--start-assistant-stream
                     '((data . ((turn . 7) (step . 8)))) "-PENDING")
                    (plist-get stream :timer)))
           (page (json-read-from-string
                  "{\"hasMore\":false,\"records\":[
{\"type\":\"event\",\"event\":{\"type\":\"turn/start\",\"seq\":1,\"data\":{\"turn\":1}}},
{\"type\":\"event\",\"event\":{\"type\":\"request/context\",\"seq\":2,\"data\":{\"model\":\"old-model\"}}},
{\"type\":\"event\",\"event\":{\"type\":\"step/start\",\"seq\":3,\"data\":{\"turn\":1,\"step\":1}}},
{\"type\":\"event\",\"event\":{\"type\":\"tool/call\",\"seq\":4,\"data\":{\"callId\":\"old-call\",\"name\":\"bash\",\"arguments\":\"{\\\"command\\\":\\\"echo history\\\"}\"}}},
{\"type\":\"event\",\"event\":{\"type\":\"tool/result\",\"seq\":5,\"data\":{\"message\":{\"callId\":\"old-call\",\"content\":[{\"type\":\"tool-result\",\"exitCode\":0,\"content\":[{\"type\":\"text\",\"text\":\"HISTORICAL-OUTPUT\"}]}]}}}},
{\"type\":\"event\",\"event\":{\"type\":\"tool/call\",\"seq\":6,\"data\":{\"callId\":\"old-todo\",\"name\":\"todo_write\",\"arguments\":\"{\\\"todos\\\":[{\\\"content\\\":\\\"Old plan\\\",\\\"status\\\":\\\"completed\\\"}]}\"}}},
{\"type\":\"event\",\"event\":{\"type\":\"turn/end\",\"seq\":7,\"data\":{\"turn\":1,\"reason\":{\"kind\":\"completed\"}}}}]}")))
      (cl-letf (((symbol-function 'dsh-emacs-notify--post)
                 (lambda (&rest _) (cl-incf notifications))))
        (dsh-emacs--load-older-history-page (current-buffer) page))
      (dsh-test-assert (format "history-page-settles-tools-%s" busy)
        (eq 'success (plist-get (dsh-emacs-render--tool-state "old-call")
                                :state))
        (let* ((block (dsh-emacs-ui-find-block
                       (dsh-emacs-render--make-namespace) "tool-old-call"))
               (state (and block (get-text-property
                                  (car block) 'dsh-emacs-ui-state))))
          (and state (string-match-p "HISTORICAL-OUTPUT"
                                     (map-elt state :body)))))
      (dsh-test-assert (format "history-page-preserves-live-state-%s" busy)
        (eq dsh-emacs--ml-busy busy)
        (equal dsh-emacs--modeline-model "current-model")
        (equal dsh-emacs--modeline-step step)
        (equal dsh-emacs--todo-list todo)
        dsh-emacs--turn-awaiting
        (= notifications 0)
        (= dsh-emacs--anchor-seq 20))
      (dsh-test-assert (format "history-page-preserves-live-stream-%s" busy)
        (eq dsh-emacs--streaming-assistant stream)
        (eq (plist-get stream :timer) timer)
        (memq timer timer-list)
        (equal (plist-get stream :pending) '("-PENDING"))
        (marker-buffer (plist-get stream :start))
        (> (marker-position (plist-get stream :start)) start)
        (equal "LIVE-BODY" (buffer-substring-no-properties
                            (plist-get stream :start)
                            (plist-get stream :end))))
      (dsh-emacs--ml-busy-clear))))

;; The in-render "this is a settled page" flag decides page-vs-live on its
;; own, independent of whether an insertion marker could be computed.
(dsh-test-assert "history-page-predicate-unset"
  (not (dsh-emacs-render--history-page-p)))
(with-temp-buffer
  (dsh-emacs-mode)
  (let ((dsh-emacs--history-page t))
    (dsh-test-assert "history-page-predicate-set"
      (dsh-emacs-render--history-page-p)))
  (dsh-test-assert "history-page-predicate-cleared"
    (not (dsh-emacs-render--history-page-p)))
  ;; A marker alone no longer means "page": it is positioning state only.
  (let ((marker (copy-marker (point-min) t)))
    (setq dsh-emacs--history-insert-marker marker)
    (dsh-test-assert "history-page-predicate-ignores-marker"
      (not (dsh-emacs-render--history-page-p)))
    (set-marker marker nil)
    (setq dsh-emacs--history-insert-marker nil)))

;; A page renders settled text synchronously and never joins the live idle
;; Markdown queue (whose jobs format the streaming tail).
(let ((dsh-emacs-stream-markdown-limit 40))
  (with-temp-buffer
    (dsh-emacs-mode)
    (setq-local dsh-emacs--buffer-session "history-markdown")
    (setq-local dsh-emacs--history-earliest-seq 5)
    (let ((body (concat "**bold** word " (make-string 120 ?x))))
      (dsh-emacs--load-older-history-page
       (current-buffer)
       (list (cons "hasMore" :json-false)
             (cons "records"
                   (vector (dsh-test--history-event-record
                            "assistant/message" 4
                            (list (cons "message"
                                        (list (cons "content"
                                                    (vector
                                                     (list (cons "type" "text")
                                                           (cons "text" body))))))))))))
      (dsh-test-assert "history-page-renders-markdown-synchronously"
        (null dsh-emacs--markdown-pending)
        (null dsh-emacs--markdown-timer)
        (string-match-p "bold" (buffer-string))
        (let ((face (get-text-property
                     (1+ (dsh-test--history-text-pos "bold")) 'face)))
          (memq 'dsh-emacs-markdown-bold
                (if (listp face) face (list face))))))))

;; Control: the same body on the live path still defers, so the page gate
;; narrows the idle queue instead of disabling it.
(let ((dsh-emacs-stream-markdown-limit 40))
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-render-history-events
     (list (dsh-test--history-event-record
            "assistant/message" 4
            (list (cons "message"
                        (list (cons "content"
                                    (vector (list (cons "type" "text")
                                                  (cons "text"
                                                        (concat "**b** "
                                                                (make-string 100 ?x))))))))))))
    (dsh-test-assert "live-path-still-defers-markdown"
      dsh-emacs--markdown-pending
      dsh-emacs--markdown-timer)
    (dsh-emacs-render--cancel-markdown)))

;; A page stops no spinner and leaves the optimistic pending-command alone.
(with-temp-buffer
  (dsh-emacs-mode)
  (setq-local dsh-emacs--buffer-session "history-command")
  (setq-local dsh-emacs--history-earliest-seq 5)
  (let* ((block-id "cmd-old-cmd")
         (ns (dsh-emacs-render--make-namespace))
         (stopped nil)
         (pending '(("cmd-temp-local" "compile"))))
    (puthash "old-cmd" (list ns block-id "compile" nil)
             dsh-emacs--command-blocks)
    (setq dsh-emacs--pending-command pending)
    (cl-letf (((symbol-function 'dsh-emacs--command-spinner-stop)
               (lambda (&rest _) (setq stopped t))))
      (dsh-emacs--load-older-history-page
       (current-buffer)
       (list (cons "hasMore" :json-false)
             (cons "records"
                   (vector
                    (dsh-test--history-event-record
                     "command/done" 4
                     '((commandId . "old-cmd")
                       (name . "compile")
                       (kind . "success")
                       (text . "COMPILE-DONE"))))))))
    (dsh-test-assert "history-page-command-not-animated"
      (not stopped)
      (equal dsh-emacs--pending-command pending)
      ;; The done row still renders (its body stays collapsed, so assert the
      ;; header, which is what is normally visible).
      (string-match-p "compile" (buffer-string))
      (string-match-p "✓ done" (buffer-string)))))

;; Backfill keeps newest-first recall, including when the list is full.
(dolist (limit '(3 5))
  (let ((dsh-emacs-input-history-length limit)
        (dsh-emacs--input-history-by-session (make-hash-table :test 'equal)))
    (with-temp-buffer
      (dsh-emacs-mode)
      (setq-local dsh-emacs--buffer-session "history-recall")
      (dsh-emacs-render-history-events
       (list (dsh-test--history-fixture "user/message" 20 "LATEST")))
      (setq dsh-emacs--history-earliest-seq 20)
      (puthash "history-recall" '("LATEST" "RECENT")
               dsh-emacs--input-history-by-session)
      (dsh-emacs--load-older-history-page
       (current-buffer)
       (list (cons "hasMore" :json-false)
             (cons "records"
                   (vector (dsh-test--history-fixture "user/message" 1 "ANCIENT")
                           (dsh-test--history-fixture "user/message" 2 "RECENT")
                           (dsh-test--history-fixture "user/message" 3 "OLDER")))))
      (dsh-test-assert (format "history-page-keeps-recall-order-limit-%s" limit)
        (equal (gethash "history-recall" dsh-emacs--input-history-by-session)
               (if (= limit 3)
                   '("LATEST" "RECENT" "OLDER")
                 '("LATEST" "RECENT" "OLDER" "ANCIENT")))))))

;; Repeated pages retain a reading window and draft, even after header trim.
(save-window-excursion
  (with-temp-buffer
    (dsh-emacs-mode)
    (setq-local dsh-emacs--buffer-session "history-window")
    (dsh-emacs-render-history-events
     (list (dsh-test--history-fixture "user/message" 10 "TAIL-USER")
           (dsh-test--history-fixture "assistant/message" 11 "TAIL-REPLY")))
    (setq dsh-emacs--history-earliest-seq 10)
    (let ((inhibit-read-only t))
      (delete-region (point-min)
                     (text-property-any (point-min) (point-max)
                                        'dsh-emacs-transcript-block t)))
    (goto-char dsh-emacs--input-marker)
    (insert "DRAFT")
    (switch-to-buffer (current-buffer))
    (let ((draft-point (copy-marker (point) t))
          (reading-point (copy-marker (dsh-test--history-text-pos "TAIL-REPLY") t)))
      (set-window-start (selected-window) reading-point t)
      (dolist (seq '(5 1))
        (dsh-emacs--load-older-history-page
         (current-buffer)
         (list (cons "hasMore" t)
               (cons "records"
                     (vector (dsh-test--history-fixture
                              "user/message" seq (format "PAGE-%d" seq)))))))
      (dsh-test-assert "history-pages-preserve-window-and-draft"
        (= (point) draft-point)
        (= (window-start) reading-point)
        (equal (buffer-substring-no-properties dsh-emacs--input-marker
                                               (point-max)) "DRAFT")
        (< (dsh-test--history-text-pos "PAGE-1")
           (dsh-test--history-text-pos "PAGE-5")
           (dsh-test--history-text-pos "TAIL-USER")
           (dsh-test--history-text-pos "TAIL-REPLY")))
      (set-marker draft-point nil)
      (set-marker reading-point nil))))

(princ "\n===== test summary =====\n")
(let ((pass (cl-count-if (lambda (r) (cdr r)) dsh-test-results))
      (fail (cl-count-if (lambda (r) (not (cdr r))) dsh-test-results)))
  (princ (format "%d passed, %d failed\n" pass fail))
  (when (> fail 0)
    (princ "failed tests:\n")
    ;; `reverse' (copy) rather than `nreverse' (in-place reversal): nreverse rewrites
    ;; the cdr structure of dsh-test-results in place, and after the print loop that
    ;; variable holds only the last cons before reversal (a one-element list), so the
    ;; exit-code check below can never see the failed items — a red test would sneak
    ;; past the verify.sh suite step with exit 0.
    (dolist (r (reverse dsh-test-results))
      (unless (cdr r)
        (princ (format "  - %s: %s\n" (car r) (cdr r)))))))
(when (and noninteractive
           (cl-some (lambda (r) (not (cdr r))) dsh-test-results))
  (kill-emacs 1))
