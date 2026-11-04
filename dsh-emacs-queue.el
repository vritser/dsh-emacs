;;; dsh-emacs-queue.el --- Pending-input queue (queue/steer) for dsh-emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2025 vritser

;; Author: vritser
;; Version: 0.8.0
;; License: GPL-3.0-or-later
;; Package-Requires: ((emacs "28.1"))

;;; Commentary:

;; Client-side mirror of the dsh agent inbox: input sent while a turn is
;; running either queues as the next turn (`session/prompt' mode "queue")
;; or steers the running agent before its next step (mode "steer").  The
;; host publishes the authoritative snapshot as the `inbox' session
;; projection on the core connection's `session/control' logical stream
;; (every session's cell in the generation baseline, then a `projection'
;; frame on each inbox splice), so this module only mirrors frames — there
;; is no fetch RPC and no local bookkeeping that could drift.  dsh 0.1.7
;; deleted the dedicated `session/queue' frames that carried the same state
;; through 0.1.6; the `inbox' projection predates them and is still
;; published, so this source works against 0.1.5+ servers.

;; Emacs-native interaction (no panels, no overlays):
;;   - the echo area flashes transient feedback on enqueue / steer /
;;     consumption, derived from the frame diff;
;;   - `dsh-emacs-list-queue' (C-c C-q) opens one completion list:
;;     RET or C-c s sends now, C-c e edits, C-c d deletes, C-c x
;;     deletes all;
;;   - Composer displays the next visible pending item on its own read-only
;;     row above the input; this module owns selection and transient gating.

;;; Code:
(defvar dsh-emacs--buffer-subagent)
(declare-function dsh-emacs-subagent-require "dsh-emacs-subagent"
                  (action &optional session-id))

(require 'cl-lib)
(require 'dsh-emacs-protocol)
(require 'dsh-emacs-server)
(require 'dsh-emacs-ui)

;; Lazy boundary with same-package modules (see AGENTS.md): dsh-emacs.el
;; assembles this module, which calls back into its symbols through
;; declare-function at runtime, avoiding a top-level require cycle.
(declare-function dsh-emacs--active-session-id "dsh-emacs" ())
(declare-function dsh-emacs--busy-p "dsh-emacs" ())
(declare-function dsh-emacs--submit-plain "dsh-emacs" (message &rest args))
(declare-function dsh-emacs-composer-render "dsh-emacs-composer" ())

;;; ---------------------------------------------------------------------------
;;; State mirror (buffer-local, replaced wholesale by mux frames)
;;; ---------------------------------------------------------------------------

(defvar-local dsh-emacs--queue-items nil
  "Pending inbox items of this chat's session, in delivery order.
List of `dsh-protocol-queue-item'; replaced wholesale by every
`inbox' projection frame (the host snapshot is authoritative).")

(defvar-local dsh-emacs--queue-process nil
  "The mux process the current mirror was seeded from.
A frame from a different process means a fresh connection whose first
`inbox' projection frame is the connect-time snapshot: apply it silently,
without enqueue/steer/consumption echoes.")

(defvar-local dsh-emacs--queue-deleted nil
  "Item ids this client deleted via `session/updateQueue'.
Their disappearance from the next frame is the delete being confirmed,
not a consumption, so the `running' feedback is suppressed.  Ids are
pruned once the confirming frame arrives.")

(defvar-local dsh-emacs--queue-submit-suppress nil
  "Non-nil while the mirror stays silent about a self-submitted transient.
The wire knows only `queue' / `steer' prompt modes, so a message sent
while the mirror is EMPTY — idle, or queued behind a running turn with
nothing else pending — STILL passes through the host inbox: the host
appends it (an `inbox' projection frame with the item) and claims it again
at the turn start (a frame without it) within milliseconds.  Diffing
that pair flashes `queued:' then `running:' — the flash on sending a new
message — though nothing was ever really parked: the submit path renders
the user message directly.  While this flag is set, `dsh-emacs-queue-apply'
updates the mirror but emits no feedback — it clears at the claim frame
(the mirror empties again AFTER the submit's own item was seen in it —
an empty baseline/seed before the splice is not a claim), in the submit
failure branch, or via `dsh-emacs-queue--submit-suppress-timer'
(transport-safety only:
un-sticks the echo gate when neither a settle frame nor an RPC failure
ever arrives; it paces NO preview).  The Next Message preview is gated
by this flag too — with one exception: a submit that was already PARKED
when it was made (`dsh-emacs-queue--submit-parked-p': a turn was running
then) shows its preview at once, because such an item can only be
claimed at the turn end.  An IDLE submit is not parked — the host claims
it at the turn START — so its splice→claim transient stays hidden even
after the send path lights the optimistic spinner; keying this on the
live spinner instead painted the row and cleared it within milliseconds
(the `C-c C-c' flash).
Connection seeds do NOT clear it: on a fresh open the submit's own
splice-in frame is the seed, and the claim leg that must stay silent
follows it.  Set by `dsh-emacs-queue--mark-submit-suppress' (called
from the submit paths), buffer-local per chat.")

(defvar-local dsh-emacs-queue--submit-suppress-timer nil
  "Defensive disarm timer for `dsh-emacs--queue-submit-suppress'.
Clears the flag when no settling frame arrives at all — a dead
transport or an RPC that never fails visibly — so the echo gate does
not stay stuck until the next submit.  The claim frame normally clears
the flag within milliseconds, so this is pure transport hygiene: its
value carries no user-visible timing (the parked preview is revealed by
`dsh-emacs-queue--submit-parked-p', not by this timer).")

(defvar-local dsh-emacs-queue--submit-parked-p nil
  "Whether the submit behind `dsh-emacs--queue-submit-suppress' is parked.
Non-nil when that submit was made while a turn was ALREADY running, so
the host can only claim it at the turn end: it is genuinely parked and
its Next Message preview must show at once, even while the suppression
flag is up.  An IDLE submit is not parked — the host claims it at the
turn START — and its splice→claim transient must stay invisible even
after the send path lights the optimistic spinner.  Set alongside
`dsh-emacs--queue-submit-suppress' (see
`dsh-emacs-queue--mark-submit-suppress'), cleared with it.")

(defvar-local dsh-emacs-queue--submit-seen-p nil
  "Whether the suppressed submit's own item has reached the mirror.
`dsh-emacs-queue-apply' sets it when an item arrives while
`dsh-emacs--queue-submit-suppress' is up.  Only AFTER that does an empty
frame mean \"the item was claimed\" and disarm the suppression: a fresh
session's mirror is seeded by the connection's first frame, which can be
empty and land between the arm and the splice, and treating that seed as
the claim disarmed the gate early — the row then painted the very next
frame (the `C-c C-c' flash in a new session).  The hygiene timer still
bounds a submit whose item never reaches the mirror.")

(defvar-local dsh-emacs-queue--optimistic-submit nil
  "Locally submitted message not yet reflected in the host queue mirror.
A `dsh-protocol-queue-item' shown as the Next Message preview from the
moment the user queues it until the host's own `inbox' projection frame lands,
so the row appears with the keystroke instead of one HTTP round trip later.
nil when no local queued submit is in flight.")

(defun dsh-emacs-queue--optimistic-submit-show (text)
  "Preview a just-submitted TEXT as the pending next message.
Call in the chat buffer on the busy submit path (after
`dsh-emacs-queue--mark-submit-suppress'): the queued message is real but its
host `inbox' projection frame is still a round trip away, so the local preview
keeps the send from feeling sticky.  The host's confirming frame, the submit
failure branch, or the hygiene timer clears it."
  (when (and text (not (string-empty-p text)))
    (setq dsh-emacs-queue--optimistic-submit
          (make-dsh-protocol-queue-item
           :id (format "local-%s" (float-time))
           :placement 'queued
           :text text
           :kind "user"))
    (dsh-emacs-queue--refresh-ui)))

(defun dsh-emacs-queue--optimistic-submit-clear ()
  "Drop the optimistic Next Message preview (painting is the caller's job)."
  (setq dsh-emacs-queue--optimistic-submit nil))

(defun dsh-emacs-queue--submit-suppress-clear ()
  "Clear the submit-suppression flag and its timer (idempotent).
Repaints once afterwards so the preview reflects the flag change
immediately instead of waiting for the next queue frame."
  (when (timerp dsh-emacs-queue--submit-suppress-timer)
    (cancel-timer dsh-emacs-queue--submit-suppress-timer))
  (setq dsh-emacs-queue--submit-suppress-timer nil)
  (setq dsh-emacs--queue-submit-suppress nil)
  (setq dsh-emacs-queue--submit-parked-p nil)
  (setq dsh-emacs-queue--submit-seen-p nil)
  (dsh-emacs-queue--optimistic-submit-clear)
  (dsh-emacs-queue--schedule-paint))

(defun dsh-emacs-queue--mark-submit-suppress ()
  "Silence the queue echoes for the submit about to be sent.
Call in the chat buffer just before submitting while the mirror is
empty (see `dsh-emacs--queue-submit-suppress'): the host will splice
the message into the inbox — behind a running turn, or straight into
the next one — and claim it again at the turn start, and neither
transition deserves a `queued:' / `running:' flash; the message itself
is rendered directly by the submit path.  With items already parked the
flashes are genuine (ordering information) and stay."
  (dsh-emacs-queue--submit-suppress-clear)
  (setq dsh-emacs--queue-submit-suppress t)
  ;; Capture whether this submit is genuinely parked NOW: a turn already
  ;; running means the host can only claim the item at the turn end, so its
  ;; preview must show at once.  An idle submit must NOT be revealed just
  ;; because the send path lights the optimistic spinner while the claim
  ;; frame is still in flight — that is the `C-c C-c' flash (see
  ;; `dsh-emacs-queue--submit-parked-p').
  (setq dsh-emacs-queue--submit-parked-p (dsh-emacs--busy-p))
  (let ((buf (current-buffer)))
    ;; Transport hygiene only: a dead transport would otherwise leave the
    ;; echo gate stuck until the next submit.  The parked preview is NOT
    ;; revealed by this timer — `dsh-emacs-queue--submit-parked-p' gates
    ;; the preview independently (see `dsh-emacs--queue-submit-suppress'),
    ;; so the value only bounds the one remaining corner: an interrupted
    ;; turn keeps its parked items while busy drops, and the preview there
    ;; returns when this fires (2s, as before the parked gate).
    (setq dsh-emacs-queue--submit-suppress-timer
          (run-at-time 2 nil
                       (lambda ()
                         (when (buffer-live-p buf)
                           (with-current-buffer buf
                             (dsh-emacs-queue--submit-suppress-clear))))))))

(defvar-local dsh-emacs-queue--paint-timer nil
  "Pending zero-delay timer that repaints Composer.
Queue frames arrive in bursts — the host often splices an item in and
claims it again within milliseconds, and painting each frame would
flash the Next Message row.  One repaint per burst, from the settled
mirror, keeps such transient states invisible.")

(defun dsh-emacs-queue-items ()
  "Return this session's pending items (raw mirror, may be nil)."
  dsh-emacs--queue-items)

(defun dsh-emacs-queue--counts-of (items)
  "Return (QUEUED . STEERING) counts of ITEMS, ignoring `context' entries."
  (let ((q 0) (s 0))
    (dolist (item items)
      (pcase (dsh-protocol-queue-item-placement item)
        ('queued (setq q (1+ q)))
        ('steering (setq s (1+ s)))))
    (cons q s)))

(defun dsh-emacs-queue-counts ()
  "Return (QUEUED . STEERING) pending counts for the current buffer."
  (dsh-emacs-queue--counts-of dsh-emacs--queue-items))

(defun dsh-emacs-queue-preview (text)
  "Return TEXT as a one-line preview (first line, at most 40 chars)."
  (let ((line (car (split-string (or text "") "\n"))))
    (if (> (length line) 40)
        (concat (substring line 0 37) "...")
      line)))

;;; ---------------------------------------------------------------------------
;;; Frame application + feedback (echo area)
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-queue--find-id (items id)
  "Return the item of ITEMS whose id is ID, or nil."
  (cl-find id items :test #'string= :key #'dsh-protocol-queue-item-id))

(defun dsh-emacs-queue--diff-events (old new deleted)
  "Return the feedback implied by mirror transition OLD → NEW.
DELETED lists locally-deleted ids whose disappearance is a confirmed
delete, not a consumption.  Each event is (KIND . TEXT) with KIND one
of `running', `steering' or `queued'; TEXT is a display preview."
  (let ((events '()))
    ;; Consumption: the id vanished from the mirror and is not a local
    ;; delete (claimed by the next turn/step).
    (dolist (item old)
      (let ((id (dsh-protocol-queue-item-id item)))
        (when (and id
                   (not (member id deleted))
                   (null (dsh-emacs-queue--find-id new id)))
          (push (cons 'running
                      (dsh-emacs-queue-preview
                       (dsh-protocol-queue-item-text item)))
                events))))
    ;; Steering: a newly appearing next-step item, or one promoted from
    ;; queued (a queue-jump started here or by the other dsh web client is
    ;; announced this way).
    (dolist (item new)
      (let* ((id (dsh-protocol-queue-item-id item))
             (prev (and id (dsh-emacs-queue--find-id old id))))
        (when (and (eq (dsh-protocol-queue-item-placement item) 'steering)
                   (or (null prev)
                       (not (eq (dsh-protocol-queue-item-placement prev)
                                'steering))))
          (push (cons 'steering
                      (dsh-emacs-queue-preview
                       (dsh-protocol-queue-item-text item)))
                events))))
    ;; Queued: a newly appearing next-turn item (parked here or by
    ;; another client).
    (dolist (item new)
      (let ((id (dsh-protocol-queue-item-id item)))
        (when (and (eq (dsh-protocol-queue-item-placement item) 'queued)
                   id
                   (null (dsh-emacs-queue--find-id old id)))
          (push (cons 'queued
                      (dsh-emacs-queue-preview
                       (dsh-protocol-queue-item-text item)))
                events))))
    (nreverse events)))

(defun dsh-emacs-queue--flash (format &rest args)
  "Show FORMAT/ARGS in the echo area and auto-dismiss it after ~2s.
The clear is guarded: a message is only withdrawn while it is still the
current one and no minibuffer session is active."
  (let ((text (apply #'format format args)))
    (message "%s" text)
    (run-with-timer 2 nil
                    (lambda ()
                      (unless (active-minibuffer-window)
                        (when (equal (current-message) text)
                          (message nil)))))))

(defun dsh-emacs-queue--announce (events)
  "Flash the echo-area feedback for EVENTS."
  (dolist (event events)
    (pcase (car event)
      ('running (dsh-emacs-queue--flash "running: %s" (cdr event)))
      ('steering (dsh-emacs-queue--flash "steering: %s" (cdr event)))
      ('queued (dsh-emacs-queue--flash "queued: %s" (cdr event))))))

(defun dsh-emacs-queue-apply (chat process items)
  "Replace CHAT's pending-input mirror with ITEMS arriving on PROCESS.
ITEMS is the `dsh-protocol-queue-item' list derived from the session's
`inbox' projection (`dsh-protocol-queue-items-from-inbox') — the events
dispatcher resolves CHAT by session id and retains the latest cell on the
core connection for closed chats.  The first frame of a connection is a snapshot
and seeds the mirror silently; later frames diff against the mirror to
emit the enqueue / steer / consumption feedback.

While `dsh-emacs--queue-submit-suppress' is set no feedback is emitted:
the frames are the append+claim transient of a prompt the client itself
just submitted with an empty queue (see
`dsh-emacs-queue--mark-submit-suppress') — the mirrored items still
update, and the flag clears when the mirror settles back to empty or by
its timeout."
  (when (buffer-live-p chat)
    (with-current-buffer chat
      (let ((seed (not (eq process dsh-emacs--queue-process))))
        (setq dsh-emacs--queue-process process)
        (unless (or seed dsh-emacs--queue-submit-suppress)
          (dsh-emacs-queue--announce
           (dsh-emacs-queue--diff-events dsh-emacs--queue-items
                                         items
                                         dsh-emacs--queue-deleted)))
        (setq dsh-emacs--queue-items items)
        ;; The host has now spoken about the queue: its frame carries the
        ;; optimistic submit's own item (or the items ahead of it), so the
        ;; local preview is no longer the source of truth.
        (when items
          (dsh-emacs-queue--optimistic-submit-clear))
        ;; A suppressed submit ends at its CLAIM: the empty frame that
        ;; follows its own splice.  Record that the splice was seen first —
        ;; a fresh session's mirror is seeded by the connection's first
        ;; frame, which can be empty and arrive between the arm and the
        ;; splice; taking that baseline for the claim disarmed the gate
        ;; before the splice landed, so the row then painted our own message
        ;; (the `C-c C-c' flash in a new session).  Seeding still does not
        ;; re-arm the announcements, and the hygiene timer bounds a submit
        ;; whose item never reaches the mirror.
        (when (and dsh-emacs--queue-submit-suppress items)
          (setq dsh-emacs-queue--submit-seen-p t))
        (when (and dsh-emacs--queue-submit-suppress
                   dsh-emacs-queue--submit-seen-p
                   (null items))
          (dsh-emacs-queue--submit-suppress-clear))
        ;; The delete is confirmed by the server (the item is gone): clear the
        ;; suppression mark so it does not swallow the feedback of a later
        ;; real consumption.
        (setq dsh-emacs--queue-deleted
              (cl-remove-if-not
               (lambda (id)
                 (dsh-emacs-queue--find-id items id))
               dsh-emacs--queue-deleted))
        (dsh-emacs-queue--schedule-paint)))))

;;; ---------------------------------------------------------------------------
;;; Next-message selection / visibility and coalesced UI refresh
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-queue-next-item ()
  "Return the next pending message to display in this buffer, or nil.
Steering (next-step) precedes queued (next-turn); context entries are never
previewed.  Suppress the client's transient self-submit — unless that submit
was already parked behind a running turn, which must show at once (see
`dsh-emacs-queue--submit-parked-p').  When the mirror does not offer an item
yet, fall back to the local optimistic queued submit so the preview appears
with the keystroke rather than one round trip later.  The raw mirror is
unchanged."
  (or (when (or (null dsh-emacs--queue-submit-suppress)
                dsh-emacs-queue--submit-parked-p)
        (or (cl-find 'steering dsh-emacs--queue-items
                     :key #'dsh-protocol-queue-item-placement)
            (cl-find 'queued dsh-emacs--queue-items
                     :key #'dsh-protocol-queue-item-placement)))
      dsh-emacs-queue--optimistic-submit))

(defun dsh-emacs-queue--paint-after-burst ()
  "Repaint Composer from the settled queue mirror."
  (setq dsh-emacs-queue--paint-timer nil)
  (dsh-emacs-composer-render))

(defun dsh-emacs-queue--schedule-paint ()
  "Schedule one Composer repaint for the current frame burst.
Further frames arriving before the timer fires (same burst) are folded
into the same repaint — see `dsh-emacs-queue--paint-timer'."
  (unless dsh-emacs-queue--paint-timer
    (let ((buf (current-buffer)))
      (setq dsh-emacs-queue--paint-timer
            (run-at-time
             0 nil
             (lambda ()
               (when (buffer-live-p buf)
                 (with-current-buffer buf
                   (dsh-emacs-queue--paint-after-burst)))))))))

(defun dsh-emacs-queue--refresh-ui ()
  "Recompute Composer rows from the queue mirror.
Optimistic path (steer/delete/edit RPC success): paint right away and
drop any pending burst repaint, so our own actions stay instantaneous."
  (when (timerp dsh-emacs-queue--paint-timer)
    (cancel-timer dsh-emacs-queue--paint-timer))
  (setq dsh-emacs-queue--paint-timer nil)
  (dsh-emacs-queue--paint-after-burst))

;;; ---------------------------------------------------------------------------
;;; RPC: session/updateQueue (edit / remove / steer)
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-queue--session-id ()
  "Return the session id this queue manages, or error when none is open."
  (or (dsh-emacs--active-session-id)
      (user-error "No session is open")))

(defun dsh-emacs-queue--update (item-id action &optional on-error on-success)
  "Send one `session/updateQueue' call for ITEM-ID with ACTION.
ACTION is the wire action alist (e.g. ((kind . \"remove\"))).  ON-ERROR
runs in the chat buffer when the call fails; ON-SUCCESS when it
succeeds — both with the chat buffer current.  The mirror is normally
confirmed by the following `session/control' `inbox' projection frame;
ON-SUCCESS is where this client applies our own actions OPTIMISTICALLY,
so steer / delete / edit update the next-preview hint
the instant the RPC succeeds, without waiting for the frame round-trip."

  (dsh-emacs-subagent-require 'mutate)
  (let ((session-id (dsh-emacs-queue--session-id))
        (buf (current-buffer)))
    (dsh-emacs--rpc-async
     "session/updateQueue"
     (dsh-protocol-session-update-queue-request session-id item-id action)
     (lambda (ok value)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (if ok
               (when on-success (funcall on-success value))
             (when on-error (funcall on-error value))
             (message "Queue update failed: %s"
                      (dsh-emacs-rpc-error-text value)))))))))

(defun dsh-emacs-queue--delete (item)
  "Delete ITEM via `session/updateQueue' (kind remove)."
  (let ((id (dsh-protocol-queue-item-id item)))
    (push id dsh-emacs--queue-deleted)
    (dsh-emacs-queue--update
     id (dsh-protocol-queue-remove-action)
     (lambda (_value)
       ;; Delete failed: the item is still queued, so restore the
       ;; consumption-feedback semantics.
       (setq dsh-emacs--queue-deleted
             (delete id dsh-emacs--queue-deleted)))
     (lambda (_value)
       ;; Delete succeeded: remove optimistically (the confirming frame
       ;; repaints the whole mirror) + input-line flash.
       (setq dsh-emacs--queue-items
             (cl-remove-if (lambda (it)
                             (equal id (dsh-protocol-queue-item-id it)))
                           dsh-emacs--queue-items))
       (dsh-emacs-queue--refresh-ui)))))

(defun dsh-emacs-queue--steer (item)
  "Promote queued ITEM into the running turn (kind steer).
On success the mirror is updated optimistically (placement → steering)
and the hint recomputed, so the promotion is visible before the
confirming `inbox' projection frames arrive.  The id joins the
deleted-suppression list so the transient removal frame is never
announced as a consumption (`running'); the `steering' feedback still
rides the re-insertion frame's diff (the mirror is cleared in between)."
  (let ((id (dsh-protocol-queue-item-id item)))
    (dsh-emacs-queue--update
     id (dsh-protocol-queue-steer-action)
     nil
     (lambda (_value)
       (push id dsh-emacs--queue-deleted)
       (setq dsh-emacs--queue-items
             (mapcar (lambda (it)
                       (if (equal id (dsh-protocol-queue-item-id it))
                           (progn
                             (setf (dsh-protocol-queue-item-placement it)
                                   'steering)
                             it)
                         it))
                     dsh-emacs--queue-items))
       (dsh-emacs-queue--refresh-ui)))))

(defun dsh-emacs-queue--edit (item new-text)
  "Replace ITEM's text with NEW-TEXT (kind edit, text blocks only).
On success the mirror is updated optimistically so the hint shows the
edited preview at once; the confirming frame overwrites the mirror."
  (let ((id (dsh-protocol-queue-item-id item)))
    (dsh-emacs-queue--update
     id
     (dsh-protocol-queue-edit-action new-text)
     nil
     (lambda (_value)
       (dolist (it dsh-emacs--queue-items)
         (when (equal id (dsh-protocol-queue-item-id it))
           (setf (dsh-protocol-queue-item-text it) new-text)))
       (dsh-emacs-queue--refresh-ui)))))

;;; ---------------------------------------------------------------------------
;;; Management UI: C-c C-q (completing-read, Vertico/Ivy/Helm compatible)
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-queue--send-now (item)
  "Send ITEM right away.
While a turn is running this steers it into the running turn (jump the
queue).  While idle there is no wake-only RPC: the item is deleted and
submitted as a literal prompt, which wakes the driver — the parked queue
drains in order and the submitted copy re-joins at the tail with its text
preserved.  The text never re-enters the composer's input parsing, so a
queued \"!\" or \"/name\" line stays an ordinary message (no local shell,
no `commands.execute') and the unrelated draft in the input area is left
untouched.  Reject non-text items while idle, before removing anything: the
text-only submit cannot preserve their attachments.  Subagent queues are
read-only, so a child conversation rejects here before any removal too."
  (dsh-emacs-subagent-require 'mutate)
  (cond
   ((eq (dsh-protocol-queue-item-placement item) 'steering)
    (message "Already steering"))
   ((dsh-emacs--busy-p)
    (dsh-emacs-queue--steer item))
   ((not (dsh-protocol-queue-item-text-only item))
    (user-error "Cannot send queued attachments while idle"))
   (t
    (let* ((text (dsh-protocol-queue-item-text item))
           (id (dsh-protocol-queue-item-id item))
           (session-id (dsh-emacs-queue--session-id))
           (buf (current-buffer)))
      (push id dsh-emacs--queue-deleted) ; delete on send, not a consumption
      (dsh-emacs--rpc-async
       "session/updateQueue"
       (dsh-protocol-session-update-queue-request
        session-id id (dsh-protocol-queue-remove-action))
       (lambda (ok value)
         (when (buffer-live-p buf)
           (with-current-buffer buf
             (if ok
                 (progn
                   ;; Optimistic removal + input-line flash, then submit
                   ;; the item's text as a literal message (never resent).
                   (setq dsh-emacs--queue-items
                         (cl-remove-if
                          (lambda (it)
                            (equal id (dsh-protocol-queue-item-id it)))
                          dsh-emacs--queue-items))
                   (dsh-emacs-queue--refresh-ui)
                   (dsh-emacs--submit-plain text :input-consumed t))
               (progn
                 (setq dsh-emacs--queue-deleted
                       (delete id dsh-emacs--queue-deleted))
                 (message "Queue update failed: %s"
                          (dsh-emacs-rpc-error-text value))))))))))))

(defun dsh-emacs-queue--label (item)
  "Return the queue-menu label for ITEM, e.g. \"[Q] fix the bug\"."
  (format "[%c] %s"
          (if (eq (dsh-protocol-queue-item-placement item) 'steering)
              ?S ?Q)
          (dsh-emacs-queue-preview (dsh-protocol-queue-item-text item))))

(defun dsh-emacs-queue--delete-all (items)
  "Delete every queue ITEM after confirmation."
  (when (y-or-n-p (format "Delete all %d pending item%s? "
                          (length items)
                          (if (= (length items) 1) "" "s")))
    (dolist (item items)
      (dsh-emacs-queue--delete item))))

(defun dsh-emacs-queue--edit-item (item)
  "Read new text for ITEM and apply it when it is not blank.
Refuse a non-text item: the edit RPC replaces its content with one text
block, which would drop its attachments."
  (unless (dsh-protocol-queue-item-text-only item)
    (user-error "Cannot edit queued attachments"))
  (let ((text (read-string "Edit queued message: "
                           (dsh-protocol-queue-item-text item))))
    (unless (string-empty-p (string-trim text))
      (dsh-emacs-queue--edit item text))))

(cl-defun dsh-emacs-list-queue ()
  "Manage this session's pending queue in one completion list.
RET or C-c s sends the selected entry now, steering a running turn or
waking the idle queue drain.  C-c e edits it, C-c d deletes it, and
C-c x deletes the whole queue after confirmation.  Ordinary letters
filter the list; C-g cancels.  Host-injected `context' items are hidden."
  (interactive)
  (when (bound-and-true-p dsh-emacs--buffer-subagent)
    (with-help-window "*DSH Subagent Queue*"
      (princ "Subagent queue (read-only)\n\n")
      (dolist (item (dsh-emacs-queue-items))
        (princ (concat (dsh-protocol-queue-item-text item) "\n"))))
    (cl-return-from dsh-emacs-list-queue))
  (dsh-emacs-queue--session-id)
  (condition-case nil
      (let ((items (cl-remove-if
                    (lambda (item)
                      (eq (dsh-protocol-queue-item-placement item) 'context))
                    dsh-emacs--queue-items)))
        (when (null items)
          (user-error "Queue is empty"))
        (pcase-let ((`(,action ,item)
                     (dsh-emacs-ui-menu-read
                      (format "Queue Q%d S%d (RET or C-c s send; C-c e/d/x): "
                              (car (dsh-emacs-queue-counts))
                              (cdr (dsh-emacs-queue-counts)))
                      (dsh-emacs-ui-menu-entries items
                                                 #'dsh-emacs-queue--label)
                      'send
                      '(("C-c s" send) ("C-c e" edit)
                        ("C-c d" delete) ("C-c x" delete-all t)))))
          (pcase action
            ('send (dsh-emacs-queue--send-now item))
            ('edit (dsh-emacs-queue--edit-item item))
            ('delete (dsh-emacs-queue--delete item))
            ('delete-all (dsh-emacs-queue--delete-all items))
            (_ (user-error "Unknown queue menu action: %s" action)))))
    (quit (message "Queue manager cancelled"))))

(provide 'dsh-emacs-queue)

;;; dsh-emacs-queue.el ends here
