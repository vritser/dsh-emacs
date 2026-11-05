;;; dsh-test-skill.el --- Skill tests -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "28.1"))

(require 'dsh-test-support)

(ert-deftest dsh-emacs-test-skill-prefetch-keeps-origin-and-owner ()
  :tags '(dsh-unit)
  (dolist (change '(none stop endpoint closed))
    (let ((origin (generate-new-buffer " *dsh-prefetch-origin*"))
          (dsh-emacs-base-url "http://prefetch.example")
          (dsh-emacs--server-generation 0)
          (dsh-emacs--server-process nil)
          (dsh-emacs--server-alive-check nil)
          (dsh-emacs--skill-catalogs nil)
          (dsh-emacs--skill-fetch-inflight nil)
          (dsh-emacs--skill-fetch-stamps nil)
          (dsh-emacs-skill-prefetch t)
          (calls 0) timer)
      (unwind-protect
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (_method _params callback)
                       (cl-incf calls)
                       (should (eq (current-buffer) origin))
                       (funcall callback t []))))
            (with-current-buffer origin
              (setq timer (dsh-emacs-skill-prefetch "same-session")))
            (should (timerp timer))
            (cancel-timer timer)
            (pcase change
              ('stop (dsh-emacs-server-stop))
              ('endpoint (setq dsh-emacs-base-url "http://other.example"))
              ('closed (kill-buffer origin)))
            ;; Timers run with an unrelated current buffer.  Deliver even
            ;; after cancellation to exercise ownership, not the scheduler.
            (with-temp-buffer
              (apply (timer--function timer) (timer--args timer)))
            (should (= calls (if (eq change 'none) 1 0)))
            (should-not dsh-emacs--skill-fetch-inflight))
        (when (timerp timer) (cancel-timer timer))
        (when (buffer-live-p origin) (kill-buffer origin))))))

;; --- Test 97b: skill catalog (skills/list) ---
(ert-deftest dsh-emacs-test-skill-skill-from-alist-full ()
  :tags '(dsh-unit)
  (let* ((skill (dsh-protocol-skill--from-alist
                 '((name . "review")
                   (description . "Review a diff")
                   (whenToUse . "before committing")
                   (modelInvocable . t)
                   (path . "/tmp/skills/review/SKILL.md")))))
    (ert-info ((format "%s" "skill-from-alist-full"))
      (should (string= "review" (dsh-protocol-skill-name skill)))
      (should (string= "Review a diff" (dsh-protocol-skill-description skill)))
      (should (string= "before committing" (dsh-protocol-skill-when-to-use skill)))
      (should (dsh-protocol-skill-model-invocable skill))
      (should (string= "/tmp/skills/review/SKILL.md" (dsh-protocol-skill-path skill))))))

(ert-deftest dsh-emacs-test-skill-skill-from-alist-user-only ()
  :tags '(dsh-unit)
  (let ((skill (dsh-protocol-skill--from-alist
                '((name . "notes") (description . "Private notes")
                  (modelInvocable . :json-false)))))
    (ert-info ((format "%s" "skill-from-alist-user-only"))
      (should (null (dsh-protocol-skill-model-invocable skill)))
      (should (null (dsh-protocol-skill-when-to-use skill)))
      (should (null (dsh-protocol-skill-path skill))))))

;; The value is an envelope object ({skills: [...]}) whose array arrives as a
;; vector; a non-object element is dropped at the protocol boundary
(ert-deftest dsh-emacs-test-skill-skill-list-envelope-normalizes-array ()
  :tags '(dsh-unit)
  (let* ((value (dsh-protocol-skill-list--from-alist
                 '((skills . [((name . "a")) "junk" ((name . "b"))]))))
         (skills (dsh-protocol-skill-list-skills value)))
    (ert-info ((format "%s" "skill-list-envelope-normalizes-array"))
      (should (= 2 (length skills)))
      (should (string= "a" (dsh-protocol-skill-name (car skills))))
      (should (string= "b" (dsh-protocol-skill-name (cadr skills)))))))

;; A value that is not the promised envelope object declines at the protocol
;; boundary instead of signalling out of the constructor (an old server that
;; answers 404-style empty arrays must not break the "/" completion)
(ert-deftest dsh-emacs-test-skill-skill-list-malformed-value-declines ()
  :tags '(dsh-unit)
  (ert-info ((format "%s" "skill-list-malformed-value-declines"))
    (should (null (dsh-protocol-skill-list-skills
                   (dsh-protocol-skill-list--from-alist []))))))

(ert-deftest dsh-emacs-test-skill-skill-catalog-sync-caches ()
  :tags '(dsh-unit)
  (let ((sid "sess-skill")
        (calls 0)
        (seen nil)
        (old dsh-emacs--skill-catalogs))
    (unwind-protect
        (cl-letf (((symbol-function 'dsh-emacs--rpc-request)
                   (lambda (method params)
                     (setq calls (1+ calls))
                     (push (cons method params) seen)
                     (cons t '((skills . [((name . "review")
                                           (description . "R")
                                           (modelInvocable . t))]))))))
          (let ((items (dsh-emacs-skill-catalog-sync sid))
                (again (dsh-emacs-skill-catalog-sync sid)))
            (ert-info ((format "%s" "skill-catalog-sync-caches"))
              (should (= calls 1))
              (should (= 1 (length items)))
              (should (string= "review" (dsh-protocol-skill-name (car items))))
              (should (equal again items))
              (should (equal '((request (sessionId . "sess-skill")))
                             (cdr (assoc "skills/list" seen)))))))
      (setq dsh-emacs--skill-catalogs old))))

;; An empty catalog is a real answer: cache it so TAB does not re-fetch a
;; session that has no skills
(ert-deftest dsh-emacs-test-skill-skill-catalog-caches-empty ()
  :tags '(dsh-unit)
  (let ((sid "sess-skill-empty")
        (calls 0)
        (old dsh-emacs--skill-catalogs))
    (unwind-protect
        (cl-letf (((symbol-function 'dsh-emacs--rpc-request)
                   (lambda (_m _p)
                     (setq calls (1+ calls))
                     (cons t '((skills . []))))))
          (let ((first (dsh-emacs-skill-catalog-sync sid))
                (second (dsh-emacs-skill-catalog-sync sid)))
            (ert-info ((format "%s" "skill-catalog-caches-empty"))
              (should (null first))
              (should (null second))
              (should (= calls 1)))))
      (setq dsh-emacs--skill-catalogs old))))

(ert-deftest dsh-emacs-test-skill-skill-catalog-fetch-async ()
  :tags '(dsh-unit)
  (let ((sid "sess-skill-async")
        (fetched 'none)
        (old dsh-emacs--skill-catalogs))
    (unwind-protect
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (_m _p cb)
                     (funcall cb t '((skills . [((name . "audit"))]))))))
          (dsh-emacs-skill-catalog-fetch
           sid (lambda (items) (setq fetched items)))
          (ert-info ((format "%s" "skill-catalog-fetch-async"))
            (should (consp fetched))
            (should (string= "audit" (dsh-protocol-skill-name (car fetched))))
            (should (equal fetched (dsh-emacs-skill-catalog sid)))))
      (setq dsh-emacs--skill-catalogs old))))

;; Several fetches for one session leave exactly one cache entry (string keys
;; need assoc-delete-all, same as the command catalog)
(ert-deftest dsh-emacs-test-skill-skill-catalog-single-entry-per-session ()
  :tags '(dsh-unit)
  (let ((sid "sess-skill-dedup")
        (old dsh-emacs--skill-catalogs))
    (unwind-protect
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (_m _p cb)
                     (funcall cb t '((skills . [((name . "a"))]))))))
          (dsh-emacs-skill-catalog-fetch sid)
          (dsh-emacs-skill-catalog-fetch sid)
          (let ((entries (cl-remove-if-not
                          (lambda (e) (string= sid (car e)))
                          dsh-emacs--skill-catalogs)))
            (ert-info ((format "%s" "skill-catalog-single-entry-per-session"))
              (should (= 1 (length entries))))))
      (setq dsh-emacs--skill-catalogs old))))

(ert-deftest dsh-emacs-test-skill-skill-prefetch-schedules-timer ()
  :tags '(dsh-unit)
  (let ((sid "sess-skill-prefetch")
        (old dsh-emacs--skill-catalogs)
        (old-pref dsh-emacs-skill-prefetch)
        (old-delay dsh-emacs-skill-prefetch-delay)
        (timers nil))
    (unwind-protect
        (progn
          (setq dsh-emacs-skill-prefetch t
                dsh-emacs-skill-prefetch-delay 0.05)
          (let ((timer (dsh-emacs-skill-prefetch sid)))
            (when timer (push timer timers))
            (ert-info ((format "%s" "skill-prefetch-schedules-timer"))
              (should (timerp timer))))
          (dsh-emacs-skill--cache-catalog
           sid (list (dsh-protocol-skill--from-alist '((name . "x")))))
          (let ((before (length timer-list)))
            (dsh-emacs-skill-prefetch sid)
            (ert-info ((format "%s" "skill-prefetch-skips-when-cached"))
              (should (= (length timer-list) before)))))
      (mapc #'cancel-timer timers)
      (setq dsh-emacs--skill-catalogs old
            dsh-emacs-skill-prefetch old-pref
            dsh-emacs-skill-prefetch-delay old-delay))))

(ert-deftest dsh-emacs-test-skill-skill-catalog-refresh-replaces-cache ()
  :tags '(dsh-unit)
  (let ((sid "sess-skill-refresh")
        (calls 0)
        (old dsh-emacs--skill-catalogs))
    (unwind-protect
        (progn
          (dsh-emacs-skill--cache-catalog
           sid (list (dsh-protocol-skill--from-alist '((name . "old")))))
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (_m _p cb)
                       (setq calls (1+ calls))
                       (funcall cb t '((skills . [((name . "new"))]))))))
            (dsh-emacs-skill-catalog-refresh sid)
            (let ((items (dsh-emacs-skill-catalog sid)))
              (ert-info ((format "%s" "skill-catalog-refresh-replaces-cache"))
                (should (= calls 1))
                (should (string= "new" (dsh-protocol-skill-name (car items))))))))
      (setq dsh-emacs--skill-catalogs old))))

;; A response from a fetch that a refresh superseded must not repopulate the
;; cache: the older request can land after the newer one (this is the race the
;; prefetch timer and the manual refresh run into)
(ert-deftest dsh-emacs-test-skill-skill-catalog-drops-superseded-response ()
  :tags '(dsh-unit)
  (let ((sid "sess-skill-stale")
        (old-catalogs dsh-emacs--skill-catalogs)
        (old-inflight dsh-emacs--skill-fetch-inflight)
        (old-stamps dsh-emacs--skill-fetch-stamps)
        (callbacks nil))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (_m _p cb) (push cb callbacks))))
            (dsh-emacs-skill-catalog-fetch sid))
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (_m _p cb) (push cb callbacks))))
            (dsh-emacs-skill-catalog-refresh sid))
          (funcall (nth 0 callbacks) t '((skills . [((name . "fresh"))])))
          (funcall (nth 1 callbacks) t '((skills . [((name . "stale"))])))
          (let ((items (dsh-emacs-skill-catalog sid)))
            (ert-info ((format "%s" "skill-catalog-drops-superseded-response"))
              (should (consp items))
              (should (string= "fresh" (dsh-protocol-skill-name (car items)))))))
      (setq dsh-emacs--skill-catalogs old-catalogs
            dsh-emacs--skill-fetch-inflight old-inflight
            dsh-emacs--skill-fetch-stamps old-stamps))))

;; Synchronous completion supersedes prefetch too, including replies delivered
;; while the blocking RPC pumps process output, not just after it returns.
(ert-deftest dsh-emacs-test-skill-skill-sync-supersedes-prefetch-case ()
  :tags '(dsh-unit)
  (dolist (timing '(during after))
    (let ((dsh-emacs--skill-catalogs nil)
          (dsh-emacs--skill-fetch-inflight nil)
          (dsh-emacs--skill-fetch-stamps nil)
          callback
          (old-callback-ran nil))
      (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                 (lambda (_method _params cb) (setq callback cb)))
                ((symbol-function 'dsh-emacs--rpc-request)
                 (lambda (&rest _)
                   (when (eq timing 'during)
                     (funcall callback t '((skills . [((name . "old"))]))))
                   (cons t '((skills . [((name . "new"))]))))))
        (dsh-emacs-skill-catalog-fetch
         "sync-race" (lambda (_) (setq old-callback-ran t)))
        (dsh-emacs-skill-catalog-sync "sync-race")
        (when (eq timing 'after)
          (funcall callback t '((skills . [((name . "old"))]))))
        (ert-info ((format "%s" (format "skill-sync-supersedes-prefetch-%s" timing)))
          (should (equal '("new") (mapcar #'dsh-protocol-skill-name
                                          (dsh-emacs-skill-catalog "sync-race"))))
          (should (not old-callback-ran))
          (should (not (member "sync-race" dsh-emacs--skill-fetch-inflight))))))))

;; A refresh started during a synchronous wait owns the cache and inflight
;; marker; completion must not overwrite it when its older RPC returns.
(ert-deftest dsh-emacs-test-skill-skill-sync-preserves-newer-refresh-inflight ()
  :tags '(dsh-unit)
  (let ((dsh-emacs--skill-catalogs nil)
        (dsh-emacs--skill-fetch-inflight nil)
        (dsh-emacs--skill-fetch-stamps nil)
        callback)
    (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
               (lambda (_method _params cb) (setq callback cb)))
              ((symbol-function 'dsh-emacs--rpc-request)
               (lambda (&rest _)
                 (dsh-emacs-skill-catalog-refresh "newer-refresh")
                 (cons t '((skills . [((name . "old"))]))))))
      (dsh-emacs-skill-catalog-sync "newer-refresh")
      (ert-info ((format "%s" "skill-sync-preserves-newer-refresh-inflight"))
        (should (null (dsh-emacs-skill-catalog "newer-refresh")))
        (should (member "newer-refresh" dsh-emacs--skill-fetch-inflight)))
      (funcall callback t '((skills . [((name . "new"))]))))
    (ert-info ((format "%s" "skill-sync-allows-newer-refresh-result"))
      (should (equal '("new") (mapcar #'dsh-protocol-skill-name
                                      (dsh-emacs-skill-catalog "newer-refresh")))))))

;; Aborted synchronous requests must not leave a permanent in-flight guard.
(ert-deftest dsh-emacs-test-skill-skill-sync-cleans-up-case ()
  :tags '(dsh-unit)
  (dolist (failure '(error quit))
    (let ((dsh-emacs--skill-catalogs nil)
          (dsh-emacs--skill-fetch-inflight nil)
          (dsh-emacs--skill-fetch-stamps nil))
      (cl-letf (((symbol-function 'dsh-emacs--rpc-request)
                 (lambda (&rest _) (signal failure '("test abort")))))
        (condition-case nil
            (dsh-emacs-skill-catalog-sync "sync-abort")
          ((error quit) nil)))
      (ert-info ((format "%s" (format "skill-sync-cleans-up-%s" failure)))
        (should (not (member "sync-abort" dsh-emacs--skill-fetch-inflight)))
        (should (not (assoc "sync-abort" dsh-emacs--skill-fetch-stamps)))))))

(provide 'dsh-test-skill)
;;; dsh-test-skill.el ends here
