;;; dsh-e2e.el --- End-to-end tests against a real dsh server -*- lexical-binding: t; -*-

;; Copyright (C) 2025-2026

;; Author: dsh-emacs contributors
;; Keywords: tools
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; Run with:
;;
;;   emacs -Q --batch -L . -l test/dsh-e2e.el
;;
;; DSH_E2E_URL may override the default server URL.  A URL containing a
;; launch token is accepted.  The test creates one session, exercises the
;; real event stream, and archives the session during cleanup because dsh
;; does not expose a session deletion RPC.
;; Set DSH_E2E_PLAN_REVIEW=1 to exercise model-generated plan review,
;; requesting changes, and approval (requires a working model provider).
;; Set DSH_E2E_SUBAGENTS=1 for real delegation, paging, follow-up and stop.
;; For timed questions, load this file in a running graphical Emacs, select
;; a timed preset via DSH_E2E_PRESET, then call (dsh-emacs-e2e-run t).
;; Keep other answer-capable clients disconnected during this test: a Web
;; client's own countdown can settle a waterfall that Emacs is still reading.
;; The test uses the real minibuffer, automatically choosing option 2.  It
;; delays an actual HTTP send, exercises expiry and late answers, rebaselines,
;; and fetches the original pending tool result through older-history paging.
;; Loading in an interactive Emacs only defines tests; it never exits Emacs.

;;; Code:

(add-to-list 'load-path
             (expand-file-name ".." (file-name-directory load-file-name)))

(require 'cl-lib)
(require 'dsh-emacs)

(defvar dsh-e2e--results nil)
(defvar dsh-e2e--session-id nil)
(defvar dsh-e2e--chat nil)

(defun dsh-e2e--pass (name)
  (push (list name t nil) dsh-e2e--results)
  (princ (format "PASS: %s\n" name)))

(defun dsh-e2e--fail (name detail)
  (push (list name nil detail) dsh-e2e--results)
  (princ (format "FAIL: %s -- %s\n" name detail)))

(defun dsh-e2e--check (name value &optional detail)
  (if value
      (dsh-e2e--pass name)
    (dsh-e2e--fail name (or detail "check returned nil")))
  value)

(defun dsh-e2e--wait-until (predicate timeout)
  (let ((deadline (+ (float-time) timeout)))
    (while (and (not (funcall predicate))
                (< (float-time) deadline))
      (accept-process-output nil 0.05)
      (sit-for 0.05))
    (funcall predicate)))

(defun dsh-e2e--rpc (method args)
  (pcase-let ((`(,ok-p . ,value) (dsh-emacs--rpc-request method args)))
    (if ok-p
        value
      (error "%s failed: %S" method value))))

(defun dsh-e2e--session-cached-p ()
  (cl-some (lambda (session)
             (equal (dsh-protocol-session-session-id session)
                    dsh-e2e--session-id))
           dsh-emacs--sessions))

(defun dsh-e2e--question-answered-p (call-id question-id label)
  "Whether CALL-ID's card displays QUESTION-ID answered with LABEL."
  (with-current-buffer dsh-e2e--chat
    (let* ((state (dsh-emacs-render--tool-state call-id))
           (answers (dsh-emacs-render--ask-answers (plist-get state :result)))
           (block (dsh-emacs-ui-find-block
                   (plist-get state :ns) (concat "tool-" call-id))))
      (and (equal answers (list (list question-id (list label) nil)))
           block
           (string-match-p
            "Ask question · 1/1 answered"
            (buffer-substring-no-properties (car block) (cdr block)))))))

(defun dsh-e2e--timed-question (late)
  "Exercise a real timed question, answering after expiry when LATE is non-nil.
Only human input and outbound delivery timing are automated.  Tool calls,
waterfalls, wait claims, HTTP replies and projections all come from the host."
  (let* ((question-id (if late "e2e-timed-late" "e2e-timed-held"))
         (open-stream (symbol-function 'dsh-emacs-events-open-stream))
         (requested (symbol-function 'dsh-emacs--question-requested))
         (rpc (symbol-function 'dsh-emacs--rpc-async))
         (release (symbol-function 'dsh-emacs--question-release-wait))
         (setup nil)
         timers call-id event-id timed remaining wait-claim wait-ended claim-held
         response feedback released-after-response prompt-depth continued-seq
         question-error)
    (setq setup
          (lambda ()
            (when (and dsh-emacs--question-current
                       (equal question-id
                              (dsh-protocol-question-id
                               dsh-emacs--question-current)))
              (setq prompt-depth (minibuffer-depth))
              (push
               (run-with-timer
                15 nil
                (lambda ()
                  (when (and (active-minibuffer-window)
                             dsh-emacs--question-current
                             (equal question-id
                                    (dsh-protocol-question-id
                                     dsh-emacs--question-current)))
                    (abort-recursive-edit))))
               timers)
              (push
               (run-with-timer
                (if late 0.1 3.0) nil
                (lambda ()
                  (when (and (active-minibuffer-window)
                             dsh-emacs--question-current
                             (equal question-id
                                    (dsh-protocol-question-id
                                     dsh-emacs--question-current)))
                    (execute-kbd-macro (kbd "2 RET")))))
               timers))))
    (unwind-protect
        (cl-letf
            (((symbol-function 'dsh-emacs--question-requested)
              (lambda (chat event session questions &optional wait)
                (if (not (equal session dsh-e2e--session-id))
                    (funcall requested chat event session questions wait)
                  (setq event-id event
                        timed (and wait (dsh-protocol-question-wait-timed wait))
                        call-id (and wait
                                     (dsh-protocol-question-wait-call-id wait)))
                  (if (and (= (length questions) 1)
                           (equal question-id
                                  (dsh-protocol-question-id
                                   (dsh-protocol--struct
                                    #'dsh-protocol-question-p
                                    #'dsh-protocol-question--from-alist
                                    (elt questions 0)))))
                      (funcall requested chat event session questions wait)
                    ;; Never leave an unrecognized model prompt waiting for
                    ;; human input in an otherwise unattended acceptance run.
                    (setq question-error t)
                    (dsh-emacs--question-decline event)))))
             ((symbol-function 'dsh-emacs-events-open-stream)
              (lambda (process endpoint args name handler)
                (let* ((ours (and (equal endpoint "userQuestions/attachWait")
                                  (equal (alist-get 'agentId args)
                                         dsh-e2e--session-id)))
                       (stream
                        (funcall
                         open-stream process endpoint args name
                         (if ours
                             (lambda (value)
                               (if value
                                   (setq remaining (alist-get 'remainingMs value))
                                 (setq wait-ended t))
                               (funcall handler value))
                           handler))))
                  (when ours (setq wait-claim (cons process stream)))
                  stream)))
             ((symbol-function 'dsh-emacs--question-release-wait)
              (lambda (claim)
                (when (and claim (equal claim wait-claim))
                  (setq released-after-response (and response t)))
                (funcall release claim)))
             ((symbol-function 'dsh-emacs--rpc-async)
              (lambda (method args callback)
                (if (or (and event-id (equal method "$events/result")
                             (equal event-id (alist-get 'eventId args)))
                        (and (equal method "userQuestions/answer")
                             (equal dsh-e2e--session-id
                                    (alist-get 'agentId args))))
                    (let ((deliver
                           (lambda ()
                             (funcall
                              rpc method args
                              (lambda (ok value)
                                (setq response (list ok value)
                                      feedback (funcall callback ok value)))))))
                      (if (or late (not (equal method "$events/result")))
                          (funcall deliver)
                        ;; Delay the actual HTTP send past the deadline.  A
                        ;; client that releases on reader exit loses its answer.
                        (push
                         (run-with-timer
                          1 nil
                          (lambda ()
                            (with-current-buffer dsh-e2e--chat
                              (setq claim-held
                                    (cl-some
                                     (lambda (entry)
                                       (equal "userQuestions/attachWait"
                                              (cadr entry)))
                                     (process-get dsh-emacs--event-process
                                                  'dsh-emacs-stream-handlers))))
                            (funcall deliver)))
                         timers)))
                  (funcall rpc method args callback)))))
          (add-hook 'minibuffer-setup-hook setup)
          ;; Occupying the real prompt slot lets the second waterfall expire
          ;; naturally on the host, including its cancel frame and pending result.
          (let ((dsh-emacs--question-active
                 (if late 'e2e-occupied dsh-emacs--question-active)))
            (dsh-e2e--rpc
             "session/prompt"
             `((request
                . ((requestId . ,(dsh-emacs--rpc-id))
                   (sessionId . ,dsh-e2e--session-id)
                   (mode . "queue")
                   (content
                    . [((type . "text")
                        (text
                         . ,(format
                             (concat
                              "Client acceptance test. Call ask_user_question "
                              "exactly once with timeout=2 and exactly one "
                              "question: id=%s, question=E2E timed choice, "
                              "options=[{label:Alpha},{label:Beta}]. "
                              "Do not use other tools. After the tool returns, "
                              "reply only TEST_DONE. If a late answer arrives, "
                              "reply only LATE_DONE without asking again.")
                             question-id)))])))))
            (unless (dsh-e2e--wait-until
                     (lambda () (or question-error
                                    (if late
                                        (with-current-buffer dsh-e2e--chat
                                          (and call-id
                                               (cl-find
                                                call-id
                                                (dsh-emacs--question-continued)
                                                :key #'dsh-protocol-pending-question-call-id
                                                :test #'equal)))
                                      (or response wait-ended))))
                     90)
              (error "Timed question did not finish; use a timed preset and working model")))
          (when question-error
            (error "Model did not ask the specified single question: %s" question-id))
          (dsh-e2e--check (concat question-id "-timed-waterfall")
                          (and timed call-id event-id))
          (unless (and timed call-id)
            (error "The selected preset must enable ask_user_question mode: timed"))
          (with-current-buffer dsh-e2e--chat
            (when late
              (setq continued-seq
                    (dsh-protocol-user-questions-seq dsh-emacs--session-questions))
              (dsh-e2e--check
               "timed-expiry-pending-card"
               (dsh-e2e--wait-until
                (lambda ()
                  (dsh-emacs-render--ask-pending-p
                   (plist-get (dsh-emacs-render--tool-state call-id) :result)))
                10))
              (dsh-e2e--check
               "timed-expiry-withdraws-waterfall"
               (dsh-e2e--wait-until
                (lambda ()
                  (not (cl-find event-id dsh-emacs--question-queue
                                :key #'cadr :test #'equal)))
                10))
              (dsh-emacs-answer-question)))
          (dsh-e2e--check
           (concat question-id "-http-accepted")
           (and (dsh-e2e--wait-until (lambda () response) 10)
                (car response) (or (not late) (eq (cadr response) t))))
          (dsh-e2e--check (concat question-id "-real-reader")
                          (equal prompt-depth 1))
          (unless late
            (dsh-e2e--check "timed-claim-held-beyond-deadline"
                            (and (numberp remaining) (< 0 remaining)
                                 (<= remaining 2000) claim-held))
            ;; The reply callback can run after the global prompt slot clears.
            (dsh-e2e--check "timed-answer-before-claim-release"
                            released-after-response))
          (dsh-e2e--check
           (concat question-id "-answered-card")
           (dsh-e2e--wait-until
            (lambda () (dsh-e2e--question-answered-p call-id question-id "Beta"))
            30))
          (when late
            (with-current-buffer dsh-e2e--chat
              (dsh-e2e--check
               "late-answer-settled-projection"
               (and (> (dsh-protocol-user-questions-seq dsh-emacs--session-questions)
                       continued-seq)
                    (null (dsh-emacs--question-continued))
                    (cl-find call-id
                             (dsh-protocol-user-questions-settled
                              dsh-emacs--session-questions)
                             :key #'dsh-protocol-settled-question-call-id
                             :test #'equal)))
              (setq response nil feedback nil)
              (dsh-emacs--question-answer-late
               dsh-e2e--session-id call-id
               `(((id . ,question-id) (selected . ["Beta"])))))
            (dsh-e2e--check
             "late-answer-duplicate-reported-as-rejected"
             (and (dsh-e2e--wait-until (lambda () response) 10)
                  (car response) (eq (cadr response) :json-false)
                  (equal feedback "Question is no longer waiting for an answer"))))
          (cons call-id question-id))
      (remove-hook 'minibuffer-setup-hook setup)
      (dolist (timer timers) (cancel-timer timer)))))

(defun dsh-e2e--question-history (call-id question-id)
  "Check CALL-ID's late answer through rebaseline and older-page loading."
  (let ((snapshot-handler
         (symbol-function 'dsh-emacs-events--follow-snapshot))
        recovered)
    (cl-letf (((symbol-function 'dsh-emacs-events--follow-snapshot)
               (lambda (chat value)
                 (funcall snapshot-handler chat value)
                 (when (eq chat dsh-e2e--chat) (setq recovered t)))))
      (with-current-buffer dsh-e2e--chat
        (dsh-emacs-events--follow-rebaseline))
      (dsh-e2e--check
       "late-answer-survives-follow-rebaseline"
       (and (dsh-e2e--wait-until (lambda () recovered) 10)
            (dsh-e2e--question-answered-p call-id question-id "Beta")))))
  ;; A fresh buffer has no cached tool rows.  Seed the settled projection
  ;; from the tail, then fetch the original pending result in an older page.
  (dsh-emacs-events-disconnect dsh-e2e--chat)
  (kill-buffer dsh-e2e--chat)
  (let ((dsh-emacs-history-window 1))
    (dsh-emacs-open-session dsh-e2e--session-id)
    (setq dsh-e2e--chat dsh-emacs--current-buffer)
    (unless (dsh-e2e--wait-until
             (lambda () (buffer-local-value 'dsh-emacs--event-ready dsh-e2e--chat))
             10)
      (error "Timed question history did not reopen")))
  (with-current-buffer dsh-e2e--chat
    (dsh-e2e--check
     "late-answer-projection-before-history-card"
     (and (null (dsh-emacs-render--tool-state call-id))
          dsh-emacs--session-questions
          (cl-find call-id
                   (dsh-protocol-user-questions-settled dsh-emacs--session-questions)
                   :key #'dsh-protocol-settled-question-call-id :test #'equal)))
    (let ((dsh-emacs-history-window 30))
      (dsh-emacs-load-older-history))
    (dsh-e2e--check
     "late-answer-completes-older-history-card"
     (dsh-e2e--wait-until
      (lambda () (dsh-e2e--question-answered-p call-id question-id "Beta")) 10))))

(defun dsh-e2e--plan-review ()
  "Exercise document review and both decisions against the real model."
  (dolist (approve '(nil t))
    (dsh-e2e--rpc
     "commands/execute"
     `((agentId . ,dsh-e2e--session-id)
       (line . ,(concat
                 "/plan This is a client UI acceptance test. "
                 "Do not read or modify files, run commands, or use other tools. "
                 "Immediately submit a short three-step plan using exit_plan_mode, "
                 "starting with # Client review test. The plan is only to reply "
                 "REVIEW_ACCEPTED after approval. If review is dismissed, stop "
                 "and wait for my feedback. After approval, reply REVIEW_ACCEPTED "
                 "and finish without any other work."))
       (submittedAttachments . [])))
    (unless (dsh-e2e--wait-until
             (lambda () (buffer-local-value 'dsh-emacs-plan--pending
                                            dsh-e2e--chat))
             60)
      (error "Model did not submit a plan for review"))
    (let* ((review (car (buffer-local-value 'dsh-emacs-plan--pending
                                            dsh-e2e--chat)))
           (document (plist-get review :buffer)))
      (dsh-e2e--check
       (if approve "plan-second-review-document" "plan-first-review-document")
       (and (= (minibuffer-depth) 0)
            (buffer-live-p document)
            (with-current-buffer document
              (and (eq major-mode 'dsh-emacs-plan-mode)
                   (string-match-p "Client review test" (buffer-string))
                   (string-match-p "Approve and execute" (buffer-string))))))
      (with-current-buffer document
        (if approve (dsh-emacs-plan-approve)
          (dsh-emacs-plan-request-changes)))
      (dsh-e2e--check
       (if approve "plan-approval-acknowledged" "plan-changes-acknowledged")
       (dsh-e2e--wait-until
        (lambda () (equal (plist-get review :status)
                          (if approve "Approved" "Changes requested")))
        10))
      (dsh-e2e--check
       (if approve "plan-approved-mode-off" "plan-changes-stay-in-plan")
       (dsh-e2e--wait-until
        (lambda ()
          (with-current-buffer dsh-e2e--chat
            (and dsh-emacs--modeline-plan
                 (eq (dsh-protocol-plan-active dsh-emacs--modeline-plan)
                     (not approve)))))
        30)))))

(defun dsh-e2e--choose-subagent (chat entry &optional other-window)
  "Choose ENTRY through CHAT's real minibuffer, optionally in OTHER-WINDOW."
  (let ((choice (format "%s [%s]" (dsh-emacs-subagent--label entry)
                        (dsh-protocol-subagent-entry-id entry)))
        timer)
    (unwind-protect
        (with-current-buffer chat
          (minibuffer-with-setup-hook
              (lambda ()
                (insert choice)
                (setq timer (run-with-timer
                             0.1 nil #'execute-kbd-macro (kbd "RET"))))
            (dsh-emacs-list-subagents other-window)))
      (when (timerp timer) (cancel-timer timer)))))

(defun dsh-e2e--subagents ()
  "Exercise real delegated children; requires an available model provider."
  (let ((parent dsh-e2e--session-id)
        (parent-chat dsh-e2e--chat)
        children)
    (unless (display-graphic-p)
      (error "Subagent E2E requires graphical Emacs for its real minibuffer"))
    (save-window-excursion
      (unwind-protect
          (progn
            (with-current-buffer parent-chat
              (dsh-emacs--submit-prompt
               "Client integration test: delegate exactly two children using your subagent tool. First call: run_in_background=false, label e2e-one-shot, ask it to reply ONE_SHOT_READY without tools. Second call: run_in_background=true, label e2e-continuable, ask it to reply BACKGROUND_READY without tools. Do not read/write files or ask questions. Do not send further messages to the children. Reply PARENT_READY."))
            (unless (dsh-e2e--wait-until
                     (lambda ()
                       (let ((entries (dsh-emacs-subagent--value parent 'subagentCatalog)))
                         (and (cl-find "one-shot" entries :test #'equal
                                       :key #'dsh-protocol-subagent-entry-mode)
                              (cl-find "continuable" entries :test #'equal
                                       :key #'dsh-protocol-subagent-entry-mode)))) 120)
              (error "Model did not create both child modes"))
            (let* ((entries (dsh-emacs-subagent--value parent 'subagentCatalog))
                   (one (cl-find "one-shot" entries :test #'equal
                                 :key #'dsh-protocol-subagent-entry-mode))
                   (continuable (cl-find "continuable" entries :test #'equal
                                         :key #'dsh-protocol-subagent-entry-mode))
                   (id (dsh-protocol-subagent-entry-id one)))
              (dsh-e2e--check
               "subagent-usage-before-chat-open"
               (dsh-e2e--wait-until
                (lambda () (dsh-emacs-subagent--value id 'tokenUsage)) 15))
              (let* ((cold (dsh-e2e--rpc "session/projections"
                                         (dsh-protocol-subagent-projections-request id)))
                     (cells (dsh-protocol-subagent-baseline--from-alist cold))
                     (identity (cl-find 'subagent cells
                                        :key #'dsh-protocol-subagent-cell-key)))
                (dsh-e2e--check "subagent-settled-cold-projections"
                                (and identity (dsh-protocol-subagent-cell-value identity))))
              (switch-to-buffer parent-chat)
              (let ((dsh-emacs-history-window 1)
                    (departure (point-marker)))
                (dsh-e2e--choose-subagent parent-chat one)
                (let ((chat dsh-emacs--current-buffer))
                  (push chat children)
                  (unless (dsh-e2e--wait-until
                           (lambda () (buffer-local-value 'dsh-emacs--event-ready chat)) 15)
                    (error "Child follow failed"))
                  (with-current-buffer chat
                    (dsh-e2e--check "subagent-one-shot-read-only"
                                    (and buffer-read-only
                                         (condition-case nil
                                             (progn (goto-char dsh-emacs--input-marker) (insert "blocked") nil)
                                           (buffer-read-only t))))
                    (let ((before dsh-emacs--history-earliest-seq))
                      (unless dsh-emacs--history-has-more (error "No second child history page"))
                      (dsh-emacs-load-older-history)
                      (dsh-e2e--check
                       "subagent-real-history-second-page"
                       (dsh-e2e--wait-until
                        (lambda () (and (not dsh-emacs--history-loading)
                                        (< dsh-emacs--history-earliest-seq before))) 15))))
                  (funcall (key-binding (kbd "M-,")))
                  (dsh-e2e--check "subagent-xref-returns-to-parent-position"
                                  (and (eq (current-buffer) parent-chat)
                                       (= (point) (marker-position departure)))
                                  (format "actual=%s:%s expected=%s:%s"
                                          (buffer-name) (point)
                                          (buffer-name parent-chat) (marker-position departure)))
                  (set-marker departure nil)))
              (let ((window (selected-window)))
                (dsh-e2e--choose-subagent parent-chat continuable t)
                (dsh-e2e--check "subagent-picker-other-window"
                                (not (eq window (selected-window)))))
              (let ((chat dsh-emacs--current-buffer))
                (push chat children)
                (unless (dsh-e2e--wait-until
                         (lambda () (and (buffer-local-value 'dsh-emacs--event-ready chat)
                                         (not (buffer-local-value 'buffer-read-only chat)))) 15)
                  (error "Continuable child did not become writable"))
                (with-current-buffer chat
                  (dsh-emacs--submit-prompt
                   "Reply with the concatenation of SUBAGENT_ and FOLLOWUP_DONE, nothing else. Do not use tools.")
                  (dsh-e2e--check
                   "subagent-real-follow-up-completes"
                   (dsh-e2e--wait-until
                    (lambda () (string-match-p "SUBAGENT_FOLLOWUP_DONE" (buffer-string))) 90))
                  (dsh-emacs--submit-prompt
                   "Run the bash command sleep 30 and then reply STOP_TEST_DONE. Do not access files.")
                  (unless (dsh-e2e--wait-until #'dsh-emacs--busy-p 30)
                    (error "Child never became busy for stop"))
                  (dsh-emacs-interrupt-turn)
                  (dsh-e2e--check "subagent-real-stop-settles"
                                  (dsh-e2e--wait-until (lambda () (not (dsh-emacs--busy-p))) 30)))
                (with-current-buffer (get-buffer dsh-emacs-sessions-buffer)
                  (dsh-emacs-events-host-disconnect)
                  (dsh-e2e--check "subagent-disconnect-closes-input"
                                  (buffer-local-value 'buffer-read-only chat))
                  (dsh-emacs-events-host-connect))
                (dsh-e2e--check "subagent-reconnect-refreshes-parent-gate"
                                (dsh-e2e--wait-until
                                 (lambda () (not (buffer-local-value 'buffer-read-only chat))) 20)))))
        (dolist (chat children)
          (when (buffer-live-p chat) (kill-buffer chat)))))))

(defun dsh-emacs-e2e-run (&optional questions)
  "Run real-server E2E checks and return (NAME PASSED DETAIL) results.
With QUESTIONS (interactively, a prefix argument), include timed questions.
They need a graphical Emacs and a preset with ask_user_question mode: timed.
DSH_E2E_PRESET selects the preset; existing chats and connections are preserved."
  (interactive "P")
  (when (or (active-minibuffer-window) dsh-emacs--question-active
            dsh-emacs--approval-active dsh-emacs--question-queue
            dsh-emacs--approval-queue)
    (user-error "An interaction is active or queued"))
  (when (and questions noninteractive)
    (user-error "Timed-question E2E needs a graphical Emacs for its real reader"))
  (let* ((dsh-emacs-base-url (or (getenv "DSH_E2E_URL") dsh-emacs-base-url))
         (dsh-emacs-enable-notifications nil)
         (dsh-emacs-new-session-auto-project nil)
         (dsh-emacs-show-tool-calls t)
         (dsh-emacs-history-window 30)
         (dsh-emacs--current-session dsh-emacs--current-session)
         (dsh-emacs--current-buffer dsh-emacs--current-buffer)
         (kill-ring (copy-sequence kill-ring))
         (kill-ring-yank-pointer kill-ring)
         (interprogram-cut-function nil)
         (modeline-enabled dsh-emacs-modeline-enabled)
         (core (get-buffer dsh-emacs-sessions-buffer))
         (core-process (and core (buffer-local-value 'dsh-emacs--host-process core)))
         (core-connected (and (processp core-process) (process-live-p core-process)))
         (dsh-e2e--results nil)
         (dsh-e2e--session-id nil)
         (dsh-e2e--chat nil))
    (save-window-excursion
      (unwind-protect
          (condition-case error-data
              (progn
                (dsh-e2e--rpc "session/list" (dsh-emacs--session-list-args))
                (dsh-e2e--pass "health-check")

                ;; The normal entry point owns the core control/projection stream;
                ;; opening a chat directly only starts its transcript follow stream.
                (dsh-emacs)
                (dsh-e2e--check
                 "core-stream-ready"
                 (dsh-e2e--wait-until
                  (lambda ()
                    (and dsh-emacs-events--client-id
                         (buffer-local-value 'dsh-emacs--host-ready
                                             (get-buffer dsh-emacs-sessions-buffer))))
                  10))

                (let* ((preset (getenv "DSH_E2E_PRESET"))
                       (request `((cwd . ,(expand-file-name default-directory))))
                       (request (if (and preset (not (string-empty-p preset)))
                                    (append request `((agentPreset . ,preset)))
                                  request))
                       (response (dsh-e2e--rpc
                                  "session/create"
                                  `((request . ,request))))
                       (session (dsh-protocol--struct
                                 #'dsh-protocol-session-p
                                 #'dsh-protocol-session--from-alist
                                 response)))
                  (setq dsh-e2e--session-id
                        (dsh-protocol-session-session-id session))
                  (dsh-e2e--check "new-session" dsh-e2e--session-id
                                  "session/create returned no session id")
                  (dsh-emacs--cache-new-session
                   dsh-e2e--session-id
                   nil
                   preset))

                (dsh-emacs-open-session dsh-e2e--session-id)
                (setq dsh-e2e--chat dsh-emacs--current-buffer)
                (dsh-e2e--check
                 "open-session"
                 (dsh-e2e--wait-until
                  (lambda ()
                    (and (buffer-live-p dsh-e2e--chat)
                         (buffer-local-value 'dsh-emacs--event-ready
                                             dsh-e2e--chat)))
                  10)
                 "session/follow did not become ready")

                (with-current-buffer dsh-e2e--chat
                  (dsh-e2e--check "conversation-buffer-mode"
                                  (eq major-mode 'dsh-emacs-mode))
                  (dsh-e2e--check "input-area-created"
                                  (markerp dsh-emacs--input-marker))
                  (dsh-e2e--check "modeline-rendered"
                                  (not (string-empty-p
                                        (dsh-emacs-modeline-format))))

                  (dsh-e2e--check
                   "plan-projection-available"
                   (dsh-e2e--wait-until
                    (lambda () (dsh-protocol-plan-p dsh-emacs--modeline-plan)) 10))
                  (dsh-e2e--rpc
                   "commands/execute"
                   `((agentId . ,dsh-e2e--session-id) (line . "/plan")
                     (submittedAttachments . [])))
                  (dsh-e2e--check
                   "plan-command-enters-mode"
                   (dsh-e2e--wait-until
                    (lambda ()
                      (and dsh-emacs--modeline-plan
                           (dsh-protocol-plan-active dsh-emacs--modeline-plan)
                           (equal (string-trim (dsh-emacs-modeline--plan-indicator))
                                  "Plan")))
                    10))

                  (let ((message (format "dsh-emacs e2e transport probe %s"
                                         (float-time))))
                    (goto-char dsh-emacs--input-marker)
                    (insert message)
                    (dsh-emacs-send-or-stop)
                    (dsh-e2e--check
                     "send-message-confirmed"
                     (dsh-e2e--wait-until
                      (lambda () (null dsh-emacs--pending-user-messages))
                      10)
                     "server did not confirm the optimistic user message")
                    (dsh-e2e--check "send-message-rendered"
                                    ;; The stream can confirm before the RPC
                                    ;; callback paints the optimistic echo.
                                    (dsh-e2e--wait-until
                                     (lambda ()
                                       (with-current-buffer dsh-e2e--chat
                                         (string-match-p (regexp-quote message)
                                                         (buffer-string))))
                                     10)))

                  (dsh-e2e--rpc
                   "session/cancel"
                   `((request . ((sessionId . ,dsh-e2e--session-id)))))
                  (dsh-e2e--pass "cancel-session")

                  ;; Exercise the gap-recovery transport, including the old
                  ;; stream's end frame racing the new opening snapshot.
                  (let ((process dsh-emacs--event-process)
                        (old (process-get dsh-emacs--event-process
                                          'dsh-emacs-follow-stream-id))
                        (snapshot-handler
                         (symbol-function 'dsh-emacs-events--follow-snapshot))
                        recovered)
                    (cl-letf (((symbol-function 'dsh-emacs-events--follow-snapshot)
                               (lambda (chat value)
                                 (funcall snapshot-handler chat value)
                                 (when (eq chat dsh-e2e--chat)
                                   (setq recovered t)))))
                      (dsh-emacs-events--follow-rebaseline)
                      (dsh-e2e--check
                       "follow-rebaseline-snapshot"
                       (dsh-e2e--wait-until (lambda () recovered) 10)
                       "replacement session/follow did not deliver a snapshot")
                      (dsh-e2e--check
                       "follow-rebaseline-keeps-socket"
                       (and (eq process dsh-emacs--event-process)
                            (process-live-p process)
                            dsh-emacs--event-ready
                            (not (equal old (process-get process
                                                         'dsh-emacs-follow-stream-id)))
                            (null dsh-emacs--event-reconnect-timer)))))

                  (dsh-e2e--check
                   "plan-survives-turn-and-rebaseline"
                   (and dsh-emacs--modeline-plan
                        (dsh-protocol-plan-active dsh-emacs--modeline-plan)))
                  (when (getenv "DSH_E2E_PLAN_REVIEW")
                    (dsh-e2e--plan-review))
                  (dsh-e2e--rpc
                   "commands/execute"
                   `((agentId . ,dsh-e2e--session-id) (line . "/plan off")
                     (submittedAttachments . [])))
                  (dsh-e2e--check
                   "plan-command-leaves-mode"
                   (dsh-e2e--wait-until
                    (lambda ()
                      (and dsh-emacs--modeline-plan
                           (not (dsh-protocol-plan-active dsh-emacs--modeline-plan))
                           (not (dsh-protocol-plan-pending dsh-emacs--modeline-plan))
                           (null (dsh-emacs-modeline--plan-indicator))))
                    10))

                  (if (equal (getenv "DSH_E2E_SUBAGENTS") "1")
                      (dsh-e2e--subagents)
                    (princ "SKIP: subagent delegation (DSH_E2E_SUBAGENTS=1)\n"))

                  (let ((dsh-emacs-modeline-format-spec
                         '(:separator " " :segments (tokens))))
                    (dsh-emacs-modeline-set-usage
                     (dsh-emacs-make-usage 1000 500 0 0 0.05))
                    (dsh-e2e--check "modeline-update"
                                    (string-match-p
                                     "1\\.0k" (dsh-emacs-modeline-format))))

                  (let ((was-enabled dsh-emacs-modeline-enabled))
                    (dsh-emacs-modeline-toggle)
                    (dsh-e2e--check "modeline-toggle"
                                    (eq dsh-emacs-modeline-enabled
                                        (not was-enabled)))
                    (unless (eq dsh-emacs-modeline-enabled was-enabled)
                      (dsh-emacs-modeline-toggle)))

                  (dsh-emacs-copy-transcript)
                  (dsh-e2e--check "copy-transcript"
                                  (not (string-empty-p (current-kill 0)))))

                (when questions
                  (dsh-e2e--timed-question nil)
                  (pcase-let ((`(,call-id . ,question-id)
                               (dsh-e2e--timed-question t)))
                    (unless (dsh-e2e--wait-until
                             (lambda () (not (buffer-local-value
                                              'dsh-emacs--ml-busy dsh-e2e--chat)))
                             60)
                      (error "Model did not finish after the late answer"))
                    (dsh-e2e--question-history call-id question-id)))

                (dsh-emacs-list-sessions-display)
                (dsh-e2e--check
                 "session-list-loaded"
                 (dsh-e2e--wait-until #'dsh-e2e--session-cached-p 10)
                 "created session did not appear in the session cache")
                (with-current-buffer dsh-emacs-sessions-buffer
                  (dsh-e2e--check "session-list-mode"
                                  (eq major-mode 'dsh-emacs-session-mode))
                  (dsh-e2e--check "session-list-rendered"
                                  (string-match-p "Sessions" (buffer-string)))))
            (error
             (dsh-e2e--fail "unexpected-error"
                            (error-message-string error-data))))
        (when dsh-e2e--session-id
          (condition-case error-data
              (progn
                (dsh-e2e--rpc
                 "session/cancel"
                 `((request . ((sessionId . ,dsh-e2e--session-id)))))
                (when (buffer-live-p dsh-e2e--chat)
                  (unless (dsh-e2e--wait-until
                           (lambda () (not (buffer-local-value
                                            'dsh-emacs--ml-busy dsh-e2e--chat)))
                           10)
                    (error "Test session did not stop"))))
            (error (dsh-e2e--fail "stop-test-session"
                                  (error-message-string error-data)))))
        (when (buffer-live-p dsh-e2e--chat)
          (dsh-emacs-events-disconnect dsh-e2e--chat)
          (kill-buffer dsh-e2e--chat))
        (unless core-connected
          (when-let* ((list-buffer (get-buffer dsh-emacs-sessions-buffer)))
            (with-current-buffer list-buffer
              (dsh-emacs-events-host-disconnect))))
        (unless (eq dsh-emacs-modeline-enabled modeline-enabled)
          (dsh-emacs-modeline-toggle))
        (when dsh-e2e--session-id
          (condition-case error-data
              (progn
                (dsh-e2e--rpc
                 "workspace/archiveSession"
                 `((request . ((sessionId . ,dsh-e2e--session-id)))))
                (dsh-e2e--pass "archive-test-session"))
            (error
             (dsh-e2e--fail "archive-test-session"
                            (error-message-string error-data))))))


      (let ((passed (cl-count-if #'cadr dsh-e2e--results))
            (failed (cl-count-if-not #'cadr dsh-e2e--results)))
        (princ (format "\n===== E2E: %d passed, %d failed =====\n" passed failed))
        (message "E2E: %d passed, %d failed" passed failed))
      (nreverse dsh-e2e--results))))

(when noninteractive
  (when (cl-some (lambda (result) (not (cadr result)))
                 (dsh-emacs-e2e-run (getenv "DSH_E2E_QUESTIONS")))
    (kill-emacs 1)))

;;; dsh-e2e.el ends here
