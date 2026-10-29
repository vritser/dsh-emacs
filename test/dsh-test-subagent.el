;;; dsh-test-subagent.el --- Subagent tests -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "28.1"))

(require 'dsh-test-support)

;; A repeated summary updates live facts without discarding projection cells.
(ert-deftest dsh-emacs-test-subagent-subagent-summary-upsert-preserves-projections ()
  :tags '(dsh-unit)
  (let* ((item (dsh-protocol-session--from-alist
                '((sessionId . "subagent-parent") (running . :json-false)
                  (projections . ((values . ((title . "New control title")
                                             (contextPressure . ((pressureTokens . 42)
                                                                 (contextWindow . 100))))))))))
         (dsh-emacs--sessions (list item)))
    (cl-letf (((symbol-function 'dsh-emacs-events--host-repaint) #'ignore))
      (dsh-emacs-events--host-session-added
       '((sessionId . "subagent-parent") (running . t) (agentAvailable . t)
         (updatedAt . 73) (projections . ((values . ((title . "Old hint"))))))))
    (ert-info ((format "%s" "subagent-summary-upsert-preserves-projections"))
      (should (dsh-protocol-session-running item))
      (should (equal (dsh-protocol-session-title-value item) "New control title"))
      (should (= (dsh-protocol-session-context-pressure item) 42)))))

;; Subagent protocol, store and capability contracts.
(ert-deftest dsh-emacs-test-subagent-subagent-availability-three-states ()
  :tags '(dsh-unit)
  (let ((unknown (dsh-protocol-session--from-alist '((sessionId . "p"))))
        (offline (dsh-protocol-session--from-alist '((agentAvailable . :json-false))))
        (online (dsh-protocol-session--from-alist '((agentAvailable . t)))))
    (ert-info ((format "%s" "subagent-availability-three-states"))
      (should (null (dsh-protocol-session-agent-available unknown)))
      (should (eq :unavailable (dsh-protocol-session-agent-available offline)))
      (should (eq t (dsh-protocol-session-agent-available online))))))

(ert-deftest dsh-emacs-test-subagent-subagent-cumulative-token-contract ()
  :tags '(dsh-unit)
  (let* ((usage (dsh-protocol-token-usage--from-alist
                 '((uncachedInputTokens . 13) (outputTokens . 7)
                   (cacheReadTokens . 101) (cacheWriteTokens . 3))))
         (address (dsh-protocol-subagent-address-create "direct" "grandchild" "continuable"))
         (follow (dsh-protocol-session-address-json "grandchild" address))
         (prompt (cdr (assq 'request (dsh-protocol-subagent-prompt-request
                                      address "req" "steer" "hello" "UTC")))))
    (ert-info ((format "%s" "subagent-cumulative-token-contract"))
      (should (= (dsh-protocol-token-usage-input usage) 13))
      (should (= (dsh-emacs-subagent-token-total usage) 124)))
    (ert-info ((format "%s" "subagent-direct-parent-address"))
      (should (equal (cdr (assq 'parentSessionId follow)) "direct"))
      (should (equal (cdr (assq 'childSessionId follow)) "grandchild"))
      (should (equal (cdr (assq 'kind follow)) "subagent"))
      (should (equal (dsh-protocol-session-address-json "ordinary")
                     '((kind . "session") (sessionId . "ordinary")))))
    (ert-info ((format "%s" "subagent-prompt-fields"))
      (should (equal prompt '((requestId . "req") (parentSessionId . "direct")
                              (childSessionId . "grandchild") (mode . "continuable")
                              (delivery . "steer")
                              (content . [((type . "text") (text . "hello"))])
                              (clientTimeZone . "UTC"))))
      (should (equal (dsh-protocol-subagent-stop-request address)
                     '((parentSessionId . "direct") (childSessionId . "grandchild")
                       (mode . "continuable")))))))

(ert-deftest dsh-emacs-test-subagent-subagent-cells-ignore-stale-cold-read-without-chat ()
  :tags '(dsh-unit)
  (let ((dsh-emacs--subagent-catalogs (make-hash-table :test #'equal)))
    (cl-letf (((symbol-function 'dsh-emacs-subagent--changed) #'ignore))
      (dsh-emacs-subagent-apply
       "child" (dsh-protocol-subagent-baseline--from-alist
                '((asOfSeq . 5) (values (subagentCatalog . [])
                                        (tokenUsage (uncachedInputTokens . 10) (outputTokens . 2))))))
      (dsh-emacs-subagent-apply
       "child" (list (dsh-protocol-subagent-cell--from-alist
                      '((key . "tokenUsage") (seq . 9)
                        (value (uncachedInputTokens . 20) (outputTokens . 4))))))
      (dsh-emacs-subagent-apply
       "child" (dsh-protocol-subagent-baseline--from-alist
                '((asOfSeq . 7) (values (tokenUsage (uncachedInputTokens . 999))))))
      (ert-info ((format "%s" "subagent-cells-ignore-stale-cold-read-without-chat"))
        (should (= (dsh-emacs-subagent-token-total
                    (dsh-emacs-subagent--value "child" 'tokenUsage)) 24))
        (should (eq 'ready (plist-get (gethash "child" dsh-emacs--subagent-catalogs) :state))))
      (let (callbacks (requests 0))
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (_method _args callback)
                     (cl-incf requests) (push callback callbacks))))
          (dsh-emacs-subagent-refresh "cold")
          (dsh-emacs-subagent-apply
           "cold" (dsh-protocol-subagent-baseline--from-alist
                   '((asOfSeq . 3) (values (subagentCatalog . [])))))
          (dsh-emacs-subagent-refresh "cold")
          (ert-info ((format "%s" "subagent-cold-read-deduplicated-after-live-update"))
            (should (= requests 1))
            (should (eq 'loading (plist-get (gethash "cold" dsh-emacs--subagent-catalogs) :state))))
          (funcall (pop callbacks) nil '((message . "unavailable")))
          (ert-info ((format "%s" "subagent-cold-error-visible"))
            (should (eq 'error (plist-get (gethash "cold" dsh-emacs--subagent-catalogs) :state))))
          (dsh-emacs-subagent-refresh "cold")
          (funcall (pop callbacks) t '((asOfSeq . 8) (values (subagentCatalog . []))))
          (ert-info ((format "%s" "subagent-cold-retry-ready-empty"))
            (should (= requests 2))
            (should (eq 'ready (plist-get (gethash "cold" dsh-emacs--subagent-catalogs) :state)))
            (should (dsh-protocol-subagent-cell-present
                     (dsh-emacs-subagent--cell "cold" 'subagentCatalog)))))))))

(ert-deftest dsh-emacs-test-subagent-projection-notifies-only-on-change ()
  :tags '(dsh-unit)
  (let ((dsh-emacs--subagent-catalogs (make-hash-table :test #'equal))
        (changes 0))
    (cl-letf (((symbol-function 'dsh-emacs-subagent--changed)
               (lambda () (cl-incf changes) nil)))
      (dsh-emacs-subagent-apply
       "child" (dsh-protocol-subagent-baseline--from-alist
                '((asOfSeq . 5) (values (subagentCatalog . [])
                                        (tokenUsage (outputTokens . 12))))))
      (should (= changes 1))
      (dolist (seq '(4 5))
        (dsh-emacs-subagent-apply
         "child" (dsh-protocol-subagent-baseline--from-alist
                  `((asOfSeq . ,seq) (values (subagentCatalog . [])
                                             (tokenUsage (outputTokens . 999)))))))
      (should (= changes 1))
      (should (= 12 (dsh-emacs-subagent-token-total
                     (dsh-emacs-subagent--value "child" 'tokenUsage))))
      ;; A newer watermark matters even when the value is unchanged.
      (dsh-emacs-subagent-apply
       "child" (list (dsh-protocol-subagent-cell--from-alist
                      '((key . "tokenUsage") (seq . 9)
                        (value (outputTokens . 12))))))
      (should (= changes 2))
      (should (= 9 (dsh-protocol-subagent-cell-seq
                    (dsh-emacs-subagent--cell "child" 'tokenUsage))))
      (dsh-emacs-subagent-apply
       "child" (list (dsh-protocol-subagent-cell--from-alist
                      '((key . "tokenUsage") (seq . 8)
                        (value (outputTokens . 999))))))
      (should (= changes 2))
      (should (= 12 (dsh-emacs-subagent-token-total
                     (dsh-emacs-subagent--value "child" 'tokenUsage))))
      (puthash "child" (plist-put (gethash "child" dsh-emacs--subagent-catalogs)
                                  :state 'error)
               dsh-emacs--subagent-catalogs)
      (dsh-emacs-subagent-apply "child" nil)
      (should (= changes 3))
      (should (eq 'ready (plist-get
                          (gethash "child" dsh-emacs--subagent-catalogs) :state)))
      (dsh-emacs-subagent-apply "child" nil)
      (should (= changes 3)))))

(ert-deftest dsh-emacs-test-subagent-refresh-notifies-read-state-transitions ()
  :tags '(dsh-unit)
  (let ((dsh-emacs--subagent-catalogs (make-hash-table :test #'equal))
        (dsh-emacs--subagent-generation 1)
        states callback)
    (cl-letf (((symbol-function 'dsh-emacs-subagent--changed)
               (lambda ()
                 (push (plist-get (gethash "child" dsh-emacs--subagent-catalogs)
                                  :state)
                       states)
                 nil))
              ((symbol-function 'dsh-emacs--rpc-async)
               (lambda (_method _args cb) (setq callback cb))))
      (dsh-emacs-subagent-refresh "child")
      (should (equal states '(loading)))
      (dsh-emacs-subagent-apply
       "child" (dsh-protocol-subagent-baseline--from-alist
                '((asOfSeq . 9) (values (subagentCatalog . [])
                                        (tokenUsage (outputTokens . 12))))))
      (should (equal states '(loading loading)))
      ;; The cold response still completes loading when every cell is older.
      (funcall callback t '((asOfSeq . 8) (values (subagentCatalog . [])
                                                  (tokenUsage (outputTokens . 999)))))
      (should (equal states '(ready loading loading)))
      (should (= 9 (dsh-protocol-subagent-cell-seq
                    (dsh-emacs-subagent--cell "child" 'tokenUsage))))
      (should (= 12 (dsh-emacs-subagent-token-total
                     (dsh-emacs-subagent--value "child" 'tokenUsage))))
      (should-not (plist-get (gethash "child" dsh-emacs--subagent-catalogs)
                             :request))
      (setq states nil)
      (dsh-emacs-subagent-refresh "child")
      (funcall callback nil "Unavailable")
      (should (equal states '(error loading)))
      (should (equal "Unavailable"
                     (plist-get (gethash "child" dsh-emacs--subagent-catalogs)
                                :error)))
      (setq states nil)
      (dsh-emacs-subagent-refresh "child")
      (funcall callback t '((asOfSeq . 10) (values (subagentCatalog . [])
                                                   (tokenUsage (outputTokens . 24)))))
      (should (equal states '(ready loading)))
      (should (= 24 (dsh-emacs-subagent-token-total
                     (dsh-emacs-subagent--value "child" 'tokenUsage)))))))

(ert-deftest dsh-emacs-test-subagent-migration-hints-never-become-cells ()
  :tags '(dsh-unit)
  (let ((hints '((kind . "migration-required")
                 (values (subagentCatalog . [])
                         (tokenUsage (outputTokens . 999)))))
        (dsh-emacs--subagent-catalogs (make-hash-table :test #'equal))
        callback)
    (should-error (dsh-protocol-subagent-baseline--from-alist hints)
                  :type 'dsh-protocol-migration-required)
    (cl-letf (((symbol-function 'dsh-emacs-subagent--changed) #'ignore)
              ((symbol-function 'dsh-emacs--rpc-async)
               (lambda (_method _args cb) (setq callback cb))))
      (dsh-emacs-subagent-refresh "cold")
      (funcall callback t hints)
      (let ((state (gethash "cold" dsh-emacs--subagent-catalogs)))
        (should (eq (plist-get state :state) 'error))
        (should (string-match-p "requires migration" (plist-get state :error)))
        (should-not (plist-get state :request))
        (should-not (plist-get state :cells)))
      ;; A live baseline received during a cold read retains its exact cut.
      (dsh-emacs-subagent-refresh "cold")
      (dsh-emacs-subagent-apply
       "cold" (dsh-protocol-subagent-baseline--from-alist
               '((kind . "sequenced") (asOfSeq . 8)
                 (values (subagentCatalog . []) (tokenUsage (outputTokens . 12))))))
      (funcall callback t hints)
      (should (= 8 (dsh-protocol-subagent-cell-seq
                    (dsh-emacs-subagent--cell "cold" 'tokenUsage))))
      (should (= 12 (dsh-emacs-subagent-token-total
                     (dsh-emacs-subagent--value "cold" 'tokenUsage))))
      (dsh-emacs-subagent-refresh "cold")
      (funcall callback t '((kind . "sequenced") (asOfSeq . 9)
                           (values (subagentCatalog . []))))
      (should (eq 'ready (plist-get
                         (gethash "cold" dsh-emacs--subagent-catalogs) :state))))
    (cl-letf (((symbol-function 'dsh-emacs--active-session-id)
               (lambda () "legacy"))
              ((symbol-function 'dsh-emacs--rpc-request)
               (lambda (&rest _) (cons t hints))))
      (should-error (dsh-emacs-subagent--read)
                    :type 'dsh-protocol-migration-required)
      (should-not (gethash "legacy" dsh-emacs--subagent-catalogs)))))

(ert-deftest dsh-emacs-test-subagent-subagent-idle-parent-allows-input ()
  :tags '(dsh-unit)
  (let* ((parent (dsh-protocol-session--from-alist
                  '((sessionId . "p") (agentAvailable . t) (running . :json-false))))
         (dsh-emacs--sessions (list parent))
         (dsh-emacs--subagent-host-live t)
         (dsh-emacs--subagent-catalogs (make-hash-table :test #'equal))
         (address (dsh-protocol-subagent-address-create "p" "c" "continuable")))
    (with-temp-buffer
      (dsh-emacs-mode)
      (setq dsh-emacs--buffer-subagent address)
      (dsh-emacs--subagent-input-update)
      (ert-info ((format "%s" "subagent-idle-parent-allows-input"))
        (should (not buffer-read-only)))
      (setf (dsh-protocol-session-agent-available parent) :unavailable)
      (dsh-emacs--subagent-input-update)
      (ert-info ((format "%s" "subagent-offline-parent-locks-input"))
        (should buffer-read-only)
        (should (string-match-p "unavailable" (buffer-string))))
      (ert-info ((format "%s" "subagent-read-only-insertion-boundary"))
        (should (condition-case nil (progn (goto-char dsh-emacs--input-marker) (insert "no") nil)
                  (buffer-read-only t))))
      (let (calls)
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (&rest args) (push args calls))))
          (dolist (fn '(dsh-emacs-select-model dsh-emacs-set-permission
                                               dsh-emacs-answer-question dsh-emacs-attach-clipboard-image))
            (ert-info ((format "%s" (format "subagent-local-refusal-%s" fn)))
              (should (condition-case nil (progn (funcall fn) nil) (user-error t)))))
          (ert-info ((format "%s" "subagent-deferred-refuses-before-rpc"))
            (should (condition-case nil (progn (dsh-emacs--submit-deferred "test" :mode 'queue) nil)
                      (user-error t)))
            (should (null calls)))))
      (setf (dsh-protocol-session-agent-available parent) t)
      (dsh-emacs--subagent-input-update)
      (ert-info ((format "%s" "subagent-reactivation-unlocks-input"))
        (should (not buffer-read-only)))
      (let (method request)
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (m p _callback) (setq method m request p))))
          (dsh-emacs--submit-prompt "follow up" nil 'steer))
        (ert-info ((format "%s" "subagent-submit-routes-to-parent-not-session"))
          (should (equal method "subagents/prompt"))
          (should (equal (cdr (assq 'parentSessionId (cdr (assq 'request request)))) "p"))
          (should (equal (cdr (assq 'delivery (cdr (assq 'request request)))) "steer"))))
      (setq dsh-emacs--subagent-host-live nil)
      (dsh-emacs--subagent-input-update)
      (ert-info ((format "%s" "subagent-disconnected-input-closed"))
        (should buffer-read-only)))))

(ert-deftest dsh-emacs-test-subagent-subagent-older-page-uses-durable-address ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (let ((dsh-emacs--sessions nil))
      (dsh-emacs-mode)
      (setq dsh-emacs--buffer-session "child"
            dsh-emacs--buffer-subagent
            (dsh-protocol-subagent-address-create "direct" "child" "one-shot")
            dsh-emacs--history-earliest-seq 10
            dsh-emacs--history-cursor 40
            dsh-emacs--history-has-more t)
      (let (method request)
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (m p _callback) (setq method m request p))))
          (dsh-emacs-load-older-history))
        (let* ((args (cdr (assq 'request request)))
               (address (cdr (assq 'address args))))
          (ert-info ((format "%s" "subagent-older-page-uses-durable-address"))
            (should (equal method "session/page"))
            (should (equal (cdr (assq 'parentSessionId address)) "direct"))
            (should (equal (cdr (assq 'kind address)) "subagent"))
            (should (= (cdr (assq 'throughSeq args)) 40))
            (should (= (cdr (assq 'beforeSeq args)) 10))))))))

(ert-deftest dsh-emacs-test-subagent-external-has-no-local-conversation ()
  :tags '(dsh-unit)
  (let ((dsh-emacs--subagent-catalogs (make-hash-table :test #'equal))
        (dsh-emacs--subagent-host-live nil)
        (dsh-emacs--chat-buffers (make-hash-table :test #'equal))
        reads)
    (cl-letf (((symbol-function 'dsh-emacs-subagent--changed) #'ignore)
              ((symbol-function 'dsh-emacs--active-session-id) (lambda () "parent"))
              ((symbol-function 'dsh-emacs--rpc-async)
               (lambda (method args _cb) (push (cons method args) reads)))
              ((symbol-function 'dsh-emacs-server-ensure)
               (lambda () (error "External child must not connect")))
              ((symbol-function 'completing-read)
               (lambda (&rest _) "Remote [external]")))
      (dsh-emacs-subagent-apply
       "parent" (dsh-protocol-subagent-baseline--from-alist
                 '((asOfSeq . 1)
                   (values (subagentCatalog .
                            [((id . "external") (mode . "external") (label . "Remote"))
                             ((id . "local") (mode . "continuable") (label . "Local"))])))))
      (pcase-let ((`(,parent . ,entry) (dsh-emacs-subagent--read)))
        (should (equal parent "parent"))
        (should (equal (dsh-protocol-subagent-entry-id entry) "external"))
        (should (equal reads '(("session/projections"
                               (request (sessionId . "local"))))))
        (should-error (dsh-emacs-open-subagent parent entry) :type 'user-error)
        (should-not (gethash "external" dsh-emacs--chat-buffers)))
      (should-error (dsh-emacs-subagent-stop) :type 'user-error)
      (should (cl-every (lambda (call) (equal (car call) "session/projections"))
                        reads)))))

(ert-deftest dsh-emacs-test-subagent-subagent-picker-distinguishes-duplicate-labels ()
  :tags '(dsh-unit)
  (let ((dsh-emacs--subagent-catalogs (make-hash-table :test #'equal))
        (dsh-emacs--sessions nil)
        (dsh-emacs--subagent-host-live nil)
        opened reads)
    (cl-letf (((symbol-function 'dsh-emacs-subagent--changed) #'ignore)
              ((symbol-function 'dsh-emacs--rpc-request)
               (lambda (method args)
                 (push (cons method args) reads)
                 '(t (asOfSeq . 1)
                     (values (subagentCatalog . [((id . "a") (mode . "one-shot") (label . "Same"))
                                                 ((id . "b") (mode . "continuable") (label . "Same"))])))))
              ((symbol-function 'dsh-emacs-subagent-refresh) #'ignore)
              ((symbol-function 'dsh-emacs-open-subagent)
               (lambda (parent entry &optional other-window)
                 (setq opened (list parent (dsh-protocol-subagent-entry-id entry) other-window))))
              ((symbol-function 'completing-read)
               (lambda (_prompt table &rest _args)
                 (let ((candidates (all-completions "" table)))
                   (ert-info ((format "%s" "subagent-picker-distinguishes-duplicate-labels"))
                     (should (equal candidates '("Same [a]" "Same [b]"))))
                   (ert-info ((format "%s" "subagent-picker-annotation-shows-mode-and-activity"))
                     (should (equal (funcall (plist-get completion-extra-properties :annotation-function)
                                             "Same [b]")
                                    "  continuable  unknown")))
                   "Same [b]"))))
      (with-temp-buffer
        (setq-local dsh-emacs--buffer-session "direct-parent")
        (let ((before (buffer-list)))
          (dsh-emacs-list-subagents t)
          (ert-info ((format "%s" "subagent-picker-opens-direct-child-without-browser"))
            (should (equal opened '("direct-parent" "b" t)))
            (should (equal before (buffer-list)))
            (should (= (length reads) 1))
            (should (equal (caar reads) "session/projections"))))
        (dsh-emacs-list-subagents)
        (ert-info ((format "%s" "subagent-picker-reuses-catalog"))
          (should (= (length reads) 1)))
        (setq opened nil)
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (&rest _) (signal 'quit nil))))
          (condition-case nil (dsh-emacs-list-subagents) (quit nil)))
        (ert-info ((format "%s" "subagent-picker-cancel-does-not-navigate"))
          (should (null opened)))
        (setq-local dsh-emacs--buffer-session "b")
        (cl-letf (((symbol-function 'dsh-emacs--rpc-request)
                   (lambda (&rest _)
                     '(t (asOfSeq . 1)
                         (values (subagentCatalog . [((id . "grandchild")
                                                      (mode . "one-shot")
                                                      (label . "Nested"))])))))
                  ((symbol-function 'completing-read)
                   (lambda (_prompt table &rest _args)
                     (ert-info ((format "%s" "subagent-picker-lists-only-current-parents-children"))
                       (should (equal (all-completions "" table) '("Nested [grandchild]"))))
                     "Nested [grandchild]")))
          (dsh-emacs-list-subagents))
        (ert-info ((format "%s" "subagent-picker-nested-child-keeps-direct-parent"))
          (should (equal opened '("b" "grandchild" nil))))))))

(ert-deftest dsh-emacs-test-subagent-subagent-picker-cold-error-is-not-empty-catalog ()
  :tags '(dsh-unit)
  (let ((dsh-emacs--subagent-catalogs (make-hash-table :test #'equal))
        (dsh-emacs--subagent-host-live nil))
    (with-temp-buffer
      (setq-local dsh-emacs--buffer-session "unread")
      (cl-letf (((symbol-function 'dsh-emacs--rpc-request)
                 (lambda (&rest _) '(nil (message . "cold failed")))))
        (ert-info ((format "%s" "subagent-picker-cold-error-is-not-empty-catalog"))
          (should (condition-case err (progn (dsh-emacs-list-subagents) nil)
                    (user-error (string-match-p "cold failed" (error-message-string err)))))))
      (cl-letf (((symbol-function 'dsh-emacs--rpc-request)
                 (lambda (&rest _) '(t (asOfSeq . 1) (values (subagentCatalog . []))))))
        (ert-info ((format "%s" "subagent-picker-empty-catalog-reports-no-children"))
          (should (condition-case err (progn (dsh-emacs-list-subagents) nil)
                    (user-error (string-match-p "No subagents" (error-message-string err))))))))))

;; Reordering workspaces must not diff the entire list or lose xref markers.
(ert-deftest dsh-emacs-test-subagent-session-unknown-catalog-has-no-disclosure ()
  :tags '(dsh-unit)
  (let* ((dsh-emacs--sessions
          (cl-loop for i below 20 collect
                   (dsh-protocol-session--from-alist
                    `((sessionId . ,(format "row-%d" i))
                      (updatedAt . ,i)
                      (projections (values (title . ,(format "会话 %d" i))))))))
         (dsh-emacs--workspaces
          (cl-loop for w below 4 collect
                   (dsh-protocol-workspace--from-alist
                    `((workspaceId . ,(format "workspace-%d" w))
                      (title . ,(format "Workspace %d" w))
                      (sessionIds . ,(vconcat
                                      (cl-loop for i from (* w 5) below (* (1+ w) 5)
                                               collect (format "row-%d" i))))))))
         (dsh-emacs--subagent-catalogs (make-hash-table :test #'equal))
         (dsh-emacs--archived-sessions nil)
         (dsh-emacs--current-session nil)
         (diff (symbol-function 'replace-buffer-contents))
         (largest-diff 0))
    (with-temp-buffer
      (setq-local dsh-emacs-session--workspace-fold-default nil)
      (dsh-emacs-session--render)
      (ert-info ((format "%s" "session-unknown-catalog-has-no-disclosure"))
        (should (not (string-match-p "[▸▾] .*会话" (buffer-string)))))
      (let ((first (copy-marker (dsh-emacs-session--row-pos
                                 'dsh-emacs-row-id "row-3")))
            (last (copy-marker (+ 8 (dsh-emacs-session--row-pos
                                     'dsh-emacs-row-id "row-17")))))
        (setq dsh-emacs--workspaces (reverse dsh-emacs--workspaces))
        (setf (dsh-protocol-session-title-value (nth 9 dsh-emacs--sessions))
              "Changed title")
        (cl-letf (((symbol-function 'replace-buffer-contents)
                   (lambda (&rest args)
                     (setq largest-diff (max largest-diff (- (point-max) (point-min))))
                     (apply diff args))))
          (dsh-emacs-session--render))
        (ert-info ((format "%s" "session-regroup-only-diffs-individual-rows"))
          (should (< largest-diff 150)))
        (ert-info ((format "%s" "session-regroup-preserves-xref-row-identities"))
          (should (equal (get-text-property first 'dsh-emacs-row-id) "row-3"))
          (should (equal (get-text-property last 'dsh-emacs-row-id) "row-17"))
          (should (< last first)))
        (ert-info ((format "%s" "session-regroup-updates-title-and-workspace-order"))
          (should (string-match-p "Changed title" (buffer-string)))
          (should (< (dsh-emacs-session--row-pos
                      'dsh-emacs-workspace-group-id "workspace-3")
                     (dsh-emacs-session--row-pos
                      'dsh-emacs-workspace-group-id "workspace-0"))))
        ;; A new row inserted exactly at a departure marker must move that
        ;; marker along with the original row, even with insertion type nil.
        (push (dsh-protocol-session--from-alist
               '((sessionId . "inserted") (updatedAt . 3.5)
                 (projections (values (title . "Inserted")))))
              dsh-emacs--sessions)
        (push "inserted" (dsh-protocol-workspace-session-ids
                          (car (last dsh-emacs--workspaces))))
        (dsh-emacs-session--render)
        (ert-info ((format "%s" "session-insert-before-departure-keeps-original-row"))
          (should (equal (get-text-property first 'dsh-emacs-row-id) "row-3")))
        (let ((transpose (symbol-function 'transpose-regions))
              (moves 0))
          (goto-char (dsh-emacs-session--row-pos
                      'dsh-emacs-workspace-group-id "workspace-3"))
          (cl-letf (((symbol-function 'transpose-regions)
                     (lambda (&rest args)
                       (cl-incf moves)
                       (apply transpose args))))
            (dsh-emacs-session-toggle-workspace))
          (ert-info ((format "%s" "session-collapse-deletes-hidden-rows-without-moving-survivors"))
            (should (= moves 0))
            (should (null (dsh-emacs-session--row-pos
                           'dsh-emacs-row-id "row-17")))
            (should (equal (get-text-property first 'dsh-emacs-row-id) "row-3"))
            (should (equal (get-text-property (point) 'dsh-emacs-workspace-group-id)
                           "workspace-3")))
          (dsh-emacs-session-toggle-workspace)
          (ert-info ((format "%s" "session-expand-restores-hidden-rows-with-survivor-markers"))
            (should (dsh-emacs-session--row-pos 'dsh-emacs-row-id "row-17"))
            (should (equal (get-text-property first 'dsh-emacs-row-id) "row-3"))))
        (set-marker first nil)
        (set-marker last nil))
      (let ((cell (dsh-protocol-subagent-cell--from-alist
                   '((key . subagentCatalog) (seq . 1)
                     (value . [((id . "child") (label . "Child")
                                (mode . "one-shot"))])))))
        (puthash "row-0" (list :cells (list (cons 'subagentCatalog cell)))
                 dsh-emacs--subagent-catalogs)
        (dsh-emacs-session--render)
        (goto-char (dsh-emacs-session--row-pos 'dsh-emacs-row-id "row-0"))
        (ert-info ((format "%s" "session-known-children-show-disclosure"))
          (should (string-match-p "▸" (buffer-substring (point) (line-end-position)))))
        (setq dsh-emacs-session--expanded-subagents '("row-0"))
        (setf (dsh-protocol-subagent-cell-value cell) nil)
        (dsh-emacs-session--render)
        (ert-info ((format "%s" "session-empty-catalog-has-no-disclosure-even-if-expanded"))
          (should (not (string-match-p "[▸▾]" (buffer-substring
                                               (point) (line-end-position)))))
          (should (not (string-match-p "No subagents" (buffer-string))))
          (should (null (dsh-emacs-session--row-pos
                         'dsh-emacs-row-id "child"))))))))

;; Inline child rows use the same catalog and direct-parent navigation as chats.
(ert-deftest dsh-emacs-test-subagent-session-children-start-collapsed ()
  :tags '(dsh-unit)
  (let* ((dsh-emacs-sessions-buffer (generate-new-buffer-name " *dsh-child-list*"))
         (buffer (get-buffer-create dsh-emacs-sessions-buffer))
         (dsh-emacs--subagent-catalogs (make-hash-table :test #'equal))
         (dsh-emacs--chat-buffers (make-hash-table :test #'equal))
         (dsh-emacs--subagent-host-live nil)
         (dsh-emacs--current-session nil)
         (dsh-emacs--archived-sessions nil)
         (dsh-emacs-workspaces-collapsed-by-default nil)
         (dsh-emacs--sessions
          (dsh-emacs-test--session-items
           '(((sessionId . "root") (projections (values (title . "Parent"))))
             ((sessionId . "branch") (origin . "subagent")
              (parentSessionId . "root") (running . t)))))
         (dsh-emacs--workspaces
          (list (dsh-protocol-workspace--from-alist
                 '((workspaceId . "ws") (title . "Workspace")
                   (sessionIds . ["root" "branch"])))))
         (root-value
          '((asOfSeq . 1)
            (values (subagentCatalog . [((id . "leaf") (label . "Read only")
                                         (mode . "one-shot"))
                                        ((id . "branch") (label . "Worker")
                                         (mode . "continuable"))]))))
         requests callback opened)
    (unwind-protect
        (with-current-buffer buffer
          (cl-letf (((symbol-function 'dsh-emacs-events-host-connect) #'ignore)
                    ((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method args cb)
                       (push (cons method args) requests)
                       (setq callback cb))))
            (dsh-emacs-session-mode)
            (ert-info ((format "%s" "session-children-start-collapsed"))
              (should (null (dsh-emacs-session--row-pos
                             'dsh-emacs-session-id "branch"))))
            (goto-char (dsh-emacs-session--row-pos 'dsh-emacs-session-id "root"))
            (call-interactively (key-binding (kbd "TAB")))
            (ert-info ((format "%s" "session-unknown-catalog-tab-does-not-expand-or-fetch"))
              (should (null dsh-emacs-session--expanded-subagents))
              (should (null requests))
              (should (not (string-match-p "Loading subagents" (buffer-string))))
              (should (equal (dsh-emacs-session-id-at-point) "root")))
            (dsh-emacs-subagent-refresh "root")
            (funcall callback t root-value)
            (ert-info ((format "%s" "session-catalog-arrival-does-not-auto-expand"))
              (should (null dsh-emacs-session--expanded-subagents))
              (should (equal (dsh-emacs-session-id-at-point) "root"))
              (should (equal (car requests)
                             '("session/projections"
                               (request (sessionId . "root"))))))
            (call-interactively (key-binding (kbd "TAB")))
            (ert-info ((format "%s" "session-children-callback-renders-without-refetch"))
              (should (= (length requests) 1))
              (should (string-match-p "one-shot · unknown" (buffer-string)))
              (should (string-match-p "continuable · running" (buffer-string)))
              (should (equal (dsh-emacs-session-id-at-point) "root")))
            (goto-char (dsh-emacs-session--row-pos 'dsh-emacs-session-id "branch"))
            (ert-info ((format "%s" "session-child-inherits-workspace"))
              (should (equal (dsh-emacs-workspace-id-at-point) "ws"))
              (should (equal (car (get-text-property
                                   (point) 'dsh-emacs-subagent)) "root")))
            (dsh-emacs-subagent-refresh "branch")
            (funcall callback t
                     '((asOfSeq . 2)
                       (values (subagentCatalog . [((id . "grandchild")
                                                    (label . "Nested")
                                                    (mode . "one-shot"))]))))
            (call-interactively (key-binding (kbd "TAB")))
            (goto-char (dsh-emacs-session--row-pos
                        'dsh-emacs-session-id "grandchild"))
            (cl-letf (((symbol-function 'dsh-emacs-open-subagent)
                       (lambda (parent entry &optional _other-window)
                         (setq opened
                               (list parent (dsh-protocol-subagent-entry-id entry)))))
                      ((symbol-function 'dsh-emacs-open-session)
                       (lambda (&rest _) (error "Ordinary child address"))))
              (call-interactively (key-binding (kbd "RET"))))
            (ert-info ((format "%s" "session-nested-ret-uses-direct-parent"))
              (should (equal opened '("branch" "grandchild"))))
            (cl-letf (((symbol-function 'dsh-emacs-server-ensure)
                       (lambda () (error "Child mutation reached server"))))
              (dolist (command '(dsh-emacs-rename-session-at-point
                                 dsh-emacs-archive-session-at-point
                                 dsh-emacs-fork-session-at-point))
                (ert-info ((format "%s" (format "session-cold-child-refuses-%s" command)))
                  (should (condition-case nil
                              (progn (funcall command) nil)
                            (user-error t))))))
            (dsh-emacs-session--render)
            (ert-info ((format "%s" "session-child-refresh-preserves-focus-and-folds"))
              (should (equal (dsh-emacs-session-id-at-point) "grandchild"))
              (should (member "branch" dsh-emacs-session--expanded-subagents))
              (should (= (length requests) 2)))
            (save-window-excursion
              (switch-to-buffer buffer)
              (delete-other-windows)
              (goto-char (dsh-emacs-session--row-pos
                          'dsh-emacs-session-id "grandchild"))
              (let ((other (split-window-right))
                    (departure (point-marker)))
                (set-window-point other (dsh-emacs-session--row-pos
                                         'dsh-emacs-session-id "leaf"))
                (dsh-emacs-subagent-apply
                 "root"
                 (dsh-protocol-subagent-baseline--from-alist
                  '((asOfSeq . 4)
                    (values
                     (subagentCatalog . [((id . "new") (mode . "one-shot"))
                                         ((id . "leaf") (label . "Read only")
                                          (mode . "one-shot"))
                                         ((id . "branch") (label . "Worker")
                                          (mode . "continuable"))])))))
                (ert-info ((format "%s" "session-live-child-arrival-keeps-each-window-row"))
                  (should (dsh-emacs-session--row-pos
                           'dsh-emacs-session-id "new"))
                  (should (equal (dsh-emacs-session-id-at-point) "grandchild"))
                  (should (equal (get-text-property (window-point other)
                                                    'dsh-emacs-session-id)
                                 "leaf"))
                  (should (= (length requests) 2)))
                (ert-info ((format "%s" "session-child-xref-marker-survives-refresh"))
                  (should (equal (get-text-property departure
                                                    'dsh-emacs-session-id)
                                 "grandchild")))
                (set-marker departure nil)))
            (goto-char (dsh-emacs-session--row-pos 'dsh-emacs-session-id "root"))
            (dsh-emacs-session-toggle)
            (ert-info ((format "%s" "session-parent-collapse-hides-descendants"))
              (should (null (dsh-emacs-session--row-pos
                             'dsh-emacs-session-id "grandchild")))
              (should (equal (dsh-emacs-session-id-at-point) "root")))
            (dsh-emacs-subagent-apply
             "root" (dsh-protocol-subagent-baseline--from-alist root-value))
            (ert-info ((format "%s" "session-live-projections-respect-collapse"))
              (should (null (dsh-emacs-session--row-pos
                             'dsh-emacs-session-id "leaf"))))
            (dsh-emacs-session-toggle)
            (ert-info ((format "%s" "session-expand-restores-nested-folds-without-rpc"))
              (should (dsh-emacs-session--row-pos
                       'dsh-emacs-session-id "grandchild"))
              (should (= (length requests) 2)))
            (setq dsh-emacs-session--expanded-subagents nil
                  dsh-emacs-session--workspace-fold-default t
                  dsh-emacs-session--workspace-fold-overrides nil
                  dsh-emacs-session--auto-jump-session "grandchild")
            (dsh-emacs-session--render)
            (ert-info ((format "%s" "session-child-jump-reveals-workspace-and-ancestors"))
              (should (equal (dsh-emacs-session-id-at-point) "grandchild"))
              (should (null dsh-emacs-session--auto-jump-session)))
            (goto-char (dsh-emacs-session--row-pos 'dsh-emacs-session-id "leaf"))
            (dolist (state '(nil (:state loading) (:state error)
                                 (:state ready)))
              (puthash "leaf" state dsh-emacs--subagent-catalogs)
              (when (eq (plist-get state :state) 'ready)
                (dsh-emacs-subagent-apply
                 "leaf" (dsh-protocol-subagent-baseline--from-alist
                         '((asOfSeq . 3) (values (subagentCatalog . []))))))
              (let ((before (buffer-string)))
                (call-interactively (key-binding (kbd "TAB")))
                (ert-info ((format "%s" "session-leaf-tab-preserves-list-without-rpc"))
                  (should (equal before (buffer-string)))
                  (should (not (member "leaf" dsh-emacs-session--expanded-subagents)))
                  (should (equal (dsh-emacs-session-id-at-point) "leaf"))
                  (should (= (length requests) 2)))))))
      (kill-buffer buffer))))

(ert-deftest dsh-emacs-test-subagent-session-child-open-fetches-missing-ancestor-catalog ()
  :tags '(dsh-unit)
  (let* ((dsh-emacs-sessions-buffer (generate-new-buffer-name " *dsh-child-reveal*"))
         (buffer (get-buffer-create dsh-emacs-sessions-buffer))
         (dsh-emacs--subagent-catalogs (make-hash-table :test #'equal))
         (dsh-emacs--chat-buffers (make-hash-table :test #'equal))
         (dsh-emacs--current-session "another-chat")
         (dsh-emacs--workspaces nil)
         (dsh-emacs--archived-sessions nil)
         (dsh-emacs--sessions
          (dsh-emacs-test--session-items
           '(((sessionId . "root"))
             ((sessionId . "child") (origin . "subagent")
              (parentSessionId . "root")))))
         request callback)
    (unwind-protect
        (cl-letf (((symbol-function 'dsh-emacs-events-host-connect) #'ignore)
                  ((symbol-function 'pop-to-buffer) #'ignore)
                  ((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (method args cb)
                     (setq request (cons method args) callback cb))))
          (with-temp-buffer
            (setq-local dsh-emacs--buffer-session "child")
            (dsh-emacs-list-sessions-display))
          (with-current-buffer buffer
            (ert-info ((format "%s" "session-child-open-fetches-missing-ancestor-catalog"))
              (should (equal request '("session/projections"
                                       (request (sessionId . "root")))))
              (should (string-match-p "Loading subagents" (buffer-string)))
              (should (equal dsh-emacs-session--auto-jump-session "child")))
            (funcall callback t
                     '((asOfSeq . 1)
                       (values (subagentCatalog . [((id . "child")
                                                    (mode . "one-shot"))]))))
            (ert-info ((format "%s" "session-child-cold-reveal-completes-pending-jump"))
              (should (equal (dsh-emacs-session-id-at-point) "child"))
              (should (null dsh-emacs-session--auto-jump-session)))))
      (kill-buffer buffer))))

(ert-deftest dsh-emacs-test-subagent-subagent-reconnect-pending-case ()
  :tags '(dsh-unit)
  (dolist (event '(status summary removed disconnected))
    (let* ((parent (dsh-protocol-session--from-alist
                    '((sessionId . "parent") (agentAvailable . t))))
           (dsh-emacs--sessions (list parent))
           (dsh-emacs--chat-buffers (make-hash-table :test #'equal))
           (dsh-emacs--subagent-catalogs (make-hash-table :test #'equal))
           (dsh-emacs--subagent-generation 0)
           (dsh-emacs--subagent-host-live nil)
           (dsh-emacs--subagent-summary-request nil)
           callback)
      (with-temp-buffer
        (dsh-emacs-mode)
        (setq dsh-emacs--buffer-session "child"
              dsh-emacs--buffer-subagent
              (dsh-protocol-subagent-address-create
               "parent" "child" "continuable"))
        (puthash "child" (current-buffer) dsh-emacs--chat-buffers)
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (_method _args cb) (setq callback cb)))
                  ((symbol-function 'dsh-emacs-events--host-repaint) #'ignore))
          (dsh-emacs-subagent-host-reset t)
          (ert-info ((format "%s" (format "subagent-reconnect-pending-%s" event)))
            (should buffer-read-only)
            (should (null (dsh-protocol-session-agent-available parent))))
          (pcase event
            ('status (dsh-emacs-events--host-session-status "parent" t))
            ('summary
             (dsh-emacs-events--host-session-added
              '((sessionId . "parent") (agentAvailable . :json-false)
                (running . t))))
            ('removed (dsh-emacs-events--host-session-removed "parent"))
            ('disconnected (dsh-emacs-subagent-host-reset)))
          (funcall callback t
                   '((items . [((sessionId . "parent") (agentAvailable . t)
                                (running . :json-false))]))))
        (pcase event
          ('status
           (ert-info ((format "%s" "subagent-status-race-restores-parent-availability"))
             (should (eq t (dsh-protocol-session-agent-available parent)))
             (should (dsh-protocol-session-running parent))
             (should (not buffer-read-only))))
          ('summary
           (ert-info ((format "%s" "subagent-refresh-preserves-newer-full-summary"))
             (should (eq :unavailable
                         (dsh-protocol-session-agent-available parent)))
             (should (dsh-protocol-session-running parent))
             (should buffer-read-only)))
          ('removed
           (ert-info ((format "%s" "subagent-refresh-does-not-resurrect-removed-parent"))
             (should (null (dsh-emacs--chat-session-item "parent")))
             (should buffer-read-only)))
          ('disconnected
           (ert-info ((format "%s" "subagent-summary-refresh-ignores-old-generation"))
             (should (null (dsh-protocol-session-agent-available parent)))
             (should buffer-read-only))))))))

(ert-deftest dsh-emacs-test-subagent-subagent-summary-refresh-sends-required-request-argument ()
  :tags '(dsh-unit)
  (let ((dsh-emacs--subagent-host-live t)
        (dsh-emacs--subagent-summary-request nil)
        (dsh-emacs--subagent-catalogs (make-hash-table :test #'equal))
        request)
    (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
               (lambda (_method args _callback) (setq request args))))
      (dsh-emacs-subagent--refresh-summaries))
    (ert-info ((format "%s" "subagent-summary-refresh-sends-required-request-argument"))
      (should (assq '_request request)))))

(ert-deftest dsh-emacs-test-subagent-subagent-cold-request-outlives-view ()
  :tags '(dsh-unit)
  (let ((dsh-emacs--subagent-catalogs (make-hash-table :test #'equal))
        (dsh-emacs--subagent-generation 10)
        (dsh-emacs--subagent-host-live t)
        (dsh-emacs--sessions nil)
        owner callback)
    (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
               (lambda (_method _args cb) (setq owner (current-buffer) callback cb)))
              ((symbol-function 'dsh-emacs-subagent--changed) #'ignore))
      (with-temp-buffer (dsh-emacs-subagent-refresh "closed-view"))
      (ert-info ((format "%s" "subagent-cold-request-outlives-view"))
        (should (buffer-live-p owner)))
      (funcall callback t '((asOfSeq . 5) (values (subagentCatalog . []))))
      (ert-info ((format "%s" "subagent-closed-view-request-settles"))
        (should (eq 'ready (plist-get (gethash "closed-view" dsh-emacs--subagent-catalogs) :state))))
      (dsh-emacs-subagent-refresh "stale-generation")
      (dsh-emacs-subagent-host-reset)
      (funcall callback t '((asOfSeq . 100) (values (subagentCatalog . []))))
      (ert-info ((format "%s" "subagent-old-generation-response-ignored"))
        (should (null (dsh-emacs-subagent--cell "stale-generation" 'subagentCatalog)))))))

(ert-deftest dsh-emacs-test-subagent-subagent-duration-adds-settled-and-live-segments ()
  :tags '(dsh-unit)
  (let* ((dsh-emacs--subagent-catalogs (make-hash-table :test #'equal))
         (child (dsh-protocol-session--from-alist '((sessionId . "timed") (running . t))))
         (dsh-emacs--sessions (list child))
         (dsh-emacs--subagent-host-live t))
    (cl-letf (((symbol-function 'dsh-emacs-subagent--changed) #'ignore))
      (dsh-emacs-subagent-apply
       "root" (dsh-protocol-subagent-baseline--from-alist
               '((asOfSeq . 1) (values (subagentCatalog . [((id . "timed"))])))))
      (dsh-emacs-subagent-apply
       "timed" (dsh-protocol-subagent-baseline--from-alist
                '((asOfSeq . 1) (values (subagentCatalog . [])
                                        (subagentTiming (settledMs . 10000)
                                                        (active (since . 20000) (through . 22000))))))))
    (let ((entry (car (dsh-emacs-subagent--value "root" 'subagentCatalog))))
      (cl-letf (((symbol-function 'float-time) (lambda (&optional _time) 27.0)))
        (ert-info ((format "%s" "subagent-duration-adds-settled-and-live-segments"))
          (should (string-match-p "running  17.0s" (dsh-emacs-subagent--annotation "root" entry))))
        (setf (dsh-protocol-session-running child) nil)
        (ert-info ((format "%s" "subagent-idle-duration-stops-at-through"))
          (should (string-match-p "idle  12.0s" (dsh-emacs-subagent--annotation "root" entry))))
        (setf (dsh-protocol-session-running child) t)
        (setq dsh-emacs--subagent-host-live nil)
        (ert-info ((format "%s" "subagent-offline-duration-stops-at-through"))
          (should (string-match-p "12.0s" (dsh-emacs-subagent--annotation "root" entry))))))))

(ert-deftest dsh-emacs-test-subagent-subagent-indicator-keeps-total-and-running-details ()
  :tags '(dsh-unit)
  (let ((dsh-emacs--subagent-catalogs (make-hash-table :test #'equal))
        (dsh-emacs--buffer-session "indicator-parent")
        (dsh-emacs--buffer-subagent nil)
        (dsh-emacs--subagent-host-live nil)
        (dsh-emacs--sessions
         (list (dsh-protocol-session--from-alist '((sessionId . "a") (running . t))))))
    (puthash "indicator-parent"
             (list :cells (list (cons 'subagentCatalog
                                      (dsh-protocol-subagent-cell--from-alist
                                       '((key . "subagentCatalog") (seq . 1)
                                         (value . [((id . "a")) ((id . "b")) ((id . "c"))]))))))
             dsh-emacs--subagent-catalogs)
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) nil))
              ((symbol-function 'char-displayable-p) (lambda (_) nil)))
      (let ((indicator (dsh-emacs-subagent-indicator)))
        (ert-info ((format "%s" "subagent-indicator-keeps-total-and-running-details"))
          (should (equal (substring-no-properties indicator) " Sub 3"))
          (should (equal (get-text-property 1 'help-echo indicator)
                         "3 subagents, 1 running; mouse-1 to choose"))
          (should (eq (get-text-property 1 'face indicator) 'dsh-emacs-modeline-face))
          (should (eq (get-text-property 1 'local-map indicator) dsh-emacs-subagent-map)))))))

;; A live host, an SVG display and a running direct child pulse the child-count
;; icon between the muted and running tints; settling stops it.  `--changed' is
;; the wiring point every summary/projection update uses, so the test drives
;; that instead of the timer helper directly.
(defun dsh-test-subagent-indicator-icon (indicator)
  "Return INDICATOR's icon SVG string, or nil."
  (let ((position 0) icon)
    (while (and (< position (length indicator)) (null icon))
      (let ((display (get-text-property position 'display indicator)))
        (when (stringp display) (setq icon display)))
      (setq position (1+ position)))
    icon))

(defun dsh-test-subagent-indicator-count-tint (indicator)
  "Return INDICATOR's child-count foreground tint, or nil."
  (let ((face (get-text-property (1- (length indicator)) 'face indicator)))
    (and (listp face) (plist-get face :foreground))))

(ert-deftest dsh-emacs-test-subagent-subagent-indicator-pulses-icon-while-child-runs ()
  :tags '(dsh-unit)
  (let ((dsh-emacs--subagent-catalogs (make-hash-table :test #'equal))
        (dsh-emacs-subagent--icon-frames nil)
        (dsh-emacs--buffer-session "anim-parent")
        (dsh-emacs--buffer-subagent nil)
        (dsh-emacs--subagent-host-live t)
        (dsh-emacs-sessions-buffer " *dsh-test-no-sessions*")
        (dsh-emacs--chat-buffers (make-hash-table :test #'equal))
        (dsh-emacs--sessions
         (list (dsh-protocol-session--from-alist '((sessionId . "a") (running . t)))
               (dsh-protocol-session--from-alist '((sessionId . "b") (running . :json-false)))))
        (playing nil)
        (plays 0)
        (stops 0)
        (played-slot nil)
        (renderer nil))
    (puthash "anim-parent"
             (list :cells (list (cons 'subagentCatalog
                                      (dsh-protocol-subagent-cell--from-alist
                                       '((key . "subagentCatalog") (seq . 1)
                                         (value . [((id . "a")) ((id . "b"))]))))))
             dsh-emacs--subagent-catalogs)
    (with-temp-buffer
      (puthash "anim-parent" (current-buffer) dsh-emacs--chat-buffers)
      ;; This test owns the subagent slot only; the whale activity
      ;; integration has its own tests.
      (cl-letf (((symbol-function 'dsh-emacs-modeline-set-subagent-activity)
                 #'ignore)
                ((symbol-function 'dsh-emacs-modeline-animation-available-p)
                 (lambda () t))
                ((symbol-function 'dsh-emacs-modeline-animation-playing-p)
                 (lambda (_slot) playing))
                ((symbol-function 'dsh-emacs-modeline-animation-play)
                 (lambda (slot clip)
                   (cl-incf plays)
                   (setq played-slot slot playing t)
                   (setq renderer (plist-get clip :render))
                   clip))
                ((symbol-function 'dsh-emacs-modeline-animation-clip)
                 (lambda (duration render)
                   (setq renderer render)
                   (list :duration duration :render render)))
                ((symbol-function 'dsh-emacs-modeline-animation-stop)
                 (lambda (_slot) (cl-incf stops) (setq playing nil)))
                ((symbol-function 'display-graphic-p) (lambda (&optional _) t))
                ((symbol-function 'image-type-available-p) (lambda (_type) t))
                ((symbol-function 'create-image)
                 (lambda (data &rest _) data))
                ((symbol-function 'color-values)
                 (lambda (color &optional _frame)
                   (pcase color
                     ("red" '(65535 0 0))
                     ("blue" '(0 0 65535))
                     (_ '(65535 65535 65535)))))
                ((symbol-function 'color-name-to-rgb)
                 (lambda (color &optional _frame)
                   (let ((hex (substring color 1)))
                     (cl-loop for index below 3
                              for width = (/ (length hex) 3)
                              collect
                              (/ (string-to-number
                                  (substring hex (* index width)
                                             (* (1+ index) width))
                                  16)
                                 255.0)))))
                ((symbol-function 'face-foreground)
                 (lambda (face &optional _frame _inherit)
                   (pcase face
                     ('dsh-emacs-status-running-face "blue")
                     (_ "red")))))
        (dsh-emacs-subagent--changed)
        (ert-info ((format "%s" "subagent-icon-pulse-plays-motion-line-clip"))
          (should (= plays 1))
          (should (= stops 0))
          (should (eq played-slot dsh-emacs-subagent--animation-slot))
          (should (eq played-slot 'dsh-subagents))
          (should playing)
          (should (equal (substring-no-properties (dsh-emacs-subagent-indicator))
                         "   2")))
        (ert-info ((format "%s" "subagent-icon-clip-renders-the-pulse"))
          (should (string-match-p "stroke=\"#ff0000\""
                                  (dsh-test-subagent-indicator-icon
                                   (funcall renderer 0.0))))
          (should (string-match-p "stroke=\"#0000ff\""
                                  (dsh-test-subagent-indicator-icon
                                   (funcall renderer 0.6)))))
        (ert-info ((format "%s" "subagent-count-tints-with-the-icon"))
          (should (equal (dsh-test-subagent-indicator-count-tint
                          (funcall renderer 0.0))
                         "#ff0000"))
          (should (equal (dsh-test-subagent-indicator-count-tint
                          (funcall renderer 0.3))
                         (dsh-emacs-subagent--pulse-tint "#ff0000" "#0000ff" 0.25)))
          (should (equal (dsh-test-subagent-indicator-count-tint
                          (funcall renderer 0.6))
                         "#0000ff")))
        ;; A second update while the child still runs must not restart the
        ;; clip (that would pin the pulse at its first frame).
        (dsh-emacs-subagent--changed)
        (ert-info ((format "%s" "subagent-icon-pulse-keeps-its-phase"))
          (should (= plays 1)))
        ;; The running child settles: the next change stops the slot and the
        ;; static indicator shows the idle tint again.
        (setf (dsh-protocol-session-running (car dsh-emacs--sessions)) nil)
        (dsh-emacs-subagent--changed)
        (ert-info ((format "%s" "subagent-icon-pulse-stops-when-children-settle"))
          (should (= stops 1))
          (should-not playing)
          (should (equal (substring-no-properties (dsh-emacs-subagent-indicator))
                         "   2"))
          (should (string-match-p "stroke=\"#ff0000\""
                                  (dsh-test-subagent-indicator-icon
                                   (dsh-emacs-subagent-indicator)))))))))

;; Every child-state change feeds the whale's activity state, and the last
;; child settling clears it.
(ert-deftest dsh-emacs-test-subagent-running-child-drives-modeline-activity ()
  :tags '(dsh-unit)
  (let ((dsh-emacs--subagent-catalogs (make-hash-table :test #'equal))
        (dsh-emacs--buffer-session "activity-parent")
        (dsh-emacs--buffer-subagent nil)
        (dsh-emacs--subagent-host-live t)
        (dsh-emacs-sessions-buffer " *dsh-test-no-sessions*")
        (dsh-emacs--chat-buffers (make-hash-table :test #'equal))
        (dsh-emacs--sessions
         (list (dsh-protocol-session--from-alist
                '((sessionId . "activity-child") (running . t)))))
        (activity 'unset))
    (puthash "activity-parent"
             (list :cells
                   (list (cons 'subagentCatalog
                               (dsh-protocol-subagent-cell--from-alist
                                '((key . "subagentCatalog") (seq . 1)
                                  (value . [((id . "activity-child"))]))))))
             dsh-emacs--subagent-catalogs)
    (with-temp-buffer
      (setq-local dsh-emacs--buffer-session "activity-parent"
                  dsh-emacs--buffer-subagent nil
                  dsh-emacs--event-ready t)
      (puthash "activity-parent" (current-buffer) dsh-emacs--chat-buffers)
      (cl-letf (((symbol-function 'dsh-emacs-modeline-animation-available-p)
                 #'ignore)
                ((symbol-function 'dsh-emacs-modeline-set-subagent-activity)
                 (lambda (active) (setq activity active))))
        (dsh-emacs-subagent--changed)
        (ert-info ((format "%s" "running-child-sets-modeline-activity"))
          (should (eq activity t)))
        (setf (dsh-protocol-session-running (car dsh-emacs--sessions)) nil)
        (setq activity 'unset)
        (dsh-emacs-subagent--changed)
        (ert-info ((format "%s" "settled-child-clears-modeline-activity"))
          (should-not activity))))))

(ert-deftest dsh-emacs-test-subagent-whale-activity-follows-chat-lifecycle ()
  :tags '(dsh-unit)
  (let* ((dsh-emacs--subagent-catalogs (make-hash-table :test #'equal))
         (dsh-emacs--chat-buffers (make-hash-table :test #'equal))
         (dsh-emacs--subagent-host-live t)
         (dsh-emacs-sessions-buffer " *dsh-test-no-sessions*")
         (dsh-emacs--sessions
          (list (dsh-protocol-session--from-alist
                 '((sessionId . "cached-child") (running . t)))))
         (cells (list (dsh-protocol-subagent-cell--from-alist
                       '((key . "subagentCatalog") (seq . 1)
                         (value . [((id . "cached-child"))])))))
         (snapshot (dsh-protocol--make-follow-projections :subagents cells)))
    ;; Host control already cached these cells before the chat was opened.
    (dsh-emacs-subagent-apply "cached-parent" cells)
    (with-temp-buffer
      (dsh-emacs-mode)
      (setq-local dsh-emacs--buffer-session "cached-parent"
                  dsh-emacs--event-ready t)
      (puthash "cached-parent" (current-buffer) dsh-emacs--chat-buffers)
      (dsh-emacs-modeline-setup)
      (cl-letf (((symbol-function 'float-time) (lambda (&optional _) 100.0)))
        (dsh-emacs-events--apply-snapshot-projections "cached-parent" snapshot))
      (should (= (dsh-emacs-subagent--running-count) 1))
      (should dsh-emacs--modeline-subagent-active)
      (should (= dsh-emacs--modeline-run-start 100.0))
      (should-not dsh-emacs--ml-busy)
      (dsh-emacs-events-disconnect)
      ;; Host updates cannot restart the whale in a detached chat.
      (dsh-emacs-subagent--changed)
      (should-not dsh-emacs--modeline-subagent-active)
      (should-not dsh-emacs--modeline-run-start)
      ;; Reconnecting with the same cells starts a fresh observation interval.
      (setq dsh-emacs--event-ready t)
      (cl-letf (((symbol-function 'float-time) (lambda (&optional _) 200.0)))
        (dsh-emacs-events--apply-snapshot-projections "cached-parent" snapshot))
      (should dsh-emacs--modeline-subagent-active)
      (should (= dsh-emacs--modeline-run-start 200.0))
      (let ((process (make-pipe-process :name "dsh-test-child-activity")))
        (unwind-protect
            (progn
              (setq dsh-emacs--event-process process)
              (process-put process 'dsh-emacs-chat-buffer (current-buffer))
              (cl-letf (((symbol-function 'dsh-emacs-events--schedule-reconnect)
                         #'ignore))
                (dsh-emacs-events--lost process))
              (should-not dsh-emacs--modeline-subagent-active)
              (should-not dsh-emacs--modeline-run-start)
              (dsh-emacs-subagent--changed)
              (should (equal (dsh-emacs--ml-busy-indicator) "")))
          (delete-process process))))))

(provide 'dsh-test-subagent)
;;; dsh-test-subagent.el ends here
