;;; dsh-test-protocol.el --- Protocol tests -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "28.1"))

(require 'dsh-test-support)

(ert-deftest dsh-emacs-test-protocol-session-title-event ()
  :tags '(dsh-unit)
  (dolist (wire '(((type . "session/title") (data (title . "Renamed")))
                  (("type" . "session/title")
                   ("data" ("title" . "Renamed")))))
    (should (equal "Renamed"
                   (dsh-protocol-session-title-title
                    (dsh-protocol-session-title--from-alist wire)))))
  ;; Absence is distinct from an unrelated event: callers still record it.
  (let ((view (dsh-protocol-session-title--from-alist
               '((type . "session/title")))))
    (should (dsh-protocol-session-title-p view))
    (should-not (dsh-protocol-session-title-title view)))
  (should-not (dsh-protocol-session-title--from-alist
               '((type . "assistant/message") (data (title . "Ignore"))))))

(ert-deftest dsh-emacs-test-protocol-deliverables-event ()
  :tags '(dsh-unit)
  (dolist (wire
           '(((seq . 17) (data (turn . 4)
                               (files . [((path . "a.md") (description . "old"))
                                         ((path . "a.md") (description . "new"))
                                         ((path . "b.txt") (description . ""))
                                         ((path . "c.txt") (description . 42))
                                         ((path . "") (description . "drop"))
                                         ((path . 42)) nil "invalid"])))
             (("seq" . 17) ("data" ("turn" . 4)
                            ("files" . [(("path" . "a.md") ("description" . "old"))
                                        (("path" . "a.md") ("description" . "new"))
                                        (("path" . "b.txt"))
                                        (("path" . "c.txt"))])))))
    (let ((view (dsh-protocol-deliverables--from-alist wire)))
      (should (= 17 (dsh-protocol-deliverables-seq view)))
      (should (= 4 (dsh-protocol-deliverables-turn view)))
      (should (equal '(("a.md" . "old") ("a.md" . "new")
                       ("b.txt") ("c.txt"))
                     (dsh-protocol-deliverables-files view)))))
  (let ((view (dsh-protocol-deliverables--from-alist '((seq . 19)))))
    (should (= 19 (dsh-protocol-deliverables-seq view)))
    (should-not (dsh-protocol-deliverables-turn view))
    (should-not (dsh-protocol-deliverables-files view))))

(ert-deftest dsh-emacs-test-protocol-command-event-fields ()
  :tags '(dsh-unit)
  (dolist (keys '((type data commandId name kind text)
                  ("type" "data" "commandId" "name" "kind" "text")))
    (dolist (type '("command/run" "command/done"))
      (pcase-let* ((`(,type-key ,data-key ,id-key ,name-key ,kind-key ,text-key)
                    keys)
                   (text "First line\nSecond line")
                   (decoded
                    (dsh-protocol-command-event--from-alist
                     (list (cons type-key type)
                           (cons data-key
                                 (list (cons id-key "cmd-7")
                                       (cons name-key "/compact")
                                       (cons kind-key "future-outcome")
                                       (cons text-key text)))))))
        (should (equal type (dsh-protocol-command-event-type decoded)))
        (should (equal "cmd-7" (dsh-protocol-command-event-command-id decoded)))
        (should (equal "/compact" (dsh-protocol-command-event-name decoded)))
        (should (equal "future-outcome" (dsh-protocol-command-event-kind decoded)))
        (should (eq text (dsh-protocol-command-event-text decoded))))))
  (let ((decoded (dsh-protocol-command-event--from-alist
                  '((type . "command/done")))))
    (should (equal "command/done" (dsh-protocol-command-event-type decoded)))
    (should-not (dsh-protocol-command-event-command-id decoded))
    (should-not (dsh-protocol-command-event-name decoded))
    (should-not (dsh-protocol-command-event-kind decoded))
    (should-not (dsh-protocol-command-event-text decoded))))

(ert-deftest dsh-emacs-test-protocol-tool-call-retains-opaque-arguments ()
  :tags '(dsh-unit)
  (dolist (keys '((name callId arguments) ("name" "callId" "arguments")))
    (dolist (args '("{\"command\":\"printf protocol\"}" "invalid JSON"
                    ((unexpected . t)) nil))
      (pcase-let* ((`(,name-key ,id-key ,args-key) keys)
                   (call (dsh-protocol-tool-call--from-alist
                          (list (cons name-key "bash") (cons id-key "call-7")
                                (cons args-key args)))))
        (should (equal "bash" (dsh-protocol-tool-call-name call)))
        (should (equal "call-7" (dsh-protocol-tool-call-call-id call)))
        (should (eq args (dsh-protocol-tool-call-arguments call))))))
  (let ((call (dsh-protocol-tool-call--from-alist nil)))
    (should-not (dsh-protocol-tool-call-name call))
    (should-not (dsh-protocol-tool-call-call-id call))
    (should-not (dsh-protocol-tool-call-arguments call))))

(ert-deftest dsh-emacs-test-protocol-reply-event-tool-identity ()
  :tags '(dsh-unit)
  (dolist (keys '((type data name callId) ("type" "data" "name" "callId")))
    (pcase-let ((`(,type-key ,data-key ,name-key ,id-key) keys))
      (dolist (type '("tool/call" "turn/start" "turn/end" "step/start"
                      "assistant/message" "assistant/attempt"))
        (let ((event
               (dsh-protocol-reply-event--from-alist
                (list (cons type-key type)
                      (cons data-key (list (cons name-key "grep")
                                           (cons id-key "call-23")))))))
          (should (equal (and (equal type "tool/call") "grep")
                         (dsh-protocol-reply-event-tool-name event)))
          (should (equal (and (equal type "tool/call") "call-23")
                         (dsh-protocol-reply-event-call-id event)))))))
  (let ((event (dsh-protocol-reply-event--from-alist
                '((type . "tool/call")))))
    (should-not (dsh-protocol-reply-event-tool-name event))
    (should-not (dsh-protocol-reply-event-call-id event))))

(ert-deftest dsh-emacs-test-protocol-reply-event-folding-facts ()
  :tags '(dsh-unit)
  (dolist (string-keys '(nil t))
    (cl-labels ((wire (value)
                 (cond ((vectorp value) (vconcat (mapcar #'wire value)))
                       ((consp value)
                        (mapcar (lambda (entry)
                                  (cons (if string-keys
                                            (symbol-name (car entry))
                                          (car entry))
                                        (wire (cdr entry))))
                                value))
                       (t value)))
               (decode (type content &optional reason)
                 (dsh-protocol-reply-event--from-alist
                  (wire `((type . ,type) (seq . 17) (time . 1200)
                          (data (turn . 4) (step . 3)
                                (reason (kind . ,reason))
                                (message (content . ,content))
                                (usage (inputTokens . 10)
                                       (outputTokens . 2))))))))
      (let ((reply (decode "assistant/message"
                           [((type . "reasoning") (text . "work"))
                            ((type . "text") (text . "**answer**"))])))
        (should (= 17 (dsh-protocol-reply-event-seq reply)))
        (should (= 4 (dsh-protocol-reply-event-turn reply)))
        (should (dsh-protocol-reply-event-answer-p reply))
        (should (equal "**answer**" (dsh-protocol-reply-event-text reply)))
        (should (equal '(:input 10 :output 2 :cache-read 0 :cache-write 0)
                       (dsh-protocol-reply-event-usage reply))))
      (dolist (content '([((type . "text") (text . ""))]
                         [((type . "text") (text . " \t\n"))]
                         [((type . "reasoning") (text . "only thinking"))]
                         [((type . "text") (text . "calling tool"))
                          ((type . "tool-call") (name . "read"))]
                         []))
        (should-not (dsh-protocol-reply-event-answer-p
                     (decode "assistant/message" content))))
      (dolist (type '("assistant/attempt" "step/start" "tool/call"
                      "turn/start" "turn/end"))
        (let ((event (decode type [((type . "text") (text . "not an answer"))]
                             "completed")))
          (should (equal type (dsh-protocol-reply-event-type event)))
          (should-not (dsh-protocol-reply-event-answer-p event))))
      (dolist (reason '("completed" "error" "aborted" "interrupted" "forked"))
        (let ((event (decode "turn/end" [] reason)))
          (should (equal reason (dsh-protocol-reply-event-reason event)))
          (should (equal (unless (equal reason "forked") 1200)
                         (dsh-protocol-reply-event-time event)))))
      (should-not (decode "step/end" []))
      (should-not (decode "tool/result" [])))))

(ert-deftest dsh-emacs-test-protocol-mux-frame-preserves-logical-payloads ()
  :tags '(dsh-unit)
  (let* ((payload '((type . "event") (records . [((seq . 3))])))
         (failure '((code . "unavailable") (message . "Retry later")))
         (item (dsh-protocol-mux-frame--from-alist
                `((type . "item") (streamId . "follow-1") (value . ,payload))))
         (err (dsh-protocol-mux-frame--from-alist
               `(("type" . "error") ("streamId" . "jobs-1")
                 ("error" . ,failure))))
         (end (dsh-protocol-mux-frame--from-alist
               '((type . "end") (streamId . "follow-1")))))
    (should (equal "item" (dsh-protocol-mux-frame-type item)))
    (should (equal "follow-1" (dsh-protocol-mux-frame-stream-id item)))
    (should (eq payload (dsh-protocol-mux-frame-value item)))
    (should-not (dsh-protocol-mux-frame-error item))
    (should (equal "error" (dsh-protocol-mux-frame-type err)))
    (should (equal "jobs-1" (dsh-protocol-mux-frame-stream-id err)))
    (should (eq failure (dsh-protocol-mux-frame-error err)))
    (should-not (dsh-protocol-mux-frame-value err))
    (should (equal "end" (dsh-protocol-mux-frame-type end)))
    (should (equal "follow-1" (dsh-protocol-mux-frame-stream-id end)))
    (should-not (dsh-protocol-mux-frame-value end))
    (should-not (dsh-protocol-mux-frame-error end))))

(ert-deftest dsh-emacs-test-protocol-follow-snapshot-normalizes-the-whole-window ()
  :tags '(dsh-unit)
  (dolist (key-type '(symbol string))
    (dolist (array-type '(vector list))
      (let* ((json-key-type key-type)
             (json-array-type array-type)
             (json-object-type 'alist)
             (json-false :json-false)
             (wire
              (json-read-from-string
               (json-encode
                '((cursor . -1) (hasMore . t)
                  (records . [9
                              ((type . "event")
                               (event . ((type . "compaction/start") (seq . 8)
                                         (data . ((compactionId . "whole"))))))
                              ((type . "other")
                               (event . ((type . "llm/retry") (seq . 7)
                                         (data . ((retryId . "retry"))))))
                              ((type . "event")
                               (event . ((type . "user/message") (seq . 8))))
                              ((type . "event")
                               (event . ((type . "turn/end") (seq . 3))))])
                  (projections . ((asOfSeq . 31)
                                  (values . ((plan . ((active . :json-false)
                                                      (pending . t)))))))
                  (assistantStream
                   . ((revision . 9)
                      (activeAttempt
                       . ((attemptId . "attempt") (turn . 2) (step . 3)
                          (nextIndex . 2)
                          (stream . [((type . "text-chunks") (index . 0)
                                      (texts . ["Hello" " world"]))])))))))))
             (raw-records (append (dsh-protocol--field 'records wire) nil))
             (snapshot (dsh-protocol-follow-snapshot--from-alist wire))
             (records (dsh-protocol-follow-snapshot-records snapshot))
             (execution (dsh-protocol-follow-snapshot-execution snapshot))
             (plan (dsh-protocol-follow-snapshot-plan snapshot))
             (assistant (dsh-protocol-follow-snapshot-assistant snapshot)))
        (ert-info ((format "keys=%s arrays=%s" key-type array-type))
          ;; Follow snapshots retain duplicates and non-increasing sequence
          ;; numbers; strict page validation belongs to history pagination.
          (should (= -1 (dsh-protocol-follow-snapshot-cursor snapshot)))
          (should (eq t (dsh-protocol-follow-snapshot-has-more snapshot)))
          (should (= 3 (length records)))
          (should (eq (nth 0 records) (nth 1 raw-records)))
          (should (eq (nth 1 records) (nth 3 raw-records)))
          (should (eq (nth 2 records) (nth 4 raw-records)))
          ;; Execution consumes the entire object window, including records
          ;; not selected as transcript entries and those below an anchor.
          (should (equal (mapcar #'dsh-protocol-execution-event-type execution)
                         '("compaction/start" "llm/retry" "turn/end")))
          (should (equal (mapcar #'dsh-protocol-execution-event-seq execution)
                         '(8 7 3)))
          (should (eq (dsh-protocol-follow-snapshot-projections snapshot)
                      (dsh-protocol--field 'projections wire)))
          (should-not (dsh-protocol-plan-active plan))
          (should (dsh-protocol-plan-pending plan))
          (should (= 31 (dsh-protocol-plan-seq plan)))
          (should (= 9 (dsh-protocol-assistant-baseline-revision assistant)))
          (should (equal "attempt"
                         (dsh-protocol-assistant-baseline-attempt-id assistant)))
          (should (= 2 (dsh-protocol-assistant-baseline-next-index assistant)))
          (should (equal '("Hello" " world")
                         (dsh-protocol-assistant-record-texts
                          (car (dsh-protocol-assistant-baseline-stream
                                assistant))))))))))

(ert-deftest dsh-emacs-test-protocol-follow-snapshot-retains-absence-watermark ()
  :tags '(dsh-unit)
  (dolist (case '((nil nil nil)
                  (((cursor . -1) (records . []) (hasMore . :json-false)
                    (projections . ((asOfSeq . 17) (values))))
                   -1 17)))
    (pcase-let* ((`(,wire ,cursor ,seq) case)
                 (snapshot (dsh-protocol-follow-snapshot--from-alist wire))
                 (plan (dsh-protocol-follow-snapshot-plan snapshot))
                 (assistant (dsh-protocol-follow-snapshot-assistant snapshot)))
      (should (equal cursor (dsh-protocol-follow-snapshot-cursor snapshot)))
      (should-not (dsh-protocol-follow-snapshot-records snapshot))
      (should-not (dsh-protocol-follow-snapshot-has-more snapshot))
      (should-not (dsh-protocol-follow-snapshot-execution snapshot))
      (should (dsh-protocol-plan-p plan))
      (should (equal seq (dsh-protocol-plan-seq plan)))
      (should-not (dsh-protocol-plan-available plan))
      (should (dsh-protocol-assistant-baseline-p assistant))
      (should-not (dsh-protocol-assistant-baseline-revision assistant))
      (should-not (dsh-protocol-assistant-baseline-attempt-id assistant))
      (should-not (dsh-protocol-assistant-baseline-stream assistant)))))

(ert-deftest dsh-emacs-test-protocol-follow-item-selects-typed-payloads ()
  :tags '(dsh-unit)
  (let* ((event '((type . "assistant/message") (seq . 8)))
         (chunk '((type . "text-delta") (index . 0) (text . "live")))
         (durable (dsh-protocol-follow-item--from-alist
                   `((type . "event") (event . ,event))))
         (snapshot (dsh-protocol-follow-item--from-alist
                    '((type . "snapshot") (cursor . -1) (records . []))))
         (stream (dsh-protocol-follow-item--from-alist
                  `(("type" . "assistant-stream")
                    ("frame" . (("type" . "chunk") ("revision" . 9)
                                ("attemptId" . "attempt") ("index" . 2)
                                ("chunk" . ,chunk))))))
         (frame (dsh-protocol-follow-item-payload stream)))
    (should (equal "event" (dsh-protocol-follow-item-type durable)))
    (should (eq event (dsh-protocol-follow-item-payload durable)))
    (should (dsh-protocol-follow-snapshot-p
             (dsh-protocol-follow-item-payload snapshot)))
    (should (= -1 (dsh-protocol-follow-snapshot-cursor
                   (dsh-protocol-follow-item-payload snapshot))))
    (should (equal "assistant-stream" (dsh-protocol-follow-item-type stream)))
    (should (dsh-protocol-assistant-frame-p frame))
    (should (equal "chunk" (dsh-protocol-assistant-frame-type frame)))
    (should (= 9 (dsh-protocol-assistant-frame-revision frame)))
    (should (equal "attempt" (dsh-protocol-assistant-frame-attempt-id frame)))
    (should (= 2 (dsh-protocol-assistant-frame-index frame)))
    (should (eq chunk (dsh-protocol-assistant-frame-chunk frame)))
    (should-not (dsh-protocol-follow-item-payload
                 (dsh-protocol-follow-item--from-alist
                  `(("type" . "future-item") ("event" . ,event))))))
  (dolist (invalid '(nil 7 "bad" ["bad"]))
    (let ((frame (dsh-protocol-follow-item-payload
                  (dsh-protocol-follow-item--from-alist
                   `((type . "assistant-stream") (frame . ,invalid))))))
      (should (dsh-protocol-assistant-frame-p frame))
      (should-not (dsh-protocol-assistant-frame-type frame))
      (should-not (dsh-protocol-assistant-frame-revision frame))
      (should-not (dsh-protocol-assistant-frame-chunk frame)))))

(ert-deftest dsh-emacs-test-protocol-follow-projections-decode-known-values ()
  :tags '(dsh-unit)
  (let* ((baseline
          '((asOfSeq . 23)
            (values . ((userQuestions
                        . ((active . [((callId . "pending")
                                        (state . "continued")
                                        (questions . []))])
                           (settled . [])))
                       (goal . ((goal . ((objective . "Continue work")
                                         (phase . "active")))
                                (roundsStarted . 3)))
                       (permissions . ((currentValue . " host ")))
                       (contextPressure . ((pressureTokens . 20)
                                           (projectedTokens . 25)
                                           (contextWindow . 100)))
                       (title . "Snapshot title")
                       (subagentCatalog . [])
                       (tokenUsage . ((outputTokens . 5)))
                       (plan . ((active . t)))
                       (inbox . ((next-turn . [])))
                       (futureCell . ((nested . [1 2])))))))
         (view (dsh-protocol-follow-projections--from-alist baseline))
         (subagents (dsh-protocol-follow-projections-subagents view))
         (context (dsh-protocol-follow-projections-context view))
         (goal (dsh-protocol-follow-projections-goal view))
         (questions (dsh-protocol-follow-projections-questions view)))
    (should (equal "Snapshot title" (dsh-protocol-follow-projections-title view)))
    (should (equal '(20 25 100)
                   (list (dsh-protocol-context-pressure-pressure context)
                         (dsh-protocol-context-pressure-projected context)
                         (dsh-protocol-context-pressure-window context))))
    (should (equal " host " (dsh-protocol-follow-projections-permission view)))
    (should (dsh-protocol-follow-projections-goal-update-p view))
    (should (equal "Continue work" (dsh-protocol-goal-objective goal)))
    (should (= 3 (dsh-protocol-goal-rounds-started goal)))
    (should (= 23 (dsh-protocol-user-questions-seq questions)))
    (should (equal '("pending")
                   (mapcar #'dsh-protocol-pending-question-call-id
                           (dsh-protocol-user-questions-active questions))))
    (should (equal '(subagentCatalog subagent subagentTiming tokenUsage)
                   (mapcar #'dsh-protocol-subagent-cell-key subagents)))
    (should (equal '(23 23 23 23)
                   (mapcar #'dsh-protocol-subagent-cell-seq subagents)))
    (should (equal '(t nil nil t)
                   (mapcar #'dsh-protocol-subagent-cell-present subagents)))
    (should (= 5 (dsh-protocol-token-usage-output
                  (dsh-protocol-subagent-cell-value (car (last subagents))))))))

(ert-deftest dsh-emacs-test-protocol-follow-projections-distinguish-goal-clear ()
  :tags '(dsh-unit)
  (dolist (case
           '((nil t nil)
             (((asOfSeq . 17)) t 17)
             (((asOfSeq . 17) (values)) t 17)
             (((asOfSeq . 17) (values (goal . nil))) t 17)
             (((asOfSeq . 17) (values (goal . :json-false))) nil 17)
             (((asOfSeq . 17) (values (goal . "invalid"))) nil 17)
             (((asOfSeq . 17) (values (goal . 42))) nil 17)
             (((asOfSeq . 17) (values (goal . []))) nil 17)))
    (pcase-let* ((`(,baseline ,clear-p ,seq) case)
                 (view (dsh-protocol-follow-projections--from-alist baseline))
                 (questions (dsh-protocol-follow-projections-questions view)))
      (ert-info ((format "baseline=%S" baseline))
        ;; A nil decoded goal alone cannot distinguish a clear from a skip.
        (should (eq clear-p (dsh-protocol-follow-projections-goal-update-p view)))
        (should-not (dsh-protocol-follow-projections-goal view))
        (should (dsh-protocol-user-questions-p questions))
        (should (equal seq (dsh-protocol-user-questions-seq questions)))
        (should-not (dsh-protocol-user-questions-active questions))
        (should-not (dsh-protocol-user-questions-settled questions))))))

(ert-deftest dsh-emacs-test-protocol-follow-projections-retain-catalog-presence ()
  :tags '(dsh-unit)
  (dolist (case
           '((nil -1 nil)
             (((asOfSeq . 31) (values)) 31 nil)
             (((asOfSeq . 31) (values (subagentCatalog . []))) 31 t)
             (((asOfSeq . 31) (values (subagentCatalog . nil))) 31 t)))
    (pcase-let* ((`(,baseline ,seq ,present) case)
                 (view (dsh-protocol-follow-projections--from-alist baseline))
                 (cells (dsh-protocol-follow-projections-subagents view)))
      (ert-info ((format "baseline=%S" baseline))
        (should (equal '(subagentCatalog subagent subagentTiming tokenUsage)
                       (mapcar #'dsh-protocol-subagent-cell-key cells)))
        (should (equal (make-list 4 seq)
                       (mapcar #'dsh-protocol-subagent-cell-seq cells)))
        (should (equal (list present nil nil nil)
                       (mapcar #'dsh-protocol-subagent-cell-present cells)))
        (should (equal '(nil nil nil nil)
                       (mapcar #'dsh-protocol-subagent-cell-value cells)))))))

(ert-deftest dsh-emacs-test-protocol-follow-snapshot-defers-migration-error ()
  :tags '(dsh-unit)
  (let* ((baseline '((kind . "migration-required")
                     (values (subagentCatalog . []))))
         (snapshot (dsh-protocol-follow-snapshot--from-alist
                    `((cursor . 9) (records . [])
                      (projections . ,baseline)))))
    ;; Opening views are decoded before history; this boundary must stay late.
    (should (dsh-protocol-follow-snapshot-p snapshot))
    (should (= 9 (dsh-protocol-follow-snapshot-cursor snapshot)))
    (should (eq baseline (dsh-protocol-follow-snapshot-projections snapshot)))
    (should-error (dsh-protocol-follow-projections--from-alist baseline)
                  :type 'dsh-protocol-migration-required)))

(ert-deftest dsh-emacs-test-protocol-context-pressure-preserves-raw-sample ()
  :tags '(dsh-unit)
  (dolist (keys '((pressureTokens projectedTokens contextWindow)
                  ("pressureTokens" "projectedTokens" "contextWindow")))
    (dolist (sample '((0 321 1000) (:json-false "raw" -1)))
      (pcase-let* ((`(,pressure-key ,projected-key ,window-key) keys)
                   (`(,pressure ,projected ,window) sample)
                   (view (dsh-protocol-context-pressure--from-alist
                          (list (cons pressure-key pressure)
                                (cons projected-key projected)
                                (cons window-key window)))))
        ;; Decoding must not choose a display estimate or discard a sample;
        ;; the consumer owns the raw-pressure trust guard.
        (should (equal pressure (dsh-protocol-context-pressure-pressure view)))
        (should (equal projected (dsh-protocol-context-pressure-projected view)))
        (should (equal window (dsh-protocol-context-pressure-window view))))))
  (let ((session
         (dsh-protocol-session--from-alist
          '((sessionId . "context")
            (projections
             . ((values . ((contextPressure
                            . ((pressureTokens . 7) (projectedTokens . 11)
                               (contextWindow . 97)))))))))))
    (should (equal '(7 11 97)
                   (list (dsh-protocol-session-context-pressure session)
                         (dsh-protocol-session-context-projected session)
                         (dsh-protocol-session-context-window session)))))
  (dolist (wire '(nil :json-false 7 "not-an-object" []))
    (let ((view (dsh-protocol-context-pressure--from-alist wire)))
      (should (dsh-protocol-context-pressure-p view))
      (should-not (dsh-protocol-context-pressure-pressure view))
      (should-not (dsh-protocol-context-pressure-projected view))
      (should-not (dsh-protocol-context-pressure-window view)))))

(ert-deftest dsh-emacs-test-protocol-permission-value-keeps-host-defined-names ()
  :tags '(dsh-unit)
  (dolist (key '(currentValue "currentValue"))
    (dolist (value '("workspace-write" "auto" "custom" " host-defined " " "))
      (should (equal value
                     (dsh-protocol-permission-value--from-alist
                      (list (cons key value))))))
    (dolist (value '(nil "" :json-false 7 []))
      (should-not (dsh-protocol-permission-value--from-alist
                   (list (cons key value))))))
  (dolist (wire '(nil :json-false 7 "bare-preset" [] ((other . "custom"))))
    (should-not (dsh-protocol-permission-value--from-alist wire))))

(ert-deftest dsh-emacs-test-protocol-control-baseline-keeps-raw-session-records ()
  :tags '(dsh-unit)
  (let* ((first '(first . ((asOfSeq . 7) (values))))
         (migration '("migration" . ((kind . "migration-required"))))
         (entries (list first '(empty) migration)))
    (dolist (key '(projections "projections"))
      (dolist (records (list entries (vconcat entries)))
        ;; A later migration hint must not prevent the caller from applying
        ;; an earlier session; only the per-session decoder may signal it.
        (let ((decoded (dsh-protocol-control-baseline--from-alist
                        (list (cons key records)))))
          (should (= 2 (length decoded)))
          (should (eq first (car decoded)))
          (should (eq migration (cadr decoded)))))))
  (should-not (dsh-protocol-control-baseline--from-alist nil)))

(ert-deftest dsh-emacs-test-protocol-control-session-keeps-cuts-and-cell-presence ()
  :tags '(dsh-unit)
  (dolist (session-id '(control-a "control-a"))
    (let* ((baseline
            '((asOfSeq . 17)
              (values . ((goal . nil)
                         (futureCell . ((nested . [1 2])))
                         (contextPressure . ((pressureTokens . 20)
                                             (projectedTokens . 22)
                                             (contextWindow . 100)))
                         (permissions . ((currentValue . " host ")))
                         (inbox . nil) (subagentCatalog . [])))))
           (session (dsh-protocol-control-session--from-alist
                     (cons session-id baseline)))
           (projections (dsh-protocol-control-session-projections session))
           (subagents (dsh-protocol-control-session-subagents session)))
      (should (equal "control-a" (dsh-protocol-control-session-session-id session)))
      (should (equal (mapcar #'dsh-protocol-projection-key projections)
                     '("plan" "userQuestions" "goal" "futureCell"
                       "contextPressure" "permissions" "inbox")))
      (should (equal (mapcar #'dsh-protocol-projection-session-id projections)
                     (make-list 7 "control-a")))
      (pcase-let ((`(,plan ,questions ,goal ,unknown ,context ,permission ,inbox)
                   (mapcar #'dsh-protocol-projection-value projections)))
        (should (= 17 (dsh-protocol-plan-seq plan)))
        (should-not (dsh-protocol-plan-available plan))
        (should (= 17 (dsh-protocol-user-questions-seq questions)))
        (should-not (dsh-protocol-user-questions-active questions))
        (should-not goal)
        (should (eq unknown (dsh-protocol--field
                             'futureCell (dsh-protocol--field 'values baseline))))
        (should (= 22 (dsh-protocol-context-pressure-projected context)))
        (should (equal " host " permission))
        (should-not inbox))
      (should (equal '(17 17 17 17)
                     (mapcar #'dsh-protocol-subagent-cell-seq subagents)))
      (should (equal '(t nil nil nil)
                     (mapcar #'dsh-protocol-subagent-cell-present subagents)))))
  (let ((projections
         (dsh-protocol-control-session-projections
          (dsh-protocol-control-session--from-alist '(empty . ((asOfSeq . 4)))))))
    (should (equal (mapcar #'dsh-protocol-projection-key projections)
                   '("plan" "userQuestions")))))

(ert-deftest dsh-emacs-test-protocol-control-session-tolerates-malformed-inbox ()
  :tags '(dsh-unit)
  (let* ((baseline
          '((asOfSeq . 9)
            (values . ((title . "Kept")
                       (inbox . ((next-turn . [7])))))))
         (session (dsh-protocol-control-session--from-alist
                   (cons "control-bad" baseline)))
         (projections (dsh-protocol-control-session-projections session)))
    ;; One malformed cell must not discard the rest of the session.
    (should (equal "control-bad"
                   (dsh-protocol-control-session-session-id session)))
    (should (equal '("plan" "userQuestions" "title" "inbox")
                   (mapcar #'dsh-protocol-projection-key projections)))
    (should (equal "Kept"
                   (dsh-protocol-projection-value
                    (cl-find "title" projections
                             :key #'dsh-protocol-projection-key
                             :test #'equal)))))
  (dolist (inbox '(7 "junk" ((next-turn . 7)) ((next-step . "x"))))
    (should-not (dsh-protocol-queue-items-from-inbox inbox))))

(ert-deftest dsh-emacs-test-protocol-projection-decodes-known-values ()
  :tags '(dsh-unit)
  (dolist (case
           (list
            (list 'contextPressure '((pressureTokens . 30) (projectedTokens . 33)
                                     (contextWindow . 100))
                  #'dsh-protocol-context-pressure-projected 33)
            (list "permissions" '((currentValue . " custom ")) #'identity " custom ")
            (list 'goal '((goal . ((objective . "Keep going") (phase . "active"))))
                  #'dsh-protocol-goal-objective "Keep going")
            (list "inbox"
                  (list (cons 'next-turn
                              (vector (dsh-emacs-test--inbox-message "i1" "queued body"))))
                  (lambda (items) (mapcar #'dsh-protocol-queue-item-text items))
                  '("queued body"))
            (list 'plan '((active . t) (pending . :json-false))
                  #'dsh-protocol-plan-seq 23)
            (list "userQuestions" '((active . []) (settled . []))
                  #'dsh-protocol-user-questions-seq 23)
            (list 'tokenUsage '((outputTokens . 5))
                  (lambda (cell)
                    (list (dsh-protocol-subagent-cell-key cell)
                          (dsh-protocol-subagent-cell-seq cell)
                          (dsh-protocol-token-usage-output
                           (dsh-protocol-subagent-cell-value cell))))
                  '(tokenUsage 23 5))))
    (pcase-let* ((`(,key ,wire ,read-value ,expected) case)
                 (projection
                  (dsh-protocol-projection--from-alist
                   `((sessionId . "control-a") (key . ,key)
                     (seq . 23) (value . ,wire)))))
      (ert-info ((format "projection key=%s" key))
        (should (equal "control-a" (dsh-protocol-projection-session-id projection)))
        (should (equal (format "%s" key) (dsh-protocol-projection-key projection)))
        (should (equal expected
                       (funcall read-value (dsh-protocol-projection-value projection)))))))
  (let* ((raw '((nested . [1 2])))
         (projection (dsh-protocol-projection--from-alist
                      `((sessionId . "control-a") (key . futureCell) (value . ,raw)))))
    (should (equal "futureCell" (dsh-protocol-projection-key projection)))
    (should (eq raw (dsh-protocol-projection-value projection)))))

(ert-deftest dsh-emacs-test-protocol-core-item-decodes-workspace-payloads ()
  :tags '(dsh-unit)
  (dolist (array (list #'identity #'vconcat))
    (let* ((row '((workspaceId . "w") (title . "Workspace")
                  (sessionIds . ["s"])))
           (baseline
            (dsh-protocol-core-item--from-alist
             `(("type" . "baseline")
               ("value" . (("items" . ,(funcall array (list row)))
                           ("archivedSessionIds"
                            . ,(funcall array '("archived"))))))))
           (upsert (dsh-protocol-core-item--from-alist
                    `((type . "upsert") (workspace . ,row))))
           (remove (dsh-protocol-core-item--from-alist
                    '(("type" . "remove") ("workspaceId" . "gone"))))
           (order (dsh-protocol-core-item--from-alist
                   `((type . "order")
                     (workspaceIds . ,(funcall array '("b" "a" "b"))))))
           (archived (dsh-protocol-core-item--from-alist
                      `((type . "archived")
                        (archivedSessionIds . ,(funcall array nil)))))
           (view (dsh-protocol-core-item-payload baseline)))
      (should (equal '("baseline" "upsert" "remove" "order" "archived")
                     (mapcar #'dsh-protocol-core-item-type
                             (list baseline upsert remove order archived))))
      (should (equal '("archived")
                     (dsh-protocol-workspace-list-archived-session-ids view)))
      (should (= 1 (length (dsh-protocol-workspace-list-items view))))
      (let ((workspace (car (dsh-protocol-workspace-list-items view))))
        (should (equal "w" (dsh-protocol-workspace-workspace-id workspace)))
        (should (equal "Workspace" (dsh-protocol-workspace-title workspace)))
        (should (equal '("s") (dsh-protocol-workspace-session-ids workspace)))
        (should (equal workspace (dsh-protocol-core-item-payload upsert))))
      (should (equal "gone" (dsh-protocol-core-item-payload remove)))
      (should (equal '("b" "a" "b") (dsh-protocol-core-item-payload order)))
      (should-not (dsh-protocol-core-item-payload archived))))
  (should-not (dsh-protocol-core-item-payload
               (dsh-protocol-core-item--from-alist '((type . "upsert"))))))

(ert-deftest dsh-emacs-test-protocol-core-item-retains-control-boundaries ()
  :tags '(dsh-unit)
  (dolist (value '(nil
                   ((items . nil) (projections))
                   ((projections
                     (first . ((values (title . "Applied first"))))
                     (later . ((kind . "migration-required")))))))
    (let ((item (dsh-protocol-core-item--from-alist
                 `((type . "baseline") (value . ,value)))))
      ;; The consumer must still decode/apply one session before the next.
      (should (equal "baseline" (dsh-protocol-core-item-type item)))
      (should (eq value (dsh-protocol-core-item-payload item)))))
  (let* ((item (dsh-protocol-core-item--from-alist
                '((type . "projection") (sessionId . "session")
                  (key . "plan") (seq . 19)
                  (value . ((active . t) (pending . :json-false))))))
         (projection (dsh-protocol-core-item-payload item))
         (plan (dsh-protocol-projection-value projection)))
    (should (equal "projection" (dsh-protocol-core-item-type item)))
    (should (equal "session" (dsh-protocol-projection-session-id projection)))
    (should (equal "plan" (dsh-protocol-projection-key projection)))
    (should (dsh-protocol-plan-active plan))
    (should-not (dsh-protocol-plan-pending plan))
    (should (= 19 (dsh-protocol-plan-seq plan))))
  (let* ((wire '((type . "future-item") (value . ((nested . [1 2])))))
         (item (dsh-protocol-core-item--from-alist wire)))
    (should (equal "future-item" (dsh-protocol-core-item-type item)))
    (should (eq wire (dsh-protocol-core-item-payload item)))))

(ert-deftest dsh-emacs-test-protocol-core-session-notices-name-their-arguments ()
  :tags '(dsh-unit)
  (dolist (array (list #'identity #'vconcat))
    (dolist (case '(("api-session/added" (((sessionId . "new"))) nil)
                    ("api-session/removed" ("gone") "gone")
                    ("api-session/status" ("busy" t) "busy" t)
                    ("api-session/status" ("idle" :json-false) "idle")
                    ("api-session/status" ("absent") "absent")
                    ("api-session/activity" ("recent" 123) "recent" 123)
                    ("future-event" ("ignored" 456) nil)))
      (pcase-let* ((`(,name ,args ,id . ,rest) case)
                   (item (dsh-protocol-core-item--from-alist
                          `(("type" . "emit") ("event" . ,name)
                            ("args" . ,(funcall array args)))))
                   (notice (dsh-protocol-core-item-payload item)))
        (should (equal "emit" (dsh-protocol-core-item-type item)))
        (should (equal name (dsh-protocol-session-notice-name notice)))
        (should (equal id (dsh-protocol-session-notice-session-id notice)))
        (if (equal name "api-session/added")
            (should (eq (car args) (dsh-protocol-session-notice-value notice)))
          (should (equal (car rest)
                         (dsh-protocol-session-notice-value notice)))))))
  (dolist (case '(("ready" clientId "client") ("cancel" eventId "event")
                  ("ready" clientId nil) ("cancel" eventId nil)))
    (pcase-let* ((`(,type ,key ,id) case)
                 (item (dsh-protocol-core-item--from-alist
                        `((type . ,type) (,key . ,id)))))
      (should (equal type (dsh-protocol-core-item-type item)))
      (should (equal id (dsh-protocol-core-item-payload item))))))

(ert-deftest dsh-emacs-test-protocol-waterfall-keeps-request-decoding-late ()
  :tags '(dsh-unit)
  (dolist (name '("user-questions/request" "approval/request" "future-request"))
    (let* ((raw '((wait . ((callId . "call") . bad))))
           (item (dsh-protocol-core-item--from-alist
                  `(("type" . "waterfall") ("event" . ,name)
                    ("eventId" . "event") ("agentId" . "agent")
                    ("request" . ,raw))))
           (waterfall (dsh-protocol-core-item-payload item)))
      (should (equal "waterfall" (dsh-protocol-core-item-type item)))
      (should (equal name (dsh-protocol-waterfall-name waterfall)))
      (should (equal "event" (dsh-protocol-waterfall-event-id waterfall)))
      (should (equal "agent" (dsh-protocol-waterfall-agent-id waterfall)))
      (should (eq raw (dsh-protocol-waterfall-request waterfall)))))
  (dolist (array (list #'identity #'vconcat))
    (let* ((questions '(((id . "q") (question . "First?")) malformed-later-item))
           (request (dsh-protocol-question-request--from-alist
                     `(("questions" . ,(funcall array questions))
                       ("wait" . (("callId" . "call") ("timed" . t))))))
           (wait (dsh-protocol-question-request-wait request)))
      ;; Preserve question objects and their order for the existing readers.
      (should (equal questions (dsh-protocol-question-request-questions request)))
      (should (eq (car questions)
                  (car (dsh-protocol-question-request-questions request))))
      (should (equal "call" (dsh-protocol-question-wait-call-id wait)))
      (should (dsh-protocol-question-wait-timed wait))))
  (dolist (wait '(nil [] :json-false "invalid"))
    (let ((request (dsh-protocol-question-request--from-alist
                    `((questions . []) (wait . ,wait)))))
      (should-not (dsh-protocol-question-request-questions request))
      (should-not (dsh-protocol-question-request-wait request)))))

;; Empty question text is presentational; the options still belong to the
;; card.  Only a question with neither an id nor text is unusable.
(ert-deftest dsh-emacs-test-protocol-ask-questions-keeps-empty-text-with-id ()
  :tags '(dsh-unit)
  (let* ((args (json-encode
                '((questions
                   . [((id . "q1") (question . "")
                       (options . [((label . "A")) ((label . "B"))]))
                      ((question . "")
                       (options . [((label . "dropped"))]))]))))
         (questions (dsh-protocol-ask-questions--from-alist args)))
    (should (= 1 (length questions)))
    (should (equal "q1" (dsh-protocol-question-id (car questions))))
    (should (equal '("A" "B")
                   (mapcar #'dsh-protocol-question-option-label
                           (dsh-protocol-question-options
                            (car questions)))))))

;; --- Test 57: protocol layer workspace baseline / workspace-result
;; / model-selection-result ---
;; workspace/follow baseline top-level values: items array->list,
;; archivedSessionIds array->list
(ert-deftest dsh-emacs-test-protocol-protocol-workspace-list-conversion ()
  :tags '(dsh-unit)
  (let* ((value '((items . [((workspaceId . "w1") (title . "WS A")
                             (path . "/tmp/a") (sessionIds . ["s1" "s2"])
                             (createdAt . "2026-08-25T00:00:00Z")
                             (updatedAt . "2026-08-25T01:00:00Z"))
                            ((workspaceId . "w2") (title . "WS B")
                             (path . "/tmp/b") (sessionIds . []))])
                  (archivedSessionIds . ["s9"])))
         (wl (dsh-protocol-workspace-list--from-alist value))
         (items (dsh-protocol-workspace-list-items wl))
         (w1 (car items)))
    (ert-info ((format "%s" "protocol-workspace-list-conversion"))
      (should (and (= (length items) 2)
                   (equal (dsh-protocol-workspace-list-archived-session-ids wl)
                          '("s9"))
                   ;; items converted inline + arrays normalized to lists
                   (dsh-protocol-workspace-p w1)
                   (equal (dsh-protocol-workspace-session-ids w1) '("s1" "s2"))
                   ;; WorkspaceView official fields complete
                   (string= (dsh-protocol-workspace-title w1) "WS A")
                   (string= (dsh-protocol-workspace-created-at w1)
                            "2026-08-25T00:00:00Z")
                   (string= (dsh-protocol-workspace-updated-at w1)
                            "2026-08-25T01:00:00Z")
                   (string= (dsh-protocol-workspace-path w1) "/tmp/a")
                   (string= (dsh-protocol-workspace-workspace-id
                             (car (dsh-protocol-workspace-list-items
                                   (dsh-protocol-workspace-list--from-alist
                                    '((items . [((workspaceId . "w2"))]))))))
                            "w2"))))))

;; workspace/create response: {workspace, created}
(ert-deftest dsh-emacs-test-protocol-protocol-workspace-create-result ()
  :tags '(dsh-unit)
  (let* ((value '((workspace . ((workspaceId . "w3") (title . "New")
                                (path . "/tmp/new") (sessionIds . [])
                                (createdAt . "x") (updatedAt . "y")))
                  (created . t)))
         (r (dsh-protocol-workspace-result--from-alist value)))
    (ert-info ((format "%s" "protocol-workspace-create-result"))
      (should (and (dsh-protocol-workspace-p (dsh-protocol-workspace-result-workspace r))
                   (eq (dsh-protocol-workspace-result-created r) t)
                   (string= (dsh-protocol-workspace-title
                             (dsh-protocol-workspace-result-workspace r))
                            "New"))))))

;; workspace/rename / insertSessionBefore response: only {workspace},
;; created is nil
(ert-deftest dsh-emacs-test-protocol-protocol-workspace-rename-result ()
  :tags '(dsh-unit)
  (let* ((r (dsh-protocol-workspace-result--from-alist
             '((workspace . ((workspaceId . "w1") (title . "Renamed"))))))
         (d (dsh-protocol-workspace-result-created r)))
    (ert-info ((format "%s" "protocol-workspace-rename-result"))
      (should (and (string= (dsh-protocol-workspace-title
                             (dsh-protocol-workspace-result-workspace r))
                            "Renamed")
                   (null d))))))

(ert-deftest dsh-emacs-test-protocol-model-selection-projection-last-used-only ()
  :tags '(dsh-unit)
  (dolist (wire
           '(((lastUsed . ((provider . "used-provider") (model . "used-model")
                           (reasoningEffort . "high")))
              (next . ((provider . "next-provider") (model . "next-model"))))
             (("lastUsed" . (("provider" . "used-provider")
                             ("model" . "used-model")
                             ("reasoningEffort" . "high")))
              ("next" . (("provider" . "next-provider")
                         ("model" . "next-model"))))))
    (let ((selection
           (dsh-protocol-model-selection-projection--from-alist wire)))
      (should (dsh-protocol-model-selection-p selection))
      (should (equal "used-provider"
                     (dsh-protocol-model-selection-provider selection)))
      (should (equal "used-model"
                     (dsh-protocol-model-selection-model selection)))
      (should (equal "high"
                     (dsh-protocol-model-selection-reasoning-effort selection)))))
  (dolist (wire
           '(nil
             ((next . ((provider . "next-provider") (model . "next-model"))))
             ((lastUsed . nil)
              (next . ((provider . "next-provider") (model . "next-model"))))
             (("lastUsed" . nil)
              ("next" . (("provider" . "next-provider")
                         ("model" . "next-model"))))))
    (should-not (dsh-protocol-model-selection-projection--from-alist wire))))

(ert-deftest dsh-emacs-test-protocol-model-selection-projection-surfaces ()
  :tags '(dsh-unit)
  (dolist (effort '(nil "high"))
    (let* ((projection
            `((lastUsed . ((provider . "used-provider") (model . "used-model")
                           ,@(when effort `((reasoningEffort . ,effort)))))
              (next . ((provider . "next-provider") (model . "next-model")
                       (reasoningEffort . "low")))))
           (baseline `((asOfSeq . 23) (values (modelSelection . ,projection))))
           (row (dsh-protocol-session--from-alist
                 `((sessionId . "model-session") (projections . ,baseline))))
           (increment (dsh-protocol-projection--from-alist
                       `((sessionId . "model-session") (key . "modelSelection")
                         (seq . 24) (value . ,projection))))
           (control (dsh-protocol-control-session--from-alist
                     (cons "model-session" baseline)))
           (control-model
            (cl-find "modelSelection"
                     (dsh-protocol-control-session-projections control)
                     :key #'dsh-protocol-projection-key :test #'equal))
           (snapshot (dsh-protocol-follow-snapshot--from-alist
                      `((cursor . 23) (records . [])
                        (projections . ,baseline))))
           (follow (dsh-protocol-follow-projections--from-alist
                    (dsh-protocol-follow-snapshot-projections snapshot))))
      (should (equal "model-session"
                     (dsh-protocol-projection-session-id increment)))
      (should (equal "model-session"
                     (dsh-protocol-projection-session-id control-model)))
      (dolist (surface
               (list (cons 'row (dsh-protocol-session-model-selection row))
                     (cons 'increment (dsh-protocol-projection-value increment))
                     (cons 'control (dsh-protocol-projection-value control-model))
                     (cons 'follow
                           (dsh-protocol-follow-projections-model-selection follow))))
        (ert-info ((format "surface=%s effort=%S" (car surface) effort))
          (let ((selection (cdr surface)))
            (should (dsh-protocol-model-selection-p selection))
            (should (equal "used-provider"
                           (dsh-protocol-model-selection-provider selection)))
            (should (equal "used-model"
                           (dsh-protocol-model-selection-model selection)))
            (should (equal effort
                           (dsh-protocol-model-selection-reasoning-effort
                            selection)))))))))

;; session/selectModel response: {selected}
(ert-deftest dsh-emacs-test-protocol-protocol-model-selection-result ()
  :tags '(dsh-unit)
  (let* ((r (dsh-protocol-model-selection-result--from-alist
             '((selected . ((provider . "deepseek")
                            (model . "deepseek-chat")
                            (reasoningEffort . "high"))))))
         (sel (dsh-protocol-model-selection-result-selected r)))
    (ert-info ((format "%s" "protocol-model-selection-result"))
      (should (and (dsh-protocol-model-selection-p sel)
                   (string= (dsh-protocol-model-selection-provider sel) "deepseek")
                   (string= (dsh-protocol-model-selection-model sel) "deepseek-chat")
                   (string= (dsh-protocol-model-selection-reasoning-effort sel)
                            "high"))))))

(ert-deftest dsh-emacs-test-protocol-message-envelope-and-attachments ()
  :tags '(dsh-unit)
  (let* ((event '((data . ((content . [((type . "text") (text . "user"))])
                           (message . ((content . [((type . "text") (text . "assistant"))])))
                           (source . ((kind . "session-reference")
                                      (references . [((sessionId . "s1") (label . "one"))])))))))
         (user (dsh-protocol-message--from-alist event))
         (assistant (dsh-protocol-message--from-alist event :assistant t))
         (image (dsh-protocol-content-block--from-alist
                 '((type . "image") (name . "inline")
                   (attachment . ((name . "nested") (attachmentId . "img")
                                  (mediaType . "image/png")))))))
    (should (equal (dsh-protocol-content-block-text
                    (car (dsh-protocol-message-content user))) "user"))
    (should (equal (dsh-protocol-content-block-text
                    (car (dsh-protocol-message-content assistant))) "assistant"))
    (should (equal (dsh-protocol-message-references user) '(("one" . "s1"))))
    (should (equal (dsh-protocol-content-block-name image) "inline"))
    (should (equal (dsh-protocol-content-block-attachment-id image) "img"))
    (should (equal (dsh-protocol-content-block-media-type image) "image/png"))))

(ert-deftest dsh-emacs-test-protocol-request-and-usage-envelopes ()
  :tags '(dsh-unit)
  (let ((config (dsh-protocol-request-model--from-alist
                 '(("data" . (("header" . (("config" . (("model" . "m")
                                                        ("provider" . "p")
                                                        ("reasoningEffort" . "high")))))))) :header-p t)))
    (should (equal (dsh-protocol-model-selection-model config) "m"))
    (should (equal (dsh-protocol-model-selection-provider config) "p"))
    (should (equal (dsh-protocol-model-selection-reasoning-effort config) "high")))
  (should-not (dsh-protocol-request-model--from-alist '((data . ((other . t)))) :header-p t))
  (should (equal (dsh-protocol-message-usage--from-alist
                  '((data . ((usage . ((inputTokens . "11") (input . 99)
                                       (output . 7) (cacheReadTokens . 3)
                                       (cacheWrite . "2") (cost . "0.25")))))) :event-p t)
                 '(11 7 3 2 0.25)))
  (should (equal (dsh-protocol-message-usage--from-alist nil :event-p t) '(0 0 0 0 0.0))))

(ert-deftest dsh-emacs-test-protocol-tool-arguments-precedence-and-fallback ()
  :tags '(dsh-unit)
  (let ((args (dsh-protocol-tool-arguments--from-alist
               "{\"description\":\"wrong\",\"job_id\":\"job-7\",\"command\":\"pwd\"}"
               "job_output" "bash")))
    (should (equal (dsh-protocol-tool-arguments-summary args) "job-7"))
    (should (equal (dsh-protocol-tool-arguments-command args) "pwd")))
  (let ((args (dsh-protocol-tool-arguments--from-alist
               "{\"files\":[{\"path\":\"a\"},{\"path\":\"\"},{\"path\":\"b\"}]}" "present")))
    (should (equal (dsh-protocol-tool-arguments-paths args) '("a" "b"))))
  (should-not (dsh-protocol-tool-arguments-object
               (dsh-protocol-tool-arguments--from-alist "{broken"))))

(ert-deftest dsh-emacs-test-protocol-rpc-and-upload-envelopes ()
  :tags '(dsh-unit)
  (should (equal (dsh-protocol-rpc-result--from-alist
                  '((result . ((ok . t) (value . 42))))) '(t . 42)))
  (should (equal (dsh-protocol-rpc-result--from-alist
                  '((result . ((ok . :json-false) (error . "inner")))
                    (message . "outer"))) '(nil . "inner")))
  (should (equal (dsh-protocol-rpc-result--from-alist
                  '((message . "provider message") (error . "provider error")))
                 '(nil . "provider message")))
  (should (equal (dsh-protocol-rpc-result--from-alist
                  '((ok . t) (value . "receipt")) :direct-p t) '(t . "receipt")))
  (should (equal (dsh-protocol-rpc-result--from-alist
                  '((ok . :json-false) (error . "upload error")) :direct-p t)
                 '(nil . "upload error")))
  (should (equal (dsh-protocol-rpc-result--from-alist
                  '((message . "not an upload error")) :direct-p t) '(nil))))

(ert-deftest dsh-emacs-test-protocol-rpc-error-accessors ()
  :tags '(dsh-unit)
  (let* ((value '((code . "agent-preset/not-found")
                  (message . "Unknown agent preset: focused-investigation")
                  (details . ((agentPreset . "focused-investigation")
                              (available . ["standard" "tiny"])))))
         (error (dsh-protocol-rpc-error--from-alist value)))
    (should (equal "agent-preset/not-found"
                   (dsh-protocol-rpc-error-code error)))
    (should (equal "Unknown agent preset: focused-investigation"
                   (dsh-protocol-rpc-error-message error)))
    (should (equal '((agentPreset . "focused-investigation")
                     (available . ["standard" "tiny"]))
                   (dsh-protocol-rpc-error-details error)))
    (should (equal '("focused-investigation" "standard" "tiny")
                   (dsh-protocol-agent-preset-error--from-alist value))))
  (should-not (dsh-protocol-rpc-error-code
               (dsh-protocol-rpc-error--from-alist "boom")))
  (should-not (dsh-protocol-agent-preset-error--from-alist nil))
  (should-not (dsh-protocol-agent-preset-error--from-alist
               '((code . "gateway/internal") (message . "boom")))))

(ert-deftest dsh-emacs-test-protocol-plan-json-boundary ()
  :tags '(dsh-unit)
  (let ((json-object-type 'hash-table)
        (json-key-type 'string))
    (should (equal (dsh-protocol-plan-document-text
                    (dsh-protocol-plan-document--from-alist
                     "{\"plan\":\"# Next\\nDo work\"}" :json-p t))
                   "# Next\nDo work")))
  (should-not (dsh-protocol-plan-document-text
               (dsh-protocol-plan-document--from-alist "42" :json-p t)))
  (should-error (dsh-protocol-plan-document--from-alist "{broken" :json-p t)
                :type 'json-error))

(ert-deftest dsh-emacs-test-protocol-tool-json-ignores-dynamic-json-settings ()
  :tags '(dsh-unit)
  ;; Tool payloads must decode to the wire object shape even when a caller
  ;; has dynamically rebound the JSON reader's settings.
  (let ((json-object-type 'hash-table)
        (json-key-type 'string))
    (should (equal '((a . 1)) (dsh-protocol--tool-json "{\"a\":1}")))
    (should (equal '(("A" . "completed"))
                   (dsh-protocol-todos--from-alist
                    "{\"todos\":[{\"content\":\"A\",\"status\":\"completed\"}]}")))
    (should (equal '("a.txt" nil "x")
                   (dsh-protocol-intended-diff--from-alist
                    "write" "{\"file_path\":\"a.txt\",\"content\":\"x\"}")))))

(ert-deftest dsh-emacs-test-protocol-outbound-simple-request-contracts ()
  :tags '(dsh-unit)
  (dolist (case
           '((dsh-protocol-session-rename-request ("s" "Title")
              "{\"request\":{\"sessionId\":\"s\",\"title\":\"Title\"}}")
             (dsh-protocol-session-cancel-request ("s")
              "{\"request\":{\"sessionId\":\"s\"}}")
             (dsh-protocol-session-attachment-request ("s" "image-2")
              "{\"request\":{\"sessionId\":\"s\",\"attachmentId\":\"image-2\"}}")
             (dsh-protocol-workspace-archive-session-request ("s")
              "{\"request\":{\"sessionId\":\"s\"}}")
             (dsh-protocol-workspace-create-request ("/project")
              "{\"request\":{\"path\":\"/project\"}}")
             (dsh-protocol-workspace-rename-request ("w" "Workspace")
              "{\"request\":{\"workspaceId\":\"w\",\"title\":\"Workspace\"}}")
             (dsh-protocol-workspace-delete-request ("w")
              "{\"request\":{\"workspaceId\":\"w\"}}")
             (dsh-protocol-job-list-request ("s")
              "{\"request\":{\"sessionId\":\"s\"}}")
             (dsh-protocol-job-kill-request ("s" "job-2")
              "{\"request\":{\"sessionId\":\"s\",\"jobId\":\"job-2\"}}")
             (dsh-protocol-skills-list-request ("s")
              "{\"request\":{\"sessionId\":\"s\"}}")))
    (pcase-let ((`(,encoder ,arguments ,json) case))
      (ert-info ((symbol-name encoder))
        (let ((args (apply encoder arguments)))
          (should (equal args (dsh-protocol-read-json json)))
          (should (equal (dsh-protocol-write-json args) json)))))))

(ert-deftest dsh-emacs-test-protocol-outbound-optional-request-fields ()
  :tags '(dsh-unit)
  (dolist (case
           '((dsh-protocol-session-select-model-request ("s" "p" "m" nil)
              "{\"request\":{\"sessionId\":\"s\",\"provider\":\"p\",\"model\":\"m\"}}")
             (dsh-protocol-session-select-model-request ("s" "p" "m" "high")
              "{\"request\":{\"sessionId\":\"s\",\"provider\":\"p\",\"model\":\"m\",\"reasoningEffort\":\"high\"}}")
             (dsh-protocol-workspace-insert-before-request ("w" nil)
              "{\"request\":{\"workspaceId\":\"w\"}}")
             (dsh-protocol-workspace-insert-before-request ("w" "before")
              "{\"request\":{\"workspaceId\":\"w\",\"beforeWorkspaceId\":\"before\"}}")
             (dsh-protocol-job-follow-request ("job-2")
              "{\"request\":{\"jobId\":\"job-2\"}}")
             (dsh-protocol-job-follow-request ("job-2" "s")
              "{\"request\":{\"jobId\":\"job-2\",\"sessionId\":\"s\"}}")))
    (pcase-let ((`(,encoder ,arguments ,json) case))
      (ert-info ((format "%s %S" encoder arguments))
        (let ((args (apply encoder arguments)))
          (should (equal args (dsh-protocol-read-json json)))
          (should (equal (dsh-protocol-write-json args) json)))))))

(ert-deftest dsh-emacs-test-protocol-outbound-session-list-empty-object ()
  :tags '(dsh-unit)
  (let ((args (dsh-protocol-session-list-request)))
    (should (= (length args) 1))
    (should (eq (caar args) '_request))
    (should (hash-table-p (cdar args)))
    (should (= (hash-table-count (cdar args)) 0))
    (should (equal (dsh-protocol-write-json args) "{\"_request\":{}}"))))

(ert-deftest dsh-emacs-test-protocol-outbound-follow-address-and-window ()
  :tags '(dsh-unit)
  (dolist (subagent '(nil t))
    (dolist (limit '(nil 0 8))
      (let* ((address (and subagent
                           (dsh-protocol-subagent-address-create
                            "parent" "child" "continuable")))
             (wire-address (if subagent
                               '((kind . "subagent") (parentSessionId . "parent")
                                 (childSessionId . "child") (mode . "continuable"))
                             '((kind . "session") (sessionId . "s"))))
             (args (dsh-protocol-session-follow-request "s" address limit 3))
             (expected `((request . ((address . ,wire-address)
                                    (assistantStream . t)
                                    ,@(when limit `((maxMessages . ,limit)))
                                    (turnWindow . ((minMessages . 1) (minTurns . 3)))))))
             (json (concat
                    "{\"request\":{\"address\":"
                    (if subagent
                        "{\"kind\":\"subagent\",\"parentSessionId\":\"parent\",\"childSessionId\":\"child\",\"mode\":\"continuable\"}"
                      "{\"kind\":\"session\",\"sessionId\":\"s\"}")
                    ",\"assistantStream\":true"
                    (if limit (format ",\"maxMessages\":%d" limit) "")
                    ",\"turnWindow\":{\"minMessages\":1,\"minTurns\":3}}}")))
        (ert-info ((format "subagent=%S limit=%S" subagent limit))
          (should (equal args expected))
          (should (equal (dsh-protocol-write-json args) json)))))))

(ert-deftest dsh-emacs-test-protocol-outbound-prompt-caption-parts-and-modes ()
  :tags '(dsh-unit)
  (dolist (mode '("queue" "steer"))
    (dolist (attachments '(nil t))
      (let* ((parts (and attachments
                         '(((type . "image") (mediaType . "image/png")
                            (data . "aW1n") (name . "image.png"))
                           ((type . "file") (receiptId . "receipt-2")))))
             (content (dsh-protocol-prompt-content "caption" parts))
             (expected-content
              (if attachments
                  [((type . "text") (text . "caption"))
                   ((type . "image") (mediaType . "image/png")
                    (data . "aW1n") (name . "image.png"))
                   ((type . "file") (receiptId . "receipt-2"))]
                [((type . "text") (text . "caption"))]))
             (args (dsh-protocol-session-prompt-request
                    "s" "request-2" mode content "UTC"))
             (json (concat
                    "{\"request\":{\"requestId\":\"request-2\",\"sessionId\":\"s\",\"mode\":\""
                    mode "\",\"content\":[{\"type\":\"text\",\"text\":\"caption\"}"
                    (if attachments
                        ",{\"type\":\"image\",\"mediaType\":\"image/png\",\"data\":\"aW1n\",\"name\":\"image.png\"},{\"type\":\"file\",\"receiptId\":\"receipt-2\"}"
                      "")
                    "],\"clientTimeZone\":\"UTC\"}}")))
        (ert-info ((format "mode=%s attachments=%S" mode attachments))
          (should (equal content expected-content))
          (should (equal args
                         `((request . ((requestId . "request-2") (sessionId . "s")
                                       (mode . ,mode) (content . ,expected-content)
                                       (clientTimeZone . "UTC"))))))
          (should (equal (dsh-protocol-write-json args) json)))))))

(ert-deftest dsh-emacs-test-protocol-outbound-queue-action-contracts ()
  :tags '(dsh-unit)
  (dolist (case
           (list
            (list (dsh-protocol-queue-remove-action) "{\"kind\":\"remove\"}")
            (list (dsh-protocol-queue-steer-action) "{\"kind\":\"steer\"}")
            (list (dsh-protocol-queue-edit-action "replacement")
                  "{\"kind\":\"edit\",\"content\":[{\"type\":\"text\",\"text\":\"replacement\"}]}")
            (list (dsh-protocol-queue-edit-action "")
                  "{\"kind\":\"edit\",\"content\":[{\"type\":\"text\",\"text\":\"\"}]}")))
    (pcase-let* ((`(,action ,action-json) case)
                 (args (dsh-protocol-session-update-queue-request
                        "s" "item-2" action)))
      (ert-info ((cdr (assq 'kind action)))
        (should (equal args
                       `((request . ((sessionId . "s") (itemId . "item-2")
                                     (action . ,action))))))
        (should (equal (dsh-protocol-write-json args)
                       (concat "{\"request\":{\"sessionId\":\"s\",\"itemId\":\"item-2\",\"action\":"
                               action-json "}}")))))))

(ert-deftest dsh-emacs-test-protocol-outbound-command-requests ()
  :tags '(dsh-unit)
  (should (equal (dsh-protocol-commands-list-request "s") '((agentId . "s"))))
  (should (equal (dsh-protocol-write-json
                  (dsh-protocol-commands-execute-request "s" "/plan off" nil))
                 (concat "{\"agentId\":\"s\",\"line\":\"/plan off\","
                         "\"submittedAttachments\":[]}")))
  (let* ((parts '(((type . "image") (mediaType . "image/png") (data . "eA=="))
                  ((type . "file") (receiptId . "receipt-2"))))
         (json (concat "{\"agentId\":\"s\",\"line\":\"/inspect\","
                       "\"submittedAttachments\":[{\"type\":\"image\","
                       "\"mediaType\":\"image/png\",\"data\":\"eA==\"},"
                       "{\"type\":\"file\",\"receiptId\":\"receipt-2\"}]}")))
    (dolist (input (list parts (vconcat parts)))
      (let ((args (dsh-protocol-commands-execute-request "s" "/inspect" input)))
        (should (equal args (dsh-protocol-read-json json)))
        (should (equal (dsh-protocol-write-json args) json))
        (should (eq (aref (cdr (assq 'submittedAttachments args)) 0)
                    (car parts)))))))

(ert-deftest dsh-emacs-test-protocol-outbound-reference-query-request ()
  :tags '(dsh-unit)
  (dolist (case '(("" "{\"agentId\":\"s\",\"query\":\"\"}")
                  ("src/a b" "{\"agentId\":\"s\",\"query\":\"src/a b\"}")))
    (pcase-let* ((`(,query ,json) case)
                 (args (dsh-protocol-reference-query-request "s" query)))
      (should (equal args `((agentId . "s") (query . ,query))))
      (should (equal (dsh-protocol-write-json args) json)))))

(ert-deftest dsh-emacs-test-protocol-outbound-goal-mutation-request ()
  :tags '(dsh-unit)
  (dolist (revision '(0 7))
    (let ((goal (dsh-protocol-goal--from-alist
                 `((id . "goal-1") (revision . ,revision)
                   (objective . "Original") (phase . "paused")))))
      (dolist (case '((nil "")
                      ("" ",\"request\":{\"objective\":\"\"}")
                      ("New\nobjective" ",\"request\":{\"objective\":\"New\\nobjective\"}")))
        (pcase-let* ((`(,objective ,suffix) case)
                     (args (dsh-protocol-goal-mutation-request "s" goal objective))
                     (json (concat "{\"agentId\":\"s\",\"ref\":{\"id\":\"goal-1\","
                                   (format "\"revision\":%d}" revision) suffix "}")))
          (should (equal args (dsh-protocol-read-json json)))
          (should (equal (dsh-protocol-write-json args) json))
          (should (= (dsh-protocol-goal-revision goal) revision))
          (should (equal (dsh-protocol-goal-objective goal) "Original")))))))

(ert-deftest dsh-emacs-test-protocol-outbound-provider-settings-create ()
  :tags '(dsh-unit)
  (let* ((section (dsh-protocol-provider-settings--from-alist
                   '((ns . "adapter") (revision . 0))))
         (args (dsh-protocol-provider-settings-request
                section "custom" nil :endpoint "https://example.invalid/v1"
                :api "openai-completions" :models '("m1" "m2") :key-ref "TEST_KEY"))
         (json (concat "{\"ns\":\"adapter\",\"expectedRevision\":0,\"ops\":[{\"op\":\"set\","
                       "\"path\":[\"providers\",\"custom\"],\"value\":{\"apiKeyEnv\":\"TEST_KEY\","
                       "\"models\":[{\"id\":\"m1\"},{\"id\":\"m2\"}],\"api\":\"openai-completions\","
                       "\"baseURL\":\"https://example.invalid/v1\"}}]}")))
    (should (equal args (dsh-protocol-read-json json)))
    (should (equal (dsh-protocol-write-json args) json))
    (should (= (dsh-protocol-provider-settings-revision section) 0))))

(ert-deftest dsh-emacs-test-protocol-outbound-provider-settings-update ()
  :tags '(dsh-unit)
  (let* ((section (dsh-protocol-provider-settings--from-alist
                   '((ns . "adapter") (revision . 7))))
         (profile (dsh-protocol-provider-profile--from-alist
                   '((baseURL . "https://old.invalid") (apiKeyEnv . "KEEP_KEY"))))
         (args (dsh-protocol-provider-settings-request
                section "keep" profile :endpoint "https://new.invalid"))
         (json (concat "{\"ns\":\"adapter\",\"expectedRevision\":7,\"ops\":[{\"op\":\"set\","
                       "\"path\":[\"providers\",\"keep\",\"baseURL\"],"
                       "\"value\":\"https://new.invalid\"}]}")))
    (should (equal args (dsh-protocol-read-json json)))
    (should (equal (dsh-protocol-write-json args) json))
    (should (equal (dsh-protocol-provider-profile-endpoint profile)
                   "https://old.invalid"))))

(ert-deftest dsh-emacs-test-protocol-outbound-provider-empty-settings ()
  :tags '(dsh-unit)
  (let ((section (dsh-protocol-provider-settings--from-alist
                  '((ns . "adapter") (revision . 9)))))
    (dolist (profile (list nil (dsh-protocol-provider-profile--from-alist nil)))
      (let ((args (dsh-protocol-provider-settings-request section "catalog" profile)))
        (should (equal (dsh-protocol-write-json args)
                       (if profile
                           "{\"ns\":\"adapter\",\"expectedRevision\":9,\"ops\":[]}"
                         (concat "{\"ns\":\"adapter\",\"expectedRevision\":9,\"ops\":[{"
                                 "\"op\":\"set\",\"path\":[\"providers\",\"catalog\"],"
                                 "\"value\":{}}]}"))))))))

(ert-deftest dsh-emacs-test-protocol-outbound-credential-requests ()
  :tags '(dsh-unit)
  (should (equal (dsh-protocol-credentials-describe-request "TEST_KEY")
                 '((refs . ["TEST_KEY"]))))
  (should (equal (dsh-protocol-write-json
                  (dsh-protocol-credentials-set-request "TEST_KEY" "fake-key"))
                 "{\"ref\":\"TEST_KEY\",\"value\":\"fake-key\"}")))

(ert-deftest dsh-emacs-test-protocol-outbound-interaction-args ()
  :tags '(dsh-unit)
  (let* ((outcome '((kind . "result") (value . "opaque")))
         (args (dsh-protocol-events-result-request "client" "event" outcome)))
    (should (equal args '((clientId . "client") (eventId . "event")
                          (outcome . ((kind . "result") (value . "opaque"))))))
    (should (eq (cdr (assq 'outcome args)) outcome))
    (should (equal (dsh-protocol-write-json args)
                   (concat "{\"clientId\":\"client\",\"eventId\":\"event\","
                           "\"outcome\":{\"kind\":\"result\",\"value\":\"opaque\"}}"))))
  (should (equal (dsh-protocol-question-wait-request "s" "call")
                 '((agentId . "s") (callId . "call")))))

(ert-deftest dsh-emacs-test-protocol-outbound-question-answer-shapes ()
  :tags '(dsh-unit)
  (dolist (case '((nil nil "{\"id\":\"q\",\"selected\":null}")
                  ([] nil "{\"id\":\"q\",\"selected\":[]}")
                  (("B" "A") nil "{\"id\":\"q\",\"selected\":[\"B\",\"A\"]}")
                  (["B" "A"] nil "{\"id\":\"q\",\"selected\":[\"B\",\"A\"]}")
                  ([] "" "{\"id\":\"q\",\"selected\":[],\"custom\":\"\"}")
                  ([] "Other" "{\"id\":\"q\",\"selected\":[],\"custom\":\"Other\"}")))
    (pcase-let* ((`(,selected ,custom ,json) case)
                 (answer (dsh-protocol-question-answer-request "q" selected custom)))
      (should (eq (cdr (assq 'selected answer)) selected))
      (should (equal (dsh-protocol-write-json answer) json)))))

(ert-deftest dsh-emacs-test-protocol-outbound-interaction-outcomes ()
  :tags '(dsh-unit)
  (dolist (case
           (list
            (list (dsh-protocol-approval-outcome t)
                  "{\"kind\":\"result\",\"value\":\"allowed-once\"}")
            (list (dsh-protocol-approval-outcome nil)
                  "{\"kind\":\"result\",\"value\":\"rejected\"}")
            (list (dsh-protocol-events-next-outcome) "{\"kind\":\"next\"}")
            (list (dsh-protocol-events-cancelled-outcome "User abandoned the questions")
                  (concat "{\"kind\":\"rejected\",\"error\":{\"name\":\"cancelled\","
                          "\"message\":\"User abandoned the questions\"}}"))
            (list (dsh-protocol-events-cancelled-outcome "User requested plan changes")
                  (concat "{\"kind\":\"rejected\",\"error\":{\"name\":\"cancelled\","
                          "\"message\":\"User requested plan changes\"}}"))))
    (pcase-let ((`(,outcome ,json) case))
      (should (equal (dsh-protocol-write-json outcome) json)))))

(ert-deftest dsh-emacs-test-protocol-outbound-question-batch-shapes ()
  :tags '(dsh-unit)
  (let* ((rows '(((id . "q1") (selected . ("B" "A")))
                 ((id . "q2") (selected . []) (custom . "Other"))))
         (json (concat "[{\"id\":\"q1\",\"selected\":[\"B\",\"A\"]},"
                       "{\"id\":\"q2\",\"selected\":[],\"custom\":\"Other\"}]")))
    (dolist (answers (list rows (vconcat rows)))
      (let ((outcome (dsh-protocol-question-result-outcome answers))
            (late (dsh-protocol-question-late-answer-request "s" "call" answers)))
        (should (eq (cdr (assq 'answers (cdr (assq 'value outcome)))) answers))
        (should (eq (cdr (assq 'answers (cdr (assq 'answer late)))) answers))
        (should (equal (dsh-protocol-write-json outcome)
                       (concat "{\"kind\":\"result\",\"value\":{\"answers\":" json "}}")))
        (should (equal (dsh-protocol-write-json late)
                       (concat "{\"agentId\":\"s\",\"callId\":\"call\","
                               "\"answer\":{\"answers\":" json "}}")))))))

(ert-deftest dsh-emacs-test-protocol-outbound-image-descriptor ()
  :tags '(dsh-unit)
  (let* ((bytes (concat (unibyte-string 0 255 13 10) (make-string 80 ?x)))
         (expected (concat "AP8NCnh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4"
                           "eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4"))
         (attachment (dsh-protocol-image-attachment "image/png" bytes "fake.png")))
    (should (> (length expected) 76))
    (should (equal attachment
                   `((mediaType . "image/png") (data . ,expected) (name . "fake.png"))))
    (should-not (string-match-p "\n" (cdr (assq 'data attachment))))))

(ert-deftest dsh-emacs-test-protocol-outbound-image-part-preserves-descriptor ()
  :tags '(dsh-unit)
  (let* ((attachment '((name . "fake.png") (data . "eA==")
                       (mediaType . "image/png") (extra . "opaque")))
         (part (dsh-protocol-image-content-part attachment)))
    (should (eq (cdr part) attachment))
    (should (equal part '((type . "image") (name . "fake.png") (data . "eA==")
                          (mediaType . "image/png") (extra . "opaque"))))
    (should (equal attachment '((name . "fake.png") (data . "eA==")
                                (mediaType . "image/png") (extra . "opaque")))))
  (should-not (dsh-protocol-image-content-part nil))
  (should-not (dsh-protocol-image-content-part
               '((file . "/local/fake.pdf") (name . "fake.pdf") (bytes . 3))))
  (should (equal (dsh-protocol-image-content-part '((mediaType . nil)))
                 '((type . "image") (mediaType . nil)))))

(ert-deftest dsh-emacs-test-protocol-outbound-file-part-is-receipt-only ()
  :tags '(dsh-unit)
  (let* ((receipt (dsh-protocol-file-receipt--from-alist
                   '((receiptId . "receipt-1")
                     (file . ((attachmentId . "sha256:fake")
                              (name . "remote.pdf") (bytes . 23))))))
         (part (dsh-protocol-file-content-part receipt)))
    (should (equal part '((type . "file") (receiptId . "receipt-1"))))
    (should (equal (dsh-protocol-write-json part)
                   "{\"type\":\"file\",\"receiptId\":\"receipt-1\"}"))
    (should (equal (dsh-protocol-file-ref-name
                    (dsh-protocol-file-receipt-file receipt)) "remote.pdf"))))

(ert-deftest dsh-emacs-test-protocol-inbox-splice ()
  :tags '(dsh-unit)
  (let ((splice (dsh-protocol-inbox-splice--from-alist
                 '((type . "agent/inbox/spliced") (seq . 4)
                   (data . ((target . "next-turn") (start . 0)
                            (removedCount . 1) (outcome . "canceled")
                            (inserted . [((id . "a")
                                          (source . ((kind . "agent-message"))))
                                         ((id . "b")
                                          (source . ((kind . "user"))))
                                         ((source . ((kind . "user"))))])))))))
    (should (equal (dsh-protocol-inbox-splice-target splice) "next-turn"))
    (should (equal (dsh-protocol-inbox-splice-start splice) 0))
    (should (equal (dsh-protocol-inbox-splice-removed-count splice) 1))
    (should (equal (dsh-protocol-inbox-splice-outcome splice) "canceled"))
    ;; An entry without an id is not a claimable occurrence.
    (should (equal (dsh-protocol-inbox-splice-inserted splice)
                   '(("a" . "agent-message") ("b" . "user")))))
  (should-not (dsh-protocol-inbox-splice-target
               (dsh-protocol-inbox-splice--from-alist
                '((type . "user/message") (data . ((content . []))))))))

(ert-deftest dsh-emacs-test-protocol-message-trigger-fields ()
  :tags '(dsh-unit)
  (let ((message (dsh-protocol-message--from-alist
                  '((type . "user/message")
                    (data . ((id . "m1")
                             (source . ((kind . "webhook")
                                        (provider . "github")))
                             (content . [])))))))
    (should (equal (dsh-protocol-message-id message) "m1"))
    (should (equal (dsh-protocol-message-source-kind message) "webhook"))
    (should (equal (dsh-protocol-message-source-provider message) "github")))
  ;; An optimistic echo has neither identity nor provider.
  (let ((message (dsh-protocol-message--from-alist
                  '((type . "user/message")
                    (data . ((content . [])))))))
    (should-not (dsh-protocol-message-id message))
    (should-not (dsh-protocol-message-source-provider message))))

(ert-deftest dsh-emacs-test-protocol-history-human-rounds ()
  :tags '(dsh-unit)
  (cl-labels ((record (type seq data)
                (list (cons 'type "event")
                      (cons 'event (list (cons 'type type)
                                         (cons 'seq seq)
                                         (cons 'data data))))))
    (let* ((records
            (list (record "turn/start" 1 '((turn . 1)))
                  (record "user/message" 2
                          '((content . [])
                            (source . ((kind . "agent-message")))))
                  (record "turn/start" 3 '((turn . 2)))
                  (record "user/message" 4
                          '((content . [])
                            (source . ((kind . "user")))))
                  (record "turn/start" 5 '((turn . 3)))
                  (record "user/message" 6 '((content . [])))))
           (snapshot (dsh-protocol-follow-snapshot--from-alist
                      `((records . ,(vconcat records))
                        (hasMore . :json-false)))))
      ;; Only turns with a user-authored message are rounds; a source-less
      ;; message remains author text for fixtures and optimistic echoes.
      (should (equal '(2 3)
                     (mapcar #'car
                             (dsh-protocol-history-human-rounds records))))
      (should (= 2 (dsh-protocol-follow-snapshot-human-round-count
                    snapshot)))
      (should (equal 3 (nth 1 (car (dsh-protocol-history-human-rounds
                                    records))))))))

(provide 'dsh-test-protocol)
;;; dsh-test-protocol.el ends here
