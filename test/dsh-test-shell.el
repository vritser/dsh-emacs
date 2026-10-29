;;; dsh-test-shell.el --- Shell tests -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "28.1"))

(require 'dsh-test-support)

;; --- Test 96e: a `!' line ⇒ local execution (bypassing session/prompt /
;; commands/execute) ---
(ert-deftest dsh-emacs-test-shell-submit-shell-runs-locally ()
  :tags '(dsh-unit)
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
            (ert-info ((format "%s" "submit-shell-runs-locally"))
              (should (equal "echo hi" (caar runs)))
              (should (eq buf (nth 1 (car runs))))
              (should (= parse-count 1))
              (should (null calls)))
            (ert-info ((format "%s" "submit-shell-records-history-once"))
              (should (= 1 (cl-count "!echo hi" dsh-emacs--input-history
                                     :test #'string=))))
            (setq calls nil runs nil parse-count 0)
            (dsh-emacs--replace-input "! ls -la")
            (dsh-emacs-send-or-stop)
            (ert-info ((format "%s" "interactive-shell-tolerates-space-and-parses-once"))
              (should (equal "ls -la" (caar runs)))
              (should (= parse-count 1))
              (should (equal "! ls -la" (car dsh-emacs--input-history)))
              (should (null calls)))
            ;; A bare `!' is a plain message (no command to execute)
            (setq calls nil runs nil dsh-emacs--input-history nil)
            (dsh-emacs--submit-prompt "!")
            (ert-info ((format "%s" "submit-bare-bang-is-plain-message"))
              (should (null runs))
              (should (equal "session/prompt" (caar calls))))
            ;; Submitting while busy (queue/steer) also executes locally and does not enter
            ;; the inbox
            (setq calls nil runs nil)
            (cl-letf (((symbol-function 'dsh-emacs--busy-p)
                       (lambda (&rest _) t)))
              (dsh-emacs--submit-prompt "!ls" nil 'queue))
            (ert-info ((format "%s" "submit-shell-runs-while-busy"))
              (should (equal "ls" (caar runs)))
              (should (null calls)))))
      (kill-buffer buf)
      (setq dsh-emacs--input-history old-hist
            dsh-emacs--input-history-pos old-pos))))

;; A ! caption with attachments is still model input; idle, queued, and steer all
;; keep the images.
(ert-deftest dsh-emacs-test-shell-shell-caption-keeps-attachment-case ()
  :tags '(dsh-unit)
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
            (ert-info ((format "%s" (format "shell-caption-keeps-attachment-%s" mode)))
              (should (null runs))
              (should (= (length calls) 1))
              (should (equal (caar calls) "session/prompt"))
              (should (equal (alist-get 'mode request) (if (eq mode 'steer) "steer" "queue")))
              (should (equal (alist-get 'content request)
                             [((type . "text") (text . "!describe this image"))
                              ((type . "image") (mediaType . "image/png")
                               (data . "cGljdHVyZQ==") (name . "picture.png"))])))))))))

;; A refused confirmation keeps the draft, history, and old process; an accepted
;; confirmation and the default no-confirm path submit only once.
(ert-deftest dsh-emacs-test-shell-shell-confirm-prompt-case ()
  :tags '(dsh-unit)
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
          (ert-info ((format "%s" (format "shell-confirm-prompt-%s" answer)))
            (should (equal prompts (unless (eq answer 'immediate)
                                     '("Run shell command: printf accepted? ")))))
          (if (eq answer 'decline)
              (ert-info ((format "%s" "shell-confirm-decline-preserves-input-and-history"))
                (should (equal (dsh-emacs--get-input) "!printf accepted"))
                (should (equal dsh-emacs--input-history '("older")))
                (should (equal dsh-emacs--input-history-pos 1))
                (should (equal dsh-emacs--input-history-pending "saved draft"))
                (should (null runs))
                (should (null killed)))
            (ert-info ((format "%s" (format "shell-confirm-submits-once-%s" answer)))
              (should (equal runs (list (list "printf accepted" (current-buffer)))))
              (should (equal (dsh-emacs--get-input) ""))
              (should (equal dsh-emacs--input-history '("!printf accepted" "older")))
              (should (null dsh-emacs--input-history-pos))
              (should (null dsh-emacs--input-history-pending))
              (should killed))))))))

;; The interactive entry point must recognize local commands before the server
;; probe and the busy-stop branch.
(ert-deftest dsh-emacs-test-shell-shell-interactive-offline-busy-case ()
  :tags '(dsh-unit)
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
          (ert-info ((format "%s" (format "shell-interactive-offline-busy-%s" busy)))
            (should (null failure))
            (should (null calls))
            (should (equal runs '(("!printf local" "printf local"))))))))
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
        (ert-info ((format "%s" "shell-interactive-bypasses-busy-stop"))
          (should (null calls))
          (should (equal runs '(("!printf local" "printf local")))))))))

;; --- Test 96f: `!' line parsing (pure function) ---
(ert-deftest dsh-emacs-test-shell-shell-parse-admission ()
  :tags '(dsh-unit)
  (ert-info ((format "%s" "shell-parse-admission"))
    (should (equal "echo hi" (dsh-emacs-shell-parse "!echo hi")))
    (should (equal "ls -la" (dsh-emacs-shell-parse "!   ls -la")))
    (should (equal "ls -la" (dsh-emacs-shell-parse " ! ls -la  ")))
    (should (equal "git status" (dsh-emacs-shell-parse "!git status")))
    (should (null (dsh-emacs-shell-parse "!")))
    (should (null (dsh-emacs-shell-parse "!   ")))
    (should (null (dsh-emacs-shell-parse "/compact")))
    (should (null (dsh-emacs-shell-parse "hi")))
    (should (null (dsh-emacs-shell-parse nil)))))

(ert-deftest dsh-emacs-test-shell-shell-parse-preserves-multiline-command ()
  :tags '(dsh-unit)
  (ert-info ((format "%s" "shell-parse-preserves-multiline-command"))
    (should (equal "printf first\nprintf second"
                   (dsh-emacs-shell-parse "!printf first\nprintf second")))
    (should (equal "cat <<'EOF'\n  indented body\nEOF"
                   (dsh-emacs-shell-parse "! cat <<'EOF'\n  indented body\nEOF")))))

;; --- Test 96g: real async execution of a `!' line: exit code + merged
;; stdout/stderr rendering ---
(ert-deftest dsh-emacs-test-shell-shell-run-finished-output-and-exit ()
  :tags '(dsh-unit)
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
              (ert-info ((format "%s" "shell-run-finished-output-and-exit"))
                (should (equal "test-shell-id" (car done)))
                (should (null (nth 1 done)))
                (should (equal 3 (nth 2 done)))
                (should (null (nth 3 done)))
                (should (equal "SHELLOKSHELLDOC\nSHELLERR" (nth 4 done)))))
            ;; exit 0 + very long output → truncated (max-output is bound before the run)
            (let ((dsh-emacs-shell-max-output 8))
              (setq done nil)
              (let* ((proc2 (with-current-buffer buf
                              (dsh-emacs-shell-run "printf abcdefghij" buf)))
                     (deadline (time-add (current-time) (seconds-to-time 8))))
                (while (and (null done)
                            (time-less-p (current-time) deadline))
                  (accept-process-output proc2 0.2))
                (ert-info ((format "%s" "shell-run-success-truncates-output"))
                  (should (eq t (nth 1 done)))
                  (should (equal 0 (nth 2 done)))
                  (should (and (string-prefix-p "abcdefgh" (nth 4 done))
                               (string-match-p "truncated" (nth 4 done)))))))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

;; stop/continue notifications do not mean exit: output, timeout, and tracking
;; are kept until it actually finishes.
(ert-deftest dsh-emacs-test-shell-shell-stopped-process-retains-resources ()
  :tags '(dsh-unit)
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
            (ert-info ((format "%s" "shell-stopped-process-retains-resources"))
              (should (eq (process-status proc) 'stop))
              (should (null done))
              (should (eq proc (cdr (assoc "id-stop-resume" dsh-emacs--shell-procs))))
              (should (buffer-live-p out-buffer))
              (should (memq timer timer-list)))
            (continue-process proc)
            (accept-process-output proc 0.1)
            (ert-info ((format "%s" "shell-continued-process-retains-resources"))
              (should (eq (process-status proc) 'run))
              (should (null done))
              (should (eq proc (cdr (assoc "id-stop-resume" dsh-emacs--shell-procs))))
              (should (buffer-live-p out-buffer))
              (should (memq timer timer-list)))
            (process-send-string proc "after")
            (process-send-eof proc)
            ;; Exit status can change before the sentinel releases resources.
            (let ((deadline (+ (float-time) 5)))
              (while (and (null done) (< (float-time) deadline))
                (accept-process-output nil 0.1)))
            (ert-info ((format "%s" "shell-resumed-process-finishes-once"))
              (should (equal done '(("id-stop-resume" t 0 nil "beforeafter"))))
              (should (null dsh-emacs--shell-procs))
              (should (not (buffer-live-p out-buffer)))
              (should (not (memq timer timer-list)))))
        (when (and proc (process-live-p proc)) (delete-process proc))
        (when timer (cancel-timer timer))
        (when (buffer-live-p out-buffer) (kill-buffer out-buffer))))))

;; --- Test 96h: `!' line rendering (start → done status coloring + body) ---
(ert-deftest dsh-emacs-test-shell-shell-row-tints-pending-header ()
  :tags '(dsh-unit)
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
            (ert-info ((format "%s" "shell-row-tints-pending-header"))
              (should (and block
                           (seq-every-p
                            (lambda (pos)
                              (memq 'dsh-emacs-tool-pending-face
                                    (ensure-list (get-text-property pos 'face))))
                            (number-sequence (car block) (1- (cdr block)))))))
            (dsh-emacs-render-shell-done id t 0 nil "nested output")
            (let ((text (buffer-substring-no-properties (point-min)
                                                        (point-max))))
              (ert-info ((format "%s" "shell-row-renders-outcome"))
                (should (string-match-p "echo hello" text))
                (should (string-match-p "✓ exit 0" text))
                (should (string-match-p "nested output" text))))
            (let* ((done-block (dsh-emacs-ui-find-block (nth 0 entry)
                                                        (nth 1 entry)))
                   (body-start (and done-block
                                    (save-excursion
                                      (goto-char (car done-block))
                                      (forward-line 1)
                                      (point)))))
              ;; Success coloring lands only on the header line and the output body must not
              ;; inherit it (the body must genuinely exist)
              (ert-info ((format "%s" "shell-row-tints-success-header-only"))
                (should (and done-block body-start (< body-start (cdr done-block))
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
                              (number-sequence body-start (1- (cdr done-block)))))))))
          ;; Failure path: non-zero exit → red status
          (let ((bad-id (dsh-emacs-render-shell-start "false")))
            (dsh-emacs-render-shell-done bad-id nil 1 nil "boom")
            (let ((text (buffer-substring-no-properties (point-min)
                                                        (point-max))))
              (ert-info ((format "%s" "shell-row-renders-failure"))
                (should (string-match-p "✗ exit 1" text))))))
      (kill-buffer buf))))

;; The same row under `simple': one state-colored dot, muted label and header,
;; with the dot carrying success/failure instead of the header tint.
(ert-deftest dsh-emacs-test-shell-simple-style-row-uses-dot-and-muted-text ()
  :tags '(dsh-unit)
  (let ((buf (generate-new-buffer " *dsh-shell-simple*"))
        (dsh-emacs-render-style 'simple))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-mode)
          (let* ((id (dsh-emacs-render-shell-start "echo hello"))
                 (entry (gethash id dsh-emacs--command-blocks))
                 (block (and entry (dsh-emacs-ui-find-block (nth 0 entry)
                                                            (nth 1 entry))))
                 (start (car block))
                 (text (and block (buffer-substring-no-properties
                                   start (cdr block)))))
            (ert-info ((format "%s" "simple-shell-row-uses-one-dot"))
              (should (string-match-p "● echo hello" text))
              (should (memq 'dsh-emacs-tool-icon-face
                            (dsh-test--faces-at start)))
              (should-not (memq 'dsh-emacs-tool-pending-face
                                (dsh-test--faces-at start)))
              ;; Label is muted in `simple', not the tool-title accent.
              (should (memq 'dsh-emacs-event-row-face
                            (dsh-test--faces-at (+ start 2))))
              (should-not (memq 'dsh-emacs-tool-title-face
                                (dsh-test--faces-at (+ start 2))))
              ;; No header tint in `simple': the dot alone carries pending.
              (should-not (seq-some (lambda (pos)
                                      (memq 'dsh-emacs-tool-pending-face
                                            (dsh-test--faces-at pos)))
                                    (number-sequence start (1- (cdr block))))))
            (dsh-emacs-render-shell-done id t 0 nil "nested output")
            (let* ((done-block (dsh-emacs-ui-find-block (nth 0 entry)
                                                        (nth 1 entry)))
                   (done-text (buffer-substring-no-properties
                               (car done-block) (cdr done-block)))
                   (status (+ (car done-block)
                              (string-match "✓ exit 0" done-text))))
              (ert-info ((format "%s" "simple-shell-row-dot-carries-success"))
                (should (string-match-p "● echo hello · ✓ exit 0"
                                        done-text))
                (should (memq 'dsh-emacs-tool-success-face
                              (dsh-test--faces-at (car done-block))))
                (should (memq 'dsh-emacs-timestamp-face
                              (dsh-test--faces-at status)))
                (should-not (memq 'dsh-emacs-tool-success-face
                                  (dsh-test--faces-at status)))
                ;; The outcome body keeps the muted label face, not success.
                (should-not (seq-some
                             (lambda (pos)
                               (memq 'dsh-emacs-tool-success-face
                                     (dsh-test--faces-at pos)))
                             (number-sequence
                              (save-excursion
                                (goto-char (car done-block))
                                (forward-line 1)
                                (point))
                              (1- (cdr done-block)))))))))
      (kill-buffer buf))))

;; Both an explicit cancel command and kill-buffer after explicitly installing
;; cleanup hooks release the process resources.
(ert-deftest dsh-emacs-test-shell-shell-process-cleanup-case ()
  :tags '(dsh-unit)
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
            ;; Dispatch pending sentinels even when PROC has already died.
            (let ((deadline (+ (float-time) 3)))
              (while (and (null done) (< (float-time) deadline))
                (accept-process-output nil 0.1)))
            (ert-info ((format "%s" (format "shell-process-cleanup-%s" action)))
              (should (not (process-live-p proc)))
              (should (not (buffer-live-p out-buffer)))
              (should (not (memq timer timer-list)))
              (should (= (length done) 1))
              (should (equal (caar done) "id-kill"))
              (should (null (nth 1 (car done))))
              (should (null (nth 2 (car done))))
              (should (integerp (nth 3 (car done)))))
            (when (eq action 'interrupt)
              (with-current-buffer buf
                (let (notice)
                  (cl-letf (((symbol-function 'message)
                             (lambda (format-string &rest args)
                               (setq notice (apply #'format format-string args)))))
                    (dsh-emacs-shell-process-kill))
                  (ert-info ((format "%s" "shell-process-kill-idle-reports-no-command"))
                    (should (null dsh-emacs--shell-procs))
                    (should (equal notice "No running shell command in this buffer")))))))
        (when (and proc (process-live-p proc)) (delete-process proc))
        (when timer (cancel-timer timer))
        (when (buffer-live-p buf) (kill-buffer buf))
        (when (buffer-live-p out-buffer) (kill-buffer out-buffer))))))

;; Reopening the chat calls mode again; switching mode must also clean up the
;; local process first.
(ert-deftest dsh-emacs-test-shell-shell-mode-cleanup-case ()
  :tags '(dsh-unit)
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
              (ert-info ((format "%s" (format "shell-mode-cleanup-%s" mode)))
                (should (not (process-live-p proc)))
                (should (not (buffer-live-p out-buffer)))
                (should (not (memq timer timer-list)))
                (should (null dsh-emacs--shell-procs))))
          (when (and proc (process-live-p proc)) (delete-process proc))
          (when timer (cancel-timer timer))
          (when (buffer-live-p out-buffer) (kill-buffer out-buffer)))))))

;; Even if the exit notification arrives after the chat buffer is destroyed, the
;; process resources must be released.
(ert-deftest dsh-emacs-test-shell-shell-dead-chat-releases-process-resources ()
  :tags '(dsh-unit)
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
          (ert-info ((format "%s" "shell-dead-chat-releases-process-resources"))
            (should (not (buffer-live-p out-buffer)))
            (should (not (memq timer timer-list)))
            (should (null rendered))))
      (when (and proc (process-live-p proc)) (delete-process proc))
      (when timer (cancel-timer timer))
      (when (buffer-live-p buf) (kill-buffer buf))
      (when (buffer-live-p out-buffer) (kill-buffer out-buffer)))))

;; --- Test 96i: closing stdin makes cat exit immediately, without relying on
;; shell redirection syntax ---
(ert-deftest dsh-emacs-test-shell-shell-null-stdin-eof-case ()
  :tags '(dsh-unit)
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
              (ert-info ((format "%s" (format "shell-null-stdin-eof-%s" shell)))
                (should (equal done '("id-cat" t 0 nil "")))
                (should (not (process-live-p proc)))))
          (when (and proc (process-live-p proc)) (delete-process proc))
          (when (buffer-live-p out-buffer) (kill-buffer out-buffer)))))))

;; --- Test 96j: submitting a new `!' command automatically terminates the
;; previous running command ---
(ert-deftest dsh-emacs-test-shell-shell-new-command-stops-previous ()
  :tags '(dsh-unit)
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
            (ert-info ((format "%s" "shell-new-command-stops-previous"))
              (should (and (gethash "id-0" done) (null (car (gethash "id-0" done)))))
              (should (equal (list t 0 nil) (gethash "id-1" done))))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

;; A nil command is a caller error and must be rejected before any submit side
;; effect.
(ert-deftest dsh-emacs-test-shell-shell-submit-rejects-nil-before-side-effects ()
  :tags '(dsh-unit)
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
        (ert-info ((format "%s" "shell-submit-rejects-nil-before-side-effects"))
          (should (equal failure '(error "Shell command must be non-nil")))
          (should (null effects))
          (should (equal (dsh-emacs--get-input) "!draft"))
          (should (equal dsh-emacs--input-history '("older")))
          (should (equal dsh-emacs--input-history-pos 1))
          (should (equal dsh-emacs--input-history-pending "saved draft")))))))

;; The timeout Custom type and both execution entry points reject non-positive
;; integers and do not clear the input.
(require 'wid-edit)

(ert-deftest dsh-emacs-test-shell-shell-timeout-custom-type ()
  :tags '(dsh-unit)
  (let ((widget (widget-convert (get 'dsh-emacs-shell-timeout 'custom-type))))
    (ert-info ((format "%s" "shell-timeout-custom-type"))
      (should (widget-apply widget :match nil))
      (should (widget-apply widget :match 1))
      (should (not (widget-apply widget :match 0)))
      (should (not (widget-apply widget :match -1)))
      (should (not (widget-apply widget :match 1.5))))))

(ert-deftest dsh-emacs-test-shell-shell-invalid-timeout-case-case ()
  :tags '(dsh-unit)
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
          (ert-info ((format "%s" (format "shell-invalid-timeout-%s-%s" entry value)))
            (should rejected)
            (should (null effects))))))))

;; --- Test 96k: timeout force-terminates (dsh-emacs-shell-timeout) ---
(ert-deftest dsh-emacs-test-shell-shell-timeout-kills-and-notes ()
  :tags '(dsh-unit)
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
              (ert-info ((format "%s" "shell-timeout-kills-and-notes"))
                (should (null (nth 1 done)))
                (should (string-match-p "timed out after 1 seconds"
                                        (nth 4 done)))))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(provide 'dsh-test-shell)
;;; dsh-test-shell.el ends here
