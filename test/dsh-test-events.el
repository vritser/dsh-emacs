;;; dsh-test-events.el --- Events tests -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "28.1"))

(require 'dsh-test-support)

(ert-deftest dsh-emacs-test-events-activity-replay-keeps-newest-timestamp ()
  :tags '(dsh-unit)
  (dolist (snapshot-time '(nil 50 150))
    (let ((dsh-emacs--sessions nil)
          (dsh-emacs-sessions-buffer nil)
          (dsh-emacs--host-refresh-depth 0)
          (dsh-emacs--host-refresh-frames nil))
      (dsh-emacs-events--host-refresh-begin)
      ;; A cold list must retain the event until its session summary arrives.
      (dsh-emacs-events--host-item
       nil '((type . "emit") (event . "api-session/activity")
             (args . ["active" 100])))
      (should-not dsh-emacs--sessions)
      (should (equal dsh-emacs--host-refresh-frames
                     '((:session-activity "active" 100))))
      (setq dsh-emacs--sessions
            (dsh-emacs-test--session-items
             `(((sessionId . "active") (updatedAt . ,snapshot-time)))))
      (dsh-emacs-events--host-refresh-drain)
      (should (= (dsh-protocol-session-updated-at (car dsh-emacs--sessions))
                 (max 100 (or snapshot-time 0))))
      (should-not dsh-emacs--host-refresh-frames)
      (should (= 0 dsh-emacs--host-refresh-depth)))))

(ert-deftest dsh-emacs-test-events-model-selection-projections-update-chat-and-cache ()
  :tags '(dsh-unit)
  (dolist (route '(increment control follow))
    (dolist (cached '(nil t))
      (with-temp-buffer
        (dsh-emacs-mode)
        (setq-local dsh-emacs--buffer-session "model-session")
        (setq dsh-emacs--modeline-model "old-model"
              dsh-emacs--modeline-provider "old-provider"
              dsh-emacs--modeline-effort "old-effort")
        (let* ((dsh-emacs--chat-buffers (make-hash-table :test 'equal))
               (dsh-emacs--subagent-catalogs (make-hash-table :test 'equal))
               (dsh-emacs--sessions
                (and cached (list (dsh-protocol-session--from-alist
                                   '((sessionId . "model-session"))))))
               (dsh-emacs-sessions-buffer (generate-new-buffer-name " *absent-list*"))
               (selection '((lastUsed . ((provider . "new-provider")
                                         (model . "new-model")))
                            (next . ((provider . "next-provider")
                                     (model . "next-model")))))
               (baseline `((asOfSeq . 5)
                           (values . ((modelSelection . ,selection))))))
          (puthash "model-session" (current-buffer) dsh-emacs--chat-buffers)
          (pcase route
            ('increment
             (dsh-emacs-events--host-apply-projection
              nil `((sessionId . "model-session") (key . "modelSelection")
                    (seq . 5) (value . ,selection))))
            ('control
             (dsh-emacs-events--host-control-baseline
              nil `((projections . ((model-session . ,baseline))))))
            ('follow
             (dsh-emacs-events--apply-snapshot-projections "model-session" baseline)))
          (ert-info ((format "route=%s cached=%s" route cached))
            (should (equal dsh-emacs--modeline-model "new-model"))
            (should (equal dsh-emacs--modeline-provider "new-provider"))
            (should-not dsh-emacs--modeline-effort)
            (when cached
              (should (equal (dsh-protocol-model-selection-model
                              (dsh-emacs--session-model-selection "model-session"))
                             "new-model")))))))))

(ert-deftest dsh-emacs-test-events-model-selection-refresh-replays-live-update ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (setq-local dsh-emacs--buffer-session "model-refresh")
    (let* ((dsh-emacs--chat-buffers (make-hash-table :test 'equal))
           (dsh-emacs--sessions nil)
           (dsh-emacs--host-refresh-depth 0)
           (dsh-emacs--host-refresh-frames nil)
           (dsh-emacs-sessions-buffer (generate-new-buffer-name " *absent-list*"))
           callback)
      (puthash "model-refresh" (current-buffer) dsh-emacs--chat-buffers)
      (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                 (lambda (_method _args done) (setq callback done)))
                ((symbol-function 'dsh-emacs-list-workspaces) #'ignore))
        (dsh-emacs-list-sessions--fetch)
        (dolist (model '("new-model" "newest-model"))
          (dsh-emacs-events--host-apply-projection
           nil `((sessionId . "model-refresh") (key . "modelSelection")
                 (value . ((lastUsed . ((provider . "new-provider")
                                        (model . ,model))))))))
        (funcall callback t
                 '((items . [((sessionId . "model-refresh")
                              (projections . ((values . ((modelSelection
                                                          . ((lastUsed
                                                              . ((model . "old-model"))))))))))])))
        (should (equal dsh-emacs--modeline-model "newest-model"))
        (should (equal (dsh-protocol-model-selection-model
                        (dsh-emacs--session-model-selection "model-refresh"))
                       "newest-model"))
        (should (= dsh-emacs--host-refresh-depth 0))
        (should-not dsh-emacs--host-refresh-frames)))))

(ert-deftest dsh-emacs-test-events-model-selection-refresh-outlives-origin-chat ()
  :tags '(dsh-unit)
  (let ((origin (generate-new-buffer " *model-fetch-origin*"))
        (dsh-emacs--chat-buffers (make-hash-table :test 'equal))
        (dsh-emacs--sessions nil)
        (dsh-emacs--host-refresh-depth 0)
        (dsh-emacs--host-refresh-frames nil)
        callback owner)
    (unwind-protect
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (_method _args done)
                     (setq owner (current-buffer) callback done)))
                  ((symbol-function 'dsh-emacs-list-workspaces) #'ignore))
          (with-current-buffer origin (dsh-emacs-list-sessions--fetch))
          (kill-buffer origin)
          ;; Match HTTP dispatch: callbacks are dropped for dead owners.
          (when (buffer-live-p owner)
            (with-current-buffer owner (funcall callback t '((items . [])))))
          (should (= dsh-emacs--host-refresh-depth 0))
          (should-not dsh-emacs--host-refresh-frames))
      (when (buffer-live-p origin) (kill-buffer origin)))))

(ert-deftest dsh-emacs-test-events-model-selection-during-follow-history-wins ()
  :tags '(dsh-unit)
  (dolist (refresh '(nil t))
    (with-temp-buffer
      (dsh-emacs-mode)
      (setq-local dsh-emacs--buffer-session "model-snapshot")
      (let* ((dsh-emacs--chat-buffers (make-hash-table :test 'equal))
             (dsh-emacs--subagent-catalogs (make-hash-table :test 'equal))
             (dsh-emacs--sessions nil)
             (dsh-emacs--host-refresh-depth 0)
             (dsh-emacs--host-refresh-frames nil)
             (dsh-emacs-sessions-buffer (generate-new-buffer-name " *absent-list*"))
             (snapshot
              (dsh-protocol-read-json
               (concat "{\"cursor\":20,\"records\":[{\"type\":\"event\",\"event\":{"
                       "\"type\":\"request/header\",\"seq\":10,\"data\":{\"header\":{"
                       "\"config\":{\"model\":\"historical-model\"}}}}}],"
                       "\"projections\":{\"asOfSeq\":20,\"values\":{\"modelSelection\":{"
                       "\"lastUsed\":{\"model\":\"snapshot-model\"}}}}}"))))
        (puthash "model-snapshot" (current-buffer) dsh-emacs--chat-buffers)
        (when refresh (dsh-emacs-events--host-refresh-begin))
        (cl-letf (((symbol-function 'dsh-emacs-render-history-events)
                   (lambda (records &rest _)
                     (dsh-emacs-events--host-apply-projection
                      nil (dsh-protocol-read-json
                           (concat "{\"sessionId\":\"model-snapshot\","
                                   "\"key\":\"modelSelection\",\"value\":{"
                                   "\"lastUsed\":{\"model\":\"live-model\"}}}")))
                     ;; Rendering can resume with an older request after yielding.
                     (dsh-emacs-modeline-note-header
                      (cdr (assq 'event (car records)))))))
          (dsh-emacs-events--follow-snapshot (current-buffer) snapshot))
        (should (equal dsh-emacs--modeline-model "live-model"))
        ;; A list response can install the row only after the live increment.
        (setq dsh-emacs--sessions
              (list (dsh-protocol-session--from-alist
                     '((sessionId . "model-snapshot")))))
        (dsh-emacs-events--host-refresh-drain)
        (should (equal dsh-emacs--modeline-model "live-model"))
        (should (equal (and refresh
                            (dsh-protocol-model-selection-model
                             (dsh-emacs--session-model-selection "model-snapshot")))
                       (and refresh "live-model")))))))

(ert-deftest dsh-emacs-test-events-follow-projections-run-after-history ()
  :tags '(dsh-unit)
  (dolist (decoded '(nil t))
    (with-temp-buffer
      (dsh-emacs-mode)
      (setq-local dsh-emacs--buffer-session "follow-contract")
      (let* ((dsh-emacs--chat-buffers (make-hash-table :test 'equal))
             (dsh-emacs--input-history-by-session (make-hash-table :test 'equal))
             (dsh-emacs--subagent-catalogs (make-hash-table :test 'equal))
             (apply-projections
              (symbol-function 'dsh-emacs-events--apply-snapshot-projections))
             (record
              '((type . "event")
                (event . ((type . "user/message") (seq . 3)
                          (data . ((content . [((type . "text")
                                                (text . "snapshot body"))])))))))
             (projections
              '((asOfSeq . 3)
                (values . ((userQuestions
                            . ((active . []) (settled . [])))))))
             (wire
              `((type . "snapshot") (cursor . 3) (hasMore . :json-false)
                (records . ,(vector record)) (projections . ,projections)))
             (item (if decoded (dsh-protocol-follow-item--from-alist wire) wire))
             observed)
        (puthash "follow-contract" (current-buffer) dsh-emacs--chat-buffers)
        (cl-letf (((symbol-function 'dsh-emacs-events--apply-snapshot-projections)
                   (lambda (session projections)
                     (setq observed
                           (list session
                                 (and (string-match-p "snapshot body"
                                                      (buffer-string)) t)
                                 dsh-emacs--history-cursor
                                 dsh-emacs--anchor-seq))
                     (funcall apply-projections session projections))))
          (dsh-emacs-events--follow-item (current-buffer) item))
        (ert-info ((format "decoded=%s" decoded))
          (should (equal observed '("follow-contract" t 3 3)))
          (should-not dsh-emacs--history-has-more)
          (should (dsh-protocol-user-questions-p dsh-emacs--session-questions))
          (should (= 3 (dsh-protocol-user-questions-seq
                        dsh-emacs--session-questions))))))))

(ert-deftest dsh-emacs-test-events-follow-projections-distinguish-goal-and-values-shapes ()
  :tags '(dsh-unit)
  (dolist (case '((nil t nil)
                  (((futureCell . "ignored")) t nil)
                  (((goal . nil)) t nil)
                  (((goal . :json-false)) nil nil)
                  (((goal . 7)) nil nil)
                  (((goal . "bad")) nil nil)
                  (((goal . [])) nil nil)
                  (:json-false nil t)
                  ([] nil t)))
    (pcase-let ((`(,values ,clears ,invalid) case))
      (with-temp-buffer
        (dsh-emacs-mode)
        (setq-local dsh-emacs--buffer-session "follow-shapes")
        (let* ((dsh-emacs--chat-buffers (make-hash-table :test 'equal))
               (dsh-emacs--subagent-catalogs (make-hash-table :test 'equal))
               (dsh-emacs-sessions-buffer (generate-new-buffer-name " *absent-list*"))
               (goal (dsh-protocol-goal--from-alist
                      '((objective . "Existing goal") (phase . "active"))))
               (questions (dsh-protocol-user-questions--from-alist nil 3))
               (projections `((asOfSeq . 9) (values . ,values))))
          (puthash "follow-shapes" (current-buffer) dsh-emacs--chat-buffers)
          (dsh-emacs-composer-set-goal goal)
          (dsh-emacs--session-questions-apply questions)
          (ert-info ((format "values=%S" values))
            (if invalid
                (should-error
                 (dsh-emacs-events--apply-snapshot-projections "follow-shapes" projections)
                 :type 'wrong-type-argument)
              (dsh-emacs-events--apply-snapshot-projections "follow-shapes" projections))
            (if clears
                (should-not dsh-emacs--composer-goal)
              (should (eq goal dsh-emacs--composer-goal)))
            (if invalid
                (progn
                  (should (eq questions dsh-emacs--session-questions))
                  (should-not (gethash "follow-shapes" dsh-emacs--subagent-catalogs)))
              (should (= 9 (dsh-protocol-user-questions-seq dsh-emacs--session-questions)))
              (should (= 9 (dsh-protocol-subagent-cell-seq
                            (dsh-emacs-subagent--cell "follow-shapes" 'subagentCatalog)))))))))))

(ert-deftest dsh-emacs-test-events-follow-projections-apply-in-order-without-inbox ()
  :tags '(dsh-unit)
  (dolist (decoded '(nil t))
    (with-temp-buffer
      (dsh-emacs-mode)
      (setq-local dsh-emacs--buffer-session "follow-order")
      (let* ((dsh-emacs--chat-buffers (make-hash-table :test 'equal))
             (dsh-emacs--subagent-catalogs (make-hash-table :test 'equal))
             (dsh-emacs-sessions-buffer (generate-new-buffer-name " *absent-list*"))
             (session (dsh-protocol-session--from-alist '((sessionId . "follow-order"))))
             (dsh-emacs--sessions (list session))
             (items (list (dsh-emacs-test--queue-item "keep" "queued" "Keep input")))
             (plan (dsh-protocol-plan--from-alist '((active . t)) 3))
             (projections
              '((asOfSeq . 9)
                (values . ((userQuestions . ((active . []) (settled . [])))
                           (goal . ((goal . ((objective . "Follow goal") (phase . "active")))))
                           (permissions . ((currentValue . "custom")))
                           (contextPressure . ((pressureTokens . 40) (projectedTokens . 45)
                                               (contextWindow . 100)))
                           (title . "Follow title") (subagentCatalog . [])
                           (plan . ((active . :json-false) (pending . t)))
                           (inbox . nil) (futureCell . ((payload . "ignored")))))))
             (expected '(dsh-emacs-subagent-apply
                         dsh-emacs-events--apply-title
                         dsh-emacs--events-apply-context-projection
                         dsh-emacs--events-apply-permission-projection
                         dsh-emacs-events--apply-goal-projection
                         dsh-emacs--session-questions-apply))
             calls advices)
        (puthash "follow-order" (current-buffer) dsh-emacs--chat-buffers)
        (dsh-emacs-queue-apply (current-buffer) 'queue-owner items)
        (dsh-emacs-modeline-set-plan plan)
        (unwind-protect
            (progn
              ;; Observe real consumers; every recorder forwards the same input.
              (dolist (function expected)
                (let* ((target function)
                       (recorder (lambda (original &rest args)
                                   (push target calls)
                                   (apply original args))))
                  (push (cons target recorder) advices)
                  (advice-add target :around recorder)))
              (dsh-emacs-events--apply-snapshot-projections
               "follow-order"
               (if decoded (dsh-protocol-follow-projections--from-alist projections) projections))
              (should (equal (reverse calls) expected))
              (should (equal "Follow title" (dsh-protocol-session-title-value session)))
              (should (= 45 dsh-emacs--modeline-context-pressure))
              (should (= 100 dsh-emacs--modeline-context-window-server))
              (should (equal "custom" dsh-emacs--modeline-permission))
              (should (equal "Follow goal" (dsh-protocol-goal-objective dsh-emacs--composer-goal)))
              (should (= 9 (dsh-protocol-user-questions-seq dsh-emacs--session-questions)))
              (should (= 9 (dsh-protocol-subagent-cell-seq
                            (dsh-emacs-subagent--cell "follow-order" 'subagentCatalog))))
              (should (eq items dsh-emacs--queue-items))
              (should (eq 'queue-owner dsh-emacs--queue-process))
              (should (eq plan dsh-emacs--modeline-plan))
              (should (= 3 dsh-emacs--modeline-plan-seq)))
          (dolist (entry advices)
            (advice-remove (car entry) (cdr entry))))))))

(ert-deftest dsh-emacs-test-events-follow-projection-error-follows-history-progress ()
  :tags '(dsh-unit)
  (dolist (decoded '(nil t))
    (with-temp-buffer
      (dsh-emacs-mode)
      (setq-local dsh-emacs--buffer-session "follow-migration"
                  dsh-emacs--history-cursor 1
                  dsh-emacs--anchor-seq 1
                  dsh-emacs--ws-last-event-time 123.0)
      (let* ((dsh-emacs--chat-buffers (make-hash-table :test 'equal))
             (dsh-emacs--input-history-by-session (make-hash-table :test 'equal))
             (dsh-emacs--subagent-catalogs (make-hash-table :test 'equal))
             (record
              '((type . "event")
                (event . ((type . "user/message") (seq . 7)
                          (data . ((content . [((type . "text")
                                                (text . "Applied before migration"))])))))))
             (snapshot
              `((cursor . 7) (records . ,(vector record))
                (projections . ((kind . "migration-required") (asOfSeq . 7) (values))))))
        (puthash "follow-migration" (current-buffer) dsh-emacs--chat-buffers)
        (should-error
         (dsh-emacs-events--follow-snapshot
          (current-buffer)
          (if decoded (dsh-protocol-follow-snapshot--from-alist snapshot) snapshot))
         :type 'dsh-protocol-migration-required)
        (should (string-match-p "Applied before migration" (buffer-string)))
        (should (= 7 dsh-emacs--history-cursor))
        (should (= 7 dsh-emacs--anchor-seq))
        (should (= 123.0 dsh-emacs--ws-last-event-time))
        (should-not (gethash "follow-migration" dsh-emacs--subagent-catalogs))))))

;; --- Test 28: frames after the WebSocket handshake are still consumed (live
;; fix) ---
(ert-deftest dsh-emacs-test-events-websocket-frames-consumed-after-handshake ()
  :tags '(dsh-unit)
  (let ((dsh-emacs--current-session "s1"))
    (with-temp-buffer
      (dsh-emacs-mode)
      (dsh-emacs-modeline-setup)
      (setq-local dsh-emacs--buffer-session "s1")
      (let ((fake-proc (make-pipe-process :name "dsh-test-proc" :noquery t))
            (dispatch-count 0)
            (dispatch (symbol-function 'dsh-emacs-events--dispatch-json)))
        (unwind-protect
            (cl-letf (((symbol-function 'dsh-emacs-events--dispatch-json)
                       (lambda (&rest args)
                         (cl-incf dispatch-count)
                         (apply dispatch args))))
              (process-put fake-proc 'dsh-emacs-chat-buffer (current-buffer))
              (process-put fake-proc 'dsh-emacs-follow-stream-id "f1")
              (process-put fake-proc 'dsh-emacs-event-ready t)
              ;; Feed a separate masked item frame after the handshake.
              (let* ((json (json-encode
                            '((type . "item") (streamId . "f1")
                              (value . ((type . "event")
                                        (event . ((type . "assistant/message")
                                                  (seq . 1)
                                                  (data . ((message . ((content . [((type . "text") (text . "hello ws"))]))))))))))))
                     (frame (dsh-emacs-events--frame
                             1 (encode-coding-string json 'utf-8 t))))
                (process-put fake-proc 'dsh-emacs-event-input frame)
                (dsh-emacs-events--consume-frames fake-proc))
              (should (= dispatch-count 1))
              (should (string-empty-p
                       (process-get fake-proc 'dsh-emacs-event-input)))
              (should (string-match-p "hello ws" (buffer-string))))
          (delete-process fake-proc))))))

;; --- Test 43c: on send, a session with no stream reconnects first (self-heal);
;; no duplicate connect while the handshake is in flight ---
(ert-deftest dsh-emacs-test-events-submit-heals-streamless-buffer-with-reconnect ()
  :tags '(dsh-unit)
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
          (ert-info ((format "%s" "submit-heals-streamless-buffer-with-reconnect"))
            (should (eq (car connects) chat)))
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
                  (ert-info ((format "%s" "submit-in-handshake-keeps-single-stream"))
                    (should (null connects))))
              (delete-process proc))))
      (setq dsh-emacs--current-session old-current-session)
      (when (buffer-live-p chat) (kill-buffer chat)))))

;; --- Test 51h: connecting an already-connected host stream is a no-op ---
(ert-deftest dsh-emacs-test-events-host-connect-is-idempotent ()
  :tags '(dsh-unit)
  (let* ((proc (make-pipe-process :name "dsh-test-host" :noquery t))
         (dsh-emacs--host-process proc)
         (disconnects 0))
    (unwind-protect
        (cl-letf (((symbol-function 'dsh-emacs-events-host-disconnect)
                   (lambda () (setq disconnects (1+ disconnects)))))
          (dsh-emacs-events-host-connect)
          (ert-info ((format "%s" "host-connect-is-idempotent"))
            (should (zerop disconnects))
            (should (dsh-emacs-events-host-connected-p))))
      (delete-process proc))))

;; --- Test 69: with multiple sessions in parallel, transcript events
;; route by buffer ownership (the guard must not use the global
;; current-session) ---
;; After opening sessions A and B, the global dsh-emacs--current-session
;; points to B, the last opened one; when A's buffer follow stream receives
;; A's transcript event, the ownership check must consult the chat buffer
;; bound to that process (recorded per process at open-session), otherwise
;; A's live transcript would be swallowed by the global current-session
;; ("B"). Conversely: B's events reach only B.
(ert-deftest dsh-emacs-test-events-parallel-sessions-mux-event-routes-to-owner ()
  :tags '(dsh-unit)
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
            (ert-info ((format "%s" "parallel-sessions-mux-event-routes-to-owner"))
              (should (and rendered-a (null rendered-b))))
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
            (ert-info ((format "%s" "parallel-sessions-both-streams-render"))
              (should (and rendered-a rendered-b)))))
      (setq dsh-emacs--current-session old-session)
      (kill-buffer chat-a)
      (kill-buffer chat-b)
      (delete-process proc-a)
      (delete-process proc-b))))

;; --- Test 70: an interactive command's target ownership follows the
;; command context (not the global current-session) ---
;; After opening session A and then B, the global
;; dsh-emacs--current-session="sess-b", current-buffer=buf-b; now the user
;; does switch-to-buffer back to A's chat buffer and presses C-c C-c
;; (send/interrupt) or C-c C-r (refresh); the target must be A -- ownership
;; is resolved from the buffer-local dsh-emacs--buffer-session, not from the
;; last-opened global value.
(ert-deftest dsh-emacs-test-events-send-in-inactive-buffer-targets-its-own-session ()
  :tags '(dsh-unit)
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
            (ert-info ((format "%s" "send-in-inactive-buffer-targets-its-own-session"))
              (should (and sent
                           (equal (list "session/prompt" "sess-a") (car sent))))))
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
            (ert-info ((format "%s" "interrupt-in-inactive-buffer-targets-own-session"))
              (should (and sent
                           (equal (list "session/cancel" "sess-a") (car sent))))))
          ;; Scenario 3: refresh delegates the current chat's reconnect;
          ;; connect owns teardown and preservation of live state.
          (with-current-buffer buf-a
            (setq sent nil)
            (cl-letf (((symbol-function 'dsh-emacs-events-disconnect)
                       (lambda () (push 'disconnect sent)))
                      ((symbol-function 'dsh-emacs-events-connect)
                       (lambda (target) (push (list "connect" target) sent))))
              (dsh-emacs-refresh))
            (ert-info ((format "%s" "refresh-in-inactive-buffer-targets-own-session"))
              (should (equal (list (list "connect" buf-a)) sent))))
          ;; Scenario 4: no ownership context (e.g. the *dsh-sessions* list buffer)
          ;; -> global fallback
          (with-temp-buffer
            (ert-info ((format "%s" "active-session-falls-back-to-global"))
              (should (string= "sess-b" (dsh-emacs--active-session-id))))))
      (setq dsh-emacs--current-session old-session)
      (setq dsh-emacs--current-buffer old-buffer)
      (kill-buffer buf-a)
      (kill-buffer buf-b))))

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
(ert-deftest dsh-emacs-test-events-refresh-from-inactive-chat-renders-into-own-buffer ()
  :tags '(dsh-unit)
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
          (ert-info ((format "%s" "refresh-from-inactive-chat-renders-into-own-buffer"))
            (should (equal (list (list "connect" buf-a)) targets))))
      (setq dsh-emacs--current-session old-session)
      (setq dsh-emacs--current-buffer old-buffer)
      (kill-buffer buf-a)
      (kill-buffer buf-b))))

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
(ert-deftest dsh-emacs-test-events-events-result-wire-envelope ()
  :tags '(dsh-unit)
  (let* (calls delivered
         (callback (lambda (ok value) (setq delivered (list ok value)))))
    (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
               (lambda (method params cb)
                 (push (list method params cb) calls)
                 (funcall cb t "accepted"))))
      (dsh-emacs--events-result-async
       "c1" "wf-1"
       '((kind . "result")
         (value . ((answers . (((id . "q1") (selected "Yes")))))))
       callback))
    (ert-info ((format "%s" "events-result-wire-envelope"))
      (should (= 1 (length calls)))
      (should (equal (caar calls) "$events/result"))
      (should (equal (cadar calls)
                     '((clientId . "c1")
                       (eventId . "wf-1")
                       (outcome . ((kind . "result")
                                   (value . ((answers . (((id . "q1")
                                                         (selected "Yes")))))))))))
      (should (eq (nth 2 (car calls)) callback))
      (should (equal delivered '(t "accepted"))))))

;; --- Test 78j: $events ready -> capture clientId; generation change retires pending
;; waterfalls ---
;; `$events' sends ready(clientId) first per generation (each reconnect); this
;; client answers waterfalls with that clientId, and after a generation change the old
;; generation's pending frames (result now a no-op) are retired as a whole.
(ert-deftest dsh-emacs-test-events-events-ready-captures-client-id ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (let ((dsh-emacs--chat-buffers (make-hash-table :test 'equal))
          (dsh-emacs-events--client-id nil)
          (dsh-emacs--question-queue nil)
          (dsh-emacs--approval-queue nil))
      (dsh-emacs-events--host-item
       'process (dsh-protocol-core-item--from-alist
                 '((type . "ready") (clientId . "gen-1"))))
      (should (equal "gen-1" dsh-emacs-events--client-id))
      (setq dsh-emacs--question-queue
            (list (list (current-buffer) "e-1" "sess-g" '((id . "q1")))))
      (dsh-emacs-events--host-item
       'process (dsh-protocol-core-item--from-alist
                 '((type . "ready") (clientId . "gen-1"))))
      (ert-info ("Same generation retains pending questions")
        (should (= 1 (length dsh-emacs--question-queue))))
      (setq dsh-emacs--approval-queue
            (list (list (current-buffer) "e-2" "sess-g" "bash" "reason" nil)))
      (dsh-emacs-events--host-item
       'process (dsh-protocol-core-item--from-alist
                 '((type . "ready") (clientId . "gen-2"))))
      (ert-info ("New generation retires both kinds of pending work")
        (should (equal "gen-2" dsh-emacs-events--client-id))
        (should-not dsh-emacs--question-queue)
        (should-not dsh-emacs--approval-queue)))))

;; --- Test 78j2: a new generation is only reported when it dropped work ---
;; A reconnect mints a new generation as a matter of course; announcing
;; "retiring 0 queued question(s) and 0 approval(s)" on every one of them is
;; echo-area noise, while a generation that actually dropped queued
;; waterfalls still has to say so.
(ert-deftest dsh-emacs-test-events-events-generation-quiet-with-nothing-pending ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (let ((dsh-emacs-events--client-id "gen-old")
          (dsh-emacs--chat-buffers (make-hash-table :test 'equal))
          (dsh-emacs--question-queue nil)
          (dsh-emacs--approval-queue nil)
          (messages nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args)
                   (push (apply #'format fmt args) messages))))
        (dsh-emacs-events--host-item
         'process '((type . "ready") (clientId . "gen-quiet")))
        (ert-info ((format "%s" "events-generation-quiet-with-nothing-pending"))
          (should (null messages))
          (should (equal "gen-quiet" dsh-emacs-events--client-id)))
        (setq dsh-emacs--question-queue
              (list (list (current-buffer) "e-3" "s" '((id . "q"))))
              dsh-emacs--approval-queue
              (list (list (current-buffer) "e-4" "s" "bash" "r" nil)))
        (dsh-emacs-events--host-item
         'process '((type . "ready") (clientId . "gen-loud")))
        (ert-info ((format "%s" "events-generation-reports-retired-work"))
          (should (= 1 (length messages)))
          (should (string-match-p "retiring 1 queued question" (car messages)))
          (should (string-match-p "1 approval" (car messages)))
          (should (null dsh-emacs--question-queue))
          (should (null dsh-emacs--approval-queue)))))))

;; --- Test 78k: $events cancel -> retire matching pending waterfalls by eventId ---
;; A host cancellation (session end / withdraw) sends cancel(eventId); only frames of
;; the same eventId retire, other pending frames are kept.
(ert-deftest dsh-emacs-test-events-events-cancel-retires-matching-question ()
  :tags '(dsh-unit)
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
           'process (dsh-protocol-core-item--from-alist
                     '((type . "cancel") (eventId . "q-cancel"))))
          (ert-info ((format "%s" "events-cancel-retires-matching-question"))
            (should (= 1 (length dsh-emacs--question-queue)))
            (should (equal "q-keep" (nth 1 (car dsh-emacs--question-queue))))
            (should (= 2 (length dsh-emacs--approval-queue))))
          (dsh-emacs-events--host-item
           'process (dsh-protocol-core-item--from-alist
                     '((type . "cancel") (eventId . "a-cancel"))))
          (ert-info ((format "%s" "events-cancel-retires-matching-approval"))
            (should (= 1 (length dsh-emacs--approval-queue)))
            (should (equal "a-keep" (nth 1 (car dsh-emacs--approval-queue))))
            (should (= 1 (length dsh-emacs--question-queue)))))
      (when (buffer-live-p chat) (kill-buffer chat)))))

(ert-deftest dsh-emacs-test-events-waterfalls-route-before-request-decoding ()
  :tags '(dsh-unit)
  (dolist (decoded '(nil t))
    (with-temp-buffer
      (let ((dsh-emacs--chat-buffers (make-hash-table :test 'equal))
            (dsh-emacs-events--client-id "client")
            calls responses)
        (puthash "local" (current-buffer) dsh-emacs--chat-buffers)
        (cl-letf (((symbol-function 'dsh-emacs--question-requested)
                   (lambda (&rest args) (push args calls)))
                  ((symbol-function 'dsh-emacs--approval-requested)
                   (lambda (&rest args) (push args calls)))
                  ((symbol-function 'dsh-emacs--events-result-async)
                   (lambda (client event outcome callback)
                     (push (list client event outcome) responses)
                     (funcall callback t nil))))
          (dolist (frame
                   '(((type . "waterfall") (event . "approval/request")
                      (eventId . "foreign-approval") (agentId . "foreign")
                      (request . ((displayReason . ((en . "English") . bad)))))
                     ((type . "waterfall") (event . "user-questions/request")
                      (eventId . "foreign-question") (agentId . "foreign")
                      (request . ((wait . ((callId . "call") . bad)))))
                     ((type . "waterfall") (event . "future-request")
                      (eventId . "foreign-unknown") (agentId . "foreign"))
                     ((type . "waterfall") (event . "future-request")
                      (eventId . "local-unknown") (agentId . "local"))
                     ((type . "waterfall") (event . "approval/request")
                      (agentId . "local")
                      (request . ((displayReason . ((en . "English") . bad)))))))
            (dsh-emacs-events--host-item
             nil (if decoded (dsh-protocol-core-item--from-alist frame) frame)))
          (should-not calls)
          (should (equal responses
                         '(("client" "foreign-unknown" ((kind . "next")))
                           ("client" "foreign-question" ((kind . "next")))
                           ("client" "foreign-approval" ((kind . "next")))))))))))

;; --- Test 93e: the WebSocket handshake carries the browser session cookie ---
(ert-deftest dsh-emacs-test-events-websocket-auth-authority-case ()
  :tags '(dsh-unit)
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
        (ert-info ((format "%s" (format "websocket-auth-authority-%s" dsh-emacs-base-url)))
          (should (string-match-p "Cookie: dsh-auth-HASH=ok\\.sig\r\n" sent))
          (should (string-match-p (regexp-quote (format "Host: %s\r\n" authority)) sent))
          (should (string-match-p
                   (regexp-quote
                    (format "Origin: %s://%s\r\n"
                            (url-type (url-generic-parse-url dsh-emacs-base-url)) authority))
                   sent)))))))

;; --- Test 93g: /api/remote.mux open message and downstream frame envelope ---
(ert-deftest dsh-emacs-test-events-mux-open-message-shape ()
  :tags '(dsh-unit)
  (let* ((json (dsh-protocol-mux-open-json
                "follow-1" "session/follow"
                '((request . ((address . ((kind . "session")
                                          (sessionId . "s1"))))))))
         (msg (json-read-from-string json)))
    (ert-info ((format "%s" "mux-open-message-shape"))
      (should (equal "open" (dsh-protocol--field "type" msg)))
      (should (equal "follow-1" (dsh-protocol--field "streamId" msg)))
      (should (equal "session/follow" (dsh-protocol--field "endpoint" msg)))
      (should (equal "s1"
                     (dsh-protocol--field
                      "sessionId"
                      (dsh-protocol--field
                       "address"
                       (dsh-protocol--field "request"
                                               (dsh-protocol--field "args"
                                                                       (dsh-protocol--field "payload" msg))))))))))

(ert-deftest dsh-emacs-test-events-mux-open-no-args-encodes-empty-object ()
  :tags '(dsh-unit)
  (let* ((json (dsh-protocol-mux-open-json "events-1" "$events" nil))
         (msg (json-read-from-string json))
         (args (assq 'args (dsh-protocol--field "payload" msg))))
    ;; The reader collapses both {} and null to nil; inspect the wire too.
    (ert-info ((format "%s" "mux-open-no-args-encodes-empty-object"))
      (should (string-match-p "\"payload\":{\"args\":{}}" json))
      (should (and args (null (cdr args)))))))

(ert-deftest dsh-emacs-test-events-mux-malformed-input-stays-quiet ()
  :tags '(dsh-unit)
  (let (chat-frames host-items messages)
    (cl-letf (((symbol-function 'dsh-emacs-events--dispatch-stream)
               (lambda (_process frame) (push frame chat-frames)))
              ((symbol-function 'dsh-emacs-events--host-item)
               (lambda (_process value) (push value host-items)))
              ((symbol-function 'message)
               (lambda (&rest args) (push args messages))))
      (dolist (json '("{" "[]" "false" "5" "\"text\"" "{}"))
        (dsh-emacs-events--dispatch-json nil json)
        (dsh-emacs-events--host-dispatch nil json))
      (dsh-emacs-events--dispatch-json
       nil "{\"type\":\"item\",\"value\":{\"type\":\"event\"}}")
      (should-not chat-frames)
      (should-not host-items)
      (should-not messages)
      (dsh-emacs-events--dispatch-json
       nil (concat "{\"type\":\"item\",\"streamId\":\"f1\","
                   "\"value\":{\"type\":\"event\"}}"))
      (dsh-emacs-events--host-dispatch
       nil "{\"type\":\"item\",\"value\":{\"type\":\"ready\"}}")
      (should (= 1 (length chat-frames)))
      (should (equal "f1" (dsh-protocol-mux-frame-stream-id (car chat-frames))))
      (should (equal '((type . "event"))
                     (dsh-protocol-mux-frame-value (car chat-frames))))
      (should (equal host-items '(((type . "ready")))))
      (should-not messages))))

(ert-deftest dsh-emacs-test-events-mux-custom-error-keeps-handler-until-end ()
  :tags '(dsh-unit)
  (let ((process (make-pipe-process :name "dsh-custom-mux" :noquery t))
        values messages)
    (unwind-protect
        (cl-letf (((symbol-function 'process-send-string) #'ignore)
                  ((symbol-function 'message)
                   (lambda (format-string &rest args)
                     (push (apply #'format format-string args) messages))))
          (process-put process 'dsh-emacs-follow-stream-id "follow-1")
          (process-put process 'dsh-emacs-stream-handlers
                       (list (cons "custom-1"
                                   (cons "custom/list"
                                         (lambda (value) (push value values))))))
          (dsh-emacs-events--dispatch-json
           process (concat "{\"type\":\"error\",\"streamId\":\"custom-1\","
                           "\"error\":{\"code\":\"unavailable\"}}"))
          (should-not values)
          (should (assoc "custom-1"
                         (process-get process 'dsh-emacs-stream-handlers)))
          (should (equal messages
                         '("dsh custom-1 stream error: ((code . \"unavailable\"))")))
          (dsh-emacs-events--dispatch-json
           process (concat "{\"type\":\"item\",\"streamId\":\"custom-1\","
                           "\"value\":{\"rows\":[1,2]}}"))
          (should (equal values '(((rows . [1 2])))))
          (dsh-emacs-events--dispatch-json
           process "{\"type\":\"end\",\"streamId\":\"custom-1\"}")
          (should (equal values '(nil ((rows . [1 2])))))
          (should-not (process-get process 'dsh-emacs-stream-handlers))
          (dsh-emacs-events--dispatch-json
           process "{\"type\":\"end\",\"streamId\":\"custom-1\"}")
          (should (equal values '(nil ((rows . [1 2]))))))
      (delete-process process))))

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
(ert-deftest dsh-emacs-test-events-frame-encodes-multibyte-payload-in-unibyte-buffer ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (set-buffer-multibyte nil)          ; reproduce the process-buffer environment
    (let ((payload (string-make-multibyte
                    "{\"type\":\"open\",\"streamId\":\"s1\",\"x\":\"中文\"}")))
      (when (multibyte-string-p payload)
        (let ((frame (condition-case err
                         (dsh-emacs-events--frame 1 payload)
                       (error (list :err err)))))
          (ert-info ((format "%s" "frame-encodes-multibyte-payload-in-unibyte-buffer"))
            (should (and (not (and (consp frame) (eq (car frame) :err)))
                         (not (multibyte-string-p frame))
                         (stringp frame)))))))))

;; --- Test 98g: reconnect (connect→disconnect→restore) does not lose the
;; mode-line busy flag ---
;; Regression: the stream drops while switching away and back, and on reconnect
;; the disconnect clears the busy flag --- yet the busy flag is exactly the
;; switch for the C-c C-c interrupt (session/cancel): lose it and you get "cannot
;; interrupt, please enter a message".
(ert-deftest dsh-emacs-test-events-reconnect-keeps-busy-flag ()
  :tags '(dsh-unit)
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
          (ert-info ((format "%s" "reconnect-keeps-busy-flag"))
            (should (and dsh-emacs--ml-busy
                         (not (string-empty-p (dsh-emacs--ml-busy-indicator))))))
          (dsh-emacs--ml-busy-clear))
      (kill-buffer buf))))

;; A failed reconnect must retain liveness for the next attempt.  After a
;; long turn's compaction, the bounded snapshot need not include turn/start.
(ert-deftest dsh-emacs-test-events-failed-reconnect-retains-running-after-compaction ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (setq-local dsh-emacs--buffer-session "reconnect-compaction")
    (setq-local dsh-emacs--anchor-seq 100)
    (dsh-emacs--ml-busy-set t)
    (let ((attempts 0))
      (unwind-protect
          (cl-letf (((symbol-function 'open-network-stream)
                     (lambda (&rest _)
                       (if (= (cl-incf attempts) 1)
                           (error "Test connection failure")
                         :fake-proc)))
                    ((symbol-function 'set-process-query-on-exit-flag) #'ignore)
                    ((symbol-function 'set-process-coding-system) #'ignore)
                    ((symbol-function 'process-put) #'ignore)
                    ((symbol-function 'set-process-filter) #'ignore)
                    ((symbol-function 'set-process-sentinel) #'ignore)
                    ((symbol-function 'dsh-emacs-events--schedule-reconnect)
                     #'ignore))
            (dsh-emacs-events-connect (current-buffer))
            (dsh-emacs-events-connect (current-buffer))
            (dsh-emacs-events--follow-snapshot
             (current-buffer)
             '((cursor . 102)
               (records . [((type . "event")
                            (event . ((type . "compaction/start") (seq . 101)
                                      (data . ((compactionId . "c") (turn . 1))))))
                           ((type . "event")
                            (event . ((type . "compaction/end") (seq . 102)
                                      (data . ((compactionId . "c") (turn . 1))))))])))
            (ert-info ((format "%s" "failed-reconnect-retains-running-after-compaction"))
              (should dsh-emacs--ml-busy)
              (should (string-match-p "Deep diving" (dsh-emacs--ml-busy-indicator))))
            (dsh-emacs-events--dispatch-event
             (current-buffer)
             '((type . "turn/end") (seq . 103) (data . ((turn . 1)))))
            (ert-info ((format "%s" "recovered-connection-still-obeys-turn-end"))
              (should (null dsh-emacs--ml-busy))
              (should (string-empty-p (dsh-emacs--ml-busy-indicator)))))
        (dsh-emacs-events-disconnect (current-buffer))))))

;; Exercise the command, not just connect: a preliminary disconnect loses
;; liveness before connect can save it, and a bounded snapshot cannot repair it.
(ert-deftest dsh-emacs-test-events-manual-refresh-preserves-running-case ()
  :tags '(dsh-unit)
  (dolist (running '(t nil))
    (dolist (fail-connect '(nil t))
      (let ((dsh-emacs--sessions
             (list (dsh-protocol-session--from-alist
                    '((sessionId . "manual-refresh") (running . t))))))
        (with-temp-buffer
          (dsh-emacs-mode)
          (setq-local dsh-emacs--buffer-session "manual-refresh"
                      dsh-emacs--anchor-seq 100)
          (dsh-emacs--ml-busy-set running)
          (unwind-protect
              (cl-letf (((symbol-function 'dsh-emacs-server-ensure) #'ignore)
                        ((symbol-function 'open-network-stream)
                         (lambda (&rest _)
                           (if fail-connect (error "Test connection failure")
                             :fake-proc)))
                        ((symbol-function 'set-process-query-on-exit-flag) #'ignore)
                        ((symbol-function 'set-process-coding-system) #'ignore)
                        ((symbol-function 'process-put) #'ignore)
                        ((symbol-function 'set-process-filter) #'ignore)
                        ((symbol-function 'set-process-sentinel) #'ignore)
                        ((symbol-function 'dsh-emacs-events--schedule-reconnect)
                         #'ignore))
                (dotimes (_ 2)
                  (dsh-emacs-refresh)
                  (dsh-emacs-events--health-stop)
                  (ert-info ((format "running=%S fail-connect=%S"
                                     running fail-connect))
                    (should (eq dsh-emacs--ml-busy running))))
                ;; Neither old history nor a lagging running cache may
                ;; overwrite the last observed live turn state.
                (dsh-emacs-events--follow-snapshot
                 (current-buffer)
                 '((cursor . 101) (hasMore . t)
                   (records . [((type . "event")
                                (event . ((type . "step/start") (seq . 101)
                                          (data . ((turn . 1) (step . 20))))))])))
                (should (eq dsh-emacs--ml-busy running))
                (should (eq (not (string-empty-p
                                 (dsh-emacs--ml-busy-indicator))) running))
                (dsh-emacs-events--dispatch-event
                 (current-buffer)
                 '((type . "turn/end") (seq . 102) (data . ((turn . 1)))))
                (should-not dsh-emacs--ml-busy)
                (should (string-empty-p (dsh-emacs--ml-busy-indicator))))
            (dsh-emacs-events-disconnect (current-buffer))
            (when-let* ((transport (get-buffer " *dsh-events:manual-refresh*")))
              (kill-buffer transport))))))))

;; --- Test 98h: reconnect while idle/settled does not light busy --- no ghost
;; spinner may appear ---
(ert-deftest dsh-emacs-test-events-reconnect-idle-keeps-busy-off ()
  :tags '(dsh-unit)
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
          (ert-info ((format "%s" "reconnect-idle-keeps-busy-off"))
            (should (null dsh-emacs--ml-busy))))
      (kill-buffer buf))))

;; A fresh client has no local busy flag.  A long running turn's opening
;; history window can omit turn/start, so connection must seed from its own
;; cached session row.  Later turn/end remains authoritative even before the
;; separate host cache receives its idle update.
(ert-deftest dsh-emacs-test-events-fresh-connect-restores-running-case ()
  :tags '(dsh-unit)
  (dolist (running '(t nil))
    (let ((dsh-emacs--sessions
           (list (dsh-protocol-session--from-alist
                  `((sessionId . "resumed-running") (running . ,running)))))
          (dsh-emacs--current-session "resumed-running"))
      (with-temp-buffer
        (dsh-emacs-mode)
        (setq-local dsh-emacs--buffer-session "resumed-running")
        (unwind-protect
            (cl-letf (((symbol-function 'open-network-stream)
                       (lambda (&rest _) :fake-proc))
                      ((symbol-function 'set-process-query-on-exit-flag) #'ignore)
                      ((symbol-function 'set-process-coding-system) #'ignore)
                      ((symbol-function 'process-put) #'ignore)
                      ((symbol-function 'set-process-filter) #'ignore)
                      ((symbol-function 'set-process-sentinel) #'ignore))
              (dsh-emacs-events-connect (current-buffer))
              (dsh-emacs-events--health-stop)
              (dsh-emacs-events--follow-snapshot
               (current-buffer)
               '((cursor . 100) (hasMore . t)
                 (records . [((type . "event")
                              (event . ((type . "step/start") (seq . 100)
                                        (data . ((turn . 1) (step . 20))))))])))
              (ert-info ((format "%s" (format "fresh-connect-restores-running-%s" running)))
                (should (eq dsh-emacs--ml-busy running))
                (should (eq (not (string-empty-p (dsh-emacs--ml-busy-indicator))) running))
                (should (or (not (featurep 'motion-line))
                            (eq (and (motion-line-playing-p 'dsh-running) t) running))))
              (dsh-emacs-render-event '((type . "turn/end") (seq . 101)))
              (ert-info ((format "%s" (format "resumed-turn-end-clears-running-%s" running)))
                (should (null dsh-emacs--ml-busy))
                (should (string-empty-p (dsh-emacs--ml-busy-indicator))))
              ;; A global selection must never light another chat's indicator.
              (setq-local dsh-emacs--buffer-session "unlisted-session")
              (dsh-emacs-events-connect (current-buffer))
              (dsh-emacs-events--health-stop)
              (ert-info ((format "%s" (format "fresh-connect-isolates-running-%s" running)))
                (should (null dsh-emacs--ml-busy))))
          (dsh-emacs-events-disconnect (current-buffer)))))))

;; A host status can lag the transcript on the other socket.  Once this
;; buffer has observed turn/end, reconnect must not resurrect it from cache.
(ert-deftest dsh-emacs-test-events-reconnect-keeps-confirmed-turn-end-over-stale-cache ()
  :tags '(dsh-unit)
  (let ((dsh-emacs--sessions
         (list (dsh-protocol-session--from-alist
                '((sessionId . "settled-reconnect") (running . t))))))
    (with-temp-buffer
      (dsh-emacs-mode)
      (setq-local dsh-emacs--buffer-session "settled-reconnect")
      (dsh-emacs-render-event '((type . "turn/start") (seq . 1)))
      (dsh-emacs-render-event '((type . "turn/end") (seq . 2)))
      (unwind-protect
          (cl-letf (((symbol-function 'open-network-stream)
                     (lambda (&rest _) :fake-proc))
                    ((symbol-function 'set-process-query-on-exit-flag) #'ignore)
                    ((symbol-function 'set-process-coding-system) #'ignore)
                    ((symbol-function 'process-put) #'ignore)
                    ((symbol-function 'set-process-filter) #'ignore)
                    ((symbol-function 'set-process-sentinel) #'ignore))
            (dsh-emacs-events-connect (current-buffer))
            (dsh-emacs-events--health-stop)
            (ert-info ((format "%s" "reconnect-keeps-confirmed-turn-end-over-stale-cache"))
              (should (null dsh-emacs--ml-busy)))
            (dsh-emacs-events--follow-snapshot
             (current-buffer)
             '((cursor . 2)
               (records . [((type . "event")
                            (event . ((type . "turn/start") (seq . 1))))
                           ((type . "event")
                            (event . ((type . "turn/end") (seq . 2))))])))
            (dsh-emacs-events--host-session-status "settled-reconnect" nil)
            (ert-info ((format "%s" "reconnect-deduped-completion-stays-idle"))
              (should (null dsh-emacs--ml-busy))
              (should (string-empty-p (dsh-emacs--ml-busy-indicator)))))
        (dsh-emacs-events-disconnect (current-buffer))))))

;; --- Test 98j: event stream decides busy --- turn/start lights it up,
;; turn/end turns it off ---
;; When reopening a session / refetching history, an unclosed turn
;; (turn/start with no turn/end) must also light the spinner.
(ert-deftest dsh-emacs-test-events-turn-start-lights-busy ()
  :tags '(dsh-unit)
  (let ((buf (generate-new-buffer " *dsh-turn-open*")))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-mode)
          (dsh-emacs--ml-busy-clear)
          (dsh-emacs-render-event '((type . "turn/start") (seq . 1)))
          (ert-info ((format "%s" "turn-start-lights-busy"))
            (should (and dsh-emacs--ml-busy
                         (not (string-empty-p (dsh-emacs--ml-busy-indicator))))))
          (dsh-emacs-render-event '((type . "turn/end") (seq . 2)))
          (ert-info ((format "%s" "turn-end-extinguishes-busy"))
            (should (null dsh-emacs--ml-busy))))
      (kill-buffer buf))))

;; --- Test 98j2: the opening follow snapshot completes even while input is
;; --- pending --- a dropped tail wedges the mode-line spinner ---
;; Regression: the snapshot seed ran inside `while-no-input', whose early exit
;; drops the whole batch whenever input is pending (fast typing while a session
;; opens from the list).  The snapshot caller still advanced
;; `dsh-emacs--anchor-seq' to the snapshot cursor afterwards, so the dropped
;; records were never re-delivered — a dropped trailing `turn/end' left the
;; mode-line running animation lit with no later event to stop it.
(ert-deftest dsh-emacs-test-events-snapshot-completes-with-input-pending ()
  :tags '(dsh-unit)
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
          (ert-info ((format "%s" "snapshot-completes-with-input-pending"))
            (should (string-match "hello" (buffer-substring-no-properties
                                           (point-min) (point-max)))))
          (ert-info ((format "%s" "snapshot-turn-end-extinguishes-busy"))
            (should (null dsh-emacs--ml-busy)))
          (ert-info ((format "%s" "snapshot-anchor-lands-on-cursor"))
            (should (= 3 dsh-emacs--anchor-seq)))
          (dsh-emacs--ml-busy-clear))
      (remhash "sess-snapshot-input" dsh-emacs--input-history-by-session)
      (kill-buffer buf))))

(ert-deftest dsh-emacs-test-events-multi-session-busy-a-lit ()
  :tags '(dsh-unit)
  (let ((buf-a (generate-new-buffer " *dsh-multi-a*"))
        (buf-b (generate-new-buffer " *dsh-multi-b*")))
    (unwind-protect
        (progn
          (with-current-buffer buf-a
            (dsh-emacs-mode)
            (dsh-emacs--ml-busy-set t)
            (ert-info ((format "%s" "multi-session-busy-a-lit"))
              (should (and dsh-emacs--ml-busy (not (string-empty-p (dsh-emacs--ml-busy-indicator)))))))
          (with-current-buffer buf-b
            (dsh-emacs-mode)
            (dsh-emacs--ml-busy-set t)
            (ert-info ((format "%s" "multi-session-busy-b-lit"))
              (should (and dsh-emacs--ml-busy (not (string-empty-p (dsh-emacs--ml-busy-indicator))))))
            ;; B ends: only B's own spinner goes dark
            (dsh-emacs--ml-busy-set nil)
            (ert-info ((format "%s" "multi-session-busy-b-cleared"))
              (should (null dsh-emacs--ml-busy))))
          ;; Key point: B's turn/end must not cut off A's spinner too
          (with-current-buffer buf-a
            (ert-info ((format "%s" "multi-session-busy-a-survives-b-clear"))
              (should (and dsh-emacs--ml-busy (not (string-empty-p (dsh-emacs--ml-busy-indicator))))))
            (dsh-emacs--ml-busy-clear))
          ;; command rows: same-key optimistic rows stay per-buffer
          (with-current-buffer buf-a
            (setq dsh-emacs--show-commands t
                  dsh-emacs--command-blocks (make-hash-table :test 'equal)
                  dsh-emacs--pending-command nil)
            (dsh-emacs-render-command-optimistic "/compact")
            (ert-info ((format "%s" "multi-session-command-row-a"))
              (should (gethash "pending-compact" dsh-emacs--command-blocks))))
          (with-current-buffer buf-b
            (setq dsh-emacs--show-commands t
                  dsh-emacs--command-blocks (make-hash-table :test 'equal)
                  dsh-emacs--pending-command nil)
            (dsh-emacs-render-command-optimistic "/compact")
            (ert-info ((format "%s" "multi-session-command-row-b"))
              (should (gethash "pending-compact" dsh-emacs--command-blocks)))
            (setq dsh-emacs--command-blocks (make-hash-table :test 'equal)))
          (with-current-buffer buf-a
            (ert-info ((format "%s" "multi-session-command-row-a-survives-b"))
              (should (gethash "pending-compact" dsh-emacs--command-blocks)))))
      (kill-buffer buf-a)
      (kill-buffer buf-b))))

;; --- Test 98l: optimistic user echo is not duplicated --- mux delivers
;; user/message before the HTTP callback ---
;; Regression: pending was originally registered in session/prompt's HTTP
;; callback, but the mux stream can deliver the same user/message first
;; (pending is empty then → one real message is rendered), and the callback
;; then renders the optimistic echo again → "occasionally two user input
;; messages are rendered". Fix: pending is registered before the RPC is
;; sent, so an event arriving at any moment can be consumed by the dedup
;; gate.
(ert-deftest dsh-emacs-test-events-user-echo-no-duplicate-when-stream-wins ()
  :tags '(dsh-unit)
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
            (dsh-emacs--submit-plain "race-msg" :history-recorded t))
          (let ((n (1- (length (split-string
                                (buffer-substring-no-properties (point-min)
                                                                (point-max))
                                "race-msg")))))
            (ert-info ((format "%s" "user-echo-no-duplicate-when-stream-wins"))
              (should (= 1 n))))
          (ert-info ((format "%s" "user-pending-consumed-by-stream-event"))
            (should (null dsh-emacs--pending-user-messages)))
          (dsh-emacs--ml-busy-clear)
          (dsh-emacs-events--watchdog-stop))
      (kill-buffer buf))))

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
(ert-deftest dsh-emacs-test-events-fast-run-end-before-callback-keeps-spinner-off ()
  :tags '(dsh-unit)
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
            (dsh-emacs--submit-plain "fast" :history-recorded t))
          (ert-info ((format "%s" "fast-run-end-before-callback-keeps-spinner-off"))
            (should (null dsh-emacs--ml-busy))
            (should (string-empty-p (dsh-emacs--ml-busy-indicator))))
          (dsh-emacs-events--watchdog-stop))
      (kill-buffer buf))))

;; Control: while the turn/end has NOT arrived, the callback still lights
;; the spinner — a pending run must always show progress.
(ert-deftest dsh-emacs-test-events-pending-run-callback-lights-spinner ()
  :tags '(dsh-unit)
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
            (dsh-emacs--submit-plain "normal" :history-recorded t))
          (ert-info ((format "%s" "pending-run-callback-lights-spinner"))
            (should (and dsh-emacs--ml-busy (not (string-empty-p (dsh-emacs--ml-busy-indicator))))))
          (dsh-emacs--ml-busy-clear)
          (dsh-emacs-events--watchdog-stop))
      (kill-buffer buf))))

(defun dsh-emacs-test--buffer-copies (needle)
  "Count non-overlapping occurrences of NEEDLE in the current buffer."
  (let ((n 0) (text (buffer-substring-no-properties (point-min) (point-max))))
    (while (string-search needle text)
      (setq n (1+ n)
            text (substring text (+ (string-search needle text)
                                    (length needle)))))
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
(ert-deftest dsh-emacs-test-events-replay-live-pass-renders-once ()
  :tags '(dsh-unit)
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
          (ert-info ((format "%s" "replay-live-pass-renders-once"))
            (should (= 1 (dsh-emacs-test--buffer-copies "replay-msg")))
            (should (= 1 (dsh-emacs-test--buffer-copies "replay-reply")))
            (should (= 2 dsh-emacs--anchor-seq)))
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
          (ert-info ((format "%s" "reconnect-replay-does-not-duplicate"))
            (should (= 1 (dsh-emacs-test--buffer-copies "replay-msg")))
            (should (= 1 (dsh-emacs-test--buffer-copies "replay-reply")))
            (should (= 2 dsh-emacs--anchor-seq)))
          ;; Same gate on the streaming path: a replayed assistant/chunk must not
          ;; open a second stream
          (dsh-emacs-events--dispatch-event
           chat '((type . "assistant/chunk") (seq . 3)
                  (data . ((turn . 2) (step . 1)
                           (chunk . ((type . "text-delta") (index . 1)
                                     (text . "replay-chunk")))))))
          (ert-info ((format "%s" "replay-chunk-live-renders-once"))
            (should (= 1 (dsh-emacs-test--buffer-copies "replay-chunk")))
            (should (= 3 dsh-emacs--anchor-seq)))
          (dsh-emacs-events--dispatch-event
           chat '((type . "assistant/chunk") (seq . 3)
                  (data . ((turn . 2) (step . 1)
                           (chunk . ((type . "text-delta") (index . 1)
                                     (text . "replay-chunk")))))))
          (ert-info ((format "%s" "replay-chunk-replay-does-not-duplicate"))
            (should (= 1 (dsh-emacs-test--buffer-copies "replay-chunk")))
            (should (= 3 dsh-emacs--anchor-seq)))
          ;; Fill the gap: events produced while disconnected (seq > anchor) are
          ;; rendered once
          (dsh-emacs-events--dispatch-event
           chat '((type . "user/message") (seq . 4)
                  (data . ((content . [((type . "text")
                                        (text . "during-outage"))])))))
          (ert-info ((format "%s" "reconnect-catchup-renders-new-events"))
            (should (= 1 (dsh-emacs-test--buffer-copies "during-outage")))
            (should (= 4 dsh-emacs--anchor-seq))))
      (when (buffer-live-p chat) (kill-buffer chat)))))

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
(ert-deftest dsh-emacs-test-events-snapshot-reseed-no-duplicate ()
  :tags '(dsh-unit)
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
          (ert-info ((format "%s" "snapshot-reseed-no-duplicate"))
            (should (= 0 (dsh-emacs-test--buffer-copies "reseed-old-msg")))
            (should (= 0 (dsh-emacs-test--buffer-copies "reseed-old-reply")))
            (should (= 6 dsh-emacs--anchor-seq)))
          ;; New events produced while disconnected (seq > anchor) are backfilled
          ;; once via the live path.
          (dsh-emacs-events--dispatch-event
           chat '((type . "user/message") (seq . 7)
                  (data . ((content . [((type . "text")
                                        (text . "reseed-catchup"))])))))
          (ert-info ((format "%s" "snapshot-reseed-catchup-renders-new"))
            (should (= 1 (dsh-emacs-test--buffer-copies "reseed-catchup")))
            (should (= 7 dsh-emacs--anchor-seq))))
      (when (buffer-live-p chat) (kill-buffer chat)))))

;; --- Regression: when host normalizes the sent canonical session mention
;; to `@label' on echo, the optimistic pending entry must still be consumed
;; (otherwise the same message is rendered twice, once canonical and once
;; as label)
(ert-deftest dsh-emacs-test-events-consume-pending-matches-normalized-session-echo ()
  :tags '(dsh-unit)
  (let ((canon "@[实现dsh web的@指令](dsh-session:InNlc3Npb24tYWU0NGZlYTUtYmY2Ny00YmE5LWIzZGEtNTk5OTAzODMyOTMzIg)")
        (echo "@实现dsh web的@指令 summary"))
    (let ((dsh-emacs--pending-user-messages (list (concat canon " summary"))))
      (ert-info ((format "%s" "consume-pending-matches-normalized-session-echo"))
        (should (and (dsh-emacs-render--consume-pending-user-message
                      `((type . "user/message")
                        (data . ((content . [((type . "text") (text . ,echo))])))))
                     (null dsh-emacs--pending-user-messages)))))))

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
(ert-deftest dsh-emacs-test-events-connect-throw-is-contained ()
  :tags '(dsh-unit)
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
                (ert-info ((format "%s" "connect-throw-is-contained"))
                  (should (null threw)))
                (ert-info ((format "%s" "connect-throw-schedules-reconnect"))
                  (should (timerp dsh-emacs--event-reconnect-timer)))))))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (when (timerp dsh-emacs--event-reconnect-timer)
            (cancel-timer dsh-emacs--event-reconnect-timer))
          (setq dsh-emacs--event-reconnect-timer nil))
        (kill-buffer buf)))))

;; --- Test 98m: turn/end with reason.kind=error (model failure such as
;; 429) renders a visible error line ---
(ert-deftest dsh-emacs-test-events-turn-error-lights-busy-before-end ()
  :tags '(dsh-unit)
  (let ((buf (generate-new-buffer " *dsh-turn-error*")))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-mode)
          (dsh-emacs--ml-busy-clear)
          (dsh-emacs-render-event
           '((type . "turn/start") (seq . 1) (data . ((turn . 1)))))
          (ert-info ((format "%s" "turn-error-lights-busy-before-end"))
            (should (and dsh-emacs--ml-busy (not (string-empty-p (dsh-emacs--ml-busy-indicator))))))
          ;; Model failure: turn/end + data.reason.kind = "error"
          (dsh-emacs-render-event
           '((type . "turn/end") (seq . 2) (data . ((turn . 1)
                                                    (reason . ((kind . "error")
                                                               (error . ((code . "insufficient_quota")
                                                                         (message . "Allocated quota exceeded")))))))))
          (let ((text (buffer-substring-no-properties (point-min) (point-max))))
            (ert-info ((format "%s" "turn-error-renders-visible-row"))
              (should (and (null dsh-emacs--ml-busy)
                           (string-match-p "insufficient_quota" text)
                           (string-match-p "Allocated quota exceeded" text))))))
      (kill-buffer buf))))

;; --- Test 98n: a successful / interrupted turn/end does not render an
;; error line ---
(ert-deftest dsh-emacs-test-events-turn-success-no-error-row ()
  :tags '(dsh-unit)
  (let ((buf (generate-new-buffer " *dsh-turn-ok*")))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-mode)
          (dsh-emacs-render-event
           '((type . "turn/end") (seq . 1)
             (data . ((turn . 1) (reason . ((kind . "completed")))))))
          ;; Successful end: no error line
          (ert-info ((format "%s" "turn-success-no-error-row"))
            (should (not (string-match-p "Model error"
                                         (buffer-substring-no-properties
                                          (point-min) (point-max))))))
          ;; Interrupted (reason.kind=cancelled): likewise no error line
          (dsh-emacs-render-event
           '((type . "turn/end") (seq . 2)
             (data . ((turn . 2) (reason . ((kind . "cancelled")))))))
          (ert-info ((format "%s" "turn-cancelled-no-error-row"))
            (should (not (string-match-p "Model error"
                                         (buffer-substring-no-properties
                                          (point-min) (point-max)))))))
      (kill-buffer buf))))

;; An idle application stream is healthy when the WebSocket answers pings.
(ert-deftest dsh-emacs-test-events-watchdog-probes-before-disconnecting ()
  :tags '(dsh-unit)
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
            (ert-info ((format "%s" "watchdog-probes-before-disconnecting"))
              (should sent)
              (should (not deleted))
              (should (= 9 (or (car (and sent (dsh-emacs-events--read-frame sent))) -1))))
            (when sent
              (let ((payload (nth 2 (dsh-emacs-events--read-frame sent))))
                (process-put process 'dsh-emacs-event-input
                             (dsh-emacs-events--frame 10 "wrong-probe"))
                (dsh-emacs-events--consume-frames process)
                (ert-info ((format "%s" "watchdog-ignores-unmatched-pong"))
                  (should dsh-emacs--ws-probe-inflight))
                (process-put process 'dsh-emacs-event-input
                             (dsh-emacs-events--frame 10 payload))
                (dsh-emacs-events--consume-frames process)
                (ert-info ((format "%s" "watchdog-pong-clears-probe"))
                  (should (not dsh-emacs--ws-probe-inflight)))))
            (setq dsh-emacs--ws-probe-inflight "unanswered"
                  dsh-emacs--ws-last-probe-time 90
                  deleted nil)
            (cl-letf (((symbol-function 'float-time) (lambda (&rest _) 100.0))
                      ((symbol-function 'delete-process)
                       (lambda (_process) (setq deleted t))))
              (dsh-emacs-events--watchdog-tick (current-buffer)))
            (ert-info ((format "%s" "watchdog-disconnects-unanswered-probe"))
              (should deleted)))
        (delete-process process)))))

;; A write can discover a broken connection after the watchdog's live check.
(ert-deftest dsh-emacs-test-events-watchdog-write-error-case-recovers ()
  :tags '(dsh-unit)
  (dolist (closed-before-error '(nil t))
    (with-temp-buffer
      (let* ((owner (current-buffer))
             (process (make-pipe-process :name "dsh-watchdog-write-error"
                                         :buffer owner :noquery t))
             (watchdog (run-at-time 3600 1 #'ignore))
             (health (run-at-time 3600 1 #'ignore))
             (reads (run-at-time 3600 nil #'ignore))
             (writes 0) (reconnects 0) (closed-streams 0)
             escaped reported)
        (unwind-protect
            (progn
              (setq-local dsh-emacs--event-process process
                          dsh-emacs--event-ready t
                          dsh-emacs--ml-busy t
                          dsh-emacs--ws-last-event-time 0
                          dsh-emacs--ws-last-probe-time nil
                          dsh-emacs--ws-probe-inflight nil
                          dsh-emacs--ws-watchdog-timer watchdog
                          dsh-emacs--event-connect-timer health)
              (process-put process 'dsh-emacs-chat-buffer owner)
              (process-put process 'dsh-emacs-event-handshake-sent t)
              (process-put process 'dsh-emacs-event-read-timer reads)
              (process-put process 'dsh-emacs-event-read-filter #'ignore)
              (process-put process 'dsh-emacs-stream-handlers
                           (list (cons "test" (cons "test"
                                                    (lambda (value)
                                                      (unless value
                                                        (cl-incf closed-streams)))))))
              ;; Cover a pending sentinel as well as deletion invoking it inline.
              (unless closed-before-error
                (set-process-sentinel process #'dsh-emacs-events--sentinel))
              (cl-letf (((symbol-function 'process-send-string)
                         (lambda (proc _data)
                           (cl-incf writes)
                           (when closed-before-error (delete-process proc))
                           (error "Process %s no longer connected to pipe; closed it"
                                  (process-name proc))))
                        ((symbol-function 'dsh-emacs-events--schedule-reconnect)
                         (lambda () (cl-incf reconnects)))
                        ((symbol-function 'message)
                         (lambda (format-string &rest args)
                           (push (apply #'format format-string args) reported))))
                (condition-case err
                    (with-temp-buffer
                      (dsh-emacs-events--watchdog-tick owner))
                  (error (setq escaped err)))
                (ert-info ((format "%s" (format "watchdog-write-error-%s-recovers" closed-before-error)))
                  (should (null escaped))
                  (should (= writes 1))
                  (should (= reconnects 1))
                  (should (= closed-streams 1))
                  (should (not (process-live-p process)))
                  (should (null dsh-emacs--event-process))
                  (should (null dsh-emacs--event-ready))
                  (should (null dsh-emacs--ws-watchdog-timer))
                  (should (null dsh-emacs--event-connect-timer))
                  (should (null (process-get process 'dsh-emacs-event-read-timer)))
                  (should (null (process-get process 'dsh-emacs-event-read-filter)))
                  (should (not (memq watchdog timer-list)))
                  (should (not (memq health timer-list)))
                  (should (not (memq reads timer-list)))
                  (should (= (length reported) 1))
                  (should (string-match-p "no longer connected to pipe" (or (car reported) ""))))
                ;; A late sentinel or queued tick must not repeat cleanup/writes.
                (dsh-emacs-events--sentinel process "closed")
                (dsh-emacs-events--watchdog-tick owner)
                (ert-info ((format "%s" (format "watchdog-write-error-%s-cleans-once" closed-before-error)))
                  (should (= writes 1))
                  (should (= reconnects 1))
                  (should (= closed-streams 1)))))
          (set-process-sentinel process #'ignore)
          (delete-process process)
          (cancel-timer watchdog)
          (cancel-timer health)
          (cancel-timer reads))))))

;; A chat socket receives its first frame immediately, then batches reads.
(ert-deftest dsh-emacs-test-events-socket-read-batch-case-first ()
  :tags '(dsh-unit)
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
                (ert-info ((format "%s" (format "socket-read-batch-%s-first" ending)))
                  (should (equal received '("first")))
                  (should (eq (process-filter process) t))
                  (should (eq (process-get process 'dsh-emacs-event-read-filter) filter))
                  (should (timerp timer))
                  (should (equal (process-get process 'dsh-emacs-event-input)
                                 (substring frame 0 3))))
                (pcase ending
                  ((or 'resume 'alternate)
                   (when (timerp timer)
                     ;; Timer callbacks need no current-buffer assumption.
                     (with-temp-buffer
                       (apply (timer--function timer) (timer--args timer))))
                   (ert-info ((format "%s" (format "socket-read-batch-%s-restores-filter" ending)))
                     (should (eq (process-filter process) filter))
                     (should (null (process-get process 'dsh-emacs-event-read-timer)))
                     (should (null (process-get process 'dsh-emacs-event-read-filter)))
                     (should (not (memq timer timer-list))))
                   (dsh-emacs-events--filter
                    process (concat (substring frame 3)
                                    (dsh-emacs-events--frame 1 "third")))
                   (ert-info ((format "%s" (format "socket-read-batch-%s-keeps-fragments-and-order"
                                                   ending)))
                     (should (equal (reverse received) '("first" "second" "third")))
                     (should (timerp (process-get process 'dsh-emacs-event-read-timer)))))
                  ('disconnect (dsh-emacs-events-disconnect owner))
                  ('lost
                   (cl-letf (((symbol-function 'dsh-emacs-events--schedule-reconnect)
                              #'ignore))
                     (dsh-emacs-events--lost process))))
                (unless (memq ending '(resume alternate))
                  (ert-info ((format "%s" (format "socket-read-batch-%s-cleans-timer" ending)))
                    (should (null (process-get process 'dsh-emacs-event-read-timer)))
                    (should (null (process-get process 'dsh-emacs-event-read-filter)))
                    (should (not (memq timer timer-list)))))))
          (when-let* ((pending (process-get process 'dsh-emacs-event-read-timer)))
            (cancel-timer pending))
          (when (timerp timer) (cancel-timer timer))
          (delete-process process))))))

;; Host waterfalls keep their input path immediately readable.
(ert-deftest dsh-emacs-test-events-host-stream-does-not-pause-for-chat-batching ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (let ((process (make-pipe-process :name "dsh-host-read-test"
                                      :buffer (current-buffer) :noquery t)))
      (unwind-protect
          (progn
            (process-put process 'dsh-emacs-host-stream t)
            (process-put process 'dsh-emacs-event-ready t)
            (set-process-filter process dsh-emacs-events--filter-fn)
            (dsh-emacs-events--filter process "")
            (ert-info ((format "%s" "host-stream-does-not-pause-for-chat-batching"))
              (should (eq (process-filter process) dsh-emacs-events--filter-fn))
              (should (null (process-get process 'dsh-emacs-event-read-timer)))))
        (delete-process process)))))

;; Cursor parsing retains a partial tail and handles masks/extended lengths.
(ert-deftest dsh-emacs-test-events-websocket-cursor-roundtrip-case ()
  :tags '(dsh-unit)
  (dolist (size '(0 3 126 65536))
    (let* ((payload (make-string size ?x))
           (wire (dsh-emacs-events--frame 1 payload))
           (input (concat "prefix" wire wire))
           (first (dsh-emacs-events--read-frame input 6))
           (second (dsh-emacs-events--read-frame input (nth 3 first))))
      (ert-info ((format "%s" (format "websocket-cursor-roundtrip-%d" size)))
        (should (= (nth 0 first) 1))
        (should (nth 1 first))
        (should (equal (nth 2 first) payload))
        (should (equal (nth 2 second) payload))
        (should (= (nth 3 second) (length input)))
        (should (null (dsh-emacs-events--read-frame (substring wire 0 -1))))))))

(ert-deftest dsh-emacs-test-events-websocket-consume-preserves-partial-tail ()
  :tags '(dsh-unit)
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
            (ert-info ((format "%s" "websocket-consume-preserves-partial-tail"))
              (should (equal delivered '("one")))
              (should (equal (process-get process 'dsh-emacs-event-input)
                             (substring second 0 3))))
            (process-put process 'dsh-emacs-event-input
                         (concat (process-get process 'dsh-emacs-event-input)
                                 (substring second 3)))
            (dsh-emacs-events--consume-frames process)
            (ert-info ((format "%s" "websocket-consume-completes-partial-tail"))
              (should (equal delivered '("two" "one")))
              (should (equal (process-get process 'dsh-emacs-event-input) ""))))
        (delete-process process)))))

(ert-deftest dsh-emacs-test-events-websocket-reentrant-drain-keeps-partial-input ()
  :tags '(dsh-unit)
  (dolist (fail '(nil t))
    (with-temp-buffer
      (let* ((process (make-pipe-process :name "dsh-reentrant-frames"
                                         :buffer (current-buffer) :noquery t))
             (first (concat (unibyte-string 129 3) "one"))
             (second (concat (unibyte-string 129 3) "two"))
             (third (concat (unibyte-string 129 5) "three"))
             delivered messages injected)
        (unwind-protect
            (cl-letf (((symbol-function 'dsh-emacs-events--dispatch-json)
                       (lambda (_process json)
                         (push json delivered)
                         (unless injected
                           (setq injected t)
                           (dsh-emacs-events--filter process (substring third 0 3))
                           (when fail (error "Dispatch failed")))))
                      ((symbol-function 'message)
                       (lambda (format &rest args)
                         (push (apply #'format format args) messages))))
              (process-put process 'dsh-emacs-event-ready t)
              (dsh-emacs-events--filter process (concat first second))
              (ert-info ((format "Failed dispatch=%s releases the consumer" fail))
                (should-not (process-get process 'dsh-emacs-event-draining))
                (should (equal (reverse delivered) (if fail '("one") '("one" "two"))))
                (should (equal (process-get process 'dsh-emacs-event-input)
                               (concat (and fail second) (substring third 0 3))))
                (should (= (length messages) (if fail 1 0))))
              (dsh-emacs-events--filter process (substring third 3))
              (should (equal (reverse delivered) '("one" "two" "three")))
              (should (equal (process-get process 'dsh-emacs-event-input) ""))
              (should-not (process-get process 'dsh-emacs-event-draining)))
          (dsh-emacs-events--cancel-read-timer process)
          (delete-process process))))))

;; A dispatch can write (pong, rebaseline) after the peer already closed the
;; socket; that expected teardown race must not surface as a frame error.
(ert-deftest dsh-emacs-test-events-frame-error-after-close-is-silent ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (let* ((process (make-pipe-process :name "dsh-frame-closed-test"
                                       :buffer (current-buffer) :noquery t))
           (messages nil)
           (lost 0))
      (unwind-protect
          (progn
            (process-put process 'dsh-emacs-event-ready t)
            (cl-letf (((symbol-function 'dsh-emacs-events--dispatch-json)
                       (lambda (proc _json)
                         (delete-process proc)
                         (error "Process %s no longer connected to pipe; closed it"
                                (process-name proc))))
                      ((symbol-function 'dsh-emacs-events--lost)
                       (lambda (_process) (cl-incf lost)))
                      ((symbol-function 'message)
                       (lambda (format-string &rest args)
                         (push (apply #'format format-string args) messages))))
              (process-put process 'dsh-emacs-event-input
                           (dsh-emacs-events--frame 1 "{}"))
              (dsh-emacs-events--consume-frames process))
            (ert-info ((format "%s" "frame-error-after-close-is-silent"))
              (should (= lost 1))
              (should-not messages)
              (should-not (process-live-p process))))
        (delete-process process)))))

(ert-deftest dsh-emacs-test-events-follow-snapshot-serializes-reentrant-input ()
  :tags '(dsh-unit)
  (dolist (arrival '(snapshot tail newer))
    (with-temp-buffer
      (dsh-emacs-mode)
      (setq-local dsh-emacs--buffer-session "reentrant-history")
      (let* ((owner (current-buffer))
             (process (make-pipe-process :name "dsh-reentrant-history"
                                         :buffer owner :noquery t))
             (dsh-emacs-fold-work-details nil)
             (dsh-emacs-reply-footer-items '(copy fork))
             (dsh-emacs--chat-buffers (make-hash-table :test 'equal))
             (dsh-emacs--input-history-by-session (make-hash-table :test 'equal))
             (dsh-emacs--subagent-catalogs (make-hash-table :test 'equal))
             (events
              (append
               (cl-loop for seq from 1 to 5
                        collect `((type . "step/end") (seq . ,seq)
                                  (data . ((turn . 1) (step . 1)))))
               '(((type . "assistant/message") (seq . 6)
                  (data . ((turn . 1) (step . 1)
                           (message . ((content . [((type . "reasoning")
                                                    (text . "Tail thought"))]))))))
                 ((type . "tool/call") (seq . 7)
                  (data . ((turn . 1) (step . 1) (callId . "first")
                           (name . "run_code") (arguments . "{}"))))
                 ((type . "tool/call") (seq . 8)
                  (data . ((turn . 1) (step . 1) (callId . "second")
                           (name . "run_code") (arguments . "{}"))))
                 ((type . "assistant/message") (seq . 9)
                  (data . ((turn . 1) (step . 2)
                           (message . ((content . [((type . "text")
                                                    (text . "FINAL-ONCE"))]))))))
                 ((type . "turn/end") (seq . 10)
                  (data . ((turn . 1) (reason . ((kind . "completed")))))))))
             (newer '((type . "assistant/message") (seq . 11)
                      (data . ((turn . 2) (step . 1)
                               (message . ((content . [((type . "text")
                                                        (text . "AFTER-SNAPSHOT"))])))))))
             (snapshot `((type . "snapshot") (cursor . 10)
                         (records . ,(vconcat
                                      (mapcar (lambda (event)
                                                `((type . "event") (event . ,event)))
                                              events)))))
             injected)
        (unwind-protect
            (cl-labels
                ((wire (value)
                   (dsh-emacs-events--frame
                    1 (dsh-protocol-write-json
                       `((type . "item") (streamId . "follow") (value . ,value))))))
              (process-put process 'dsh-emacs-chat-buffer owner)
              (process-put process 'dsh-emacs-follow-stream-id "follow")
              (process-put process 'dsh-emacs-event-ready t)
              (set-process-filter process dsh-emacs-events--filter-fn)
              (cl-letf (((symbol-function 'sit-for)
                         (lambda (&rest _)
                           (unless injected
                             (setq injected t)
                             ;; The read timer can fire while history yields.
                             (dsh-emacs-events--resume-reads process)
                             (dsh-emacs-events--filter
                              process
                              (concat
                               (pcase arrival
                                 ('snapshot (wire snapshot))
                                 ('tail
                                  (mapconcat
                                   (lambda (event)
                                     (wire `((type . "event") (event . ,event))))
                                   (nthcdr 5 events) "")))
                               (wire `((type . "event") (event . ,newer)))))))))
                (dsh-emacs-events--filter process (wire snapshot)))
              (ert-info ((format "Reentrant %s must wait for the snapshot" arrival))
                (should injected)
                (should (= (how-many "FINAL-ONCE" (point-min) (point-max)) 1))
                (should (= (how-many "Tail thought" (point-min) (point-max)) 1))
                (should (= (how-many "Run Code" (point-min) (point-max)) 2))
                (should (= (how-many "Copy" (point-min) (point-max)) 1))
                (should (= (how-many "AFTER-SNAPSHOT" (point-min) (point-max)) 1))
                (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                  (should (< (string-match "FINAL-ONCE" text)
                             (string-match "Copy" text)
                             (string-match "AFTER-SNAPSHOT" text))))
                (should (= dsh-emacs--anchor-seq 11))
                (should (equal (process-get process 'dsh-emacs-event-input) ""))))
          (dsh-emacs-events--cancel-read-timer process)
          (delete-process process))))))

;; --- Test 119: dsh 0.1.5 in-process assistant-stream frames drive live text ---
;; `assistant/chunk' is no longer a durable Session event (dsh 0.1.5); the
;; process-local `assistant-stream' frames are the only incremental source.
;; A follow client must opt in with `assistantStream: true' and consume
;; `chunk' frames through the incremental renderer.
(ert-deftest dsh-emacs-test-events-follow-assistant-stream-renders-live-text ()
  :tags '(dsh-unit)
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
             (frame . ((type . "chunk") (attemptId . "a1") (revision . 2)
                       (index . 0) (time . 5)
                       (chunk . ((type . "text-delta") (index . 1)
                                 (text . "live-")))))))
          (dsh-emacs-events--follow-item
           (current-buffer)
           '((type . "assistant-stream")
             (frame . ((type . "chunk") (attemptId . "a1") (revision . 3)
                       (index . 1) (time . 6)
                       (chunk . ((type . "text-delta") (index . 1)
                                 (text . "reply")))))))
          ;; Flush what the burst timer still owes so the assertion does not
          ;; race it.
          (dsh-emacs-render--flush-stream (current-buffer) t)
          (ert-info ((format "%s" "follow-assistant-stream-renders-live-text"))
            (should (string-match-p "live-reply" (buffer-string)))
            (should (= dsh-emacs--anchor-seq 7))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

;; --- Test 119b: assistant-stream frames with an old revision are dropped ---
;; Each emitted frame increments `revision'; a reconnect snapshot already
;; contains every frame through its baseline revision.
(ert-deftest dsh-emacs-test-events-follow-assistant-stream-drops-stale-revision ()
  :tags '(dsh-unit)
  (let ((buf (generate-new-buffer " *dsh-stream-revision*")))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-mode)
          (setq-local dsh-emacs--buffer-session "sess-frame")
          (dsh-emacs-events--assistant-stream-frame
           (current-buffer)
           '((type . "start") (revision . 2) (attemptId . "a1")
             (turn . 1) (step . 1)))
          (dsh-emacs-events--assistant-stream-frame
           (current-buffer)
           '((type . "chunk") (revision . 3) (attemptId . "a1") (index . 0)
             (chunk . ((type . "text-delta") (text . "new-gen")))))
          (dsh-emacs-events--assistant-stream-frame
           (current-buffer)
           '((type . "chunk") (revision . 3) (attemptId . "a1") (index . 0)
             (chunk . ((type . "text-delta") (text . "new-gen")))))
          (dsh-emacs-events--assistant-stream-frame
           (current-buffer)
           '((type . "chunk") (revision . 1) (attemptId . "a1") (index . 0)
             (chunk . ((type . "text-delta") (text . "stale-gen")))))
          (dsh-emacs-render--flush-stream (current-buffer) t)
          (ert-info ((format "%s" "follow-assistant-stream-drops-stale-revision"))
            (should (= 3 dsh-emacs--assistant-stream-revision))
            (should (= (how-many "new-gen" (point-min) (point-max)) 1))
            (should (string-match-p "new-gen" (buffer-string)))
            (should (not (string-match-p "stale-gen" (buffer-string))))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

;; --- Test 119c: the follow snapshot's assistantStream baseline continues an
;; in-progress stream ---
;; A reconnect that lands mid-attempt replays the accumulated process-local
;; stream in the opening snapshot, so the live body continues instead of
;; starting empty; the replay must not move the dedup anchor.
(ert-deftest dsh-emacs-test-events-follow-snapshot-seeds-active-assistant-stream ()
  :tags '(dsh-unit)
  (let ((buf (generate-new-buffer " *dsh-stream-baseline*")))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-mode)
          (setq-local dsh-emacs--buffer-session "sess-frame")
          ;; The disconnected socket already displayed a prefix. Re-baselining
          ;; replaces that prefix, including a Think block folded above it.
          (dsh-emacs-render-event
           '((type . "assistant/chunk")
             (data . ((turn . 2) (step . 1)
                      (chunk . ((type . "reasoning-delta") (index . 0)
                                (text . "baseline reasoning")))))))
          (dsh-emacs-render-event
           '((type . "assistant/chunk")
             (data . ((turn . 2) (step . 1)
                      (chunk . ((type . "text-delta") (index . 1)
                                (text . "half-")))))))
          (dsh-emacs-events--follow-snapshot
           (current-buffer)
           '((type . "snapshot")
             (cursor . 42)
             (records . [])
             (assistantStream . ((revision . 4)
                                 (activeAttempt . ((attemptId . "a1")
                                                   (startedAfterSeq . 40)
                                                   (turn . 2) (step . 1)
                                                   (nextIndex . 3)
                                                   (stream . [((type . "reasoning-chunks")
                                                               (time0 . 1) (dt . [])
                                                               (index . 0)
                                                               (texts . ["baseline reasoning"]))
                                                              ((type . "text-chunks")
                                                               (time0 . 2) (dt . [1])
                                                               (index . 1)
                                                               (texts . ["half-" "done"]))])))))))
          (dsh-emacs-render--flush-stream (current-buffer) t)
          (ert-info ((format "%s" "follow-snapshot-seeds-active-assistant-stream"))
            (should (= dsh-emacs--assistant-stream-revision 4))
            (should (equal (plist-get dsh-emacs--assistant-stream-attempt :position)
                           '(2 . 1)))
            (should (string-match-p "half-done" (buffer-string)))
            (should (= (how-many "half-" (point-min) (point-max)) 1))
            (should (= (how-many "Think" (point-min) (point-max)) 1))
            (should (= dsh-emacs--anchor-seq 42))
            (should (progn
                      (dsh-emacs-events--assistant-stream-frame
                       (current-buffer)
                       '((type . "chunk") (revision . 2)
                         (chunk . ((type . "text-delta") (text . "stale")))))
                      (not (string-match-p "stale" (buffer-string)))))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

;; --- Review regression: stream restart, missing frames and empty cleanup ---
(ert-deftest dsh-emacs-test-events-follow-counter-reset-replaces-old-attempt ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (setq-local dsh-emacs--anchor-seq 7)
    (dolist (frame '(((type . "start") (revision . 1) (attemptId . "old")
                      (turn . 1) (step . 1))
                     ((type . "chunk") (revision . 2) (attemptId . "old")
                      (index . 0)
                      (chunk . ((type . "text-delta") (index . 0)
                                (text . "old-prefix"))))
                     ((type . "start") (revision . 1) (attemptId . "new")
                      (turn . 2) (step . 1))
                     ;; A replayed start at the watermark it already set is a
                     ;; duplicate, not another lifecycle reset.
                     ((type . "start") (revision . 1) (attemptId . "new")
                      (turn . 2) (step . 1))
                     ((type . "chunk") (revision . 2) (attemptId . "new")
                      (index . 0)
                      (chunk . ((type . "text-delta") (index . 0)
                                (text . "new-prefix"))))
                     ((type . "chunk") (revision . 3) (attemptId . "new")
                      (index . 1)
                      (chunk . ((type . "text-delta") (index . 0)
                                (text . "-tail"))))))
      (dsh-emacs-events--assistant-stream-frame (current-buffer) frame))
    (dsh-emacs-render--flush-stream (current-buffer) t)
    (ert-info ((format "%s" "follow-counter-reset-replaces-old-attempt"))
      (should (string-match-p "new-prefix-tail" (buffer-string)))
      (should (not (string-match-p "old-prefix" (buffer-string))))
      (should (= dsh-emacs--anchor-seq 7)))))

;; Attempt ids restart with each Agent lifecycle, so a genuine reset can
;; arrive while the old attempt is still open under the same id.  The
;; revision watermark must drive the reset, or the new attempt merges into
;; the old live body.
(ert-deftest dsh-emacs-test-events-follow-counter-reset-reuses-attempt-id ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (setq-local dsh-emacs--buffer-session "reset-session")
    (dolist (frame '(((type . "start") (revision . 1) (attemptId . "sess:1")
                      (turn . 1) (step . 1))
                     ((type . "chunk") (revision . 2) (attemptId . "sess:1")
                      (index . 0)
                      (chunk . ((type . "text-delta") (index . 0)
                                (text . "old-attempt"))))
                     ;; No end frame: the old attempt is still open.
                     ((type . "start") (revision . 1) (attemptId . "sess:1")
                      (turn . 2) (step . 1))
                     ((type . "chunk") (revision . 2) (attemptId . "sess:1")
                      (index . 0)
                      (chunk . ((type . "text-delta") (index . 0)
                                (text . "new-attempt"))))))
      (dsh-emacs-events--assistant-stream-frame (current-buffer) frame))
    (dsh-emacs-render--flush-stream (current-buffer) t)
    (ert-info ((format "%s" "follow-counter-reset-reuses-attempt-id"))
      (should (string-match-p "new-attempt" (buffer-string)))
      (should (not (string-match-p "old-attempt" (buffer-string))))
      (should (equal (plist-get dsh-emacs--assistant-stream-attempt :position)
                     '(2 . 1)))
      (should (= dsh-emacs--assistant-stream-revision 2)))))

(ert-deftest dsh-emacs-test-events-follow-gap-reopens-stream-case ()
  :tags '(dsh-unit)
  (dolist (bad-frame
           '(((type . "chunk") (revision . 4) (attemptId . "a") (index . 2)
              (chunk . ((type . "text-delta") (index . 0) (text . "C"))))
             ((type . "end") (revision . 4) (attemptId . "a") (index . 2)
              (outcome . ((kind . "abandoned"))))
             ((type . "chunk") (revision . 3) (attemptId . "a") (index . 2)
              (chunk . ((type . "text-delta") (index . 0) (text . "C"))))
             ((type . "chunk") (revision . 4) (attemptId . "a") (index . 1)
              (chunk . ((type . "text-delta") (index . 0) (text . "C"))))
             ((type . "chunk") (revision . 3) (attemptId . "other") (index . 1)
              (chunk . ((type . "text-delta") (index . 0) (text . "C"))))
             ((type . "start") (revision . 3) (attemptId . "other")
              (turn . 2) (step . 1))))
    (with-temp-buffer
      (dsh-emacs-mode)
      (setq-local dsh-emacs--buffer-session "gap-session")
      (setq-local dsh-emacs--anchor-seq 7)
      (let ((proc (start-process "dsh-gap" nil "/bin/cat"))
            sent)
        (unwind-protect
            (progn
              (setq-local dsh-emacs--event-process proc)
              (process-put proc 'dsh-emacs-chat-buffer (current-buffer))
              (process-put proc 'dsh-emacs-follow-session "gap-session")
              (process-put proc 'dsh-emacs-follow-stream-id "old-follow")
              (cl-letf (((symbol-function 'dsh-emacs-events--frame)
                         (lambda (_opcode payload) payload))
                        ((symbol-function 'process-send-string)
                         (lambda (_proc payload)
                           (push (json-read-from-string payload) sent))))
                (dsh-emacs-events--assistant-stream-frame
                 (current-buffer)
                 '((type . "start") (revision . 1) (attemptId . "a")
                   (turn . 1) (step . 1)))
                (dsh-emacs-events--assistant-stream-frame
                 (current-buffer)
                 '((type . "chunk") (revision . 2) (attemptId . "a") (index . 0)
                   (chunk . ((type . "text-delta") (index . 0) (text . "A")))))
                (dsh-emacs-events--assistant-stream-frame
                 (current-buffer) bad-frame)
                (ert-info ((format "%s" (format "follow-gap-reopens-stream-%S" bad-frame)))
                  (should (= (length sent) 2))
                  (should (equal (alist-get 'type (car sent)) "open"))
                  (should (equal (alist-get 'endpoint (car sent)) "session/follow"))
                  (should (equal (alist-get 'type (cadr sent)) "cancel"))
                  (should (equal (alist-get 'streamId (cadr sent)) "old-follow"))
                  (should (not (equal (process-get proc 'dsh-emacs-follow-stream-id)
                                      "old-follow"))))
                ;; Retired stream frames cannot corrupt the new baseline or
                ;; schedule yet another recovery (including its end frame).
                (dsh-emacs-events--dispatch-follow
                 proc (dsh-protocol-mux-frame--from-alist
                       '((streamId . "old-follow") (type . "end"))))
                (dsh-emacs-events--dispatch-follow
                 proc (dsh-protocol-mux-frame--from-alist
                       '((streamId . "old-follow") (type . "item")
                         (value . ((type . "assistant-stream")
                                   (frame . ((type . "chunk") (revision . 5)
                                             (attemptId . "a") (index . 3)
                                             (chunk . ((type . "text-delta")
                                                       (index . 0)
                                                       (text . "STALE"))))))))))
                (dsh-emacs-events--follow-snapshot
                 (current-buffer)
                 '((type . "snapshot") (cursor . 7) (records . [])
                   (assistantStream .
                                    ((revision . 4)
                                     (activeAttempt .
                                                    ((attemptId . "a") (turn . 1) (step . 1) (nextIndex . 3)
                                                     (stream . [((type . "text-chunks") (index . 0)
                                                                 (time0 . 1) (dt . [1 1])
                                                                 (texts . ["A" "B" "C"]))])))))))
                (dsh-emacs-events--assistant-stream-frame
                 (current-buffer)
                 '((type . "chunk") (revision . 5) (attemptId . "a") (index . 3)
                   (chunk . ((type . "text-delta") (index . 0) (text . "D")))))
                (dsh-emacs-render--flush-stream (current-buffer) t)
                (ert-info ((format "%s" (format "follow-gap-baseline-restores-complete-body-%S"
                                                bad-frame)))
                  (should (= (length sent) 2))
                  (should (null dsh-emacs--event-reconnect-timer))
                  (should (= (how-many "ABCD" (point-min) (point-max)) 1))
                  (should (not (string-match-p "STALE" (buffer-string))))
                  (should (= dsh-emacs--anchor-seq 7)))))
          (setq dsh-emacs--event-process nil)
          (when (process-live-p proc) (delete-process proc)))))))

;; Without a session the reopen would be a no-op, so the live stream id must
;; not be retired either.
(ert-deftest dsh-emacs-test-events-follow-rebaseline-needs-a-session ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (let ((proc (start-process "dsh-no-session" nil "/bin/cat"))
          sent)
      (unwind-protect
          (progn
            (setq-local dsh-emacs--event-process proc)
            (process-put proc 'dsh-emacs-follow-stream-id "keep-me")
            (cl-letf (((symbol-function 'process-send-string)
                       (lambda (_proc payload) (push payload sent))))
              (dsh-emacs-events--follow-rebaseline))
            (ert-info ((format "%s" "follow-rebaseline-needs-a-session"))
              (should (null sent))
              (should (equal (process-get proc 'dsh-emacs-follow-stream-id)
                             "keep-me"))))
        (setq dsh-emacs--event-process nil)
        (when (process-live-p proc) (delete-process proc))))))

(ert-deftest dsh-emacs-test-events-discard-empty-tracking-does-not-claim-visible-removal ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (setq-local dsh-emacs--streamed-step
                (list :key '(1 . 1)
                      :text-regions (list (list :start (copy-marker (point-min))
                                                :end (copy-marker (point-min))))
                      :thinking-blocks '(("gone" . "gone"))))
    (let ((before (buffer-string)))
      (ert-info ((format "%s" "discard-empty-tracking-does-not-claim-visible-removal"))
        (should (not (dsh-emacs-render--discard-stream)))
        (should (equal before (buffer-string)))
        (should (null dsh-emacs--streamed-step))))))

;; --- Test 119d: the follow open request declares assistantStream ---
;; Without the opt-in the host never sends the process-local frames, and a
;; reply would only appear once its durable `assistant/message' settles.
(ert-deftest dsh-emacs-test-events-follow-open-opts-into-assistant-stream ()
  :tags '(dsh-unit)
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
            (ert-info ((format "%s" "follow-open-opts-into-assistant-stream"))
              (should (and sent
                           (string-match-p "\"assistantStream\"" sent)
                           (string-match-p "\"session/follow\"" sent)
                           (string-match-p "\"sess-open\"" sent))))))
      (when (process-live-p proc) (delete-process proc)))))

(ert-deftest dsh-emacs-test-events-follow-open-requests-one-round ()
  :tags '(dsh-unit)
  (let ((dsh-emacs-history-rounds 5)
        (dsh-emacs-history-window 7)
        sent)
    (cl-letf (((symbol-function 'process-get)
               (lambda (_process key)
                 (pcase key
                   ('dsh-emacs-follow-session "opening")
                   ('dsh-emacs-follow-stream-id "follow"))))
              ((symbol-function 'process-live-p) (lambda (_) t))
              ((symbol-function 'process-send-string)
               (lambda (_process text) (setq sent text)))
              ((symbol-function 'dsh-emacs-events--frame)
               (lambda (_opcode text) text)))
      (dsh-emacs-events--follow-open 'test-process))
    (let* ((frame (dsh-protocol-read-json sent))
           (request (alist-get 'request
                               (alist-get 'args (alist-get 'payload frame)))))
      (should (equal (alist-get 'endpoint frame) "session/follow"))
      (should (equal (alist-get 'turnWindow request)
                     '((minMessages . 1) (minTurns . 1))))
      (should (= (alist-get 'maxMessages request) 7))
      (should (eq (alist-get 'assistantStream request) t)))))

(provide 'dsh-test-events)
;;; dsh-test-events.el ends here
