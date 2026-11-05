;;; dsh-test-plan.el --- Plan tests -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "28.1"))

(require 'dsh-test-support)

;; Plan is a persistent projection, never inferred from commands or old events.
(ert-deftest dsh-emacs-test-plan-plan-decodes-string-keys-and-json-false ()
  :tags '(dsh-unit)
  (let ((plan (dsh-protocol-plan--from-alist
               '(("active" . :json-false) ("pending" . t)))))
    (ert-info ((format "%s" "plan-decodes-string-keys-and-json-false"))
      (should (not (dsh-protocol-plan-active plan)))
      (should (dsh-protocol-plan-pending plan))
      (should (not (dsh-protocol-plan-available (dsh-protocol-plan--from-alist nil)))))))

(ert-deftest dsh-emacs-test-plan-plan-live ()
  :tags '(dsh-unit)
  (let ((first (generate-new-buffer " *plan-main*"))
        (second (generate-new-buffer " *plan-other*"))
        (dsh-emacs--chat-buffers (make-hash-table :test 'equal)))
    (unwind-protect
        (progn
          (puthash "plan-main" first dsh-emacs--chat-buffers)
          (puthash "plan-other" second dsh-emacs--chat-buffers)
          (with-current-buffer first
            (dsh-emacs-mode)
            (setq-local dsh-emacs--buffer-session "plan-main")
            (setq dsh-emacs--todo-list '(("Keep working" . "in_progress"))))
          (with-current-buffer second (dsh-emacs-mode))
          (dolist (case '(("inactive" :json-false :json-false "")
                          ("entering" :json-false t "Plan → on")
                          ("entry-cancelled" :json-false :json-false "")
                          ("active" t :json-false "Plan")
                          ("leaving" t t "Plan → off")
                          ("exit-failed" t :json-false "Plan")
                          ("left" :json-false :json-false "")))
            (pcase-let ((`(,name ,active ,pending ,label) case))
              (with-current-buffer second
                (dsh-emacs-events--host-item
                 nil `((type . "projection") (sessionId . "plan-main")
                       (changes . [((key . "plan")
                                    (val . ((active . ,active) (pending . ,pending))))]))))
              (with-current-buffer first
                (ert-info ((format "%s" (concat "plan-live-" name)))
                  (should (equal (string-trim (dsh-emacs-modeline--ml-indicator)) label))
                  (should (equal dsh-emacs--todo-list '(("Keep working" . "in_progress")))))
                (when (eq pending t)
                  (ert-info ((format "%s" (concat "plan-detail-" name)))
                    (should (string-match-p
                             (if (eq active t) "Pending: leave" "Pending: enter")
                             (dsh-emacs-modeline--status-detail))))))))
          (with-current-buffer second
            (dsh-emacs-events--host-item
             nil '((type . "projection") (sessionId . "unopened")
                   (changes . [((key . "plan")
                                (val . ((active . t) (pending . t))))])))
            (ert-info ((format "%s" "plan-foreign-projections-do-not-change-current-chat"))
              (should (null dsh-emacs--modeline-plan))))
          ;; Real JSON exercises symbol session keys and false booleans in baselines.
          (dsh-emacs-events--host-item
           nil (json-read-from-string
                "{\"type\":\"baseline\",\"value\":{\"projections\":{\"plan-main\":{\"asOfSeq\":4,\"values\":{\"plan\":{\"active\":true,\"pending\":false}}}}}}"))
          (with-current-buffer first
            (ert-info ((format "%s" "plan-control-baseline-restores-active"))
              (should (equal (string-trim (dsh-emacs-modeline--ml-indicator)) "Plan")))
            (dsh-emacs-render-event
             (dsh-test--execution-event "turn/end" 4 '((turn . 1))))
            (dsh-emacs--ml-busy-clear)
            (ert-info ((format "%s" "plan-persists-after-turn-and-transport-teardown"))
              (should (equal (string-trim (dsh-emacs-modeline--ml-indicator)) "Plan")))
            ;; Plan is projection-owned, so a `plan/mode' record has no event
            ;; path into the badge; this is a tripwire for a future event-based
            ;; implementation, not the guard that keeps history from rewinding.
            (let ((dsh-emacs--history-page t))
              (dsh-emacs-render-history-events
               (list `((type . "event")
                       (event . ,(dsh-test--execution-event
                                  "plan/mode" 1 '((active . :json-false))))))
               nil 4 :follow-p nil))
            (ert-info ((format "%s" "plan-history-does-not-rewind-projection"))
              (should (equal (string-trim (dsh-emacs-modeline--ml-indicator)) "Plan")))
            (dsh-emacs-events--follow-snapshot
             first '((cursor . 5) (records . [])
                     (projections . ((asOfSeq . 5)
                                     (values . ((plan . ((active . t)
                                                         (pending . t)))))))))
            (ert-info ((format "%s" "plan-follow-snapshot-restores-pending-without-events"))
              (should (equal (string-trim (dsh-emacs-modeline--ml-indicator)) "Plan → off")))
            (save-window-excursion
              (dsh-emacs-describe-status)
              (with-current-buffer "*dsh status*"
                (ert-info ((format "%s" "plan-keyboard-details-include-current-and-target"))
                  (should (string-match-p "Plan mode: active" (buffer-string)))
                  (should (string-match-p "Pending: leave" (buffer-string))))))
            (let ((render (symbol-function 'dsh-emacs-render-history-events)))
              (cl-letf (((symbol-function 'dsh-emacs-render-history-events)
                         (lambda (&rest args)
                           (apply render args)
                           (dsh-emacs-events--host-apply-projection
                            nil '((sessionId . "plan-main") (key . "plan")
                                  (value . ((active . t)
                                            (pending . :json-false))))))))
                (dsh-emacs-events--follow-snapshot
                 first `((cursor . 6)
                         (records . [((type . "event")
                                      (event . ,(dsh-test--execution-event
                                                 "plan/mode" 6
                                                 '((active . :json-false)))))])
                         (projections . ((asOfSeq . 6)
                                         (values . ((plan . ((active . :json-false)
                                                             (pending . t)))))))))))
            (ert-info ((format "%s" "plan-live-increment-during-history-wins"))
              (should (equal (string-trim (dsh-emacs-modeline--ml-indicator)) "Plan")))
            (dsh-emacs-events--follow-snapshot
             first '((cursor . 7) (records . []) (projections . ((values)))))
            (ert-info ((format "%s" "plan-absent-from-follow-clears-capability"))
              (should (null dsh-emacs--modeline-plan))
              (should (string-empty-p (dsh-emacs-modeline--ml-indicator)))))
          (dsh-emacs-events--host-apply-projection
           nil '((sessionId . "plan-main") (key . "plan")
                 (value . ((active . t) (pending . nil)))))
          (dsh-emacs-events--host-control-baseline
           nil '((projections . ((plan-main . ((asOfSeq . 8) (values)))))))
          (with-current-buffer first
            (ert-info ((format "%s" "plan-absent-from-control-clears-capability"))
              (should (null dsh-emacs--modeline-plan)))
            (dsh-emacs-events--host-item
             nil '((type . "projection") (sessionId . "plan-main")
                   (seq . 12)
                   (changes . [((key . "plan")
                                (val . ((active . t) (pending . :json-false))))])))
            (dsh-emacs-events--follow-snapshot
             first '((cursor . 11) (records . [])
                     (projections . ((asOfSeq . 11)
                                     (values . ((plan . ((active . :json-false)
                                                         (pending . :json-false)))))))))
            (ert-info ((format "%s" "plan-older-follow-cannot-overwrite-newer-control"))
              (should (equal (string-trim (dsh-emacs-modeline--ml-indicator)) "Plan")))
            (dsh-emacs-events--host-item
             nil '((type . "projection") (sessionId . "plan-main")
                   (seq . 10)
                   (changes . [((key . "plan")
                                (val . ((active . :json-false) (pending . :json-false))))])))
            (dsh-emacs-events--host-control-baseline
             nil '((projections . ((plan-main . ((asOfSeq . 11) (values)))))))
            (ert-info ((format "%s" "plan-older-increment-and-absent-baseline-are-ignored"))
              (should (equal (string-trim (dsh-emacs-modeline--ml-indicator)) "Plan")))
            (dsh-emacs-events--follow-snapshot
             first '((cursor . 13) (records . [])
                     (projections . ((asOfSeq . 13) (values)))))
            (dsh-emacs-events--host-item
             nil '((type . "projection") (sessionId . "plan-main")
                   (seq . 12)
                   (changes . [((key . "plan")
                                (val . ((active . t) (pending . :json-false))))])))
            (ert-info ((format "%s" "plan-absence-keeps-watermark-against-late-increment"))
              (should (null dsh-emacs--modeline-plan)))
            (let ((process (dsh-test--event-process :name "plan-new-host" :noquery t)))
              (unwind-protect
                  (cl-letf (((symbol-function 'process-send-string) #'ignore))
                    (dsh-emacs-events--host-open process))
                (delete-process process)))
            (dsh-emacs-events--host-control-baseline
             nil '((projections
                    . ((plan-main . ((asOfSeq . 1)
                                     (values . ((plan . ((active . t)
                                                         (pending . :json-false)))))))))))
            (ert-info ((format "%s" "plan-new-host-generation-can-start-at-lower-sequence"))
              (should (equal (string-trim (dsh-emacs-modeline--ml-indicator)) "Plan")))))
      (kill-buffer first)
      (kill-buffer second))))

;; A plan review carries presentation intent separately from its question text.
(ert-deftest dsh-emacs-test-plan-plan-review-preserves-presentation-intent ()
  :tags '(dsh-unit)
  (let ((question (dsh-protocol-question--from-alist
                   '((id . "review") (detail . "# Search plan\n\nThree steps.")
                     (intent . ((kind . "plan-review") (approve . "Execute")
                                (callId . "plan-call")))))))
    (ert-info ((format "%s" "plan-review-preserves-presentation-intent"))
      (should (and (fboundp 'dsh-protocol-question-intent-kind)
                   (equal (dsh-protocol-question-intent-kind question) "plan-review")
                   (equal (dsh-protocol-question-approve-label question) "Execute")
                   (equal (dsh-protocol-question-call-id question) "plan-call"))))))

(defun dsh-test--plan-question (&optional call-id)
  "Return a wire-shaped plan review fixture with CALL-ID."
  (copy-tree
   `((id . "review") (question . "Approve?")
     (detail . "# Search plan\n\n1. Index sessions.\n2. Verify results.")
     (options . [((label . "Execute")) ((label . "Keep planning"))])
     (intent . ((kind . "plan-review") (approve . "Execute")
                (callId . ,(or call-id "plan-call")))))
   t))

;; Review does not enter a minibuffer; reading and closing a document never
;; answers it.  Exercise the real result serializer at the RPC seam.
(ert-deftest dsh-emacs-test-plan-plan-review-opens-full-document-without-answering ()
  :tags '(dsh-unit)
  (let ((chat (generate-new-buffer " *plan-review-test*"))
        (dsh-emacs-events--client-id "plan-client")
        (dsh-emacs-enable-notifications nil)
        documents sent callback)
    (unwind-protect
        (cl-letf (((symbol-function 'display-buffer)
                   (lambda (buffer &rest _)
                     (cl-pushnew buffer documents) nil))
                  ((symbol-function 'completing-read-multiple)
                   (lambda (&rest _) (error "Plan entered the question reader")))
                  ((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (method args cb)
                     (push (cons method args) sent)
                     (setq callback cb))))
          (with-current-buffer chat
            (insert "draft feedback")
            (dsh-emacs--question-requested
             chat "plan-event" "plan-session" (list (dsh-test--plan-question)))
            (let* ((review (car dsh-emacs-plan--pending))
                   (document (plist-get review :buffer)))
              (ert-info ((format "%s" "plan-review-opens-full-document-without-answering"))
                (should (buffer-live-p document))
                (should (null sent))
                (should (with-current-buffer document
                          (and buffer-read-only
                               (string-match-p "Index sessions" (buffer-string))
                               (string-match-p "Approve and execute" (buffer-string))))))
              (dsh-emacs--question-requested
               chat "plan-event" "plan-session" (list (dsh-test--plan-question)))
              (ert-info ((format "%s" "plan-review-replay-does-not-duplicate"))
                (should (= (length dsh-emacs-plan--pending) 1))
                (should (= (length documents) 1)))
              (kill-buffer document)
              (ert-info ((format "%s" "plan-killing-document-keeps-review-pending"))
                (should (null sent))
                (should (memq review dsh-emacs-plan--pending)))
              (setq document
                    (dsh-emacs-plan--show chat "plan-call"
                                          (dsh-protocol-question-detail
                                           (plist-get review :question))))
              (with-current-buffer document
                (ert-info ((format "%s" "plan-reopened-document-restores-actions"))
                  (should (eq review dsh-emacs-plan--review)))
                (dsh-emacs-plan-approve)
                (ert-info ((format "%s" "plan-approval-sends-exact-host-label-and-request"))
                  (should (equal (car sent)
                                 '("$events/result" (clientId . "plan-client")
                                   (eventId . "plan-event")
                                   (outcome . ((kind . "result")
                                               (value . ((answers .
                                                                  [((id . "review")
                                                                    (selected . ["Execute"]))]))))))))
                  (should (not (string-match-p "Approve and execute" (buffer-string)))))
                (ert-info ((format "%s" "plan-double-submit-is-blocked"))
                  (should (condition-case nil (progn (dsh-emacs-plan-approve) nil)
                            (user-error t)))
                  (should (= (length sent) 1)))
                (funcall callback nil "offline")
                (ert-info ((format "%s" "plan-failed-response-retains-retry-and-error"))
                  (should (not (plist-get review :retired)))
                  (should (string-match-p "Decision failed: offline" (buffer-string)))
                  (should (string-match-p "Approve and execute" (buffer-string))))
                (dsh-emacs-plan-approve)
                ;; The host retires its waterfall before the HTTP callback.
                (dsh-emacs--question-cancelled "plan-event")
                (funcall callback t '((ok . t)))
                (ert-info ((format "%s" "plan-accepted-response-retires-review"))
                  (should (null (buffer-local-value 'dsh-emacs-plan--pending chat)))
                  (should (string-match-p "Approved" (buffer-string)))
                  (should (condition-case nil (progn (dsh-emacs-plan-approve) nil)
                            (user-error t)))))
              (ert-info ((format "%s" "plan-read-and-approve-preserve-chat-draft"))
                (should (equal (buffer-string) "draft feedback"))))
            (setq sent nil)
            (dsh-emacs--question-requested
             chat "plan-changes" "plan-session"
             (list (dsh-test--plan-question "plan-two")))
            (let* ((review (car dsh-emacs-plan--pending))
                   (document (plist-get review :buffer)) returned)
              (with-current-buffer document (dsh-emacs-plan-request-changes))
              (ert-info ((format "%s" "plan-request-changes-cancels-instead-of-replanning"))
                        (should (equal sent
                                       '(("$events/result"
                                          (clientId . "plan-client")
                                          (eventId . "plan-changes")
                                          (outcome . ((kind . "rejected")
                                                      (error . ((name . "cancelled")
                                                                (message . "User requested plan changes"))))))))))
              (cl-letf (((symbol-function 'pop-to-buffer)
                         (lambda (buffer &rest _) (setq returned buffer))))
                (funcall callback t nil))
              (ert-info ((format "%s" "plan-request-changes-returns-to-own-chat"))
                (should (eq returned chat))
                (should (null dsh-emacs-plan--pending))
                (should (equal (buffer-string) "draft feedback"))))
            (dsh-emacs--question-requested
             chat "plan-expired" "plan-session"
             (list (dsh-test--plan-question "plan-three")))
            (let* ((review (car dsh-emacs-plan--pending))
                   (document (plist-get review :buffer)))
              (with-current-buffer document (dsh-emacs-plan-approve))
              (dsh-emacs--waterfall-generation-retired)
              (funcall callback t nil)
              (ert-info ((format "%s" "plan-disconnect-rejects-late-callback"))
                (should (null dsh-emacs-plan--pending))
                (should (with-current-buffer document
                          (and (string-match-p "review expired" (buffer-string))
                               (condition-case nil (progn (dsh-emacs-plan-approve) nil)
                                 (user-error t)))))))))
      (with-current-buffer chat (dsh-emacs-plan--cancel))
      (kill-buffer chat)
      (dolist (buffer documents)
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

;; Closing the plan document must not take the decision's completion with it:
;; the review belongs to the chat, so the result request (and its callback)
;; must be owned by the live chat buffer, not by the closable document.
(ert-deftest dsh-emacs-test-plan-plan-document-close-keeps-failure-callback-ownership ()
  :tags '(dsh-unit)
  (let ((chat (generate-new-buffer " *plan-owner-chat*"))
        (dsh-emacs-events--client-id "owner-client")
        (dsh-emacs-enable-notifications nil)
        documents sent request-buffer callback)
    (unwind-protect
        (cl-letf (((symbol-function 'display-buffer)
                   (lambda (buffer &rest _) (cl-pushnew buffer documents) nil))
                  ((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (method args cb)
                     (push (cons method args) sent)
                     (setq request-buffer (current-buffer)
                           callback cb))))
          (with-current-buffer chat
            (dsh-emacs--question-requested
             chat "owner-event" "owner-session" (list (dsh-test--plan-question)))
            (let ((review (car dsh-emacs-plan--pending)))
              (with-current-buffer (plist-get review :buffer)
                (dsh-emacs-plan-approve))
              (ert-info ((format "%s" "plan-decision-request-belongs-to-chat"))
                (should (eq request-buffer chat))
                (should (= (length sent) 1)))
              (kill-buffer (plist-get review :buffer))
              ;; Mirror `dsh-emacs--http-post': a response only reaches the
              ;; buffer that made the request while that buffer is live.
              (when (buffer-live-p request-buffer)
                (with-current-buffer request-buffer
                  (funcall callback nil "offline")))
              (ert-info ((format "%s" "plan-document-close-keeps-failure-callback-ownership"))
                (should (null (plist-get review :busy)))
                (should (not (plist-get review :retired)))
                (should (memq review dsh-emacs-plan--pending))
                (should (equal (plist-get review :status)
                               "Decision failed: offline")))
              (let ((document
                     (dsh-emacs-plan--show
                      chat (plist-get review :identity)
                      (dsh-protocol-question-detail
                       (plist-get review :question)))))
                (with-current-buffer document
                  (ert-info ((format "%s" "plan-reopened-after-failure-offers-approve"))
                    (should (eq review dsh-emacs-plan--review))
                    (should (string-match-p "Decision failed: offline"
                                            (buffer-string)))
                    (should (string-match-p "Approve and execute"
                                            (buffer-string)))))))))
      (when (buffer-live-p chat)
        (with-current-buffer chat (dsh-emacs-plan--cancel)))
      (when (buffer-live-p chat) (kill-buffer chat))
      (dolist (buffer documents)
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

;; Equal call ids in different chats must never share actions or retirement.
(ert-deftest dsh-emacs-test-plan-plan-documents-isolate-equal-call-ids-by-chat ()
  :tags '(dsh-unit)
  (let ((first (generate-new-buffer " *plan-first*"))
        (second (generate-new-buffer " *plan-second*"))
        (dsh-emacs-events--client-id "isolated-client")
        (dsh-emacs-enable-notifications nil)
        documents sent)
    (unwind-protect
        (cl-letf (((symbol-function 'display-buffer)
                   (lambda (buffer &rest _) (push buffer documents) nil))
                  ((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (method args callback)
                     (push (cons method args) sent) (funcall callback t nil))))
          (dsh-emacs--question-requested
           first "review-first" "first" (list (dsh-test--plan-question)))
          (dsh-emacs--question-requested
           second "review-second" "second" (list (dsh-test--plan-question)))
          (ert-info ((format "%s" "plan-documents-isolate-equal-call-ids-by-chat"))
            (should (= (length (delete-dups (copy-sequence documents))) 2)))
          (dsh-emacs--question-cancelled "review-first")
          (ert-info ((format "%s" "plan-host-cancel-retires-only-target-without-answer"))
            (should (null sent))
            (should (null (buffer-local-value 'dsh-emacs-plan--pending first)))
            (should (= (length (buffer-local-value 'dsh-emacs-plan--pending second)) 1))
            (should (with-current-buffer (cadr documents)
                      (condition-case nil (progn (dsh-emacs-plan-approve) nil)
                        (user-error t)))))
          (kill-buffer second)
          (ert-info ((format "%s" "plan-chat-closure-hands-back-only-own-request"))
            (should (equal sent
                           '(("$events/result"
                              (clientId . "isolated-client")
                              (eventId . "review-second")
                              (outcome . ((kind . "next")))))))
            (should (with-current-buffer (car documents)
                      (string-match-p "Chat closed" (buffer-string))))))
      (when (buffer-live-p first) (kill-buffer first))
      (when (buffer-live-p second) (kill-buffer second))
      (dolist (buffer documents) (kill-buffer buffer)))))

;; A re-issued waterfall for the same submitted document moves the single
;; pending request onto the newest event id instead of stacking a second one.
(ert-deftest dsh-emacs-test-plan-plan-reissued-review-refreshes-single-pending ()
  :tags '(dsh-unit)
  (let ((chat (generate-new-buffer " *plan-reissued*"))
        (dsh-emacs-events--client-id "reissue-client")
        (dsh-emacs-enable-notifications nil)
        documents sent)
    (unwind-protect
        (cl-letf (((symbol-function 'display-buffer)
                   (lambda (buffer &rest _) (cl-pushnew buffer documents) nil))
                  ((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (method args _callback)
                     (push (cons method args) sent))))
          (with-current-buffer chat
            (dsh-emacs--question-requested
             chat "review-old" "reissue"
             (list (dsh-test--plan-question "call-reissued")))
            (dsh-emacs--question-requested
             chat "review-new" "reissue"
             (list (dsh-test--plan-question "call-reissued")))
            (let ((review (car dsh-emacs-plan--pending)))
              (ert-info ((format "%s" "plan-reissued-review-refreshes-single-pending"))
                (should (= (length dsh-emacs-plan--pending) 1))
                (should (= (length documents) 1))
                (should (equal (plist-get review :event-id) "review-new")))
              (with-current-buffer (plist-get review :buffer)
                (dsh-emacs-plan-approve))
              (ert-info ((format "%s" "plan-reissued-review-answers-newest-waterfall"))
                (should (equal (alist-get 'eventId (cdr (car sent))) "review-new"))))))
      (with-current-buffer chat (dsh-emacs-plan--cancel))
      (kill-buffer chat)
      (dolist (buffer documents)
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

;; A response settles only the waterfall it was submitted for.  When the
;; host re-issues the same plan under a new event id, the old response must
;; not retire the new request, and the re-issued request must be answerable.
(ert-deftest dsh-emacs-test-plan-plan-superseded-response-does-not-retire-reissue ()
  :tags '(dsh-unit)
  (let ((chat (generate-new-buffer " *plan-superseded*"))
        (dsh-emacs-events--client-id "superseded-client")
        (dsh-emacs-enable-notifications nil)
        documents sent callbacks)
    (unwind-protect
        (cl-letf (((symbol-function 'display-buffer)
                   (lambda (buffer &rest _) (cl-pushnew buffer documents) nil))
                  ((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (method args callback)
                     (push (cons method args) sent)
                     (push (cons (alist-get 'eventId args) callback) callbacks))))
          (with-current-buffer chat
            (dsh-emacs--question-requested
             chat "plan-old" "superseded"
             (list (dsh-test--plan-question "call-superseded")))
            (let ((review (car dsh-emacs-plan--pending)))
              (with-current-buffer (plist-get review :buffer)
                (dsh-emacs-plan-approve))
              (let ((stale (cdr (assoc "plan-old" callbacks))))
                (dsh-emacs--question-requested
                 chat "plan-new" "superseded"
                 (list (dsh-test--plan-question "call-superseded")))
                (funcall stale t nil)
                (ert-info ((format "%s" "plan-superseded-success-keeps-reissued-review"))
                  (should-not (plist-get review :retired))
                  (should (memq review dsh-emacs-plan--pending))
                  (should (equal (plist-get review :event-id) "plan-new"))
                  (should-not (plist-get review :busy))
                  (should (equal (plist-get review :status) "Pending review"))
                  (should (with-current-buffer (plist-get review :buffer)
                            (string-match-p "Approve and execute" (buffer-string)))))
                (funcall stale nil "stale failure")
                (ert-info ((format "%s" "plan-superseded-failure-keeps-reissued-status"))
                  (should (memq review dsh-emacs-plan--pending))
                  (should-not (plist-get review :retired))
                  (should (equal (plist-get review :status) "Pending review"))
                  (should-not (plist-get review :busy)))
                (with-current-buffer (plist-get review :buffer)
                  (dsh-emacs-plan-approve))
                (ert-info ((format "%s" "plan-superseded-reissue-answers-newest-event"))
                  (should (= (length sent) 2))
                  (should (equal (alist-get 'eventId (cdr (car sent))) "plan-new"))
                  (should (plist-get review :busy)))
                (funcall (cdr (assoc "plan-new" callbacks)) t nil)
                (ert-info ((format "%s" "plan-current-response-retires-reissued-review"))
                  (should-not (memq review dsh-emacs-plan--pending))
                  (should (plist-get review :retired))
                  (should (equal (plist-get review :status) "Approved"))
                  (should (with-current-buffer (plist-get review :buffer)
                            (string-match-p "Approved" (buffer-string)))))))))
      (when (buffer-live-p chat)
        (with-current-buffer chat (dsh-emacs-plan--cancel)))
      (when (buffer-live-p chat) (kill-buffer chat))
      (dolist (buffer documents)
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

;; An empty call id is no identity: two submitted documents stay two requests
;; (and two document buffers) instead of collapsing onto each other.
(ert-deftest dsh-emacs-test-plan-plan-empty-call-id-keeps-requests-separate ()
  :tags '(dsh-unit)
  (let ((chat (generate-new-buffer " *plan-empty-call-id*"))
        (dsh-emacs-events--client-id "empty-client")
        (dsh-emacs-enable-notifications nil)
        documents)
    (unwind-protect
        (cl-letf (((symbol-function 'display-buffer)
                   (lambda (buffer &rest _) (cl-pushnew buffer documents) nil))
                  ((symbol-function 'dsh-emacs--rpc-async) #'ignore))
          (with-current-buffer chat
            (dsh-emacs--question-requested
             chat "empty-one" "empty" (list (dsh-test--plan-question "")))
            (dsh-emacs--question-requested
             chat "empty-two" "empty" (list (dsh-test--plan-question "")))
            (ert-info ((format "%s" "plan-empty-call-id-keeps-requests-separate"))
              (should (= (length dsh-emacs-plan--pending) 2))
              (should (= (length documents) 2))
              (should (equal (mapcar (lambda (review) (plist-get review :event-id))
                                     dsh-emacs-plan--pending)
                             '("empty-two" "empty-one"))))))
      (with-current-buffer chat (dsh-emacs-plan--cancel))
      (kill-buffer chat)
      (dolist (buffer documents)
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

;; Closing a chat whose decision is already on the wire must not hand the same
;; waterfall back to the host a second time.
(ert-deftest dsh-emacs-test-plan-plan-chat-closure-while-sending-does-not-hand-back ()
  :tags '(dsh-unit)
  (let ((chat (generate-new-buffer " *plan-busy-close*"))
        (dsh-emacs-events--client-id "busy-client")
        (dsh-emacs-enable-notifications nil)
        documents sent)
    (unwind-protect
        (cl-letf (((symbol-function 'display-buffer)
                   (lambda (buffer &rest _) (cl-pushnew buffer documents) nil))
                  ((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (method args _callback)
                     (push (cons method args) sent))))
          (with-current-buffer chat
            (dsh-emacs--question-requested
             chat "busy-event" "busy" (list (dsh-test--plan-question "call-busy")))
            (with-current-buffer (plist-get (car dsh-emacs-plan--pending) :buffer)
              (dsh-emacs-plan-approve))
            (dsh-emacs-plan--chat-closed)
            (ert-info ((format "%s" "plan-chat-closure-while-sending-does-not-hand-back"))
              (should (= (length sent) 1))
              (should (equal (alist-get 'kind (alist-get 'outcome (cdr (car sent)))) "result"))
              (should (null dsh-emacs-plan--pending)))))
      (when (buffer-live-p chat) (kill-buffer chat))
      (dolist (buffer documents)
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

;; Unsupported intents keep the existing ordinary question path; a plan-review
;; intent that cannot be presented as a document says so instead of degrading
;; silently.
(ert-deftest dsh-emacs-test-plan-plan-review-falls-back-for-case ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dolist (kind '(plain multi batch bad-label))
      (let* ((question (dsh-test--plan-question))
             (questions (list question))
             messages)
        (pcase kind
          ('plain (setf (alist-get 'intent question) nil))
          ('multi (push '(multiSelect . t) question) (setq questions (list question)))
          ('batch (push (copy-tree question) questions))
          ('bad-label (setf (alist-get 'approve (alist-get 'intent question)) "No")))
        (cl-letf (((symbol-function 'message)
                   (lambda (format-string &rest args)
                     (push (apply #'format format-string args) messages))))
          (ert-info ((format "%s" (format "plan-review-falls-back-for-%s" kind)))
            (should (not (dsh-emacs-plan--request (current-buffer) "fallback" "s" questions)))
            (should (if (memq kind '(multi bad-label))
                        (and messages
                             (string-match-p "plan review" (downcase (car messages))))
                      (null messages)))))))))

;; Historical cards survive settlement and replay; opening them never approves.
(ert-deftest dsh-emacs-test-plan-plan-history-card-keeps-document-and-title ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (let ((text "# Search plan\n\nA readable historical plan.")
          opened)
      (dsh-emacs-render-tool-call
       (dsh-emacs-test--tool-call-event
        1 "plan-history" "exit_plan_mode" (json-encode `((plan . ,text)))))
      (dsh-emacs-render-tool-result
       (dsh-emacs-test--tool-result-event
        2 "plan-history" nil nil "Plan approved"))
      (goto-char (point-min))
      (search-forward "Plan: Search plan")
      (let ((button (button-at (match-beginning 0))))
        (ert-info ((format "%s" "plan-history-card-keeps-document-and-title"))
          (should button)
          (should (equal (button-get button 'dsh-emacs-plan--markdown) text))
          (should (string-match-p "Approved" (buffer-string)))
          (should (not (string-match-p "Tool Call" (buffer-string)))))
        (cl-letf (((symbol-function 'dsh-emacs-plan--show)
                   (lambda (chat call-id body &rest _)
                     (setq opened (list chat call-id body)) chat))
                  ((symbol-function 'pop-to-buffer) #'ignore))
          (button-activate button))
        (ert-info ((format "%s" "plan-history-card-opens-correct-call"))
          (should (equal opened (list (current-buffer) "plan-history" text))))))))

(provide 'dsh-test-plan)
;;; dsh-test-plan.el ends here
