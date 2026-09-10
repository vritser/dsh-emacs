;;; dsh-emacs-queue.el --- Pending-input queue (queue/steer) for dsh-emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2025 vritser

;; Author: vritser
;; Version: 0.3.0
;; License: GPL-3.0-or-later
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; Client-side mirror of the dsh agent inbox: input sent while a turn is
;; running either queues as the next turn (`session/prompt' mode "queue")
;; or steers the running agent before its next step (mode "steer").  The
;; host publishes the authoritative snapshot as `session/queue' frames on
;; the core connection's `session/control' logical stream (a baseline once
;; per connection, then on every inbox splice), so this module only mirrors
;; frames — there is no fetch RPC and no local bookkeeping that could drift.

;; Emacs-native interaction (no panels, no overlays):
;;   - mode line shows `[Q2 S1]' while items are pending (`context'
;;     placement items — host-injected next-step content — are not counted,
;;     matching dsh web's QueueDock);
;;   - the echo area flashes transient feedback on enqueue / steer /
;;     consumption, derived from the frame diff;
;;   - `dsh-emacs-list-queue' (C-c C-q) opens the queue as a minibuffer
;;     candidate list and applies single keys to the CURRENTLY highlighted
;;     entry (vertico up/down picks the item — no numbering): e = edit,
;;     s = steer, d = delete, RET = send now, x = delete the whole queue;
;;   - Composer displays the next visible pending item on its own read-only
;;     row above the input; this module owns selection and transient gating.

;;; Code:

(require 'cl-lib)
(require 'dsh-emacs-protocol)

;; 同包模块的惰性边界（见 AGENTS.md）：dsh-emacs.el 装配本模块，运行时
;; 反向调用其符号走 declare-function，避免顶层 require 环。
(declare-function dsh-emacs--active-session-id "dsh-emacs" ())
(declare-function dsh-emacs--busy-p "dsh-emacs" ())
(declare-function dsh-emacs--replace-input "dsh-emacs" (text))
(declare-function dsh-emacs--rpc-async "dsh-emacs" (method params callback))
(declare-function dsh-emacs--submit-prompt "dsh-emacs" (message &optional images mode))
(declare-function dsh-emacs-composer-render "dsh-emacs-composer" ())

(defvar dsh-emacs--buffer-session)
;; Borrowed vertico runtime variables (see `dsh-emacs-queue--menu-item'):
;; declare-only so the byte-compiler stays quiet — always read under `boundp'.
(defvar vertico--index)
(defvar vertico--candidates)

;;; ---------------------------------------------------------------------------
;;; 状态镜像（buffer-local，随 mux 帧全量更新）
;;; ---------------------------------------------------------------------------

(defvar-local dsh-emacs--queue-items nil
  "Pending inbox items of this chat's session, in delivery order.
List of `dsh-protocol-queue-item'; replaced wholesale by every
`session/queue' frame (the host snapshot is authoritative).")

(defvar-local dsh-emacs--queue-process nil
  "The mux process the current mirror was seeded from.
A frame from a different process means a fresh connection whose first
`session/queue' frame is the connect-time snapshot: apply it silently,
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
appends it (a `session/queue' frame with the item) and claims it again
at the turn start (a frame without it) within milliseconds.  Diffing
that pair flashes `queued:' then `running:' — the flash on sending a new
message — though nothing was ever really parked: the submit path renders
the user message directly.  While this flag is set, `dsh-emacs-queue-apply'
updates the mirror but emits no feedback — it clears when the mirror
settles back to empty (the claim frame), in the submit failure branch,
or via `dsh-emacs-queue--submit-suppress-timer' (transport-safety only:
un-sticks the echo gate when neither a settle frame nor an RPC failure
ever arrives; it paces NO preview).  The Next Message preview is gated
by this flag too — with one event-driven exception: while a turn is
RUNNING (`dsh-emacs--busy-p') the preview shows regardless, because an
item mirrored then can only be claimed at the turn end and is genuinely
parked — that is how a queued message surfaces without any timing hack.
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
`dsh-emacs--busy-p', not by this timer).")

(defun dsh-emacs-queue--submit-suppress-clear ()
  "Clear the submit-suppression flag and its timer (idempotent).
Repaints once afterwards so the preview reflects the flag change
immediately instead of waiting for the next queue frame."
  (when (timerp dsh-emacs-queue--submit-suppress-timer)
    (cancel-timer dsh-emacs-queue--submit-suppress-timer))
  (setq dsh-emacs-queue--submit-suppress-timer nil)
  (setq dsh-emacs--queue-submit-suppress nil)
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
  (let ((buf (current-buffer)))
    ;; Transport hygiene only: a dead transport would otherwise leave the
    ;; echo gate stuck until the next submit.  The parked preview is NOT
    ;; revealed by this timer — `dsh-emacs--busy-p' gates the preview
    ;; independently (see `dsh-emacs--queue-submit-suppress'), so the
    ;; value only bounds the one remaining corner: an interrupted turn
    ;; keeps its parked items while busy drops, and the preview there
    ;; returns when this fires (2s, as before the busy-gate).
    (setq dsh-emacs-queue--submit-suppress-timer
          (run-at-time 2 nil
                       (lambda ()
                         (when (buffer-live-p buf)
                           (with-current-buffer buf
                             (dsh-emacs-queue--submit-suppress-clear))))))))

(defvar-local dsh-emacs-queue--paint-timer nil
  "Pending zero-delay timer that repaints Composer and the mode-line.
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
;;; 帧应用 + 反馈（echo area）
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
    ;; 消费：id 从镜像中消失且不是本端删除（下一轮/下一步领取）。
    (dolist (item old)
      (let ((id (dsh-protocol-queue-item-id item)))
        (when (and id
                   (not (member id deleted))
                   (null (dsh-emacs-queue--find-id new id)))
          (push (cons 'running
                      (dsh-emacs-queue-preview
                       (dsh-protocol-queue-item-text item)))
                events))))
    ;; steering：新出现的 next-step 项，或从 queued 提升的项（本端或
    ;; dsh web 另一端发起的 插队 都由此反馈）。
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
    ;; queued：新出现的 next-turn 项（本端或另一端排队）。
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

(defun dsh-emacs-queue-apply (chat process payload)
  "Apply a `session/queue' frame PAYLOAD for CHAT arriving on PROCESS.
The first frame of a connection is the connect-time snapshot and seeds
the mirror silently; later frames diff against the mirror to emit the
enqueue / steer / consumption feedback.  Payloads for other sessions
are filtered out by the events dispatcher.

While `dsh-emacs--queue-submit-suppress' is set no feedback is emitted:
the frames are the append+claim transient of a prompt the client itself
just submitted with an empty queue (see `dsh-emacs-queue--mark-submit-suppress') —
the mirrored items still update, and the flag clears when the mirror
settles back to empty or by its timeout."
  (when (buffer-live-p chat)
    (with-current-buffer chat
      (let* ((items (dsh-protocol-queue-items-from-alist payload))
             (seed (not (eq process dsh-emacs--queue-process))))
        (setq dsh-emacs--queue-process process)
        (unless (or seed dsh-emacs--queue-submit-suppress)
          (dsh-emacs-queue--announce
           (dsh-emacs-queue--diff-events dsh-emacs--queue-items
                                         items
                                         dsh-emacs--queue-deleted)))
        (setq dsh-emacs--queue-items items)
        ;; The claim frame of a submit transient: the mirror is empty
        ;; again, the transient is over — re-arm the announcements.  Seeding
        ;; (a connection's first frame) does NOT re-arm: on a fresh open the
        ;; submit's own splice-in frame IS the seed, and the claim leg that
        ;; must stay silent follows it.
        (when (and dsh-emacs--queue-submit-suppress (null items))
          (dsh-emacs-queue--submit-suppress-clear))
        ;; 删除已被服务器确认（项已消失）：清掉抑制标记，避免吞掉后续
        ;; 真实消费的反馈。
        (setq dsh-emacs--queue-deleted
              (cl-remove-if-not
               (lambda (id)
                 (dsh-emacs-queue--find-id items id))
               dsh-emacs--queue-deleted))
        (dsh-emacs-queue--schedule-paint)))))

;;; ---------------------------------------------------------------------------
;;; 下一条消息的选择 / 可见性，以及 UI 合并刷新
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-queue-next-item ()
  "Return the next pending message to display in this buffer, or nil.
Steering (next-step) precedes queued (next-turn); context entries are never
previewed.  Suppress the client's transient self-submit while idle, but show
parked input immediately while a turn runs.  The raw mirror is unchanged."
  (when (or (null dsh-emacs--queue-submit-suppress) (dsh-emacs--busy-p))
    (or (cl-find 'steering dsh-emacs--queue-items
                 :key #'dsh-protocol-queue-item-placement)
        (cl-find 'queued dsh-emacs--queue-items
                 :key #'dsh-protocol-queue-item-placement))))

(defun dsh-emacs-queue--paint-after-burst ()
  "Repaint Composer and mode-line from the settled queue mirror."
  (setq dsh-emacs-queue--paint-timer nil)
  (dsh-emacs-composer-render)
  (force-mode-line-update))

(defun dsh-emacs-queue--schedule-paint ()
  "Schedule one Composer/mode-line repaint for the current frame burst.
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
  "Recompute Composer rows and the mode-line counts.
Optimistic path (steer/delete/edit RPC success): paint right away and
drop any pending burst repaint, so our own actions stay instantaneous."
  (when (timerp dsh-emacs-queue--paint-timer)
    (cancel-timer dsh-emacs-queue--paint-timer))
  (setq dsh-emacs-queue--paint-timer nil)
  (dsh-emacs-queue--paint-after-burst))

;;; ---------------------------------------------------------------------------
;;; RPC：session/updateQueue（edit / remove / steer）
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
confirmed by the following `session/control' `queue' frame; ON-SUCCESS
is where this client applies our own actions OPTIMISTICALLY, so steer /
delete / edit update the next-preview hint and the mode-line the instant
the RPC succeeds, without waiting for the frame round-trip."
  (let ((session-id (dsh-emacs-queue--session-id))
        (buf (current-buffer)))
    (dsh-emacs--rpc-async
     "session/updateQueue"
     `((request . ((sessionId . ,session-id)
                   (itemId . ,item-id)
                   (action . ,action))))
     (lambda (ok value)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (if ok
               (when on-success (funcall on-success value))
             (when on-error (funcall on-error value))
             (message "Queue update failed: %S" value))))))))

(defun dsh-emacs-queue--delete (item)
  "Delete ITEM via `session/updateQueue' (kind remove)."
  (let ((id (dsh-protocol-queue-item-id item)))
    (push id dsh-emacs--queue-deleted)
    (dsh-emacs-queue--update
     id '((kind . "remove"))
     (lambda (_value)
       ;; 删除失败：项仍在队列里，恢复消费反馈的口径。
       (setq dsh-emacs--queue-deleted
             (delete id dsh-emacs--queue-deleted)))
     (lambda (_value)
       ;; 删除成功：乐观移除（确认帧随后全量覆盖镜像）+ 输入行闪现。
       (setq dsh-emacs--queue-items
             (cl-remove-if (lambda (it)
                             (equal id (dsh-protocol-queue-item-id it)))
                           dsh-emacs--queue-items))
       (dsh-emacs-queue--refresh-ui)))))

(defun dsh-emacs-queue--steer (item)
  "Promote queued ITEM into the running turn (kind steer).
On success the mirror is updated optimistically (placement → steering)
and the hint recomputed, so the promotion is visible before the
confirming `session/queue' frames arrive.  The id joins the
deleted-suppression list so the transient removal frame is never
announced as a consumption (`running'); the `steering' feedback still
rides the re-insertion frame's diff (the mirror is cleared in between)."
  (let ((id (dsh-protocol-queue-item-id item)))
    (dsh-emacs-queue--update
     id '((kind . "steer"))
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
     `((kind . "edit")
       (content . ,(vector (list (cons 'type "text")
                                 (cons 'text new-text)))))
     nil
     (lambda (_value)
       (dolist (it dsh-emacs--queue-items)
         (when (equal id (dsh-protocol-queue-item-id it))
           (setf (dsh-protocol-queue-item-text it) new-text)))
       (dsh-emacs-queue--refresh-ui)))))

;;; ---------------------------------------------------------------------------
;;; 管理界面：C-c C-q（completing-read，Vertico/Ivy/Helm 兼容）
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-queue--send-now (item)
  "Send ITEM right away.
While a turn is running this steers it into the running turn (jump the
queue).  While idle there is no wake-only RPC: the item is deleted and
re-submitted as an ordinary prompt, which wakes the driver — the parked
queue drains in order and the re-submitted copy re-joins at the tail
with its text preserved."
  (if (eq (dsh-protocol-queue-item-placement item) 'steering)
      (message "Already steering")
    (if (dsh-emacs--busy-p)
        (dsh-emacs-queue--steer item)
      (let* ((text (dsh-protocol-queue-item-text item))
             (id (dsh-protocol-queue-item-id item))
             (session-id (dsh-emacs-queue--session-id))
             (buf (current-buffer)))
        (push id dsh-emacs--queue-deleted) ; 发送即删除：确认帧不当作消费
        (dsh-emacs--rpc-async
         "session/updateQueue"
         `((request . ((sessionId . ,session-id)
                       (itemId . ,id)
                       (action . ((kind . "remove"))))))
         (lambda (ok value)
           (when (buffer-live-p buf)
             (with-current-buffer buf
               (if ok
                   (progn
                     ;; 乐观移除 + 输入行闪现，再重提交（失败绝不重发）。
                     (setq dsh-emacs--queue-items
                           (cl-remove-if
                            (lambda (it)
                              (equal id (dsh-protocol-queue-item-id it)))
                            dsh-emacs--queue-items))
                     (dsh-emacs-queue--refresh-ui)
                     (dsh-emacs--submit-prompt text))
                 (progn
                   (setq dsh-emacs--queue-deleted
                         (delete id dsh-emacs--queue-deleted))
                   (message "Queue update failed: %S" value)))))))))))

(defun dsh-emacs-queue--label (item)
  "Return the queue-menu label for ITEM, e.g. \"[Q] fix the bug\"."
  (format "[%c] %s"
          (if (eq (dsh-protocol-queue-item-placement item) 'steering)
              ?S ?Q)
          (dsh-emacs-queue-preview (dsh-protocol-queue-item-text item))))

(defun dsh-emacs-queue--table (items)
  "Return ((LABEL . ITEM) ...) for ITEMS with unique LABELs:
items whose preview text collides get a \"[N]\" suffix, so each label
maps back to exactly one item however the minibuffer picked it."
  (let ((seen (make-hash-table :test 'equal)))
    (mapcar (lambda (item)
              (let* ((base (dsh-emacs-queue--label item))
                     (n (1+ (gethash base seen 0))))
                (puthash base n seen)
                (cons (if (= n 1) base
                        (format "%s [%d]" base n))
                      item)))
            items)))

(defvar dsh-emacs--queue-pick-table nil
  "((LABEL . ITEM) ...): the queue entries of the open queue menu.
A DYNAMIC binding set by `dsh-emacs-list-queue' around the
`completing-read'; the single-key menu commands resolve the entry they
act on through this table — the same pattern as
`dsh-emacs--question-pick-labels'.")

(defun dsh-emacs-queue--menu-item ()
  "The ITEM the next menu key acts on: the vertico-highlighted
candidate when vertico renders the list; else the minibuffer's typed
input as an exact/prefix match on the labels; else the first entry
(the next to run).
The highlighted candidate is read straight off `vertico--index' /
`vertico--candidates' rather than through an accessor like
`vertico--current', which no longer exists in current vertico
(renamed to `vertico--candidate', whose return additionally prepends
`vertico--base' after the user typed input).  `equal' ignores text
properties, so the face vertico puts on the candidate does not break
the table lookup."
  (let* ((vertico-active (and (bound-and-true-p vertico-mode)
                              (boundp 'vertico--candidates)
                              (boundp 'vertico--index)
                              (>= vertico--index 0)))
         (hl (and vertico-active
                  (ignore-errors
                    (nth vertico--index vertico--candidates))))
         (typed (condition-case nil (minibuffer-contents) (error nil)))
         (entry (or (and hl
                         (assoc hl dsh-emacs--queue-pick-table))
                    (and typed
                         (assoc typed dsh-emacs--queue-pick-table))
                    (and typed
                         (let ((hit (car (all-completions
                                          typed
                                          (mapcar #'car
                                                  dsh-emacs--queue-pick-table)))))
                           (and hit
                                (assoc hit dsh-emacs--queue-pick-table))))
                    (car dsh-emacs--queue-pick-table))))
    (cdr entry)))

(defun dsh-emacs-queue--menu-chat ()
  "The chat buffer the queue menu was opened from."
  (window-buffer (minibuffer-selected-window)))

(defun dsh-emacs-queue--menu-run (fn)
  "Close the queue minibuffer and run FN on the picked item, in the
chat buffer the menu was opened from (RPC/input state stay the
session's own).  FN is deferred through `run-at-time 0': inside a
minibuffer command, nothing after `exit-minibuffer' is ever executed
— the exit THROWS out of the recursive minibuffer edit, abandoning
the rest of the command — so the action must be scheduled BEFORE the
exit and fired once the minibuffer is gone (same pattern as the `e'
and `x' keys)."
  (let* ((chat (dsh-emacs-queue--menu-chat))
         (item (dsh-emacs-queue--menu-item)))
    ;; 定时器必须排在 exit 之前：`exit-minibuffer' 会 throw 离开
    ;; 命令，之后的代码永不执行。
    (run-at-time 0 nil
                 (lambda ()
                   (when (and (buffer-live-p chat) item)
                     (with-current-buffer chat
                       (funcall fn item)))))
    (exit-minibuffer)))

(defun dsh-emacs-queue--menu-edit ()
  "Edit the picked entry's text (`e')."
  (interactive)
  (let* ((chat (dsh-emacs-queue--menu-chat))
         (item (dsh-emacs-queue--menu-item)))
    ;; 定时器先于 exit 注册，exit 后 minibuffer 已关，read-string
    ;; 不再嵌套在 recursive minibuffer 里（提示不会被吞）。
    (run-at-time 0 nil
                 (lambda ()
                   (when (and (buffer-live-p chat) item)
                     (with-current-buffer chat
                       (let ((text (read-string
                                    "Edit queued message: "
                                    (dsh-protocol-queue-item-text item))))
                         (unless (string-empty-p (string-trim text))
                           (dsh-emacs-queue--edit item text)))))))
    (exit-minibuffer)))

(defun dsh-emacs-queue--menu-steer ()
  "Steer the picked entry into the running turn (`s')."
  (interactive)
  (dsh-emacs-queue--menu-run
   (lambda (item)
     (cond
      ((eq (dsh-protocol-queue-item-placement item) 'steering)
       (message "Already steering"))
      ((not (dsh-emacs--busy-p))
       (message "No turn is running — RET sends it now"))
      (t (dsh-emacs-queue--steer item))))))

(defun dsh-emacs-queue--menu-delete ()
  "Delete the picked entry (`d')."
  (interactive)
  (dsh-emacs-queue--menu-run #'dsh-emacs-queue--delete))

(defun dsh-emacs-queue--menu-send ()
  "Send the picked entry now (`RET')."
  (interactive)
  (dsh-emacs-queue--menu-run #'dsh-emacs-queue--send-now))

(defun dsh-emacs-queue--menu-delete-all ()
  "Delete the whole queue after confirmation (`x')."
  (interactive)
  (let* ((chat (dsh-emacs-queue--menu-chat))
         (items (delq nil (mapcar #'cdr dsh-emacs--queue-pick-table))))
    ;; 定时器先于 exit 注册（exit 的 throw 会丢弃命令剩余代码）。
    (run-at-time 0 nil
                 (lambda ()
                   (when (buffer-live-p chat)
                     (with-current-buffer chat
                       (when (y-or-n-p
                              (format "Delete all %d queued item%s? "
                                      (length items)
                                      (if (= (length items) 1) "" "s")))
                         (dolist (it items)
                           (dsh-emacs-queue--delete it)))))))
    (exit-minibuffer)))

(defun dsh-emacs-queue--chooser-keymap ()
  "Minibuffer keymap for the queue menu: `e'/`s'/`d'/`RET' act on the
picked entry, `x' deletes the whole queue.  Built exactly like the
question chooser's (`dsh-emacs--question-chooser-keymap'): a copy of
the minibuffer's current local map (vertico's when active, so its
navigation keys survive) plus our single keys.  Mounted last in the
minibuffer-setup-hook chain (`minibuffer-with-setup-hook' prepends its
hook, so vertico's `use-local-map vertico-map' has already run), which
is what makes the keys win."
  (let ((map (copy-keymap (or (current-local-map)
                              (make-sparse-keymap)))))
    (define-key map (kbd "e") #'dsh-emacs-queue--menu-edit)
    (define-key map (kbd "s") #'dsh-emacs-queue--menu-steer)
    (define-key map (kbd "d") #'dsh-emacs-queue--menu-delete)
    (define-key map (kbd "x") #'dsh-emacs-queue--menu-delete-all)
    (define-key map (kbd "RET") #'dsh-emacs-queue--menu-send)
    map))

(defun dsh-emacs-queue--chooser-setup-hook ()
  "Queue-menu minibuffer setup: stable candidate order (no completion
re-sort), first entry preselected, single-key map mounted.  Same as the
question chooser's setup — because `minibuffer-with-setup-hook'
prepends, this hook runs AFTER vertico's and its `use-local-map' wins.
Returns nil explicitly — `minibuffer-with-setup-hook' funcalls the
setup value."
  (when (boundp 'vertico-sort-function)
    (setq-local vertico-sort-function nil))
  (when (boundp 'vertico-sort-override-function)
    (setq-local vertico-sort-override-function nil))
  (when (boundp 'vertico-preselect)
    (setq-local vertico-preselect 'first))
  (use-local-map (dsh-emacs-queue--chooser-keymap))
  nil)

(defun dsh-emacs-list-queue ()
  "Manage this session's pending queue (minibuffer menu).
Opens the queue as a candidate list (`[Q]' queued, `[S]' steering;
vertico/icomplete up/down moves) and acts on the picked entry with the
SINGLE keys bound inside the minibuffer — no numbering, no separate
selection step: `e' edit the current entry's text, `s' steer it into
the running turn, `d' delete it, `x' delete the whole queue (after
confirmation), `RET' send it now (steer while a turn runs; while idle
it wakes the queue drain).  One `C-g' cancels.  Keys and RPCs run back
in the chat buffer the menu was opened from.  Host-injected `context'
items are never shown or acted on."
  (interactive)
  (dsh-emacs-queue--session-id)
  ;; C-g 一次彻底退出（菜单、编辑、全删确认），不留半开 minibuffer。
  (condition-case nil
      (let* ((items (cl-remove-if
                     (lambda (item)
                       (eq (dsh-protocol-queue-item-placement item) 'context))
                     dsh-emacs--queue-items)))
        (when (null items)
          (user-error "Queue is empty"))
        (let* ((table (dsh-emacs-queue--table items))
               (dsh-emacs--queue-pick-table table))
          (minibuffer-with-setup-hook
              (lambda () (dsh-emacs-queue--chooser-setup-hook))
            (completing-read
             (format "Queue Q%d S%d — e edit, s steer, d delete, x all, RET send: "
                     (car (dsh-emacs-queue-counts))
                     (cdr (dsh-emacs-queue-counts)))
             (mapcar #'car table) nil nil nil nil nil))))
    (quit (message "Queue manager cancelled"))))

(provide 'dsh-emacs-queue)

;;; dsh-emacs-queue.el ends here
