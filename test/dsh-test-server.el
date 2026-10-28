;;; dsh-test-server.el --- Server tests -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "28.1"))

(require 'dsh-test-support)

;; Load the E2E definitions without starting its real-server runner.
(let ((noninteractive nil))
  (load (expand-file-name "dsh-e2e.el" dsh-emacs-test-directory) nil t))

(ert-deftest dsh-emacs-test-server-e2e-saved-auth ()
  :tags '(dsh-unit)
  (let* ((file (make-temp-file "dsh-e2e-custom-" nil ".el"))
         (process-environment (copy-sequence process-environment))
         (dsh-emacs-base-url "http://127.0.0.1:3080")
         (custom-file file))
    (unwind-protect
        (progn
          (setenv "DSH_E2E_CUSTOM_FILE" nil)
          (dolist (case
                   '(("literal"
                      ((custom-set-variables
                        '(dsh-emacs-server-auth-token "saved-token")))
                      "saved-token")
                     ("no-eval"
                      ((error "must not execute config")
                       (custom-set-variables
                        '(dsh-emacs-server-auth-token "saved-token")))
                      "saved-token")
                     ("computed"
                      ((custom-set-variables
                        '(dsh-emacs-server-auth-token
                          (error "must not evaluate token"))))
                      nil)
                     ("empty"
                      ((custom-set-variables '(dsh-emacs-server-auth-token "")))
                      nil)
                     ("wrong-port"
                      ((custom-set-variables
                        '(dsh-emacs-base-url "http://127.0.0.1:9999")
                        '(dsh-emacs-server-auth-token "other-token")))
                      nil)
                     ("wrong-host"
                      ((custom-set-variables
                        '(dsh-emacs-base-url "http://elsewhere.test:3080")
                        '(dsh-emacs-server-auth-token "other-token")))
                      nil)
                     ("same-base"
                      ((custom-set-variables
                        '(dsh-emacs-base-url "http://127.0.0.1:3080/")
                        '(dsh-emacs-server-auth-token "saved-token")))
                      "saved-token")))
            (with-temp-file file
              (dolist (form (nth 1 case))
                (prin1 form (current-buffer))
                (terpri (current-buffer))))
            (let ((actual (condition-case err
                              (dsh-e2e--saved-auth-token)
                            (error (car err)))))
              (ert-info ((format "%s" (concat "e2e-saved-auth-" (car case))))
                (should (equal actual (nth 2 case))))))
          (with-temp-file file
            (insert "(custom-set-variables '(dsh-emacs-server-auth-token \"saved-token\"))"))
          (let ((dsh-emacs-base-url "https://remote.test"))
            (ert-info ((format "%s" "e2e-saved-auth-unscoped-token-stays-local"))
              (should (null (condition-case err (dsh-e2e--saved-auth-token)
                              (error (car err)))))))
          (setenv "DSH_E2E_CUSTOM_FILE" file)
          (let ((custom-file "/missing/ignored-custom.el"))
            (ert-info ((format "%s" "e2e-saved-auth-explicit-file-wins"))
              (should (equal (condition-case err (dsh-e2e--saved-auth-token)
                               (error (car err)))
                             "saved-token"))))
          (setenv "DSH_E2E_URL" nil)
          (dolist (case '((saved nil nil nil "saved-token")
                          (configured "configured-token" nil nil "configured-token")
                          (cookie nil "existing-cookie" nil nil)
                          (url nil nil "http://127.0.0.1:3080/?token=url-token" nil)))
            (let ((dsh-emacs-server-auth-token (nth 1 case))
                  (dsh-emacs--server-auth-cookie (nth 2 case))
                  (dsh-emacs-base-url (or (nth 3 case) dsh-emacs-base-url))
                  (dsh-emacs--interaction-active nil)
                  (dsh-emacs--question-queue nil)
                  (dsh-emacs--approval-queue nil)
                  (dsh-emacs-sessions-buffer " *dsh-e2e-auth-test*")
                  observed)
              (cl-letf (((symbol-function 'dsh-emacs--server-auth-token)
                         (lambda () dsh-emacs-server-auth-token))
                        ((symbol-function 'dsh-e2e--rpc)
                         (lambda (&rest _)
                           (setq observed dsh-emacs-server-auth-token)
                           (throw 'dsh-e2e-auth-ready t))))
                (catch 'dsh-e2e-auth-ready (dsh-emacs-e2e-run)))
              (ert-info ((format "%s" (format "e2e-auth-before-rpc-%s" (car case))))
                (should (equal observed (nth 4 case)))
                (should (equal dsh-emacs-server-auth-token (nth 1 case))))))
          (with-temp-file file (insert "(custom-set-variables 'broken"))
          (let ((detail (condition-case err
                            (progn (dsh-e2e--saved-auth-token) nil)
                          (error (error-message-string err)))))
            (ert-info ((format "%s" "e2e-saved-auth-malformed-file-reports-safe-error"))
              (should (stringp detail))
              (should (string-match-p "Cannot read E2E auth settings" (or detail "")))
              (should (not (string-match-p "broken" (or detail "")))))))
      (delete-file file))))

(ert-deftest dsh-emacs-test-server-dsh-emacs-server-loaded ()
  :tags '(dsh-unit)
  (ert-info ((format "%s" "dsh-emacs-server loaded"))
    (should (featurep 'dsh-emacs-server))))

;; --- Test 79: server bootstrap: base-url -> (host . port) parsing ---
(ert-deftest dsh-emacs-test-server-server-host-port-parses-default-url ()
  :tags '(dsh-unit)
  (let ((dsh-emacs-base-url "http://127.0.0.1:3080"))
    (let ((hp (dsh-emacs--server-host-port)))
      (ert-info ((format "%s" "server-host-port-parses-default-url"))
        (should (and (equal "127.0.0.1" (car hp)) (= 3080 (cdr hp))))))))

(ert-deftest dsh-emacs-test-server-server-host-port-parses-custom-host-port ()
  :tags '(dsh-unit)
  (let ((dsh-emacs-base-url "http://localhost:9999"))
    (let ((hp (dsh-emacs--server-host-port)))
      (ert-info ((format "%s" "server-host-port-parses-custom-host-port"))
        (should (and (equal "localhost" (car hp)) (= 9999 (cdr hp))))))))

(ert-deftest dsh-emacs-test-server-server-host-port-defaults-to-80 ()
  :tags '(dsh-unit)
  (let ((dsh-emacs-base-url "http://127.0.0.1"))
    (ert-info ((format "%s" "server-host-port-defaults-to-80"))
      (should (= 80 (cdr (dsh-emacs--server-host-port)))))))

;; --- Test 80: alive probe has a short cache (no re-probe within the TTL) ---
(ert-deftest dsh-emacs-test-server-server-alive-cached-within-ttl ()
  :tags '(dsh-unit)
  (let ((dsh-emacs--server-alive-check nil)
        (probes 0))
    (setq dsh-emacs--server-alive-check nil)
    (cl-letf (((symbol-function 'dsh-emacs--server-probe)
               (lambda () (setq probes (1+ probes)) t)))
      (dsh-emacs--server-alive-p)
      (dsh-emacs--server-alive-p)
      (ert-info ((format "%s" "server-alive-cached-within-ttl"))
        (should (= 1 probes)))
      (dsh-emacs--server-invalidate-alive)
      (dsh-emacs--server-alive-p)
      (ert-info ((format "%s" "server-alive-invalidate-reprobes"))
        (should (= 2 probes))))
    (setq dsh-emacs--server-alive-check nil)))

;; Server readiness must neither block nor start a remote/failed server loop.
(ert-deftest dsh-emacs-test-server-readiness-returns-before-http-response ()
  :tags '(dsh-unit)
  (dolist (scenario '(ready auth stale challenge challenge-timeout startup
                            restart-token failed-start remote timeout closed changed
                            install-ready install-timeout install-closed
                            install-changed install-concurrent))
    (let ((noninteractive nil)
          (dsh-emacs-base-url "http://127.0.0.1:3080")
          (dsh-emacs--server-alive-check nil)
          (dsh-emacs--server-auth-cookie (and (eq scenario 'stale) "old-cookie"))
          (dsh-emacs-server-auth-token
           (cond ((eq scenario 'restart-token) "old-token")
                 ((memq scenario '(auth stale)) "unit+test")))
          (dsh-emacs--server-process nil)
          (dsh-emacs-server-auto-start t)
          (origin (generate-new-buffer " *async-ready-test*"))
          (responses nil)
          (timers nil)
          (launches 0)
          (prompts 0)
          (remembered nil)
          (alive t)
          (result nil))
      (unwind-protect
          (cl-letf (((symbol-function 'dsh-emacs--server-probe)
                     (lambda () (error "Blocking readiness probe")))
                    ((symbol-function 'dsh-emacs--server-auth-token)
                     (lambda () dsh-emacs-server-auth-token))
                    ((symbol-function 'dsh-emacs--server-local-host-p)
                     (lambda () (not (eq scenario 'remote))))
                    ((symbol-function 'dsh-emacs-server--basic-auth-header) #'ignore)
                    ((symbol-function 'url-retrieve)
                     (lambda (url callback &rest _)
                       (let ((buf (generate-new-buffer " *async-http-test*")))
                         (push (list buf callback url) responses)
                         buf)))
                    ((symbol-function 'run-at-time)
                     (lambda (_delay _repeat function &rest args)
                       (push (cons function args) timers)
                       'test-timer))
                    ((symbol-function 'cancel-timer) #'ignore)
                    ((symbol-function 'read-string)
                     (lambda (&rest _)
                       (cl-incf prompts)
                       (when (eq scenario 'challenge-timeout)
                         (apply (caar timers) (cdar timers)))
                       "entered-token"))
                    ((symbol-function 'dsh-emacs--server-auth-remember-token)
                     (lambda (value) (setq remembered value)))
                    ((symbol-function 'dsh-emacs--server-bin)
                     (lambda ()
                       (unless (memq scenario '(install-ready install-timeout
                                                              install-closed install-changed
                                                              install-concurrent))
                         "/dsh")))
                    ((symbol-function 'dsh-emacs--server-ensure-installed)
                     (lambda ()
                       ;; Installation yields to timers and user input.
                       (pcase scenario
                         ('install-timeout (apply (caar timers) (cdar timers)))
                         ('install-closed (kill-buffer origin))
                         ('install-changed
                          (setq dsh-emacs-base-url "http://different-server:3080"))
                         ('install-concurrent
                          (setq dsh-emacs--server-process 'test-process)))
                       "/installed/dsh"))
                    ((symbol-function 'dsh-emacs--server-launch)
                     (lambda (&rest _)
                       (setq launches (1+ launches)
                             dsh-emacs--server-process 'test-process)))
                    ((symbol-function 'process-live-p)
                     (lambda (proc) (and alive (eq proc 'test-process)))))
            (cl-labels ((respond (code &optional cookie)
                          (pcase-let ((`(,buf ,callback ,_url) (car responses)))
                            (with-current-buffer buf
                              (setq-local url-http-response-status code)
                              (insert (format "HTTP/1.1 %s Test\r\n" (or code 0)))
                              (when cookie
                                (insert "Set-Cookie: " cookie "; Path=/\r\n"))
                              (insert "\r\n")
                              (funcall callback nil)))))
              (with-current-buffer origin
                (dsh-emacs-server-ensure-async
                 (lambda (reason) (push reason result))))
              (ert-info ((format "%s" "readiness-returns-before-http-response"))
                (should (null result))
                (should (= (length responses) 1))
                (should (zerop launches)))
              (pcase scenario
                ((or 'install-ready 'install-timeout 'install-closed
                     'install-changed 'install-concurrent)
                 (respond nil)
                 (ert-info ((format "%s" (format "readiness-after-%s" scenario)))
                   (should (if (memq scenario '(install-ready install-concurrent))
                               (and (null result) (= (length timers) 2)
                                    (= launches (if (eq scenario 'install-ready) 1 0)))
                             (and (zerop launches) (= (length timers) 1)
                                  (equal result
                                         (pcase scenario
                                           ('install-timeout
                                            '("dsh server readiness timed out"))
                                           ('install-changed
                                            '("Server changed during startup"))
                                           ('install-closed nil)))))))
                 (when (memq scenario '(install-ready install-concurrent))
                   (apply (caar timers) (cdar timers))
                   (respond 200)
                   (ert-info ((format "%s" (format "readiness-completes-after-%s" scenario)))
                     (should (equal result '(nil)))))
                 ;; Cancel a faulty implementation before restoring timer mocks.
                 (when (buffer-live-p origin) (kill-buffer origin)))
                ('ready
                 (respond 200)
                 (ert-info ((format "%s" "readiness-http-success"))
                   (should (equal result '(nil)))))
                ('auth
                 (ert-info ((format "%s" "readiness-encodes-launch-token"))
                   (should (string-suffix-p "?token=unit%2Btest" (nth 2 (car responses)))))
                 (respond 303 "dsh-auth-unit=cookie")
                 (ert-info ((format "%s" "readiness-mints-cookie-asynchronously"))
                   (should (equal result '(nil)))
                   (should (equal dsh-emacs--server-auth-cookie "dsh-auth-unit=cookie"))))
                ('stale
                 (respond 401)
                 (ert-info ((format "%s" "readiness-stale-cookie-exchanges-known-token"))
                   (should (null result))
                   (should (= (length responses) 2))
                   (should (string-suffix-p "?token=unit%2Btest" (nth 2 (car responses)))))
                 (respond 303 "dsh-auth-unit=fresh")
                 (ert-info ((format "%s" "readiness-stale-cookie-does-not-prompt"))
                   (should (equal result '(nil)))
                   (should (null remembered))))
                ('challenge-timeout
                 (respond 401)
                 (ert-info ((format "%s" "readiness-timeout-during-prompt-stops-exchange"))
                   (should (string-match-p "timed out" (car result)))
                   (should (= (length responses) 1))))
                ('challenge
                 (respond 401)
                 (ert-info ((format "%s" "readiness-token-prompt-retries-exchange"))
                   (should (null result))
                   (should (= (length responses) 2))
                   (should (string-suffix-p "?token=entered-token" (nth 2 (car responses)))))
                 (respond 303 "dsh-auth-unit=entered")
                 (ert-info ((format "%s" "readiness-remembers-successful-entered-token"))
                   (should (equal result '(nil)))
                   (should (equal remembered "entered-token"))))
                ('restart-token
                 (respond nil)
                 (apply (caar timers) (cdar timers))
                 ;; The new process is still booting; its launch token arrives
                 ;; after this poll has already reused the configured old one.
                 (ert-info ((format "%s" "readiness-restart-polls-before-token-arrives"))
                   (should (= launches 1))
                   (should (null result))
                   (should (string-suffix-p "?token=old-token" (nth 2 (car responses)))))
                 (respond nil)
                 (setq dsh-emacs-server-auth-token "fresh-token")
                 (apply (caar timers) (cdar timers))
                 (if (string-suffix-p "?token=fresh-token" (nth 2 (car responses)))
                     (respond 303 "dsh-auth-unit=fresh")
                   (respond 401)
                   (respond 401))
                 (ert-info ((format "%s" "readiness-restart-uses-fresh-token-without-prompt"))
                   (should (equal result '(nil)))
                   (should (= launches 1))
                   (should (zerop prompts))
                   (should (equal dsh-emacs--server-auth-cookie "dsh-auth-unit=fresh"))))
                ((or 'startup 'failed-start)
                 (respond nil)
                 (ert-info ((format "%s" "readiness-starts-without-blocking"))
                   (should (= launches 1))
                   (should (null result)))
                 (apply (caar timers) (cdar timers))
                 (if (eq scenario 'startup)
                     (progn
                       (respond 200)
                       (ert-info ((format "%s" "readiness-polls-until-started"))
                         (should (equal result '(nil)))
                         (should (= launches 1))))
                   (setq alive nil)
                   (respond nil)
                   (ert-info ((format "%s" "readiness-does-not-relaunch-exited-server"))
                     (should (= launches 1))
                     (should (string-match-p "exited" (car result))))))
                ('remote
                 (respond nil)
                 (ert-info ((format "%s" "readiness-never-starts-local-server-for-remote"))
                   (should (zerop launches))
                   (should (stringp (car result)))))
                ('timeout
                 (apply (caar timers) (cdar timers))
                 (ert-info ((format "%s" "readiness-timeout-cleans-request"))
                   (should (string-match-p "timed out" (car result)))
                   (should (not (buffer-live-p (caar responses))))))
                ('closed
                 (kill-buffer origin)
                 (ert-info ((format "%s" "readiness-close-cancels-without-callback"))
                   (should (null result))
                   (should (not (buffer-live-p (caar responses))))))
                ('changed
                 (setq dsh-emacs-base-url "http://different-server:3080")
                 (respond 303 "dsh-auth-unit=wrong-server")
                 (ert-info ((format "%s" "readiness-server-change-discards-cookie"))
                   (should (string-match-p "changed" (car result)))
                   (should (null dsh-emacs--server-auth-cookie))
                   (should (null dsh-emacs--server-alive-check)))))))
        (dolist (buf (cons origin (mapcar #'car responses)))
          (when (buffer-live-p buf) (kill-buffer buf)))))))

;; --- Test 81: ensure is always a no-op under batch (noninteractive) ---
(ert-deftest dsh-emacs-test-server-server-ensure-noop-in-batch ()
  :tags '(dsh-unit)
  (let ((started 0)
        (noninteractive t))
    (cl-letf (((symbol-function 'dsh-emacs--server-alive-p) (lambda () nil))
              ((symbol-function 'dsh-emacs-server-start)
               (lambda (&optional _wait) (setq started (1+ started)))))
      (dsh-emacs-server-ensure))
    (ert-info ((format "%s" "server-ensure-noop-in-batch"))
      (should (= 0 started)))))

;; --- Test 82: ensure interactive path: server already ready -> do not start ---
(ert-deftest dsh-emacs-test-server-server-ensure-alive-skips-start ()
  :tags '(dsh-unit)
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
    (ert-info ((format "%s" "server-ensure-alive-skips-start"))
      (should (= 0 started)))))

;; --- Test 83: ensure interactive path: down + auto-start -> start is called ---
(ert-deftest dsh-emacs-test-server-server-ensure-down-starts-server ()
  :tags '(dsh-unit)
  (let ((started 0)
        (noninteractive nil))
    (cl-letf (((symbol-function 'dsh-emacs--server-alive-p) (lambda () nil))
              ((symbol-function 'dsh-emacs-server-start)
               (lambda (&optional _wait) (setq started (1+ started)))))
      (dsh-emacs-server-ensure))
    (ert-info ((format "%s" "server-ensure-down-starts-server"))
      (should (= 1 started)))))

;; --- Test 84: ensure interactive path: auto-start nil -> user-error with guidance ---
(ert-deftest dsh-emacs-test-server-server-ensure-auto-start-nil-errors ()
  :tags '(dsh-unit)
  (let ((dsh-emacs-server-auto-start nil)
        (noninteractive nil))
    (cl-letf (((symbol-function 'dsh-emacs--server-alive-p) (lambda () nil)))
      (let ((err (should-error (dsh-emacs-server-ensure) :type 'user-error)))
        (ert-info ((format "%s" "server-ensure-auto-start-nil-errors"))
          (should (string-match-p "not reachable" (error-message-string err))))))))

;; --- Test 84b: remote base-url + down -> no start / no CLI install, report
;; unreachable ---
(ert-deftest dsh-emacs-test-server-server-ensure-remote-no-start ()
  :tags '(dsh-unit)
  (let* ((dsh-emacs-base-url "http://dsh-remote.example:3080")
         (noninteractive nil)
         (started 0))
    (cl-letf (((symbol-function 'dsh-emacs--server-alive-p) (lambda () nil))
              ((symbol-function 'dsh-emacs-server-start)
               (lambda (&optional _wait) (setq started (1+ started)))))
      (let ((err (should-error (dsh-emacs-server-ensure) :type 'user-error)))
        (ert-info ((format "%s" "server-ensure-remote-no-start"))
          (should (and (= 0 started)   ; A remote host never goes through local startup
                       (string-match-p "not reachable" (error-message-string err))
                       (string-match-p "remote" (error-message-string err)))))))))

;; --- Test 84c: local/remote host determination ---
(ert-deftest dsh-emacs-test-server-server-local-host-loopback ()
  :tags '(dsh-unit)
  (let ((dsh-emacs-base-url "http://127.0.0.1:3080")
        (noninteractive nil))
    (ert-info ((format "%s" "server-local-host-loopback"))
      (should (dsh-emacs--server-local-host-p)))))

(ert-deftest dsh-emacs-test-server-server-local-host-localhost ()
  :tags '(dsh-unit)
  (let ((dsh-emacs-base-url "http://localhost:3080")
        (noninteractive nil))
    (ert-info ((format "%s" "server-local-host-localhost"))
      (should (dsh-emacs--server-local-host-p)))))

(ert-deftest dsh-emacs-test-server-server-local-host-remote-false ()
  :tags '(dsh-unit)
  (let ((dsh-emacs-base-url "http://dsh-remote.example:3080")
        (noninteractive nil))
    (ert-info ((format "%s" "server-local-host-remote-false"))
      (should (not (dsh-emacs--server-local-host-p))))))

;; IPv6 loopback: url-host carries brackets ("[::1]"), host-name strips them, local
(ert-deftest dsh-emacs-test-server-server-local-host-ipv6-loopback ()
  :tags '(dsh-unit)
  (let ((dsh-emacs-base-url "http://[::1]:3080")
        (noninteractive nil))
    (ert-info ((format "%s" "server-local-host-ipv6-loopback"))
      (should (and (equal "::1" (dsh-emacs--server-host-name))
                   (dsh-emacs--server-local-host-p))))))

;; Private network IP: non-loopback host -> judged remote
(ert-deftest dsh-emacs-test-server-server-local-host-private-ip-remote ()
  :tags '(dsh-unit)
  (let ((dsh-emacs-base-url "http://192.168.1.100:3080")
        (noninteractive nil))
    (ert-info ((format "%s" "server-local-host-private-ip-remote"))
      (should (not (dsh-emacs--server-local-host-p))))))

;; --- Test 84d: remote base-url + start-on-init -> do not spawn a local server ---
(ert-deftest dsh-emacs-test-server-server-remote-init-no-spawn ()
  :tags '(dsh-unit)
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
    (ert-info ((format "%s" "server-remote-init-no-spawn"))
      (should (= 0 spawned)))))

;; --- Test 84e: nginx basic auth -- auth header when base-url carries
;; userinfo ---
(ert-deftest dsh-emacs-test-server-server-basic-auth-header-built ()
  :tags '(dsh-unit)
  (let ((dsh-emacs-base-url "http://alice:secret@dsh-remote.example:3080"))
    (let ((hdr (dsh-emacs-server--basic-auth-header)))
      (ert-info ((format "%s" "server-basic-auth-header-built"))
        (should (and (equal "Authorization" (car hdr))
                     (equal (concat "Basic "
                                    (base64-encode-string "alice:secret" t))
                            (cdr hdr))))))))

(ert-deftest dsh-emacs-test-server-server-no-auth-header-without-userinfo ()
  :tags '(dsh-unit)
  (let ((dsh-emacs-base-url "http://dsh-remote.example:3080"))
    (ert-info ((format "%s" "server-no-auth-header-without-userinfo"))
      (should (null (dsh-emacs-server--basic-auth-header))))))

;; --- Test 84f: WebSocket handshake carries the Basic auth header (nginx basic auth) ---
(ert-deftest dsh-emacs-test-server-server-websocket-handshake-carries-basic-auth ()
  :tags '(dsh-unit)
  (let ((dsh-emacs-base-url "http://alice:secret@127.0.0.1:3080")
        (sent nil))
    (cl-letf (((symbol-function 'dsh-emacs-events--random-mask)
               (lambda () (apply #'unibyte-string (list 1 2 3 4))))
              ((symbol-function 'process-send-string)
               (lambda (_proc string) (setq sent string))))
      (dsh-emacs-events--send-handshake
       (make-pipe-process :name "ws-test" :buffer (get-buffer-create " *ws*"))))
    (ert-info ((format "%s" "server-websocket-handshake-carries-basic-auth"))
      (should (and sent
                   (string-match-p "Authorization: Basic [A-Za-z0-9+/=]+" sent))))))

;; --- Test 84g: HTTPS base-url probe goes through the url library (TLS) path ---
(ert-deftest dsh-emacs-test-server-server-probe-https-dispatch ()
  :tags '(dsh-unit)
  (let ((dsh-emacs-base-url "https://probe.example:443")
        (noninteractive nil))
    (cl-letf (((symbol-function 'dsh-emacs--server-probe-https)
               (lambda () t))
              ((symbol-function 'dsh-emacs--server-probe-plain)
               (lambda () (error "plain probe must not run for https"))))
      (ert-info ((format "%s" "server-probe-https-dispatch"))
        (should (dsh-emacs--server-probe))))))

(ert-deftest dsh-emacs-test-server-server-probe-http-dispatch ()
  :tags '(dsh-unit)
  (let ((dsh-emacs-base-url "http://probe.example:3080")
        (noninteractive nil))
    (cl-letf (((symbol-function 'dsh-emacs--server-probe-https)
               (lambda () (error "https probe must not run for http")))
              ((symbol-function 'dsh-emacs--server-probe-plain)
               (lambda () t)))
      (ert-info ((format "%s" "server-probe-http-dispatch"))
        (should (dsh-emacs--server-probe))))))

;; --- Test 84h: https probe has a bounded timeout; empty return keeps the buffer ---
;;
;; When url-retrieve-synchronously returns nil (timeout/refusal), the probe returns
;; nil, and must not delete the caller's current buffer via (kill-buffer nil).
(ert-deftest dsh-emacs-test-server-server-probe-https-timeout-nil-safe ()
  :tags '(dsh-unit)
  (let ((dsh-emacs-base-url "https://probe.example:443")
        (victim (generate-new-buffer " *probe-victim*")))
    (unwind-protect
        (with-current-buffer victim
          (cl-letf (((symbol-function 'url-retrieve-synchronously)
                     (lambda (&rest _) nil)))   ; Simulate a timeout returning nil
            (let ((result (condition-case e
                              (dsh-emacs--server-probe-https)
                            (error (list :err e)))))
              (ert-info ((format "%s" "server-probe-https-timeout-nil-safe"))
                (should (and (null result)
                             (eq (current-buffer) victim)
                             (buffer-live-p victim)))))))
      (kill-buffer victim))))

;; --- Test 84i: HTTPS probe does not ask Basic credentials on a 401 before the
;; token exchange ---
;; Use url's real auth handling: dsh has no WWW-Authenticate, so url falls back to Basic.
(require 'url-http)

(require 'url-auth)

(ert-deftest dsh-emacs-test-server-server-probe-https-case-alive-without-basic-prompt ()
  :tags '(dsh-unit)
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
                   (push (list type prompt
                               (not (or url-request-noninteractive
                                        url-http-noninteractive)))
                         challenges)
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
            (ert-info ((format "%s" (format "server-probe-https-%s-alive-without-basic-prompt" status)))
              (should (dsh-emacs--server-probe-https))
              (should (equal challenges (and (equal status "401") '(("basic" t nil)))))
              (should (not (buffer-live-p response))))
          (when (buffer-live-p response) (kill-buffer response)))))))

;; --- Test 85: install flow: accept -> run the install and return the dsh path ---
(ert-deftest dsh-emacs-test-server-server-install-accepted-runs-install ()
  :tags '(dsh-unit)
  (cl-letf (((symbol-function 'dsh-emacs--server-bin) (lambda () nil))
            ((symbol-function 'y-or-n-p) (lambda (_prompt) t))
            ((symbol-function 'dsh-emacs--server-run-install)
             (lambda () "/usr/bin/dsh")))
    (ert-info ((format "%s" "server-install-accepted-runs-install"))
      (should (equal "/usr/bin/dsh" (dsh-emacs--server-ensure-installed))))))

;; --- Test 86: install flow: decline -> user-error with manual guidance ---
(ert-deftest dsh-emacs-test-server-server-install-declined-errors ()
  :tags '(dsh-unit)
  (cl-letf (((symbol-function 'dsh-emacs--server-bin) (lambda () nil))
            ((symbol-function 'y-or-n-p) (lambda (_prompt) nil)))
    (let ((err (should-error (dsh-emacs--server-ensure-installed) :type 'user-error)))
      (ert-info ((format "%s" "server-install-declined-errors"))
        (should (string-match-p "manually" (error-message-string err)))))))

;; --- Test 87: server-start: already ready -> do not launch a process ---
(ert-deftest dsh-emacs-test-server-server-start-alive-does-not-spawn ()
  :tags '(dsh-unit)
  (let ((commands nil))
    (cl-letf (((symbol-function 'dsh-emacs--server-alive-p) (lambda () t))
              ((symbol-function 'dsh-emacs--server-auth-ensure-interactive)
               ;; Test only server-start's start control flow; auth gating is tested
               ;; separately.
               (lambda () t))
              ((symbol-function 'make-process)
               (lambda (&rest args) (push args commands) 'fake-proc)))
      (dsh-emacs-server-start))
    (ert-info ((format "%s" "server-start-alive-does-not-spawn"))
      (should (null commands)))))

;; --- Test 88: server-start: down -> launch dsh web at base-url's host/port ---
(ert-deftest dsh-emacs-test-server-server-start-spawns-dsh-web-with-base-url-args ()
  :tags '(dsh-unit)
  (let ((dsh-emacs--server-process nil)
        (dsh-emacs--server-alive-check nil)
        (dsh-emacs--server-auth-cookie nil)
        (dsh-emacs--server-auth-captured-token nil)
        (commands nil)
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
    (ert-info ((format "%s" "server-start-spawns-dsh-web-with-base-url-args"))
      (should (= 1 waits))
      (should (equal '("/usr/bin/dsh" "web" "--host" "127.0.0.1"
                       "--port" "3080" "--no-open")
                     (plist-get (car commands) :command))))
    (setq dsh-emacs--server-process nil)))

;; --- Test 89: wait-ready: server already ready -> return t immediately ---
(ert-deftest dsh-emacs-test-server-server-wait-ready-alive-returns-t ()
  :tags '(dsh-unit)
  (cl-letf (((symbol-function 'dsh-emacs--server-alive-p) (lambda () t)))
    (ert-info ((format "%s" "server-wait-ready-alive-returns-t"))
      (should (eq t (dsh-emacs--server-wait-ready))))))

;; --- Test 89b: list-sessions polls for the grace period a blocking start
;; would use, not a fixed few seconds ---
;; A cold `dsh web' boot composes the profile and loads the whole plugin tree
;; (measured ~4.5 s here), so a hardcoded 5 s window loses the race.  The
;; deadline must derive from `dsh-emacs-server-wait-seconds'.
(ert-deftest dsh-emacs-test-server-list-sessions-waits-the-configured-grace-period ()
  :tags '(dsh-unit)
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
    (ert-info ((format "%s" "list-sessions-waits-the-configured-grace-period"))
      (should (equal deadline 1030.0)))))

;; --- Test 89d: auto-start nil refuses the automatic list path instead of
;; launching or offering to install anything ---
(ert-deftest dsh-emacs-test-server-list-sessions-honours-auto-start-nil ()
  :tags '(dsh-unit)
  (let ((dsh-emacs-server-auto-start nil)
        (dsh-emacs--server-process nil)
        (fetched nil))
    (cl-letf (((symbol-function 'dsh-emacs--server-alive-p) (lambda () nil))
              ((symbol-function 'dsh-emacs--server-bin) (lambda () nil))
              ((symbol-function 'y-or-n-p)
               (lambda (&rest _) (error "PROMPTED")))
              ((symbol-function 'dsh-emacs-list-sessions--fetch)
               (lambda () (setq fetched t)))
              ((symbol-function 'dsh-emacs-list-sessions--fetch-when-ready)
               (lambda (&rest _) (setq fetched t))))
      (let ((err (should-error (dsh-emacs-list-sessions) :type 'user-error)))
        (ert-info ((format "%s" "list-sessions-honours-auto-start-nil"))
          (should-not fetched)
          (should (string-match-p "not reachable" (error-message-string err)))
          (should (string-match-p "M-x dsh-emacs-server-start"
                                  (error-message-string err))))))))

;; --- Test 89e: a reachable server still serves the list with auto-start nil ---
(ert-deftest dsh-emacs-test-server-list-sessions-fetches-when-alive-with-auto-start-nil ()
  :tags '(dsh-unit)
  (let ((dsh-emacs-server-auto-start nil)
        (dsh-emacs--server-process nil)
        (fetched nil))
    (cl-letf (((symbol-function 'dsh-emacs--server-alive-p) (lambda () t))
              ((symbol-function 'dsh-emacs--server-auth-ensure-interactive)
               #'ignore)
              ((symbol-function 'dsh-emacs-list-sessions--fetch)
               (lambda () (setq fetched t))))
      (dsh-emacs-list-sessions))
    (ert-info ((format "%s" "list-sessions-fetches-when-alive-with-auto-start-nil"))
      (should fetched))))

;; --- Test 89c: the non-blocking poll keeps retrying while the deadline
;; remains, and reports the timeout instead of scheduling once it passed ---
(ert-deftest dsh-emacs-test-server-server-ready-poll-keeps-waiting-past-five-seconds ()
  :tags '(dsh-unit)
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
      (ert-info ((format "%s" "server-ready-poll-keeps-waiting-past-five-seconds"))
        (should (= 1 scheduled))
        (should (null reported)))
      ;; Past the deadline: report, do not schedule another attempt.
      (setq scheduled 0
            now 31.0
            reported nil)
      (dsh-emacs-list-sessions--fetch-when-ready 30.0)
      (ert-info ((format "%s" "server-ready-poll-reports-the-timeout"))
        (should (= 0 scheduled))
        (should (and (stringp reported)
                     (string-match-p "did not become ready" reported)))))))

;; --- Test 90: clean up the managed process when Emacs exits ---
(ert-deftest dsh-emacs-test-server-server-teardown-registered-on-kill-emacs-hook ()
  :tags '(dsh-unit)
  (ert-info ((format "%s" "server-teardown-registered-on-kill-emacs-hook"))
    (should (memq 'dsh-emacs-server--teardown kill-emacs-hook))))

;; --- Test 91: command-body guardrail -- error with guidance when the server is
;; unreachable ---
;; The guardrail is in `dsh-emacs-server-ensure' (the entry point of commands such
;; as switch-session).  `dsh-emacs-list-sessions' has its own guard for its
;; non-blocking auto-start path; see test 89d.
(ert-deftest dsh-emacs-test-server-list-sessions-guard-fails-with-guidance ()
  :tags '(dsh-unit)
  (let ((dsh-emacs-server-auto-start nil)
        (noninteractive nil))
    (cl-letf (((symbol-function 'dsh-emacs--server-alive-p) (lambda () nil)))
      (let ((err (should-error (dsh-emacs-server-ensure) :type 'user-error)))
        (ert-info ((format "%s" "list-sessions-guard-fails-with-guidance"))
          (should (string-match-p "not reachable" (error-message-string err)))
          (should (string-match-p "M-x dsh-emacs-server-start"
                                  (error-message-string err))))))))

;; --- Test 92: open-web opens dsh web (base-url; settings is a popup, no subroute) ---
(ert-deftest dsh-emacs-test-server-open-web-opens-web-ui-root ()
  :tags '(dsh-unit)
  (let ((dsh-emacs-base-url "http://127.0.0.1:3080")
        (opened nil))
    (cl-letf (((symbol-function 'browse-url)
               (lambda (url) (setq opened url))))
      (dsh-emacs-open-web))
    (ert-info ((format "%s" "open-web-opens-web-ui-root"))
      (should (equal "http://127.0.0.1:3080" opened)))))

;; --- Test 93: open-web is likewise protected by the server guardrail ---
(ert-deftest dsh-emacs-test-server-open-web-guard-fails-with-guidance ()
  :tags '(dsh-unit)
  (let ((dsh-emacs-server-auto-start nil)
        (noninteractive nil))
    (cl-letf (((symbol-function 'dsh-emacs--server-alive-p) (lambda () nil)))
      (let ((err (should-error (dsh-emacs-open-web) :type 'user-error)))
        (ert-info ((format "%s" "open-web-guard-fails-with-guidance"))
          (should (string-match-p "not reachable" (error-message-string err))))))))

;; --- Test 93bis: browser session auth -- capture launch token from *dsh-server* ---
(ert-deftest dsh-emacs-test-server-auth-token-captured-from-server-output ()
  :tags '(dsh-unit)
  (let ((dsh-emacs--server-auth-captured-token nil)
        (dsh-emacs--server-auth-cookie nil)
        (get-buffer (symbol-function 'get-buffer))
        (buf (generate-new-buffer " *dsh-server-token-test*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (erase-buffer)
            (insert "dsh web: http://127.0.0.1:3080/?token=CapturedTok123 (LAN: http://192.168.1.5:3080/?token=CapturedTok123)\n"))
          (ert-info ((format "%s" "auth-token-captured-from-server-output"))
            (cl-letf (((symbol-function 'get-buffer)
                       (lambda (name)
                         (if (equal name "*dsh-server*") buf
                           (funcall get-buffer name)))))
              (should (equal "CapturedTok123"
                             (dsh-emacs--server-auth-token))))))
      (kill-buffer buf))
    (setq dsh-emacs--server-auth-captured-token nil)))

;; --- Test 93c: launch token extracted from the base-url token query parameter ---
(ert-deftest dsh-emacs-test-server-auth-token-from-url-single ()
  :tags '(dsh-unit)
  (ert-info ((format "%s" "auth-token-from-url-single"))
    (should (equal "AbC_-D"
                   (dsh-emacs--server-auth-token-from-url
                    "http://127.0.0.1:3080/?token=AbC_-D")))))

(ert-deftest dsh-emacs-test-server-auth-token-from-url-clean-is-nil ()
  :tags '(dsh-unit)
  (ert-info ((format "%s" "auth-token-from-url-clean-is-nil"))
    (should (null (dsh-emacs--server-auth-token-from-url "http://127.0.0.1:3080")))))

;; --- Test 93c2: a ?token= query in base-url is stripped when building request URLs ---
;; When the user puts the full URL printed by dsh web (including ?token=) into
;; dsh-emacs-base-url, RPC/probe/open-web path building must not splice the query
;; in (otherwise the URL becomes ...?token=X/api/...) -- the cleaned base drops the
;; query and the trailing slash, and the token is extracted separately.
(ert-deftest dsh-emacs-test-server-auth-base-url-strips-token-query-for-url-building ()
  :tags '(dsh-unit)
  (let ((dsh-emacs-base-url "http://127.0.0.1:3080/?token=Xy-9_"))
    (ert-info ((format "%s" "auth-base-url-strips-token-query-for-url-building"))
      (should (and (equal "http://127.0.0.1:3080"
                          (dsh-emacs--server-base-url))
                   (equal "http://127.0.0.1:3080/api/session/list"
                          (format "%s/api/session/list"
                                  (dsh-emacs--server-base-url)))
                   (equal "http://127.0.0.1:3080/"
                          (concat (dsh-emacs--server-base-url) "/")))))
    (ert-info ((format "%s" "auth-base-url-raw-still-carries-token"))
      (should (equal "Xy-9_"
                     (dsh-emacs--server-auth-token-from-url
                      (dsh-emacs--server-base-url-raw)))))))

;; --- Test 93d: token → cookie exchange parses Set-Cookie and caches it, no
;; repeated mint ---
;; exchange goes through `dsh-emacs--server-auth-exchange-plain' (raw TCP): dsh's
;; successful exchange is 303 + Set-Cookie, so the first 303's headers must be
;; read and redirects must not be followed (url-retrieve follows to / and drops
;; the header). The unit test feeds a real 303 response through a mock socket.
(ert-deftest dsh-emacs-test-server-auth-raw-exchange-hits-token-query ()
  :tags '(dsh-unit)
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
        (ert-info ((format "%s" "auth-raw-exchange-hits-token-query"))
          (should (string-match-p "GET /\\?token=TokD HTTP/1.0" sent)))
        (ert-info ((format "%s" "auth-raw-exchange-carries-configured-basic-auth"))
          (should (string-match-p
                   (concat "Authorization: Basic " (base64-encode-string "alice:secret" t)
                           "\r\n")
                   sent)))
        (ert-info ((format "%s" "auth-raw-exchange-parses-303-set-cookie"))
          (should (equal "dsh-auth-HASH=eyJ2MSJ9.sig" cookie))))
      (setq cookie-header "")
      (ert-info ((format "%s" "auth-raw-exchange-rejects-unrelated-cookie"))
        (should (null (dsh-emacs--server-auth-exchange-plain
                       "http://127.0.0.1:3080/?token=TokD")))))))

;; --- Test 93d2: for an https base the token exchange goes through url-retrieve
;; and parses the 303 Set-Cookie ---
;; https needs TLS, so it can only go through the url library; the implementation
;; uses `url-max-redirections 0' to make url-retrieve stop at the first 303 and
;; read the Set-Cookie (instead of following to /). On-demand mint inside an RPC
;; must not inherit the outer POST, request body, or auth headers.
(ert-deftest dsh-emacs-test-server-auth-https-exchange-disables-redirects ()
  :tags '(dsh-unit)
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
        (ert-info ((format "%s" "auth-https-exchange-disables-redirects"))
          (should redirs-unbounded))
        (ert-info ((format "%s" "auth-https-exchange-isolates-get-from-rpc-context"))
          (should (equal '("GET" nil nil t) request-context)))
        (ert-info ((format "%s" "auth-https-exchange-preserves-outer-rpc-context"))
          (should (equal '("POST" "outer-rpc-body" (("Cookie" . "outer-cookie")) nil)
                         (list url-request-method url-request-data
                               url-request-extra-headers url-request-noninteractive))))
        (ert-info ((format "%s" "auth-https-exchange-parses-303-set-cookie"))
          (should (equal "dsh-auth-ABC=v1.body.sig" cookie)))))))

;; --- Test 93d3: ensure end-to-end --- a known token exchanges for a cookie and
;; caches it ---
(ert-deftest dsh-emacs-test-server-auth-ensure-mints-from-token-and-caches ()
  :tags '(dsh-unit)
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
        (ert-info ((format "%s" "auth-ensure-mints-from-token-and-caches"))
          (should (and (equal "dsh-auth-EEE=v1.sig" cookie)
                       (equal "dsh-auth-EEE=v1.sig" dsh-emacs--server-auth-cookie))))))
    (setq dsh-emacs--server-auth-cookie nil
          dsh-emacs-server-auth-token nil)))

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
(ert-deftest dsh-emacs-test-server-auth-cookie-multibyte-flag-normalized ()
  :tags '(dsh-unit)
  (let ((old dsh-emacs--server-auth-cookie))
    (unwind-protect
        (let* ((cookie (string-as-multibyte "dsh-auth-MB=v1.body.sig"))
               (dsh-emacs--server-auth-cookie cookie))
          (ert-info ((format "%s" "auth-cookie-multibyte-flag-normalized"))
            (should (let ((out (dsh-emacs--server-auth-cookie-header)))
                      (and (stringp out)
                           (equal "dsh-auth-MB=v1.body.sig"
                                  (decode-coding-string out 'utf-8))
                           (not (multibyte-string-p out))))))
          (ert-info ((format "%s" "auth-cookie-already-unibyte-passthrough"))
            (should (let ((dsh-emacs--server-auth-cookie "dsh-auth-UB=v1.sig"))
                      (equal "dsh-auth-UB=v1.sig"
                             (dsh-emacs--server-auth-cookie-header)))))
          (ert-info ((format "%s" "auth-cookie-nil-returns-nil"))
            (should (let ((dsh-emacs--server-auth-cookie nil))
                      (null (dsh-emacs--server-auth-cookie-header))))))
      (setq dsh-emacs--server-auth-cookie old))))

;; --- Test 93d3c: a stale cookie after an external server restart is cleared on
;; 401 ---
;; Regression: a user-managed external `dsh web' issues a new per-process token
;; on every restart, invalidating the old cookie cached on this side; the client
;; cannot tell that the token changed, so it keeps sending the dead cookie and
;; every RPC 401s until Emacs restarts. On a "401 carrying our cookie" it should
;; clear the cache (the next call mints again / asks again).
(ert-deftest dsh-emacs-test-server-auth-http-401-p-detects-http-401 ()
  :tags '(dsh-unit)
  (let ((dsh-emacs--server-auth-cookie "dsh-auth-STALE=v1.old"))
    (ert-info ((format "%s" "auth-http-401-p-detects-http-401"))
      (should (dsh-emacs--server-auth-http-401-p '(error http 401)))
      (should (not (dsh-emacs--server-auth-http-401-p '(error http 404))))
      (should (not (dsh-emacs--server-auth-http-401-p nil))))
    (dsh-emacs--server-auth-maybe-expire)
    (ert-info ((format "%s" "auth-stale-cookie-cleared-on-401"))
      (should (null dsh-emacs--server-auth-cookie)))
    ;; Without a cookie, maybe-expire stays as-is (it must not wrongly clear state in
    ;; the no-cookie case)
    (dsh-emacs--server-auth-maybe-expire)
    (ert-info ((format "%s" "auth-maybe-expire-with-no-cookie"))
      (should (null dsh-emacs--server-auth-cookie)))))

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
(ert-deftest dsh-emacs-test-server-async-readiness-real-http-reads-first-303-cookie ()
  :tags '(dsh-unit)
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
      (pcase-let ((`(,request . (,result ,cookie))
                   (raw-socket-server
                    (concat "HTTP/1.1 303 See Other\r\nLocation: /\r\n"
                            "Set-Cookie: dsh-auth-unit=async; Path=/\r\n"
                            "Content-Length: 0\r\n\r\n")
                    (lambda ()
                      (let ((noninteractive nil)
                            (dsh-emacs--server-auth-cookie nil)
                            (dsh-emacs-server-auth-token "Tok+Async")
                            (dsh-emacs--server-alive-check nil)
                            (dsh-emacs--server-process nil)
                            (dsh-emacs-server-wait-seconds 1)
                            (result 'pending))
                        (with-temp-buffer
                          (dsh-emacs-server-ensure-async
                           (lambda (reason) (setq result reason)))
                          (let ((deadline (+ (float-time) 2)))
                            (while (and (eq result 'pending)
                                        (< (float-time) deadline))
                              (accept-process-output nil 0.01))))
                        (list result dsh-emacs--server-auth-cookie))))))
        (ert-info ((format "%s" "async-readiness-real-http-reads-first-303-cookie"))
          (should (null result))
          (should (equal cookie "dsh-auth-unit=async"))
          (should (string-match-p "GET /\\?token=Tok%2BAsync HTTP/1.1" request))
          (should (not (string-match-p "\r\r\n" request)))))
      (pcase-let ((`(,probe-request . ,probe-alive)
                   (raw-socket-server
                    "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
                    #'dsh-emacs--server-probe-plain)))
        (ert-info ((format "%s" "raw-probe-request-keeps-crlf-under-dos-coding"))
          (should (string-match-p "GET / HTTP/1.0\r\nHost: 127\\.0\\.0\\.1:[0-9]+\r\n\r\n"
                                  probe-request))
          (should (not (string-match-p "\r\r\n" probe-request))))
        (ert-info ((format "%s" "raw-probe-alive-under-dos-coding"))
          (should probe-alive)))
      (pcase-let ((`(,auth-request . ,auth-required)
                   (raw-socket-server
                    "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n"
                    #'dsh-emacs--server-auth-required-plain)))
        (ert-info ((format "%s" "raw-auth-probe-request-keeps-crlf-under-dos-coding"))
          (should (not (string-match-p "\r\r\n" auth-request))))
        (ert-info ((format "%s" "raw-auth-probe-detects-401-under-dos-coding"))
          (should auth-required)))
      (pcase-let ((`(,exchange-request . ,exchange-cookie)
                   (raw-socket-server
                    (concat "HTTP/1.1 303 See Other\r\nLocation: /\r\n"
                            "Set-Cookie: dsh-auth-HASH=v1.body.sig; Path=/; HttpOnly\r\n"
                            "\r\n")
                    (lambda ()
                      (dsh-emacs--server-auth-exchange-plain
                       (concat dsh-emacs-base-url "/?token=TokDos"))))))
        (ert-info ((format "%s" "raw-exchange-request-keeps-crlf-under-dos-coding"))
          (should (string-match-p "GET /\\?token=TokDos HTTP/1.0" exchange-request))
          (should (not (string-match-p "\r\r\n" exchange-request))))
        (ert-info ((format "%s" "raw-exchange-mints-cookie-under-dos-coding"))
          (should (equal "dsh-auth-HASH=v1.body.sig" exchange-cookie)))))))

;; --- Test 93d4: interactive auth gate --- with a known cookie, no prompting ---
(ert-deftest dsh-emacs-test-server-auth-gate-cookie-present-asks-nothing ()
  :tags '(dsh-unit)
  (let ((dsh-emacs-base-url "http://127.0.0.1:3080")
        (dsh-emacs--server-auth-cookie "dsh-auth-HASH=ok.sig")
        (noninteractive nil)
        (asked 0))
    (cl-letf (((symbol-function 'read-string)
               (lambda (&rest _) (setq asked (1+ asked)) "Tok")))
      (dsh-emacs--server-auth-ensure-interactive))
    (ert-info ((format "%s" "auth-gate-cookie-present-asks-nothing"))
      (should (= 0 asked)))
    (setq dsh-emacs--server-auth-cookie nil)))

;; --- Test 93d5: interactive auth gate --- known token → mint directly, no
;; prompting ---
(ert-deftest dsh-emacs-test-server-auth-gate-known-token-mints-silently ()
  :tags '(dsh-unit)
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
    (ert-info ((format "%s" "auth-gate-known-token-mints-silently"))
      (should (and (= 0 asked)
                   (equal "dsh-auth-KNOWN=v1.sig" dsh-emacs--server-auth-cookie))))
    (setq dsh-emacs--server-auth-cookie nil
          dsh-emacs-server-auth-token nil)))

;; --- Test 93d6: interactive auth gate --- server needs no cookie → passes
;; without prompting ---
(ert-deftest dsh-emacs-test-server-auth-gate-no-auth-needed-asks-nothing ()
  :tags '(dsh-unit)
  (let ((dsh-emacs-base-url "http://127.0.0.1:3080")
        (dsh-emacs--server-auth-cookie nil)
        (noninteractive nil)
        (asked 0))
    (cl-letf (((symbol-function 'dsh-emacs--server-auth-required-p)
               (lambda () nil))
              ((symbol-function 'read-string)
               (lambda (&rest _) (setq asked (1+ asked)) "x")))
      (dsh-emacs--server-auth-ensure-interactive))
    (ert-info ((format "%s" "auth-gate-no-auth-needed-asks-nothing"))
      (should (= 0 asked)))))

;; --- Test 93d7: interactive auth gate --- external auth-required server →
;; prompt for a token and mint ---
(ert-deftest dsh-emacs-test-server-auth-gate-external-auth-asks-and-mints ()
  :tags '(dsh-unit)
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
    (ert-info ((format "%s" "auth-gate-external-auth-asks-and-mints"))
      (should (and (= 1 asked)
                   (equal "dsh-auth-USERT=v1.sig" dsh-emacs--server-auth-cookie)
                   (equal dsh-emacs-server-auth-token "UserTok")))) ; remembered for reuse
    (setq dsh-emacs--server-auth-cookie nil
          dsh-emacs-server-auth-token nil)))

;; --- Test 93d8: interactive auth gate --- empty user input → user-error
;; guidance ---
(ert-deftest dsh-emacs-test-server-auth-gate-empty-token-errors-with-guidance ()
  :tags '(dsh-unit)
  (let ((dsh-emacs-base-url "http://127.0.0.1:3080")
        (dsh-emacs--server-auth-cookie nil)
        (noninteractive nil))
    (cl-letf (((symbol-function 'dsh-emacs--server-auth-required-p)
               (lambda () t))
              ((symbol-function 'read-string)
               (lambda (&rest _) "")))
      (let ((err (should-error (dsh-emacs--server-auth-ensure-interactive) :type 'user-error)))
        (ert-info ((format "%s" "auth-gate-empty-token-errors-with-guidance"))
          (should (string-match-p "dsh-emacs-server-auth-token"
                                  (error-message-string err))))))))

;; --- Test 93d8b: empty input, a wrong token, and C-g can all be retried on the
;; next call ---
(ert-deftest dsh-emacs-test-server-auth-gate-failed-attempt-blocks-case ()
  :tags '(dsh-unit)
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
        (ert-info ((format "%s" (format "auth-gate-failed-attempt-blocks-%s" first-input)))
          (should (eq first-result (if (eq first-input 'quit) 'quit 'user-error)))
          (should (null dsh-emacs--server-auth-cookie))
          (should (= asked 1)))
        (setq retry-result
              (condition-case err
                  (dsh-emacs--server-auth-ensure-interactive)
                (user-error (car err))))
        (ert-info ((format "%s" (format "auth-gate-retry-succeeds-%s" first-input)))
          (should (eq retry-result t))
          (should (= asked 2))
          (should (equal dsh-emacs--server-auth-cookie "dsh-auth-RETRY=ok"))
          (should (equal (reverse exchanged)
                         (if (equal first-input "WrongTok")
                             '("WrongTok" "CorrectTok") '("CorrectTok")))))))))

;; --- Test 93d9: interactive auth gate --- on success cache the cookie and do
;; not ask again ---
(ert-deftest dsh-emacs-test-server-auth-gate-cookie-cached-skips-repeat-ask ()
  :tags '(dsh-unit)
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
    (ert-info ((format "%s" "auth-gate-cookie-cached-skips-repeat-ask"))
      (should (and (= 1 asked)
                   (equal "dsh-auth-A=v1.sig" dsh-emacs--server-auth-cookie)
                   (equal dsh-emacs-server-auth-token "TokA")))) ; remembered for reuse
    (setq dsh-emacs--server-auth-cookie nil
          dsh-emacs-server-auth-token nil)))

;; --- Test 93d9b: a remembered token is persisted only when its value changes
;; (anti-churn) ---
(ert-deftest dsh-emacs-test-server-auth-remember-saves-and-skips-churn ()
  :tags '(dsh-unit)
  (let ((dsh-emacs-server-auth-token nil) (saved nil))
    (cl-letf (((symbol-function 'customize-save-variable)
               (lambda (var val) (push (list var val) saved))))
      (dsh-emacs--server-auth-remember-token "tokX")
      (let ((after-first saved))
        (dsh-emacs--server-auth-remember-token "tokX")
        (ert-info ((format "%s" "auth-remember-saves-and-skips-churn"))
          (should (and (equal dsh-emacs-server-auth-token "tokX")
                       (equal after-first
                              (list (list 'dsh-emacs-server-auth-token "tokX")))
                       (equal saved after-first))))))
    (setq dsh-emacs-server-auth-token nil)))

;; --- RPC error text: the server message wins, the code stays visible, and a
;; missing response is named instead of printing nil ---
(ert-deftest dsh-emacs-test-server-rpc-error-text ()
  :tags '(dsh-unit)
  (should (equal "Unknown agent preset: gone (agent-preset/not-found)"
                 (dsh-emacs-rpc-error-text
                  '((code . "agent-preset/not-found")
                    (message . "Unknown agent preset: gone")
                    (details . ((agentPreset . "gone")))))))
  (should (equal "provider said no"
                 (dsh-emacs-rpc-error-text
                  '((message . "provider said no")))))
  (should (equal "legacy failure"
                 (dsh-emacs-rpc-error-text "legacy failure")))
  (should (equal "session/gone"
                 (dsh-emacs-rpc-error-text '((code . "session/gone")))))
  (should (equal "no response" (dsh-emacs-rpc-error-text nil)))
  (should (equal "42" (dsh-emacs-rpc-error-text 42))))

(provide 'dsh-test-server)
;;; dsh-test-server.el ends here
