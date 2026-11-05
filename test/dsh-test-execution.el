;;; dsh-test-execution.el --- Execution tests -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "28.1"))

(require 'dsh-test-support)

(ert-deftest dsh-emacs-test-execution-execution-decodes-string-wire-keys ()
  :tags '(dsh-unit)
  (let ((event (dsh-protocol-execution-event--from-alist
                '(("type" . "llm/retry") ("seq" . 10)
                  ("data" . (("retryId" . "chain") ("turn" . 1)
                             ("step" . 2) ("retry" . 3) ("maxRetries" . 5)
                             ("delayMs" . 1234) ("provider" . "test-provider")
                             ("failure" . (("code" . "rate-limit")
                                           ("message" . "Try later")))))))))
    (ert-info ((format "%s" "execution-decodes-string-wire-keys"))
      (should (equal (dsh-protocol-execution-event-id event) "chain"))
      (should (= (dsh-protocol-execution-event-attempt event) 3))
      (should (= (dsh-protocol-execution-event-limit event) 5))
      (should (= (dsh-protocol-execution-event-delay event) 1234))
      (should (equal (dsh-protocol-execution-event-code event) "rate-limit"))
      (should (equal (dsh-protocol-execution-event-message event) "Try later")))))

(ert-deftest dsh-emacs-test-execution-retry-does-not-add-mode-line-status ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs--ml-busy-set t)
    (dolist (type '("llm/retry" "llm/retry-started"))
      (dsh-emacs-render-event
       (dsh-test--execution-event
        type (if (equal type "llm/retry") 1 2)
        '((retryId . "r") (turn . 1) (step . 1) (retry . 1)
          (maxRetries . 3) (delayMs . 2500) (provider . "provider-a")
          (failure . ((code . "rate-limit") (message . "Slow down"))))))
      (should dsh-emacs--ml-busy)
      (should-not (string-match-p "Retry" (dsh-emacs-modeline--ml-indicator)))
      (should-not (string-match-p "retry" (dsh-emacs-modeline--status-detail))))))

(ert-deftest dsh-emacs-test-execution-execution-compaction-without-running-turn ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-render-event
     (dsh-test--execution-event "compaction/start" 1
                                '((compactionId . "manual") (turn . nil))))
    (ert-info ((format "%s" "execution-compaction-without-running-turn"))
      (should (not dsh-emacs--ml-busy))
      (should (string-match-p "\\bCompacting\\b" (dsh-emacs-modeline--ml-indicator))))
    (dsh-emacs-render-event
     (dsh-test--execution-event "turn/end" 2 '((turn . 9))))
    (dsh-emacs-render-event
     (dsh-test--execution-event "compaction/end" 3
                                '((compactionId . "other") (turn . nil))))
    (ert-info ((format "%s" "execution-compaction-matches-identity"))
      (should (string-match-p "\\bCompacting\\b" (dsh-emacs-modeline--ml-indicator))))
    (dsh-emacs-render-event
     (dsh-test--execution-event "llm/retry" 4
                                '((retryId . "r") (retry . 1) (turn . 10)
                                  (step . 1) (maxRetries . 2))))
    (ert-info ((format "%s" "execution-retry-does-not-replace-compaction"))
      (should (string-match-p "Compacting"
                              (dsh-emacs-modeline--ml-indicator))))
    (dsh-emacs-render-event
     (dsh-test--execution-event "compaction/end" 5
                                '((compactionId . "manual") (turn . nil))))
    (ert-info ((format "%s" "execution-compaction-end-leaves-no-retry-label"))
      (should (null dsh-emacs--modeline-compaction))
      (should (null dsh-emacs--modeline-compaction-start))
      (should (string-empty-p (dsh-emacs--ml-busy-indicator)))
      (should (string-empty-p (dsh-emacs-modeline--ml-indicator))))
    (dsh-emacs-render-event
     (dsh-test--execution-event "assistant/message" 6
                                '((turn . 10) (step . 1)
                                  (message . ((role . "assistant")
                                              (content . []))) (stream . []))))
    (ert-info ((format "%s" "execution-success-leaves-mode-line-idle"))
      (should (string-empty-p (dsh-emacs-modeline--ml-indicator))))))

(ert-deftest dsh-emacs-test-execution-execution-turn-scoped-compaction-shows ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-render-event
     (dsh-test--execution-event "compaction/start" 1
                                '((compactionId . "turn-scoped") (turn . 4))))
    (ert-info ((format "%s" "execution-turn-scoped-compaction-shows"))
      (should (string-match-p "\\bCompacting\\b" (dsh-emacs-modeline--ml-indicator))))
    (dsh-emacs-render-event
     (dsh-test--execution-event "turn/end" 2 '((turn . 4))))
    (ert-info ((format "%s" "execution-turn-end-clears-same-turn-compaction"))
      (should (null dsh-emacs--modeline-compaction))
      (should (null dsh-emacs--modeline-compaction-start))
      (should (string-empty-p (dsh-emacs--ml-busy-indicator)))
      (should (string-empty-p (dsh-emacs-modeline--ml-indicator))))))

(ert-deftest dsh-emacs-test-execution-execution-compaction-failure-stays-inspectable ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-render-event
     (dsh-test--execution-event "compaction/start" 1
                                '((compactionId . "auto") (turn . 1))))
    (dsh-emacs-render-event
     (dsh-test--execution-event "compaction/end" 2
                                '((compactionId . "auto") (turn . 1)
                                  (error . "Summary provider unavailable"))))
    (ert-info ((format "%s" "execution-compaction-failure-stays-inspectable"))
      (should (null dsh-emacs--modeline-compaction))
      (should (string-match-p "Context compaction failed" (buffer-string)))
      (should (string-match-p "Summary provider unavailable" (buffer-string))))
    (dsh-emacs-render-event
     (dsh-test--execution-event "command/run" 3
                                '((commandId . "cmd") (name . "compact"))))
    (dsh-emacs-render-event
     (dsh-test--execution-event "compaction/start" 4
                                '((compactionId . "manual")
                                  (sourceCommandId . "cmd") (turn . nil))))
    (dsh-emacs-render-event
     (dsh-test--execution-event "compaction/end" 5
                                '((compactionId . "manual")
                                  (sourceCommandId . "cmd") (turn . nil)
                                  (error . "Manual failure reason"))))
    (dsh-emacs-render-event
     (dsh-test--execution-event "command/done" 6
                                '((commandId . "cmd") (kind . "error")
                                  (text . "Manual failure reason"))))
    (goto-char (car (dsh-emacs-ui-find-block
                     (dsh-emacs-render--make-namespace) "cmd-cmd")))
    (dsh-emacs-ui-toggle-fragment)
    (ert-info ((format "%s" "execution-manual-failure-uses-command-card"))
      (should (null dsh-emacs--modeline-compaction))
      (should (= (how-many "Manual failure reason" (point-min) (point-max)) 1))
      (should (= (how-many "Context compaction failed" (point-min) (point-max)) 1)))))

(ert-deftest dsh-emacs-test-execution-execution-snapshot-folds-below-transcript-anchor ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (setq-local dsh-emacs--buffer-session "execution-snapshot")
    (let* ((retry (dsh-test--execution-event
                   "llm/retry" 10
                   '((retryId . "reconnect") (turn . 1) (step . 2)
                     (retry . 3) (maxRetries . 5))))
           (compact (dsh-test--execution-event
                     "compaction/start" 11
                     '((compactionId . "c") (turn . 1))))
           (snapshot `((cursor . 11)
                       (records . [((type . "event") (event . ,retry))
                                   ((type . "event") (event . ,compact))]))))
      (setq dsh-emacs--anchor-seq 11)
      (dsh-emacs-events--follow-snapshot (current-buffer) snapshot)
      (ert-info ((format "%s" "execution-snapshot-folds-below-transcript-anchor"))
        (should (string-match-p "Compacting"
                                (dsh-emacs-modeline--ml-indicator))))
      (let ((dsh-emacs--history-page t))
        ;; Drop the seq watermark so only the history-page guard can reject the
        ;; replayed record: an older page must never rewind the live status.
        (setq dsh-emacs--modeline-execution-seq nil)
        (dsh-emacs-render-history-events
         (list `((event . ,(dsh-test--execution-event
                            "compaction/end" 1
                            '((compactionId . "c") (turn . 1)))))) nil 10
         :follow-p nil))
      (ert-info ((format "%s" "execution-history-page-keeps-current-status"))
        (should (string-match-p "Compacting"
                                (dsh-emacs-modeline--ml-indicator))))
      (dsh-emacs--ml-busy-clear)
      (ert-info ((format "%s" "execution-teardown-clears-feedback"))
        (should (null dsh-emacs--modeline-compaction))
        (should (null dsh-emacs--modeline-compaction-start))
        (should (string-empty-p (dsh-emacs--ml-busy-indicator)))
        (should (string-empty-p (dsh-emacs-modeline--ml-indicator))))
      (let ((render (symbol-function 'dsh-emacs-render-history-events)))
        (cl-letf (((symbol-function 'dsh-emacs-render-history-events)
                   (lambda (&rest args)
                     (apply render args)
                     (dsh-emacs-events--dispatch-event
                      (current-buffer)
                      (dsh-test--execution-event "compaction/end" 12
                                                 '((compactionId . "c")
                                                   (turn . 1)))))))
          (dsh-emacs-events--follow-snapshot (current-buffer) snapshot)))
      (ert-info ((format "%s" "execution-snapshot-cannot-overwrite-newer-live-event"))
        (should (string-empty-p (dsh-emacs-modeline--ml-indicator))))
      (dsh-emacs-events--follow-snapshot
       (current-buffer)
       `((cursor . 13)
         (records . [((type . "event")
                      (event . ,(dsh-test--execution-event
                                 "turn/end" 13 '((turn . 1)))))])))
      (ert-info ((format "%s" "execution-closed-snapshot-is-idle"))
        (should (null dsh-emacs--modeline-compaction))
        (should (null dsh-emacs--modeline-compaction-start))
        (should (string-empty-p (dsh-emacs--ml-busy-indicator)))
        (should (string-empty-p (dsh-emacs-modeline--ml-indicator))))
      (dsh-emacs-events--follow-snapshot (current-buffer) snapshot)
      (dsh-emacs-events--follow-snapshot
       (current-buffer) '((cursor . 14) (records . [])))
      (ert-info ((format "%s" "execution-missing-snapshot-evidence-clears-stale-status"))
        (should (null dsh-emacs--modeline-compaction))
        (should (null dsh-emacs--modeline-compaction-start))
        (should (string-empty-p (dsh-emacs--ml-busy-indicator)))
        (should (string-empty-p (dsh-emacs-modeline--ml-indicator)))))))

(ert-deftest dsh-emacs-test-execution-execution-state-is-buffer-local ()
  :tags '(dsh-unit)
  (let ((first (generate-new-buffer " *execution-first*"))
        (second (generate-new-buffer " *execution-second*")))
    (unwind-protect
        (progn
          (with-current-buffer first
            (dsh-emacs-mode)
            (dsh-emacs-events--dispatch-event
             first (dsh-test--execution-event
                    "compaction/start" 1 '((compactionId . "c") (turn . nil)))))
          (with-current-buffer second
            (dsh-emacs-mode)
            (ert-info ((format "%s" "execution-state-is-buffer-local"))
              (should (null dsh-emacs--modeline-compaction))
              (should (null dsh-emacs--modeline-compaction-start))
              (should (string-empty-p (dsh-emacs--ml-busy-indicator)))
              (should (string-empty-p (dsh-emacs-modeline--ml-indicator)))))
          (save-window-excursion
            (delete-other-windows)
            (let ((clicked (selected-window)))
              (set-window-buffer clicked first)
              (select-window (split-window-below))
              (switch-to-buffer second)
              (call-interactively
               #'dsh-emacs-describe-status nil
               (vector (list 'mouse-1 (list clicked 'mode-line '(0 . 0) 0))))
              (with-current-buffer "*dsh status*"
                (ert-info ((format "%s" "execution-click-uses-clicked-chat"))
                  (should (equal (buffer-string)
                                 "Compacting context (between turns)\n"))))))
          (with-current-buffer first
            (let ((process (dsh-test--event-process :name "execution-lost" :noquery t)))
              (unwind-protect
                  (progn
                    (setq dsh-emacs--event-process process)
                    (process-put process 'dsh-emacs-chat-buffer first)
                    (cl-letf (((symbol-function 'dsh-emacs-events--schedule-reconnect)
                               #'ignore))
                      (dsh-emacs-events--lost process))
                    (ert-info ((format "%s" "execution-socket-loss-clears-status-now"))
                      (should (null dsh-emacs--modeline-compaction))
                      (should (null dsh-emacs--modeline-compaction-start))
                      (should (string-empty-p (dsh-emacs--ml-busy-indicator)))
                      (should (string-empty-p (dsh-emacs-modeline--ml-indicator)))))
                (delete-process process)))))
      (kill-buffer first)
      (kill-buffer second))))

(ert-deftest dsh-emacs-test-execution-attempt-card-terminal-reasons ()
  :tags '(dsh-unit)
  (should-not (dsh-emacs-render--attempt-cards nil))
  (let ((attempt (dsh-protocol-execution-event--from-alist
                  (dsh-test--execution-event
                   "assistant/attempt" 1 '((turn . 1) (step . 1))))))
    (dolist (case '(("error" "Failed reply" t)
                    ("aborted" "Cancelled reply" t)
                    ("completed" "Incomplete reply" nil)
                    ("future-reason" "Incomplete reply" nil)
                    (nil "Incomplete reply" nil)))
      (pcase-let* ((`(,reason ,label ,settled) case)
                   (end (dsh-protocol-execution-event--from-alist
                         (dsh-test--execution-event
                          "turn/end" 2 `((turn . 1) (reason . ((kind . ,reason)))))))
                   (cards (dsh-emacs-render--attempt-cards
                           (list (cons 1 attempt) (cons 2 end)))))
        (ert-info ((format "Terminal reason %S" reason))
          (should (equal cards
                         (list (list :event attempt :label label
                                     :cause (and settled end))))))))))

(ert-deftest dsh-emacs-test-execution-attempt-card-retry-identity ()
  :tags '(dsh-unit)
  (let* ((attempt (dsh-protocol-execution-event--from-alist
                   (dsh-test--execution-event
                    "assistant/attempt" 1 '((turn . 1) (step . 1)))))
         (retry (dsh-protocol-execution-event--from-alist
                 (dsh-test--execution-event
                  "llm/retry" 2 '((turn . 1) (step . 1)
                                  (retryId . "chain") (retry . 1)))))
         (end (dsh-protocol-execution-event--from-alist
               (dsh-test--execution-event
                "turn/end" 4 '((turn . 1) (reason . ((kind . "aborted"))))))))
    (dolist (case '(("chain" 1 1 "started")
                    ("other" 1 1 "scheduled")
                    ("chain" 2 1 "scheduled")
                    ("chain" 1 2 "scheduled")))
      (pcase-let* ((`(,id ,step ,number ,label) case)
                   (started (dsh-protocol-execution-event--from-alist
                             (dsh-test--execution-event
                              "llm/retry-started" 3
                              `((turn . 1) (step . ,step)
                                (retryId . ,id) (retry . ,number)))))
                   (facts (list (cons 1 attempt) (cons 2 retry) (cons 3 started)))
                   (expected (list (list :event attempt :label label :cause retry)))
                   (cards (dsh-emacs-render--attempt-cards facts)))
        (ert-info ((format "Started identity %S" case))
          (should (equal cards expected))
          (should
           (equal (dsh-emacs-render--attempt-cards
                   (append facts (list (cons 4 end))))
                  (if (equal label "started") expected
                    (list (list :event attempt :label "Retry cancelled"
                                :cause end)))))
          (should (equal cards expected)))))))

(ert-deftest dsh-emacs-test-execution-attempt-card-recovery-step-boundary ()
  :tags '(dsh-unit)
  (dolist (type '("assistant/message" "assistant/attempt"))
    (dolist (step '(1 2))
      (let* ((attempt (dsh-protocol-execution-event--from-alist
                       (dsh-test--execution-event
                        "assistant/attempt" 1 '((turn . 1) (step . 1)))))
             (response (dsh-protocol-execution-event--from-alist
                        (dsh-test--execution-event
                         type 2 `((turn . 1) (step . ,step)))))
             (expected
              (list (list :event attempt
                          :label (if (= step 1) "Retried" "Incomplete reply")
                          :cause (and (= step 1) response)))))
        (when (equal type "assistant/attempt")
          (push (list :event response :label "Incomplete reply" :cause nil)
                expected))
        (ert-info ((format "Recovery %s in step %d" type step))
          (should (equal (dsh-emacs-render--attempt-cards
                          (list (cons 1 attempt) (cons 2 response)))
                         expected)))))))

(ert-deftest dsh-emacs-test-execution-attempt-card-retry-requires-attempt-step ()
  :tags '(dsh-unit)
  (dolist (step '(1 2))
    (let* ((attempt (dsh-protocol-execution-event--from-alist
                     (dsh-test--execution-event
                      "assistant/attempt" 1 '((turn . 1) (step . 1)))))
           (retry (dsh-protocol-execution-event--from-alist
                   (dsh-test--execution-event
                    "llm/retry" 2 `((turn . 1) (step . ,step)
                                    (retryId . "chain") (retry . 1))))))
      (should-not (dsh-emacs-render--attempt-cards (list (cons 2 retry))))
      (should (equal (dsh-emacs-render--attempt-cards
                      (list (cons 1 attempt) (cons 2 retry)))
                     (list (list :event attempt
                                 :label (if (= step 1) "scheduled" "Incomplete reply")
                                 :cause (and (= step 1) retry))))))))

(ert-deftest dsh-emacs-test-execution-attempt-card-failure-and-purity ()
  :tags '(dsh-unit)
  (let* ((facts
          (cl-loop
           for event in
           (list (dsh-test--execution-event
                  "assistant/attempt" 1 '((turn . 1) (step . 1)))
                 (dsh-test--execution-event
                  "llm/retry" 2 '((turn . 1) (step . 1)
                                  (retryId . "chain") (retry . 1)))
                 (dsh-test--execution-event
                  "llm/retry-started" 3 '((turn . 1) (step . 1)
                                          (retryId . "chain") (retry . 1)))
                 (dsh-test--execution-event
                  "assistant/attempt" 4 '((turn . 1) (step . 1)))
                 (dsh-test--execution-event
                  "turn/end" 5 '((turn . 1) (reason . ((kind . "error"))))))
           for decoded = (dsh-protocol-execution-event--from-alist event)
           collect (cons (dsh-protocol-execution-event-seq decoded) decoded)))
         (original (copy-tree facts t))
         (dsh-emacs-render--attempt-turns 'untouched)
         (expected
          (list (list :event (cdr (nth 3 facts)) :label "Failed reply"
                      :cause (cdr (nth 4 facts)))
                (list :event (cdar facts) :label "started"
                      :cause (cdr (nth 1 facts)))))
         (cards (dsh-emacs-render--attempt-cards facts)))
    (should (equal cards expected))
    (should (equal facts original))
    (should (eq dsh-emacs-render--attempt-turns 'untouched))
    ;; Presentation may modify its result without contaminating the next replay.
    (setf (plist-get (car cards) :label) "caller changed this result")
    (should (equal (dsh-emacs-render--attempt-cards facts) expected))))

(ert-deftest dsh-emacs-test-execution-attempt-outcomes ()
  :tags '(dsh-unit)
  (dolist (delivery '(live history prepend reverse))
    (with-temp-buffer
      (dsh-emacs-mode)
      (let* ((events
              (list
               (dsh-test--execution-event "assistant/attempt" 1
                                          '((turn . 1) (step . 1) (stream . [])))
               (dsh-test--execution-event "llm/retry" 2
                                          '((turn . 1) (step . 1) (retryId . "r")
                                            (retry . 1) (maxRetries . 3)
                                            (failure . ((message . "Slow down")))))
               (dsh-test--execution-event "llm/retry-started" 3
                                          '((turn . 1) (step . 1) (retryId . "r")
                                            (retry . 1)))
               (dsh-test--execution-event "assistant/attempt" 4
                                          '((turn . 1) (step . 1) (stream . [])))
               (dsh-test--execution-event "turn/end" 5
                                          '((turn . 1) (reason . ((kind . "error")
                                                                  (error . ((code . "LIMIT")
                                                                            (message . "Exhausted"))))))))))
        (let ((entries (mapcar (lambda (event) (list (cons 'event event))) events)))
          (pcase delivery
            ('live (dolist (event events) (dsh-emacs-render-event event)))
            ('reverse (dolist (event (reverse events)) (dsh-emacs-render-event event)))
            ('prepend
             (dsh-emacs-render-history-events (nthcdr 2 entries))
             (let* ((dsh-emacs--history-insert-marker
                     (dsh-emacs-render--history-prepend-marker))
                    (position (marker-position dsh-emacs--history-insert-marker)))
               (dsh-emacs-render-history-events
                (cl-subseq entries 0 2) nil 3 :insert-before position :follow-p nil)
               (set-marker dsh-emacs--history-insert-marker nil)))
            (_ (dsh-emacs-render-history-events entries)
               (dsh-emacs-render-history-events entries))))
        (let* ((ns (dsh-emacs-render--make-namespace))
               (first (dsh-emacs-ui-find-block ns "evt-1"))
               (last (dsh-emacs-ui-find-block ns "evt-4")))
          (should (string-match-p "Retry 1/3 · started"
                                  (buffer-substring (car first) (cdr first))))
          (should (string-match-p "Failed reply"
                                  (buffer-substring (car last) (cdr last))))
          (should-not (string-match-p "Incomplete reply" (buffer-string))))))))

(ert-deftest dsh-emacs-test-execution-attempt-cancellation ()
  :tags '(dsh-unit)
  (dolist (retry '(nil t))
    (with-temp-buffer
      (dsh-emacs-mode)
      (dsh-emacs-render-event
       (dsh-test--execution-event "assistant/attempt" 1
                                  '((turn . 1) (step . 1) (stream . []))))
      (when retry
        (dsh-emacs-render-event
         (dsh-test--execution-event "llm/retry" 2
                                    '((turn . 1) (step . 1) (retryId . "r")
                                      (retry . 2) (maxRetries . 3))))
        ;; A stale started event must not mark this wait as started.
        (dsh-emacs-render-event
         (dsh-test--execution-event "llm/retry-started" 3
                                    '((turn . 1) (step . 1) (retryId . "r")
                                      (retry . 1)))))
      (dsh-emacs-render-event
       (dsh-test--execution-event "turn/end" 4
                                  '((turn . 1) (reason . ((kind . "aborted"))))))
      (should (string-match-p (if retry "Retry cancelled" "Cancelled reply")
                              (buffer-string))))))

(ert-deftest dsh-emacs-test-execution-attempt-preserves-body-and-draft ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (goto-char (point-max))
    (insert "draft")
    (dsh-emacs-render-event
     (dsh-test--execution-event "assistant/attempt" 1
                                '((turn . 1) (step . 1)
                                  (stream . [((type . "text-chunks")
                                              (texts . ["partial reply"]))]))))
    (let* ((ns (dsh-emacs-render--make-namespace))
           (block (dsh-emacs-ui-find-block ns "evt-1")))
      (goto-char (car block))
      (dsh-emacs-ui-toggle-fragment)
      (goto-char (point-max))
      (dsh-emacs-render-event
       (dsh-test--execution-event "llm/retry" 2
                                  '((turn . 1) (step . 1) (retryId . "r")
                                    (retry . 1) (delayMs . 2500)
                                    (failure . ((code . "RATE_LIMIT")
                                                (message . "Slow down"))))))
      (setq block (dsh-emacs-ui-find-block ns "evt-1"))
      (let ((state (get-text-property (car block) 'dsh-emacs-ui-state)))
        (should-not (map-elt state :collapsed))
        (should (equal (map-elt state :body) "partial reply"))
        (should (string-match-p "RATE_LIMIT · Slow down"
                                (get-text-property 0 'help-echo
                                                   (substring (map-elt state :label-left) 2))))))
    (should (string-match-p "Retry 1 · scheduled" (buffer-string)))
    (should (string-match-p "wait 2.5s" (buffer-string)))
    (should (string-suffix-p "draft" (buffer-string)))
    (should (= (point) (point-max)))
    (dsh-emacs-render--reset-tool-tracking)
    (should-not dsh-emacs-render--attempt-turns)))

(ert-deftest dsh-emacs-test-execution-recovery-without-retry-event ()
  :tags '(dsh-unit)
  (dolist (delivery '(live history prepend))
    (with-temp-buffer
      (dsh-emacs-mode)
      (let* ((events
              (list
               (dsh-test--execution-event "assistant/attempt" 1
                                          '((turn . 1) (step . 1) (stream . [])))
               (dsh-test--execution-event "compaction/start" 2
                                          '((turn . 1) (compactionId . "overflow")))
               (dsh-test--execution-event "compaction/end" 3
                                          '((turn . 1) (compactionId . "overflow")))
               (dsh-test--execution-event "assistant/attempt" 4
                                          '((turn . 1) (step . 1) (stream . [])))
               (dsh-test--execution-event "assistant/message" 5
                                          '((turn . 1) (step . 1)
                                            (message . ((content . [((type . "text")
                                                                     (text . "Recovered"))])))
                                            (stream . [])))))
             (entries (mapcar (lambda (event) (list (cons 'event event))) events)))
        (pcase delivery
          ('live (dolist (event events) (dsh-emacs-render-event event)))
          ('prepend
           (dsh-emacs-render-history-events (nthcdr 3 entries))
           (let* ((dsh-emacs--history-insert-marker
                   (dsh-emacs-render--history-prepend-marker))
                  (position (marker-position dsh-emacs--history-insert-marker)))
             (dsh-emacs-render-history-events
              (cl-subseq entries 0 3) nil 4 :insert-before position :follow-p nil)
             (set-marker dsh-emacs--history-insert-marker nil)))
          (_ (dsh-emacs-render-history-events entries)))
        (dolist (id '("evt-1" "evt-4"))
          (let* ((block (dsh-emacs-ui-find-block
                         (dsh-emacs-render--make-namespace) id))
                 (label (map-elt (get-text-property
                                  (car block) 'dsh-emacs-ui-state) :label-left)))
            (should (equal (substring-no-properties label) "● Retried"))
            (should (eq (get-text-property 0 'face label) 'dsh-emacs-running-face))))))))

(ert-deftest dsh-emacs-test-execution-recovery-keeps-step-boundary ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-render-event
     (dsh-test--execution-event "assistant/attempt" 1
                                '((turn . 1) (step . 1) (stream . []))))
    (dsh-emacs-render-event
     (dsh-test--execution-event "assistant/message" 2
                                '((turn . 1) (step . 2)
                                  (message . ((content . []))) (stream . []))))
    (should (string-match-p "Incomplete reply" (buffer-string)))
    (should-not (string-match-p "Retried" (buffer-string)))))

(ert-deftest dsh-emacs-test-execution-trim-prunes-outcome-cache ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (setq-local dsh-emacs-reply-footer-items nil)
    (setq-local dsh-emacs-max-buffer-size 300)
    (dotimes (n 100)
      (let ((turn (1+ n)))
        (dsh-emacs-render-event
         (dsh-test--execution-event
          "assistant/message" (1+ (* n 2))
          `((turn . ,turn) (step . 1)
            (message . ((content . [((type . "text")
                                     (text . ,(make-string 100 ?a)))])))
            (stream . []))))
        (dsh-emacs-render-event
         (dsh-test--execution-event "turn/end" (+ 2 (* n 2))
                                    `((turn . ,turn) (reason . ((kind . "completed"))))))
        (dsh-emacs-render--trim-buffer)))
    (should (< (buffer-size) 300))
    (should (< (hash-table-count dsh-emacs-render--attempt-turns) 5))
    (should-not (gethash 1 dsh-emacs-render--attempt-turns))
    (should (gethash 100 dsh-emacs-render--attempt-turns))))

(ert-deftest dsh-emacs-test-execution-trim-retains-outcome-for-older-page ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (setq-local dsh-emacs-reply-footer-items nil)
    (setq-local dsh-emacs-max-buffer-size 300)
    (dsh-emacs-render-event
     (dsh-test--execution-event
      "assistant/message" 6
      `((turn . 1) (step . 1)
        (message . ((content . [((type . "text")
                                 (text . ,(make-string 500 ?a)))])))
        (stream . []))))
    (dsh-emacs-render--trim-buffer)
    (should (gethash 1 dsh-emacs-render--attempt-turns))
    (let* ((dsh-emacs--history-insert-marker (copy-marker (point-min) t))
           (event (dsh-test--execution-event
                   "assistant/attempt" 1
                   '((turn . 1) (step . 1) (stream . [])))))
      (dsh-emacs-render-history-events
       (list (list (cons 'event event))) nil 6
       :insert-before (point-min) :follow-p nil)
      (set-marker dsh-emacs--history-insert-marker nil))
    (should (string-match-p "Retried" (buffer-string)))
    (let ((state (gethash 1 dsh-emacs-render--attempt-turns)))
      (should (= (plist-get state :seq) 6))
      (should (= (plist-get state :position)
                 (dsh-emacs-render--input-insert-point))))
    (setq-local dsh-emacs-max-buffer-size 100)
    (dsh-emacs-render--trim-buffer)
    (should (gethash 1 dsh-emacs-render--attempt-turns))))

(provide 'dsh-test-execution)
;;; dsh-test-execution.el ends here
