;;; dsh-test-lifecycle.el --- Lifecycle tests -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "28.1"))

(require 'dsh-test-support)

;; A new session must expose an editable draft before readiness or creation.
(ert-deftest dsh-emacs-test-lifecycle-new-session-draft-precedes-server-readiness ()
  :tags '(dsh-unit)
  (let ((ready nil)
        (create nil)
        (draft nil)
        (dsh-emacs--current-session "previous-session")
        (dsh-emacs--current-buffer nil)
        (dsh-emacs--sessions nil)
        (dsh-emacs--chat-buffers (make-hash-table :test #'equal)))
    (save-window-excursion
      (unwind-protect
          (cl-letf (((symbol-function 'dsh-emacs-server-ensure-async)
                     (lambda (callback) (setq ready callback)))
                    ((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (_method _params callback) (setq create callback))))
            (setq draft (dsh-emacs-new-session "/tmp" "w-one" "ptc"))
            (ert-info ((format "%s" "new-session-draft-precedes-server-readiness"))
              (should (bufferp draft))
              (should ready)
              (should (null create))
              (should (eq (window-buffer (selected-window)) draft)))
            (when (bufferp draft)
              (with-current-buffer draft
                (insert "Draft before response")
                (ert-info ((format "%s" "new-session-draft-blocks-old-session-fallback"))
                  (should (null (dsh-emacs--active-session-id))))
                (funcall ready nil)
                (ert-info ((format "%s" "new-session-starts-create-after-readiness"))
                  (should create)
                  (should (equal (buffer-string) "Draft before response"))))))
        (when (bufferp draft) (kill-buffer draft))))))

;; --- Test 36: session buffer naming (matches the list + dsh prefix) ---
(ert-deftest dsh-emacs-test-lifecycle-chat-buffer-name-with-title ()
  :tags '(dsh-unit)
  (let* ((dsh-emacs--sessions nil)
         (item (list (cons 'sessionId "sess-title-1")
                     (cons 'blank :json-false)
                     (cons 'projections
                           (list (cons 'values
                                       (list (cons 'title "Emacs tweak")))))))
         (old dsh-emacs--sessions))
    (setq dsh-emacs--sessions
          (dsh-emacs-test--session-items (list item)))
    (ert-info ((format "%s" "chat-buffer-name-with-title"))
      (should (string= "dsh: Emacs tweak" (dsh-emacs--chat-buffer-name "sess-title-1"))))
    (setq dsh-emacs--sessions old)))

(ert-deftest dsh-emacs-test-lifecycle-chat-buffer-name-fallback-without-title ()
  :tags '(dsh-unit)
  (let ((dsh-emacs--sessions nil)
        (old dsh-emacs--sessions))
    (setq dsh-emacs--sessions nil)
    (ert-info ((format "%s" "chat-buffer-name-fallback-without-title"))
      (should (string= "dsh: sess-fallback" (dsh-emacs--chat-buffer-name "sess-fallback"))))
    (setq dsh-emacs--sessions old)))

;; --- Test 37: name sanitizing (% and newline) ---
(ert-deftest dsh-emacs-test-lifecycle-sanitize-percent-fullwidth ()
  :tags '(dsh-unit)
  (ert-info ((format "%s" "sanitize-percent-fullwidth"))
    (should (string= "进度50％完成" (dsh-emacs--sanitize-buffer-name "进度50%完成")))))

(ert-deftest dsh-emacs-test-lifecycle-sanitize-newline-flatten ()
  :tags '(dsh-unit)
  (ert-info ((format "%s" "sanitize-newline-flatten"))
    (should (string= "a b" (dsh-emacs--sanitize-buffer-name "a\nb")))))

(ert-deftest dsh-emacs-test-lifecycle-sanitize-trims-whitespace ()
  :tags '(dsh-unit)
  (ert-info ((format "%s" "sanitize-trims-whitespace"))
    (should (string= "" (dsh-emacs--sanitize-buffer-name "  ")))))

;; --- Test 38: title with % makes the buffer name use full-width % ---
(ert-deftest dsh-emacs-test-lifecycle-chat-buffer-name-escape-percent ()
  :tags '(dsh-unit)
  (let* ((dsh-emacs--sessions nil)
         (item (list (cons 'sessionId "sess-pct")
                     (cons 'blank :json-false)
                     (cons 'projections
                           (list (cons 'values
                                       (list (cons 'title "完成50%")))))))
         (old dsh-emacs--sessions))
    (setq dsh-emacs--sessions
          (dsh-emacs-test--session-items (list item)))
    (ert-info ((format "%s" "chat-buffer-name-escape-percent"))
      (should (string= "dsh: 完成50％" (dsh-emacs--chat-buffer-name "sess-pct"))))
    (setq dsh-emacs--sessions old)))

;; --- Test 39: same-title sessions get unique names (<N> suffix) ---
(ert-deftest dsh-emacs-test-lifecycle-chat-buffer-name-unique-suffix ()
  :tags '(dsh-unit)
  (let* ((title (make-temp-name "dup-title-"))
         (item (list (cons 'sessionId "sess-dup-1")
                     (cons 'blank :json-false)
                     (cons 'projections
                           (list (cons 'values
                                       (list (cons 'title title)))))))
         (dsh-emacs--sessions (dsh-emacs-test--session-items (list item)))
         (base (dsh-emacs--chat-buffer-name "sess-dup-1"))
         (b1 (generate-new-buffer base))
         (b2 (generate-new-buffer base)))
    (unwind-protect
        (ert-info ((format "%s" "chat-buffer-name-unique-suffix"))
          (should (string= (concat base "<2>") (buffer-name b2))))
      (when (buffer-live-p b1) (kill-buffer b1))
      (when (buffer-live-p b2) (kill-buffer b2)))))

;; --- Test 40: sync live buffers on cache drift (rename + workspace dir) ---
(ert-deftest dsh-emacs-test-lifecycle-chat-buffer-sync-renames ()
  :tags '(dsh-unit)
  (let* ((dsh-emacs--chat-buffers (make-hash-table :test #'equal))
         (item (list (cons 'sessionId "sess-rename")
                     (cons 'blank :json-false)
                     (cons 'cwd "/tmp/proj")
                     (cons 'projections
                           (list (cons 'values
                                       (list (cons 'title "renamed")))))))
         (old dsh-emacs--sessions)
         (buf (generate-new-buffer " *dsh-test-sync*")))
    (unwind-protect
        (progn
          (setq dsh-emacs--sessions
                (dsh-emacs-test--session-items (list item)))
          (with-current-buffer buf
            (setq dsh-emacs--buffer-session "sess-rename")
            (rename-buffer (generate-new-buffer-name "old-name")))
          (puthash "sess-rename" buf dsh-emacs--chat-buffers)
          (dsh-emacs--chat-buffer-sync "sess-rename")
          (ert-info ((format "%s" "chat-buffer-sync-renames"))
            (should (string= "dsh: renamed" (buffer-name buf))))
          (ert-info ((format "%s" "chat-buffer-sync-sets-default-directory"))
            (should (and (stringp (buffer-local-value 'default-directory buf))
                         (string= "/tmp/proj/"
                                  (buffer-local-value 'default-directory buf)))))
          (remhash "sess-rename" dsh-emacs--chat-buffers))
      (setq dsh-emacs--sessions old)
      (when (buffer-live-p buf) (kill-buffer buf)))))

;; --- Test 40b: session workspace path source (cwd field of session/list) ---
(ert-deftest dsh-emacs-test-lifecycle-chat-cwd-from-session-item ()
  :tags '(dsh-unit)
  (let* ((dsh-emacs--sessions nil)
         (item (list (cons 'sessionId "sess-cwd")
                     (cons 'blank :json-false)
                     (cons 'cwd "/Users/ed/playground/dsh-emacs")
                     (cons 'projections
                           (list (cons 'values
                                       (list (cons 'title "some-session")))))))
         (old dsh-emacs--sessions))
    (setq dsh-emacs--sessions
          (dsh-emacs-test--session-items (list item)))
    (ert-info ((format "%s" "chat-cwd-from-session-item"))
      (should (string= "/Users/ed/playground/dsh-emacs"
                       (dsh-emacs--chat-cwd "sess-cwd"))))
    (ert-info ((format "%s" "chat-cwd-nil-when-unknown"))
      (should (null (dsh-emacs--chat-cwd "sess-unknown"))))
    (setq dsh-emacs--sessions old)))

;; --- Test 41: title matches the list display ---
(ert-deftest dsh-emacs-test-lifecycle-chat-title-matches-list ()
  :tags '(dsh-unit)
  (let* ((dsh-emacs--sessions nil)
         (item (list (cons 'sessionId "sess-match")
                     (cons 'blank :json-false)
                     (cons 'projections
                           (list (cons 'values
                                       (list (cons 'title "matches-list")))))))
         (old dsh-emacs--sessions))
    (setq dsh-emacs--sessions
          (dsh-emacs-test--session-items (list item)))
    (ert-info ((format "%s" "chat-title-matches-list"))
      (should (string= "matches-list" (dsh-emacs--chat-title "sess-match"))))
    (setq dsh-emacs--sessions old)))

;; --- Test 43: first open of a session locates the workspace
;; (default-directory) ---
;; Regression: sync used to run before `setq-local dsh-emacs--buffer-session', so
;; the first-opened buffer was silently skipped by sync's guard, so
;; default-directory was never set, leaving magit unable to locate the project.
;; Here stubs mask network/rendering and the full open path runs.
;; Mock prefetch scheduling too: its timers outlive the chat buffer and would
;; otherwise make real requests after these local network mocks unwind.
(ert-deftest dsh-emacs-test-lifecycle-open-session-first-open-sets-default-directory ()
  :tags '(dsh-unit)
  (cl-letf (((symbol-function 'dsh-emacs-command-catalog-prefetch) #'ignore)
            ((symbol-function 'dsh-emacs-skill-prefetch) #'ignore)
            ((symbol-function 'dsh-emacs-reference-prefetch) #'ignore)
            ((symbol-function 'dsh-emacs-events-connect) (lambda (&rest _) nil))
            ((symbol-function 'pop-to-buffer) (lambda (&rest _) nil)))
    (let ((dsh-emacs--chat-buffers (make-hash-table :test #'equal))
          (old-sessions dsh-emacs--sessions)
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
              (ert-info ((format "%s" "open-session-first-open-sets-default-directory"))
                (should (and (bufferp buf)
                             (string= "/tmp/ws/"
                                      (buffer-local-value 'default-directory buf)))))
              (ert-info ((format "%s" "open-session-first-open-names-buffer"))
                (should (and (bufferp buf) (string= "dsh: opening" (buffer-name buf)))))))
        (setq dsh-emacs--sessions old-sessions
              dsh-emacs--current-buffer old-current-buffer
              dsh-emacs--current-session old-current-session)
        (dolist (b (buffer-list))
          (when (and (buffer-local-value 'dsh-emacs--buffer-session b)
                     (string= "sess-open"
                              (buffer-local-value 'dsh-emacs--buffer-session b)))
            (kill-buffer b)))
        (remhash "sess-open" dsh-emacs--chat-buffers)))))

(ert-deftest dsh-emacs-test-lifecycle-open-session-replaces-killed-buffer ()
  :tags '(dsh-unit)
  (let* ((dsh-emacs--chat-buffers (make-hash-table :test #'equal))
         (dsh-emacs--current-session nil)
         (dsh-emacs--current-buffer nil)
         (dsh-emacs--sessions nil)
         (dead (generate-new-buffer " *dsh-killed-chat*"))
         (ready-count 0)
         activated
         pop-args)
    (kill-buffer dead)
    (puthash "sess-killed" dead dsh-emacs--chat-buffers)
    (unwind-protect
        (cl-letf (((symbol-function 'dsh-emacs-server-ensure)
                   (lambda () (cl-incf ready-count)))
                  ((symbol-function 'dsh-emacs--activate-chat-buffer)
                   (lambda (sid buf address)
                     (setq activated (list sid buf address))))
                  ((symbol-function 'pop-to-buffer)
                   (lambda (buffer &optional action)
                     (setq pop-args (list buffer action)))))
          (dsh-emacs-open-session "sess-killed" nil t)
          (should (buffer-live-p dsh-emacs--current-buffer))
          (should-not (eq dsh-emacs--current-buffer dead))
          (should (equal activated
                         (list "sess-killed" dsh-emacs--current-buffer nil)))
          (should (equal dsh-emacs--current-session "sess-killed"))
          (should (= ready-count 1))
          (should (equal pop-args
                         (list dsh-emacs--current-buffer
                               '(display-buffer-pop-up-window)))))
      (when (buffer-live-p dsh-emacs--current-buffer)
        (kill-buffer dsh-emacs--current-buffer)))))

;; --- Test 43b: opening a new session no longer drops other sessions' streams
;; (multi-session realtime) ---
;; Regression: open-session used to unconditionally tear down the mux of the
;; previous current-buffer — opening B from A cut A's stream with nobody
;; reconnecting it, so A could only poll afterwards and misleading
;; "event stream connecting / switches back to realtime" messages appeared
;; (it never got back).
(ert-deftest dsh-emacs-test-lifecycle-open-second-session-connects-its-own-stream ()
  :tags '(dsh-unit)
  (let* ((dsh-emacs--chat-buffers (make-hash-table :test #'equal))
         (buf-a (generate-new-buffer " *t43b-a*"))
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
          (cl-letf (((symbol-function 'dsh-emacs-command-catalog-prefetch) #'ignore)
                    ((symbol-function 'dsh-emacs-skill-prefetch) #'ignore)
                    ((symbol-function 'dsh-emacs-reference-prefetch) #'ignore)
                    ((symbol-function 'dsh-emacs-events-connect)
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
            (ert-info ((format "%s" "open-second-session-connects-its-own-stream"))
              (should (and connects (eq (nth 1 (car connects)) buf-b))))
            ;; A's stream was not dropped
            (ert-info ((format "%s" "open-second-session-keeps-previous-stream"))
              (should (not (cl-some (lambda (d) (eq (nth 1 d) buf-a))
                                    disconnects)))))
          ;; Reopening the same session only selects its live buffer.
          (setq disconnects nil connects nil)
          (cl-letf (((symbol-function 'dsh-emacs-command-catalog-prefetch) #'ignore)
                    ((symbol-function 'dsh-emacs-skill-prefetch) #'ignore)
                    ((symbol-function 'dsh-emacs-reference-prefetch) #'ignore)
                    ((symbol-function 'dsh-emacs-events-connect)
                     (lambda (chat) (push (list 'connect chat) connects)))
                    ((symbol-function 'dsh-emacs-events-disconnect)
                     (lambda (&optional chat)
                       (push (list 'disconnect chat) disconnects)))
                    ((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (&rest _) nil))
                    ((symbol-function 'pop-to-buffer)
                     (lambda (&rest _) nil)))
            (dsh-emacs-open-session "sess-kb"))
          (ert-info ("reopen-same-session-keeps-existing-stream")
            (should-not connects)
            (should-not disconnects)))
      (setq dsh-emacs--sessions old-sessions
            dsh-emacs--current-buffer old-current-buffer
            dsh-emacs--current-session old-current-session)
      (dolist (b (buffer-list))
        (let ((sid (buffer-local-value 'dsh-emacs--buffer-session b)))
          (when (member sid '("sess-ka" "sess-kb"))
            (kill-buffer b))))
      (remhash "sess-ka" dsh-emacs--chat-buffers)
      (remhash "sess-kb" dsh-emacs--chat-buffers))))

;; --- Test 43d: first open of a new session (cache miss) → refetch the list to
;; get a ctx snapshot ---
;; The new session is not in the `dsh-emacs--sessions' cache: the enhanced
;; guard of `dsh-emacs--link-session-preset' (triggered by either a missing
;; preset or a missing session) should lazily fetch session/list — in the
;; callback `dsh-emacs--chat-buffers-sync-all' (with context-sync) feeds the
;; contextPressure snapshot into the mode-line, so ctx% finally shows on first
;; open instead of staying empty forever.
(ert-deftest dsh-emacs-test-lifecycle-first-open-fetches-session-list ()
  :tags '(dsh-unit)
  (let* ((dsh-emacs--chat-buffers (make-hash-table :test #'equal))
         (old-sessions dsh-emacs--sessions)
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
          (ert-info ((format "%s" "first-open-fetches-session-list"))
            (should (member "session/list" methods))))
      (setq dsh-emacs--sessions old-sessions)
      (remhash "sess-first" dsh-emacs--chat-buffers)
      (when (buffer-live-p buf) (kill-buffer buf)))))

;; --- Test 43e: with a warm cache the mode-line ctx snapshot lands after
;; open-session ---
;; Regression: `dsh-emacs--chat-buffer-context-sync' used to run before
;; `dsh-emacs-mode', and the kill-all-local-variables of define-derived-mode
;; wiped the whole buffer-local snapshot that had been fed in → ctx% never
;; showed. Now sync runs after mode and mode-line-setup, so with a warm cache
;; it should land in one shot.
(ert-deftest dsh-emacs-test-lifecycle-open-session-feeds-context-snapshot ()
  :tags '(dsh-unit)
  (let* ((dsh-emacs--chat-buffers (make-hash-table :test #'equal))
         (old-sessions dsh-emacs--sessions)
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
                    ((symbol-function 'dsh-emacs-command-catalog-prefetch) #'ignore)
                    ((symbol-function 'dsh-emacs-skill-prefetch) #'ignore)
                    ((symbol-function 'dsh-emacs-reference-prefetch) #'ignore)
                    ((symbol-function 'pop-to-buffer)
                     (lambda (&rest _) nil)))
            (dsh-emacs-open-session "sess-ctxexist"))
          (let* ((buf (gethash "sess-ctxexist" dsh-emacs--chat-buffers))
                 (pressure (and buf (buffer-local-value
                                     'dsh-emacs--modeline-context-pressure buf)))
                 (window (and buf (buffer-local-value
                                   'dsh-emacs--modeline-context-window-server buf))))
            (ert-info ((format "%s" "open-session-feeds-context-snapshot"))
              (should (and (= 129946 pressure) (= 262144 window))))))
      (setq dsh-emacs--sessions old-sessions)
      (let ((b (gethash "sess-ctxexist" dsh-emacs--chat-buffers)))
        (remhash "sess-ctxexist" dsh-emacs--chat-buffers)
        (when (buffer-live-p b) (kill-buffer b))))))

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
(ert-deftest dsh-emacs-test-lifecycle-model-error-row-keeps-ctx-snapshot ()
  :tags '(dsh-unit)
  (let* ((old-sessions dsh-emacs--sessions)
         (ghost (generate-new-buffer " *t43f-chat*"))
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
            (ert-info ((format "%s" "model-error-row-keeps-ctx-snapshot"))
              (should (and (= 129946 p) (= 262144 w)))))
          ;; The list row does not even have a contextPressure projection → all the more
          ;; reason not to clear
          (setq dsh-emacs--sessions
                (list (dsh-protocol-session--from-alist
                       '((sessionId . "sess-ctxkeep")))))
          (dsh-emacs--chat-buffer-context-sync "sess-ctxkeep" ghost)
          (let ((p (buffer-local-value 'dsh-emacs--modeline-context-pressure ghost))
                (w (buffer-local-value 'dsh-emacs--modeline-context-window-server ghost)))
            (ert-info ((format "%s" "projectionless-row-keeps-ctx-snapshot"))
              (should (and (= 129946 p) (= 262144 w)))))
          ;; A complete paired row still lands as usual (with a healthy model the list
          ;; refresh keeps correcting ctx%)
          (setq dsh-emacs--sessions
                (list (dsh-protocol-session--from-alist good)))
          (dsh-emacs--chat-buffer-context-sync "sess-ctxkeep" ghost)
          (let ((p (buffer-local-value 'dsh-emacs--modeline-context-pressure ghost))
                (w (buffer-local-value 'dsh-emacs--modeline-context-window-server ghost)))
            (ert-info ((format "%s" "complete-row-still-updates-ctx-snapshot"))
              (should (and (= 129946 p) (= 262144 w))))))
      (setq dsh-emacs--sessions old-sessions)
      (when (buffer-live-p ghost) (kill-buffer ghost)))))

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
(ert-deftest dsh-emacs-test-lifecycle-zero-projection-frame-keeps-ctx-snapshot ()
  :tags '(dsh-unit)
  (let* ((dsh-emacs--chat-buffers (make-hash-table :test #'equal))
         (old-sessions dsh-emacs--sessions)
         (buf (generate-new-buffer " *t43g-chat*")))
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
          (ert-info ((format "%s" "zero-projection-frame-keeps-ctx-snapshot"))
            (should (= 66617 (buffer-local-value 'dsh-emacs--modeline-context-pressure buf)))
            (should (= 1000000 (buffer-local-value 'dsh-emacs--modeline-context-window-server buf))))
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
          (ert-info ((format "%s" "submit-after-error-keeps-ctx-snapshot"))
            (should (= 66617 (buffer-local-value 'dsh-emacs--modeline-context-pressure buf)))
            (should (= 1000000 (buffer-local-value 'dsh-emacs--modeline-context-window-server buf))))
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
          (ert-info ((format "%s" "zero-pressure-list-row-keeps-ctx-snapshot"))
            (should (= 66617 (buffer-local-value 'dsh-emacs--modeline-context-pressure buf)))
            (should (= 1000000 (buffer-local-value 'dsh-emacs--modeline-context-window-server buf))))
          ;; The next real usage sample lands as usual (the projection recovers after a
          ;; successful run)
          (dsh-emacs--events-apply-context-projection
           "sess-zero"
           '((projectedTokens . 70123) (pressureTokens . 70000)
             (contextWindow . 1000000)))
          (ert-info ((format "%s" "positive-projection-still-updates-ctx-snapshot"))
            (should (= 70123 (buffer-local-value 'dsh-emacs--modeline-context-pressure buf)))
            (should (= 1000000 (buffer-local-value 'dsh-emacs--modeline-context-window-server buf)))))
      (remhash "sess-zero" dsh-emacs--chat-buffers)
      (setq dsh-emacs--sessions old-sessions)
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest dsh-emacs-test-lifecycle-context-projection-only-updates-target ()
  :tags '(dsh-unit)
  (let* ((dsh-emacs--chat-buffers (make-hash-table :test #'equal))
         (target (generate-new-buffer " *context-projection-target*"))
         (wire '((pressureTokens . 70) (projectedTokens . 73)
                 (contextWindow . 200)))
         (frame `((sessionId . "context-target")
                  (key . contextPressure) (value . ,wire)))
         (payloads (list frame (dsh-protocol-projection--from-alist frame))))
    (unwind-protect
        (with-temp-buffer
          (setq-local dsh-emacs--buffer-session "unrelated"
                      dsh-emacs--modeline-context-pressure 17
                      dsh-emacs--modeline-context-window-server 19)
          (puthash "context-target" target dsh-emacs--chat-buffers)
          (dolist (payload payloads)
            (with-current-buffer target
              (setq-local dsh-emacs--buffer-session "context-target"
                          dsh-emacs--modeline-context-pressure 100
                          dsh-emacs--modeline-context-window-server 1000))
            (dsh-emacs-events--host-apply-projection nil payload)
            (should (= 73 (buffer-local-value
                           'dsh-emacs--modeline-context-pressure target)))
            (should (= 200 (buffer-local-value
                            'dsh-emacs--modeline-context-window-server target)))
            (should (= 17 dsh-emacs--modeline-context-pressure))
            (should (= 19 dsh-emacs--modeline-context-window-server)))
          ;; A stale table entry and a session with no entry must both leave
          ;; the unrelated current buffer untouched, for raw and typed input.
          (kill-buffer target)
          (dolist (session '("context-target" "missing"))
            (let ((update `((sessionId . ,session)
                            (key . contextPressure) (value . ,wire))))
              (dolist (payload (list update
                                     (dsh-protocol-projection--from-alist update)))
                (dsh-emacs-events--host-apply-projection nil payload)
                (should (= 17 dsh-emacs--modeline-context-pressure))
                (should (= 19 dsh-emacs--modeline-context-window-server))))))
      (when (buffer-live-p target) (kill-buffer target)))))

;; --- Test 43h: the `permissions' projection drives the mode-line segment ---
;; dsh 0.1.6 narrowed the projection to `{currentValue}'; the selectable
;; options moved to the permissionPresets/catalog Remote.  A configured key
;; and the derived `custom' both display; an absent/unknown value must not
;; clear the segment or guess.
(ert-deftest dsh-emacs-test-lifecycle-permission-projection-sets-segment ()
  :tags '(dsh-unit)
  (let ((dsh-emacs--chat-buffers (make-hash-table :test #'equal))
        (buf (generate-new-buffer " *t43h-chat*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (setq-local dsh-emacs--buffer-session "sess-perm"))
          (puthash "sess-perm" buf dsh-emacs--chat-buffers)
          (dsh-emacs-events--host-apply-projection
           nil '((sessionId . "sess-perm") (key . "permissions")
                 (value . ((currentValue . "workspace-write")))))
          (ert-info ((format "%s" "permission-projection-sets-segment"))
            (should (equal "workspace-write"
                           (buffer-local-value 'dsh-emacs--modeline-permission buf))))
          (dsh-emacs-events--host-apply-projection
           nil '((sessionId . "sess-perm") (key . "permissions")
                 (value . ((currentValue . "custom")))))
          (ert-info ((format "%s" "permission-projection-replaces-value"))
            (should (equal "custom"
                           (buffer-local-value 'dsh-emacs--modeline-permission buf))))
          (dolist (value '("auto" " host-defined "))
            (dsh-emacs-events--host-apply-projection
             nil `((sessionId . "sess-perm") (key . "permissions")
                   (value . (("currentValue" . ,value)))))
            (should (equal value
                           (buffer-local-value 'dsh-emacs--modeline-permission buf))))
          (dolist (projection '(nil ((currentValue . "")) ((somethingElse . 1))
                                ((currentValue . 7)) ((currentValue . :json-false))
                                "workspace-write"))
            (dsh-emacs-events--host-apply-projection
             nil `((sessionId . "sess-perm") (key . "permissions")
                   (value . ,projection)))
            (ert-info ((format "Ignored permission projection: %S" projection))
              (should (equal " host-defined "
                             (buffer-local-value
                              'dsh-emacs--modeline-permission buf))))))
      (remhash "sess-perm" dsh-emacs--chat-buffers)
      (when (buffer-live-p buf) (kill-buffer buf)))))

;; --- Test 50: fork session ---
(ert-deftest dsh-emacs-test-lifecycle-fork-default-omits-event-boundary ()
  :tags '(dsh-unit)
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
      (ert-info ((format "%s" "fork-default-omits-event-boundary"))
        (should (equal (car calls)
                       '("session/fork" ((request . ((sessionId . "parent-1"))))))))
      (ert-info ((format "%s" "fork-opens-child"))
        (should (equal "child-1" opened)))
      (ert-info ((format "%s" "fork-refreshes-list"))
        (should listed))
      (dsh-emacs-fork-session "parent-1" 0)
      (ert-info ((format "%s" "fork-accepts-zero-boundary"))
        (should (equal (car calls)
                       '("session/fork"
                         ((request . ((sessionId . "parent-1") (atSeq . 0)))))))))))

;; Fork uses the selected durable reply, even inside a code block, never
;; the newest reply or the globally selected session.
(ert-deftest dsh-emacs-test-lifecycle-fork-message-selects-exact-reply-and-buffer-session ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (setq dsh-emacs--buffer-session "parent-at-point")
    (let ((dsh-emacs--current-session "another-session")
          (calls nil))
      (cl-letf (((symbol-function 'dsh-emacs-server-ensure) #'ignore)
                ((symbol-function 'dsh-emacs--rpc-async)
                 (lambda (method params _cb) (push (list method params) calls))))
        (dolist (entry '((17 . "```elisp\nchosen-reply\n```")
                         (29 . "newest-reply")))
          (dsh-emacs-render-event
           `((type . "assistant/message") (seq . ,(car entry))
             (data . ((turn . ,(car entry)) (step . 1)
                      (message . ((content . [((type . "text")
                                               (text . ,(cdr entry)))]))))))))
        (goto-char (point-min))
        (search-forward "chosen-reply")
        (call-interactively (lookup-key dsh-emacs-mode-map (kbd "C-c C-y")))
        (ert-info ((format "%s" "fork-message-selects-exact-reply-and-buffer-session"))
          (should (equal calls
                         '(("session/fork"
                            ((request . ((sessionId . "parent-at-point")
                                         (atSeq . 17)))))))))
        (dsh-emacs-render-user-message
         '((type . "user/message") (seq . 30)
           (data . ((content . [((type . "text") (text . "user-input"))])))))
        (goto-char (point-min))
        (search-forward "user-input")
        (ert-info ((format "%s" "fork-rejects-user-message-without-rpc"))
          (should (condition-case err (progn (dsh-emacs-fork-message-at-point) nil)
                    (user-error (equal (cadr err)
                                       "Point is not on a committed assistant reply"))))
          (should (= (length calls) 1)))
        (goto-char (point-max))
        (ert-info ((format "%s" "fork-rejects-composer-without-rpc"))
          (should (condition-case nil (progn (dsh-emacs-fork-message-at-point) nil)
                    (user-error t)))
          (should (= (length calls) 1)))))))

;; Settled live blocks and idle Markdown must retain the durable seq;
;; the same visible text is not forkable before assistant/message arrives.
(ert-deftest dsh-emacs-test-lifecycle-fork-rejects-uncommitted-stream ()
  :tags '(dsh-unit)
  (dolist (defer '(nil 1))
    (with-temp-buffer
      (dsh-emacs-mode)
      (setq dsh-emacs--buffer-session "stream-parent")
      (let ((dsh-emacs-stream-markdown-limit defer)
            (calls nil))
        (cl-letf (((symbol-function 'dsh-emacs-server-ensure) #'ignore)
                  ((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (_method params _cb) (push params calls))))
          (dsh-emacs-render--start-assistant-stream
           '((data . ((turn . 1) (step . 1)))) "**settled-prefix**")
          (dsh-emacs-render--start-thinking-stream
           '((data . ((turn . 1) (step . 1)))) "thinking")
          (dsh-emacs-render--start-assistant-stream
           '((data . ((turn . 1) (step . 1)))) "streamed-answer")
          (goto-char (point-min))
          (search-forward "streamed-answer")
          (backward-char)
          (ert-info ((format "%s" "fork-rejects-uncommitted-stream"))
            (should (condition-case nil (progn (dsh-emacs-fork-message-at-point) nil)
                      (user-error t)))
            (should (null calls)))
          (dsh-emacs-render-event
           '((type . "assistant/message") (seq . 43)
             (data . ((turn . 1) (step . 1)
                      (message . ((content . [((type . "text")
                                               (text . "**settled-prefix**"))
                                              ((type . "reasoning")
                                               (text . "thinking"))
                                              ((type . "text")
                                               (text . "streamed-answer"))])))))))
          (while dsh-emacs--markdown-pending
            (dsh-emacs-render--run-markdown (current-buffer)))
          (dolist (body '("settled-prefix" "streamed-answer"))
            (goto-char (point-min))
            (search-forward body)
            (backward-char)
            (dsh-emacs-fork-message-at-point))
          (ert-info ((format "%s" "fork-settled-stream-keeps-durable-boundary"))
            (should (equal calls
                           '(((request . ((sessionId . "stream-parent")
                                          (atSeq . 43))))
                             ((request . ((sessionId . "stream-parent")
                                          (atSeq . 43))))))))
          (setq dsh-emacs--buffer-subagent
                (dsh-protocol-subagent-address-create
                 "parent" "child" "continuable"))
          (ert-info ((format "%s" "fork-message-rejects-subagent-without-rpc"))
            (should (condition-case err (progn (dsh-emacs-fork-message-at-point) nil)
                      (user-error (equal (cadr err)
                                         "This command is unavailable in a subagent conversation"))))
            (should (= (length calls) 2))))))))

;; --- Test 58: archive session (workspace/archiveSession) ---
;; server has no session.delete, so archiving is the only removal
;; path; the response is the full archive set.
(ert-deftest dsh-emacs-test-lifecycle-archive-passes-session-id ()
  :tags '(dsh-unit)
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
        (ert-info ((format "%s" "archive-passes-session-id"))
          (should (and (string= "workspace/archiveSession" method)
                       (string= "s3"
                                (cdr (assq 'sessionId
                                           (cdr (assq 'request params)))))))))
      (ert-info ((format "%s" "archive-updates-archived-set"))
        (should (and (gethash "s1" dsh-emacs--archived-sessions)
                     (gethash "s2" dsh-emacs--archived-sessions)
                     (not (gethash "s3" dsh-emacs--archived-sessions)))))
      (ert-info ((format "%s" "archive-refreshes-list"))
        (should listed)))))

;; --- Test 58b: unarchive session (workspace/unarchiveSession, dsh 0.1.6) ---
;; The inverse of Test 58: the response is the complete remaining archive
;; set, so the cache is replaced wholesale (the host is idempotent for an
;; id it no longer holds archived).
(ert-deftest dsh-emacs-test-lifecycle-unarchive-passes-session-id ()
  :tags '(dsh-unit)
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
      (ert-info ((format "%s" "unarchive-passes-session-id"))
        (should (let* ((call (car calls))
                       (params (cadr call)))
                  (and (string= "workspace/unarchiveSession" (car call))
                       (string= "s2"
                                (cdr (assq 'sessionId
                                           (cdr (assq 'request params)))))))))
      (ert-info ((format "%s" "unarchive-updates-archived-set"))
        (should (and (gethash "s1" dsh-emacs--archived-sessions)
                     (not (gethash "s2" dsh-emacs--archived-sessions)))))
      (ert-info ((format "%s" "unarchive-refreshes-list"))
        (should listed)))))

;; --- Test 58c: the unarchive picker offers only archived rows ---
;; `dsh-emacs--completing-session-id' grew an optional FILTER; an empty
;; candidate set must surface EMPTY-MESSAGE as a user-error rather than
;; letting `completing-read' fail on an empty collection.
(ert-deftest dsh-emacs-test-lifecycle-unarchive-picker-offers-archived-only ()
  :tags '(dsh-unit)
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
      (ert-info ((format "%s" "unarchive-picker-offers-archived-only"))
        (should (let ((picked (dsh-emacs--completing-session-id
                               "Unarchive session: " #'dsh-emacs--archived-session-p
                               "No archived session can be restored")))
                  (and (= 1 (length offered))
                       (string-match-p "gone" (car offered))
                       (equal "gone" picked)))))
      (let ((dsh-emacs--archived-sessions nil))
        (ert-info ((format "%s" "unarchive-picker-empty-user-error"))
          (should (equal "No archived session can be restored"
                         (condition-case err
                             (dsh-emacs--completing-session-id
                              "Unarchive session: " #'dsh-emacs--archived-session-p
                              "No archived session can be restored")
                           (user-error (error-message-string err))))))))))

;; --- Test 59: rename session at point ---
;; The r key in the list should act on the session at point like
;; archive (the D key), taking id + new title from the text property,
;; with no completing-read.
(ert-deftest dsh-emacs-test-lifecycle-rename-at-point-uses-point-session ()
  :tags '(dsh-unit)
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
              (ert-info ((format "%s" "rename-at-point-uses-point-session"))
                (should (and (string= "session/rename" (car call))
                             (string= "sid-1" (cdr (assq 'sessionId req)))
                             (string= "renamed" (cdr (assq 'title req)))))))))
      (kill-buffer buf))))

;; --- Test 59b: rename the session owned by the current chat buffer ---
;; The rename command inside a chat buffer must target that buffer's
;; session and prefill the current title; the session picker must not run.
(ert-deftest dsh-emacs-test-lifecycle-rename-chat-uses-buffer-session ()
  :tags '(dsh-unit)
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
            (ert-info ((format "%s" "rename-chat-uses-buffer-session"))
              (should (equal "session/rename" (car call)))
              (should (equal "sid-chat" (cdr (assq 'sessionId req))))
              (should (equal "New title" (cdr (assq 'title req)))))
            (ert-info ((format "%s" "rename-chat-prefills-current-title"))
              (should (equal "Old title" prefill)))))
      (setq dsh-emacs--sessions old)
      (when (buffer-live-p buf) (kill-buffer buf)))))

;; --- Test 63: the session/title event updates the title live
;; (server auto-rename) ---
;; The server auto-renames after the first 1-2 dialogue turns (summary
;; title) and broadcasts a `session/title' event over the follow stream;
;; the emacs side should do it live: update the cached title-value,
;; rename the already-open chat buffer, redraw the session list --
;; without waiting for a session/list refresh.
(ert-deftest dsh-emacs-test-lifecycle-title-event-updates-cache ()
  :tags '(dsh-unit)
  (let* ((old-sessions dsh-emacs--sessions)
         (old-buffers dsh-emacs--chat-buffers)
         (item (list (cons 'sessionId "sess-title")
                     (cons 'blank :json-false)
                     (cons 'title "old title")
                     (cons 'projections
                           (list (cons 'values
                                       (list (cons 'title "old title")))))))
         (chat-buf (generate-new-buffer " *dsh-test-title-chat*"))
         (list-buf (generate-new-buffer "*dsh-sessions*"))
         (proc (make-pipe-process :name "t-title" :buffer nil))
         (old-sessions-buffer dsh-emacs--sessions-buffer)
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
            (setq dsh-emacs--sessions-buffer (buffer-name)))
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
            (ert-info ((format "%s" "title-event-updates-cache"))
              (should (and cached
                           (equal "auto summary title"
                                  (dsh-protocol-session-title-value cached))))))
          ;; 2) The list buffer line is redrawn with the new title
          (ert-info ((format "%s" "title-event-repaints-list"))
            (should (string-match-p "auto summary title"
                                    (with-current-buffer list-buf
                                      (buffer-string)))))
          ;; 3) The open chat buffer has been renamed
          (ert-info ((format "%s" "title-event-renames-chat-buffer"))
            (should (string-match-p "auto summary title" (buffer-name chat-buf)))))
      (setq dsh-emacs--sessions old-sessions)
      (setq dsh-emacs--chat-buffers old-buffers)
      (setq dsh-emacs--sessions-buffer old-sessions-buffer)
      (when (buffer-live-p chat-buf) (kill-buffer chat-buf))
      (when (buffer-live-p list-buf) (kill-buffer list-buf))
      (when (process-live-p proc) (delete-process proc)))))

;; --- Test 64: a new workspace session joins that workspace, and the
;; title event clears blank ---
;; Regression: the session/create callback used to only open the
;; session, so the new session did not enter the cache/workspace
;; session-ids -> grouping fell to ungrouped, and the session/title
;; event could not find the cached item, blank was not cleared ->
;; auto-rename never took effect.
(ert-deftest dsh-emacs-test-lifecycle-new-session-cached-after-create ()
  :tags '(dsh-unit)
  (let* ((old-sessions dsh-emacs--sessions)
         (old-workspaces dsh-emacs--workspaces)
         (old-buffers dsh-emacs--chat-buffers)
         (ws (dsh-protocol-workspace--from-alist
              (list (cons 'workspaceId "w-empty")
                    (cons 'title "Empty WS")
                    (cons 'path "/tmp/dsh-empty-ws")
                    (cons 'sessionIds []))))
         (chat-buf (generate-new-buffer " *dsh-test-ws-create*")))
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
          (ert-info ((format "%s" "new-session-cached-after-create"))
            (should (dsh-emacs--chat-session-item "s-new")))
          ;; 2) workspace session-ids has absorbed the new session
          (let ((w (car dsh-emacs--workspaces)))
            (ert-info ((format "%s" "new-session-attached-to-workspace"))
              (should (member "s-new" (dsh-protocol-workspace-session-ids w)))))
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
            (ert-info ((format "%s" "new-session-grouped-in-workspace-not-ungrouped"))
              (should (and ws-group
                           (member "s-new"
                                   (mapcar #'dsh-protocol-session-session-id
                                           (plist-get ws-group :sessions)))
                           (not (member "s-new"
                                        (mapcar #'dsh-protocol-session-session-id
                                                (and ungrouped
                                                     (plist-get ungrouped :sessions)))))))))
          ;; 4) The title event arrives: blank is cleared + title-value
          ;; updated -> the displayed title is no longer
          ;;    "New Session"
          (dsh-emacs-events--apply-title chat-buf "s-new" "auto summary name")
          (let* ((item (dsh-emacs--chat-session-item "s-new"))
                 (blank (dsh-protocol-session-blank item))
                 (shown (dsh-emacs-session--display-title item)))
            (ert-info ((format "%s" "title-event-clears-blank-and-updates-title"))
              (should (and item
                           (not (and blank (not (eq blank :json-false))))
                           (equal "auto summary name" shown))))))
      (setq dsh-emacs--sessions old-sessions)
      (setq dsh-emacs--workspaces old-workspaces)
      (setq dsh-emacs--chat-buffers old-buffers)
      (when (buffer-live-p chat-buf) (kill-buffer chat-buf)))))

;; --- Test 64b: the $events api-session/added arrives first (session
;; enters cache), then the RPC callback ---
;; Regression: cache-new-session used a single not-cached guard around
;; "enter cache + workspace attach". When the core stream (the
;; api-session/added emit of $events) arrived before the session/create
;; callback, the session was already in the cache -> the whole when was
;; skipped -> the workspace was not attached and the new session fell
;; into Ungrouped. Now attach runs independently of cache insertion
;; (idempotent), so the race window no longer loses ownership.
(ert-deftest dsh-emacs-test-lifecycle-host-first-cache-no-duplicate ()
  :tags '(dsh-unit)
  (let* ((old-sessions dsh-emacs--sessions)
         (old-workspaces dsh-emacs--workspaces)
         (old-sessions-buffer dsh-emacs--sessions-buffer)
         (ws (dsh-protocol-workspace--from-alist
              (list (cons 'workspaceId "w-race")
                    (cons 'title "Race WS")
                    (cons 'path "/tmp/race-ws")
                    (cons 'sessionIds []))))
         (list-buf (generate-new-buffer " *dsh-race-list*")))
    (unwind-protect
        (progn
          (setq dsh-emacs--sessions nil)
          (setq dsh-emacs--workspaces (list ws))
          (setq dsh-emacs--sessions-buffer (buffer-name list-buf))
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
          (ert-info ((format "%s" "host-first-cache-no-duplicate"))
            (should (= 1 (length dsh-emacs--sessions))))
          ;; Assertion: the workspace is attached (the race fix point)
          (let ((w (car dsh-emacs--workspaces)))
            (ert-info ((format "%s" "host-first-still-attaches-to-workspace"))
              (should (and w
                           (member "s-new"
                                   (dsh-protocol-workspace-session-ids w))))))
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
            (ert-info ((format "%s" "host-first-grouped-in-workspace"))
              (should (and ws-group
                           (member "s-new"
                                   (mapcar #'dsh-protocol-session-session-id
                                           (plist-get ws-group :sessions))))))))
      (setq dsh-emacs--sessions old-sessions)
      (setq dsh-emacs--workspaces old-workspaces)
      (setq dsh-emacs--sessions-buffer old-sessions-buffer)
      (when (buffer-live-p list-buf) (kill-buffer list-buf)))))

;; --- Test 78: a new session carries agentPreset ---
;; Calling directly with a preset -> the session/create params contain
;; agentPreset (both the cwd and workspaceId contexts); the agentPreset in
;; the response enters the placeholder cache row (immediately visible in the
;; list detail/footer); without a preset -> no agentPreset is sent.
(ert-deftest dsh-emacs-test-lifecycle-new-session-with-preset-sends-agent-preset ()
  :tags '(dsh-unit)
  (let* ((dsh-emacs--chat-buffers (make-hash-table :test #'equal))
         (dsh-emacs--current-session nil)
         (dsh-emacs--current-buffer nil)
         (dsh-emacs--sessions nil)
         (dsh-emacs--workspaces nil)
         (old-sessions dsh-emacs--sessions))
    (unwind-protect
        (progn
          (setq dsh-emacs--sessions nil)
          ;; with preset (cwd context)
          (let ((calls nil)
                (dsh-emacs-new-session-auto-project nil))
            (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                       (lambda (method params cb)
                         (push (list method params) calls)
                         (funcall cb t `((sessionId . ,(cdr (assq 'sessionId
                                                                  (cdr (assq 'request params)))))
                                         (agentPreset . "standard")))))
                      ((symbol-function 'pop-to-buffer)
                       (lambda (buffer &rest _) buffer))
                      ((symbol-function 'dsh-emacs--activate-chat-buffer)
                       (lambda (sid buffer &optional _address)
                         (puthash sid buffer dsh-emacs--chat-buffers)
                         (with-current-buffer buffer
                           (setq-local dsh-emacs--buffer-session sid)
                           (dsh-emacs--chat-buffer-sync sid)
                           (dsh-emacs-mode)))))
              (dsh-emacs-new-session nil nil "standard")
              (let* ((call (car calls))
                     (params (cadr call)))
                (ert-info ((format "%s" "new-session-with-preset-sends-agent-preset"))
                  (should (and (string= "session/create" (car call))
                               (null (assq 'workspaceId (cdr (assq 'request params))))
                               (assq 'cwd (cdr (assq 'request params)))
                               (string= "standard"
                                        (cdr (assq 'agentPreset (cdr (assq 'request params)))))))))
              ;; the placeholder cache row carries the preset
              ;; (written back from the response)
              (let ((item (dsh-emacs--chat-session-item
                           (cdr (assq 'sessionId
                                      (cdr (assq 'request (cadar calls))))))))
                (ert-info ((format "%s" "new-session-preset-cached-in-placeholder"))
                  (should (and item
                               (string= "standard"
                                        (dsh-protocol-session-agent-preset item))))))))
          ;; with preset (workspace context): workspaceId and agentPreset coexist
          (let ((calls nil))
            (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                       (lambda (method params cb)
                         (push (list method params) calls)
                         (funcall cb t `((sessionId . ,(cdr (assq 'sessionId
                                                                  (cdr (assq 'request params)))))))))
                      ((symbol-function 'pop-to-buffer)
                       (lambda (buffer &rest _) buffer))
                      ((symbol-function 'dsh-emacs--activate-chat-buffer)
                       (lambda (sid buffer &optional _address)
                         (puthash sid buffer dsh-emacs--chat-buffers)
                         (with-current-buffer buffer
                           (setq-local dsh-emacs--buffer-session sid)
                           (dsh-emacs--chat-buffer-sync sid)
                           (dsh-emacs-mode)))))
              (dsh-emacs-new-session nil "w1" "ptc")
              (let* ((call (car calls))
                     (params (cadr call)))
                (ert-info ((format "%s" "new-session-workspace-with-preset"))
                  (should (and (string= "session/create" (car call))
                               (string= "w1" (cdr (assq 'workspaceId (cdr (assq 'request params)))))
                               (null (assq 'cwd (cdr (assq 'request params))))
                               (string= "ptc" (cdr (assq 'agentPreset (cdr (assq 'request params)))))))))))
          ;; no preset -> no agentPreset sent
          (let ((calls nil)
                (dsh-emacs-new-session-auto-project nil))
            (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                       (lambda (method params cb)
                         (push (list method params) calls)
                         (funcall cb t `((sessionId . ,(cdr (assq 'sessionId
                                                                  (cdr (assq 'request params)))))))))
                      ((symbol-function 'pop-to-buffer)
                       (lambda (buffer &rest _) buffer))
                      ((symbol-function 'dsh-emacs--activate-chat-buffer)
                       (lambda (sid buffer &optional _address)
                         (puthash sid buffer dsh-emacs--chat-buffers)
                         (with-current-buffer buffer
                           (setq-local dsh-emacs--buffer-session sid)
                           (dsh-emacs--chat-buffer-sync sid)
                           (dsh-emacs-mode)))))
              (dsh-emacs-new-session nil nil nil)
              (let* ((call (car calls))
                     (params (cadr call)))
                (ert-info ((format "%s" "new-session-without-preset-omits-agent-preset"))
                  (should (and (string= "session/create" (car call))
                               (null (assq 'agentPreset (cdr (assq 'request params)))))))))))
      (maphash (lambda (_id chat)
                 (when (buffer-live-p chat) (kill-buffer chat)))
               dsh-emacs--chat-buffers)
      (setq dsh-emacs--sessions old-sessions))))

;; --- Test 79: interactive with a prefix argument -> pick the preset first,
;; then create ---
;; call-interactively under C-u: the interactive spec reads a preset
;; (completing-read mock returns a display name), session/create carries its
;; id, and agentPresets/list was triggered.
(ert-deftest dsh-emacs-test-lifecycle-new-session-prefix-asks-preset ()
  :tags '(dsh-unit)
  (let* ((dsh-emacs--chat-buffers (make-hash-table :test #'equal))
         (dsh-emacs--current-session nil)
         (dsh-emacs--current-buffer nil)
         (dsh-emacs--sessions nil)
         (dsh-emacs--workspaces nil)
         (old-sessions dsh-emacs--sessions)
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
                         (funcall cb t `((sessionId . ,(cdr (assq 'sessionId
                                                                  (cdr (assq 'request params))))))))))
                    ((symbol-function 'pop-to-buffer)
                     (lambda (buffer &rest _) buffer))
                    ((symbol-function 'dsh-emacs--activate-chat-buffer)
                     (lambda (sid buffer &optional _address)
                       (puthash sid buffer dsh-emacs--chat-buffers)
                       (with-current-buffer buffer
                         (setq-local dsh-emacs--buffer-session sid)
                         (dsh-emacs--chat-buffer-sync sid)
                         (dsh-emacs-mode))))
                    ((symbol-function 'completing-read)
                     (lambda (&rest _) "Minimal mode"))
                    (current-prefix-arg '(4)))
            (call-interactively #'dsh-emacs-new-session))
          (let ((create (cl-find-if
                         (lambda (c) (string= "session/create" (car c)))
                         calls)))
            (ert-info ((format "%s" "new-session-prefix-asks-preset"))
              (should (and create
                           (string= "minimal"
                                    (cdr (assq 'agentPreset
                                               (cdr (assq 'request (cadr create))))))
                           (member "agentPresets/list" (mapcar #'car calls)))))))
      (maphash (lambda (_id chat)
                 (when (buffer-live-p chat) (kill-buffer chat)))
               dsh-emacs--chat-buffers)
      (setq dsh-emacs--sessions old-sessions)
      (setq dsh-emacs--agent-presets old-cache)
      (when (buffer-live-p buf) (kill-buffer buf)))))

;; --- Test 80: list key c = create immediately with the default preset, C =
;; pick a preset first ---
;; c -> dsh-emacs-new-session (no chooser; the session carries
;; dsh-emacs-default-preset, nil means host default, no agentPreset sent and
;; no roster fetched); C -> dsh-emacs-new-session-choose-preset (pick a
;; preset first, then create; the workspace context carries over and an
;; agentPresets/list refresh is triggered).
(ert-deftest dsh-emacs-test-lifecycle-session-map-c-binds-plain-create ()
  :tags '(dsh-unit)
  (ert-info ((format "%s" "session-map-c-binds-plain-create"))
    (should (eq (lookup-key dsh-emacs-session-mode-map "c")
                #'dsh-emacs-new-session))))

(ert-deftest dsh-emacs-test-lifecycle-session-map-c-binds-preset-choose ()
  :tags '(dsh-unit)
  (ert-info ((format "%s" "session-map-C-binds-preset-choose"))
    (should (eq (lookup-key dsh-emacs-session-mode-map "C")
                #'dsh-emacs-new-session-choose-preset))))

;; c path: interactive without a prefix ->
;; only session/create is sent, with no agentPreset
(ert-deftest dsh-emacs-test-lifecycle-session-c-creates-without-preset-prompt ()
  :tags '(dsh-unit)
  (let* ((dsh-emacs--chat-buffers (make-hash-table :test #'equal))
         (dsh-emacs--current-session nil)
         (dsh-emacs--current-buffer nil)
         (dsh-emacs--sessions nil)
         (dsh-emacs--workspaces nil)
         (calls nil)
         (buf (generate-new-buffer " *dsh-c-default-create*"))
         (dsh-emacs-new-session-auto-project nil))
    (unwind-protect
        (with-current-buffer buf
          (insert "row text\n")
          (goto-char (point-min))
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method params cb)
                       (push (list method params) calls)
                       (funcall cb t `((sessionId . ,(cdr (assq 'sessionId
                                                                (cdr (assq 'request params)))))))))
                    ((symbol-function 'pop-to-buffer)
                     (lambda (buffer &rest _) buffer))
                    ((symbol-function 'dsh-emacs--activate-chat-buffer)
                     (lambda (sid buffer &optional _address)
                       (puthash sid buffer dsh-emacs--chat-buffers)
                       (with-current-buffer buffer
                         (setq-local dsh-emacs--buffer-session sid)
                         (dsh-emacs--chat-buffer-sync sid)
                         (dsh-emacs-mode)))))
            (call-interactively #'dsh-emacs-new-session))
          (let* ((call (car calls))
                 (params (cadr call)))
            (ert-info ((format "%s" "session-c-creates-without-preset-prompt"))
              (should (and (string= "session/create" (car call))
                           (null (assq 'agentPreset (cdr (assq 'request params))))
                           (not (member "agentPresets/list" (mapcar #'car calls))))))))
      (maphash (lambda (_id chat)
                 (when (buffer-live-p chat) (kill-buffer chat)))
               dsh-emacs--chat-buffers)
      (when (buffer-live-p buf) (kill-buffer buf)))))

;; C path: pick a preset first (completing-read mock returns a display name),
;; create in the workspace context -> session/create carries workspaceId +
;; agentPreset, and the roster was triggered.
(ert-deftest dsh-emacs-test-lifecycle-session-c-creates-with-chosen-preset ()
  :tags '(dsh-unit)
  (let* ((dsh-emacs--chat-buffers (make-hash-table :test #'equal))
         (dsh-emacs--current-session nil)
         (dsh-emacs--current-buffer nil)
         (dsh-emacs--sessions nil)
         (dsh-emacs--workspaces nil)
         (calls nil)
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
                 '((presets . [((id . "ptc") (name . "PTC mode"))]))))
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method params cb)
                       (push (list method params) calls)
                       (when (string= method "session/create")
                         (funcall cb t `((sessionId . ,(cdr (assq 'sessionId
                                                                  (cdr (assq 'request params))))))))))
                    ((symbol-function 'pop-to-buffer)
                     (lambda (buffer &rest _) buffer))
                    ((symbol-function 'dsh-emacs--activate-chat-buffer)
                     (lambda (sid buffer &optional _address)
                       (puthash sid buffer dsh-emacs--chat-buffers)
                       (with-current-buffer buffer
                         (setq-local dsh-emacs--buffer-session sid)
                         (dsh-emacs--chat-buffer-sync sid)
                         (dsh-emacs-mode))))
                    ((symbol-function 'completing-read)
                     (lambda (&rest _) "PTC mode")))
            (call-interactively #'dsh-emacs-new-session-choose-preset))
          (let ((create (cl-find-if
                         (lambda (c) (string= "session/create" (car c)))
                         calls)))
            (ert-info ((format "%s" "session-C-creates-with-chosen-preset"))
              (should (and create
                           (string= "w-C" (cdr (assq 'workspaceId
                                                     (cdr (assq 'request (cadr create))))))
                           (string= "ptc" (cdr (assq 'agentPreset
                                                      (cdr (assq 'request (cadr create))))))
                           (member "agentPresets/list" (mapcar #'car calls)))))))
      (setq dsh-emacs--agent-presets old-cache)
      (maphash (lambda (_id chat)
                 (when (buffer-live-p chat) (kill-buffer chat)))
               dsh-emacs--chat-buffers)
      (when (buffer-live-p buf) (kill-buffer buf)))))

;; C path with a cold roster cache: fetch the roster synchronously before
;; prompting, instead of creating with the unchosen host default.
(ert-deftest dsh-emacs-test-lifecycle-choose-preset-fetches-cold-roster ()
  :tags '(dsh-unit)
  (let* ((dsh-emacs--chat-buffers (make-hash-table :test #'equal))
         (dsh-emacs--current-session nil)
         (dsh-emacs--current-buffer nil)
         (dsh-emacs--sessions nil)
         (dsh-emacs--workspaces nil)
         (calls nil)
         (fetched nil)
         (prompted nil)
         (offered nil)
         (old-cache dsh-emacs--agent-presets)
         (buf (generate-new-buffer " *dsh-C-cold-preset*")))
    (unwind-protect
        (with-current-buffer buf
          (insert "  workspace row")
          (put-text-property (point-min) (point-max)
                             'dsh-emacs-workspace-id "w-cold")
          (goto-char (point-min))
          (setq dsh-emacs--agent-presets nil)
          (cl-letf (((symbol-function 'dsh-emacs--rpc-request)
                     (lambda (method _params)
                       (setq fetched method)
                       (cons t '((presets . [((id . "ptc")
                                              (name . "PTC mode"))])))))
                    ((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method params cb)
                       (push (list method params) calls)
                       (when (string= method "session/create")
                         (funcall cb t `((sessionId . ,(cdr (assq 'sessionId
                                                                  (cdr (assq 'request params))))))))))
                    ((symbol-function 'pop-to-buffer)
                     (lambda (buffer &rest _) buffer))
                    ((symbol-function 'dsh-emacs--activate-chat-buffer)
                     (lambda (sid buffer &optional _address)
                       (puthash sid buffer dsh-emacs--chat-buffers)
                       (with-current-buffer buffer
                         (setq-local dsh-emacs--buffer-session sid)
                         (dsh-emacs--chat-buffer-sync sid)
                         (dsh-emacs-mode))))
                    ((symbol-function 'completing-read)
                     (lambda (_prompt collection &rest _)
                       (setq prompted t offered collection)
                       "PTC mode"))
                    (current-prefix-arg nil))
            (call-interactively #'dsh-emacs-new-session-choose-preset))
          (let ((create (cl-find-if
                         (lambda (c) (string= "session/create" (car c)))
                         calls)))
            (ert-info ((format "%s" "choose-preset-fetches-cold-roster"))
              (should prompted)
              (should (equal "agentPresets/list" fetched))
              (should (equal '(("PTC mode" . "ptc")) offered))
              (should-not (member "agentPresets/list" (mapcar #'car calls)))
              (should (and create
                           (string= "ptc"
                                    (cdr (assq 'agentPreset
                                               (cdr (assq 'request
                                                          (cadr create)))))))))))
      (setq dsh-emacs--agent-presets old-cache)
      (maphash (lambda (_id chat)
                 (when (buffer-live-p chat) (kill-buffer chat)))
               dsh-emacs--chat-buffers)
      (when (buffer-live-p buf) (kill-buffer buf)))))

;; A fork rejected because the source session's preset vanished explains the
;; preset and lists the ids the server still provides, instead of dumping the
;; raw error alist into the echo area.
(ert-deftest dsh-emacs-test-lifecycle-fork-missing-preset-lists-available ()
  :tags '(dsh-unit)
  (let ((messages nil)
        (value '((code . "agent-preset/not-found")
                 (message . "Unknown agent preset: focused-investigation")
                 (details . ((agentPreset . "focused-investigation")
                             (available . ["standard" "ptc" "tiny"]))))))
    (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
               (lambda (method _params cb)
                 (when (string= method "session/fork")
                   (funcall cb nil value))))
              ((symbol-function 'message)
               (lambda (format-string &rest args)
                 (push (apply #'format format-string args) messages))))
      (dsh-emacs-fork-session "parent-1")
      (ert-info ((format "%s" "fork-missing-preset-lists-available"))
        (should (equal messages
                       (list (concat
                              "Failed to fork session: "
                              "Unknown agent preset: focused-investigation "
                              "(agent-preset/not-found); available presets: "
                              "standard, ptc, tiny"))))))))

;; A draft whose preset disappeared on the server retries once under the host
;; default (same recovery as the dsh web's startup restoration) instead of
;; failing with the server's raw error value.
(ert-deftest dsh-emacs-test-lifecycle-create-falls-back-when-preset-missing ()
  :tags '(dsh-unit)
  (let* ((dsh-emacs--chat-buffers (make-hash-table :test #'equal))
         (dsh-emacs--current-session nil)
         (dsh-emacs--current-buffer nil)
         (dsh-emacs--sessions nil)
         (dsh-emacs--workspaces nil)
         (dsh-emacs-new-session-auto-project nil)
         (presets nil)
         (messages nil))
    (unwind-protect
        (cl-letf
            (((symbol-function 'dsh-emacs--rpc-async)
              (lambda (method params cb)
                (when (string= method "session/create")
                  (let* ((request (cdr (assq 'request params)))
                         (preset (cdr (assq 'agentPreset request))))
                    (push preset presets)
                    (if preset
                        (funcall cb nil
                                 '((code . "agent-preset/not-found")
                                   (message . "Unknown agent preset: gone")
                                   (details
                                    . ((agentPreset . "gone")
                                       (available . ["standard" "ptc"])))))
                      (funcall cb t
                               `((sessionId
                                  . ,(cdr (assq 'sessionId request)))
                                 (agentPreset . "standard"))))))))
             ((symbol-function 'pop-to-buffer)
              (lambda (buffer &rest _) buffer))
             ((symbol-function 'dsh-emacs--activate-chat-buffer)
              (lambda (sid buffer &optional _address)
                (puthash sid buffer dsh-emacs--chat-buffers)
                (with-current-buffer buffer
                  (setq-local dsh-emacs--buffer-session sid)
                  (dsh-emacs--chat-buffer-sync sid)
                  (dsh-emacs-mode))))
             ((symbol-function 'message)
              (lambda (format-string &rest args)
                (push (apply #'format format-string args) messages))))
          (dsh-emacs-new-session nil nil "gone")
          (ert-info ((format "%s" "create-falls-back-when-preset-missing"))
            (should (equal (reverse presets) (list "gone" nil)))
            (should (cl-some (lambda (text)
                               (string-match-p "Preset gone unavailable" text))
                             messages))))
      (maphash (lambda (_id chat)
                 (when (buffer-live-p chat) (kill-buffer chat)))
               dsh-emacs--chat-buffers))))

;; An unrelated create failure keeps the draft and reports the error; only a
;; missing/unusable preset earns the one-shot fallback.
(ert-deftest dsh-emacs-test-lifecycle-create-does-not-retry-unrelated-failure ()
  :tags '(dsh-unit)
  (let* ((dsh-emacs--chat-buffers (make-hash-table :test #'equal))
         (dsh-emacs--sessions nil)
         (dsh-emacs--workspaces nil)
         (dsh-emacs-new-session-auto-project nil)
         (requests nil)
         (messages nil)
         (buf nil))
    (unwind-protect
        (cl-letf
            (((symbol-function 'dsh-emacs--rpc-async)
              (lambda (method params cb)
                (when (string= method "session/create")
                  (push (cdr (assq 'agentPreset
                                   (cdr (assq 'request params))))
                        requests)
                  (funcall cb nil
                           '((code . "gateway/internal")
                             (message . "boom"))))))
             ((symbol-function 'pop-to-buffer)
              (lambda (buffer &rest _) buffer))
             ((symbol-function 'message)
              (lambda (format-string &rest args)
                (push (apply #'format format-string args) messages))))
          (setq buf (dsh-emacs-new-session nil nil "gone"))
          (ert-info ((format "%s" "create-does-not-retry-unrelated-failure"))
            (should (equal requests '("gone")))
            (should (cl-some (lambda (text)
                               (string-match-p "gateway/internal" text))
                             messages))
            (with-current-buffer buf
              (should (derived-mode-p 'dsh-emacs-draft-mode))
              (should dsh-emacs--creation-context))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

;; A fallback retry that fails too must stop after one attempt, keep the draft
;; editable, and report the second (readable) error.
(ert-deftest dsh-emacs-test-lifecycle-create-fallback-retry-failure-keeps-draft ()
  :tags '(dsh-unit)
  (let* ((dsh-emacs--chat-buffers (make-hash-table :test #'equal))
         (dsh-emacs--sessions nil)
         (dsh-emacs--workspaces nil)
         (dsh-emacs-new-session-auto-project nil)
         (requests nil)
         (messages nil)
         (first t)
         (buf nil))
    (unwind-protect
        (cl-letf
            (((symbol-function 'dsh-emacs--rpc-async)
              (lambda (method params cb)
                (when (string= method "session/create")
                  (push (cdr (assq 'agentPreset
                                   (cdr (assq 'request params))))
                        requests)
                  (if first
                      (progn
                        (setq first nil)
                        ;; The first reply arrives while the draft is current.
                        (insert "draft text")
                        (funcall cb nil
                                 '((code . "agent-preset/not-found")
                                   (message . "Unknown agent preset: gone")
                                   (details
                                    . ((agentPreset . "gone")
                                       (available . ["standard"]))))))
                    (funcall cb nil
                             '((code . "gateway/internal")
                               (message . "second failure")))))))
             ((symbol-function 'pop-to-buffer)
              (lambda (buffer &rest _) buffer))
             ((symbol-function 'message)
              (lambda (format-string &rest args)
                (push (apply #'format format-string args) messages))))
          (setq buf (dsh-emacs-new-session nil nil "gone"))
          (ert-info ((format "%s" "create-fallback-retry-failure-keeps-draft"))
            (should (equal (reverse requests) (list "gone" nil)))
            (should (cl-some (lambda (text)
                               (string-match-p
                                "Failed to create session: second failure (gateway/internal)"
                                text))
                             messages))
            (with-current-buffer buf
              (should (derived-mode-p 'dsh-emacs-draft-mode))
              (should (null dsh-emacs--creation-pending))
              (should (equal "draft text"
                             (buffer-substring-no-properties
                              (point-min) (point-max))))
              (should (null (nth 2 dsh-emacs--creation-context))))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

;; A fork failure without an available-preset list keeps the generic readable
;; text; only `agent-preset/not-found' names ids to append.
(ert-deftest dsh-emacs-test-lifecycle-fork-failure-without-available-presets ()
  :tags '(dsh-unit)
  (should (equal "boom (gateway/internal)"
                 (dsh-emacs--fork-failure-text
                  '((code . "gateway/internal") (message . "boom")))))
  (should (equal "Unknown agent preset: gone (agent-preset/invalid)"
                 (dsh-emacs--fork-failure-text
                  '((code . "agent-preset/invalid")
                    (message . "Unknown agent preset: gone")
                    (details . ((agentPreset . "gone")
                                (reason . "bad declaration"))))))))

(provide 'dsh-test-lifecycle)
;;; dsh-test-lifecycle.el ends here
