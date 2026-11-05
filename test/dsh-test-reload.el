;;; dsh-test-reload.el --- Reload tests -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "28.1"))

(require 'dsh-test-support)

(ert-deftest dsh-emacs-test-reload-rejects-each-active-interaction ()
  :tags '(dsh-unit)
  (dolist (active '((question . "question-event")
                    (approval . "approval-event")
                    (late-answer)))
    (let ((dsh-emacs--interaction-active active))
      (should-error (dsh-emacs-reload) :type 'user-error))))

;; Exercise real source reload in a fresh Emacs, not this suite's mocks.
(ert-deftest dsh-emacs-test-reload-reload-sources-preserve-state-and-refresh-definitions ()
  :tags '(dsh-unit)
  (let* ((root (file-name-directory (locate-library "dsh-emacs")))
         (copy (make-temp-file "dsh-reload-test-" t))
         (output (generate-new-buffer " *dsh-reload-test*"))
         (process-environment (copy-sequence process-environment)))
    (unwind-protect
        (progn
          (dolist (file (directory-files root t "\\`dsh-emacs.*\\.el\\'"))
            (copy-file file (expand-file-name (file-name-nondirectory file) copy)))
          (setenv "DSH_RELOAD_TEST_ROOT" copy)
          (let ((status
                 (call-process
                  (expand-file-name invocation-name invocation-directory)
                  nil output nil "-Q" "--batch" "-L" copy "-l" "dsh-emacs.el"
                  "--eval"
                  (prin1-to-string
                   '(let* ((root (getenv "DSH_RELOAD_TEST_ROOT"))
                           (fixture (expand-file-name "dsh-emacs-reload-fixture.el" root))
                           (chat (generate-new-buffer " *reload-chat*"))
                           (proc (make-pipe-process :name "reload-events" :noquery t))
                           (timer (run-at-time 3600 nil #'ignore))
                           (dsh-emacs-base-url "http://example.invalid:9999")
                           (dsh-emacs-server-auth-token "keep-auth"))
                      (with-temp-file fixture
                        (insert ";;; -*- lexical-binding: t; -*-\n"
                                "(require 'dsh-emacs)\n"
                                "(defvar dsh-reload-test-state 1)\n"
                                "(defvar dsh-reload-test-map (let ((m (make-sparse-keymap))) (define-key m (kbd \"a\") #'ignore) m))\n"
                                "(defface dsh-reload-test-face '((t :foreground \"red\")) \"Test face.\" :group 'dsh-emacs)\n"
                                "(defun dsh-reload-test-value () 1)\n"
                                "(provide 'dsh-emacs-reload-fixture)\n"))
                      (load fixture nil t t)
                      (require 'bytecomp)
                      (byte-compile-file fixture)
                      (set 'dsh-reload-test-state 99)
                      (custom-set-faces
                       '(dsh-reload-test-face ((t :foreground "blue"))))
                      (with-temp-file fixture
                        (insert ";;; -*- lexical-binding: t; -*-\n"
                                "(require 'dsh-emacs)\n"
                                "(defvar dsh-reload-test-state 2)\n"
                                "(defvar dsh-reload-test-map (let ((m (make-sparse-keymap))) (define-key m (kbd \"b\") #'ignore) m))\n"
                                "(defface dsh-reload-test-face '((t :foreground \"green\")) \"Test face.\" :group 'dsh-emacs)\n"
                                "(defun dsh-reload-test-value () 2)\n"
                                "(provide 'dsh-emacs-reload-fixture)\n"))
                      (set-file-times fixture (seconds-to-time 1))
                      (unwind-protect
                          (with-current-buffer chat
                            (dsh-emacs-mode)
                            (setq-local dsh-emacs--buffer-session "keep-session"
                                        dsh-emacs--event-process proc
                                        dsh-emacs--event-ready t
                                        dsh-emacs--ws-watchdog-timer timer
                                        dsh-emacs--ml-busy t
                                        dsh-emacs--pending-attachments
                                        '(((name . "draft.txt"))))
                            (setq dsh-emacs--queue-items
                                  (list (dsh-protocol-queue-item--from-message
                                         '((id . "q")
                                           (content . [((type . "text") (text . "Next"))]))
                                         'queued)))
                            (set-process-filter proc t)
                            (goto-char dsh-emacs--input-marker)
                            (insert "Keep my draft")
                            (dsh-emacs-composer-refresh)
                            (let ((dsh-emacs-render--stream-batch-interval 3600)
                                  (event '((data . ((turn . "t") (step . "s"))))))
                              (dsh-emacs-render--start-assistant-stream event "Live")
                              (dsh-emacs-render--start-assistant-stream event " pending"))
                            (let ((map (symbol-value 'dsh-reload-test-map))
                                  (mode-map (current-local-map))
                                  (queue dsh-emacs--queue-items)
                                  (attachments dsh-emacs--pending-attachments)
                                  (marker dsh-emacs--input-marker)
                                  (stream dsh-emacs--streaming-assistant)
                                  (pending (plist-get dsh-emacs--streaming-assistant :pending))
                                  (stream-timer (plist-get dsh-emacs--streaming-assistant :timer))
                                  (before (buffer-string))
                                  (point-before (point))
                                  (hooks (copy-tree after-load-alist)))
                              (dotimes (_ 2) (dsh-emacs-reload))
                              (cl-assert (= (funcall 'dsh-reload-test-value) 2))
                              (cl-assert (= (symbol-value 'dsh-reload-test-state) 99))
                              (cl-assert (eq map (symbol-value 'dsh-reload-test-map)))
                              (cl-assert (null (lookup-key map (kbd "a"))))
                              (cl-assert (eq (lookup-key map (kbd "b")) #'ignore))
                              (cl-assert (eq mode-map (current-local-map)))
                              (cl-assert (equal (get 'dsh-reload-test-face 'face-defface-spec)
                                                '((t :foreground "green"))))
                              (cl-assert (equal (face-foreground 'dsh-reload-test-face nil t)
                                                "blue"))
                              (cl-assert (equal (buffer-string) before))
                              (cl-assert (= (point) point-before))
                              (cl-assert (eq dsh-emacs--input-marker marker))
                              (cl-assert (eq dsh-emacs--streaming-assistant stream))
                              (cl-assert (eq (plist-get stream :pending) pending))
                              (cl-assert (equal pending '(" pending")))
                              (cl-assert (equal (plist-get stream :chunks) '(" pending" "Live")))
                              (cl-assert (eq (plist-get stream :timer) stream-timer))
                              (cl-assert (memq stream-timer timer-list))
                              (cl-assert (eq dsh-emacs--queue-items queue))
                              (cl-assert (eq dsh-emacs--pending-attachments attachments))
                              (cl-assert (eq dsh-emacs--event-process proc))
                              (cl-assert (eq (process-filter proc) t))
                              (cl-assert (process-live-p proc))
                              (cl-assert (memq timer timer-list))
                              (cl-assert (eq dsh-emacs--ws-watchdog-timer timer))
                              (cl-assert dsh-emacs--event-ready)
                              (cl-assert dsh-emacs--ml-busy)
                              (cl-assert (equal dsh-emacs-base-url "http://example.invalid:9999"))
                              (cl-assert (equal dsh-emacs-server-auth-token "keep-auth"))
                              (dolist (feature '(nerd-icons doom-modeline-segments
                                                            nerd-icons-completion))
                                (cl-assert (equal (assq feature after-load-alist)
                                                  (assq feature hooks)))))
                            (dsh-emacs-render--flush-stream chat)
                            (cl-assert (string-match-p "Live pending" (buffer-string)))
                            (cl-assert (equal (dsh-emacs--get-input) "Keep my draft"))
                            (let ((dsh-emacs--history-loading t))
                              (cl-assert
                               (condition-case nil (progn (dsh-emacs-reload) nil)
                                 (user-error t))))
                            (with-temp-file fixture (insert "(defun broken ("))
                            (cl-assert
                             (condition-case err (progn (dsh-emacs-reload) nil)
                               (error (string-match-p "Cannot read"
                                                      (error-message-string err)))))
                            (cl-assert (= (funcall 'dsh-reload-test-value) 2))
                            (with-temp-file fixture
                              (insert "(require 'dsh-emacs-reload-fixture)\n"))
                            (cl-assert
                             (condition-case err (progn (dsh-emacs-reload) nil)
                               (error (string-match-p "Circular package require"
                                                      (error-message-string err)))))
                            (cl-assert (process-live-p proc)))
                        (set-process-filter proc nil)
                        (cancel-timer timer)
                        (kill-buffer chat)
                        (delete-process proc)))))))
            (ert-info ((with-current-buffer output (buffer-string)))
              (should (equal status 0)))))
      (kill-buffer output)
      (delete-directory copy t))))

(ert-deftest dsh-emacs-test-reload-completes-once-with-modeline-owner ()
  :tags '(dsh-unit)
  (let ((dsh-emacs-reload--finish-timer nil)
        (file (expand-file-name "dsh-emacs-reload.el"
                                dsh-emacs-reload--directory))
        (restores 0)
        (refreshes 0))
    (unwind-protect
        (cl-letf (((symbol-function 'dsh-emacs-reload--sources)
                   (lambda (_directory) (list file)))
                  ((symbol-function 'dsh-emacs-events-host-restore)
                   (lambda () (cl-incf restores)))
                  ((symbol-function 'dsh-emacs--composer-delete-guard-install)
                   #'ignore)
                  ((symbol-function 'dsh-emacs-composer-refresh) #'ignore)
                  ((symbol-function 'dsh-emacs-session--render) #'ignore)
                  ((symbol-function 'dsh-emacs-modeline-refresh)
                   (lambda () (cl-incf refreshes))))
          (dsh-emacs-reload)
          (should (= restores 1))
          (should (= refreshes 1))
          (should-not dsh-emacs-reload--finish-timer)
          (accept-process-output nil 0.01)
          (should (= restores 1))
          (should (= refreshes 1)))
      (when (timerp dsh-emacs-reload--finish-timer)
        (cancel-timer dsh-emacs-reload--finish-timer)))))

(ert-deftest dsh-emacs-test-reload-legacy-sockets-require-explicit-reconnect ()
  :tags '(dsh-unit)
  (dolist (kind '(chat core))
    (let ((process (make-pipe-process :name "pre-owner-socket" :noquery t))
          (restored nil))
      (unwind-protect
          (cl-letf (((symbol-function 'dsh-emacs-events-host-restore)
                     (lambda () (setq restored t)))
                    ((symbol-function 'dsh-emacs-composer-refresh) #'ignore)
                    ((symbol-function 'dsh-emacs-session--render) #'ignore)
                    ((symbol-function 'dsh-emacs-modeline-refresh) #'ignore))
            ;; This fixture intentionally has NO dsh-server-owner property.
            (process-put process (if (eq kind 'chat) 'dsh-emacs-chat-buffer
                                   'dsh-emacs-host-stream)
                         (if (eq kind 'chat) (current-buffer) t))
            (let ((err (should-error (dsh-emacs-reload--finish) :type 'user-error)))
              (should (string-match-p "disconnect" (error-message-string err))))
            (should-not restored)
            (should-not (process-get process 'dsh-server-owner))
            (should (process-live-p process)))
        (delete-process process)))))

(provide 'dsh-test-reload)
;;; dsh-test-reload.el ends here
