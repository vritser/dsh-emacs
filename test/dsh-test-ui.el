;;; dsh-test-ui.el --- Ui tests -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "28.1"))

(require 'dsh-test-support)

(ert-deftest dsh-emacs-test-ui-navigation-records-only-successful-moves ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (insert "abcdef")
    (goto-char 2)
    (let (recorded)
      (cl-letf (((symbol-function 'xref-push-marker-stack)
                 (lambda (marker) (push marker recorded))))
        (should (eq (dsh-emacs-ui-navigate (point-marker) #'identity 'unchanged)
                    'unchanged))
        (should-not recorded)
        (should-error (dsh-emacs-ui-navigate (point-marker) #'error "Failed"))
        (should-not recorded)
        (should (eq (condition-case nil
                        (dsh-emacs-ui-navigate
                         (point-marker) (lambda () (signal 'quit nil)))
                      (quit 'cancelled))
                    'cancelled))
        (should-not recorded)
        (should (= (dsh-emacs-ui-navigate (point-marker) #'goto-char 5) 5))
        (should (= (length recorded) 1))
        (should (= (car recorded) 2))
        (should (eq (marker-buffer (car recorded)) (current-buffer))))
      (dolist (marker recorded) (set-marker marker nil)))))

(ert-deftest dsh-emacs-test-ui-navigation-file-and-session-return ()
  :tags '(dsh-unit)
  (pcase-let ((`(,status . ,output)
               (dsh-test--fresh-process
                '(progn
                   (require 'ert)
                   (require 'dsh-emacs)
                   (let* ((file (make-temp-file "dsh-xref-" nil ".txt"
                                                "first line\nsecond line\n"))
                          (origin (generate-new-buffer " *xref-origin*"))
                          (target (generate-new-buffer " *xref-session*"))
                          (dsh-emacs--chat-buffers (make-hash-table :test #'equal))
                          (dsh-emacs--current-session "origin")
                          (dsh-emacs--current-buffer origin)
                          (dsh-emacs--sessions
                           (list (dsh-protocol-session--from-alist
                                  `((sessionId . "origin")
                                    (cwd . ,(file-name-directory file)))))))
                     (unwind-protect
                         (progn
                           (switch-to-buffer origin)
                           (insert "source position")
                           (goto-char 4)
                           (dsh-emacs-reference--open-ref 'file file)
                           (should (equal buffer-file-name file))
                           (call-interactively (key-binding (kbd "M-,")))
                           (should (eq (current-buffer) origin))
                           (should (= (point) 4))
                           ;; A local link into the same file still records
                           ;; the departure before applying its line/column.
                           (find-file file)
                           (goto-char 3)
                           (dsh-emacs-markdown--open-local-link
                            (concat file "#L2C3"))
                           (should (= (line-number-at-pos) 2))
                           (should (= (current-column) 2))
                           (call-interactively (key-binding (kbd "M-,")))
                           (should (equal buffer-file-name file))
                           (should (= (point) 3))
                           (switch-to-buffer origin)
                           (goto-char 6)
                           (puthash "target" target dsh-emacs--chat-buffers)
                           (dsh-emacs-reference--open-ref 'session "target")
                           (should (eq (current-buffer) target))
                           (call-interactively (key-binding (kbd "M-,")))
                           (should (eq (current-buffer) origin))
                           (should (= (point) 6)))
                       (when-let* ((buffer (get-file-buffer file)))
                         (kill-buffer buffer))
                       (kill-buffer origin)
                       (kill-buffer target)
                       (delete-file file)))))))
    (ert-info (output)
      (should (equal status 0)))))

(ert-deftest dsh-emacs-test-ui-navigation-child-records-once ()
  :tags '(dsh-unit)
  (let* ((origin (generate-new-buffer " *xref-parent*"))
         (child nil)
         (dsh-emacs--chat-buffers (make-hash-table :test #'equal))
         (dsh-emacs--subagent-catalogs (make-hash-table :test #'equal))
         (dsh-emacs--sessions nil)
         (dsh-emacs--current-buffer nil)
         (dsh-emacs--current-session nil)
         (entry (dsh-protocol-subagent-entry--from-alist
                 '((id . "child") (mode . "one-shot"))))
         departures)
    (save-window-excursion
      (unwind-protect
          (cl-letf (((symbol-function 'xref-push-marker-stack)
                     (lambda (marker) (push marker departures)))
                    ((symbol-function 'dsh-emacs-subagent--refresh-summaries) #'ignore)
                    ((symbol-function 'dsh-emacs--activate-chat-buffer)
                     (lambda (id buffer &optional address)
                       (puthash id buffer dsh-emacs--chat-buffers)
                       (with-current-buffer buffer
                         (dsh-emacs-mode)
                         (setq dsh-emacs--buffer-session id
                               dsh-emacs--buffer-subagent address))))
                    ((symbol-function 'dsh-emacs-server-ensure) #'ignore)
                    ((symbol-function 'dsh-emacs--chat-buffer-name)
                     (lambda (_id) " *xref-child*")))
            (switch-to-buffer origin)
            (insert "parent source")
            (goto-char 4)
            (puthash "parent" origin dsh-emacs--chat-buffers)
            ;; Cold children record only when their follow snapshot succeeds.
            (dsh-emacs-open-subagent "parent" entry)
            (setq child dsh-emacs--current-buffer)
            (should-not departures)
            (should (marker-buffer dsh-emacs--subagent-departure))
            (dsh-emacs-events--follow-snapshot
             child '((cursor . 0) (records . []) (hasMore . :json-false)))
            (should (= (length departures) 1))
            (should (eq (marker-buffer (car departures)) origin))
            (should (= (car departures) 4))
            (should-not dsh-emacs--subagent-departure)
            ;; Returning to the root uses the same session navigation owner.
            (dsh-emacs-subagent-open-parent)
            (should (eq (current-buffer) origin))
            (should (= (length departures) 2))
            ;; Reopening the live child has no new snapshot to wait for.
            (dsh-emacs-open-subagent "parent" entry)
            (should (eq (current-buffer) child))
            (should (= (length departures) 3))
            (should-not dsh-emacs--subagent-departure)
            (dsh-emacs-open-subagent "parent" entry)
            (should (= (length departures) 3)))
        (dolist (marker departures) (set-marker marker nil))
        (kill-buffer origin)
        (when (buffer-live-p child) (kill-buffer child))))))

(ert-deftest dsh-emacs-test-ui-navigation-image-keeps-asynchronous-origin ()
  :tags '(dsh-unit)
  (let ((origin (generate-new-buffer " *xref-image-source*"))
        (other (generate-new-buffer " *xref-unrelated*"))
        (dsh-emacs--current-session "image-session")
        callback departure image)
    (save-window-excursion
      (unwind-protect
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (_method _args done) (setq callback done)))
                    ((symbol-function 'image-mode) #'ignore)
                    ((symbol-function 'xref-push-marker-stack)
                     (lambda (marker) (setq departure marker))))
            (switch-to-buffer origin)
            (insert "image")
            (put-text-property
             1 6 'dsh-emacs-attachment
             '((attachmentId . "attachment") (mediaType . "image/png")
               (bytes . 3) (width . 1) (height . 1)))
            (goto-char 3)
            (dsh-emacs-render--image-open)
            (should-not departure)
            (should (functionp callback))
            (switch-to-buffer other)
            (funcall callback t '((data . "YWJj")))
            (setq image (current-buffer))
            (should (equal (buffer-string) "abc"))
            (should (eq (marker-buffer departure) origin))
            (should (= departure 3)))
        (when departure (set-marker departure nil))
        (kill-buffer origin)
        (kill-buffer other)
        (when (buffer-live-p image) (kill-buffer image))))))

;; Follow checks must stop after one screen plus slack, even in long history.
(ert-deftest dsh-emacs-test-ui-follow-threshold-keeps-boundary ()
  :tags '(dsh-unit)
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
        (ert-info ((format "%s" "follow-threshold-keeps-boundary"))
          (should (dsh-emacs-ui--window-at-bottom-p window 16))
          (should (not (dsh-emacs-ui--window-at-bottom-p window 17))))
        (ert-info ((format "%s" "follow-long-history-is-not-at-bottom"))
          (should (not (dsh-emacs-ui--window-at-bottom-p window (point-max)))))
        (cl-letf (((symbol-function 'get-buffer-window-list)
                   (lambda (&rest _) (list window)))
                  ((symbol-function 'set-window-start) #'ignore))
          (dsh-emacs-ui-update-fragment
           (dsh-emacs-ui-make-fragment :label-left "New" :style 'minimal)
           :create-new t))
        (ert-info ((format "%s" "follow-checks-do-not-count-entire-history"))
          (should (< counted 100)))))))

;; Default character rows can overestimate capacity with line spacing/fonts.
(ert-deftest dsh-emacs-test-ui-follow-keeps-empty-input-visible ()
  :tags '(dsh-unit)
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
              (ert-info ((format "%s" (if (string-empty-p draft) "follow-keeps-empty-input-visible"
                                        "follow-keeps-multiline-draft-visible")))
                (should (= (point) draft-point))
                (should (save-excursion
                          (goto-char (window-start window))
                          (vertical-motion (window-body-height window) window)
                          (>= (point) draft-point)))
                (should (= (window-start window) start))))))))))

;; Wrapped transcript lines count as screen rows for following and pinning.
(ert-deftest dsh-emacs-test-ui-follow-wrapped-history-is-not-at-bottom ()
  :tags '(dsh-unit)
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
          (ert-info ((format "%s" "follow-wrapped-history-is-not-at-bottom"))
            (should (not (dsh-emacs-ui--window-at-bottom-p window anchor))))
          (dsh-emacs-render--follow-stream)
          (ert-info ((format "%s" "follow-preserves-scrolled-wrapped-window"))
            (should (= (window-start window) (point-min))))
          (goto-char anchor)
          (vertical-motion (- (1- (window-text-height window))) window)
          (let ((expected (point)))
            (set-window-start window expected)
            (goto-char (point-max))
            (let ((draft-point (point)))
              (dsh-emacs-render--follow-stream)
              (ert-info ((format "%s" "follow-pins-by-screen-rows-without-moving-draft"))
                (should (= (window-start window) expected))
                (should (> expected (point-min)))
                (should (= (point) draft-point))))))))))

;; Reading the transcript rules out following before any screen-row scan.
(ert-deftest dsh-emacs-test-ui-follow-history-reader-skips-screen-row-scans ()
  :tags '(dsh-unit)
  (save-window-excursion
    (with-temp-buffer
      (dsh-emacs-mode)
      (set-window-buffer (selected-window) (current-buffer))
      (dsh-emacs-render--start-assistant-stream
       '((data . ((turn . 1) (step . 1)))) "visible history\n")
      (goto-char (point-min))
      (let ((scans 0))
        (cl-letf (((symbol-function 'dsh-emacs-ui--window-at-bottom-p)
                   (lambda (&rest _) (cl-incf scans) t)))
          (dsh-emacs-render--follow-stream))
        (ert-info ((format "%s" "follow-history-reader-skips-screen-row-scans"))
          (should (zerop scans))
          (should (= (point) (point-min))))))))

;; Large stream writes retain the windows following before the edit.
(ert-deftest dsh-emacs-test-ui-stream-large-case-retains-follow ()
  :tags '(dsh-unit)
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
            (ert-info ((format "%s" (format "stream-large-%s-retains-follow" kind)))
              (should (= (window-start window)
                         (save-excursion
                           (goto-char (dsh-emacs-render--input-anchor-pos))
                           (vertical-motion (- (1- (window-text-height window))) window)
                           (point))))
              (should (> (window-start window) 1))
              (should (= (- (point) dsh-emacs--input-marker) draft-offset))
              (should (equal (dsh-emacs--get-input) "draft"))))
          (dsh-emacs-render--flush-stream nil t))))))

(defun dsh-test--stream-draft-windows (kind separate-buffers long-draft)
  "Check KIND bursts with independent drafts and a history reader.
SEPARATE-BUFFERS gives the second follower its own chat; LONG-DRAFT puts
both followers' prompts above their viewports."
  (save-window-excursion
    (let* ((chat-a (generate-new-buffer " *dsh-draft-a*"))
           (chat-b (if separate-buffers
                       (generate-new-buffer " *dsh-draft-b*")
                     chat-a))
           (buffers (delete-dups (list chat-a chat-b)))
           (selected (selected-window))
           (other (split-window-right))
           (reader (split-window selected nil 'below))
           (event '((data . ((turn . 1) (step . 1)))))
           (start (if (eq kind 'thinking)
                      #'dsh-emacs-render--start-thinking-stream
                    #'dsh-emacs-render--start-assistant-stream))
           (draft (concat (apply #'concat
                                 (make-list (if long-draft 80 3) "draft row\n"))
                          "draft tail"))
           (views (list (cons selected (- (length draft) 3))
                        (cons other (- (length draft) 17)))))
      (unwind-protect
          (progn
            (dolist (buffer buffers)
              (with-current-buffer buffer
                (dsh-emacs-mode)
                (let ((inhibit-read-only t))
                  (goto-char (point-min))
                  (insert (apply #'concat (make-list 100 "history row\n"))))
                (goto-char dsh-emacs--input-marker)
                (insert draft)
                (funcall start event "intro\n")))
            (set-window-buffer selected chat-a)
            (set-window-buffer other chat-b)
            (set-window-buffer reader chat-a)
            (set-window-start reader 1)
            (set-window-point reader 10)
            (dolist (view views)
              (with-selected-window (car view)
                (goto-char (+ dsh-emacs--input-marker (cdr view)))
                (recenter -1)
                (when long-draft
                  (should (< (dsh-emacs-render--input-anchor-pos)
                             (window-start))))))
            (dolist (buffer buffers)
              (with-current-buffer buffer
                (let ((expected (if separate-buffers
                                    (list (if (eq buffer chat-a) selected other))
                                  (list selected other)))
                      (followers (dsh-emacs-render--following-windows)))
                  (should (= (length followers) (length expected)))
                  (dolist (window expected)
                    (should (memq window followers))))))
            (dotimes (_ 2)
              (let ((starts (mapcar (lambda (view)
                                     (window-start (car view)))
                                   views)))
                (dolist (buffer buffers)
                  (with-current-buffer buffer
                    (funcall start event
                             (apply #'concat (make-list 100 "burst row\n")))
                    (dsh-emacs-render--flush-stream)))
                (should (eq (selected-window) selected))
                (should (= (window-start reader) 1))
                (should (= (window-point reader) 10))
                (cl-loop for (window . offset) in views
                         for old-start in starts
                         do (with-current-buffer (window-buffer window)
                              (should (= (- (window-point window)
                                            dsh-emacs--input-marker)
                                         offset))
                              (should (> (window-start window) old-start))
                              (should (= (window-start window)
                                         (save-excursion
                                           (goto-char (window-point window))
                                           (vertical-motion
                                            (- (1- (window-text-height window)))
                                            window)
                                           (point))))
                              (should (equal (dsh-emacs--get-input) draft)))))))
        (dolist (buffer buffers)
          (when (buffer-live-p buffer)
            (with-current-buffer buffer
              (dsh-emacs-render--flush-stream nil t))
            (kill-buffer buffer)))))))

(ert-deftest dsh-emacs-test-ui-stream-preserves-every-window-draft-point ()
  :tags '(dsh-unit)
  (dolist (kind '(assistant thinking))
    (dolist (separate-buffers '(nil t))
      (ert-info ((format "%s separate-buffers=%s" kind separate-buffers))
        (dsh-test--stream-draft-windows kind separate-buffers nil)))))

(ert-deftest dsh-emacs-test-ui-stream-follows-drafts-below-hidden-prompt ()
  :tags '(dsh-unit)
  (dolist (kind '(assistant thinking))
    (dolist (separate-buffers '(nil t))
      (ert-info ((format "%s separate-buffers=%s" kind separate-buffers))
        (dsh-test--stream-draft-windows kind separate-buffers t)))))

(ert-deftest dsh-emacs-test-ui-stream-keeps-unselected-empty-input-following ()
  :tags '(dsh-unit)
  (dolist (kind '(assistant thinking))
    (dolist (at-prompt '(t nil))
      (ert-info ((format "%s at-prompt=%s" kind at-prompt))
        (save-window-excursion
          (with-temp-buffer
            (dsh-emacs-mode)
            (let* ((selected (selected-window))
                   (other (split-window-right))
                   (event '((data . ((turn . 1) (step . 1)))))
                   (start (if (eq kind 'thinking)
                              #'dsh-emacs-render--start-thinking-stream
                            #'dsh-emacs-render--start-assistant-stream))
                   (offset (if at-prompt -2 0)))
              (set-window-buffer selected (current-buffer))
              (set-window-buffer other (current-buffer))
              (goto-char dsh-emacs--input-marker)
              (set-window-point other (+ dsh-emacs--input-marker offset))
              (dotimes (_ 2)
                (funcall start event
                         (apply #'concat (make-list 100 "burst row\n")))
                (dsh-emacs-render--flush-stream)
                (should (eq (selected-window) selected))
                (should (= (window-point selected) dsh-emacs--input-marker))
                (should (= (- (window-point other) dsh-emacs--input-marker)
                           offset))
                (should (= (length (dsh-emacs-render--following-windows)) 2)))
              (dsh-emacs-render--flush-stream nil t))))))))

;; A user scroll while a timer is pending wins over the queued output.
(ert-deftest dsh-emacs-test-ui-stream-case-flush-respects-new-scroll ()
  :tags '(dsh-unit)
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
          (ert-info ((format "%s" (format "stream-%s-flush-respects-new-scroll" kind)))
            (should (= (window-start window) 1))
            (should (= (point) 5)))
          (dsh-emacs-render--flush-stream nil t))))))

;; Following must not move the cursor in an unselected history reader.
(ert-deftest dsh-emacs-test-ui-follow-preserves-unselected-history-cursor ()
  :tags '(dsh-unit)
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
        (ert-info ((format "%s" "follow-preserves-unselected-history-cursor"))
          (should (= (window-start reader) 1))
          (should (= (window-point reader) 10)))))))

;; Fragment updates keep every reader's window start on the same text.
(defun dsh-test--viewport-card (lines)
  "Return a fragment snapshot for the viewport tests with LINES body lines."
  (dsh-emacs-ui-make-fragment
   :namespace-id "viewport" :block-id "card" :label-left "Card"
   :style 'minimal :non-foldable t
   :body (mapconcat (lambda (i) (format "card line %d" i))
                    (number-sequence 1 lines) "\n")))

(defun dsh-test--window-start-line (window)
  "Return the text of the line WINDOW starts with, and whether it is whole."
  (save-excursion
    (goto-char (window-start window))
    (list (buffer-substring-no-properties (point) (line-end-position))
          (bolp))))

(ert-deftest dsh-emacs-test-ui-fragment-growth-above-keeps-every-window-start ()
  :tags '(dsh-unit)
  (save-window-excursion
    (with-temp-buffer
      (let ((top (selected-window))
            (inhibit-read-only t))
        (dsh-emacs-ui-update-fragment (dsh-test--viewport-card 10) :expanded t)
        (goto-char (point-max))
        (dotimes (i 300) (insert (format "filler %d\n" i)))
        (set-window-buffer top (current-buffer))
        (let ((other (split-window top)))
          (set-window-buffer other (current-buffer))
          (dolist (view `((,top . "filler 40") (,other . "filler 120")))
            (goto-char (point-min))
            (search-forward (concat (cdr view) "\n"))
            (set-window-start (car view) (line-beginning-position 0)))
          (dsh-emacs-ui-update-fragment (dsh-test--viewport-card 15))
          (ert-info ((format "%s" "fragment-growth-above-keeps-every-window-start"))
            (should (equal (dsh-test--window-start-line top) '("filler 40" t)))
            (should (equal (dsh-test--window-start-line other) '("filler 120" t))))
          (dsh-emacs-ui-update-fragment (dsh-test--viewport-card 3))
          (ert-info ((format "%s" "fragment-shrink-above-keeps-every-window-start"))
            (should (equal (dsh-test--window-start-line top) '("filler 40" t)))
            (should (equal (dsh-test--window-start-line other) '("filler 120" t))))
          ;; A start inside the replaced span collapses to the edit's first
          ;; difference (mid-line here); it must land on a whole card line.
          (goto-char (point-min))
          (search-forward "card line 2\n")
          (set-window-start top (line-beginning-position 0))
          (dsh-emacs-ui-update-fragment
           (dsh-emacs-ui-make-fragment
            :namespace-id "viewport" :block-id "card" :label-left "Card"
            :style 'minimal :non-foldable t
            :body "card line 1 x\nchanged 2\ncard line 3 x"))
          (ert-info ((format "%s" "fragment-replaced-window-start-stays-on-line-start"))
            (should (equal (dsh-test--window-start-line top) '("card line 1 x" t)))))))))

;; Updates that write nothing must not measure any window.
(ert-deftest dsh-emacs-test-ui-fragment-unchanged-update-skips-viewport-work ()
  :tags '(dsh-unit)
  (save-window-excursion
    (with-temp-buffer
      (set-window-buffer (selected-window) (current-buffer))
      (let ((model (dsh-test--viewport-card 3))
            (measured 0))
        (dsh-emacs-ui-update-fragment model :expanded t)
        (cl-letf (((symbol-function 'dsh-emacs-ui--window-at-bottom-p)
                   (lambda (&rest _) (cl-incf measured) nil)))
          (dsh-emacs-ui-update-fragment model)
          (dsh-emacs-ui-update-fragment (copy-tree model))
          (ert-info ((format "%s" "fragment-unchanged-update-skips-viewport-work"))
            (should (zerop measured)))
          (dsh-emacs-ui-update-fragment (dsh-test--viewport-card 4))
          (ert-info ((format "%s" "fragment-changed-update-measures-viewport"))
            (should (= measured 1))))))))

;; Wrapped lines are screen rows: a reader above one is not at the bottom.
(ert-deftest dsh-emacs-test-ui-fragment-update-keeps-reader-above-wrapped-line ()
  :tags '(dsh-unit)
  (save-window-excursion
    (with-temp-buffer
      (let ((window (selected-window))
            (inhibit-read-only t))
        (dsh-emacs-ui-update-fragment (dsh-test--viewport-card 2) :expanded t)
        (goto-char (point-max))
        (dotimes (i 100) (insert (format "filler %d\n" i)))
        (insert (make-string 20000 ?x) "\n")
        (set-window-buffer window (current-buffer))
        (goto-char (point-min))
        (search-forward "filler 90\n")
        (set-window-start window (line-beginning-position 0))
        (dsh-emacs-ui-update-fragment (dsh-test--viewport-card 4))
        (ert-info ((format "%s" "fragment-update-keeps-reader-above-wrapped-line"))
          (should (equal (dsh-test--window-start-line window) '("filler 90" t))))))))

;; A window at the bottom keeps following new fragments.
(ert-deftest dsh-emacs-test-ui-fragment-update-follows-bottom-window ()
  :tags '(dsh-unit)
  (save-window-excursion
    (with-temp-buffer
      (let ((window (selected-window))
            (inhibit-read-only t))
        (dotimes (i 100) (insert (format "filler %d\n" i)))
        (set-window-buffer window (current-buffer))
        (goto-char (point-max))
        (recenter -1)
        (dotimes (i 5)
          (dsh-emacs-ui-update-fragment
           (dsh-emacs-ui-make-fragment
            :namespace-id "viewport" :block-id (format "new-%d" i)
            :label-left "New" :style 'minimal :non-foldable t
            :body "one\ntwo\nthree\nfour")
           :create-new t))
        (ert-info ((format "%s" "fragment-update-follows-bottom-window"))
          (should (save-excursion
                    (goto-char (window-start window))
                    (vertical-motion (window-body-height window) window)
                    (>= (point) (1- (point-max))))))))))

;; Identical fragment updates must preserve interior markers and change ticks.
(ert-deftest dsh-emacs-test-ui-fragment-identical-update-no-write-case ()
  :tags '(dsh-unit)
  (dolist (style '(minimal rounded sharp))
    (with-temp-buffer
      (let* ((model (dsh-emacs-ui-make-fragment
                     :namespace-id "unchanged" :block-id "a" :style style
                     :label-left "Title" :body "body"))
             (range (dsh-emacs-ui-update-fragment model :expanded t))
             (inside (copy-marker (+ (car range) 2)))
             (tick (buffer-modified-tick)))
        (ert-info ((format "%s" (format "fragment-identical-update-no-write-%s" style)))
          (should (equal range (dsh-emacs-ui-update-fragment model)))
          (should (= tick (buffer-modified-tick)))
          (should (= inside (+ (car range) 2))))
        (setf (alist-get :body model) (propertize "body" 'face 'bold))
        (dsh-emacs-ui-update-fragment model)
        (goto-char (point-min))
        (search-forward "body")
        (ert-info ((format "%s" (format "fragment-property-only-update-applies-%s" style)))
          (should (eq (get-text-property (1- (point)) 'face) 'bold)))
        (set-marker inside nil)))))

;; Hidden content and layout changes must not be mistaken for identical updates.
(ert-deftest dsh-emacs-test-ui-fragment-hidden-update-retains-new-body-properties ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (let ((model (dsh-emacs-ui-make-fragment
                  :label-left "Long title" :body "old" :style 'minimal)))
      (dsh-emacs-ui-update-fragment model)
      (setf (alist-get :body model) (propertize "new" 'face 'italic))
      (dsh-emacs-ui-update-fragment model)
      (goto-char (point-min))
      (dsh-emacs-ui-toggle-fragment)
      (search-forward "new")
      (ert-info ((format "%s" "fragment-hidden-update-retains-new-body-properties"))
        (should (eq (get-text-property (1- (point)) 'face) 'italic)))
      (cl-letf (((symbol-function 'dsh-emacs-ui--box-width) (lambda () 4)))
        (dsh-emacs-ui-update-fragment model))
      (goto-char (point-min))
      (ert-info ((format "%s" "fragment-same-model-reflows-at-new-width"))
        (should (equal (buffer-substring-no-properties (point) (line-end-position))
                       "Lon…"))))))

;; Changed fragments retain markers in the unchanged prefix and suffix.
(ert-deftest dsh-emacs-test-ui-fragment-diff-preserves-unchanged-markers ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (let* ((model (dsh-emacs-ui-make-fragment
                   :style 'minimal :label-left "Title" :body "alpha\nold\nomega"))
           (range (dsh-emacs-ui-update-fragment model :expanded t))
           (title (copy-marker (+ (car range) 2)))
           (suffix (copy-marker (- (cdr range) 4))))
      (setf (alist-get :body model) "alpha\nlong replacement\nomega")
      (dsh-emacs-ui-update-fragment model)
      (ert-info ((format "%s" "fragment-diff-preserves-unchanged-markers"))
        (should (= title 3))
        (should (equal (buffer-substring-no-properties suffix (+ suffix 3)) "ega")))
      (set-marker title nil)
      (set-marker suffix nil))))

;; Repeated lookup and identical updates must not scan or render again.
(ert-deftest dsh-emacs-test-ui-fragment-repeated-updates-skip-scan-and-render ()
  :tags '(dsh-unit)
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
        (ert-info ((format "%s" "fragment-repeated-updates-skip-scan-and-render"))
          (should (= scans 0))
          (should (= renders 0))))
      ;; Caller mutation and external text edits must invalidate the fast path.
      (aset (alist-get :body model) 0 ?b)
      (dsh-emacs-ui-update-fragment model)
      (ert-info ((format "%s" "fragment-caller-string-mutation-is-not-cached"))
        (should (string-match-p "body" (buffer-string))))
      (let ((inhibit-read-only t))
        (goto-char (point-min)) (insert "prefix\n"))
      (ert-info ((format "%s" "fragment-index-follows-external-prefix-insertion"))
        (should (= (car (dsh-emacs-ui-find-block "cache" "a")) 8)))
      (let ((inhibit-read-only t)) (erase-buffer))
      (ert-info ((format "%s" "fragment-index-does-not-return-erased-block"))
        (should (not (dsh-emacs-ui-find-block "cache" "a"))))
      (dsh-emacs-ui-update-fragment model)
      (goto-char (point-min)) (dsh-emacs-ui-toggle-fragment)
      (ert-info ((format "%s" "fragment-index-survives-recreate-and-fold"))
        (should (equal (dsh-emacs-ui-find-block "cache" "a")
                       (cons (point-min) (point-max))))))))

;; Header changes do not rewrite unchanged body styling; rollback stays atomic.
(ert-deftest dsh-emacs-test-ui-fragment-header-change-does-not-restyle-body ()
  :tags '(dsh-unit)
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
      (ert-info ((format "%s" "fragment-header-change-does-not-restyle-body"))
        (should (= writes 0))
        (should (eq (get-text-property 5 'face) 'italic)))
      (let ((before (buffer-string))
            (putter (symbol-function 'put-text-property))
            injected caught)
        (setf (alist-get :body model) (propertize "unchanged body" 'face 'bold))
        (condition-case err
            (cl-letf (((symbol-function 'put-text-property)
                       (lambda (start end prop value &optional object)
                         (funcall putter start end prop value object)
                         ;; Fail the edit once; older Emacs also calls this
                         ;; primitive while rolling the transaction back.
                         (when (and (not injected) (not object)
                                    (eq prop 'dsh-emacs-ui-state))
                           (setq injected t)
                           (error "injected property failure")))))
              (dsh-emacs-ui-update-fragment model))
          (error (setq caught (equal (error-message-string err)
                                     "injected property failure"))))
        (ert-info ((format "%s" "fragment-property-failure-rolls-back-cache-and-text"))
          (should caught)
          (should (equal-including-properties before (buffer-string)))
          (should (equal (dsh-emacs-ui-find-block "global" "1")
                         (cons (point-min) (point-max)))))))))

;; The index preserves duplicate-ID ordering, delete and buffer isolation.
(ert-deftest dsh-emacs-test-ui-fragment-index-keeps-last-duplicate ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (buffer-enable-undo)
    (let ((model (dsh-emacs-ui-make-fragment :style 'minimal :label-left "Later")))
      (dsh-emacs-ui-update-fragment model :create-new t)
      (setf (alist-get :label-left model) "Earlier")
      (dsh-emacs-ui-update-fragment model :create-new t :insert-before (point-min))
      (ert-info ((format "%s" "fragment-index-keeps-last-duplicate"))
        (should (= (car (dsh-emacs-ui-find-block "global" "1")) 9)))
      (save-restriction
        (narrow-to-region 1 9)
        (ert-info ((format "%s" "fragment-index-respects-narrowing"))
          (should (equal (dsh-emacs-ui-find-block "global" "1") '(1 . 9)))))
      (ert-info ((format "%s" "fragment-index-widen-restores-last-duplicate"))
        (should (= (car (dsh-emacs-ui-find-block "global" "1")) 9)))
      (undo-boundary)
      (dsh-emacs-ui-delete-fragment "global" "1")
      (ert-info ((format "%s" "fragment-index-delete-reveals-earlier-duplicate"))
        (should (equal (dsh-emacs-ui-find-block "global" "1") '(1 . 9))))
      ;; Drive undo itself: it must run out of history without restoring Later
      ;; or disturbing the remaining fragment and its cached index.
      (let ((before (buffer-string))
            (last-command nil) (this-command 'undo) (pending-undo-list nil)
            (undo-equiv-table (make-hash-table :test 'eq))
            exhausted)
        (condition-case nil
            (undo)
          (user-error (setq exhausted t)))
        (ert-info ((format "%s" "fragment-delete-is-not-undoable"))
          (should exhausted)
          (should (equal-including-properties before (buffer-string)))
          (should (equal (dsh-emacs-ui-find-block "global" "1") '(1 . 9)))))
      (with-temp-buffer
        (ert-info ((format "%s" "fragment-index-is-buffer-local"))
          (should (not (dsh-emacs-ui-find-block "global" "1"))))))))

;; A cached model must still honor separator and arbitrary buffer changes.
(ert-deftest dsh-emacs-test-ui-fragment-cache-invalidates-on-separator-change ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (let ((model (dsh-emacs-ui-make-fragment
                  :style 'minimal :label-left "Title" :label-right "Summary")))
      (dsh-emacs-ui-update-fragment model)
      (let ((dsh-emacs-ui-label-separator "/"))
        (dsh-emacs-ui-update-fragment model)
        (ert-info ((format "%s" "fragment-cache-invalidates-on-separator-change"))
          (should (equal (buffer-substring-no-properties (point-min) (point-max))
                         "Title / Summary\n")))
        (let ((inhibit-read-only t))
          (subst-char-in-region (point-min) (point-max) ?T ?X))
        (dsh-emacs-ui-update-fragment model)
        (ert-info ((format "%s" "fragment-cache-repairs-external-text-edit"))
          (should (equal (buffer-substring-no-properties (point-min) (point-max))
                         "Title / Summary\n")))))))

;; Entirely narrowed operations need no global cache, including deletion.
(ert-deftest dsh-emacs-test-ui-fragment-narrowed-delete-without-index ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (insert "outside\n")
    (save-restriction
      (narrow-to-region (point-max) (point-max))
      (dsh-emacs-ui-update-fragment
       (dsh-emacs-ui-make-fragment :style 'minimal :label-left "Inside"))
      (progn
        (dsh-emacs-ui-delete-fragment "global" "1")
        (ert-info ((format "%s" "fragment-narrowed-delete-without-index"))
          (should (= (point-min) (point-max))))))))

;; --- Test 6: face definitions ---
(ert-deftest dsh-emacs-test-ui-user-face-exists ()
  :tags '(dsh-unit)
  (ert-info ((format "%s" "user-face exists"))
    (should (facep 'dsh-emacs-user-face))))

(ert-deftest dsh-emacs-test-ui-assistant-face-exists ()
  :tags '(dsh-unit)
  (ert-info ((format "%s" "assistant-face exists"))
    (should (facep 'dsh-emacs-assistant-face))))

(ert-deftest dsh-emacs-test-ui-tool-pending-face-exists ()
  :tags '(dsh-unit)
  (ert-info ((format "%s" "tool-pending-face exists"))
    (should (facep 'dsh-emacs-tool-pending-face))))

(ert-deftest dsh-emacs-test-ui-tool-success-face-exists ()
  :tags '(dsh-unit)
  (ert-info ((format "%s" "tool-success-face exists"))
    (should (facep 'dsh-emacs-tool-success-face))))

(ert-deftest dsh-emacs-test-ui-tool-error-face-exists ()
  :tags '(dsh-unit)
  (ert-info ((format "%s" "tool-error-face exists"))
    (should (facep 'dsh-emacs-tool-error-face))))

(ert-deftest dsh-emacs-test-ui-mode-line-face-exists ()
  :tags '(dsh-unit)
  (ert-info ((format "%s" "mode-line-face exists"))
    (should (facep 'dsh-emacs-modeline-face))))

(ert-deftest dsh-emacs-test-ui-session-title-face-exists ()
  :tags '(dsh-unit)
  (ert-info ((format "%s" "session-title-face exists"))
    (should (facep 'dsh-emacs-session-title-face))))

;; --- Test 7: UI rendering ---
(ert-deftest dsh-emacs-test-ui-ui-make-fragment ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (let ((frag (dsh-emacs-ui-make-fragment
                 :namespace-id "test"
                 :block-id "1"
                 :label-left "You"
                 :label-right "12:00"
                 :body "hello"
                 :style 'rounded)))
      (ert-info ((format "%s" "ui-make-fragment"))
        (should (and frag
                     (string= "test" (map-elt frag :namespace-id))
                     (string= "1" (map-elt frag :block-id))))))))

;; --- Test 8: minimal label line separator · ---
(ert-deftest dsh-emacs-test-ui-minimal-label-separator-dot ()
  :tags '(dsh-unit)
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
        (ert-info ((format "%s" "minimal-label-separator-dot"))
          (should (string-match-p "✶ Think · preview" text))
          (should (string-match-p "body line" text)))))))

(ert-deftest dsh-emacs-test-ui-minimal-label-separator-disabled ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (let ((dsh-emacs-ui-label-separator ""))
      (dsh-emacs-ui-update-fragment
       (dsh-emacs-ui-make-fragment
        :namespace-id "sep2" :block-id "1"
        :label-left "✶ Think" :label-right "preview"
        :body "body line" :style 'minimal)
       :create-new t :expanded t)
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (ert-info ((format "%s" "minimal-label-separator-disabled"))
          (should (and (string-match-p "✶ Think  preview" text)
                       (not (string-match-p "·" text)))))))))

;; Fragment updates are complete snapshots; adjacent blocks stay intact.
(ert-deftest dsh-emacs-test-ui-fragment-snapshot-case-case ()
  :tags '(dsh-unit)
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
          (progn
            (dsh-emacs-ui-update-fragment
             (dsh-emacs-ui-make-fragment
              :namespace-id "snapshot" :block-id "a" :style style
              :body body))
            (let* ((block (dsh-emacs-ui-find-block "snapshot" "a"))
                   (state (get-text-property (car block) 'dsh-emacs-ui-state))
                   (next (dsh-emacs-ui-find-block "snapshot" "b")))
              (ert-info ((format "%s" (format "fragment-snapshot-%s-%S" style body)))
                (should (equal (map-elt state :body) body))
                (should (not (string-match-p "Original\\|Summary"
                                             (buffer-substring (car block) (cdr block)))))
                (should (= (cdr block) (car next)))
                (should (equal-including-properties
                         neighbor-text (buffer-substring (car next) (cdr next))))))))))))

;; Nil clears flags/faces; ranges and the input marker survive replacements.
(ert-deftest dsh-emacs-test-ui-fragment-non-foldable-stays-visible ()
  :tags '(dsh-unit)
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
      (ert-info ((format "%s" "fragment-non-foldable-stays-visible"))
        (should (not (map-elt (get-text-property (point-min) 'dsh-emacs-ui-state)
                              :collapsed)))
        (should (string-match-p "body" (buffer-string))))
      (setq model (dsh-emacs-ui-make-fragment
                   :namespace-id "flags" :block-id "a" :style 'sharp
                   :label-left "New title" :body "replacement"))
      (goto-char (point-max))
      (let* ((range (dsh-emacs-ui-update-fragment model :insert-before input))
             (state (get-text-property (car range) 'dsh-emacs-ui-state)))
        (ert-info ((format "%s" "fragment-clears-flags-style-and-faces"))
          (should (eq (map-elt state :style) 'sharp))
          (should (not (map-elt state :non-foldable)))
          (should (not (map-elt state :body-face)))
          (should (not (map-elt state :header-face)))
          (should (not (string-match-p "Summary" (buffer-string))))
          (should (= (cdr range) input))
          (should (= (point) (point-max)))
          (should (equal (buffer-substring-no-properties input (point-max)) "Prompt: draft"))
          (should (not (get-text-property input 'dsh-emacs-ui-state))))
        (goto-char (car range))
        (search-forward "replacement")
        (ert-info ((format "%s" "fragment-old-face-removed-from-text"))
          (should (not (get-text-property (1- (point)) 'face))))
        (goto-char (car range))
        (dsh-emacs-ui-toggle-fragment)
        (ert-info ((format "%s" "fragment-cleared-non-foldable-can-collapse"))
          (should (not (string-match-p "replacement" (buffer-string)))))
        (dsh-emacs-ui-expand-all)
        (ert-info ((format "%s" "fragment-expand-all-restores-snapshot"))
          (should (string-match-p "replacement" (buffer-string))))
        (dsh-emacs-ui-collapse-all)
        (ert-info ((format "%s" "fragment-collapse-all-hides-body"))
          (should (not (string-match-p "replacement" (buffer-string))))))
      (set-marker input nil))))

;; Namespace and block ID are separate identity components, even with hyphens.
(ert-deftest dsh-emacs-test-ui-fragment-hyphenated-identities-do-not-collide ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-ui-update-fragment
     (dsh-emacs-ui-make-fragment
      :namespace-id "a-b" :block-id "c" :style 'minimal
      :label-left "First" :body "one") :expanded t)
    (dsh-emacs-ui-update-fragment
     (dsh-emacs-ui-make-fragment
      :namespace-id "a" :block-id "b-c" :style 'minimal
      :label-left "Second" :body "two") :expanded t)
    (ert-info ((format "%s" "fragment-hyphenated-identities-do-not-collide"))
      (should (equal (buffer-substring-no-properties (point-min) (point-max))
                     "First\none\nSecond\ntwo\n")))
    (dsh-emacs-ui-update-fragment
     (dsh-emacs-ui-make-fragment
      :namespace-id "a-b" :block-id "c" :style 'minimal
      :label-left "Changed" :body "three"))
    (ert-info ((format "%s" "fragment-update-isolated-by-both-identity-components"))
      (should (equal (buffer-substring-no-properties (point-min) (point-max))
                     "Changed\nthree\nSecond\ntwo\n")))))

(ert-deftest dsh-emacs-test-ui-fragment-pair-lookup-selects-distinct-blocks ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-ui-update-fragment
     (dsh-emacs-ui-make-fragment
      :namespace-id "a-b" :block-id "c" :style 'minimal :label-left "First"))
    (dsh-emacs-ui-update-fragment
     (dsh-emacs-ui-make-fragment
      :namespace-id "a" :block-id "b-c" :style 'minimal :label-left "Second"))
    (ert-info ((format "%s" "fragment-pair-lookup-selects-distinct-blocks"))
      (should (= (car (dsh-emacs-ui-find-block "a-b" "c")) (point-min)))
      (should (> (car (dsh-emacs-ui-find-block "a" "b-c")) (point-min))))
    (dsh-emacs-ui-delete-fragment "a-b" "c")
    (ert-info ((format "%s" "fragment-pair-delete-keeps-other-identity"))
      (should (not (dsh-emacs-ui-find-block "a-b" "c")))
      (should (equal (buffer-substring-no-properties (point-min) (point-max)) "Second\n")))))

;; Local navigation and bulk folding must not scan by identity for every card.
(ert-deftest dsh-emacs-test-ui-fragment-forward-reaches-adjacent-block ()
  :tags '(dsh-unit)
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
        (ert-info ((format "%s" "fragment-forward-reaches-adjacent-block"))
          (should (looking-at-p "Second\n")))
        (dsh-emacs-ui-backward-block)
        (ert-info ((format "%s" "fragment-backward-reaches-adjacent-block"))
          (should (= (point) (point-min))))
        (dsh-emacs-ui-collapse-all)
        (ert-info ((format "%s" "fragment-collapse-all-keeps-non-foldable"))
          (should (equal (buffer-substring-no-properties (point-min) (point-max))
                         "First\nSecond\nFixed\nFixed body\n")))
        (dsh-emacs-ui-expand-all)
        (ert-info ((format "%s" "fragment-expand-all-restores-all-local-bodies"))
          (should (equal (buffer-substring-no-properties (point-min) (point-max))
                         "First\nFirst body\nSecond\nSecond body\nFixed\nFixed body\n"))))
      (ert-info ((format "%s" "fragment-local-actions-avoid-global-identity-scans"))
        (should (= lookups 0))))))

;; Header layout gives the title priority and measures geometry once.
(ert-deftest dsh-emacs-test-ui-fragment-title-priority-case ()
  :tags '(dsh-unit)
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
          (ert-info ((format "%s" (format "fragment-title-priority-%s" style)))
            (should (string-match-p "Build result" header))
            (should (<= (string-width header) (if (eq style 'minimal) 20 24)))
            (should (= calls 1))))
        (unless (eq style 'minimal)
          (let ((widths (mapcar #'string-width
                                (split-string (buffer-string) "\n" t))))
            (ert-info ((format "%s" (format "fragment-border-widths-agree-%s" style)))
              (should (equal widths '(24 24 24))))))))))

(ert-deftest dsh-emacs-test-ui-fragment-measures-displaying-window ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (let ((window (selected-window)))
      (cl-letf (((symbol-function 'get-buffer-window) (lambda (&rest _) window))
                ((symbol-function 'window-text-width)
                 (lambda (target)
                   (ert-info ((format "%s" "fragment-measures-displaying-window"))
                     (should (eq target window)))
                   12)))
        (ert-info ((format "%s" "fragment-narrow-window-has-no-40-column-floor"))
          (should (= (dsh-emacs-ui--box-width) 8)))))))

(ert-deftest dsh-emacs-test-ui-fragment-narrow-header-and-placeholder-case-case ()
  :tags '(dsh-unit)
  (dolist (width '(1 4 12))
    (dolist (style '(minimal rounded sharp))
      (with-temp-buffer
        (cl-letf (((symbol-function 'dsh-emacs-ui--box-width) (lambda () width)))
          (dsh-emacs-ui-update-fragment
           (dsh-emacs-ui-make-fragment
            :namespace-id "narrow" :block-id "a" :style style
            :label-left "A very long title" :label-right "summary"
            :body "hidden body")))
        (ert-info ((format "%s" (format "fragment-narrow-header-and-placeholder-%s-%s"
                                        style width)))
          (should (cl-every (lambda (line)
                              (<= (string-width line)
                                  (+ width (if (eq style 'minimal) 0 4))))
                            (split-string (buffer-string) "\n" t))))))))

;; Embedded link/button keymaps take precedence over the fold default.
(ert-deftest dsh-emacs-test-ui-fragment-custom-header-action-preserved ()
  :tags '(dsh-unit)
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
        (ert-info ((format "%s" "fragment-custom-header-action-preserved"))
          (should (eq (get-text-property (1- (point)) 'keymap) map))
          (should (save-excursion
                    (backward-char)
                    (eq (key-binding (kbd "RET")) #'ignore)))
          (should (equal (get-text-property (1- (point)) 'help-echo) "open details"))
          (should (eq (get-text-property (point-min) 'keymap) dsh-emacs-ui-fragment-map)))
        (goto-char (point-min))
        (dsh-emacs-ui-toggle-fragment)))))

;; Replacing a folded row must not carry the header cursor to the block end.
(ert-deftest dsh-emacs-test-ui-fragment-ret-keeps-header-point-case-case-case-case ()
  :tags '(dsh-unit)
  (dolist (style '(minimal rounded sharp))
    (dolist (padding '(nil t))
      (dolist (position '(middle label-end line-end))
        (with-temp-buffer
          (dsh-emacs-ui-mode 1)
          (dsh-emacs-ui-update-fragment
           (dsh-emacs-ui-make-fragment
            :namespace-id "fold-point" :block-id "row" :style style
            :label-left "Title" :label-right "Summary"
            :body "First body line\nSecond body line" :padding padding))
          (dsh-emacs-ui-update-fragment
           (dsh-emacs-ui-make-fragment
            :namespace-id "fold-point" :block-id "neighbor" :style 'minimal
            :label-left "Neighbor" :body "Neighbor body"))
          (let* ((block (dsh-emacs-ui-find-block "fold-point" "row"))
                 (next (dsh-emacs-ui-find-block "fold-point" "neighbor"))
                 (boundary (copy-marker (car next) nil))
                 (neighbor (buffer-substring (car next) (cdr next))))
            (goto-char (car block))
            (search-forward "Summary")
            (pcase position
              ('middle (backward-char 3))
              ('line-end (end-of-line)))
            (let ((original-point (point)))
              (dotimes (pass 2)
                (call-interactively (key-binding (kbd "RET")))
                (let* ((row (dsh-emacs-ui-find-block "fold-point" "row"))
                       (state (get-text-property (car row) 'dsh-emacs-ui-state))
                       (next (dsh-emacs-ui-find-block "fold-point" "neighbor")))
                  (ert-info ((format "%s" (format "fragment-ret-keeps-header-point-%s-%s-%s-%s"
                                                  style padding position pass)))
                    (should (= (point) original-point))
                    (should (eq (map-elt state :collapsed) (= pass 1)))
                    (should (= boundary (car next)))
                    (should (equal-including-properties
                             neighbor (buffer-substring (car next) (cdr next))))))))
            (set-marker boundary nil)))))))

;; Rendering and insertion failures preserve text, properties and input markers.
(ert-deftest dsh-emacs-test-ui-fragment-failed-case-case-rolls-back ()
  :tags '(dsh-unit)
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
            (ert-info ((format "%s" (format "fragment-failed-%s-%s-rolls-back" operation fault)))
              (should caught)
              (should (= (point-max) original-end))
              (should (equal-including-properties before (buffer-string)))
              (should (equal (buffer-substring-no-properties anchor (point-max)) "Prompt: draft")))
            (set-marker anchor nil)))))))

;; --- Test 25: new messages auto-scroll-follow while at the bottom ---
(ert-deftest dsh-emacs-test-ui-follow-scrolls-at-bottom ()
  :tags '(dsh-unit)
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
          (ert-info ((format "%s" "follow-scrolls-at-bottom"))
            (should (> (window-start win) start-before))))))))

;; --- Test 26: not pulled back to the bottom while the user scrolls up ---
(ert-deftest dsh-emacs-test-ui-follow-does-not-yank-scrolled-window ()
  :tags '(dsh-unit)
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
      (ert-info ((format "%s" "follow-does-not-yank-scrolled-window"))
        (should (= (window-start win) 1))))))

;; --- Test 27: same-buffer input mode (agent-shell style) ---
(ert-deftest dsh-emacs-test-ui-inline-mode-single-buffer ()
  :tags '(dsh-unit)
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
      (ert-info ((format "%s" "inline-mode-single-buffer"))
        (should (and reply-pos prompt-pos
                     (< reply-pos prompt-pos)         ; reply above the prompt
                     (goto-char marker-pos)
                     (looking-back "❯ " (line-beginning-position))))))))

;; Collapsed snapshots retain complete content and faces across repeated folds.
(ert-deftest dsh-emacs-test-ui-fragment-update-preserves-fold-case ()
  :tags '(dsh-unit)
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
        (ert-info ((format "%s" (format "fragment-update-preserves-fold-%s" style)))
          (should (map-elt (get-text-property (point-min) 'dsh-emacs-ui-state) :collapsed))
          (should (not (string-match-p "second" (buffer-string)))))
        (dotimes (_ 2)
          (goto-char (point-min))
          (dsh-emacs-ui-toggle-fragment)
          (goto-char (point-min))
          (search-forward "second")
          (let ((faces (get-text-property (1- (point)) 'face)))
            (ert-info ((format "%s" (format "fragment-expand-content-faces-%s" style)))
              (should (memq 'italic faces))
              (should (memq 'dsh-emacs-tool-success-face faces))
              (should (not (memq 'dsh-emacs-thinking-face faces)))
              (should (equal (get-text-property (1- (point)) 'help-echo) "body help"))
              (should (memq 'dsh-emacs-thinking-face
                            (get-text-property (+ (point-min) 3) 'face)))))
          (goto-char (point-min))
          (dsh-emacs-ui-toggle-fragment))))))

;; Fragment faces are region-scoped: :header-face never reaches the expanded
;; body and :body-face never tints the header, for any border style.  This is
;; the general invariant behind the Think/tool-card body-tint fixes.
(ert-deftest dsh-emacs-test-ui-fragment-header-face-scoped-case ()
  :tags '(dsh-unit)
  (dolist (style '(minimal rounded sharp))
    (with-temp-buffer
      (dsh-emacs-ui-update-fragment
       (dsh-emacs-ui-make-fragment
        :namespace-id "scope" :block-id (format "sc-%s" style) :style style
        :label-left "Head" :label-right "Sum" :body "Body line"
        :header-face 'underline :body-face 'italic)
       :create-new t :expanded t)
      (goto-char (point-min))
      (ert-info ((format "%s" (format "fragment-header-face-scoped-%s" style)))
        (should (and (search-forward "Head" nil t)
                     (memq 'underline (dsh-test--faces-at (match-beginning 0)))
                     (not (memq 'italic (dsh-test--faces-at (match-beginning 0))))
                     ;; the left label is the title and keeps the title face
                     (memq 'dsh-emacs-ui-label-face
                           (dsh-test--faces-at (match-beginning 0))))))
      ;; the right label is a summary: header face but never the title face
      (goto-char (point-min))
      (ert-info ((format "%s" (format "fragment-summary-keeps-title-face-off-%s" style)))
        (should (and (search-forward "Sum" nil t)
                     (memq 'underline (dsh-test--faces-at (match-beginning 0)))
                     (not (memq 'dsh-emacs-ui-label-face
                                (dsh-test--faces-at (match-beginning 0)))))))
      (goto-char (point-min))
      (ert-info ((format "%s" (format "fragment-body-face-scoped-%s" style)))
        (should (and (search-forward "Body line" nil t)
                     (memq 'italic (dsh-test--faces-at (match-beginning 0)))
                     (not (memq 'underline (dsh-test--faces-at (match-beginning 0)))))))
      ;; The border chrome is neither region: a face attribute on the body must
      ;; not reach the bottom rule either.
      (unless (eq style 'minimal)
        (goto-char (point-max))
        (ert-info ((format "%s" (format "fragment-border-keeps-own-face-%s" style)))
          (should (and (search-backward "─" nil t)
                       (not (memq 'italic (dsh-test--faces-at (match-beginning 0)))))))))))

(ert-deftest dsh-emacs-test-ui-work-details-hides-display-properties ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (insert (propertize "Icon" 'display "VISIBLE-ICON") " Work\n")
    (let ((end (point)))
      (insert "Final answer\n")
      (let* ((overlay (dsh-emacs-ui-fold-region "display" "details" (point-min) end))
             (start (overlay-start overlay)))
        ;; GUI image/replacement display can win over invisibility alone.
        (should (equal (get-char-property start 'display) ""))
        (should (equal (get-text-property start 'display) "VISIBLE-ICON"))
        (dsh-emacs-ui--set-work-details-expanded overlay t)
        (should (equal (get-char-property start 'display) "VISIBLE-ICON"))
        (dsh-emacs-ui--set-work-details-expanded overlay nil)
        (should (equal (get-char-property start 'display) ""))))))

(ert-deftest dsh-emacs-test-ui-work-details-child-replacement-boundaries ()
  :tags '(dsh-unit)
  (dolist (ids '(("only") ("first" "last")))
    (dolist (expanded '(nil t))
      (with-temp-buffer
        (cl-labels ((card (id text)
                     (dsh-emacs-ui-make-fragment
                      :namespace-id "work" :block-id id :style 'minimal
                      :label-left text :body (concat text " body"))))
          (dolist (id ids)
            (dsh-emacs-ui-update-fragment (card id id) :expanded expanded))
          (goto-char (point-max))
          (let ((end (point))
                (inhibit-read-only t))
            (insert "Final answer\n")
            (let ((overlay (dsh-emacs-ui-fold-region
                            "work" "details" (point-min) end)))
              (cl-labels
                  ((check-bounds ()
                     (let ((header (dsh-emacs-ui-find-block "work" "details"))
                           (first (dsh-emacs-ui-find-block "work" (car ids)))
                           (last (dsh-emacs-ui-find-block "work" (car (last ids))))
                           (answer (save-excursion
                                     (goto-char (point-min))
                                     (search-forward "Final answer")
                                     (match-beginning 0))))
                       (should (= (overlay-start overlay) (cdr header)))
                       (should (= (overlay-end overlay) answer))
                       (should (= (cdr last) answer))
                       (should (invisible-p (car first)))
                       (should (invisible-p (1- (cdr last))))
                       (should-not (invisible-p (car header)))
                       (should-not (invisible-p answer)))))
                (check-bounds)
                (dolist (id ids)
                  (dsh-emacs-ui-update-fragment
                   (card id (concat "Changed " id " with more output")))
                  (check-bounds)
                  (goto-char (car (dsh-emacs-ui-find-block "work" id)))
                  (dsh-emacs-ui--toggle-fragment-at-point)
                  (check-bounds)
                  (dsh-emacs-ui--toggle-fragment-at-point)
                  (check-bounds)))
              ;; Work refreshes retain a manual reveal and exact answer bounds.
              (dsh-emacs-ui--set-work-details-expanded overlay t)
              (should (eq overlay
                          (dsh-emacs-ui-fold-region
                           "work" "details" (point-min)
                           (overlay-end overlay) overlay)))
              (should-not (overlay-get overlay 'invisible)))))))))

(ert-deftest dsh-emacs-test-ui-work-details-controls-and-navigation ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dolist (id '("first" "last" "answer"))
      (dsh-emacs-ui-update-fragment
       (dsh-emacs-ui-make-fragment
        :namespace-id "controls" :block-id id :style 'minimal
        :label-left id :body (concat id " body"))
       :expanded (equal id "first")))
    (let ((overlay (dsh-emacs-ui-fold-region
                    "controls" "details" (point-min)
                    (car (dsh-emacs-ui-find-block "controls" "answer")))))
      (goto-char (point-min))
      (dsh-emacs-ui-toggle-fragment)
      (should-not (overlay-get overlay 'invisible))
      (should-not (map-elt (get-text-property
                           (car (dsh-emacs-ui-find-block "controls" "first"))
                           'dsh-emacs-ui-state) :collapsed))
      (should (map-elt (get-text-property
                       (car (dsh-emacs-ui-find-block "controls" "last"))
                       'dsh-emacs-ui-state) :collapsed))
      (dsh-emacs-ui-toggle-fragment)
      (should (overlay-get overlay 'invisible))
      (dsh-emacs-ui-forward-block)
      (should (= (point) (car (dsh-emacs-ui-find-block "controls" "answer"))))
      (should-not (invisible-p (point)))
      (dsh-emacs-ui-backward-block)
      (should (= (point) (point-min)))
      (should-not (invisible-p (point)))
      ;; Search opens only the outer disclosure, keeping inner folds intact.
      (funcall (overlay-get overlay 'isearch-open-invisible) overlay)
      (should-not (overlay-get overlay 'invisible))
      (should (map-elt (get-text-property
                       (car (dsh-emacs-ui-find-block "controls" "last"))
                       'dsh-emacs-ui-state) :collapsed))
      (let* ((button (button-at (point-min)))
             (start (button-start button))
             (end (button-end button)))
        ;; The header keeps its text: no display replacement may sidestep the
        ;; fragment's width truncation.
        (should (equal "Completed"
                       (buffer-substring-no-properties start (- end 2))))
        (should-not (get-text-property start 'display))
        ;; The muted face outranks the bold title face `--label-merge' appends.
        (should (eq 'dsh-emacs-reply-meta-face
                    (let ((face (get-text-property start 'face)))
                      (if (listp face) (car face) face))))
        (let ((icon (get-text-property (1- end) 'display)))
          (should (if (and (display-graphic-p) (image-type-available-p 'svg))
                      (and (eq (car-safe icon) 'image)
                           (string-match-p "M4 10l4-4 4 4"
                                           (plist-get (cdr icon) :data)))
                    (equal icon "▴")))))
      (dsh-emacs-ui-collapse-all)
      (should (overlay-get overlay 'invisible))
      (dolist (id '("first" "last" "answer"))
        (should (map-elt (get-text-property
                         (car (dsh-emacs-ui-find-block "controls" id))
                         'dsh-emacs-ui-state) :collapsed)))
      (dsh-emacs-ui-expand-all)
      (should-not (overlay-get overlay 'invisible))
      (dolist (id '("first" "last" "answer"))
        (should-not (map-elt (get-text-property
                             (car (dsh-emacs-ui-find-block "controls" id))
                             'dsh-emacs-ui-state) :collapsed)))
      (should (= (overlay-end overlay)
                 (car (dsh-emacs-ui-find-block "controls" "answer")))))))

(ert-deftest dsh-emacs-test-ui-work-details-caption-refreshes ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (insert "work\n")
    (let ((end (point)))
      (insert "answer\n")
      (let ((overlay (dsh-emacs-ui-fold-region
                      "caption" "details" (point-min) end nil "Completed")))
        ;; Later timing facts replace the header text itself, not a display
        ;; string that could sidestep truncation.
        (should (eq overlay
                    (dsh-emacs-ui-fold-region
                     "caption" "details" (point-min) end overlay
                     "Completed in 4s")))
        (let* ((header (dsh-emacs-ui-find-block "caption" "details"))
               (button (button-at (car header))))
          (should (equal "Completed in 4s"
                         (buffer-substring-no-properties
                          (button-start button) (- (button-end button) 2)))))
        (dsh-emacs-ui--set-work-details-expanded overlay t)
        (should (eq overlay
                    (dsh-emacs-ui-fold-region
                     "caption" "details" (point-min) end overlay
                     "Completed in 4s")))
        (should-not (overlay-get overlay 'invisible))))))

(ert-deftest dsh-emacs-test-ui-work-details-nested-activity ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (insert "tool output\n")
    (let ((answer (copy-marker (point))))
      (insert "final answer\n")
      (let* ((activity (dsh-emacs-ui-fold-region
                        "nested" "activity" (point-min) answer
                        nil "Read files" 'activity-details))
             (outer (dsh-emacs-ui-fold-region
                     "nested" "task" (point-min) answer nil "Completed")))
        (should (invisible-p (overlay-start activity)))
        (should-not (invisible-p answer))
        (dsh-emacs-ui--set-work-details-expanded outer t)
        (let ((header (dsh-emacs-ui-find-block "nested" "activity")))
          (should-not (invisible-p (car header)))
          (should (eq 'activity-details
                      (map-elt (get-text-property (car header) 'dsh-emacs-ui-state)
                               :status))))
        (should (invisible-p (overlay-start activity)))
        (dsh-emacs-ui--set-work-details-expanded activity t)
        (should-not (invisible-p (overlay-start activity)))
        (should (eq activity (dsh-emacs-ui-fold-region
                              "nested" "activity" (overlay-start activity) answer
                              activity "Read files and ran commands" 'activity-details)))
        (should-not (overlay-get activity 'invisible))
        (dsh-emacs-ui-delete-work-details outer)
        (should (overlay-buffer activity))
        (dsh-emacs-ui-delete-work-details activity)
        (should-not (overlay-buffer activity))
        (should (equal (buffer-string) "tool output\nfinal answer\n")))
      (set-marker answer nil))))

(ert-deftest dsh-emacs-test-ui-work-details-narrow-header-keeps-truncation ()
  :tags '(dsh-unit)
  (dolist (width '(1 2 12 30))
    (with-temp-buffer
      (insert "work\n")
      (let ((end (point))
            (caption "Completed in 4m 10s"))
        (insert "answer\n")
        (cl-letf (((symbol-function 'dsh-emacs-ui--box-width) (lambda () width)))
          (let ((overlay (dsh-emacs-ui-fold-region
                          "narrow" "details" (point-min) end nil caption)))
            (let* ((header (dsh-emacs-ui-find-block "narrow" "details"))
                   (text (buffer-substring-no-properties
                          (car header) (1- (cdr header))))
                   (button (button-at (car header))))
              (ert-info ((format "narrow work header width=%d" width))
                ;; The header never renders wider than the body width.
                (should (<= (string-width text) width))
                (should-not (get-text-property (car header) 'display))
                ;; A chevron that survived truncation carries the icon; a
                ;; truncated one keeps its ellipsis instead of erroring.
                (when button
                  (should (eq (not (null (get-text-property
                                          (1- (button-end button)) 'display)))
                              (>= width (length (concat caption " ▾"))))))))
            ;; Toggling a truncated row is a no-op for the caption, not an error.
            (dsh-emacs-ui--set-work-details-expanded overlay t)
            (dsh-emacs-ui--set-work-details-expanded overlay nil)))))))

(ert-deftest dsh-emacs-test-ui-work-details-navigation-from-hidden-content ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-ui-update-fragment
     (dsh-emacs-ui-make-fragment
      :namespace-id "hidden" :block-id "child" :style 'minimal
      :label-left "Tool" :body "Output") :expanded t)
    (goto-char (point-max))
    (let ((end (point)) (inhibit-read-only t))
      (insert "Final prose\n")
      (let ((overlay (dsh-emacs-ui-fold-region
                      "hidden" "details" (point-min) end)))
        (goto-char (overlay-start overlay))
        (dsh-emacs-ui-forward-block)
        (should-not (invisible-p (point)))
        (should (= (point) (overlay-end overlay)))
        (goto-char (overlay-start overlay))
        (dsh-emacs-ui-backward-block)
        (should (= (point) (point-min)))
        (dsh-emacs-ui-expand-all)
        (goto-char (overlay-start overlay))
        (dsh-emacs-ui-collapse-all)
        (should-not (invisible-p (point)))
        (should (= (point) (point-min)))))))

(ert-deftest dsh-emacs-test-ui-lazy-body-cache-and-update ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (let* ((calls 0)
           (width 60)
           (body (lambda ()
                   (cl-incf calls)
                   (propertize (format "body at %d" width) 'face 'bold)))
           (model (dsh-emacs-ui-make-fragment
                   :namespace-id "lazy" :block-id "one" :style 'minimal
                   :label-left "Tool" :body body)))
      (cl-letf (((symbol-function 'dsh-emacs-ui--box-width) (lambda () width)))
        (dsh-emacs-ui-update-fragment model)
        (should (= calls 0))
        (goto-char (point-min))
        (dsh-emacs-ui-toggle-fragment)
        (should (= calls 1))
        (should (string-match-p "body at 60" (buffer-string)))
        (let ((pos (save-excursion (search-forward "body at 60") (match-beginning 0))))
          (should (eq (get-text-property pos 'face) 'bold)))
        (dsh-emacs-ui-toggle-fragment)
        (dsh-emacs-ui-toggle-fragment)
        (should (= calls 1))
        ;; An unchanged snapshot, even after an unrelated buffer edit, reuses
        ;; the formatted body rather than recomputing it.
        (let ((inhibit-read-only t))
          (save-excursion (goto-char (point-max)) (insert "neighbor\n")))
        (dsh-emacs-ui-update-fragment model)
        (should (= calls 1))
        (dsh-emacs-ui-toggle-fragment)
        (setq width 40)
        (dsh-emacs-ui-toggle-fragment)
        (should (= calls 2))
        (should (string-match-p "body at 40" (buffer-string)))
        ;; A new source invalidates the previous result, retaining fold state.
        (setf (alist-get :body model) (lambda () (cl-incf calls) "replacement"))
        (dsh-emacs-ui-update-fragment model)
        (should (= calls 3))
        (should (string-match-p "replacement" (buffer-string)))
        (should-not (string-match-p "body at" (buffer-string)))
        (dsh-emacs-ui-toggle-fragment)
        (setf (alist-get :body model) (lambda () (cl-incf calls) nil))
        (dsh-emacs-ui-update-fragment model)
        (should (= calls 3))
        (dsh-emacs-ui-toggle-fragment)
        (dsh-emacs-ui-toggle-fragment)
        (dsh-emacs-ui-toggle-fragment)
        (should (= calls 4))))))

(ert-deftest dsh-emacs-test-ui-lazy-body-failure-keeps-snapshot ()
  :tags '(dsh-unit)
  (dolist (fault '(body insert))
    (with-temp-buffer
      (let ((calls 0)
            (fail t)
            (original-insert (symbol-function 'insert)))
        (dsh-emacs-ui-update-fragment
         (dsh-emacs-ui-make-fragment
          :style 'minimal :label-left "Tool"
          :body (lambda ()
                  (cl-incf calls)
                  (when (and fail (eq fault 'body)) (error "Body failed"))
                  "lazy output")))
        (goto-char (point-min))
        (let ((before (buffer-string))
              (state (get-text-property (point-min) 'dsh-emacs-ui-state)))
          (cl-letf (((symbol-function 'insert)
                     (lambda (&rest args)
                       (apply original-insert args)
                       (when (and fail (eq fault 'insert))
                         (error "Insertion failed")))))
            (should-error (dsh-emacs-ui-toggle-fragment)))
          (should (equal-including-properties before (buffer-string)))
          (should (eq state (get-text-property (point-min) 'dsh-emacs-ui-state)))
          (should-not (assq :body-cache state))
          (setq fail nil)
          (goto-char (point-min))
          (dsh-emacs-ui-toggle-fragment)
          (should (= calls 2))
          (should (string-match-p "lazy output" (buffer-string))))))))

(ert-deftest dsh-emacs-test-ui-lazy-body-respects-layout ()
  :tags '(dsh-unit)
  (dolist (style '(minimal rounded sharp))
    (dolist (non-foldable '(nil t))
      (let* ((calls 0)
             (body "first\nsecond")
             (model (dsh-emacs-ui-make-fragment
                     :style style :non-foldable non-foldable
                     :label-left "Title" :body (lambda () (cl-incf calls) body)))
             (lazy (substring-no-properties
                    (dsh-emacs-ui--render-fragment model nil 60))))
        (should (= calls (if (and (eq style 'minimal) (not non-foldable)) 0 1)))
        (setf (alist-get :body model) body)
        (should (equal lazy (substring-no-properties
                             (dsh-emacs-ui--render-fragment model nil 60))))))))

(ert-deftest dsh-emacs-test-ui-lazy-body-state-update-keeps-one-cache ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (let ((calls 0)
          (width 60))
      (cl-letf (((symbol-function 'dsh-emacs-ui--box-width) (lambda () width)))
        (dsh-emacs-ui-update-fragment
         (dsh-emacs-ui-make-fragment
          :style 'minimal :label-left "Tool"
          :body (lambda () (cl-incf calls) (format "width %d" width)))
         :expanded t)
        (dolist (next-width '(60 60 40 40))
          (setq width next-width)
          (dsh-emacs-ui-update-fragment
           (get-text-property (point-min) 'dsh-emacs-ui-state))
          (let ((state (get-text-property (point-min) 'dsh-emacs-ui-state)))
            (should (= 1 (cl-count :body-cache state :key #'car))))
          (should (string-match-p (format "width %d" width) (buffer-string))))
        (should (= calls 2))))))

(defvar dsh-emacs-ui--menu-context)
(defvar vertico-sort-override-function)

(ert-deftest dsh-emacs-test-ui-menu-action-uses-native-accept ()
  :tags '(dsh-unit)
  (let ((vertico-sort-override-function #'reverse)
        (dsh-emacs-ui--menu-context
         (list :action 'send :default-action 'send
               :bindings '(("C-c d" . delete)))))
    (with-temp-buffer
      (use-local-map (make-sparse-keymap))
      (local-set-key (kbd "RET")
                     (lambda () (interactive) (throw 'accepted "delta")))
      (let ((accept (key-binding (kbd "RET"))))
        (dsh-emacs-ui--menu-setup)
        (should (eq (key-binding (kbd "C-c d")) accept))
        (should (eq (key-binding (kbd "d")) #'self-insert-command))
        (should-not vertico-sort-override-function)
        (cl-letf (((symbol-function 'this-command-keys-vector)
                   (lambda () (kbd "C-c d"))))
          (run-hooks 'pre-command-hook)
          (should (equal (catch 'accepted
                           (call-interactively (key-binding (kbd "C-c d"))))
                         "delta"))))
      (should (eq (plist-get dsh-emacs-ui--menu-context :action) 'delete)))
    (should (eq vertico-sort-override-function #'reverse))))

(ert-deftest dsh-emacs-test-ui-menu-incomplete-accept-keeps-default-action ()
  :tags '(dsh-unit)
  (let ((dsh-emacs-ui--menu-context
         (list :action 'send :default-action 'send
               :bindings '(("C-c d" . delete)))))
    (cl-letf (((symbol-function 'this-command-keys-vector)
               (lambda () (kbd "C-c d"))))
      (dsh-emacs-ui--menu-record-action))
    (should (eq (plist-get dsh-emacs-ui--menu-context :action) 'delete))
    (cl-letf (((symbol-function 'this-command-keys-vector)
               (lambda () (kbd "RET"))))
      (dsh-emacs-ui--menu-record-action))
    (should (eq (plist-get dsh-emacs-ui--menu-context :action) 'send))))

(ert-deftest dsh-emacs-test-ui-menu-global-action-needs-no-selection ()
  :tags '(dsh-unit)
  (let ((dsh-emacs-ui--menu-context
         (list :action 'show :default-action 'show
               :bindings '(("C-c r" . refresh)) :global-actions '(refresh))))
    (cl-letf (((symbol-function 'this-command-keys-vector)
               (lambda () (kbd "C-c r"))))
      (dsh-emacs-ui--menu-record-action)
      (should (equal (catch 'dsh-emacs-ui-menu-result
                       (dsh-emacs-ui--menu-global-action))
                     '(refresh nil))))))

(ert-deftest dsh-emacs-test-ui-menu-read-resolves-returned-label ()
  :tags '(dsh-unit)
  (cl-letf (((symbol-function 'completing-read)
             (lambda (&rest _) "delta")))
    (should (equal (dsh-emacs-ui-menu-read
                    "Queue: " '(("alpha" . first) ("delta" . second)) 'send
                    '(("C-c d" delete)))
                   '(send second)))))

(provide 'dsh-test-ui)
;;; dsh-test-ui.el ends here
