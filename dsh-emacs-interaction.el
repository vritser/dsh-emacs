;;; dsh-emacs-interaction.el --- Question and approval interactions -*- lexical-binding: t; -*-

;; Copyright (C) 2026 vritser
;; Author: vritser
;; Version: 0.8.0
;; License: GPL-3.0-or-later
;; Package-Requires: ((emacs "28.1"))

;;; Commentary:
;; Owns question/approval readers and their shared prompt slot, queues,
;; cancellation, timed wait claims and late answers.  Events decode and route
;; frames here; Plan reviews keep their document workflow.  The entry point
;; assembles the package and initializes session context for public commands.
;; Loading events alone supports cancellation; requests and settled projections
;; require the entry point's session context and renderer.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'crm)
(require 'dsh-emacs-protocol)
(require 'dsh-emacs-server)
(require 'dsh-emacs-faces)
(require 'dsh-emacs-subagent)
(require 'dsh-emacs-plan)

;; Cyclic transport/render seams: events requires this interaction owner,
;; while transcript rendering reads its buffer-local question projection.
(declare-function dsh-emacs-events-open-stream "dsh-emacs-events"
                  (process endpoint args name handler))
(declare-function dsh-emacs-events-close-stream "dsh-emacs-events"
                  (process stream-id))
(declare-function dsh-emacs-render-question-settled "dsh-emacs-render"
                  (call-id answers-json))
(declare-function dsh-emacs-render--tool-state "dsh-emacs-render" (tool-call-id))
(declare-function dsh-emacs-notify--post "dsh-emacs-render"
                  (session-id body &optional buffer))
(declare-function dsh-emacs--chat-buffer-name "dsh-emacs" (session-id))
(defvar dsh-emacs-events--client-id)
(defvar dsh-emacs-events--dispatching)
(defvar dsh-emacs--event-process)
(defvar dsh-emacs--tool-states)
(defvar dsh-emacs--chat-buffers)
(defvar dsh-emacs--buffer-session)

(defcustom dsh-emacs-question-skip-key "C-c C-s"
  "Key that skips the current ask question (answers it with an empty
selection, dsh web's per-question Skip) and moves to the next one.
A `C-c' prefix by default: the reader's text is the answer, so a bare
letter would make that letter untypable (and the free-text sentinel
contains several).  Bound only inside the question reader's minibuffer, so
nothing leaks into unrelated `completing-read' prompts; every question also
skips on an EMPTY input, and the key is only bound where there is a
candidate list.  Set to nil to disable the shortcut."
  :type '(choice (key-sequence :tag "Key sequence")
                 (const :tag "No shortcut" nil))
  :group 'dsh-emacs)

(defcustom dsh-emacs-question-help-display 'echo-area
  "Whether to show the question detail while answering.
`echo-area' shows the detail in the echo area without logging it; nil
disables it.  Selection and answer input are unchanged, and a question
without a detail never shows help.  Option descriptions ride along with
the completion candidates themselves (their `:annotation-function'), so
the echo area carries only the question's own detail."
  :type '(choice (const :tag "Echo area" echo-area)
                 (const :tag "No help" nil))
  :group 'dsh-emacs)

(defcustom dsh-emacs-approval-language nil
  "Language used for host-localized approval reasons.
Use a language tag such as \"zh\", \"zh-CN\" or \"en\".  nil follows
`system-messages-locale', then LC_ALL, LC_MESSAGES and LANG, ignoring
empty values.  Region tags and POSIX locales such as zh_CN.UTF-8 work.
Fallback order is the full tag, its base language, English, then the
original reason.  Only translations supplied by the host are displayed."
  :type '(choice (const :tag "Follow Emacs message locale" nil)
                 (string :tag "Language tag"))
  :group 'dsh-emacs)

;; ---------------------------------------------------------------------------
;;  User question/approval waterfall ($events) responses
;; ---------------------------------------------------------------------------
;; dsh's `ask' tool and sandbox approvals push waterfall frames
;; over the core connection's `$events' stream:
;; `user-questions/request' (questions) and `approval/request'
;; (approvals).  Each waterfall carries a host-assigned `eventId';
;; after reading the user's choice/decision the client answers
;; with an outcome via the unary endpoint POST /api/$events/result
;; (args {clientId, eventId, outcome}, where clientId comes from
;; the `$events' ready frame).  outcome.kind ∈ result (with a
;; value) / next (handed to the next taker) / rejected (with an
;; error).
;;
;; Question answer value = {answers: [{id, selected: string[],
;; custom?}]} (selected is a vector; empty when custom-only).
;; Match the host's validation rules exactly: single-select takes
;; one label or a custom (either/or), multi-select takes a set of
;; labels + optional custom, an option-less question can only give
;; a custom, and answers must cover the whole frame.  Approval
;; answer value = an ApprovalOutcome string: `allowed-once' or
;; `rejected' (rejection is the default — C-g/ESC answers with
;; rejection too; sending no decision leaves the host blocked
;; forever on the pending approval).
;;
;; Interaction: read every question in the MINIBUFFER in one pass —
;; options are completion candidates (ordinals shown as affixes), multi-select is
;; comma-separated; text that matches no option is itself the
;; answer, and empty input skips the question.  Prompts carry the
;; Question N/M number; once all are answered, one outcome is
;; returned for the batch.
;; Skipping one question uses only the `dsh-emacs-question-skip-key'
;; shortcut = that question is overridden with an empty selected
;; (dsh web's per-question Skip); the rest are answered normally.
;; Empty input on an option-less question also skips it.
;; C-g abandons the whole batch: it returns outcome.kind `rejected'
;; with an error body (name/message, mirroring the cancelled intent
;; kept by the old protocol) — the host withdraws the ask and the
;; ask tool call aborts; the old behavior (no answer at all) left
;; the host pending forever and the turn stuck.
;;
;; Per waterfall generation (each $events reconnect mints a new
;; ready/clientId): when a new ready arrives this side retires all
;; pending frames of the previous generation (no answer — the old
;; clientId's result is a no-op); when the host cancels a waterfall
;; (cancel frame or session end) the pending frame is retired by
;; eventId.
;;
;; The minibuffer is a single global resource: with several
;; sessions live, other streams keep delivering waterfalls while
;; one frame is being answered.  Each kind has a FIFO queue, and
;; only one frame is answered at a time (nested completing-read calls
;; would stack different sessions' prompts in the same minibuffer
;; and overwrite each other); prompts carry the owning session's
;; identifier (the chat buffer name, e.g. [dsh: <title>]) so the user
;; knows which session asked.

(defvar dsh-emacs--question-queue nil
  "Pending `user-questions/request' waterfalls awaiting the single
interactive answering slot; each entry is (CHAT EVENT-ID SESSION-ID
QUESTIONS WAIT).")

(defvar dsh-emacs--approval-queue nil
  "Pending `approval/request' waterfalls awaiting the single interactive
answering slot; each entry is (CHAT EVENT-ID SESSION-ID TOOL-NAME
REASON CALL-ID).")

(defvar dsh-emacs--interaction-active nil
  "Identity occupying the shared question/approval prompt slot, or nil.
Dynamically bound to (KIND . EVENT-ID) for a question or approval waterfall,
or (late-answer) while the late-answer picker and reader run.  It owns only
the synchronous interaction; a timed question's wait claim can outlive it.")

(defvar dsh-emacs--waterfall-cancelled-event-id nil
  "Waterfall event id cancelled while its minibuffer was active.
Bound by the interaction drain for each frame, so no stale outcome is sent.")

(defvar-local dsh-emacs--session-questions nil
  "Latest `userQuestions' projection view of this chat's session, or nil.
A `dsh-protocol-user-questions' struct: the timed `ask_user_question' calls
still answerable and the ones already settled (dsh 0.2.0).  It is the only
source for a question whose foreground waterfall is gone, so
`dsh-emacs-answer-question' reads it and a settled transcript card can be
completed from it.")

(defun dsh-emacs--session-questions-apply (questions)
  "Merge decoded question projection QUESTIONS by sequence for this chat.
Nil resets the mirror on a new host generation.  Capability absence retains
its sequence, so an older update cannot restore stale questions.
A newly settled call also completes its transcript ask row, so a late answer
is recorded on the card that asked the question."
  (let ((seq (and questions (dsh-protocol-user-questions-seq questions)))
        (previous (and dsh-emacs--session-questions
                       (dsh-protocol-user-questions-seq
                        dsh-emacs--session-questions))))
    (when (or (not (integerp seq)) (not (integerp previous))
              (>= seq previous))
      (setq dsh-emacs--session-questions questions)
      (dolist (settled (and questions
                            (dsh-protocol-user-questions-settled questions)))
        (dsh-emacs-render-question-settled
         (dsh-protocol-settled-question-call-id settled)
         (dsh-protocol-question-answers-json
          (dsh-protocol-settled-question-answers settled)))))))

(defun dsh-emacs--waterfall-cancel-active (kind event-id)
  "Cancel the active waterfall when both KIND and EVENT-ID match.
Mark the id before leaving the minibuffer so its answering function can
distinguish remote resolution from the user's `C-g'."
  (when (equal dsh-emacs--interaction-active (cons kind event-id))
    (setq dsh-emacs--waterfall-cancelled-event-id event-id)
    (when (active-minibuffer-window)
      (abort-recursive-edit))))

(defun dsh-emacs--waterfall-cancelled-p ()
  "Non-nil when the active waterfall was cancelled by the host.
The host sends a `cancel' frame when another client answers; the active
event id is matched so a stale flag can never suppress a later prompt.
Only a question or approval slot is a waterfall: the late-answer slot is
`(late-answer)', whose cdr is nil like an uncancelled flag."
  (and (memq (car-safe dsh-emacs--interaction-active) '(question approval))
       (equal (cdr dsh-emacs--interaction-active)
              dsh-emacs--waterfall-cancelled-event-id)))

(defun dsh-emacs--interaction-run (kind)
  "Answer queued waterfalls of KIND without blocking the event dispatcher.
A reader is synchronous once started.  Starting it inside
`dsh-emacs-events--dispatch-pending' would keep that dispatcher from
consuming the host's `cancel' frame while the prompt is open, so a waterfall
another client already answered could never close here.  Schedule a
zero-delay drain from the dispatcher; direct callers (tests, commands) keep
opening the reader immediately."
  (if (bound-and-true-p dsh-emacs-events--dispatching)
      (dsh-emacs--server-run-later 0 nil #'dsh-emacs--interaction-drain kind)
    (dsh-emacs--interaction-drain kind)))

(defun dsh-emacs--interaction-drain (kind)
  "Answer queued waterfalls, starting with KIND (question or approval).
Each kind is FIFO: finish its queue before switching to the other kind.
New frames received during a reader only enqueue; this loop owns the shared
slot and releases it on every exit.  Answer submission is asynchronous, so
the next reader may start before the preceding response is acknowledged."
  (unless dsh-emacs--interaction-active
    (while (or dsh-emacs--question-queue dsh-emacs--approval-queue)
      (unless (if (eq kind 'question)
                  dsh-emacs--question-queue
                dsh-emacs--approval-queue)
        (setq kind (if (eq kind 'question) 'approval 'question)))
      (let* ((frame (if (eq kind 'question)
                        (pop dsh-emacs--question-queue)
                      (pop dsh-emacs--approval-queue)))
             (dsh-emacs--interaction-active (cons kind (nth 1 frame)))
             (dsh-emacs--waterfall-cancelled-event-id nil))
        (pcase kind
          ('question (dsh-emacs--question-answer frame))
          ('approval (dsh-emacs--approval-answer frame)))))))

(defun dsh-emacs--question-session-label (session-id)
  "Label identifying SESSION-ID in question prompts.
Prefers the live chat buffer's name (the title-based \"dsh: <title>\"
form); uses `dsh-emacs--chat-buffer-name' when loaded, then the raw id.
Long labels are truncated so the minibuffer prompt stays readable; a nil
SESSION-ID (direct test calls) yields an empty label."
  (let* ((buf (and session-id
                   (boundp 'dsh-emacs--chat-buffers)
                   (hash-table-p dsh-emacs--chat-buffers)
                   (gethash session-id dsh-emacs--chat-buffers)))
         (label (cond
                 ((and buf (buffer-live-p buf)) (buffer-name buf))
                 (session-id
                  (or (and (fboundp 'dsh-emacs--chat-buffer-name)
                           (dsh-emacs--chat-buffer-name session-id))
                      session-id))
                 (t ""))))
    (if (> (length label) 40)
        (concat (substring label 0 37) "…")
      label)))

(defun dsh-emacs--events-result-async (client-id event-id outcome callback)
  "Answer a `$events' waterfall: send OUTCOME for EVENT-ID on CLIENT-ID.
OUTCOME is the wire `outcome' object (an alist whose `kind' is
`result' with a `value', `next', or `rejected' with an `error' body).
The answer goes as a one-shot unary RPC to POST /api/$events/result with
args {clientId, eventId, outcome} (rpc.md §3.3).  CALLBACK receives
(ok-p . value-or-error) like `dsh-emacs--rpc-async'."
  (dsh-emacs--rpc-async
   "$events/result"
   (dsh-protocol-events-result-request client-id event-id outcome)
   callback))

(defun dsh-emacs--question-answer (frame)
  "Read and answer one question FRAME in its owning chat buffer.
Called with the shared interaction slot held.  The answer goes to
`$events/result' carrying the current `$events' generation's client-id.
A timed frame claims its foreground wait before reading, so the host cannot
expire the question out from under the user.  A submitted answer keeps the
claim until its asynchronous response arrives; other exits release it."
  (pcase-let* ((`(,chat ,event-id ,session-id ,raw-questions ,wait) frame)
               (questions (dsh-protocol--list raw-questions))
               (claim nil)
               (submitted nil))
    (unwind-protect
        (condition-case err
            (progn
              (setq claim
                    (and wait
                         (dsh-protocol-question-wait-timed wait)
                         (dsh-emacs--question-claim-wait
                          chat session-id
                          (dsh-protocol-question-wait-call-id wait))))
              (let ((answers
                     (unless (dsh-emacs--waterfall-cancelled-p)
                       (when (buffer-live-p chat)
                         (with-current-buffer chat
                           (dsh-emacs--collect-question-answers
                            questions session-id))))))
                (cond
                 ((equal event-id dsh-emacs--waterfall-cancelled-event-id)
                  (message "Question was answered elsewhere"))
                 (answers
                  (dsh-emacs--events-result-async
                   dsh-emacs-events--client-id
                   event-id
                   (dsh-protocol-question-result-outcome answers)
                   (lambda (ok value)
                     (unwind-protect
                         (if ok
                             (message "Answered %d question(s)" (length answers))
                           (message "Question response not accepted (%s)" value))
                       (dsh-emacs--question-release-wait claim)
                       (setq claim nil))))
                  (setq submitted t))
                 (t
                  ;; No choices collected (aborted via an empty no-option
                  ;; input, or the chat buffer died): abandon the whole
                  ;; waterfall — outcome kind `rejected' with an error body
                  ;; (dsh web's "abandon questions") so the ask aborts
                  ;; host-side and the run is never left blocked.
                  (dsh-emacs--question-decline event-id)))))
          (quit
           (unless (equal event-id dsh-emacs--waterfall-cancelled-event-id)
             (dsh-emacs--question-decline event-id)))
          (error
           (message "dsh question error: %S" err)
           ;; The host waits for an outcome even when reading failed (for
           ;; example, a nested minibuffer made the reader signal).  Decline
           ;; unless an answer already went out or the host cancelled it.
           (unless (or submitted
                       (equal event-id dsh-emacs--waterfall-cancelled-event-id))
             (condition-case fallback
                 (dsh-emacs--question-decline event-id)
               (error (message "dsh question decline error: %S" fallback))))))
      (unless submitted
        (dsh-emacs--question-release-wait claim)))))

(defun dsh-emacs--question-claim-wait (chat session-id call-id)
  "Claim the timed foreground wait of CALL-ID on CHAT while it is being read.
The host suspends the wait's deadline while a client holds the
`userQuestions/attachWait' stream (dsh 0.2.0), so an answer prompt cannot be
expired and closed out from under the user.  Returns a (PROCESS . STREAM-ID)
token for `dsh-emacs--question-release-wait', or nil when there is nothing to
claim — no live socket, or no named call."
  (when (and (buffer-live-p chat)
             (stringp call-id)
             (not (string-empty-p call-id)))
    (with-current-buffer chat
      (let ((process dsh-emacs--event-process))
        (when (process-live-p process)
          (let ((stream
                 (dsh-emacs-events-open-stream
                  process "userQuestions/attachWait"
                  (dsh-protocol-question-wait-request session-id call-id)
                  "userQuestions/attachWait"
                  (lambda (_value) nil))))
            (and stream (cons process stream))))))))

(defun dsh-emacs--question-release-wait (claim)
  "Release a CLAIM made by `dsh-emacs--question-claim-wait'.
Closing the stream reschedules the host's original deadline, which can
already have passed.  Submitted answers must hold it until acknowledgement.
Safe on nil."
  (when claim
    (dsh-emacs-events-close-stream (car claim) (cdr claim))))

(defconst dsh-emacs--question-skip-label "Skip this question"
  "Internal sentinel for skipping one question with an empty selection.
The skip command returns it directly; it is not a visible candidate.")

;; Bound by `dsh-emacs--question-choice' around its reader, so the helper
;; functions below stay parameterless and the reader sees one context.
(defvar dsh-emacs--question-where nil
  "Prompt prefix of the question being read (session and question number).")

(defvar dsh-emacs--question-text nil
  "Text of the question being read.")

(defvar dsh-emacs--question-hint nil
  "Input hint appended to the question prompt.")

(defvar dsh-emacs--question-roster nil
  "Plain option labels of the question being read.")

(defvar dsh-emacs--question-options nil
  "Option structs of the question being read.")

(defvar dsh-emacs--question-current nil
  "Protocol struct of the question being read.")

(defvar dsh-emacs--question-multi nil
  "Whether the question being read selects multiple options.")

(defun dsh-emacs--question-pick-labels (labels)
  "Return LABELS numbered from 1, the answer form for typed numbers.
The reader displays the ordinal as a completion affix, but a comma-separated
answer can still name options by number as well as by label."
  (cl-loop for label in labels for n from 1
           collect (format "%d. %s" n label)))

(defun dsh-emacs--question-prefix-label (prefix labels)
  "Return the single LABELS entry PREFIX unambiguously starts, or nil.
Matching ignores case, so a typed `alph' finds `Alpha'.  `require-match' is
nil in the reader, so completion may hand back an unexpanded prefix instead
of the candidate; an ambiguous prefix stays unresolved on purpose, so the
text is never mapped to the wrong option."
  (let ((hits (cl-remove-if-not
               (lambda (label)
                 (and (<= (length prefix) (length label))
                      (eq t (compare-strings prefix 0 nil label 0 (length prefix)
                                             t))))
               labels)))
    (and (= 1 (length hits)) (car hits))))

(defun dsh-emacs--question-numbered-label (number labels)
  "Return the LABELS entry NUMBER refers to, or nil.
NUMBER is a bare option number.  The numbered forms are matched in
order, so `2' finds `2. Version' even when the label itself is numeric, and
an out-of-range number matches nothing."
  (let (found)
    (dolist (candidate (dsh-emacs--question-pick-labels labels) found)
      (unless found
        (when (and (string-prefix-p (concat number ". ") candidate)
                   (string-match "\\`[0-9]+\\. \\(.+\\)\\'" candidate))
          ;; The numbered form was built from the label, so the tail is it.
          (setq found (match-string 1 candidate)))))))

(defun dsh-emacs--question-label-of (picked labels)
  "Return the plain LABELS entry PICKED names, or nil.
PICKED is a candidate string, a bare option number, a label, an
unambiguous prefix of a label, or a numbered prefix such as \"2. \".
An exact label wins over an unambiguous prefix, and both win over
stripping a numbered prefix, so a label that starts with \"<number>. \"
still round-trips; a bare number or a number with no label addresses the
option at that position, because `completing-read-multiple' can hand back
an element the completion engine left unexpanded."
  (or (cl-find picked labels :test #'equal)
      (dsh-emacs--question-prefix-label picked labels)
      (let ((plain
             (cond
              ((string-match "\\`[0-9]+\\. \\(.+\\)\\'" picked)
               (dsh-emacs--question-label-of (match-string 1 picked) labels))
              ((string-match "\\`\\([0-9]+\\)\\. ?\\'" picked)
               (dsh-emacs--question-numbered-label
                (match-string 1 picked) labels))
              ((string-match "\\`\\([0-9]+\\)\\'" picked)
               (dsh-emacs--question-numbered-label picked labels)))))
        (and plain (cl-find plain labels :test #'equal)))))

(defvar-local dsh-emacs--question-echo-message nil
  "Last echo-area detail this question reader showed.")

(defun dsh-emacs--question-echo (text)
  "Show TEXT as this reader's echo-area help, without logging it.
Re-showing the same text stays quiet so repeated commands do not spam the
echo area; an empty TEXT clears help this reader owns."
  (cond
   ((or (null dsh-emacs-question-help-display) (string-empty-p text))
    (when (and dsh-emacs--question-echo-message
               (equal (current-message) dsh-emacs--question-echo-message))
      (message nil))
    (setq dsh-emacs--question-echo-message nil))
   ((equal text dsh-emacs--question-echo-message))
   (t
    (setq dsh-emacs--question-echo-message text)
    (let ((inhibit-message t)
          (message-log-max nil))
      (message "%s" text)))))

(defun dsh-emacs--question-echo-cleanup ()
  "Clear echo-area help this reader owns, leaving other messages alone."
  (when (and dsh-emacs--question-echo-message
             (equal (current-message) dsh-emacs--question-echo-message))
    (message nil))
  (setq dsh-emacs--question-echo-message nil))

(defun dsh-emacs--question-affixation (candidates)
  "Number CANDIDATES and append their option descriptions.
CANDIDATES are the plain option labels; the ordinal is display-only, so a
frontend completes with the label and deleting it leaves an empty answer
instead of a stale \"N. \" prefix.  Each description carries
`dsh-emacs-meta-face', matching the ask card."
  (mapcar
   (lambda (candidate)
     (let* ((position (cl-position candidate dsh-emacs--question-roster
                                   :test #'equal))
            (option (cl-find candidate dsh-emacs--question-options
                             :key #'dsh-protocol-question-option-label
                             :test #'equal))
            (description (and option
                              (dsh-protocol-question-option-description option)))
            (suffix (if (or (null description)
                            (string-empty-p description))
                        ""
                      (propertize (format "  %s" description)
                                  'face 'dsh-emacs-meta-face))))
       (list candidate
             (if position (format "%d. " (1+ position)) "")
             suffix)))
   candidates))

(defun dsh-emacs--question-completion-table (labels)
  "Completion table over plain LABELS that also accepts option numbers.
A typed number or numbered prefix is resolved through
`dsh-emacs--question-label-of', so \"1\", \"1. \" and \"1. Alpha\" complete
to \"Alpha\"; the reader displays the ordinal separately through
`dsh-emacs--question-affixation'.  The table pins the incoming order."
  (lambda (string pred action)
    (if (eq action 'metadata)
        '(metadata (display-sort-function . identity)
                   (cycle-sort-function . identity))
      (let* ((trimmed (string-trim string))
             (target (or (dsh-emacs--question-label-of trimmed labels)
                         trimmed)))
        (complete-with-action action labels target pred)))))

(defun dsh-emacs--question-skip-command ()
  "Skip the current question with an empty selection.
Bound from `dsh-emacs-question-skip-key' in the reader's minibuffer."
  (interactive)
  (throw 'dsh-emacs--question-command dsh-emacs--question-skip-label))

(defun dsh-emacs--question-reader-keymap ()
  "Return the reader's minibuffer keymap: the current local map plus the
skip shortcut (`dsh-emacs-question-skip-key', default `C-c C-s'), so
nothing leaks into unrelated `completing-read' prompts.  The typed text is the
answer itself (comma-separated options, see `crm-separator'), so no key
is remapped and completion keep working."
  (let ((map (copy-keymap (current-local-map))))
    (when dsh-emacs-question-skip-key
      (define-key map (if (stringp dsh-emacs-question-skip-key)
                          (kbd dsh-emacs-question-skip-key)
                        dsh-emacs-question-skip-key)
                  #'dsh-emacs--question-skip-command))
    map))

(defun dsh-emacs--question-reader-setup ()
  "Install the reader's keymap, candidate affixes and echo-area help.
Everything is minibuffer-local, so no other `completing-read' sees it.  The
prompt is preselected instead of the first candidate: an empty answer means
\"skip\", and a frontend that preselects the first row would otherwise turn
a bare RET into an answer.  The same setup also serves the nested free-text
read, where there is no question context to show."
  ;; Keep our own previous text out of the way, but never clear a message
  ;; this reader did not write.
  (when (and dsh-emacs--question-echo-message
             (equal (current-message) dsh-emacs--question-echo-message))
    (message nil))
  (setq-local dsh-emacs--question-echo-message nil)
  (when (boundp 'vertico-preselect)
    (setq-local vertico-preselect 'prompt))
  (setq-local completion-extra-properties
              (list :affixation-function #'dsh-emacs--question-affixation))
  (use-local-map (dsh-emacs--question-reader-keymap))
  (add-hook 'minibuffer-exit-hook #'dsh-emacs--question-echo-cleanup nil t)
  (dsh-emacs--question-echo
   (let ((question dsh-emacs--question-current)
         detail)
     (when (dsh-protocol-question-p question)
       (setq detail (dsh-protocol-question-detail question)))
     (if (or (null detail) (string-empty-p detail)) "" detail)))
  nil)

(defun dsh-emacs--question-answer-values (picked labels)
  "Return PICKED resolved to LABELS entries, in the question's option order.
Each element is a candidate, a bare number, a label, or a label prefix; an
element that names no option is left as the typed text, so the caller can
tell `every value is an option` from `the user is answering in text`, and
never silently drops part of the answer.  The answer follows the order the
question offered the options, not the order they were typed."
  (let ((values (mapcar (lambda (value)
                          (let ((value (if (stringp value)
                                           (string-trim value)
                                         value)))
                            (or (dsh-emacs--question-label-of value labels)
                                value)))
                        picked)))
    (cl-stable-sort values #'< :key (lambda (value)
                                      (or (cl-position value labels :test #'equal)
                                          most-positive-fixnum)))))

(defun dsh-emacs--question-read-multiple (labels)
  "Read one comma-separated answer over LABELS.
Returns the selected candidate strings, the free-text sentinel, or nil for
an empty answer.  Candidates are the plain labels; the reader shows their
ordinals through `dsh-emacs--question-affixation', so completing inserts the
label and deleting it leaves an empty answer.  `require-match' is nil on
purpose: the answer is typed text, so an empty minibuffer must stay empty (a
mandatory match lets a frontend turn a bare RET into its preselected
candidate) and an unknown value is better treated as a free-text answer than
rejected.  C-g propagates.
The completion table carries identity sort metadata: the ordinal is the
option's position in the question, so a frontend must not reorder the list
(the default ranking is by history, length and alphabet, which scrambles the
items and differs from question to question).  CRM hands the collection on to
the frontend through `crm--collection-fn', which passes this metadata
through."
  (catch 'dsh-emacs--question-command
    (minibuffer-with-setup-hook #'dsh-emacs--question-reader-setup
      (completing-read-multiple
       (concat dsh-emacs--question-where dsh-emacs--question-text
               (or dsh-emacs--question-hint "") ": ")
       (dsh-emacs--question-completion-table labels)
       nil nil nil nil nil))))

(defun dsh-emacs--question-choose (labels)
  "Read one answer over LABELS.
The prompt carries the question and the candidates carry their own
descriptions.  An empty input is a skip, and anything that names no option
is the user's own text."
  (catch 'answer
    (let ((picked (dsh-emacs--question-read-multiple labels)))
      (cond
       ((equal picked dsh-emacs--question-skip-label)
        (throw 'answer :skip))
       ((null picked) :skip)
       (t
        (let* ((values (dsh-emacs--question-answer-values picked labels))
               (options (cl-remove-if-not (lambda (value)
                                            (cl-member value labels :test #'equal))
                                          values)))
          (cond
           ((cl-every #'string-empty-p values)
            ;; Whitespace only: treat it as the empty answer, not as a
            ;; custom reply made of spaces.
            :skip)
           ((null options)
            ;; Names no option: the text is the answer, like an unmatched
            ;; input at any completion prompt.
            (throw 'answer (cons :custom (string-join picked ", "))))
           ((/= (length options) (length values))
            ;; Only part of it names options; treating it as a selection
            ;; would silently drop the rest, so the whole input is the text.
            (throw 'answer (cons :custom (string-join picked ", "))))
           (dsh-emacs--question-multi
            (cons :selected options))
           (t
            (cons :one (car options))))))))))

(defun dsh-emacs--question-choice (question &optional index total session-id)
  "Read one answer to QUESTION as ((id . ID) (selected . LABELS) ...).
QUESTION accepts a protocol struct or legacy wire alist.  INDEX/TOTAL
and SESSION-ID identify the question and its owning session in the prompt.
Multiple selection is one comma-separated answer (for example `2,3'):
the options are the candidates and their ordinals are display affixes, so
typing a number still answers but completing inserts the plain label.  An
empty input skips the question, and any text that names no option is itself the answer (like an
unmatched input at any completion prompt).  Single selection uses the first
value when several are given.  Every question is answered by one minibuffer read, so the reader is
never reopened per key.  The skip key
(`dsh-emacs-question-skip-key') answers with an empty selection and C-g
abandons the whole waterfall.  Questions without options read free text,
with empty input meaning skip.  The question detail shows in the echo
area; each option's description rides along with its candidate."
  (let* ((question (dsh-protocol--struct
                    #'dsh-protocol-question-p
                    #'dsh-protocol-question--from-alist question))
         (id (dsh-protocol-question-id question))
         (text (let ((text (dsh-protocol-question-text question)))
                 (if (and (stringp text) (not (string-empty-p text)))
                     text
                   "Question")))
         (options (dsh-protocol-question-options question))
         (labels (mapcar #'dsh-protocol-question-option-label options))
         (dsh-emacs--question-roster labels)
         (dsh-emacs--question-current question)
         (dsh-emacs--question-options options)
         (dsh-emacs--question-multi
          (dsh-protocol-question-multi-select question))
         ;; The session label is redundant in the asking buffer.
         (same-buffer (and (boundp 'dsh-emacs--buffer-session)
                           (equal dsh-emacs--buffer-session session-id)))
         (dsh-emacs--question-where
          (concat
           (if (and session-id (not (string-empty-p session-id))
                    (not same-buffer))
               (format "[%s] " (dsh-emacs--question-session-label session-id))
             "")
           (if index (format "Question %d/%d — " index total) "")))
         (dsh-emacs--question-text text)
         (dsh-emacs--question-hint
          (if (null labels)
              " (empty input = skip)"
            (if dsh-emacs--question-multi
                " (2,3 or names, or your own text; empty = skip)"
              " (a name or your own text; empty = skip)"))))
    (if (null labels)
        (let ((custom
               (string-trim
                (minibuffer-with-setup-hook #'dsh-emacs--question-reader-setup
                  (read-string (format "%s%s%s: "
                                       dsh-emacs--question-where text
                                       dsh-emacs--question-hint))))))
          (dsh-protocol-question-answer-request
           id [] (unless (string-empty-p custom) custom)))
      (let ((answer (dsh-emacs--question-choose labels)))
        (pcase answer
          (:skip
           (when (and index total)
             (message "Question %d/%d skipped" index total))
           (dsh-protocol-question-answer-request id []))
          (`(:custom . ,custom)
           (dsh-protocol-question-answer-request id [] custom))
          (`(:selected . ,selected)
           (dsh-protocol-question-answer-request id selected))
          (`(:one . ,label)
           (dsh-protocol-question-answer-request id (list label)))
          (_ (error "Unhandled question answer: %S" answer)))))))

(defun dsh-emacs--question-preview-item (id text detail multi options)
  "Build one local preview question; no wire payload is involved.
ID/TEXT/DETAIL are strings, MULTI says whether several options may be
picked, and OPTIONS is a list of (LABEL . DESCRIPTION) pairs.  Values go
in through the protocol accessors, so this local sample never spells a
wire field name."
  (let ((question (dsh-protocol-question--from-alist nil)))
    (setf (dsh-protocol-question-id question) id
          (dsh-protocol-question-text question) text
          (dsh-protocol-question-detail question) detail
          (dsh-protocol-question-multi-select question) multi
          (dsh-protocol-question-options question)
          (mapcar (pcase-lambda (`(,label . ,description))
                    (let ((option (dsh-protocol-question-option--from-alist nil)))
                      (setf (dsh-protocol-question-option-label option) label
                            (dsh-protocol-question-option-description option)
                            description)
                      option))
                  options))
    question))

(defun dsh-emacs--collect-question-answers (questions &optional session-id)
  "Answer QUESTIONS one at a time from the minibuffer: each question's
options are the completion candidates (`dsh-emacs--question-choice',
with its INDEX/TOTAL in the prompt), in frame order.  SESSION-ID (when
given) labels every prompt with the owning session.  Returns the answer
alists in frame order.  Empty free text skips an option-less question;
C-g propagates to the caller, which declines the waterfall."
  (let ((total (length questions))
        (answers nil)
        (n 0))
    (catch 'abort
      (dolist (q questions)
        (setq n (1+ n))
        (when (dsh-emacs--waterfall-cancelled-p)
          (throw 'abort nil))
        (let ((answer (dsh-emacs--question-choice q n total session-id)))
          (if (null answer) (throw 'abort nil)
            (push answer answers))))
      (reverse answers))))

;;;###autoload (autoload 'dsh-emacs-question-preview "dsh-emacs" nil t)
(defun dsh-emacs-question-preview ()
  "Try the ask reader locally, without sending an RPC.
Presents a three-question batch — a multi-select with option
descriptions, a single-select, and an option-less free-text question — so
one run shows every prompt shape and the \"Question N/M\" framing.  The
answers of the whole batch are echoed the way the RPC outcome would carry
them."
  (interactive)
  (message "Preview answers: %S"
           (dsh-emacs--collect-question-answers
            (list (dsh-emacs--question-preview-item
                   "preview-1" "What should this update include?"
                   "Multi-select: pick several (2,3), or type your own answer."
                   t
                   '(("UI" . "Show the current option's description here.")
                     ("Regression tests" . "Cover multi-select and free text.")
                     ("Docs" . "Update usage notes and the decision record.")))
                  (dsh-emacs--question-preview-item
                   "preview-2" "How should the change be verified?"
                   "Single select: pick one option, or type your own answer."
                   nil
                   '(("Run scripts/verify.sh" . "Parens, tests, compile pass.")
                     ("Click through the GUI only" . "Walk the path by hand.")))
                  (dsh-emacs--question-preview-item
                   "preview-3" "Anything else to add?"
                   "No options: empty input skips, text is the answer."
                   nil nil)))))

(cl-defun dsh-emacs--question-requested (chat event-id session-id questions
                                                  &optional wait)
  "Queue a `user-questions/request' waterfall EVENT-ID of SESSION-ID and answer it.
WAIT, when non-nil, is the frame's `dsh-protocol-question-wait' struct: it
names the timed tool call whose foreground wait the reader claims while the
question is on screen (dsh 0.2.0; nil for the blocking legacy tool).
The minibuffer is one global resource: with several chat buffers open, a
$events frame can deliver the next question while the previous one is
still being answered interactively.  Nested `completing-read' calls
would stack different sessions' prompts inside the same minibuffer, so
frames are queued (FIFO) and drained one at a time by
`dsh-emacs--interaction-drain'; each prompt carries the owning session's
label (see `dsh-emacs--question-session-label').  All questions of the
waterfall are then read one after another (options as completion
candidates plus a \"Type answer…\" free-text choice) and answered with a
single `$events/result' outcome (value = {answers: …}).  C-g abandons
the whole waterfall with outcome kind
`rejected' and an error body (dsh web's \"abandon questions\") so the host
withdraws the ask and the run is never left blocked; the quit is caught
here, so it cannot leak out of the process filter as \"error in process
filter: Quit\".
A waterfall whose EVENT-ID is already pending (queued or active) is
dropped instead of asked twice, mirroring the approval flow.
Explicit plan-review intent opens a document without occupying the minibuffer."
  (when (dsh-emacs-plan--request chat event-id session-id questions)
    (cl-return-from dsh-emacs--question-requested))
  (unless (or (equal dsh-emacs--interaction-active (cons 'question event-id))
              (cl-some (lambda (entry)
                         (equal event-id (nth 1 entry)))
                       dsh-emacs--question-queue))
    (setq dsh-emacs--question-queue
          (nconc dsh-emacs--question-queue
                 (list (list chat event-id session-id questions wait))))
    ;; Desktop notice, turn-finish style (`dsh-emacs-enable-notifications'):
    ;; the answering prompt may wait behind another session's prompt, so
    ;; announce a pending question even when the user is away from the
    ;; chat.  Acceptance-gated: a replayed duplicate waterfall is dropped
    ;; above and must never re-notify.
    (when (buffer-live-p chat)
      (let* ((qs (dsh-protocol--list questions))
             (first-text
              (dsh-protocol-question-text
               (dsh-protocol--struct #'dsh-protocol-question-p
                                     #'dsh-protocol-question--from-alist
                                     (car qs))))
             (count (length qs))
             (body (format "Question%s%s"
                           (if (stringp first-text)
                               (format ": %s" first-text)
                             "")
                           (if (> count 1)
                               (format " (+%d more)" (1- count))
                             ""))))
        (dsh-emacs-notify--post session-id body chat))))
  (dsh-emacs--interaction-run 'question))

(defun dsh-emacs--question-decline (event-id)
  "Abandon a whole `user-questions/request' waterfall EVENT-ID.
Answers with outcome kind `rejected' and an error body (name/message)
mirroring the old protocol's reserved `cancelled' intent — the same wire
signal dsh web's \"abandon questions\" produces: the host resolves the
pending ask as cancelled and the ask tool call aborts, so the agent's
turn is never left blocked on an unanswered question.  The quit is
contained here so it cannot leak out of the process filter as \"error in
process filter: Quit\"."
  (dsh-emacs--events-result-async
   dsh-emacs-events--client-id
   event-id
   (dsh-protocol-events-cancelled-outcome "User abandoned the questions")
   (lambda (ok value)
     (if ok
         (message "Question cancelled")
       (message "Question response not accepted (%s)" value)))))

(defun dsh-emacs--question-cancelled (event-id)
  "Retire the queued `user-questions/request' waterfall EVENT-ID.
A host `cancel' frame for EVENT-ID means the waterfall was withdrawn and
no longer needs answering; drop any still-queued copy so a replay never
re-asks a finished question.  When the matching waterfall owns the active
minibuffer, close it and let its drain retire without sending an outcome."
  (dsh-emacs-plan--cancel event-id)
  (setq dsh-emacs--question-queue
        (cl-remove-if (lambda (entry)
                        (equal event-id (nth 1 entry)))
                      dsh-emacs--question-queue))
  (dsh-emacs--waterfall-cancel-active 'question event-id))

(defun dsh-emacs--question-continued ()
  "Return this chat's still-answerable `continued' timed questions.
Entries are `dsh-protocol-pending-question' structs in ask order."
  (let ((view dsh-emacs--session-questions))
    (when view
      (cl-remove-if-not
       (lambda (question)
         (eq 'continued (dsh-protocol-pending-question-state question)))
       (dsh-protocol-user-questions-active view)))))

(defun dsh-emacs--question-continued-label (question)
  "Short picker label for a `continued' QUESTION.
Its first question text names the call; a call the projection could not
describe falls back to the call id."
  (let ((first (car (dsh-protocol-pending-question-questions question))))
    (or (and first (dsh-protocol-question-text first))
        (dsh-protocol-pending-question-call-id question)
        "Question")))

(defun dsh-emacs--question-answer-late (session-id call-id answers)
  "Submit ANSWERS for the timed CALL-ID of SESSION-ID.
ANSWERS is the reader's wire-shaped answer list.  The host steers the batch
into the agent as a late reply; a later `userQuestions' projection frame
reports the call settled."
  (dsh-emacs--rpc-async
   "userQuestions/answer"
   (dsh-protocol-question-late-answer-request session-id call-id answers)
   (lambda (ok value)
     (cond
      ((not ok) (message "Question answer not accepted (%s)" value))
      ((eq value t) (message "Answered %d question(s)" (length answers)))
      (t (message "Question is no longer waiting for an answer"))))))

;;;###autoload (autoload 'dsh-emacs-answer-question "dsh-emacs" nil t)
(defun dsh-emacs-answer-question ()
  "Answer a timed `ask_user_question' whose foreground window has closed.
A timed question the user did not answer before its window expired stays
answerable (dsh 0.2.0).  This command reads the session's `userQuestions'
projection, asks the chosen call's questions in the minibuffer with the
ordinary reader, and submits the batch through `userQuestions/answer'; the
host steers it into the agent as a late reply.  With several calls waiting,
one is chosen by its first question, and the batch must cover every question
of that call.  Reports instead of prompting when nothing is waiting."
  (interactive)
  (dsh-emacs-subagent-require 'mutate)
  (let ((session-id (and (boundp 'dsh-emacs--buffer-session)
                         dsh-emacs--buffer-session))
        (pending (dsh-emacs--question-continued)))
    (unless session-id
      (user-error "Not in a dsh chat buffer"))
    (unless pending
      (user-error "No question is waiting for a later answer"))
    (when (or dsh-emacs--interaction-active
              (active-minibuffer-window))
      (user-error "Another prompt is active"))
    (unwind-protect
        (let* ((dsh-emacs--interaction-active '(late-answer))
               (entry (if (= 1 (length pending))
                          (car pending)
                        (let ((choices
                               (mapcar (lambda (question)
                                         (cons (dsh-emacs--question-continued-label
                                                question)
                                               question))
                                       pending)))
                          (cdr (assoc (completing-read "Answer which question: "
                                                       choices nil t)
                                      choices)))))
               (call-id (dsh-protocol-pending-question-call-id entry))
               (questions (dsh-protocol-pending-question-questions entry))
               (answers (dsh-emacs--collect-question-answers questions session-id)))
          (unless answers
            (user-error "Question left unanswered"))
          (dsh-emacs--question-answer-late session-id call-id answers))
      ;; The dynamic reservation has unwound even on C-g or a reader error.
      ;; Preserve the late-answer handoff order: questions, then approvals.
      (dsh-emacs--interaction-drain 'question))))

(defun dsh-emacs--waterfall-generation-retired ()
  "Retire all pending question/approval waterfalls of a dead generation.
Each `$events' reconnect hands out a NEW client-id; answering the old
generation's still-queued frames with it would be a no-op, so the pending
frames are dropped (a waterfall currently being prompted cannot be
aborted from here — its stale answer is likewise a no-op).

Silent when nothing was pending: a reconnect mints a new generation as a
matter of course, and \"retiring 0 queued question(s) and 0 approval(s)\"
on every one of them is echo-area noise.  The message stays for a
generation that actually dropped queued work, which the user needs to
know about."
  (let ((questions (length dsh-emacs--question-queue))
        (approvals (length dsh-emacs--approval-queue)))
    (when (or (> questions 0) (> approvals 0))
      (message "dsh: new $events generation — retiring %d queued question(s) and %d approval(s)"
               questions approvals)))
  (dsh-emacs-plan--cancel)
  (setq dsh-emacs--question-queue nil
        dsh-emacs--approval-queue nil))

;; ---------------------------------------------------------------------------
;;  User approval (approval/request) responses
;; ---------------------------------------------------------------------------
;; Out-of-bounds requests from sandboxed tools push
;; `approval/request' waterfalls over the core connection's `$events'
;; stream: when bash/fs and friends need files outside the workspace,
;; the host first asks the user's permission (the same protocol as
;; dsh web's ApprovalPanel).  The client must show the request
;; (toolName + justification reason), read the user's approve/reject
;; decision, and answer with an outcome via the unary endpoint POST
;; /api/$events/result (value = ApprovalOutcome string: the client
;; gives only "allowed-once" | "rejected"; the wire has no
;; approvalId).
;;
;; Interaction: minibuffer y-or-n-p — y/the y key = allow once, n =
;; reject; C-g/ESC answers with rejection too (with no decision the
;; client sends nothing and the host blocks forever on the pending
;; approval; a waterfall the host already cancelled has a no-op
;; result and is dropped silently).  The minibuffer is a single
;; global resource: approvals and questions share one slot
;; (`dsh-emacs--interaction-active').  New frames queue while it is held;
;; the interaction drain finishes the current kind's queue before switching,
;; never nesting two minibuffer prompts.

(defun dsh-emacs--approval-display-reason (request)
  "Choose the localized reason of decoded approval REQUEST.
Resolve once before queueing, so the notification and prompt agree."
  (let* ((locale
          (cl-find-if
           (lambda (value) (and (stringp value) (not (string-empty-p value))))
           (list dsh-emacs-approval-language system-messages-locale
                 (getenv "LC_ALL") (getenv "LC_MESSAGES") (getenv "LANG")
                 "en")))
         (tag (car (split-string
                    (downcase (replace-regexp-in-string "_" "-" locale))
                    "[.@]")))
         (translations (dsh-protocol-approval-request-display-reasons request)))
    (or (cdr (assoc tag translations))
        (cdr (assoc (car (split-string tag "-")) translations))
        (cdr (assoc "en" translations))
        (dsh-protocol-approval-request-reason request))))

(defun dsh-emacs--approval-command-line (call-id)
  "One-line summary of the tool call CALL-ID from the live transcript.
Reads the buffer-local `dsh-emacs--tool-states' map, so it must run in
the chat buffer of the approving session.  For bash the rendered body is
the real command (\"$ cat /etc/hostname\"); other tools fall back to
\"Title — args\".  Returns nil when CALL-ID is unknown (e.g. the call
predates this window, or the approval replayed right after open)."
  (when (and call-id
             (boundp 'dsh-emacs--tool-states)
             (hash-table-p dsh-emacs--tool-states))
    (let* ((state (dsh-emacs-render--tool-state call-id))
           (title (and state (plist-get state :title)))
           (args (and state (plist-get state :args))))
      (cond
       ((and (stringp args) (string-match-p "\\`\\$ " args)) args)
       ((and (stringp args) (not (string-empty-p args)))
        (if (and (stringp title) (not (string-empty-p title)))
            (format "%s — %s" title args)
          args))
       ((and (stringp title) (not (string-empty-p title))) title)
       (t nil)))))

(defun dsh-emacs--approval-answer (frame)
  "Read and answer one approval FRAME with the shared interaction slot held.
A quit (C-g/ESC) counts as a rejection so the host never stays blocked on a
pending frame.
The decision goes out as a `$events/result' outcome (value =
ApprovalOutcome string) carrying the current generation's client-id and
the waterfall's EVENT-ID.  The prompt runs in the frame's chat buffer so
the tool-call lookup (`dsh-emacs--approval-command-line') can read the
buffer-local transcript state."
  (pcase-let ((`(,chat ,event-id ,session-id ,tool-name ,reason ,call-id) frame))
    (let ((sent nil))
      (condition-case err
          (let ((allow
                 (unless (dsh-emacs--waterfall-cancelled-p)
                   (condition-case nil
                       (if (buffer-live-p chat)
                           (with-current-buffer chat
                             (dsh-emacs--approval-prompt
                              session-id tool-name reason call-id))
                         (dsh-emacs--approval-prompt
                          session-id tool-name reason call-id))
                     ;; A remote cancel must reach the outer handler without
                     ;; becoming the user's default rejection.
                     (quit
                      (if (equal event-id
                                 dsh-emacs--waterfall-cancelled-event-id)
                          (signal 'quit nil)
                        (message "Approval %s quit — rejecting" event-id)
                        nil))))))
            (if (equal event-id dsh-emacs--waterfall-cancelled-event-id)
                (message "Approval was answered elsewhere")
              (dsh-emacs--events-result-async
               dsh-emacs-events--client-id
               event-id
               (dsh-protocol-approval-outcome allow)
               (lambda (ok value)
                 (if ok
                     (message "%s %s for %s"
                              (if allow "Approved" "Rejected")
                              (or tool-name "tool") session-id)
                   (message "Approval response not accepted (%s)"
                            value))))
              (setq sent t)))
        ;; Remote cancellation exits the prompt without answering again.
        (quit
         (unless (equal event-id dsh-emacs--waterfall-cancelled-event-id)
           (message "Approval %s cancelled" event-id)))
        (error
         (message "dsh approval error: %S" err)
         ;; Reading failed (for example, a nested minibuffer made the
         ;; prompt signal): reject so the host is not left blocked.  A
         ;; remote cancel already answered it.
         (unless (or sent
                     (equal event-id dsh-emacs--waterfall-cancelled-event-id))
           (condition-case fallback
               (dsh-emacs--events-result-async
                dsh-emacs-events--client-id event-id
                (dsh-protocol-approval-outcome nil)
                (lambda (ok value)
                  (unless ok
                    (message "Approval response not accepted (%s)" value))))
             (error (message "dsh approval rejection error: %S" fallback)))))))))

(defun dsh-emacs--avoid-minibuffer-prompt (&rest _)
  "Point-entered handler keeping point off the read-only prompt tail.
Same behavior as the obsolete `minibuffer-avoid-prompt' (deprecated
since 25.1): entering the prompt region moves point past it."
  (when (and (minibufferp) (< (point) (minibuffer-prompt-end)))
    (goto-char (minibuffer-prompt-end))))

(defun dsh-emacs--approval-prompt (session-id tool-name reason call-id)
  "Read the user's decision for one approval in the minibuffer.
The prompt is multi-line, untruncated and colored: the asker's full
justification REASON in `dsh-emacs-approval-justification-face' (light
orange), then a blank line and the actual tool call (the bash command
line, see `dsh-emacs--approval-command-line' — runs in the chat buffer,
so CALL-ID must be that session's) in `dsh-emacs-approval-command-face'
(gray).  The owning session, tool and call-id are logged to *Messages*.
Without any detail the prompt falls back to \"Allow TOOL?\".  The prompt
faces survive because `minibuffer-prompt-properties' is bound WITHOUT
its `face' slot around the read — the minibuffer prompt insertion would
otherwise replace every prompt face with `minibuffer-prompt'.  Returns t
to allow once, nil to reject; C-g signals `quit' and the caller answers
the same rejection (an unanswered frame would block the host forever)."
  (let* ((where (concat
                 (if (and session-id (not (string-empty-p session-id)))
                     (format "[%s] " (dsh-emacs--question-session-label
                                      session-id))
                   "")
                 (if (and call-id (not (string-empty-p call-id)))
                     (format "call %s " call-id)
                   "")))
         (just-line (and reason (not (string-empty-p reason))
                         (propertize reason
                                     'face
                                     'dsh-emacs-approval-justification-face)))
         (cmd-line (let ((line (dsh-emacs--approval-command-line call-id)))
                     (and line (propertize line
                                           'face
                                           'dsh-emacs-approval-command-face))))
         (lines (delq nil (list just-line cmd-line)))
         (prompt (if lines
                     (mapconcat #'identity lines "\n\n")
                   (format "Allow %s?" (or tool-name "tool")))))
    (when (and where (not (string-empty-p where)))
      (message "dsh approval, %s: %s%s"
               (or tool-name "tool") where
               (if (and reason (not (string-empty-p reason)))
                   (format " — %s" reason)
                 "")))
    (let ((minibuffer-prompt-properties
           ;; Keep the prompt non-editable and point-safe, but drop the
           ;; `face' slot: `read-from-minibuffer' applies these properties
           ;; over the prompt, and `add-text-properties' replaces an
           ;; existing `face' — with it bound the justification/command
           ;; colors above would be wiped by `minibuffer-prompt'.
           (list 'read-only t
                 'point-entered #'dsh-emacs--avoid-minibuffer-prompt)))
      ;; `y-or-n-p' may otherwise use a native dialog (after a mouse event),
      ;; which `abort-recursive-edit' cannot close when another client
      ;; answers; the documented approval reader is the minibuffer.
      (let ((use-dialog-box nil))
        (y-or-n-p prompt)))))

(defun dsh-emacs--approval-requested (chat event-id session-id tool-name
                                             reason call-id)
  "Queue an `approval/request' waterfall EVENT-ID of SESSION-ID and answer it.
Mirrors `dsh-emacs--question-requested': the minibuffer is one global
resource, so frames are queued (FIFO) and drained one at a time by
`dsh-emacs--interaction-drain', never nested inside another prompt.  A
waterfall whose EVENT-ID is already pending ($events replay of the same
request) is dropped instead of asked twice.  The decision — allow once
or reject — is sent as a single `$events/result' outcome (value =
ApprovalOutcome string) carrying the current generation's client-id and
the EVENT-ID; C-g answers the rejection too (default deny).  The quit is
caught here so it cannot leak out of the process filter as \"error in
process filter: Quit\"."
  (unless (or (equal dsh-emacs--interaction-active (cons 'approval event-id))
              (cl-some (lambda (entry)
                         (equal event-id (nth 1 entry)))
                       dsh-emacs--approval-queue))
    (setq dsh-emacs--approval-queue
          (nconc dsh-emacs--approval-queue
                 (list (list chat event-id session-id
                             tool-name reason call-id))))
    ;; Desktop notice, turn-finish style: the approval prompt may wait in
    ;; the queue while the user is in another buffer or app; the body
    ;; carries the tool call (else justification, else tool name) so the
    ;; decision can be made away from the minibuffer.  Acceptance-gated:
    ;; a replayed duplicate never re-notifies.  The command-line lookup
    ;; needs the chat buffer's transcript state, so it runs there.
    (when (buffer-live-p chat)
      (let* ((command (with-current-buffer chat
                        (dsh-emacs--approval-command-line call-id)))
             (detail (or command
                         (and (stringp reason)
                              (not (string-empty-p reason)) reason)
                         (and (stringp tool-name)
                              (not (string-empty-p tool-name)) tool-name)))
             (body (format "Approval%s"
                           (if detail (format ": %s" detail) ""))))
        (dsh-emacs-notify--post session-id body chat))))
  (dsh-emacs--interaction-run 'approval))

(defun dsh-emacs--approval-cancelled (event-id)
  "Retire the queued `approval/request' waterfall EVENT-ID.
A host `cancel' frame for EVENT-ID means the waterfall was withdrawn and
no longer needs answering; drop any still-queued copy so a replay never
re-asks a finished approval.  When the matching waterfall owns the active
minibuffer, close it and let its drain retire without sending an outcome."
  (setq dsh-emacs--approval-queue
        (cl-remove-if (lambda (entry)
                        (equal event-id (nth 1 entry)))
                      dsh-emacs--approval-queue))
  (dsh-emacs--waterfall-cancel-active 'approval event-id))

(provide 'dsh-emacs-interaction)
;;; dsh-emacs-interaction.el ends here
