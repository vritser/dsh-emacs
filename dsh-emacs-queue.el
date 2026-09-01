;;; dsh-emacs-queue.el --- Pending-input queue (queue/steer) for dsh-emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2025 vritser

;; Author: vritser
;; Version: 0.1.0
;; License: GPL-3.0-or-later
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; Client-side mirror of the dsh agent inbox: input sent while a turn is
;; running either queues as the next turn (`session.prompt' mode "queue")
;; or steers the running agent before its next step (mode "steer").  The
;; host publishes the authoritative snapshot as `session/queue' mux frames
;; (on every inbox splice, plus once per connection for sessions with
;; pending items), so this module only mirrors frames — there is no fetch
;; RPC and no local bookkeeping that could drift.

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
;;   - while the queue is non-empty the input prompt carries a
;;     clock-icon + text prefix preview (the `[next: …] ' brackets
;;     appear only when Emacs lacks SVG image support).

;;; Code:

(require 'cl-lib)
(require 'dsh-emacs-protocol)
(require 'dsh-emacs-faces)

;; 同包模块的惰性边界（见 AGENTS.md）：dsh-emacs.el 装配本模块，运行时
;; 反向调用其符号走 declare-function，避免顶层 require 环。
(declare-function dsh-emacs--active-session-id "dsh-emacs" ())
(declare-function dsh-emacs--busy-p "dsh-emacs" ())
(declare-function dsh-emacs--replace-input "dsh-emacs" (text))
(declare-function dsh-emacs--rpc-async "dsh-emacs" (method params callback))
(declare-function dsh-emacs--submit-prompt "dsh-emacs" (message &optional images mode))
(declare-function dsh-emacs-render--input-anchor-pos "dsh-emacs-render" ())

(defvar dsh-emacs--input-marker)
(defvar dsh-emacs--buffer-session)

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
  "Item ids this client deleted via `session.updateQueue'.
Their disappearance from the next frame is the delete being confirmed,
not a consumption, so the `running' feedback is suppressed.  Ids are
pruned once the confirming frame arrives.")

(defvar-local dsh-emacs--queue-prefix nil
  "The input-prompt prefix string currently shown before `❯ ', or nil.
Compared byte-wise before removal, so a stale prefix after an input-area
rebuild can never delete the wrong region.")

(defvar-local dsh-emacs-queue--prefix-timer nil
  "Pending zero-delay timer that repaints the prefix / mode-line.
Queue frames arrive in bursts — the host often splices an item in and
claims it again within milliseconds, and painting each frame would
flash the `[next: …] ' prefix.  One repaint per burst, from the settled
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
are filtered out by the events dispatcher."
  (when (buffer-live-p chat)
    (with-current-buffer chat
      (let* ((items (dsh-protocol-queue-items-from-alist payload))
             (seed (not (eq process dsh-emacs--queue-process))))
        (setq dsh-emacs--queue-process process)
        (unless seed
          (dsh-emacs-queue--announce
           (dsh-emacs-queue--diff-events dsh-emacs--queue-items
                                         items
                                         dsh-emacs--queue-deleted)))
        (setq dsh-emacs--queue-items items)
        ;; 删除已被服务器确认（项已消失）：清掉抑制标记，避免吞掉后续
        ;; 真实消费的反馈。
        (setq dsh-emacs--queue-deleted
              (cl-remove-if-not
               (lambda (id)
                 (dsh-emacs-queue--find-id items id))
               dsh-emacs--queue-deleted))
        (dsh-emacs-queue--schedule-paint)))))

;;; ---------------------------------------------------------------------------
;;; 输入行前缀预览：SVG 时钟图标 + 下一条提示 ❯
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-queue--next-item ()
  "Return the next message the host will send, or nil.
The host delivers in-flight `steering' (next-step) items at the running
agent's next step, before any `queued' (next-turn) item of the next
turn, so the preview prefers the first steering item and falls back to
the first queued one.  `context' items are host-injected content, not
pending user messages — never previewed."
  (or (cl-find-if (lambda (item)
                    (eq (dsh-protocol-queue-item-placement item) 'steering))
                  dsh-emacs--queue-items)
      (cl-find-if (lambda (item)
                    (eq (dsh-protocol-queue-item-placement item) 'queued))
                  dsh-emacs--queue-items)))

(defconst dsh-emacs-queue--next-icon-svg
  "<svg width=\"14\" height=\"14\" viewBox=\"0 0 14 14\" fill=\"none\" xmlns=\"http://www.w3.org/2000/svg\"><path d=\"M7.00049 0.199829C3.24488 0.199829 0.199952 3.24408 0.199707 6.99963C0.199707 8.0414 0.434087 9.03061 0.854004 9.91467L1.11279 10.4576L2.19775 9.94202L1.94092 9.39905L1.81787 9.12268C1.5498 8.46885 1.40186 7.75171 1.40186 6.99963C1.4021 3.90808 3.90888 1.40198 7.00049 1.40198C10.0919 1.40219 12.5979 3.90821 12.5981 6.99963C12.5981 10.0913 10.0921 12.5983 7.00049 12.5983C6.36734 12.5983 5.90348 12.5535 5.49268 12.4401C5.08803 12.3283 4.7041 12.1414 4.24463 11.8209C3.57111 11.3511 2.60588 11.1855 1.81006 11.6881L1.79736 11.6959L1.78467 11.7047L1.25537 12.0778L1.65381 13.2672L2.46045 12.6989C2.75029 12.5214 3.18004 12.5442 3.55615 12.8063C4.10063 13.1861 4.60863 13.4423 5.17334 13.5983C5.73194 13.7525 6.31665 13.8004 7.00049 13.8004C10.7561 13.8002 13.8003 10.7553 13.8003 6.99963C13.8 3.24421 10.7559 0.200041 7.00049 0.199829ZM3.81201 7.47327V8.67542H7.11572V7.47327H3.81201ZM3.81201 6.34924H10.2173V5.14709H3.81201V6.34924Z\" fill=\"currentColor\"></path></svg>"
  "SVG data of the next-preview clock icon (14x14, filled via `currentColor').

The `currentColor' value is mapped to the `:foreground' image property
by `dsh-emacs-queue--next-icon', so the icon picks up the prompt face's
color instead of a hard-coded one.")

(defun dsh-emacs-queue--next-icon ()
  "Return the clock-icon image string for the next-preview prefix, or nil.
The result is a single space carrying the image `display' property plus
the prompt face on its character, so the welcome prompt run stays
contiguous.  nil when SVG images are unavailable (Emacs built without
librsvg) — callers then fall back to the `[next: …] ' brackets."
  (when (image-type-available-p 'svg)
    (let ((fg (face-foreground 'dsh-emacs-input-prompt-face nil t)))
      (propertize
       " "
       'face 'dsh-emacs-input-prompt-face
       'display
       (create-image dsh-emacs-queue--next-icon-svg
                     'svg t
                     :ascent 'center
                     :scale 1.0
                     :foreground (or fg "gray50"))))))

(defun dsh-emacs-queue--prefix (preview)
  "Build the input-prompt prefix showing PREVIEW.
With SVG support the prefix is a clock icon followed by the preview
text; otherwise the historical `[next: …] ' brackets are kept.  The
whole string carries `dsh-emacs-input-prompt-face' (the icon keeps its
`display' property), so prefix and `❯ ' merge into one prompt run and
the anchor scan / byte-wise removal logic stays intact."
  (let ((icon (dsh-emacs-queue--next-icon)))
    (if icon
        (propertize (concat icon " " preview " ")
                    'face 'dsh-emacs-input-prompt-face)
      (propertize (format "[next: %s] " preview)
                  'face 'dsh-emacs-input-prompt-face))))

(defun dsh-emacs-queue--paint-after-burst ()
  "Repaint the next-preview prefix and mode-line from the CURRENT mirror.
Runs once per frame burst (zero-delay timer); the mirror already holds
the settled state, so a transient item that was spliced and instantly
claimed never surfaces in the prefix."
  (setq dsh-emacs-queue--prefix-timer nil)
  (when (and dsh-emacs--input-marker
             (marker-buffer dsh-emacs--input-marker))
    (dsh-emacs-queue--update-prefix)
    (force-mode-line-update)))

(defun dsh-emacs-queue--schedule-paint ()
  "Schedule one prefix/mode-line repaint for the current frame burst.
Further frames arriving before the timer fires (same burst) are folded
into the same repaint — see `dsh-emacs-queue--prefix-timer'."
  (unless dsh-emacs-queue--prefix-timer
    (let ((buf (current-buffer)))
      (setq dsh-emacs-queue--prefix-timer
            (run-at-time
             0 nil
             (lambda ()
               (when (buffer-live-p buf)
                 (with-current-buffer buf
                   (dsh-emacs-queue--paint-after-burst)))))))))

(defun dsh-emacs-queue--update-prefix ()
  "Sync the next-preview prompt prefix (clock icon + text) with the mirror.
The prefix sits in the read-only welcome region (prompt face run, so
the input anchor keeps pointing at the run start); edits go through
`inhibit-read-only' and the previous prefix is removed only when it is
still exactly what this module inserted."
  (when (and dsh-emacs--input-marker
             (marker-buffer dsh-emacs--input-marker))
    (let* ((anchor (dsh-emacs-render--input-anchor-pos))
           (next (dsh-emacs-queue--next-item))
           (wanted (and anchor next
                        (dsh-emacs-queue--prefix
                         (dsh-emacs-queue-preview
                          (dsh-protocol-queue-item-text next))))))
      (when anchor
        (let ((inhibit-read-only t)
              (old (and dsh-emacs--queue-prefix
                        (length dsh-emacs--queue-prefix))))
          (when (and old
                     (> old 0)
                     (<= (+ anchor old) (point-max))
                     (string= (buffer-substring-no-properties
                               anchor (+ anchor old))
                              dsh-emacs--queue-prefix))
            (delete-region anchor (+ anchor old)))
          (setq dsh-emacs--queue-prefix nil)
          (when wanted
            (goto-char anchor)
            (insert wanted)
            (setq dsh-emacs--queue-prefix wanted)))))))

(defun dsh-emacs-queue--refresh-ui ()
  "Recompute the input-prompt next preview and the mode-line counts.
Optimistic path (steer/delete/edit RPC success): paint right away and
drop any pending burst repaint, so our own actions stay instantaneous."
  (when (timerp dsh-emacs-queue--prefix-timer)
    (cancel-timer dsh-emacs-queue--prefix-timer))
  (setq dsh-emacs-queue--prefix-timer nil)
  (dsh-emacs-queue--paint-after-burst))

;;; ---------------------------------------------------------------------------
;;; RPC：session.updateQueue（edit / remove / steer）
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-queue--session-id ()
  "Return the session id this queue manages, or error when none is open."
  (or (dsh-emacs--active-session-id)
      (user-error "No session is open")))

(defun dsh-emacs-queue--update (item-id action &optional on-error on-success)
  "Send one `session.updateQueue' call for ITEM-ID with ACTION.
ACTION is the wire action alist (e.g. ((kind . \"remove\"))).  ON-ERROR
runs in the chat buffer when the call fails; ON-SUCCESS when it
succeeds — both with the chat buffer current.  The mirror is normally
confirmed by the following `session/queue' frame; ON-SUCCESS is where
this client applies our own actions OPTIMISTICALLY, so steer / delete /
edit update the next-preview hint and the mode-line the instant the
RPC succeeds, without waiting for the frame round-trip."
  (let ((session-id (dsh-emacs-queue--session-id))
        (buf (current-buffer)))
    (dsh-emacs--rpc-async
     "session.updateQueue"
     `((sessionId . ,session-id)
       (itemId . ,item-id)
       (action . ,action))
     (lambda (ok value)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (if ok
               (when on-success (funcall on-success value))
             (when on-error (funcall on-error value))
             (message "Queue update failed: %S" value))))))))

(defun dsh-emacs-queue--delete (item)
  "Delete ITEM via `session.updateQueue' (kind remove)."
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
         "session.updateQueue"
         `((sessionId . ,session-id)
           (itemId . ,id)
           (action . ((kind . "remove"))))
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
