;;; dsh-emacs-jobs.el --- Background-job roster and output -*- lexical-binding: t; -*-

;; Copyright (C) 2025 vritser

;; Author: vritser
;; Version: 0.5.0
;; License: GPL-3.0-or-later
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; Background jobs (dsh's `job' Remote namespace) belong to a session: a bash
;; command the model ran in the background, a subagent delegation, a workflow.
;; dsh 0.1.6 and earlier carried the same roster in the `session/control'
;; `jobs' record; 0.1.7 deleted that record and moved the state behind the
;; `job' namespace's own streams, so a client must subscribe to see it at all.
;;
;; Two logical streams on the chat buffer's `/api/remote.mux' socket:
;;
;;   job/list   (one per followed session)  the whole roster per frame, so a
;;                                          reconnect's first frame is truth;
;;   job/follow (one per job being viewed)  `opened' anchor, `output' batches
;;                                          with an absolute resume offset, then
;;                                          one terminal `status' and a normal
;;                                          close.
;;
;; Emacs-native interaction (no panels, no overlays, same shape as the pending
;; queue in `dsh-emacs-queue.el'):
;;   - the mode line shows `[J2]' while the session can see live jobs, so a
;;     background command the model started stays visible without a command;
;;   - `dsh-emacs-list-jobs' (`C-c C-j') opens the roster as a minibuffer
;;     candidate list and acts on the CURRENTLY highlighted entry with single
;;     keys (vertico up/down picks the row — no numbering): RET shows the
;;     job's retained output, k kills it (two presses, like dsh web's armed
;;     stop), r refreshes;
;;   - each job's output lives in its own read-only `*dsh-job: …*' buffer,
;;     appended as the `job/follow' stream delivers batches; `q' buries it.
;;
;; A kill is a human action: the host records `cancelled by the user' as the
;; reason and the owning agent still receives its completion notice, so the
;; model learns the user stopped its task instead of inferring it.

;;; Code:

(require 'cl-lib)
(require 'dsh-emacs-protocol)

;; Lazy boundary with same-package modules (see AGENTS.md): dsh-emacs.el
;; assembles this module; the event layer and the modeline call back into its
;; symbols through `declare-function'/runtime guards, so this module needs no
;; top-level require of them.
(declare-function dsh-emacs--rpc-async "dsh-emacs" (method params callback))
(declare-function dsh-emacs-events-close-stream "dsh-emacs-events"
                  (process stream-id))
(declare-function dsh-emacs-events-open-stream "dsh-emacs-events"
                  (process endpoint args name handler))
(defvar dsh-emacs--buffer-session)
(defvar dsh-emacs--current-session)
(defvar dsh-emacs--event-process)
;; Borrowed vertico runtime variables (see `dsh-emacs-jobs--menu-item'):
;; declare-only so the byte-compiler stays quiet — always read under `boundp'.
(defvar vertico--index)
(defvar vertico--candidates)

(defvar dsh-emacs-jobs-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mode-line mouse-1] #'dsh-emacs-list-jobs)
    map)
  "Mouse binding shared by mode-line background-job indicators.")

(defvar-local dsh-emacs-jobs--roster nil
  "Background jobs this chat's session can see, newest frame wins.
A list of `dsh-protocol-job'; replaced wholesale by every `job/list' frame
(the host's set is authoritative), so no local bookkeeping can drift.")

(defvar-local dsh-emacs-jobs--stream nil
  "Stream id of this chat's live `job/list' subscription, or nil.")

(defvar-local dsh-emacs-jobs--stream-process nil
  "Process the current `job/list' stream was opened on.
A different process means a replacement socket whose frames reboot the
roster; the old registration died with the old socket.")

(defvar-local dsh-emacs-jobs--kill-armed nil
  "Job id whose stop control is armed, or nil.
The first `k' arms it, a second `k' within `dsh-emacs-jobs-kill-arm-seconds'
kills; dsh web uses the same two-press confirmation for its stop control.")

(defvar-local dsh-emacs-jobs--kill-timer nil
  "Timer that disarms the two-press kill confirmation.")

(defvar-local dsh-emacs-jobs--popup nil
  "The output buffer this chat last opened, if it is still live.")

;; Output-buffer-local state: which chat and job the buffer is following,
;; and the resume offset the last `output' batch reported.
(defvar-local dsh-emacs-jobs--popup-chat nil
  "Chat buffer whose socket carries this output buffer's stream.")
(defvar-local dsh-emacs-jobs--popup-id nil
  "Job id this output buffer follows.")
(defvar-local dsh-emacs-jobs--popup-job nil
  "Latest `dsh-protocol-job' projection of this output buffer's job.")
(defvar-local dsh-emacs-jobs--popup-next nil
  "Absolute offset the next `job/follow' read would resume from.")
(defvar-local dsh-emacs-jobs--popup-stream nil
  "Stream id of this output buffer's live `job/follow' subscription.")

(defcustom dsh-emacs-jobs-kill-arm-seconds 3
  "How long an armed job stop waits for its confirming press.
Matches dsh web's stop control: the first press arms, the second within
this window kills, and the control resets on its own."
  :type 'number
  :group 'dsh-emacs)

(defface dsh-emacs-jobs-modeline-face
  '((t :inherit dsh-emacs-modeline-queue-face))
  "Face for the mode-line background-job indicator."
  :group 'dsh-emacs)

;;; ---------------------------------------------------------------------------
;;; Roster mirror (chat-buffer-local, replaced wholesale by job/list frames)
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-jobs--live-p (job)
  "Non-nil when JOB has not settled yet."
  (memq (dsh-protocol-job-status job) '(running stopping)))

(defun dsh-emacs-jobs-counts ()
  "Return (LIVE . SETTLED) job counts for this chat's session.
LIVE counts running and stopping jobs — what the mode line shows, since a
finished job is history the list command can still reach."
  (let ((live 0))
    (dolist (job dsh-emacs-jobs--roster)
      (when (dsh-emacs-jobs--live-p job) (setq live (1+ live))))
    (cons live (- (length dsh-emacs-jobs--roster) live))))

(defun dsh-emacs-jobs--apply (chat frame)
  "Apply one `job/list' FRAME to CHAT's roster mirror.
FRAME is `dsh-protocol-job-list'; its set replaces the previous one, so a
frame that drops a job (settled and reclaimed, or no longer visible to the
session) removes it here too."
  (when (buffer-live-p chat)
    (with-current-buffer chat
      (setq dsh-emacs-jobs--roster (dsh-protocol-job-list-jobs frame))
      (dsh-emacs-jobs--refresh))))

(defun dsh-emacs-jobs--refresh ()
  "Repaint this chat's job-dependent chrome.
The mode-line indicator is a cache derived from the roster, so a roster
change must force the line to redraw; a popup following this job updates
its own header when the next frame arrives."
  (force-mode-line-update))

(defun dsh-emacs-jobs--session-id-maybe ()
  "Session id of the current chat buffer, or nil.
The `-maybe' records the contract difference from the entry layer's
`dsh-emacs--active-session-id' (same resolution, but that one signals when
no session is open): the subscribe path runs at handshake completion and
must no-op rather than error when the connection has no session."
  (or dsh-emacs--buffer-session dsh-emacs--current-session))

;;; ---------------------------------------------------------------------------
;;; Streams (the socket is the chat buffer's; lifecycle follows it)
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-jobs--roster-handler (chat)
  "Return the `job/list' item handler for CHAT.
A nil VALUE is the stream's teardown signal (server `end', socket drop, or
an explicit close): the roster is kept as last seen rather than blanked —
a reconnect re-opens the stream and the host's first frame is the truth,
so a transient gap must not flash the mode line empty."
  (lambda (value)
    (when (and value (buffer-live-p chat))
      (dsh-emacs-jobs--apply
       chat (dsh-protocol-job-list--from-alist value)))))

(defun dsh-emacs-jobs-open (chat)
  "Subscribe CHAT's session to its `job/list' roster stream.
Idempotent for a live subscription on the same socket: called at handshake
completion (and again after a reconnect, from
`dsh-emacs-events--follow-open''s sibling call), it re-opens only when the
socket is a replacement.  No-op when CHAT has no session or no live socket."
  (when (buffer-live-p chat)
    (with-current-buffer chat
      (let ((process dsh-emacs--event-process)
            (session-id (dsh-emacs-jobs--session-id-maybe)))
        (when (and session-id (process-live-p process))
          (if (and (equal process dsh-emacs-jobs--stream-process)
                   (process-get process 'dsh-emacs-stream-handlers)
                   (assoc dsh-emacs-jobs--stream
                          (process-get process 'dsh-emacs-stream-handlers)))
              nil
            (setq dsh-emacs-jobs--stream-process process
                  dsh-emacs-jobs--stream
                  (dsh-emacs-events-open-stream
                   process "job/list"
                   `((request . ((sessionId . ,session-id))))
                   "job/list"
                   (dsh-emacs-jobs--roster-handler chat)))))))))

(defun dsh-emacs-jobs-close (chat)
  "Cancel CHAT's `job/list' subscription, if any."
  (when (buffer-live-p chat)
    (with-current-buffer chat
      (let ((process dsh-emacs-jobs--stream-process)
            (stream dsh-emacs-jobs--stream))
        (setq dsh-emacs-jobs--stream nil
              dsh-emacs-jobs--stream-process nil)
        (when (and process stream (process-live-p process))
          (dsh-emacs-events-close-stream process stream))))))

(defun dsh-emacs-jobs-reopen (chat)
  "Re-open CHAT's `job/list' stream after the chat socket was replaced.
Called by the event layer once a (re)connect completed its handshake."
  (when (buffer-live-p chat)
    (with-current-buffer chat
      (setq dsh-emacs-jobs--stream nil
            dsh-emacs-jobs--stream-process nil))
    (dsh-emacs-jobs-open chat)))

(defun dsh-emacs-jobs--chat-closed ()
  "Retire this chat's job state when its buffer is killed.
Runs on `kill-buffer-hook': the socket teardown already retired the
streams, so this only closes the output buffer that would otherwise be
left displaying a subscription nobody serves."
  (dsh-emacs-jobs--disarm)
  (let ((popup dsh-emacs-jobs--popup))
    (setq dsh-emacs-jobs--popup nil)
    (when (and (bufferp popup) (buffer-live-p popup))
      (with-current-buffer popup
        (setq dsh-emacs-jobs--popup-stream nil
              dsh-emacs-jobs--popup-chat nil))
      (let ((windows (get-buffer-window-list popup nil t)))
        (dolist (window windows)
          (quit-window nil window)))
      (kill-buffer popup))))

;;; ---------------------------------------------------------------------------
;;; Job output (`job/follow' stream into a read-only buffer)
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-jobs--output-buffer-name (job)
  "Name of JOB's output buffer."
  (format "*dsh-job: %s %s*"
          (or (dsh-protocol-job-id job) "?")
          (or (dsh-protocol-job-label job) "")))

(defun dsh-emacs-jobs--status-tag (job)
  "Short status tag of JOB for the header and list rows."
  (pcase (dsh-protocol-job-status job)
    ('running "run") ('stopping "stop") ('completed "done")
    ('killed "killed") ('failed "failed") (_ "?")))

(defun dsh-emacs-jobs--elapsed (job)
  "Human-readable elapsed time of JOB.
JOB's `startedAt'/`finishedAt' are epoch milliseconds; `float-time' is epoch
seconds, so both ends are converted to the same unit before subtracting (a
settled job mixes the two otherwise, and the difference lands in the
millions of hours)."
  (let* ((start (dsh-protocol-job-started-at job))
         (end-ms (or (dsh-protocol-job-finished-at job)
                     (and (numberp start) (* 1000 (float-time)))))
         (secs (and (numberp start) (numberp end-ms)
                    (max 0 (floor (- end-ms start) 1000)))))
    (when secs
      (cond ((< secs 60) (format "%ds" secs))
            ((< secs 3600) (format "%dm%02ds" (/ secs 60) (mod secs 60)))
            (t (format "%dh%02dm" (/ secs 3600) (/ (mod secs 3600) 60)))))))

(defun dsh-emacs-jobs--describe (job)
  "One-line description of JOB: kind, state, elapsed, label, progress/detail."
  (string-join
   (delq nil
         (list (format "[%s]" (or (dsh-protocol-job-kind job) "job"))
               (format "(%s)" (dsh-emacs-jobs--status-tag job))
               (dsh-emacs-jobs--elapsed job)
               (dsh-protocol-job-label job)
               (let ((line (or (dsh-protocol-job-progress job)
                               (dsh-protocol-job-detail job))))
                 (and line (format "— %s" line)))))
   " "))

(defun dsh-emacs-jobs--escape-percent (text)
  "Double every `%' in TEXT.
Header-line strings undergo `%'-sequence expansion, so a literal `%' in a
job label (\"make 50% done\") would otherwise be swallowed or expand to
something else."
  (replace-regexp-in-string "%" "%%" text t t))

(defun dsh-emacs-jobs--header (job)
  "Header line text for JOB's output buffer."
  (dsh-emacs-jobs--escape-percent
   (format " %s%s"
           (dsh-emacs-jobs--describe job)
           (let ((spill (dsh-protocol-job-output-spill-paths job)))
             (if spill
                 (format "  [spill: %s]" (string-join spill ", "))
               "")))))

(defun dsh-emacs-jobs--popup-live-p (buffer)
  "Non-nil when BUFFER is a live output buffer."
  (and (bufferp buffer) (buffer-live-p buffer)))

(defun dsh-emacs-jobs--append (buffer text)
  "Append TEXT to the end of read-only output BUFFER, following the tail.
Point follows the new end only when it was already at the end (a reader at
the bottom keeps streaming); a reader who scrolled back — or a buffer with
point parked mid-text while nothing displays it — keeps that reading
position.  Restoring it is deliberate: `insert' leaves point after the
inserted text, so simply inserting at `point-max' would drag the reader to
the tail on every chunk."
  (when (dsh-emacs-jobs--popup-live-p buffer)
    (with-current-buffer buffer
      (let ((inhibit-read-only t)
            (position (point))
            (at-end (= (point) (point-max))))
        (goto-char (point-max))
        (insert text)
        (goto-char (if at-end (point-max) position))))))

(defun dsh-emacs-jobs--chat-process ()
  "The event process of the chat this output buffer follows, or nil.
The socket lives on the chat buffer (`dsh-emacs--event-process' is
buffer-local there); the output buffer itself never binds it."
  (let ((chat dsh-emacs-jobs--popup-chat))
    (and (buffer-live-p chat)
         (buffer-local-value 'dsh-emacs--event-process chat))))

(defun dsh-emacs-jobs--output-item (buffer)
  "Handle one `job/follow' frame VALUE for output BUFFER.
A nil VALUE is the stream teardown (server `end' after `status', an error,
or the chat socket dropping); the text already appended stands."
  (lambda (value)
    (when (dsh-emacs-jobs--popup-live-p buffer)
      (with-current-buffer buffer
        (if (null value)
            (setq dsh-emacs-jobs--popup-stream nil)
          (let ((frame (dsh-protocol-job-frame--from-alist value)))
            (pcase (dsh-protocol-job-frame-type frame)
              ("opened"
               ;; The `from' anchor needs no gap note: the open frame omits
               ;; `from', so the host starts at `output.earliest' and every
               ;; byte it retained does arrive; only a `lossy' batch means
               ;; bytes were dropped between the request and the chunks.
               (when-let* ((job (dsh-protocol-job-frame-job frame)))
                 (setq dsh-emacs-jobs--popup-job job)
                 (setq header-line-format
                       (dsh-emacs-jobs--header job))))
              ("output"
               (when (dsh-protocol-job-frame-lossy frame)
                 (dsh-emacs-jobs--append
                  buffer "\n[dsh] earlier output was reclaimed by the host\n"))
               (dolist (chunk (dsh-protocol-job-frame-chunks frame))
                 (when (dsh-protocol-job-chunk-gap-before chunk)
                   (dsh-emacs-jobs--append
                    buffer "\n[dsh] output gap\n"))
                 (dsh-emacs-jobs--append
                  buffer (or (dsh-protocol-job-chunk-text chunk) "")))
               (setq dsh-emacs-jobs--popup-next
                     (dsh-protocol-job-frame-next frame)))
              ("status"
               (when-let* ((job (dsh-protocol-job-frame-job frame)))
                 (setq dsh-emacs-jobs--popup-job job)
                 (setq header-line-format
                       (dsh-emacs-jobs--header job))))
              (_ nil))))))))

(defun dsh-emacs-jobs--quit ()
  "Quit this output window and cancel its subscription (`q').
The buffer stays (with the text delivered so far) so re-opening the job
resumes from a fresh whole-ring read rather than an empty buffer; the
stream itself is retired, since nothing is displaying it.  The cancel goes
out on the chat buffer's socket — this buffer follows the job but does not
own the connection, so it has no process of its own."
  (interactive)
  (let ((process (dsh-emacs-jobs--chat-process))
        (stream dsh-emacs-jobs--popup-stream))
    (when (and (processp process) (process-live-p process) stream)
      (dsh-emacs-events-close-stream process stream))
    (setq dsh-emacs-jobs--popup-stream nil)
    (quit-window)))

(defvar dsh-emacs-jobs-output-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "q") #'dsh-emacs-jobs--quit)
    map)
  "Keymap for `dsh-emacs-jobs-output-mode'.")

(define-derived-mode dsh-emacs-jobs-output-mode special-mode "dsh-job"
  "Major mode for one background job's output.
The buffer is read-only and appended by the `job/follow' stream; `q'
buries the window and cancels this buffer's subscription (other viewers
are unaffected)."
  (setq-local truncate-lines nil)
  (setq-local header-line-format nil))

(defun dsh-emacs-jobs-show-output (job)
  "Show JOB's retained output in its own buffer, subscribing to it.
A second invocation for the same job reuses the buffer and re-opens the
stream, which re-reads the retained ring from the oldest byte and is
therefore also the recovery path after a drop."
  (interactive)
  (let* ((chat (current-buffer))
         (session-id (dsh-emacs-jobs--session-id-maybe))
         (process dsh-emacs--event-process)
         (name (dsh-emacs-jobs--output-buffer-name job))
         (buffer (get-buffer-create name)))
    (unless (process-live-p process)
      (user-error "Not connected to dsh"))
    (setq dsh-emacs-jobs--popup buffer)
    (with-current-buffer buffer
      (unless (derived-mode-p 'dsh-emacs-jobs-output-mode)
        (dsh-emacs-jobs-output-mode))
      (setq dsh-emacs-jobs--popup-chat chat)
      (setq dsh-emacs-jobs--popup-id (dsh-protocol-job-id job))
      (setq dsh-emacs-jobs--popup-job job)
      (setq dsh-emacs-jobs--popup-next nil)
      (setq header-line-format (dsh-emacs-jobs--header job))
      ;; A fresh subscription re-reads the retained ring from the oldest
      ;; byte; the previous stream (if any) is retired first so its queued
      ;; frames cannot interleave with the replacement.
      (when (and dsh-emacs-jobs--popup-stream process
                 (process-live-p process))
        (dsh-emacs-events-close-stream process dsh-emacs-jobs--popup-stream))
      (let ((inhibit-read-only t))
        (erase-buffer)
        ;; Park point at the end so `dsh-emacs-jobs--append' follows the tail
        ;; of this fresh view from the first chunk on (a reader who scrolls
        ;; back later keeps that position instead).
        (goto-char (point-max)))
      (setq dsh-emacs-jobs--popup-stream
            (and (process-live-p process)
                 (dsh-emacs-events-open-stream
                  process "job/follow"
                  `((request . ((jobId . ,(dsh-protocol-job-id job))
                                ,@(when (dsh-protocol-job-owner job)
                                    `((sessionId . ,session-id))))))
                  "job/follow"
                  (dsh-emacs-jobs--output-item buffer)))))
    (pop-to-buffer buffer)))

;;; ---------------------------------------------------------------------------
;;; Kill (human stop, two-press confirmation)
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-jobs--disarm ()
  "Disarm the pending stop confirmation."
  (when (timerp dsh-emacs-jobs--kill-timer)
    (cancel-timer dsh-emacs-jobs--kill-timer))
  (setq dsh-emacs-jobs--kill-timer nil
        dsh-emacs-jobs--kill-armed nil))

(defun dsh-emacs-jobs--arm (job-id)
  "Arm JOB-ID for a confirming press within `dsh-emacs-jobs-kill-arm-seconds'.
The chat buffer is captured now: after the timeout it may be gone, and the
disarm must then be a no-op rather than touch another buffer's state."
  (dsh-emacs-jobs--disarm)
  (setq dsh-emacs-jobs--kill-armed job-id)
  (let ((chat (current-buffer)))
    (setq dsh-emacs-jobs--kill-timer
          (run-at-time dsh-emacs-jobs-kill-arm-seconds nil
                       (lambda ()
                         (when (buffer-live-p chat)
                           (with-current-buffer chat
                             (dsh-emacs-jobs--disarm))))))))

(defun dsh-emacs-jobs-kill (job)
  "Kill background JOB on the human's behalf.
The host records `cancelled by the user' as the reason and still delivers
the owning agent its completion notice; the roster converges through the
`job/list' stream (`stopping', then the settled detail)."
  (let ((session-id (dsh-emacs-jobs--session-id-maybe))
        (job-id (dsh-protocol-job-id job))
        (chat (current-buffer)))
    (unless session-id
      (user-error "No session is open"))
    (dsh-emacs--rpc-async
     "job/kill"
     `((request . ((sessionId . ,session-id) (jobId . ,job-id))))
     (lambda (ok value)
       (when (buffer-live-p chat)
         (with-current-buffer chat
           (if ok
               (message "Stopping %s (%s)"
                        job-id
                        (or (and (listp value)
                                 (cdr (assq 'outcome value)))
                            "requested"))
             (message "Could not stop %s: %S" job-id value))))))))

(defun dsh-emacs-jobs--request-kill (job)
  "Two-press stop for JOB: arm on the first press, kill on the second.
Returns non-nil only when JOB was actually killed; nil means this press
armed the confirmation (`dsh-emacs-jobs--menu-kill' keeps the menu open
for the confirming press rather than exiting on the armed one)."
  (let ((job-id (dsh-protocol-job-id job)))
    (if (equal job-id dsh-emacs-jobs--kill-armed)
        (progn (dsh-emacs-jobs--disarm)
               (dsh-emacs-jobs-kill job)
               t)
      (dsh-emacs-jobs--arm job-id)
      (message "Press k again within %ss to stop %s"
               dsh-emacs-jobs-kill-arm-seconds job-id)
      nil)))

;;; ---------------------------------------------------------------------------
;;; The roster menu (`C-c C-j')
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-jobs--table (jobs)
  "Return ((LABEL . JOB) ...) for JOBS with unique LABELs.
Live jobs lead (they are what the mode line counts), each group in the
host's own order; colliding labels get a numeric suffix so a label maps
back to exactly one job however the minibuffer picked it."
  (let ((live (cl-remove-if-not #'dsh-emacs-jobs--live-p jobs))
        (settled (cl-remove-if #'dsh-emacs-jobs--live-p jobs))
        (seen (make-hash-table :test 'equal)))
    (mapcar
     (lambda (job)
       (let* ((base (dsh-emacs-jobs--describe job))
              (n (1+ (gethash base seen 0))))
         (puthash base n seen)
         (cons (if (= n 1) base (format "%s [%d]" base n)) job)))
     (append live settled))))

(defvar dsh-emacs-jobs--pick-table nil
  "((LABEL . JOB) ...): the entries of the open job menu.
A DYNAMIC binding set by `dsh-emacs-list-jobs' around the
`completing-read'; the menu's single-key commands resolve the entry they
act on through this table — the same pattern as the queue chooser.")

(defun dsh-emacs-jobs--menu-item ()
  "The JOB the next menu key acts on.
Uses the vertico-highlighted candidate when vertico renders the list, else
the typed input as an exact/prefix match on the labels, else the first
entry (the one the mode line's count points at).  Reads `vertico--index' /
`vertico--candidates' directly rather than through an accessor, exactly as
the queue chooser does; `equal' ignores text properties, so the face
vertico puts on a candidate does not break the lookup."
  (let* ((vertico-active (and (bound-and-true-p vertico-mode)
                              (boundp 'vertico--candidates)
                              (boundp 'vertico--index)
                              (>= vertico--index 0)))
         (hl (and vertico-active
                  (ignore-errors (nth vertico--index vertico--candidates))))
         (typed (condition-case nil (minibuffer-contents) (error nil)))
         (entry (or (and hl (assoc hl dsh-emacs-jobs--pick-table))
                    (and typed (assoc typed dsh-emacs-jobs--pick-table))
                    (and typed
                         (let ((hit (car (all-completions
                                          typed
                                          (mapcar #'car
                                                  dsh-emacs-jobs--pick-table)))))
                           (and hit (assoc hit dsh-emacs-jobs--pick-table))))
                    (car dsh-emacs-jobs--pick-table))))
    (cdr entry)))

(defun dsh-emacs-jobs--menu-chat ()
  "The chat buffer the job menu was opened from."
  (window-buffer (minibuffer-selected-window)))

(defun dsh-emacs-jobs--menu-run (fn)
  "Close the job minibuffer and run FN on the picked job in the chat buffer.
FN is deferred through `run-at-time 0': inside a minibuffer command nothing
after `exit-minibuffer' is ever executed — the exit THROWS out of the
recursive minibuffer edit — so the action must be scheduled BEFORE the exit
and fired once the minibuffer is gone."
  (let* ((chat (dsh-emacs-jobs--menu-chat))
         (job (dsh-emacs-jobs--menu-item)))
    (run-at-time 0 nil
                 (lambda ()
                   (when (and (buffer-live-p chat) job)
                     (with-current-buffer chat
                       (funcall fn job)))))
    (exit-minibuffer)))

(defun dsh-emacs-jobs--menu-show ()
  "Show the picked job's output (`RET')."
  (interactive)
  (dsh-emacs-jobs--menu-run #'dsh-emacs-jobs-show-output))

(defun dsh-emacs-jobs--menu-kill ()
  "Stop the picked job (`k'), with the two-press confirmation.
The arming press KEEPS the menu open: the confirmation is a second `k' on
the same menu, so the armed state stays reachable — the menu is the only
place that runs the two-press logic, and closing on the arming press would
leave no way to press `k' again inside the arm window.  Only the killing
press closes the menu."
  (interactive)
  (let* ((chat (dsh-emacs-jobs--menu-chat))
         (job (dsh-emacs-jobs--menu-item)))
    (when (and (buffer-live-p chat) job)
      (when (with-current-buffer chat (dsh-emacs-jobs--request-kill job))
        (exit-minibuffer)))))

(defun dsh-emacs-jobs--menu-refresh ()
  "Re-open the roster stream for the menu's session (`r')."
  (interactive)
  (let ((chat (dsh-emacs-jobs--menu-chat)))
    (run-at-time 0 nil
                 (lambda ()
                   (when (buffer-live-p chat)
                     (with-current-buffer chat
                       (dsh-emacs-jobs-close chat)
                       (dsh-emacs-jobs-open chat)
                       (message "Refreshing background jobs…")))))
    (exit-minibuffer)))

(defun dsh-emacs-jobs--chooser-keymap ()
  "Minibuffer keymap for the job menu.
`RET' shows the picked job's output, `k' stops it, `r' refreshes; built
exactly like the queue chooser's keymap (a copy of the minibuffer's
current local map — vertico's when active — plus our single keys), mounted
last in the setup-hook chain so the keys win."
  (let ((map (copy-keymap (or (current-local-map) (make-sparse-keymap)))))
    (define-key map (kbd "RET") #'dsh-emacs-jobs--menu-show)
    (define-key map (kbd "k") #'dsh-emacs-jobs--menu-kill)
    (define-key map (kbd "r") #'dsh-emacs-jobs--menu-refresh)
    map))

(defun dsh-emacs-jobs--chooser-setup-hook ()
  "Job-menu minibuffer setup: stable order, first entry preselected.
Mirrors the queue chooser: pins the frontend's own sort variables (the
candidates carry no completion metadata to pin) and preselects the first
row, which is the live job the mode-line count refers to.  Returns nil
explicitly — `minibuffer-with-setup-hook' funcalls the setup value."
  (when (boundp 'vertico-sort-function)
    (setq-local vertico-sort-function nil))
  (when (boundp 'vertico-sort-override-function)
    (setq-local vertico-sort-override-function nil))
  (when (boundp 'vertico-preselect)
    (setq-local vertico-preselect 'first))
  (use-local-map (dsh-emacs-jobs--chooser-keymap))
  nil)

(defun dsh-emacs-list-jobs ()
  "Manage this session's background jobs (minibuffer menu).
Opens the roster the `job/list' stream has mirrored as a candidate list
(live jobs first; vertico/icomplete up/down moves) and acts on the picked
job with SINGLE keys bound inside the minibuffer: `RET' show its retained
output in a read-only buffer, `k' stop it (press twice within
`dsh-emacs-jobs-kill-arm-seconds'), `r' re-subscribe the roster.  A session
with no jobs offers nothing to pick, so this reports that instead of
opening an empty menu."
  (interactive)
  (let ((jobs dsh-emacs-jobs--roster))
    (when (null jobs)
      (user-error "No background jobs for this session"))
    (let ((dsh-emacs-jobs--pick-table (dsh-emacs-jobs--table jobs)))
      (minibuffer-with-setup-hook
          #'dsh-emacs-jobs--chooser-setup-hook
        (completing-read
         (format "Job (%d live): " (car (dsh-emacs-jobs-counts)))
         (mapcar #'car dsh-emacs-jobs--pick-table)
         nil t nil nil (caar dsh-emacs-jobs--pick-table))))))

(provide 'dsh-emacs-jobs)

;;; dsh-emacs-jobs.el ends here
