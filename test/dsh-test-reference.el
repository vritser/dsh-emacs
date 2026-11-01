;;; dsh-test-reference.el --- Reference tests -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "28.1"))

(require 'dsh-test-support)
(defvar corfu-auto)

;; ---------------------------------------------------------------------------
;; @ reference (dsh-emacs-reference.el)
;; ---------------------------------------------------------------------------
(defun dsh-test-reference-reset ()
  "Reset the buffer-local @ reference cache state (current buffer)."
  (when (timerp dsh-emacs--reference-fetch-timer)
    (cancel-timer dsh-emacs--reference-fetch-timer))
  (setq-local dsh-emacs--reference-candidates nil
              dsh-emacs--reference-query nil
              dsh-emacs--reference-requested nil
              dsh-emacs--reference-inflight nil
              dsh-emacs--reference-fetch-gen 0
              dsh-emacs--reference-files nil
              dsh-emacs--reference-sessions nil
              dsh-emacs--reference-fetch-timer nil
              dsh-emacs--reference-pop-token nil))

;; A short @ token must not copy the entire preceding draft on each keypress.
(ert-deftest dsh-emacs-test-reference-active-token-copies-only-the-token ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (insert (make-string 100000 ?x) " @src/file")
    (let ((copied 0)
          (substring (symbol-function 'buffer-substring-no-properties)))
      (cl-letf (((symbol-function 'buffer-substring-no-properties)
                 (lambda (start end)
                   (setq copied (+ copied (- end start)))
                   (funcall substring start end))))
        (ert-info ((format "%s" "active-token-copies-only-the-token"))
          (should (equal (dsh-emacs-reference--active-token)
                         '("@src/file" "src/file" nil)))
          (should (<= copied 20)))))))

;; --- syntax: at-token aligned with web grammar.ts activeAtToken ---
(ert-deftest dsh-emacs-test-reference-at-token ()
  :tags '(dsh-unit)
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
            (ert-info ((format "%s" (concat "at-token-" name)))
              (should (equal (dsh-emacs-reference--at-token start end) expected))
              (should (= (point) start)))))))))

;; --- syntax: formatFileMention aligned with web formatFileMention ---
(ert-deftest dsh-emacs-test-reference-format-file-mention-cases ()
  :tags '(dsh-unit)
  (let ((cases
         '(("README.md" "file" nil "@README.md")
           ("src" "directory" nil "@src/")
           ("my dir/a b" "file" nil "@\"my dir/a b\"")
           ("src" "directory" t "@\"src/")
           ("a b" "file" t "@\"a b\""))))
    (ert-info ((format "%s" "format-file-mention-cases"))
      (should (cl-every
               (lambda (c)
                 (string= (apply #'dsh-emacs-reference--format-file-mention
                                 (butlast c))
                          (car (last c))))
               cases)))))

(ert-deftest dsh-emacs-test-reference-format-file-mention-rejects-control ()
  :tags '(dsh-unit)
  (ert-info ((format "%s" "format-file-mention-rejects-control"))
    (should (null (dsh-emacs-reference--format-file-mention "a\x01b" "file")))))

(ert-deftest dsh-emacs-test-reference-format-file-mention-rejects-quote ()
  :tags '(dsh-unit)
  (ert-info ((format "%s" "format-file-mention-rejects-quote"))
    (should (null (dsh-emacs-reference--format-file-mention "a\"b" "file")))))

;; --- collect-files: wire array → cache entries, unrepresentable paths skipped;
;; the host sorts directories before files (kindRank directory=0), the client
;; stably groups files first, directories after
(ert-deftest dsh-emacs-test-reference-collect-files-texts-and-kinds ()
  :tags '(dsh-unit)
  (let ((entries
         (dsh-emacs-reference--collect-files
          [((path . "src") (kind . "directory"))
           ((path . "README.md") (kind . "file"))
           ((path . "docs") (kind . "directory"))
           ((path . "bad\x01name") (kind . "file"))])))
    (ert-info ((format "%s" "collect-files-texts-and-kinds"))
      (should (equal (mapcar #'car entries)
                     '("@README.md" "@src/" "@docs/")))
      (should (equal (plist-get (cdr (assoc "@src/" entries)) :kind) 'directory))
      (should (equal (plist-get (cdr (assoc "@README.md" entries)) :path)
                     "README.md"))
      (should (equal (mapcar (lambda (e) (plist-get (cdr e) :path))
                             (cl-remove-if-not
                              (lambda (e) (eq (plist-get (cdr e) :kind) 'directory))
                              entries))
                     '("src" "docs"))))))

;; --- collect-sessions: mention is the main text, candidates without a mention
;; are skipped ---
(ert-deftest dsh-emacs-test-reference-collect-sessions-mention-and-drop ()
  :tags '(dsh-unit)
  (let ((entries
         (dsh-emacs-reference--collect-sessions
          [((sessionId . "s1")
            (label . "My Talk")
            (cwd . "/work/a")
            (sameWorkspace . t)
            (createdAt . 123)
            (mention . "@[My Talk](dsh-session:cyJpZCI6InMxIn0)"))
           ((sessionId . "s2") (label . "x"))])))
    (ert-info ((format "%s" "collect-sessions-mention-and-drop"))
      (should (equal (mapcar #'car entries)
                     '("@[My Talk](dsh-session:cyJpZCI6InMxIn0)")))
      (should (equal (plist-get (cdr (car entries)) :label) "My Talk"))
      (should (equal (plist-get (cdr (car entries)) :session-id) "s1"))
      (should (equal (plist-get (cdr (car entries)) :same-workspace) t)))))

;; --- combine: by default keep all files and sessions returned by the host ---
(ert-deftest dsh-emacs-test-reference-combine-default-keeps-all-candidates ()
  :tags '(dsh-unit)
  (let* ((dsh-emacs-reference-max-files nil)
         (dsh-emacs-reference-max-sessions nil)
         (files (list (cons "@a" '(:kind file))
                      (cons "@b" '(:kind directory))
                      (cons "@c" '(:kind file))))
         (sessions (list (cons "@s1" '(:kind session))
                         (cons "@s2" '(:kind session)))))
    (ert-info ((format "%s" "combine-default-keeps-all-candidates"))
      (should (= 5 (length (dsh-emacs-reference--combine files sessions)))))))

;; --- combine: files first, sessions after, each truncated to its cap ---
(ert-deftest dsh-emacs-test-reference-combine-order-and-caps ()
  :tags '(dsh-unit)
  (let* ((dsh-emacs-reference-max-files 2)
         (dsh-emacs-reference-max-sessions 1)
         (files (list (cons "@a" '(:kind file :path "a"))
                      (cons "@b" '(:kind file :path "b"))
                      (cons "@c" '(:kind file :path "c"))))
         (sessions (list (cons "@[s1](dsh-session:x)" '(:kind session))
                         (cons "@[s2](dsh-session:y)" '(:kind session))))
         (combined (dsh-emacs-reference--combine files sessions)))
    (ert-info ((format "%s" "combine-order-and-caps"))
      (should (equal (mapcar #'car combined)
                     '("@a" "@b" "@[s1](dsh-session:x)"))))))

;; --- M-x menu: use the ordered completion helper so the framework does not
;; reorder by text ---
(ert-deftest dsh-emacs-test-reference-reference-menu-preserves-file-dir-session-order ()
  :tags '(dsh-unit)
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
      (ert-info ((format "%s" "reference-menu-preserves-file-dir-session-order"))
        (should (equal (dsh-test-completion-items collection)
                       '("file.txt" "dir/" "Session")))))))

(ert-deftest dsh-emacs-test-reference-refresh-updates-only-current-corfu ()
  :tags '(dsh-unit)
  (save-window-excursion
    (with-temp-buffer
      (switch-to-buffer (current-buffer))
      (insert "@")
      (setq-local dsh-emacs--input-marker (point-min-marker)
                  dsh-emacs--reference-requested ""
                  dsh-emacs--reference-query "")
      (let ((corfu-auto t)
            (completion-in-region-mode t)
            (completion-in-region--data
             (list (point-min) (point-max)
                   (lambda (_string _pred action)
                     (when (eq action 'metadata)
                       '(metadata (category . dsh-emacs-reference))))))
            (last-command 'self-insert-command)
            (refreshed 0) (opened 0))
        (cl-letf (((symbol-function 'run-with-idle-timer)
                   (lambda (_delay _repeat fn &rest args) (apply fn args)))
                  ((symbol-function 'corfu--exhibit)
                   (lambda (&rest _) (cl-incf refreshed)))
                  ((symbol-function 'corfu-auto--complete-deferred)
                   (lambda (&rest _) (cl-incf opened))))
          (dsh-emacs-reference--schedule-popup-refresh)
          (should (= refreshed 1))
          (should (= opened 0))
          (setq completion-in-region-mode nil)
          (dsh-emacs-reference--schedule-popup-refresh)
          (should (= opened 1))
          (let ((last-command 'keyboard-quit))
            (dsh-emacs-reference--schedule-popup-refresh))
          (let ((corfu-auto nil))
            (dsh-emacs-reference--schedule-popup-refresh))
          (insert "new")
          (dsh-emacs-reference--schedule-popup-refresh)
          (should (= opened 1))
          (should (= refreshed 1)))))))

;; The watcher delegates to shared query scheduling, without opening a popup.
(ert-deftest dsh-emacs-test-reference-reference-corfu-refreshes-query-without-restarting ()
  :tags '(dsh-unit)
  (let ((buf (generate-new-buffer " *t-ref-corfu-native-table*"))
        (corfu-auto t)
        (dsh-emacs-reference-fetch-delay 0.15)
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
            (dsh-emacs-reference--auto-complete)
            (dsh-emacs-reference-prefetch "sess")
            (ert-info ((format "%s" "reference-corfu-refreshes-query-without-restarting"))
              (should (equal fetched '("sess" "")))
              (should (null opened))
              (should (null prefetched)))
            ;; A trailing slash skips the ordinary query debounce.
            (goto-char (point-max))
            (insert "src/")
            (dsh-emacs-reference--auto-complete)
            (ert-info ((format "%s" "reference-corfu-slash-fetches-directory"))
              (should (equal fetched '("sess" "src/")))
              (should (= delay-seen 0)))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

;; Pre-fetch is shared by every frontend, Corfu included; a query the user has
;; already requested still wins.
(ert-deftest dsh-emacs-test-reference-prefetch-warms-every-frontend ()
  :tags '(dsh-unit)
  (let ((buf (generate-new-buffer " *t-ref-prefetch*"))
        (corfu-auto t)
        (dsh-emacs-reference-prefetch-delay 0.25))
    (unwind-protect
        (with-current-buffer buf
          (let (timers fetched)
            (cl-letf (((symbol-function 'dsh-emacs--active-session-id)
                       (lambda () "sess"))
                      ((symbol-function 'run-with-idle-timer)
                       (lambda (delay _repeat function &rest _args)
                         (push (cons delay function) timers)
                         (timer-create)))
                      ((symbol-function 'dsh-emacs-reference--fetch-query)
                       (lambda (session-id query)
                         (setq fetched (list session-id query)))))
              (dsh-emacs-reference-prefetch "sess")
              (ert-info ((format "%s" "prefetch-warms-corfu-buffers"))
                (should (equal (mapcar #'car timers) '(0.25))))
              (funcall (cdar timers))
              (ert-info ((format "%s" "prefetch-fetches-the-bare-query"))
                (should (equal fetched '("sess" "")))
                (should (equal dsh-emacs--reference-requested "")))
              ;; A query the user already started takes precedence.
              (setq timers nil fetched nil)
              (setq dsh-emacs--reference-requested "src")
              (dsh-emacs-reference-prefetch "sess")
              (ert-info ((format "%s" "prefetch-yields-to-a-started-query"))
                (should-not timers)
                (should-not fetched)))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest dsh-emacs-test-reference-fetch-waits-for-both-slices ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-test-reference-reset)
    (let (callbacks)
      (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                 (lambda (method _params callback)
                   (push (cons method callback) callbacks)))
                ((symbol-function 'dsh-emacs-reference--schedule-popup-refresh)
                 #'ignore))
        (setq dsh-emacs--reference-requested "read")
        (dsh-emacs-reference--fetch-query "sess" "read")
        (funcall (cdr (assoc "fileReferences/list" callbacks))
                 t [((path . "README.md") (kind . "file"))])
        (should dsh-emacs--reference-inflight)
        (should-not dsh-emacs--reference-query)
        (funcall (cdr (assoc "sessionReferenceResolver/candidates" callbacks))
                 t [])
        (should-not dsh-emacs--reference-inflight)
        (should (equal dsh-emacs--reference-query "read"))
        (should (equal (mapcar #'car dsh-emacs--reference-candidates)
                       '("@README.md")))))))

(ert-deftest dsh-emacs-test-reference-native-matching-and-live-results ()
  :tags '(dsh-unit)
  (dolist (case '(("@re" "" (("@README.md" :kind file :path "README.md")))
                  ("@workspace" "workspace"
                   (("@[Design](dsh-session:cw)" :kind session
                     :label "Design" :session-id "s1" :cwd "/workspace")))
                  ("@\"src/a" "src/a"
                   (("@src/a.ts" :kind file :path "src/a.ts")))))
    (with-temp-buffer
      (pcase-let ((`(,input ,query ,entries) case))
        (insert input)
        (setq-local dsh-emacs--input-marker (point-min-marker)
                    dsh-emacs--reference-query query
                    dsh-emacs--reference-candidates entries)
        (let ((completion-styles '(basic))
              (completion-category-overrides nil))
          (cl-letf (((symbol-function 'dsh-emacs--active-session-id)
                     (lambda () "sess"))
                    ((symbol-function 'dsh-emacs-reference--require-cache)
                     (lambda (_session _query) t)))
            (let* ((capf (dsh-emacs-reference-completion-at-point))
                   (table (nth 2 capf))
                   (matches (completion-all-completions
                             input table nil (length input))))
              (should (stringp (car matches)))
              (should (equal (cdr (last matches)) 0))
              (should (equal (substring-no-properties (car matches))
                             (cond ((equal input "@re") "@README.md")
                                   ((equal input "@workspace") "@Design")
                                   (t "@\"src/a.ts\""))))
              (setq dsh-emacs--reference-query "button"
                    dsh-emacs--reference-candidates
                    '(("@src/button.ts" :kind file :path "src/button.ts")))
              (setq matches (completion-all-completions "@button" table nil 7))
              (should (equal (substring-no-properties (car matches))
                             (if (string-prefix-p "@\"" input)
                                 "@\"src/button.ts\"" "@src/button.ts"))))))))))

;; --- fetch-query: two remotes concurrently, install the cache after both
;; slices land ---
(ert-deftest dsh-emacs-test-reference-fetch-query-both-remotes-called ()
  :tags '(dsh-unit)
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
      (ert-info ((format "%s" "fetch-query-both-remotes-called"))
        (should (= 2 (length rpc-calls)))
        (should (cl-every (lambda (m) (member m '("fileReferences/list"
                                                  "sessionReferenceResolver/candidates")))
                          (mapcar #'car rpc-calls))))
      (ert-info ((format "%s" "fetch-query-wire-args-flat"))
        (dolist (method '("fileReferences/list"
                          "sessionReferenceResolver/candidates"))
          (should (equal (cadr (assoc method rpc-calls))
                         '((agentId . "sess") (query . "re"))))))
      (ert-info ((format "%s" "fetch-query-installs-cache"))
        (should (equal dsh-emacs--reference-query "re"))
        (should (null dsh-emacs--reference-inflight))
        (should (equal (mapcar #'car dsh-emacs--reference-candidates)
                       '("@README.md" "@[T](dsh-session:cyJpZCI6InMxIn0)")))))))

(ert-deftest dsh-emacs-test-reference-require-cache-is-nonblocking ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-test-reference-reset)
    (let (calls callbacks)
      (cl-letf (((symbol-function 'dsh-emacs--rpc-request)
                 (lambda (&rest _) (ert-fail "Synchronous reference request")))
                ((symbol-function 'run-with-idle-timer)
                 (lambda (_delay _repeat function &rest args)
                   (apply function args)))
                ((symbol-function 'dsh-emacs-reference--schedule-popup-refresh)
                 #'ignore)
                ((symbol-function 'dsh-emacs--rpc-async)
                 (lambda (method params cb)
                   (push (list method params) calls)
                   (push (cons method cb) callbacks))))
        (should-not (dsh-emacs-reference--require-cache "sess" ""))
        (should (= (length calls) 2))
        (should dsh-emacs--reference-inflight)
        (funcall (cdr (assoc "fileReferences/list" callbacks))
                 t [((path . "F") (kind . "file"))])
        (funcall (cdr (assoc "sessionReferenceResolver/candidates" callbacks)) t [])
        (should (equal dsh-emacs--reference-query ""))
        (should (dsh-emacs-reference--require-cache "sess" "F2"))
        (should (= (length calls) 4))
        (should (equal dsh-emacs--reference-requested "F2"))
        (should (equal (mapcar #'car dsh-emacs--reference-candidates) '("@F")))))))

;; --- after finishing a reference (fetch state already reset), typing @ again: no
;; longer eats the narrowed cache, re-fetches the full set. Otherwise the next @
;; would only see the single candidate left by the previous query.
(ert-deftest dsh-emacs-test-reference-post-completion-reopen-refetches-full-list ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-test-reference-reset)
    (setq dsh-emacs--reference-candidates
          '(("@just-picked.ts" :kind file :path "just-picked.ts")))
    (let (calls)
      (cl-letf (((symbol-function 'run-with-idle-timer)
                 (lambda (_delay _repeat fn &rest args) (apply fn args)))
                ((symbol-function 'dsh-emacs-reference--schedule-popup-refresh)
                 #'ignore)
                ((symbol-function 'dsh-emacs--rpc-async)
                 (lambda (method _params callback)
                   (push method calls)
                   (funcall callback t
                            (if (equal method "fileReferences/list")
                                [((path . "a.ts") (kind . "file"))
                                 ((path . "b.ts") (kind . "file"))]
                              [])))))
        (should (dsh-emacs-reference--require-cache "sess" ""))
        (should (= (length calls) 2))
        (should (equal (mapcar #'car dsh-emacs--reference-candidates)
                       '("@a.ts" "@b.ts")))))))

;; --- require-cache: a stale cache keeps answering while in-flight (the popup does
;; not disappear) ---
(ert-deftest dsh-emacs-test-reference-require-cache-stale-answers-while-inflight ()
  :tags '(dsh-unit)
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
        (ert-info ((format "%s" "require-cache-stale-answers-while-inflight"))
          (should (let ((dsh-emacs--reference-inflight t))
                    (and (dsh-emacs-reference--require-cache "sess" "re2")
                         ;; Stale cache retained, no new fetch started
                         (null rpc-requests)))))
        (ert-info ((format "%s" "require-cache-no-cache-while-inflight-nil"))
          (should (let ((dsh-emacs--reference-inflight t)
                        (dsh-emacs--reference-query nil)
                        (dsh-emacs--reference-candidates nil))
                    (null (dsh-emacs-reference--require-cache "sess" "re2")))))))))

;; --- session-rows: session row short label + duplicate-name disambiguation
;; (mention stays in the cache) ---
(ert-deftest dsh-emacs-test-reference-session-rows-short-and-unique ()
  :tags '(dsh-unit)
  (let ((dsh-emacs--reference-candidates
         (list (cons "@README.md" '(:kind file :path "README.md"))
               (cons "@[My Talk](dsh-session:cyJpZCI6InMxIn0)"
                     '(:kind session :label "My Talk" :session-id "s1"))
               (cons "@[My Talk](dsh-session:cyJpZCI6InMyIn0)"
                     '(:kind session :label "My Talk" :session-id "s2")))))
    (ert-info ((format "%s" "session-rows-short-and-unique"))
      (should (equal (dsh-emacs-reference--session-rows)
                     '(("@My Talk" . "@[My Talk](dsh-session:cyJpZCI6InMxIn0)")
                       ("@My Talk #2" . "@[My Talk](dsh-session:cyJpZCI6InMyIn0)")))))))

;; --- session-rows: a literal suffix in a label cannot collide with a generated
;; suffix row; every final row still resolves to its own session in the cache ---
(ert-deftest dsh-emacs-test-reference-session-rows-suffixed-label-collision ()
  :tags '(dsh-unit)
  (let* ((entries
          (mapcar (lambda (spec)
                    (pcase-let ((`(,sid ,label) spec))
                      (cons (concat "@[" label "]("
                                    (dsh-test-reference--session-uri sid) ")")
                            (list :kind 'session :label label
                                  :session-id sid))))
                  '(("s1" "same")
                    ("s2" "same")
                    ("s3" "same #2"))))
         (dsh-emacs--reference-candidates entries)
         (rows (dsh-emacs-reference--session-rows)))
    (ert-info ((format "%s" "session-rows-suffixed-label-collision"))
      (should (equal (mapcar #'car rows)
                     '("@same" "@same #2" "@same #2 #2")))
      (should (= (length rows)
                 (length (delete-dups (mapcar #'car rows)))))
      (should (equal (mapcar #'cdr rows) (mapcar #'car entries)))
      (should (equal (mapcar (lambda (row)
                               (plist-get (cdr (dsh-emacs-reference--entry-for
                                                row))
                                          :session-id))
                             (mapcar #'car rows))
                     '("s1" "s2" "s3")))
      (should (eq (dsh-emacs-reference--entry-for "@same #2 #2")
                  (nth 2 entries)))
      (should-not (eq (dsh-emacs-reference--entry-for "@same #2 #2")
                      (nth 1 entries))))))

;; --- affixate: file/directory rows get a leading type-icon column (consult-buffer
;; style) ---
(ert-deftest dsh-emacs-test-reference-affixate-icon-column-shape ()
  :tags '(dsh-unit)
  (let* ((entries (list (cons "@a.ts" '(:kind file :path "src/a.ts"))
                        (cons "@sub/" '(:kind directory :path "sub"))
                        (cons "@[T](dsh-session:x)"
                              '(:kind session :label "T" :cwd "/w"
                                      :same-workspace t))))
         (map (dsh-emacs-reference--snapshot-affix
               entries (dsh-emacs-reference--session-rows entries))))
    (cl-letf (((symbol-function 'dsh-emacs-reference--row-icon)
               (lambda (path kind)
                 (pcase kind
                   ('file "F")
                   ('directory "D")
                   ('session "R")
                   (_ nil)))))
      (ert-info ((format "%s" "affixate-icon-column-shape"))
        (should (equal (dsh-emacs-reference--affixate-with
                        map '("@a.ts" "@sub/" "@[T](dsh-session:x)"))
                       '(("@a.ts" "F " "")
                         ("@sub/" "D " "")
                         ("@[T](dsh-session:x)" "R " ""))))))
    (ert-info ((format "%s" "affixate-without-provider-text-only"))
      (should (cl-letf (((symbol-function 'dsh-emacs-reference--row-icon)
                         (lambda (_path _kind) nil)))
                (equal (dsh-emacs-reference--affixate-with
                        map '("@a.ts" "@sub/"))
                       '(("@a.ts" "" "")
                         ("@sub/" "" ""))))))
    (ert-info ((format "%s" "affixate-inline-icons-off"))
      (should (let ((dsh-emacs-reference-inline-icons nil))
                (equal (dsh-emacs-reference--affixate-with map '("@a.ts"))
                       '(("@a.ts" "" ""))))))
    ;; --row-icon: a non-graphical frame outputs no nerd-font PUA glyphs (terminal
    ;; tofu blocks); a graphical frame with the provider available returns the
    ;; file/directory/session icon by kind
    (ert-info ((format "%s" "row-icon-gated-off-on-non-graphic"))
      (should (cl-letf (((symbol-function 'display-graphic-p) (lambda () nil)))
                (and (null (dsh-emacs-reference--row-icon "src/a.ts" 'file))
                     (null (dsh-emacs-reference--row-icon nil 'session))))))
    (ert-info ((format "%s" "row-icon-graphic-uses-provider"))
      (cl-progv '(features) (list (cons 'nerd-icons features))
        (cl-letf (((symbol-function 'display-graphic-p) (lambda () t))
                  ((symbol-function 'nerd-icons-icon-for-file) (lambda (_f) "F"))
                  ((symbol-function 'nerd-icons-icon-for-dir) (lambda (_d) "D"))
                  ((symbol-function 'nerd-icons-codicon) (lambda (_n) "R")))
          (should (equal (dsh-emacs-reference--row-icon "src/a.ts" 'file) "F"))
          (should (equal (dsh-emacs-reference--row-icon "src" 'directory) "D"))
          (should (equal (dsh-emacs-reference--row-icon nil 'session) "R")))))))

;; --- icon data is snapshotted when the completion table is built: a background
;; fetch then replaces `dsh-emacs--reference-candidates' with the results of a
;; new query, and the still-open corfu popup (holding the old snapshot table)
;; re-affixes with the snapshot map instead of the mutable cache → icons are not
;; pulled away (regression: after a new fetch some rows had no icon when
;; filtering)
(ert-deftest dsh-emacs-test-reference-affix-snapshot-survives-cache-swap ()
  :tags '(dsh-unit)
  (let* ((entries (list (cons "@a.ts" '(:kind file :path "src/a.ts"))
                        (cons "@sub/" '(:kind directory :path "sub"))))
         (dsh-emacs--reference-candidates entries)
         (rows (dsh-emacs-reference--session-rows entries))
         (map (dsh-emacs-reference--snapshot-affix entries rows)))
    ;; A narrower fetch lands, replacing the global cache
    (setq dsh-emacs--reference-candidates
          (list (cons "@fresh.md" '(:kind file :path "fresh.md"))))
    (ert-info ((format "%s" "affix-snapshot-survives-cache-swap"))
      (should (cl-letf (((symbol-function 'dsh-emacs-reference--row-icon)
                         (lambda (_path kind) (symbol-name kind))))
                (equal (dsh-emacs-reference--affixate-with map '("@a.ts" "@sub/"))
                       '(("@a.ts" "file " "")
                         ("@sub/" "directory " ""))))))))

;; --- rendering: a completed @ reference → colored clickable link (session
;; collapsed to @label) ---
(ert-deftest dsh-emacs-test-reference-link-spans-file-and-session ()
  :tags '(dsh-unit)
  (let* ((sid "session-ab1-2")
         (spans (dsh-emacs-reference--link-spans
                 (concat "see @src/a.ts and @[My Talk]("
                         (dsh-test-reference--session-uri sid) ") done"))))
    (ert-info ((format "%s" "link-spans-file-and-session"))
      (should (equal (mapcar (lambda (s) (list (nth 2 s) (nth 3 s)))
                             spans)
                     `((file "src/a.ts") (session ,sid)))))
    ;; The URI payload is base64url: it stays a session span (so the file matcher
    ;; cannot eat its `@[label' prefix) even when no id decodes.
    (ert-info ((format "%s" "link-spans-base64url-charset-claimed"))
      (should (equal (mapcar (lambda (s) (list (nth 2 s) (nth 3 s)))
                             (dsh-emacs-reference--link-spans
                              "@[T](dsh-session:ab1_-2)"))
                     '((session nil)))))
    (ert-info ((format "%s" "link-spans-not-email"))
      (should (null (dsh-emacs-reference--link-spans "contact mail@example.com now"))))
    ;; A bare @word (including extensionless files such as @LICENSE) is always a file
    ;; reference link; only emails and a lone @ are excluded
    (ert-info ((format "%s" "link-spans-bare-atword-is-file"))
      (should (equal (mapcar (lambda (s) (nth 3 s))
                             (dsh-emacs-reference--link-spans
                              "note @LICENSE and @src/a.ts and @README.md"))
                     '("LICENSE" "src/a.ts" "README.md"))))
    (ert-info ((format "%s" "link-spans-lone-at-not-file"))
      (should (null (dsh-emacs-reference--link-spans "an @ alone and @ here"))))))

;; Regression: opening a rendered session mention sent the URI payload itself as
;; the session id, so the host answered `session/not-found' — the id must be the
;; JSON string the payload encodes.
(ert-deftest dsh-emacs-test-reference-decode-session-uri-restores-session-id ()
  :tags '(dsh-unit)
  (ert-info ((format "%s" "decode-session-uri-restores-session-id"))
    (should (equal (dsh-protocol-session-uri--from-string
                    "InNlc3Npb24tZTMyYTE1MGUtMTk1Ny00MDU3LTg2ZjMtNmM0YTNmOTM1YTYxIg")
                   "session-e32a150e-1957-4057-86f3-6c4a3f935a61"))
    (should (null (dsh-protocol-session-uri--from-string "cyJpZCI6InMxIn0")))))

;; JSON numbers and Unicode escapes alter match data, including before a parse
;; error.  Decoding must not rewind the scanner to the same mention forever.
(ert-deftest dsh-emacs-test-reference-fontify-session-scan-progress ()
  :tags '(dsh-unit)
  (dolist (case `(("number" "MTIz" nil)
                  ("unicode-escape" "InNlc3Npb24tXHUwMDAxIg"
                   ,(concat "session-" (string 1)))
                  ("parse-error" "WzEs" nil)))
    (pcase-let* ((`(,name ,payload ,id) case)
                 (prefix "a sufficiently long prefix ")
                 (decode (symbol-function
                          'dsh-protocol-session-uri--from-string))
                 (calls 0)
                 (out
                  (catch 'repeated-mention
                    (cl-letf (((symbol-function
                                'dsh-protocol-session-uri--from-string)
                               (lambda (value)
                                 ;; Bound the repro so a regression fails instead
                                 ;; of hanging the entire test suite.
                                 (when (> (cl-incf calls) 2)
                                   (throw 'repeated-mention nil))
                                 (funcall decode value))))
                      (dsh-emacs-reference-fontify
                       (concat prefix "@[T](dsh-session:" payload ")"
                               " then @[Next](dsh-session:InMyIg) @tail.md"))))))
      (ert-info ((format "%s" (concat "fontify-session-scan-progress-" name)))
        (should (= calls 2))
        (should (and (stringp out)
                     (string= (substring-no-properties out)
                              (concat prefix "@T then @Next @tail.md"))
                     (equal (get-text-property (length prefix)
                                               'dsh-emacs-reference-ref out)
                            (cons 'session id))
                     (equal (get-text-property (string-match "@Next" out)
                                               'dsh-emacs-reference-ref out)
                            '(session . "s2"))
                     (equal (get-text-property (string-match "@tail.md" out)
                                               'dsh-emacs-reference-ref out)
                            '(file . "tail.md"))))))))

(ert-deftest dsh-emacs-test-reference-fontify-session-collapses-to-label ()
  :tags '(dsh-unit)
  (let* ((sid "session-ab1-2")
         (out (dsh-emacs-reference-fontify
               (concat "see @src/ui/button.tsx then @[My Talk]("
                       (dsh-test-reference--session-uri sid)
                       "), mail@example ok"))))
    (ert-info ((format "%s" "fontify-session-collapses-to-label"))
      (should (string= (substring-no-properties out)
                       "see @src/ui/button.tsx then @My Talk, mail@example ok")))
    (ert-info ((format "%s" "fontify-spans-carry-session-id"))
      (should (equal (get-text-property (string-match "@My Talk" out)
                                        'dsh-emacs-reference-ref out)
                     `(session . ,sid))))))

(ert-deftest dsh-emacs-test-reference-fontify-quoted-file-path-linked ()
  :tags '(dsh-unit)
  (let ((out (dsh-emacs-reference-fontify "note @\"my dir/a.ts\" here")))
    (ert-info ((format "%s" "fontify-quoted-file-path-linked"))
      (should (let ((i (string-match "@\"my dir/a.ts\"" out)))
                (equal (get-text-property i 'dsh-emacs-reference-ref out)
                       '(file . "my dir/a.ts")))))))

;; The `@[label' prefix of a session mention is not treated as a file link
(ert-deftest dsh-emacs-test-reference-fontify-two-sessions-and-no-file-prefix ()
  :tags '(dsh-unit)
  (let ((out (dsh-emacs-reference-fontify
              "@[T](dsh-session:xyz) @[Q](dsh-session:uvw)")))
    (ert-info ((format "%s" "fontify-two-sessions-and-no-file-prefix"))
      (should (string= (substring-no-properties out) "@T @Q")))))

;; RET/mouse open: a session reference jumps via `dsh-emacs-open-session'
(ert-deftest dsh-emacs-test-reference-open-at-point-jumps-to-session ()
  :tags '(dsh-unit)
  (let* ((sid "session-target-1")
         (opened nil) (buf (generate-new-buffer " *t-ref-open*")))
    (unwind-protect
        (with-current-buffer buf
          (insert (dsh-emacs-reference-fontify
                   (concat "@[Sess](" (dsh-test-reference--session-uri sid) ")")))
          (goto-char (point-min))
          (cl-letf (((symbol-function 'dsh-emacs-open-session)
                     (lambda (id) (setq opened id))))
            (dsh-emacs-reference-open-at-point))
          (ert-info ((format "%s" "open-at-point-jumps-to-session"))
            (should (equal opened sid))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

;; --- reseed/reopen: when the server persists a reference message it collapses the
;; canonical mention into a readable @label (the id is stripped), and the real
;; sessionId+label appears only in the immediately following session-reference
;; recall event — rendering with REFERENCES ((LABEL . SESSION-ID)) is what
;; restores the readable @label into a session chip with the real id, while plain
;; @file still links as usual.
(ert-deftest dsh-emacs-test-reference-reseed-readable-label-links-as-session-with-real-id ()
  :tags '(dsh-unit)
  (let ((out (dsh-emacs-reference-fontify
              "see @dsh-emacs如何通过转发接入Codex与Claude 和 @src/a.ts"
              '(("dsh-emacs如何通过转发接入Codex与Claude" . "session-abc-123")))))
    (let ((label-pos (string-match "@dsh-emacs如何通过转发接入Codex与Claude" out))
          (file-pos (string-match "@src/a.ts" out)))
      (ert-info ((format "%s" "reseed-readable-label-links-as-session-with-real-id"))
        (should (and label-pos file-pos
                     (equal (get-text-property label-pos 'dsh-emacs-reference-ref out)
                            '(session . "session-abc-123"))
                     (equal (get-text-property file-pos 'dsh-emacs-reference-ref out)
                            '(file . "src/a.ts"))))))
    (ert-info ((format "%s" "reseed-readable-label-text-preserved"))
      (should (string= (substring-no-properties out)
                       "see @dsh-emacs如何通过转发接入Codex与Claude 和 @src/a.ts")))))

;; After the readable @label is restored to a chip it can still jump to the real
;; session
(ert-deftest dsh-emacs-test-reference-reseed-label-open-jumps-to-real-session ()
  :tags '(dsh-unit)
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
          (ert-info ((format "%s" "reseed-label-open-jumps-to-real-session"))
            (should (equal opened "session-abc-123"))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

;; A readable @word that matches no reference still goes through the file link
;; (not polluted)
(ert-deftest dsh-emacs-test-reference-reseed-nonmatching-label-stays-file ()
  :tags '(dsh-unit)
  (let ((out (dsh-emacs-reference-fontify
              "mention @unrelated now"
              '(("known-label" . "session-k")))))
    (ert-info ((format "%s" "reseed-nonmatching-label-stays-file"))
      (should (equal (get-text-property (string-match "@unrelated" out)
                                        'dsh-emacs-reference-ref out)
                     '(file . "unrelated"))))))

;; --- reseed/reopen: reference message + the immediately following
;; session-reference recall event ---
;; The server stores the reference message as a readable @label (id stripped),
;; and the real sessionId+label appears only in the immediately following
;; session-reference recall event. When history reseed renders these two
;; user/message entries in one batch, render-history-events should associate the
;; recall's references back to the preceding message's seq and render @label as a
;; jumpable session chip.
(ert-deftest dsh-emacs-test-reference-reseed-render-links-readable-label-to-session ()
  :tags '(dsh-unit)
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
              (ert-info ((format "%s" "reseed-render-links-readable-label-to-session"))
                (should (and pos (equal ref (cons 'session sid))))))))
      (kill-buffer buf))))

;; --- composer atomic chip: the buffer stores a short @label + canonical text
;; properties, and sending expands it back to the full mention
(ert-deftest dsh-emacs-test-reference-chip-keeps-short-label-and-canonical ()
  :tags '(dsh-unit)
  (let* ((sid "session-ab12-cd")
         (canon (concat "@[My Talk](" (dsh-test-reference--session-uri sid) ")")))
    (with-temp-buffer
      (setq-local dsh-emacs--input-marker (point-min-marker))
      (insert "@My Talk")
      (ert-info ((format "%s" "chip-keeps-short-label-and-canonical"))
        (should (and (dsh-emacs-reference--session-chip (point-min) (point) canon)
                     (string= (buffer-substring-no-properties (point-min) (point))
                              "@My Talk")
                     (string= (get-text-property (point-min)
                                                 'dsh-emacs-reference-canonical)
                              canon)
                     (equal (get-text-property (point-min) 'dsh-emacs-reference-ref)
                            `(session . ,sid))
                     (get-text-property (point-min) 'dsh-emacs-reference-chip))))
      ;; no `display' folding: visible text is exactly the short label in the buffer
      (ert-info ((format "%s" "chip-has-no-display-folding"))
        (should (null (get-text-property (point-min) 'display))))
      ;; expansion back to the full mention, via both the raw span reader and
      ;; `dsh-emacs--get-input' (the send / history path)
      (ert-info ((format "%s" "chip-expands-to-full-mention"))
        (should (string= (dsh-emacs-reference--expanded-text (point-min) (point-max))
                         canon))
        (should (string= (dsh-emacs--get-input) canon)))
      ;; self-insert while point sits on the chip hops to its end first
      (goto-char (+ (point-min) 5))
      (let ((this-command 'self-insert-command))
        (dsh-emacs-reference--chip-guard-before))
      (ert-info ((format "%s" "chip-guard-hops-out-of-interior"))
        (should (= (point) (point-max))))
      ;; backspace at the trailing edge deletes the whole chip (atomic unit)
      (goto-char (point-max))
      (delete-backward-char 1)
      (ert-info ((format "%s" "chip-backspace-deletes-whole-span"))
        (should (string= (buffer-substring-no-properties (point-min) (point-max)) "")))
      ;; typing after the chip must not inherit its link/face style
      (insert "@My Talk")
      (dsh-emacs-reference--session-chip (point-min) (point) canon)
      (insert " tail")
      (ert-info ((format "%s" "chip-typed-after-stays-plain"))
        (should (let ((p (- (point) 5)))
                  (and (null (get-text-property p 'face))
                       (null (get-text-property p 'dsh-emacs-reference-chip)))))))))

;; --- C-k on a chip deletes the whole chip atomically (not just its tail) ---
;; Regression: the chip guard used to hop every edit that started on a chip
;; character to the chip's end, so C-k starting on the chip's leading edge or
;; interior only killed what followed it and the chip itself could never be
;; deleted.  Now kill-line on a chip pulls the cursor back to the chip's start
;; so C-k removes the whole chip as one atomic unit.
(ert-deftest dsh-emacs-test-reference-kill-line-on-chip-removes-whole-chip ()
  :tags '(dsh-unit)
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
      (ert-info ((format "%s" "kill-line-on-chip-removes-whole-chip"))
        (should (string-empty-p
                 (buffer-substring-no-properties (point-min) (point-max)))))
      ;; cursor on plain text AFTER the chip -> only the tail is killed, chip kept
      (insert "@My Talk tail")
      (dsh-emacs-reference--session-chip (point-min) (+ (point-min) 8) canon)
      (goto-char (+ (point-min) 9))
      (let ((this-command 'kill-line))
        (dsh-emacs-reference--chip-guard-before))
      (kill-line)
      (ert-info ((format "%s" "kill-line-after-chip-keeps-chip"))
        (should (string= (buffer-substring-no-properties (point-min) (point-max))
                         "@My Talk "))))))

;; A completed file reference is a chip: with the cursor at its end it must not be
;; treated as a new active @ token (otherwise the data watcher re-fetches along
;; that path and re-narrows the candidate cache — the next @ would only hold the
;; previous one's candidates). Only after the cursor moves away, then space + @,
;; is it a new token.
(ert-deftest dsh-emacs-test-reference-active-token-ignores-completed-file-chip ()
  :tags '(dsh-unit)
  (let ((buf (generate-new-buffer " *t-ref-active-chip*")))
    (unwind-protect
        (with-current-buffer buf
          (setq-local dsh-emacs--input-marker (point-min-marker))
          (insert "@src/a.ts")
          (dsh-emacs-reference--composer-file-chip
           (- (point) (length "@src/a.ts")) (point) "src/a.ts")
          (ert-info ((format "%s" "active-token-ignores-completed-file-chip"))
            (should (null (dsh-emacs-reference--active-token))))
          (insert " @x")
          (ert-info ((format "%s" "active-token-after-space-and-at-is-new"))
            (should (equal (dsh-emacs-reference--active-token)
                           '("@x" "x" nil)))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

;; --- active-token / capf: input-area token → completion region and candidates ---
(ert-deftest dsh-emacs-test-reference-active-token-at-point ()
  :tags '(dsh-unit)
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
              (ert-info ((format "%s" "active-token-at-point"))
                (should (equal (dsh-emacs-reference--active-token)
                               '("@re" "re" nil))))
              (let* ((res (dsh-emacs-reference-completion-at-point))
                     (start (nth 0 res))
                     (end (nth 1 res))
                     (cands (nth 2 res))
                     (props (nthcdr 3 res)))
                (ert-info ((format "%s" "capf-region-and-candidates"))
                  (should (= start (- (point-max) 3)))
                  (should (= end (point-max)))
                  (should (equal (dsh-test-completion-items cands)
                                 '("@README.md"))))
                ;; The icon column is always drawn by :affixation-function itself, and the
                ;; capf
                ;; result never provides :company-kind (the :fn-style file/folder glyphs of
                ;; nerd-icons-corfu / kind-icon strip the nerd-font font family → garbled
                ;; symbols)
                (ert-info ((format "%s" "capf-plist-no-company-kind"))
                  (should (functionp (plist-get props :affixation-function)))
                  (should (functionp (plist-get props :exit-function)))
                  (should (null (plist-get props :company-kind))))
                (ert-info ((format "%s" "capf-reopens-bare-at-after-backspace"))
                  (should (eq (plist-get props :company-prefix-length) t)))
                (ert-info ((format "%s" "capf-preserves-reference-order"))
                  (should (eq (plist-get props :display-sort-function) #'identity))
                  (should (eq (completion-metadata-get
                               (completion-metadata "" cands nil)
                               'display-sort-function)
                              #'identity))
                  (should (eq (completion-metadata-get
                               (completion-metadata "" cands nil)
                               'cycle-sort-function)
                              #'identity))))
              ;; Point outside the input area (read-only region) → nil
              (goto-char (point-min))
              (ert-info ((format "%s" "capf-outside-input-nil"))
                (should (null (dsh-emacs-reference-completion-at-point)))))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

;; --- capf session rows: short-label candidates + exit-function rewrites to the
;; canonical mention ---
(ert-deftest dsh-emacs-test-reference-capf-session-row-short ()
  :tags '(dsh-unit)
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
                (ert-info ((format "%s" "capf-session-row-short"))
                  (should (equal (dsh-test-completion-items cands)
                                 '("@My Talk"))))
                ;; Simulate the frontend inserting the row text then calling exit: short
                ;; @label
                ;; text kept + canonical properties
                (delete-region (- (point) 2) (point))
                (insert "@My Talk")
                (ert-info ((format "%s" "capf-exit-keeps-short-label-chip"))
                  (should (progn
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
                                     "hi @[My Talk](dsh-session:cyJpZCI6InMxIn0)"))))
                ;; Completion consumes that @ token: clear the narrowed fetch state so the
                ;; next @
                ;; restores the full set
                (ert-info ((format "%s" "capf-exit-resets-fetch-state"))
                  (should (and (null dsh-emacs--reference-query)
                               (null dsh-emacs--reference-requested))))))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

;; --- directory candidates: after selection immediately request the next level so
;; Corfu can keep expanding ---
(ert-deftest dsh-emacs-test-reference-directory-pick-fetches-next-level ()
  :tags '(dsh-unit)
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
          (ert-info ((format "%s" "directory-pick-fetches-next-level"))
            (should (equal requested '("sess" "src/")))
            (should (null dsh-emacs--reference-query))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

;; --- insert: the active token before point is replaced; with no token, insert at
;; point ---
(ert-deftest dsh-emacs-test-reference-insert-replaces-token-keeps-short-label ()
  :tags '(dsh-unit)
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
          (ert-info ((format "%s" "insert-replaces-token-keeps-short-label"))
            (should (string= (buffer-substring-no-properties (point-min) (point-max))
                             "see @New"))
            (should (string= (get-text-property
                              (- (point-max) (length "@New"))
                              'dsh-emacs-reference-canonical)
                             "@[New](dsh-session:cyJpZCI6InMxIn0)")))
          (goto-char (point-max))
          (dsh-emacs-reference--insert-at-point "@tail.md")
          (ert-info ((format "%s" "insert-no-token-inserts-at-point"))
            (should (string= (buffer-substring-no-properties (point-min) (point-max))
                             "see @New@tail.md")))
          ;; Reading the input expands the short chip back to the full mention (file @path
          ;; is identical)
          (ert-info ((format "%s" "insert-expands-to-full-mention"))
            (should (string= (dsh-emacs--get-input)
                             "see @[New](dsh-session:cyJpZCI6InMxIn0)@tail.md"))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

;; --- active-token: a completed canonical mention (with label escapes) no longer
;; triggers completion ---
(ert-deftest dsh-emacs-test-reference-active-token-completed-plain-nil ()
  :tags '(dsh-unit)
  (let ((buf (generate-new-buffer " *t-ref-done*")))
    (unwind-protect
        (with-current-buffer buf
          (insert "@[My Talk](dsh-session:cyJpZCI6InMxIn0)")
          (setq-local dsh-emacs--input-marker (point-min-marker))
          (goto-char (point-max))
          (ert-info ((format "%s" "active-token-completed-plain-nil"))
            (should (null (dsh-emacs-reference--active-token))))
          ;; The host escapes `\` and `]` in the label as `\\` / `\]` (see the harness's
          ;; formatSessionReferenceMention), so the completion check must keep up
          (erase-buffer)
          (insert "@[My\\]Talk](dsh-session:cyJpZCI6InMxIn0)")
          (goto-char (point-max))
          (ert-info ((format "%s" "active-token-completed-escaped-bracket-nil"))
            (should (null (dsh-emacs-reference--active-token))))
          (erase-buffer)
          (insert "@[a\\\\b](dsh-session:cyJpZCI6InMxIn0)")
          (goto-char (point-max))
          (ert-info ((format "%s" "active-token-completed-escaped-backslash-nil"))
            (should (null (dsh-emacs-reference--active-token))))
          (erase-buffer)
          (insert "hi @re")
          (goto-char (point-max))
          (ert-info ((format "%s" "active-token-in-progress-still-triggers"))
            (should (equal (dsh-emacs-reference--active-token) '("@re" "re" nil)))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

;; Async regressions retain real callback ordering without a server or timers.
(ert-deftest dsh-emacs-test-reference-regression-reset-rejects-old-generation ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (let (calls)
      (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                 (lambda (method params callback)
                   (push (list method (cdr (assq 'query params)) callback) calls)))
                ((symbol-function 'dsh-emacs-reference--schedule-popup-refresh)
                 #'ignore))
        (setq dsh-emacs--reference-requested "old")
        (dsh-emacs-reference--fetch-query "sess" "old")
        (let ((old-file (nth 2 (cadr calls)))
              (old-session (nth 2 (car calls))))
          (funcall old-file t [((path . "old.txt") (kind . "file"))])
          (should dsh-emacs--reference-inflight)
          (should-not dsh-emacs--reference-query)
          (dsh-emacs-reference--reset-fetch)
          (setq dsh-emacs--reference-requested "new")
          (dsh-emacs-reference--fetch-query "sess" "new")
          (funcall old-session t [])
          (funcall old-file t [((path . "obsolete.txt") (kind . "file"))])
          (should (eq dsh-emacs--reference-files 'pending))
          (should (eq dsh-emacs--reference-sessions 'pending))
          (should dsh-emacs--reference-inflight)
          (funcall (nth 2 (car calls)) t [])
          (should dsh-emacs--reference-inflight)
          (should-not dsh-emacs--reference-query)
          (funcall (nth 2 (cadr calls))
                   t [((path . "new.txt") (kind . "file"))])
          (should-not dsh-emacs--reference-inflight)
          (should (equal dsh-emacs--reference-query "new"))
          (should (equal (mapcar #'car dsh-emacs--reference-candidates)
                         '("@new.txt"))))))))

(ert-deftest dsh-emacs-test-reference-regression-superseded-query-coalesces ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (let (calls timers)
      (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                 (lambda (method params callback)
                   (push (list method (cdr (assq 'query params)) callback) calls)))
                ((symbol-function 'run-with-idle-timer)
                 (lambda (_delay _repeat function &rest _args)
                   (let ((timer (timer-create)))
                     (push (cons timer function) timers)
                     timer)))
                ((symbol-function 'dsh-emacs-reference--schedule-popup-refresh)
                 #'ignore))
        (setq dsh-emacs--reference-requested "a")
        (dsh-emacs-reference--fetch-query "sess" "a")
        (dsh-emacs-reference--require-cache "sess" "ab")
        (dsh-emacs-reference--require-cache "sess" "abc")
        (should (= (length calls) 2))
        (should-not timers)
        (funcall (nth 2 (cadr calls))
                 t [((path . "a.txt") (kind . "file"))])
        (should dsh-emacs--reference-inflight)
        (should-not timers)
        (funcall (nth 2 (car calls)) t [])
        (should-not dsh-emacs--reference-query)
        (should-not dsh-emacs--reference-candidates)
        (should (= (length timers) 1))
        (funcall (cdar timers))
        (should (equal (mapcar #'cadr (reverse calls))
                       '("a" "a" "abc" "abc")))
        (funcall (nth 2 (car calls)) t [])
        (should dsh-emacs--reference-inflight)
        (funcall (nth 2 (cadr calls))
                 t [((path . "abc.txt") (kind . "file"))])
        (should (equal dsh-emacs--reference-query "abc"))
        (should (equal (mapcar #'car dsh-emacs--reference-candidates)
                       '("@abc.txt")))))))

(ert-deftest dsh-emacs-test-reference-regression-debounce-cancels-old-timer ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (let ((dsh-emacs-reference-fetch-delay 0.25)
          timers cancelled calls)
      (setq dsh-emacs--reference-query "")
      (cl-letf (((symbol-function 'run-with-idle-timer)
                 (lambda (delay _repeat function &rest _args)
                   (let ((timer (timer-create)))
                     (push (list timer function delay) timers)
                     timer)))
                ((symbol-function 'cancel-timer)
                 (lambda (timer) (push timer cancelled)))
                ((symbol-function 'dsh-emacs--rpc-async)
                 (lambda (_method params _callback)
                   (push (cdr (assq 'query params)) calls))))
        (dsh-emacs-reference--require-cache "sess" "a")
        (let ((old (car timers)))
          (dsh-emacs-reference--require-cache "sess" "ab")
          (dsh-emacs-reference--require-cache "sess" "ab")
          (should (= (length timers) 2))
          (should (equal cancelled (list (car old))))
          (should (equal (mapcar #'caddr timers) '(0.25 0.25)))
          ;; Even an already-queued cancelled callback cannot start its query.
          (funcall (cadr old))
          (should-not calls)
          (should (eq dsh-emacs--reference-fetch-timer (caar timers)))
          (funcall (cadar timers))
          (should (equal calls '("ab" "ab")))
          (should-not dsh-emacs--reference-fetch-timer)
          (should dsh-emacs--reference-inflight))))))

;; Exercise the style protocol with real input, not empty table enumeration.
(ert-deftest dsh-emacs-test-reference-regression-fresh-matches-and-predicate ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (insert "@read")
    (setq-local dsh-emacs--input-marker (point-min-marker)
                dsh-emacs--reference-query "read"
                dsh-emacs--reference-candidates
                '(("@README.md" :kind file :path "README.md")
                  ("@[Design](dsh-session:InMxIg)" :kind session
                   :label "Design" :session-id "s1" :cwd "/work/read")))
    (let ((completion-category-overrides nil)
          (completion-styles '(basic))
          (completion-ignore-case nil))
      (cl-letf (((symbol-function 'dsh-emacs--active-session-id)
                 (lambda () "sess"))
                ((symbol-function 'dsh-emacs-reference--require-cache)
                 (lambda (&rest _args) t)))
        (let ((table (nth 2 (dsh-emacs-reference-completion-at-point))))
          (should (equal (completion-all-completions "@read" table nil 5)
                         '("@README.md" "@Design" . 0)))
          (should (equal (completion-all-completions
                          "@read" table (lambda (row) (equal row "@Design")) 5)
                         '("@Design" . 0)))
          (should (equal (completion-try-completion
                          "@read" table (lambda (row) (equal row "@Design")) 5)
                         '("@Design" . 7)))
          (should-not (completion-all-completions
                       "@read" table (lambda (_row) nil) 5)))))))

;; A settled query belongs to the host: a row it returned stays offered even
;; when the client-side search fields could not have found it, while the same
;; row is filtered out as soon as the cache no longer answers this query.
(ert-deftest dsh-emacs-test-reference-regression-fresh-results-trust-the-host ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (insert "@zzz")
    (setq-local dsh-emacs--input-marker (point-min-marker)
                dsh-emacs--reference-query "zzz"
                dsh-emacs--reference-candidates
                '(("@README.md" :kind file :path "README.md")))
    (let ((completion-category-overrides nil)
          (completion-styles '(basic)))
      (cl-letf (((symbol-function 'dsh-emacs--active-session-id)
                 (lambda () "sess"))
                ((symbol-function 'dsh-emacs-reference--require-cache)
                 (lambda (&rest _args) t)))
        (let ((table (nth 2 (dsh-emacs-reference-completion-at-point))))
          (ert-info ((format "%s" "fresh-results-trust-the-host"))
            (should (equal (completion-all-completions "@zzz" table nil 4)
                           '("@README.md" . 0))))
          (setq dsh-emacs--reference-query "other")
          (ert-info ((format "%s" "stale-results-filter-by-search-fields"))
            (should-not (completion-all-completions "@zzz" table nil 4))))))))

(ert-deftest dsh-emacs-test-reference-regression-cached-search-fields ()
  :tags '(dsh-unit)
  (dolist (case '(("@read" "@README.md")
                  ("@source-123" "@Design")
                  ("@workspace" "@Design")
                  ("@src\\read" "@src/readme.md")))
    (with-temp-buffer
      (insert (car case))
      (setq-local dsh-emacs--input-marker (point-min-marker)
                  dsh-emacs--reference-query ""
                  dsh-emacs--reference-candidates
                  '(("@README.md" :kind file :path "README.md")
                    ("@src/readme.md" :kind file :path "src/readme.md")
                    ("@[Design](dsh-session:InMxIg)" :kind session
                     :label "Design" :session-id "source-123"
                     :cwd "/work/workspace")))
      (let ((completion-category-overrides nil)
            (completion-styles '(basic))
            (completion-ignore-case nil))
        (cl-letf (((symbol-function 'dsh-emacs--active-session-id)
                   (lambda () "sess"))
                  ((symbol-function 'dsh-emacs-reference--require-cache)
                   (lambda (&rest _args) t)))
          (let* ((table (nth 2 (dsh-emacs-reference-completion-at-point)))
                 (matches (completion-all-completions
                           (car case) table nil (length (car case)))))
            (should (equal matches
                           (if (equal (car case) "@read")
                               '("@README.md" "@src/readme.md" . 0)
                             (cons (cadr case) 0))))))))))

(ert-deftest dsh-emacs-test-reference-regression-user-basic-override ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (insert "@r")
    (setq-local dsh-emacs--input-marker (point-min-marker)
                dsh-emacs--reference-query "r"
                dsh-emacs--reference-candidates
                '(("@src/readme.md" :kind file :path "src/readme.md")
                  ("@README.md" :kind file :path "README.md")
                  ("@root.txt" :kind file :path "root.txt")))
    (let ((completion-category-overrides
           '((dsh-emacs-reference (styles basic))))
          (completion-styles '(basic))
          (completion-ignore-case nil))
      (cl-letf (((symbol-function 'dsh-emacs--active-session-id)
                 (lambda () "sess"))
                ((symbol-function 'dsh-emacs-reference--require-cache)
                 (lambda (&rest _args) t)))
        (let ((table (nth 2 (dsh-emacs-reference-completion-at-point))))
          (should (equal (completion-all-completions "@r" table nil 2)
                         '("@root.txt" . 0))))))))

(ert-deftest dsh-emacs-test-reference-regression-live-table-foreign-buffer ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (insert "@old")
    (setq-local dsh-emacs--input-marker (point-min-marker)
                dsh-emacs--reference-query "old"
                dsh-emacs--reference-candidates
                '(("@old.txt" :kind file :path "old.txt")))
    (let ((origin (current-buffer))
          (completion-category-overrides nil)
          (completion-styles '(basic)))
      (cl-letf (((symbol-function 'dsh-emacs--active-session-id)
                 (lambda () "sess"))
                ((symbol-function 'dsh-emacs-reference--require-cache)
                 (lambda (&rest _args) t)))
        (let ((table (nth 2 (dsh-emacs-reference-completion-at-point))))
          (with-temp-buffer
            (setq-local dsh-emacs--reference-query "old"
                        dsh-emacs--reference-candidates
                        '(("@foreign.txt" :kind file :path "foreign.txt")))
            (should (equal (completion-all-completions "@old" table nil 4)
                           '("@old.txt" . 0)))
            (with-current-buffer origin
              (setq dsh-emacs--reference-query "new"
                    dsh-emacs--reference-candidates
                    '(("@new.txt" :kind file :path "new.txt"))))
            (should (equal (completion-all-completions "@new" table nil 4)
                           '("@new.txt" . 0)))
            (should (equal dsh-emacs--reference-query "old"))))))))

(ert-deftest dsh-emacs-test-reference-regression-quoted-directory-pick ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (insert "@\"sr")
    (setq-local dsh-emacs--input-marker (point-min-marker)
                dsh-emacs--reference-query "sr"
                dsh-emacs--reference-candidates
                '(("@src/" :kind directory :path "src")))
    (let ((completion-category-overrides nil)
          (completion-styles '(basic))
          requested)
      (cl-letf (((symbol-function 'dsh-emacs--active-session-id)
                 (lambda () "sess"))
                ((symbol-function 'dsh-emacs-reference--require-cache)
                 (lambda (&rest _args) t))
                ((symbol-function 'dsh-emacs-reference--fetch-query)
                 (lambda (session query) (setq requested (list session query)))))
        (let* ((capf (dsh-emacs-reference-completion-at-point))
               (table (nth 2 capf))
               (exit (plist-get (nthcdr 3 capf) :exit-function))
               (result (completion-try-completion "@\"sr" table nil 4)))
          (should (equal result '("@\"src/" . 6)))
          (delete-region (nth 0 capf) (nth 1 capf))
          (insert (car result))
          (funcall exit (car result) 'finished)
          (should (equal (buffer-string) "@\"src/"))
          (should (equal requested '("sess" "src/")))
          (should-not (get-text-property (point-min) 'dsh-emacs-reference-chip))
          (should (equal (dsh-emacs-reference--active-token)
                         '("@\"src/" "src/" t))))))))

(ert-deftest dsh-emacs-test-reference-regression-snapshot-file-pick ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (insert "@old")
    (setq-local dsh-emacs--input-marker (point-min-marker)
                dsh-emacs--reference-query "old"
                dsh-emacs--reference-candidates
                '(("@old.txt" :kind file :path "old.txt")))
    (cl-letf (((symbol-function 'dsh-emacs--active-session-id)
               (lambda () "sess"))
              ((symbol-function 'dsh-emacs-reference--require-cache)
               (lambda (&rest _args) t)))
      (let* ((capf (dsh-emacs-reference-completion-at-point))
             (exit (plist-get (nthcdr 3 capf) :exit-function)))
        (setq dsh-emacs--reference-query "new"
              dsh-emacs--reference-candidates
              '(("@new.txt" :kind file :path "new.txt")))
        (delete-region (nth 0 capf) (nth 1 capf))
        (insert "@old.txt")
        (funcall exit "@old.txt" 'finished)
        (should (equal (get-text-property (point-min) 'dsh-emacs-reference-ref)
                       '(file . "old.txt")))
        (should (get-text-property (point-min) 'dsh-emacs-reference-chip))
        (should-not dsh-emacs--reference-query)))))

(ert-deftest dsh-emacs-test-reference-regression-stock-exact-stays-editable ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (insert "@a")
    (setq-local dsh-emacs--input-marker (point-min-marker)
                dsh-emacs--reference-query "a"
                dsh-emacs--reference-candidates
                '(("@a" :kind file :path "a")
                  ("@ab" :kind file :path "ab"))
                completion-at-point-functions
                '(dsh-emacs-reference-completion-at-point))
    (let ((completion-category-overrides nil)
          (completion-styles '(basic))
          (completion-cycle-threshold nil)
          (completion-in-region-function #'completion--in-region))
      (cl-letf (((symbol-function 'dsh-emacs--active-session-id)
                 (lambda () "sess"))
                ((symbol-function 'dsh-emacs-reference--require-cache)
                 (lambda (&rest _args) t)))
        (completion-at-point)
        (should (equal (buffer-string) "@a"))
        (should-not (get-text-property (point-min) 'dsh-emacs-reference-chip))
        (should (equal dsh-emacs--reference-query "a"))
        (should (equal (dsh-emacs-reference--active-token) '("@a" "a" nil)))
        (insert "b")
        (completion-at-point)
        (should (equal (buffer-string) "@ab"))
        (should (equal (get-text-property (point-min) 'dsh-emacs-reference-ref)
                       '(file . "ab")))))))

(ert-deftest dsh-emacs-test-reference-table-outlives-source-buffer ()
  :tags '(dsh-unit)
  (let ((table
         (with-temp-buffer
           (insert "@a")
           (setq-local dsh-emacs--input-marker (point-min-marker)
                       dsh-emacs--reference-query "a"
                       dsh-emacs--reference-candidates
                       '(("@a.txt" :kind file :path "a.txt")))
           (cl-letf (((symbol-function 'dsh-emacs--active-session-id)
                      (lambda () "sess"))
                     ((symbol-function 'dsh-emacs-reference--require-cache)
                      (lambda (&rest _) t)))
             (nth 2 (dsh-emacs-reference-completion-at-point))))))
    (should (equal (completion-metadata "" table nil) '(metadata)))
    (should-not (all-completions "" table nil))
    (should-not (completion-all-completions "@a" table nil 2))))

(ert-deftest dsh-emacs-test-reference-hides-archived-sessions-in-cached-menus ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (insert "@")
    (setq-local dsh-emacs--input-marker (point-min-marker)
                dsh-emacs--reference-query ""
                dsh-emacs--reference-candidates
                '(("@old" :kind file :path "old")
                  ("@dir/" :kind directory :path "dir")
                  ("old-mention" :kind session :label "Old" :session-id "old")
                  ("live-mention" :kind session :label "Live" :session-id "live")))
    (let ((original dsh-emacs--reference-candidates)
          (dsh-emacs--archived-sessions
           (dsh-emacs--normalize-archived '("old")))
          (completion-category-overrides nil)
          (completion-styles '(basic)))
      (cl-letf (((symbol-function 'dsh-emacs--active-session-id)
                 (lambda () "sess"))
                ((symbol-function 'dsh-emacs-reference--require-cache)
                 (lambda (&rest _) t)))
        (let ((table (nth 2 (dsh-emacs-reference-completion-at-point))))
          (dolist (case '((("old") ("@old" "@dir/" "@Live")
                           ("@old" "@dir/" "live-mention"))
                          (("live") ("@old" "@dir/" "@Old")
                           ("@old" "@dir/" "old-mention"))
                          (nil ("@old" "@dir/" "@Old" "@Live")
                               ("@old" "@dir/" "old-mention" "live-mention"))))
            ;; The host replaces this set on archive/unarchive notifications.
            (setq dsh-emacs--archived-sessions
                  (dsh-emacs--normalize-archived (nth 0 case)))
            (should (equal (all-completions "@" table nil) (nth 1 case)))
            (should (equal (completion-all-completions "@" table nil 1)
                           (append (nth 1 case) 0)))
            (should (equal (mapcar #'cdr (dsh-emacs-reference--display-pairs))
                           (nth 2 case)))
            (should (eq original dsh-emacs--reference-candidates))))))))

;; @ mirrors the session list's visible-session rule: archived ids (even when
;; the list cache does not know them), blank never-messaged sessions and
;; subagent-origin sessions are not suggested, while a session the cache does
;; not know stays offered, so a cold list cache only degrades to the archive
;; registry.
(ert-deftest dsh-emacs-test-reference-visible-candidates-follow-the-session-list ()
  :tags '(dsh-unit)
  (let* ((sessions (list (dsh-protocol-session--from-alist
                          '((sessionId . "live") (blank . :json-false)))
                         (dsh-protocol-session--from-alist
                          '((sessionId . "blank") (blank . t)))
                         (dsh-protocol-session--from-alist
                          '((sessionId . "sub") (blank . :json-false)
                            (origin . "subagent")))
                         (dsh-protocol-session--from-alist
                          '((sessionId . "archived") (blank . :json-false)))))
         (dsh-emacs--sessions sessions)
         (dsh-emacs--archived-sessions
          (dsh-emacs--normalize-archived '("archived" "gone")))
         (dsh-emacs--current-session nil)
         (dsh-emacs--reference-candidates
          (list (cons "@live" '(:kind session :label "Live" :session-id "live"))
                (cons "@blank" '(:kind session :label "Blank" :session-id "blank"))
                (cons "@sub" '(:kind session :label "Sub" :session-id "sub"))
                (cons "@archived" '(:kind session :label "Archived"
                                    :session-id "archived"))
                (cons "@gone" '(:kind session :label "Gone" :session-id "gone"))
                (cons "@unknown" '(:kind session :label "Unknown"
                                   :session-id "unknown"))
                (cons "@file.txt" '(:kind file :path "file.txt")))))
    (ert-info ((format "%s" "visible-candidates-follow-the-session-list"))
      (should (equal (mapcar #'car (dsh-emacs-reference--visible-candidates))
                     '("@live" "@unknown" "@file.txt"))))
    ;; The filter is live: a first message clears `blank' and restores the row
    ;; without refetching candidates.
    (setf (dsh-protocol-session-blank
           (cl-find "blank" sessions :key #'dsh-protocol-session-session-id
                    :test #'equal))
          nil)
    (ert-info ((format "%s" "visible-candidates-restore-after-first-message"))
      (should (equal (mapcar #'car (dsh-emacs-reference--visible-candidates))
                     '("@live" "@blank" "@unknown" "@file.txt"))))))

(provide 'dsh-test-reference)
;;; dsh-test-reference.el ends here
