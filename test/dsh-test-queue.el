;;; dsh-test-queue.el --- Queue tests -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "28.1"))

(require 'dsh-test-support)

(defvar vertico-mode)
(defvar vertico--index)
(defvar vertico--candidates)

;; Protocol layer: the `inbox' projection value → queue item structs (field
;; names appear only in the constructor).  A `next-turn' entry is `queued'; a
;; `next-step' entry with a `user' source is `steering', any other one
;; `context' — exactly the mapping the host applied through dsh 0.1.6, when it
;; published this same fold state as `session/queue' frames instead.
(ert-deftest dsh-emacs-test-queue-queue-inbox-value-normalized ()
  :tags '(dsh-unit)
  (let ((items (dsh-protocol-queue-items-from-inbox
                (list (cons 'next-turn
                            (vector (dsh-emacs-test--inbox-message "a" "first")))
                      (cons 'next-step
                            (vector (dsh-emacs-test--inbox-message
                                     "b" "steer me" "user")
                                    (dsh-emacs-test--inbox-message
                                     "c" "injected" "plugin")))))))
    (ert-info ((format "%s" "queue-inbox-value-normalized"))
      (should (= 3 (length items)))
      (should (equal "a" (dsh-protocol-queue-item-id (nth 0 items))))
      (should (equal "first" (dsh-protocol-queue-item-text (nth 0 items))))
      (should (eq 'queued (dsh-protocol-queue-item-placement (nth 0 items))))
      (should (equal "steer me" (dsh-protocol-queue-item-text (nth 1 items))))
      (should (eq 'steering (dsh-protocol-queue-item-placement (nth 1 items))))
      (should (equal "injected" (dsh-protocol-queue-item-text (nth 2 items))))
      (should (eq 'context (dsh-protocol-queue-item-placement (nth 2 items))))
      (should (equal "plugin" (dsh-protocol-queue-item-kind (nth 2 items)))))
    (ert-info ((format "%s" "queue-inbox-value-missing-lists-empty"))
      (should (null (dsh-protocol-queue-items-from-inbox nil)))
      (should (null (dsh-protocol-queue-items-from-inbox '((other . 1)))))
      (should (null (dsh-protocol-queue-items-from-inbox
                     (list (cons 'next-turn []) (cons 'next-step []))))))))

;; A queue item knows whether its content is all text: the row offers its edit
;; cell only then, because the edit RPC answers with text blocks and would
;; otherwise flatten an image or file attachment (postmortem/101).
(ert-deftest dsh-emacs-test-queue-queue-item-text-only-tracks-its-blocks ()
  :tags '(dsh-unit)
  (let ((items (dsh-protocol-queue-items-from-inbox
                (list (cons 'next-turn
                            (vector (dsh-emacs-test--inbox-message "a" "text only")
                                    (list (cons 'id "b")
                                          (cons 'content
                                                (vector
                                                 (list (cons 'type "text")
                                                       (cons 'text "look at this"))
                                                 (list (cons 'type "image")
                                                       (cons 'attachment
                                                             (list (cons 'attachmentId
                                                                         "att-1"))))))
                                          (cons 'source (list (cons 'kind "user"))))))))))
    (ert-info ((format "%s" "queue-item-text-only-tracks-its-blocks"))
      (should (eq t (dsh-protocol-queue-item-text-only (nth 0 items))))
      (should (equal "look at this" (dsh-protocol-queue-item-text (nth 1 items))))
      (should (null (dsh-protocol-queue-item-text-only (nth 1 items)))))))

;; Counts: context placement does not enter the Q/S tally (aligned with
;; dsh web QueueDock)
(ert-deftest dsh-emacs-test-queue-queue-counts-ignores-context ()
  :tags '(dsh-unit)
  (ert-info ((format "%s" "queue-counts-ignores-context"))
    (should (equal '(2 . 1)
                   (dsh-emacs-queue--counts-of
                    (list (dsh-emacs-test--queue-item "1" "queued" "a")
                          (dsh-emacs-test--queue-item "2" "queued" "b")
                          (dsh-emacs-test--queue-item "3" "steering" "c")
                          (dsh-emacs-test--queue-item "4" "context" "d")))))))

;; Preview: take the first line, truncate when overlong
(ert-deftest dsh-emacs-test-queue-queue-preview-first-line-and-truncation ()
  :tags '(dsh-unit)
  (ert-info ((format "%s" "queue-preview-first-line-and-truncation"))
    (should (equal "one" (dsh-emacs-queue-preview "one\ntwo")))
    (should (equal "abcdefghij" (dsh-emacs-queue-preview "abcdefghij")))
    (should (equal 40 (length (dsh-emacs-queue-preview
                               (make-string 100 ?x)))))
    (should (string-suffix-p "..." (dsh-emacs-queue-preview (make-string 100 ?x))))))

;; diff: consume (disappear), newly queued, newly steering, promote
(ert-deftest dsh-emacs-test-queue-queue-diff-events-consume-queue-steer ()
  :tags '(dsh-unit)
  (let* ((old (list (dsh-emacs-test--queue-item "keep" "queued" "kept")
                    (dsh-emacs-test--queue-item "gone" "queued" "consumed one")))
         (new (list (dsh-emacs-test--queue-item "keep" "queued" "kept")
                    (dsh-emacs-test--queue-item "newq" "queued" "lined up")
                    (dsh-emacs-test--queue-item "news" "steering" "steered in")))
         (events (dsh-emacs-queue--diff-events old new nil)))
    (ert-info ((format "%s" "queue-diff-events-consume-queue-steer"))
      (should (member (cons 'running "consumed one") events))
      (should (member (cons 'queued "lined up") events))
      (should (member (cons 'steering "steered in") events))
      (should (= 3 (length events))))))

;; diff: an id deleted locally produces no running feedback (deletion
;; confirmed ≠ consumed)
(ert-deftest dsh-emacs-test-queue-queue-diff-events-suppresses-deleted ()
  :tags '(dsh-unit)
  (let* ((item (dsh-emacs-test--queue-item "del" "queued" "deleted one"))
         (events (dsh-emacs-queue--diff-events (list item) nil '("del"))))
    (ert-info ((format "%s" "queue-diff-events-suppresses-deleted"))
      (should (null events)))
    (ert-info ((format "%s" "queue-diff-events-foreign-disappearance-is-consumption"))
      (should (equal '((running . "deleted one"))
                     (dsh-emacs-queue--diff-events (list item) nil nil))))))

;; diff: queued→steering promotion (initiated by the other side) reports
;; steering
(ert-deftest dsh-emacs-test-queue-queue-diff-events-promotion-is-steering ()
  :tags '(dsh-unit)
  (let* ((old (list (dsh-emacs-test--queue-item "p" "queued" "promoted")))
         (new (list (dsh-emacs-test--queue-item "p" "steering" "promoted")))
         (events (dsh-emacs-queue--diff-events old new nil)))
    (ert-info ((format "%s" "queue-diff-events-promotion-is-steering"))
      (should (equal '((steering . "promoted")) events)))))

;; Frame application: the connection's first frame seeds silently (no
;; replay of historical feedback), later frames update the mirror
(ert-deftest dsh-emacs-test-queue-queue-apply-seeds-first-frame-silently ()
  :tags '(dsh-unit)
  (let ((buf (get-buffer-create " *t-queue-apply*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (dsh-emacs-mode)
            (dsh-emacs-queue-apply buf 'proc-1
                                   (list (dsh-emacs-test--queue-item
                                          "s1" "queued" "seeded")))
            (ert-info ((format "%s" "queue-apply-seeds-first-frame-silently"))
              (should (= 1 (length dsh-emacs--queue-items)))
              (should (equal "seeded" (dsh-protocol-queue-item-text
                                       (car dsh-emacs--queue-items)))))
            ;; Second frame of the same connection: full mirror replacement
            (dsh-emacs-queue-apply buf 'proc-1
                                   (list (dsh-emacs-test--queue-item
                                          "s1" "queued" "seeded")
                                         (dsh-emacs-test--queue-item
                                          "s2" "steering" "added")))
            (ert-info ((format "%s" "queue-apply-replaces-mirror"))
              (should (= 2 (length dsh-emacs--queue-items)))
              (should (eq 'steering (dsh-protocol-queue-item-placement
                                     (cadr dsh-emacs--queue-items)))))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

;; --- Empty-queue submit transient never flashes the echo area (the
;; "C-c C-c flash next message" fix) ---
;; Regression: the protocol only knows queue/steer prompt modes, so a
;; message sent with NOTHING PENDING — idle, or queued behind a running
;; turn — is appended to the host inbox and claimed at the turn start
;; (one `session/queue' frame each, observed live: 10ms apart).  72dbca0
;; added the seq gate only to the session/event path; the queue frame
;; path's diff still surfaced this transient as user events, flashing
;; "queued: …" then "running: …".  Fix: the submit paths arm
;; dsh-emacs--queue-submit-suppress when the mirror is empty; the mirror
;; updates silently meanwhile, and the settling empty frame (the claim)
;; disarms it.  Genuine queueing (items parked) keeps its feedback.
(ert-deftest dsh-emacs-test-queue-queue-submit-suppress-swallows-splice-in ()
  :tags '(dsh-unit)
  (let ((chat (get-buffer-create " *t-queue-submit-suppress*"))
        (proc (make-pipe-process :name "t-queue-suppress" :buffer nil))
        (announced nil))
    (unwind-protect
        (progn
          (process-put proc 'dsh-emacs-chat-buffer chat)
          (with-current-buffer chat
            (dsh-emacs-mode)
            (setq-local dsh-emacs--buffer-session "sess-sup")
            (cl-letf (((symbol-function 'dsh-emacs-queue--announce)
                       (lambda (_events) (setq announced t)))
                      ((symbol-function 'run-at-time) (lambda (&rest _) t)))
              (setq-local dsh-emacs--queue-submit-suppress t)
              ;; Frame 1: our message is spliced in → mirror updates, no
              ;; flash, the flag survives.  Queue mirrors arrive on the core
              ;; connection's `session/control' stream; `dsh-emacs-queue-apply'
              ;; is the dispatcher's consumer.
              (dsh-emacs-queue-apply
               chat proc
               (list (dsh-emacs-test--queue-item
                      "x1" "queued" "hello")))
              (ert-info ((format "%s" "queue-submit-suppress-swallows-splice-in"))
                (should (null announced))
                (should (= 1 (length dsh-emacs--queue-items)))
                (should (equal "hello" (dsh-protocol-queue-item-text
                                        (car dsh-emacs--queue-items))))
                (should dsh-emacs--queue-submit-suppress))
              (setq announced nil)
              ;; Frame 2: the item is claimed → mirror empty, flag
              ;; disarmed, still no flash
              (dsh-emacs-queue-apply chat proc nil)
              (ert-info ((format "%s" "queue-submit-suppress-settles-and-unarms"))
                (should (null announced))
                (should (null dsh-emacs--queue-items))
                (should (null dsh-emacs--queue-submit-suppress)))
              ;; Reconnect seed frame: the transient stays silent across the
              ;; connection (on a fresh open the splice-in frame IS the
              ;; seed) — the seed seeds silently and keeps the flag, the
              ;; claim frame then disarms it
              (setq-local dsh-emacs--queue-submit-suppress t)
              (dsh-emacs-queue-apply
               chat 'proc-2
               (list (dsh-emacs-test--queue-item
                      "r1" "queued" "replay")))
              (ert-info ((format "%s" "queue-submit-suppress-seed-keeps-flag"))
                (should (= 1 (length dsh-emacs--queue-items)))
                (should (null announced))
                (should dsh-emacs--queue-submit-suppress))
              (dsh-emacs-queue-apply chat 'proc-2 nil)
              (ert-info ((format "%s" "queue-submit-suppress-claim-settles-after-seed"))
                (should (null dsh-emacs--queue-items))
                (should (null announced))
                (should (null dsh-emacs--queue-submit-suppress))))))
      (when (buffer-live-p chat) (kill-buffer chat))
      (delete-process proc))))

;; Preview gating: while the self-submit transient lives (mirror holds only
;; our own message, suppress armed) the Next Message row must not paint —
;; a preview would flash the input line on every submit (the literal
;; "flash next message" symptom); once disarmed it paints from the mirror
;; normally.  The mode-line Q/S counts are not gated and still reflect
;; the queue.
(ert-deftest dsh-emacs-test-queue-queue-submit-suppress-gates-next-row ()
  :tags '(dsh-unit)
  (let ((buf (get-buffer-create " *t-queue-next-row-gate*")))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-mode)
          (setq-local dsh-emacs--buffer-session "sess-pfx")
          (setq-local dsh-emacs--queue-submit-suppress t)
          (setq dsh-emacs--queue-items
                (list (dsh-emacs-test--queue-item "g1" "queued" "gated")))
          (dsh-emacs-composer-render)
          (ert-info ((format "%s" "queue-submit-suppress-gates-next-row"))
            (should (null (dsh-test-composer-next-row))))
          (dsh-emacs-queue--submit-suppress-clear)
          (dsh-emacs-composer-render)
          (ert-info ((format "%s" "queue-submit-suppress-ungates-next-row"))
            (should (dsh-test-composer-next-row))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

;; Disarming triggers a repaint: when the timeout lifts the flag while the
;; message is STILL queued (a long busy turn), the Next Message preview must
;; come back — frames are the only repaint trigger, the flag change alone
;; is not, so without this the row would stay gone until the next frame
;; arrives.
(ert-deftest dsh-emacs-test-queue-queue-submit-suppress-holds-row-hidden ()
  :tags '(dsh-unit)
  (let ((buf (get-buffer-create " *t-queue-next-row-restore*"))
        (paints nil))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-mode)
          (setq-local dsh-emacs--buffer-session "sess-pfx2")
          (cl-letf (((symbol-function 'run-at-time)
                     (lambda (_delay _repeat fn) (push fn paints) t)))
            (setq-local dsh-emacs--queue-submit-suppress t)
            (setq dsh-emacs--queue-items
                  (list (dsh-emacs-test--queue-item "g2" "queued" "still queued")))
            (dsh-emacs-composer-render)
            (ert-info ((format "%s" "queue-submit-suppress-holds-row-hidden"))
              (should (null (dsh-test-composer-next-row))))
            (dsh-emacs-queue--submit-suppress-clear)
            (ert-info ((format "%s" "queue-submit-suppress-clear-schedules-repaint"))
              (should (consp paints)))
            (dolist (fn paints) (funcall fn))
            (ert-info ((format "%s" "queue-submit-suppress-timeout-restores-row"))
              (should (dsh-test-composer-next-row)))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

;; The parked case is revealed by STATE, not by a timer: a submit made while
;; a turn is already running can only be claimed at the turn end, so its
;; Next Message preview must show even though the submit-suppression is still
;; armed — the old timer-only reveal is what made a queued message appear
;; ~2s late.  The discriminator is the submit-time busy state captured by
;; `dsh-emacs-queue--mark-submit-suppress', not the live spinner.
(ert-deftest dsh-emacs-test-queue-queue-submit-suppress-busy-reveals-parked ()
  :tags '(dsh-unit)
  (let ((buf (get-buffer-create " *t-queue-next-row-busy-reveal*")))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-mode)
          (setq-local dsh-emacs--buffer-session "sess-busy")
          (setq-local dsh-emacs--ml-busy t)
          (dsh-emacs-queue--mark-submit-suppress)
          (setq dsh-emacs--queue-items
                (list (dsh-emacs-test--queue-item "pb" "queued" "parked")))
          (dsh-emacs-composer-render)
          (ert-info ((format "%s" "queue-submit-suppress-busy-reveals-parked"))
            (should (dsh-test-composer-next-row))
            (should dsh-emacs--queue-submit-suppress)
            (should dsh-emacs-queue--submit-parked-p))
          (dsh-emacs-queue--submit-suppress-clear))
      (when (buffer-live-p buf) (kill-buffer buf)))))

;; A queued submit previews in the Next Message row immediately, before the
;; host's own `session/queue' frame: that frame is one RPC round trip away,
;; and waiting for it made the queued send feel sticky.  The optimistic item
;; is the only local preview state; the host frame (or a failed submit)
;; retires it.
(ert-deftest dsh-emacs-test-queue-queued-submit-previews-before-host-frame ()
  :tags '(dsh-unit)
  (let ((buf (get-buffer-create " *t-queue-optimistic-submit*"))
        (proc (make-pipe-process :name "t-queue-opt" :buffer nil))
        (cbs nil))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-mode)
          (setq-local dsh-emacs--buffer-session "sess-opt-submit")
          (setq dsh-emacs--queue-items nil
                dsh-emacs--queue-process nil)
          (setq-local dsh-emacs--ml-busy t)
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (_m _p callback) (push callback cbs))))
            (dsh-emacs--submit-deferred "queued now")
            (ert-info ((format "%s" "queued-submit-previews-before-host-frame"))
              (should (let ((item (dsh-emacs-queue-next-item)))
                        (and item
                             (string= "queued now" (dsh-protocol-queue-item-text item))
                             (eq 'queued (dsh-protocol-queue-item-placement item)))))
              (should (dsh-test-composer-next-row)))
            ;; The host's own frame carries the real item: the local preview retires.
            (dsh-emacs-queue-apply
             buf proc
             (list (dsh-emacs-test--queue-item
                    "real" "queued" "queued now")))
            (ert-info ((format "%s" "queued-submit-preview-cleared-by-host-frame"))
              (should (null dsh-emacs-queue--optimistic-submit))
              (should (string= "queued now"
                               (dsh-protocol-queue-item-text (dsh-emacs-queue-next-item)))))
            ;; A rejected submit drops the local preview with the suppression.
            (dsh-emacs--submit-deferred "queued lost")
            (ert-info ((format "%s" "queued-submit-preview-shown-again"))
              (should dsh-emacs-queue--optimistic-submit))
            (should (= (length cbs) 2))
            (funcall (car cbs) nil '((code . "down")))
            (ert-info ((format "%s" "queued-submit-preview-cleared-on-failure"))
              (should (null dsh-emacs-queue--optimistic-submit)))))
      (when (process-live-p proc) (delete-process proc))
      (when (buffer-live-p buf) (kill-buffer buf)))))

;; An IDLE submit is NOT parked: the host claims it at the turn START, and
;; the send path lights the optimistic spinner on acceptance — both before
;; the claim frame arrives.  The busy reveal must therefore key on whether a
;; turn was ALREADY running when the submit was made, not on the current
;; spinner: keying on the spinner paints our own message on the splice frame
;; and clears it on the claim frame (the flash on `C-c C-c').
(ert-deftest dsh-emacs-test-queue-queue-idle-submit-splice-does-not-flash-next-row ()
  :tags '(dsh-unit)
  (let ((buf (get-buffer-create " *t-queue-next-row-idle-submit*")))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-mode)
          (setq-local dsh-emacs--buffer-session "sess-idle-submit")
          (setq-local dsh-emacs--ml-busy nil)
          (setq dsh-emacs--queue-items nil)
          ;; Idle submit (mirror empty) arms the suppression while NOT busy…
          (dsh-emacs-queue--mark-submit-suppress)
          ;; …then the RPC is accepted and the optimistic spinner lights.
          (setq-local dsh-emacs--ml-busy t)
          ;; The splice frame carries our own just-submitted message.
          (setq dsh-emacs--queue-items
                (list (dsh-emacs-test--queue-item "own" "queued" "hello")))
          (dsh-emacs-composer-render)
          (ert-info ((format "%s" "queue-idle-submit-splice-does-not-flash-next-row"))
            (should (null (dsh-test-composer-next-row)))
            (should dsh-emacs--queue-submit-suppress))
          (dsh-emacs-queue--submit-suppress-clear))
      (when (buffer-live-p buf) (kill-buffer buf)))))

;; A fresh session's queue mirror is seeded by the connection's FIRST frame,
;; which can be EMPTY and arrive between the arm and the splice.  That seed
;; is a baseline, not the claim: treating any empty frame as the claim
;; disarmed the suppression early, so the next frame — our own splice —
;; painted the row and the claim cleared it again (the flash on the first
;; `C-c C-c' in a newly opened session).  The suppression must end only at
;; the empty frame that FOLLOWS our own item.
(ert-deftest dsh-emacs-test-queue-queue-empty-seed-keeps-submit-suppression ()
  :tags '(dsh-unit)
  (let ((buf (get-buffer-create " *t-queue-next-row-empty-seed*"))
        (proc (make-pipe-process :name "t-queue-empty-seed" :buffer nil))
        (announced nil))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-mode)
          (setq-local dsh-emacs--buffer-session "sess-empty-seed")
          (setq-local dsh-emacs--ml-busy nil)
          (setq dsh-emacs--queue-items nil
                dsh-emacs--queue-process nil)
          (cl-letf (((symbol-function 'dsh-emacs-queue--announce)
                     (lambda (events) (setq announced events))))
            (dsh-emacs-queue--mark-submit-suppress)
            ;; Connection seed: empty queue, first frame on this process.
            (dsh-emacs-queue-apply buf proc
                                   nil)
            (ert-info ((format "%s" "queue-empty-seed-keeps-submit-suppression"))
              (should dsh-emacs--queue-submit-suppress)
              (should (null dsh-emacs-queue--submit-seen-p))
              (should (null announced)))
            ;; Our own splice frame: still suppressed, so no row appears.
            (dsh-emacs-queue-apply
             buf proc
             (list (dsh-emacs-test--queue-item
                    "own" "queued" "hello")))
            (dsh-emacs-composer-render)
            (ert-info ((format "%s" "queue-empty-seed-splice-does-not-flash-next-row"))
              (should (null (dsh-test-composer-next-row)))
              (should dsh-emacs-queue--submit-seen-p)
              (should dsh-emacs--queue-submit-suppress)
              (should (null announced)))
            ;; The claim frame that follows the splice then disarms.
            (dsh-emacs-queue-apply buf proc
                                   nil)
            (ert-info ((format "%s" "queue-empty-seed-claim-disarms"))
              (should (null dsh-emacs--queue-submit-suppress))
              (should (null dsh-emacs--queue-items))
              (should (null announced))))
          (dsh-emacs-queue--submit-suppress-clear))
      (when (buffer-live-p buf) (kill-buffer buf))
      (delete-process proc))))

;; Submit-path arming/disarming: armed whenever the mirror is EMPTY at
;; submit time — idle (plain path) or behind a running turn (deferred
;; path) — with the defensive disarm timer; parked items keep the flag
;; off (genuine queue/steer feedback must survive); the failure branch
;; disarms (no settling frame will ever arrive).
(ert-deftest dsh-emacs-test-queue-submit-plain-arms-suppress ()
  :tags '(dsh-unit)
  (let ((buf (get-buffer-create " *t-queue-suppress-arm*"))
        (cbs nil))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-mode)
          (setq-local dsh-emacs--buffer-session "sess-arm")
          (setq dsh-emacs--current-session "sess-arm")
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (_method _params cb) (push cb cbs))))
            ;; Plain path, idle + empty mirror → armed (with the timer)
            (dsh-emacs--ml-busy-clear)
            (dsh-emacs--submit-plain "hello idle")
            (ert-info ((format "%s" "submit-plain-arms-suppress"))
              (should dsh-emacs--queue-submit-suppress)
              (should (timerp dsh-emacs-queue--submit-suppress-timer)))
            (ert-info ((format "%s" "submit-plain-idle-submit-is-not-parked"))
              (should (null dsh-emacs-queue--submit-parked-p)))
            (dsh-emacs-queue--submit-suppress-clear)
            ;; Plain path, items parked → not armed: "queued:" is genuine
            (setq dsh-emacs--queue-items
                  (list (dsh-emacs-test--queue-item "p" "queued" "parked")))
            (dsh-emacs--submit-plain "hello parked")
            (ert-info ((format "%s" "submit-plain-parked-keeps-announce"))
              (should (null dsh-emacs--queue-submit-suppress)))
            (setq dsh-emacs--queue-items nil)
            ;; Deferred path (busy), empty mirror → armed: the running
            ;; turn's submit must not flash "queued:"/"running:" either
            (dsh-emacs--ml-busy-set t)
            (dsh-emacs--submit-deferred "hello busy")
            (ert-info ((format "%s" "submit-deferred-arms-when-empty"))
              (should dsh-emacs--queue-submit-suppress)
              (should (timerp dsh-emacs-queue--submit-suppress-timer)))
            (ert-info ((format "%s" "submit-deferred-busy-submit-is-parked"))
              (should dsh-emacs-queue--submit-parked-p))
            (dsh-emacs-queue--submit-suppress-clear)
            ;; Deferred path, items parked → not armed
            (setq dsh-emacs--queue-items
                  (list (dsh-emacs-test--queue-item "q" "queued" "parked2")))
            (dsh-emacs--submit-deferred "hello parked busy")
            (ert-info ((format "%s" "submit-deferred-parked-keeps-announce"))
              (should (null dsh-emacs--queue-submit-suppress)))
            (setq dsh-emacs--queue-items nil)
            (dsh-emacs--ml-busy-clear)
            ;; Failure branch (plain): no splice/claim frames will ever
            ;; settle the transient, so the submit path disarms directly
            (dsh-emacs--submit-plain "hello fail")
            (ert-info ((format "%s" "submit-plain-failure-arms"))
              (should dsh-emacs--queue-submit-suppress))
            (funcall (car cbs) nil '((code . "down")))
            (ert-info ((format "%s" "submit-plain-failure-clears-suppress"))
              (should (null dsh-emacs--queue-submit-suppress)))
            (ert-info ((format "%s" "submit-plain-failure-clears-timer"))
              (should (null dsh-emacs-queue--submit-suppress-timer)))
            ;; Failure branch (deferred): same disarm
            (dsh-emacs--ml-busy-set t)
            (dsh-emacs--submit-deferred "hello fail busy")
            (ert-info ((format "%s" "submit-deferred-failure-arms"))
              (should dsh-emacs--queue-submit-suppress))
            (funcall (car cbs) nil '((code . "down")))
            (ert-info ((format "%s" "submit-deferred-failure-clears-suppress"))
              (should (null dsh-emacs--queue-submit-suppress)))
            (ert-info ((format "%s" "submit-deferred-failure-clears-timer"))
              (should (null dsh-emacs-queue--submit-suppress-timer)))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

;; Multi-session concurrency: the suppression flag, mirror, and timer are
;; isolated per chat buffer — A's transient silence never mutes B's
;; genuine queue feedback, and B's frames never touch A's mirror
;; (queue mirrors arrive on the core connection's `session/control' stream
;; and `dsh-emacs-events--host-item' routes each `queue' item by session-id
;; to that session's live chat buffer, leaving other buffers untouched).
(ert-deftest dsh-emacs-test-queue-queue-submit-suppress-buffer-isolated ()
  :tags '(dsh-unit)
  (let* ((old-chats dsh-emacs--chat-buffers)
         (chat-a (get-buffer-create " *t-queue-multi-a*"))
         (chat-b (get-buffer-create " *t-queue-multi-b*"))
         (proc-a (make-pipe-process :name "t-queue-multi-a" :buffer nil))
         (proc-b (make-pipe-process :name "t-queue-multi-b" :buffer nil))
         (announced nil))
    (unwind-protect
        (progn
          (setq dsh-emacs--chat-buffers
                (let ((h (make-hash-table :test 'equal)))
                  (puthash "sess-multi-a" chat-a h)
                  (puthash "sess-multi-b" chat-b h)
                  h))
          (with-current-buffer chat-a
            (dsh-emacs-mode)
            (setq-local dsh-emacs--buffer-session "sess-multi-a"))
          (with-current-buffer chat-b
            (dsh-emacs-mode)
            (setq-local dsh-emacs--buffer-session "sess-multi-b"))
          (cl-letf (((symbol-function 'dsh-emacs-queue--announce)
                     (lambda (_events) (setq announced t)))
                    ((symbol-function 'run-at-time) (lambda (&rest _) t)))
            ;; A's empty-queue submit arms its suppression (B unaffected)
            (with-current-buffer chat-a
              (dsh-emacs-queue--mark-submit-suppress))
            (ert-info ((format "%s" "queue-submit-suppress-buffer-isolated"))
              (should (with-current-buffer chat-a dsh-emacs--queue-submit-suppress))
              (should (null (with-current-buffer chat-b dsh-emacs--queue-submit-suppress))))
            ;; A session-B queue item → B echoes normally; A's mirror and
            ;; suppression stay untouched.  B's mirror is seeded with an
            ;; empty baseline first (the first frame is the connect snapshot
            ;; by design), so the next frame is a real diff.
            (dsh-emacs-queue-apply chat-b proc-b nil)
            (dsh-emacs-events--host-item
             proc-b
             (list (cons 'type "projection")
                   (cons 'sessionId "sess-multi-b")
                   (cons 'key "inbox")
                   (cons 'value
                         (list (cons 'next-turn
                                     (vector (dsh-emacs-test--inbox-message
                                              "b1" "b-real")))
                               (cons 'next-step [])))))
            (ert-info ((format "%s" "queue-submit-suppress-multi-session"))
              (should announced)
              (should (with-current-buffer chat-b
                        (equal "b-real" (dsh-protocol-queue-item-text
                                         (car dsh-emacs--queue-items)))))
              (should (null (with-current-buffer chat-a dsh-emacs--queue-items)))
              (should (with-current-buffer chat-a dsh-emacs--queue-submit-suppress)))))
      (setq dsh-emacs--chat-buffers old-chats)
      (when (buffer-live-p chat-a) (kill-buffer chat-a))
      (when (buffer-live-p chat-b) (kill-buffer chat-b))
      (delete-process proc-a)
      (delete-process proc-b))))

;; Event-dispatch level: session/control's `inbox' projection cell is routed
;; by `dsh-emacs-events--host-item' via session-id to that session's chat
;; buffer's dsh-emacs-queue-apply --- the mirror and the [next] preview row
;; update immediately; an inbox cell for another session (no open chat
;; buffer) is dropped instead of landing in whatever buffer happens to be
;; current.
(ert-deftest dsh-emacs-test-queue-queue-frame-dispatch-routes-to-chat ()
  :tags '(dsh-unit)
  (let* ((old-chats dsh-emacs--chat-buffers)
         (chat (get-buffer-create " *t-queue-dispatch*"))
         (proc (make-pipe-process :name "t-queue-proc" :buffer nil))
         (neutral (get-buffer-create " *t-queue-neutral*"))
         (paints nil))
    (unwind-protect
        (progn
          (setq dsh-emacs--chat-buffers
                (let ((h (make-hash-table :test 'equal)))
                  (puthash "sess-q" chat h)
                  h))
          (with-current-buffer chat
            (dsh-emacs-mode)
            (setq-local dsh-emacs--buffer-session "sess-q"))
          (with-current-buffer neutral (dsh-emacs-mode))
          (cl-letf (((symbol-function 'run-at-time)
                     (lambda (_delay _repeat fn) (push fn paints) t)))
            ;; An inbox item matching the session → routed to that session chat
            ;; buffer's queue-apply; after one redraw at burst end the preview row is
            ;; visible
            (dsh-emacs-events--host-item
             proc
             (list (cons 'type "projection")
                   (cons 'sessionId "sess-q")
                   (cons 'key "inbox")
                   (cons 'value
                         (list (cons 'next-turn
                                     (vector (dsh-emacs-test--inbox-message
                                              "q1" "dispatched")))
                               (cons 'next-step [])))))
            (funcall (car paints))
            (setq paints nil)
            (with-current-buffer chat
              (ert-info ((format "%s" "queue-frame-dispatch-routes-to-chat"))
                (should (= 1 (length dsh-emacs--queue-items)))
                (should (equal "dispatched"
                               (dsh-protocol-queue-item-text (car dsh-emacs--queue-items))))
                (should (dsh-test-composer-next-row))))
            ;; Another session's inbox cell (no open chat buffer) → dropped:
            ;; this mirror and preview row stay as they were, and the current
            ;; buffer does not silently adopt the foreign queue.
            (with-current-buffer neutral
              (dsh-emacs-events--host-item
               proc
               (list (cons 'type "projection")
                     (cons 'sessionId "sess-other")
                     (cons 'key "inbox")
                     (cons 'value
                           (list (cons 'next-turn
                                       (vector (dsh-emacs-test--inbox-message
                                                "o1" "foreign")))
                                 (cons 'next-step []))))))
            (with-current-buffer neutral
              (ert-info ((format "%s" "queue-frame-dispatch-foreign-cell-dropped"))
                (should (null dsh-emacs--queue-items))))
            (with-current-buffer chat
              (ert-info ((format "%s" "queue-frame-dispatch-filters-foreign-session"))
                (should (= 1 (length dsh-emacs--queue-items)))
                (should (equal "dispatched"
                               (dsh-protocol-queue-item-text (car dsh-emacs--queue-items))))
                (should (dsh-test-composer-next-row))))))
      (setq dsh-emacs--chat-buffers old-chats)
      (when (buffer-live-p chat) (kill-buffer chat))
      (when (buffer-live-p neutral) (kill-buffer neutral))
      (when (process-live-p proc) (delete-process proc)))))

;; JSON level: a real `/api/remote.mux' `item' frame carrying the `inbox'
;; projection cell (the exact 0.1.7 wire form, `next-turn'/'next-step' as
;; kebab-case JSON keys) reaches the mirror through the whole decode path —
;; json-read → alist → struct — so a field-name drift between host and
;; converter cannot pass unnoticed.
(ert-deftest dsh-emacs-test-queue-queue-inbox-json-frame-reaches-mirror ()
  :tags '(dsh-unit)
  (let* ((old-chats dsh-emacs--chat-buffers)
         (chat (get-buffer-create " *t-inbox-json*"))
         (proc (make-pipe-process :name "t-inbox-json-proc" :buffer nil)))
    (unwind-protect
        (progn
          (setq dsh-emacs--chat-buffers
                (let ((h (make-hash-table :test 'equal)))
                  (puthash "sess-json" chat h)
                  h))
          (with-current-buffer chat
            (dsh-emacs-mode)
            (setq-local dsh-emacs--buffer-session "sess-json"))
          (dsh-emacs-events--host-dispatch
           proc
           (concat "{\"type\":\"item\",\"streamId\":\"c1\",\"value\":{"
                   "\"type\":\"projection\",\"sessionId\":\"sess-json\","
                   "\"key\":\"inbox\",\"seq\":9,\"value\":{"
                   "\"next-turn\":[{\"id\":\"j1\",\"content\":[{\"type\":\"text\","
                   "\"text\":\"queued json\"}],\"source\":{\"kind\":\"user\","
                   "\"rpcId\":\"r1\"}}],"
                   "\"next-step\":[{\"id\":\"j2\",\"content\":[{\"type\":\"text\","
                   "\"text\":\"steer json\"}],\"source\":{\"kind\":\"user\"}}]}}}"))
          (with-current-buffer chat
            (ert-info ((format "%s" "queue-inbox-json-frame-reaches-mirror"))
              (should (equal '("j1" "j2")
                             (mapcar #'dsh-protocol-queue-item-id dsh-emacs--queue-items)))
              (should (equal '("queued json" "steer json")
                             (mapcar #'dsh-protocol-queue-item-text dsh-emacs--queue-items)))
              (should (equal '(queued steering)
                             (mapcar #'dsh-protocol-queue-item-placement
                                     dsh-emacs--queue-items))))))
      (setq dsh-emacs--chat-buffers old-chats)
      (when (buffer-live-p chat) (kill-buffer chat))
      (when (process-live-p proc) (delete-process proc)))))

;; next preview = the next item in the host's actual send order: in-flight
;; steering (next-step, injected into the running agent's next step) takes
;; precedence over queued (next-turn); context is host-injected content and
;; is never previewed. That is, "whichever one is steered, next shows that
;; one (when it becomes the next-step)"
(ert-deftest dsh-emacs-test-queue-queue-next-item-steering-led ()
  :tags '(dsh-unit)
  (let* ((steer-two (list (dsh-emacs-test--queue-item "a" "steering" "Alpha")
                          (dsh-emacs-test--queue-item "c" "steering" "Charlie")
                          (dsh-emacs-test--queue-item "b" "queued" "Beta")))
         (mixed (list (dsh-emacs-test--queue-item "a" "steering" "Alpha")
                      (dsh-emacs-test--queue-item "b" "queued" "Beta")))
         (queued-only (list (dsh-emacs-test--queue-item "b" "queued" "Beta")))
         (context-first (list (dsh-emacs-test--queue-item "x" "context" "X")
                              (dsh-emacs-test--queue-item "b" "queued" "Beta")
                              (dsh-emacs-test--queue-item "a" "steering" "Alpha"))))
    (let ((dsh-emacs--queue-items steer-two))
      (ert-info ((format "%s" "queue-next-item-steering-led"))
        (should (equal "Alpha" (dsh-protocol-queue-item-text
                                (dsh-emacs-queue-next-item))))))
    (let ((dsh-emacs--queue-items mixed))
      (ert-info ((format "%s" "queue-next-item-steering-over-queued"))
        (should (equal "Alpha" (dsh-protocol-queue-item-text
                                (dsh-emacs-queue-next-item))))))
    (let ((dsh-emacs--queue-items queued-only))
      (ert-info ((format "%s" "queue-next-item-falls-back-to-queued"))
        (should (equal "Beta" (dsh-protocol-queue-item-text
                               (dsh-emacs-queue-next-item))))))
    (let ((dsh-emacs--queue-items context-first))
      (ert-info ((format "%s" "queue-next-item-skips-context"))
        (should (equal "Alpha" (dsh-protocol-queue-item-text
                                (dsh-emacs-queue-next-item))))))
    (let ((dsh-emacs--queue-items nil))
      (ert-info ((format "%s" "queue-next-item-empty-nil"))
        (should (null (dsh-emacs-queue-next-item)))))))

;; The Next Message row mirrors the Goal Row's anatomy: its own queue-glyph
;; tint slot and the muted body tier the goal objective uses --- never the input
;; prompt's accent.  Both rows sit on the buffer background (postmortem/101,
;; postmortem/103).
(ert-deftest dsh-emacs-test-queue-composer-next-icon-is-chrome ()
  :tags '(dsh-unit)
  (let ((item (dsh-emacs-test--queue-item "a" "queued" "Alpha")))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
              ((symbol-function 'image-type-available-p) (lambda (_type) t))
              ((symbol-function 'create-image)
               (lambda (_data _type _data-p &rest props) (cons 'image props))))
      (let* ((row (dsh-emacs-composer--render-next-row item))
             (icon-faces (ensure-list (get-text-property 0 'face row)))
             (body-faces (ensure-list (get-text-property 3 'face row))))
        (ert-info ((format "%s" "composer-next-icon-is-chrome"))
          (should (string-prefix-p "   Alpha" (substring-no-properties row)))
          (should (eq 'image (car (get-text-property 0 'display row))))
          (should (equal '(dsh-emacs-composer-next-face) icon-faces))
          (should (equal '(dsh-emacs-composer-next-body-face) body-faces))
          (should (= 2 (string-width (dsh-emacs-composer--next-icon))))
          (should (null (memq 'dsh-emacs-input-prompt-face body-faces))))))
    (cl-letf (((symbol-function 'image-type-available-p) (lambda (_type) nil)))
      (let* ((row (dsh-emacs-composer--render-next-row item))
             (icon-faces (ensure-list (get-text-property 0 'face row))))
        (ert-info ((format "%s" "composer-next-text-fallback-is-chrome"))
          (should (string-prefix-p "≡  Alpha" (substring-no-properties row)))
          (should (= 2 (string-width (dsh-emacs-composer--next-icon))))
          (should (equal '(dsh-emacs-composer-next-face) icon-faces)))))))

;; The row carries a compact action cluster right after the text --- dsh web's
;; up arrow, edit and trash (`IconSendOutlineRegular'/`Edit'/`TrashOutline16'),
;; each cell holding its item so RET or a click runs the same queue verb the
;; `C-c C-q' manager binds to `s'/`e'/`d' (postmortem/101).
(ert-deftest dsh-emacs-test-queue-composer-next-cells-are-chrome ()
  :tags '(dsh-unit)
  (let ((item (dsh-emacs-test--queue-item "q1" "queued" "Alpha"))
        (sent nil)
        (edited nil)
        (deleted nil)
        (answer "Alpha fixed"))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
              ((symbol-function 'image-type-available-p) (lambda (_type) t))
              ((symbol-function 'create-image)
               (lambda (_data _type _data-p &rest props) (cons 'image props)))
              ((symbol-function 'read-string) (lambda (&rest _args) answer))
              ((symbol-function 'dsh-emacs-queue--send-now)
               (lambda (it) (setq sent it)))
              ((symbol-function 'dsh-emacs-queue--edit)
               (lambda (it text) (setq edited (list it text))))
              ((symbol-function 'dsh-emacs-queue--delete)
               (lambda (it) (setq deleted it))))
      (let* ((row (dsh-emacs-composer--render-next-row item))
             ;; One entry per cell: a cell's two columns share one keymap object.
             (cells nil)
             (prev nil))
        (cl-loop for i from 0 below (length row)
                 for map = (get-text-property i 'keymap row)
                 when map do
                 (unless (and prev (= i (1+ (car prev))) (eq map (cdr prev)))
                   (push (cons i map) cells))
                 (setq prev (cons i map)))
        (setq cells (nreverse cells))
        (let ((arrow (car cells))
              (edit (nth 1 cells))
              (delete (nth 2 cells)))
          (ert-info ((format "%s" "composer-next-cells-are-chrome"))
            (should (= 3 (length cells)))
            (should (= 3 (- (car edit) (car arrow))))
            (should (= 3 (- (car delete) (car edit))))
            (should (equal " " (substring-no-properties row (1- (car arrow)) (car arrow))))
            (should (equal "a" (substring-no-properties row (- (car arrow) 2)
                                                        (1- (car arrow)))))
            (should (equal (list "Send the next message now · steers into the running turn"
                                 "Edit queued message · C-c C-q e"
                                 "Delete queued message · C-c C-q d")
                           (mapcar (lambda (cell) (get-text-property (car cell) 'help-echo row))
                                   cells)))
            (should (cl-every (lambda (cell)
                                (and (eq 'dsh-emacs-composer-next-action-face
                                         (car (ensure-list
                                               (get-text-property (car cell) 'face row))))
                                     (eq 'highlight
                                         (get-text-property (car cell) 'mouse-face row))))
                              cells))
            (should (progn (call-interactively
                            (lookup-key (cdr arrow) (kbd "RET")))
                           (eq sent item)))
            (should (progn (call-interactively
                            (lookup-key (cdr edit) [mouse-1]))
                           (equal (list item "Alpha fixed") edited)))
            (should (progn (call-interactively
                            (lookup-key (cdr delete) (kbd "RET")))
                           (eq deleted item))))))
      ;; A blank answer leaves the queued text alone.
      (setq answer "   " edited nil)
      (let* ((row (dsh-emacs-composer--render-next-row item))
             (edit-pos (cl-loop for i from 0 below (length row)
                                when (equal "Edit queued message · C-c C-q e"
                                            (get-text-property i 'help-echo row))
                                return i)))
        (call-interactively (lookup-key (get-text-property edit-pos 'keymap row)
                                        (kbd "RET")))
        (ert-info ((format "%s" "composer-next-edit-ignores-blank-text"))
          (should (null edited))))
      ;; A message with a non-text block keeps the arrow and trash, not edit:
      ;; the edit RPC would replace its content with text.
      (let* ((row (dsh-emacs-composer--render-next-row
                   (dsh-emacs-test--queue-item "q1" "queued" "Alpha" nil t)))
             (helps (cl-loop for i from 0 below (length row)
                             for h = (get-text-property i 'help-echo row)
                             when (and h (string-match-p "queued message" h))
                             collect h)))
        (ert-info ((format "%s" "composer-next-edit-cell-needs-text-only-content"))
          (should (equal '("Delete queued message · C-c C-q d") (delete-dups helps)))))
      ;; Too narrow for the whole cluster: the tail yields first (delete, then
      ;; edit) while the arrow stays; narrower still drops every cell, leaving the
      ;; bare preview on the buffer background.
      (cl-letf (((symbol-function 'dsh-emacs-composer--row-width) (lambda () 18)))
        (let* ((row (dsh-emacs-composer--render-next-row item))
               (helps (cl-loop for i from 0 below (length row)
                               for h = (get-text-property i 'help-echo row)
                               when (and h (string-match-p "queued message" h))
                               collect h)))
          (ert-info ((format "%s" "composer-next-cluster-drops-from-the-tail"))
            (should (equal '("Edit queued message · C-c C-q e") (delete-dups helps)))
            (should (equal "Send the next message now · steers into the running turn"
                           (cl-loop for i from 0 below (length row)
                                    when (get-text-property i 'keymap row)
                                    return (get-text-property i 'help-echo row)))))))
      (cl-letf (((symbol-function 'dsh-emacs-composer--row-width) (lambda () 14)))
        (let ((row (dsh-emacs-composer--render-next-row item)))
          (ert-info ((format "%s" "composer-next-cells-yield-to-a-narrow-window"))
            (should (null (cl-find-if (lambda (i) (get-text-property i 'keymap row))
                                      (number-sequence 0 (1- (length row))))))
            (should (equal "   Alpha" (substring-no-properties row)))))))))

;; Inline send must not turn an attachment-bearing item into plain text while
;; idle.  Exercise the actual queue verb, mocking only the RPC/submit seams.
(ert-deftest dsh-emacs-test-queue-inline-idle-send-preserves-queued-attachments ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (setq-local dsh-emacs--buffer-session "inline-send")
    (let ((item (dsh-emacs-test--queue-item "image-q" "queued" "Look" nil t))
          (busy nil)
          calls submitted rejected)
      (cl-letf (((symbol-function 'dsh-emacs--busy-p) (lambda () busy))
                ((symbol-function 'dsh-emacs--rpc-async)
                 (lambda (method args callback)
                   (push (list method args) calls)
                   (funcall callback t nil)))
                ((symbol-function 'dsh-emacs--submit-plain)
                 (lambda (message &rest args)
                   (push (cons message args) submitted))))
        (setq dsh-emacs--queue-items (list item))
        (condition-case nil
            (call-interactively
             (lookup-key
              (get-text-property 0 'keymap
                                 (dsh-emacs-composer--next-cell item 'steer))
              (kbd "RET")))
          (user-error (setq rejected t)))
        (ert-info ((format "%s" "inline-idle-send-preserves-queued-attachments"))
          (should rejected)
          (should (null calls))
          (should (null submitted))
          (should (equal (list item) dsh-emacs--queue-items))
          (should (null dsh-emacs--queue-deleted)))
        (setq busy t calls nil submitted nil)
        (dsh-emacs-queue--send-now item)
        (ert-info ((format "%s" "inline-busy-send-steers-attachments-by-id"))
          (should (equal calls
                         '(("session/updateQueue"
                            ((request (sessionId . "inline-send") (itemId . "image-q")
                                      (action (kind . "steer"))))))))
          (should (null submitted)))
        (setq busy nil calls nil submitted nil
              item (dsh-emacs-test--queue-item "text-q" "queued" "Plain")
              dsh-emacs--queue-items (list item))
        (dsh-emacs-queue--send-now item)
        (ert-info ((format "%s" "inline-idle-send-submits-literal-text"))
          (should (equal submitted '(("Plain" :input-consumed t))))
          (should (equal calls
                         '(("session/updateQueue"
                            ((request (sessionId . "inline-send") (itemId . "text-q")
                                      (action (kind . "remove")))))))))))))

;; A queued item is a literal message: sending it now must not re-enter the
;; composer's input parsing.  A server-originated `!' line must stay text (the
;; client would otherwise run it locally), a queued `/name' line must not run
;; as a command, and none of them may consume the unrelated draft the user is
;; editing — the queue text never passes through the input area.
(ert-deftest dsh-emacs-test-queue-idle-send-now-bypasses-input-parsing ()
  :tags '(dsh-unit)
  (dolist (queued '("!echo pwned" "/compact" "plain queued text"))
    (with-temp-buffer
      (dsh-emacs-mode)
      (setq-local dsh-emacs--buffer-session "send-now")
      (dsh-emacs--replace-input "draft in progress")
      (let ((item (dsh-emacs-test--queue-item "q1" "queued" queued))
            (calls nil) (submitted nil) (shell nil) (commands nil))
        (cl-letf (((symbol-function 'dsh-emacs--busy-p) (lambda () nil))
                  ((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (method args callback)
                     (push (list method args) calls)
                     (funcall callback t nil)))
                  ((symbol-function 'dsh-emacs--submit-plain)
                   (lambda (message &rest args)
                     (push (cons message args) submitted)
                     ;; Mirror the real path's input consumption: a submit
                     ;; without :input-consumed wipes the draft, which is
                     ;; exactly the regression this test pins down.
                     (unless (plist-get args :input-consumed)
                       (dsh-emacs--clear-input))))
                  ((symbol-function 'dsh-emacs-shell-submit)
                   (lambda (&rest args) (push args shell)))
                  ((symbol-function 'dsh-emacs-command-execute)
                   (lambda (&rest args) (push args commands)))
                  ((symbol-function 'dsh-emacs--push-input-history) #'ignore)
                  ((symbol-function 'dsh-emacs-render-command-optimistic)
                   #'ignore))
          (setq dsh-emacs--queue-items (list item))
          (dsh-emacs-queue--send-now item)
          (ert-info ((concat "idle-send-now-literal-" queued))
            (should (null shell))
            (should (null commands))
            (should (equal submitted (list (cons queued '(:input-consumed t)))))
            (should (equal "draft in progress" (dsh-emacs--get-input)))
            (should (equal '("session/updateQueue")
                           (mapcar #'car calls)))))))))

;; The real submit path must leave the composer draft alone: send-now passes
;; :input-consumed t because the queue text never passed through the input area.
(ert-deftest dsh-emacs-test-queue-idle-send-now-keeps-the-current-draft ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (setq-local dsh-emacs--buffer-session "send-now-real"
                dsh-emacs--event-ready t)
    (dsh-emacs--replace-input "draft in progress")
    (let ((item (dsh-emacs-test--queue-item "q1" "queued" "queued work"))
          (prompts nil))
      (cl-letf (((symbol-function 'dsh-emacs--busy-p) (lambda () nil))
                ((symbol-function 'dsh-emacs--rpc-async)
                 (lambda (method args callback)
                   (when (equal method "session/prompt")
                     (push args prompts))
                   (funcall callback t nil)))
                ((symbol-function 'dsh-emacs--render-user-message-optimistic)
                 (lambda (&rest _) nil))
                ((symbol-function 'dsh-emacs--push-input-history) #'ignore)
                ((symbol-function 'dsh-emacs--ml-busy-set) #'ignore)
                ((symbol-function 'dsh-emacs-events--watchdog-start) #'ignore)
                ((symbol-function 'dsh-emacs-render--follow-stream) #'ignore))
        (setq dsh-emacs--queue-items (list item))
        (dsh-emacs-queue--send-now item)
        (ert-info ((concat "idle-send-now-keeps-draft"))
          (should (equal "draft in progress" (dsh-emacs--get-input)))
          (should (= 1 (length prompts))))))))

;; Child queues are read-only: the removal RPC must not run before the
;; capability check, or the item would leave the host queue with nothing sent.
(ert-deftest dsh-emacs-test-queue-send-now-rejects-subagent-before-removal ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (setq-local dsh-emacs--buffer-session "child"
                dsh-emacs--buffer-subagent 'dummy)
    (let ((item (dsh-emacs-test--queue-item "q1" "queued" "text"))
          (calls nil))
      (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                 (lambda (&rest args) (push args calls))))
        (setq dsh-emacs--queue-items (list item))
        (should-error (dsh-emacs-queue--send-now item) :type 'user-error)
        (ert-info ((concat "send-now-rejects-subagent-before-removal"))
          (should (null calls))
          (should (equal (list item) dsh-emacs--queue-items))
          (should (null dsh-emacs--queue-deleted)))))))

;; A projection replaces structs even when only placement changes.  The row's
;; arrow must run against the new placement in both directions.
(ert-deftest dsh-emacs-test-queue-inline-arrow-uses-current-placement-case ()
  :tags '(dsh-unit)
  (dolist (placement '("queued" "steering"))
    (with-temp-buffer
      (dsh-emacs-mode)
      (setq-local dsh-emacs--buffer-session "placement-chat")
      (let (calls)
        (cl-letf (((symbol-function 'dsh-emacs--busy-p) (lambda () t))
                  ((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (_method args _callback) (push args calls))))
          (setq dsh-emacs--queue-items
                (list (dsh-emacs-test--queue-item
                       "same-id" (if (equal placement "queued") "steering" "queued")
                       "Same text")))
          (dsh-emacs-composer-render)
          (setq dsh-emacs--queue-items
                (list (dsh-emacs-test--queue-item "same-id" placement "Same text")))
          (dsh-emacs-queue--refresh-ui)
          (let* ((row (dsh-test-composer-next-row))
                 (pos (text-property-not-all 0 (length row) 'keymap nil row)))
            (call-interactively (lookup-key (get-text-property pos 'keymap row)
                                            (kbd "RET"))))
          (ert-info ((format "%s" (format "inline-arrow-uses-current-placement-%s" placement)))
            (should (equal calls
                           (when (equal placement "queued")
                             '(((request (sessionId . "placement-chat")
                                         (itemId . "same-id")
                                         (action (kind . "steer"))))))))))))))

;; Optimistic previews have a local identity, not an actionable host item.
;; The host acknowledgement must restore the controls even for identical text.
(ert-deftest dsh-emacs-test-queue-inline-optimistic-preview-has-no-actions ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (setq-local dsh-emacs--buffer-session "optimistic-chat")
    (dsh-emacs-queue--optimistic-submit-show "Pending text")
    (let ((row (dsh-test-composer-next-row)))
      (ert-info ((format "%s" "inline-optimistic-preview-has-no-actions"))
        (should (string-match-p "Pending text" row))
        (should (null (text-property-not-all 0 (length row) 'keymap nil row)))))
    (dsh-emacs-queue-apply
     (current-buffer) 'test-process
     (list (dsh-emacs-test--queue-item "host-id" "queued" "Pending text")))
    (dsh-emacs-queue--refresh-ui)
    (let* ((row (dsh-test-composer-next-row))
           (pos (text-property-not-all 0 (length row) 'keymap nil row))
           calls)
      (cl-letf (((symbol-function 'dsh-emacs--busy-p) (lambda () t))
                ((symbol-function 'dsh-emacs--rpc-async)
                 (lambda (_method args _callback) (push args calls))))
        (when pos
          (call-interactively (lookup-key (get-text-property pos 'keymap row)
                                          (kbd "RET"))))
        (ert-info ((format "%s" "inline-confirmed-preview-acts-on-host-id"))
          (should (equal calls
                         '(((request (sessionId . "optimistic-chat")
                                     (itemId . "host-id") (action (kind . "steer"))))))))))))

;; Composer keeps its queue color and muted body tier without borrowing the
;; input prompt's accent.
(ert-deftest dsh-emacs-test-queue-composer-next-keeps-the-queue-colors ()
  :tags '(dsh-unit)
  (ert-info ((format "%s" "composer-next-keeps-the-queue-colors"))
    (should (equal (get 'dsh-emacs-composer-next-face 'face-defface-spec)
                   `((((background light)) :foreground ,dsh-emacs-color-queue)
                     (((background dark)) :foreground ,dsh-emacs-color-queue-dark)
                     (t :inherit warning))))))

(ert-deftest dsh-emacs-test-queue-composer-next-body-matches-the-goal-body-tier ()
  :tags '(dsh-unit)
  (ert-info ((format "%s" "composer-next-body-matches-the-goal-body-tier"))
    (should (eq (face-attribute 'dsh-emacs-composer-next-body-face :inherit)
                (face-attribute 'dsh-emacs-composer-goal-body-face :inherit)))))

;; Integration regression: after steering one item, the server first
;; pushes a remove frame (mirror cleared), then a next-step frame (the
;; entry returns as steering) --- in the host's send order the in-flight
;; steering is the next item, so after reinsert the next preview shows that
;; entry. Preview-row redraws are merged per frame burst (run-at-time 0):
;; when remove+reinsert land in the same burst only the final state is
;; drawn, and the momentary blank window caused by remove never appears on
;; screen.
(ert-deftest dsh-emacs-test-queue-queue-next-row-steer-before-shows-next ()
  :tags '(dsh-unit)
  (let ((buf (get-buffer-create " *t-queue-next-row-clear*"))
        (paints nil))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-mode)
          (cl-letf (((symbol-function 'run-at-time)
                     (lambda (_delay _repeat fn) (push fn paints) t))
                    ;; The echo self-clear timer goes through run-with-timer (internally
                    ;; also
                    ;; run-at-time), take it over as well so the flash closure does not mix
                    ;; into paints
                    ((symbol-function 'run-with-timer)
                     (lambda (&rest _) t)))
            ;; Burst 1: seed frame → one redraw at burst end
            (dsh-emacs-queue-apply
             buf 'proc
             (list (dsh-emacs-test--queue-item
                    "a" "queued" "Alpha")))
            (funcall (car paints))
            (setq paints nil)
            (ert-info ((format "%s" "queue-next-row-steer-before-shows-next"))
              (should (and (dsh-test-composer-next-row)
                           (let ((plain (substring-no-properties
                                         (dsh-test-composer-next-row))))
                             (and (string-search "Alpha" plain)
                                  ;; SVG available: the icon preview line starts with icon(space);
                                  ;; otherwise fall back to the text form
                                  (if (and (display-graphic-p)
                                           (image-type-available-p 'svg))
                                      (string-prefix-p " " plain)
                                    (string-search "≡" plain)))))))
            ;; Burst 2: remove frame (mirror cleared immediately, preview line not
            ;; redrawn yet) + steering regression frame
            (dsh-emacs-queue-apply buf 'proc nil)
            (ert-info ((format "%s" "queue-mirror-clears-on-steer-remove"))
              (should (null dsh-emacs--queue-items))
              (should (null (dsh-emacs-queue-next-item))))
            (dsh-emacs-queue-apply
             buf 'proc
             (list (dsh-emacs-test--queue-item
                    "a" "steering" "Alpha")))
            ;; Two frames combine into one redraw
            (ert-info ((format "%s" "queue-burst-remove-reinsert-single-paint"))
              (should (= 1 (length paints))))
            (funcall (car paints))
            (setq paints nil)
            (ert-info ((format "%s" "queue-next-row-steer-reinsert-shows-inflight"))
              (should (and (dsh-test-composer-next-row)
                           (string-search "Alpha"
                                          (substring-no-properties
                                           (dsh-test-composer-next-row))))))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

;; Flash regression: when the host splices in an item and instantly claims it
;; (item→empty two frames land in the same burst), the [next] preview line
;; must not hit the screen — the merged redraw only looks at the final mirror
;; after the burst ends (empty → no preview line).
;; Control: an item that truly stays (still present after the burst) → shown
;; normally after the redraw.
(ert-deftest dsh-emacs-test-queue-queue-burst-transient-single-paint-scheduled ()
  :tags '(dsh-unit)
  (let ((buf (get-buffer-create " *t-queue-burst*"))
        (paints nil))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-mode)
          (setq-local dsh-emacs--buffer-session "sess-burst")
          (cl-letf (((symbol-function 'run-at-time)
                     (lambda (_delay _repeat fn) (push fn paints) t))
                    ((symbol-function 'run-with-timer)
                     (lambda (&rest _) t)))
            ;; Same burst: enqueue frame + claim frame
            (dsh-emacs-queue-apply
             buf 'proc
             (list (dsh-emacs-test--queue-item
                    "b1" "queued" "bursty")))
            (dsh-emacs-queue-apply buf 'proc nil)
            (ert-info ((format "%s" "queue-burst-transient-single-paint-scheduled"))
              (should (= 1 (length paints))))
            (funcall (car paints))
            (setq paints nil)
            (ert-info ((format "%s" "queue-burst-claimed-item-never-paints"))
              (should (null (dsh-test-composer-next-row)))
              (should (null dsh-emacs--queue-items)))
            ;; Control: the item truly stays (still present after the burst) → the preview
            ;; line shows after the redraw
            (dsh-emacs-queue-apply
             buf 'proc
             (list (dsh-emacs-test--queue-item
                    "b2" "queued" "parked")))
            (funcall (car paints))
            (setq paints nil)
            (ert-info ((format "%s" "queue-burst-parked-item-paints"))
              (should (and (dsh-test-composer-next-row)
                           (string-search "parked"
                                          (substring-no-properties
                                           (dsh-test-composer-next-row))))))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

;; Deferred submit: mode resolution (explicit / behavior fallback) and the
;; payload mode field
(ert-deftest dsh-emacs-test-queue-queue-deferred-mode-resolution ()
  :tags '(dsh-unit)
  (let ((buf (get-buffer-create " *t-queue-deferred*"))
        (calls nil))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (setq-local dsh-emacs--buffer-session "sess-q")
            (setq dsh-emacs--input-marker nil))
          (let ((dsh-emacs-busy-enter-behavior 'queue))
            (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                       (lambda (method params _cb)
                         (push (list method params) calls))))
              ;; Explicit steer
              (with-current-buffer buf
                (dsh-emacs--submit-deferred "redirect now" :mode 'steer))
              ;; behavior=queue fallback
              (with-current-buffer buf
                (dsh-emacs--submit-deferred "line up"))
              (let ((dsh-emacs-busy-enter-behavior 'steer))
                (with-current-buffer buf
                  (dsh-emacs--submit-deferred "wake up")))
              (ert-info ((format "%s" "queue-deferred-mode-resolution"))
                (should (= 3 (length calls)))
                (should (equal "session/prompt" (car (nth 2 calls))))
                (should (equal "steer"
                               (cdr (assq 'mode
                                          (cdr (assq 'request (cadr (nth 2 calls))))))))
                (should (equal "queue"
                               (cdr (assq 'mode
                                          (cdr (assq 'request (cadr (nth 1 calls))))))))
                (should (equal "steer"
                               (cdr (assq 'mode
                                          (cdr (assq 'request (cadr (nth 0 calls)))))))))
              (ert-info ((format "%s" "queue-deferred-payload-shape"))
                (should (equal "sess-q"
                               (cdr (assq 'sessionId
                                          (cdr (assq 'request (cadr (nth 0 calls))))))))
                (should (equal "wake up"
                               (cdr (assq 'text
                                          (aref (cdr (assq 'content
                                                           (cdr (assq 'request
                                                                      (cadr (nth 0 calls))))))
                                                0)))))))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

;; C-c C-c dispatch: busy + behavior semantics (stop=interrupt, empty input
;; =interrupt, queue/steer=deferred submit)
(ert-deftest dsh-emacs-test-queue-send-or-stop-busy-queue-submits ()
  :tags '(dsh-unit)
  (let ((buf (get-buffer-create " *t-send-or-stop*"))
        (interrupted nil)
        (submitted nil))
    (unwind-protect
        (let ((dsh-emacs-busy-enter-behavior 'queue))
          (cl-letf (((symbol-function 'dsh-emacs-server-ensure) #'ignore)
                    ((symbol-function 'dsh-emacs--busy-p) (lambda (&rest _) t))
                    ((symbol-function 'dsh-emacs--get-input)
                     (lambda (&rest _) "the next thing"))
                    ((symbol-function 'dsh-emacs-interrupt-turn)
                     (lambda (&rest _) (setq interrupted t)))
                    ((symbol-function 'dsh-emacs--submit-prompt)
                     (lambda (message &optional _images mode)
                       (setq submitted (list message mode)))))
            ;; busy + queue + text → deferred submit (mode queue)
            (with-current-buffer buf
              (dsh-emacs-send-or-stop))
            (ert-info ((format "%s" "send-or-stop-busy-queue-submits"))
              (should (null interrupted))
              (should (equal '("the next thing" queue) submitted)))
            ;; C-u explicit steer
            (setq submitted nil current-prefix-arg '(4))
            (with-current-buffer buf
              (dsh-emacs-send-or-stop))
            (ert-info ((format "%s" "send-or-stop-prefix-steers-from-queue"))
              (should (equal '("the next thing" steer) submitted)))
            ;; With the default steer, C-u is still steer and does not flip to queue
            (setq submitted nil)
            (let ((dsh-emacs-busy-enter-behavior 'steer))
              (with-current-buffer buf
                (dsh-emacs-send-or-stop)))
            (ert-info ((format "%s" "send-or-stop-prefix-steers-from-steer"))
              (should (equal '("the next thing" steer) submitted)))
            ;; busy + empty input → interrupt
            (setq submitted nil current-prefix-arg nil)
            (cl-letf (((symbol-function 'dsh-emacs--get-input)
                       (lambda (&rest _) "")))
              (with-current-buffer buf
                (dsh-emacs-send-or-stop)))
            (ert-info ((format "%s" "send-or-stop-busy-empty-interrupts"))
              (should interrupted)
              (should (null submitted)))
            ;; behavior=stop → interrupt (byte-level legacy behavior)
            (setq interrupted nil submitted nil)
            (let ((dsh-emacs-busy-enter-behavior 'stop)
                  (current-prefix-arg nil))
              (with-current-buffer buf
                (dsh-emacs-send-or-stop)))
            (ert-info ((format "%s" "send-or-stop-stop-behavior-interrupts"))
              (should interrupted)
              (should (null submitted)))
            ;; Even with the default stop, C-u is still explicit steer
            (setq interrupted nil submitted nil current-prefix-arg '(4))
            (let ((dsh-emacs-busy-enter-behavior 'stop))
              (with-current-buffer buf
                (dsh-emacs-send-or-stop)))
            (ert-info ((format "%s" "send-or-stop-prefix-steers-from-stop"))
              (should (null interrupted))
              (should (equal '("the next thing" steer) submitted)))
            ;; Even when local busy state has not lit up yet, C-u is still explicit steer:
            ;; it must not degrade to a plain queue submit (which would also wrongly
            ;; optimistically render the user line).
            (setq interrupted nil submitted nil)
            (cl-letf (((symbol-function 'dsh-emacs--busy-p) (lambda (&rest _) nil)))
              (with-current-buffer buf
                (dsh-emacs-send-or-stop)))
            (ert-info ((format "%s" "send-or-stop-prefix-steers-when-local-idle"))
              (should (null interrupted))
              (should (equal '("the next thing" steer) submitted)))
            ;; idle + no prefix → plain submit (no mode)
            (setq submitted nil current-prefix-arg nil)
            (cl-letf (((symbol-function 'dsh-emacs--busy-p) (lambda (&rest _) nil)))
              (with-current-buffer buf
                (dsh-emacs-send-or-stop)))
            (ert-info ((format "%s" "send-or-stop-idle-submits-plain"))
              (should (null interrupted))
              (should (equal '("the next thing" nil) submitted)))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

;; The core session-status projection can lead the chat's turn/start frame.
;; Plain C-c C-c must honor that authoritative running bit instead of taking
;; the optimistic plain-submit path and rendering a premature user row.
(ert-deftest dsh-emacs-test-queue-send-or-stop-host-running-uses-deferred-queue ()
  :tags '(dsh-unit)
  (let ((buf (get-buffer-create " *t-send-host-running*"))
        (submitted nil)
        (dsh-emacs--sessions
         (dsh-emacs-test--session-items
          '(((sessionId . "host-running") (running . t))))))
    (unwind-protect
        (cl-letf (((symbol-function 'dsh-emacs-server-ensure) #'ignore)
                  ((symbol-function 'dsh-emacs--get-input)
                   (lambda () "queue behind host turn"))
                  ((symbol-function 'dsh-emacs--submit-prompt)
                   (lambda (message &optional _images mode)
                     (setq submitted (list message mode)))))
          (with-current-buffer buf
            (setq-local dsh-emacs--buffer-session "host-running"
                        dsh-emacs--ml-busy nil)
            (let ((current-prefix-arg nil)
                  (dsh-emacs-busy-enter-behavior 'queue))
              (dsh-emacs-send-or-stop)))
          (ert-info ((format "%s" "send-or-stop-host-running-uses-deferred-queue"))
            (should (equal '("queue behind host turn" queue) submitted))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

;; updateQueue action: wire shape of remove/steer/edit
(ert-deftest dsh-emacs-test-queue-queue-update-wire-actions ()
  :tags '(dsh-unit)
  (let ((buf (get-buffer-create " *t-queue-actions*"))
        (calls nil))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (setq-local dsh-emacs--buffer-session "sess-a")
            (let ((item (dsh-emacs-test--queue-item "it1" "queued" "x")))
              (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                         (lambda (method params _cb)
                           (push (list method params) calls))))
                (dsh-emacs-queue--delete item)
                (dsh-emacs-queue--steer item)
                (dsh-emacs-queue--edit item "rewritten")
                (dsh-emacs-queue--edit item "")
                (let ((ordered (nreverse (copy-sequence calls))))
                  (ert-info ((format "%s" "queue-update-wire-actions"))
                    (should (= 4 (length ordered)))
                    (should
                     (equal
                      ordered
                      '(("session/updateQueue"
                         ((request (sessionId . "sess-a") (itemId . "it1")
                                   (action (kind . "remove")))))
                        ("session/updateQueue"
                         ((request (sessionId . "sess-a") (itemId . "it1")
                                   (action (kind . "steer")))))
                        ("session/updateQueue"
                         ((request (sessionId . "sess-a") (itemId . "it1")
                                   (action (kind . "edit")
                                           (content . [((type . "text")
                                                        (text . "rewritten"))])))))
                        ("session/updateQueue"
                         ((request (sessionId . "sess-a") (itemId . "it1")
                                   (action (kind . "edit")
                                           (content . [((type . "text")
                                                        (text . ""))])))))))))))))
          ;; Rollback on failed delete: consumption feedback is not swallowed
          (with-current-buffer buf
            (setq dsh-emacs--queue-deleted '("it1"))
            (let ((item (dsh-emacs-test--queue-item "it1" "queued" "x")))
              (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                         (lambda (_method _params cb) (funcall cb nil '((code . "x"))))))
                (dsh-emacs-queue--delete item))
              (ert-info ((format "%s" "queue-delete-rollback-on-error"))
                (should (null dsh-emacs--queue-deleted))))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

;; A successful local operation optimistically updates the mirror: steer is
;; visible immediately (placement → steering + deleted suppresses the temporary
;; remove frame), without waiting for the session/queue frame round trip
(ert-deftest dsh-emacs-test-queue-queue-steer-before-success-unchanged ()
  :tags '(dsh-unit)
  (let ((buf (get-buffer-create " *t-queue-steer-opt*")))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-mode)
          (setq-local dsh-emacs--buffer-session "sess-opt")
          (setq dsh-emacs--queue-items
                (list (dsh-emacs-test--queue-item "o1" "queued" "origin")))
          (let ((cb nil))
            (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                       (lambda (_method _params callback) (setq cb callback))))
              (dsh-emacs-queue--steer (car dsh-emacs--queue-items))
              (ert-info ((format "%s" "queue-steer-before-success-unchanged"))
                (should (eq 'queued (dsh-protocol-queue-item-placement
                                     (car dsh-emacs--queue-items)))))
              (funcall cb t nil)
              (ert-info ((format "%s" "queue-steer-success-marks-steering-optimistically"))
                (should (eq 'steering (dsh-protocol-queue-item-placement
                                       (car dsh-emacs--queue-items))))
                (should (member "o1" dsh-emacs--queue-deleted))))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

;; Edit succeeds: mirror text optimistically replaced, prefix preview immediately
;; reflects the new text
(ert-deftest dsh-emacs-test-queue-queue-edit-success-updates-text-optimistically ()
  :tags '(dsh-unit)
  (let ((buf (get-buffer-create " *t-queue-edit-opt*")))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-mode)
          (setq-local dsh-emacs--buffer-session "sess-opt")
          (setq dsh-emacs--queue-items
                (list (dsh-emacs-test--queue-item "o2" "queued" "old text")))
          (let ((cb nil))
            (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                       (lambda (_method _params callback) (setq cb callback))))
              (dsh-emacs-queue--edit (car dsh-emacs--queue-items) "new text")
              (funcall cb t nil)
              (ert-info ((format "%s" "queue-edit-success-updates-text-optimistically"))
                (should (equal "new text"
                               (dsh-protocol-queue-item-text
                                (car dsh-emacs--queue-items))))))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

;; Delete succeeds: the entry is removed from the mirror immediately
(ert-deftest dsh-emacs-test-queue-queue-delete-success-removes-optimistically ()
  :tags '(dsh-unit)
  (let ((buf (get-buffer-create " *t-queue-delete-opt*")))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-mode)
          (setq-local dsh-emacs--buffer-session "sess-opt")
          (setq dsh-emacs--queue-items
                (list (dsh-emacs-test--queue-item "o3" "queued" "gone")))
          (let ((cb nil))
            (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                       (lambda (_method _params callback) (setq cb callback))))
              (dsh-emacs-queue--delete (car dsh-emacs--queue-items))
              (funcall cb t nil)
              (ert-info ((format "%s" "queue-delete-success-removes-optimistically"))
                (should (null dsh-emacs--queue-items))))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

;; User-visible contract regression: successful steer/delete optimistically
;; refreshes the [next] prefix (without waiting for the session/queue frame)
;; — the mirror is only necessary, not sufficient; assert directly that the
;; input-line prefix text changed.
;; In host send order: steer the second entry → next immediately shows the
;; steered one (in-flight steering leads queued); after that entry is consumed
;; it falls back to the queue head; delete the queue head → moves to the next
;; item; delete all → cleared; steer the queue head → the text stays the head
;; (it is the next one).
(ert-deftest dsh-emacs-test-queue-queue-next-row-optimistic-steer-second-flips ()
  :tags '(dsh-unit)
  (let ((buf (get-buffer-create " *t-prefix-opt-steer*"))
        (calls nil))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-mode)
          (setq-local dsh-emacs--buffer-session "sess-pfx")
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (_method _params callback) (push callback calls))))
            (dsh-emacs-queue-apply
             buf 'proc
             (list (dsh-emacs-test--queue-item "p1" "queued" "First")
                   (dsh-emacs-test--queue-item "p2" "queued" "Second")))
            ;; steer the second entry (not the queue head): next immediately flips to the
            ;; steered Second
            (let ((item (cl-find "p2" dsh-emacs--queue-items
                                 :key (lambda (i) (dsh-protocol-queue-item-id i))
                                 :test #'string=)))
              (dsh-emacs-queue--steer item)
              (let ((cb (car calls))) (setq calls (cdr calls)) (funcall cb t nil)))
            (ert-info ((format "%s" "queue-next-row-optimistic-steer-second-flips"))
              (should (and (dsh-test-composer-next-row)
                           (string-search "Second"
                                          (substring-no-properties (dsh-test-composer-next-row)))
                           (not (string-search "First"
                                               (substring-no-properties
                                                (dsh-test-composer-next-row)))))))
            ;; That in-flight entry is consumed (deleted): next falls back to the queue head
            ;; First
            (let ((item (cl-find "p2" dsh-emacs--queue-items
                                 :key (lambda (i) (dsh-protocol-queue-item-id i))
                                 :test #'string=)))
              (dsh-emacs-queue--delete item)
              (let ((cb (car calls))) (setq calls (cdr calls)) (funcall cb t nil)))
            (ert-info ((format "%s" "queue-next-row-optimistic-steered-consumed-falls-back"))
              (should (and (dsh-test-composer-next-row)
                           (string-search "First"
                                          (substring-no-properties (dsh-test-composer-next-row)))
                           (not (string-search "Second"
                                               (substring-no-properties
                                                (dsh-test-composer-next-row)))))))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest dsh-emacs-test-queue-queue-next-row-optimistic-delete-first-flips ()
  :tags '(dsh-unit)
  (let ((buf (get-buffer-create " *t-prefix-opt-delete*"))
        (calls nil))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-mode)
          (setq-local dsh-emacs--buffer-session "sess-pfx")
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (_method _params callback) (push callback calls))))
            (dsh-emacs-queue-apply
             buf 'proc
             (list (dsh-emacs-test--queue-item "p3" "queued" "Third")
                   (dsh-emacs-test--queue-item "p4" "queued" "Fourth")))
            (let ((item (cl-find "p3" dsh-emacs--queue-items
                                 :key (lambda (i) (dsh-protocol-queue-item-id i))
                                 :test #'string=)))
              (dsh-emacs-queue--delete item)
              (let ((cb (car calls))) (setq calls (cdr calls)) (funcall cb t nil)))
            (ert-info ((format "%s" "queue-next-row-optimistic-delete-first-flips"))
              (should (and (dsh-test-composer-next-row)
                           (string-search "Fourth"
                                          (substring-no-properties (dsh-test-composer-next-row)))
                           (not (string-search "Third"
                                               (substring-no-properties
                                                (dsh-test-composer-next-row)))))))
            (let ((item (cl-find "p4" dsh-emacs--queue-items
                                 :key (lambda (i) (dsh-protocol-queue-item-id i))
                                 :test #'string=)))
              (dsh-emacs-queue--delete item)
              (let ((cb (car calls))) (setq calls (cdr calls)) (funcall cb t nil)))
            (ert-info ((format "%s" "queue-next-row-optimistic-delete-only-clears"))
              (should (null (dsh-test-composer-next-row))))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest dsh-emacs-test-queue-queue-next-row-optimistic-steer-head-keeps-head ()
  :tags '(dsh-unit)
  (let ((buf (get-buffer-create " *t-prefix-opt-head*"))
        (calls nil))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-mode)
          (setq-local dsh-emacs--buffer-session "sess-pfx")
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (_method _params callback) (push callback calls))))
            (dsh-emacs-queue-apply
             buf 'proc
             (list (dsh-emacs-test--queue-item "p5" "queued" "Fifth")
                   (dsh-emacs-test--queue-item "p6" "queued" "Sixth")))
            (let ((item (cl-find "p5" dsh-emacs--queue-items
                                 :key (lambda (i) (dsh-protocol-queue-item-id i))
                                 :test #'string=)))
              (dsh-emacs-queue--steer item)
              (let ((cb (car calls))) (setq calls (cdr calls)) (funcall cb t nil)))
            ;; steer the queue head: next stays the queue head (it is the host's next one,
            ;; just changed to in-flight state)
            (ert-info ((format "%s" "queue-next-row-optimistic-steer-head-keeps-head"))
              (should (and (dsh-test-composer-next-row)
                           (string-search "Fifth"
                                          (substring-no-properties (dsh-test-composer-next-row)))
                           (not (string-search "Sixth"
                                               (substring-no-properties
                                                (dsh-test-composer-next-row)))))))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

;; Queue manager: a single C-g at any layer exits cleanly (no residue, no error)
(ert-deftest dsh-emacs-test-queue-queue-manager-one-c-g-cancels ()
  :tags '(dsh-unit)
  (let ((buf (get-buffer-create " *t-queue-quit*"))
        (completed nil))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (dsh-emacs-mode)
            (setq-local dsh-emacs--buffer-session "sess-q")
            (setq dsh-emacs--queue-items
                  (list (dsh-emacs-test--queue-item "i1" "queued" "one"))))
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (&rest _) (signal 'quit nil))))
            (with-current-buffer buf
              (condition-case nil
                  (progn (dsh-emacs-list-queue) (setq completed t))
                ((error quit) (setq completed nil)))))
          (ert-info ((format "%s" "queue-manager-one-c-g-cancels"))
            (should completed)))
      (when (buffer-live-p buf) (kill-buffer buf)))))

;; Queue menu: menu keys act on entry resolution (vertico highlight > typed
;; exact/prefix > queue-head fallback)
(ert-deftest dsh-emacs-test-queue-queue-menu-item-resolves-first ()
  :tags '(dsh-unit)
  (let* ((a (dsh-emacs-test--queue-item "a" "queued" "fix the bug"))
         (b (dsh-emacs-test--queue-item "b" "steering" "steered now"))
         (table (list (cons "[Q] fix the bug" a)
                      (cons "[S] steered now" b)))
         (dsh-emacs--queue-pick-table table))
    (cl-letf (((symbol-function 'minibuffer-contents)
               (lambda () "fix")))
      (ert-info ((format "%s" "queue-menu-item-resolves-first"))
        (should (equal a (dsh-emacs-queue--menu-item)))))
    (cl-letf (((symbol-function 'minibuffer-contents)
               (lambda () "[S] steered now")))
      (ert-info ((format "%s" "queue-menu-item-resolves-typed"))
        (should (equal b (dsh-emacs-queue--menu-item)))))
    (cl-letf (((symbol-function 'minibuffer-contents)
               (lambda () "")))
      (ert-info ((format "%s" "queue-menu-item-resolves-first-fallback"))
        (should (equal a (dsh-emacs-queue--menu-item)))))))

;; Queue menu: vertico highlight path — reads vertico--index/vertico--candidates
;; directly (the old accessor `vertico--current' no longer exists, and a string
;; assoc fails and falls back to the queue head, so the old implementation is
;; bound to fail). equal ignores text properties, so faces on candidates do not
;; affect matching
(ert-deftest dsh-emacs-test-queue-queue-menu-item-vertico-highlight-wins ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (let* ((vertico-mode t)
           (vertico--index 1)
           (vertico--candidates
            (list (propertize "[Q] fix the bug" 'face 'completions-common-part)
                  (propertize "[S] steered now" 'face 'vertico-current)))
           (a (dsh-emacs-test--queue-item "a" "queued" "fix the bug"))
           (b (dsh-emacs-test--queue-item "b" "steering" "steered now"))
           (dsh-emacs--queue-pick-table
            (list (cons "[Q] fix the bug" a) (cons "[S] steered now" b))))
      (cl-letf (((symbol-function 'minibuffer-contents) (lambda () "")))
        (ert-info ("queue-menu-item-vertico-highlight-wins")
          (should (equal b (dsh-emacs-queue--menu-item)))))
      (setq vertico--index 0)
      (ert-info ("queue-menu-item-vertico-index-0")
        (should (equal a (dsh-emacs-queue--menu-item)))))))

;; Queue menu command: actions are deferred via run-at-time until after the
;; minibuffer closes, then run in the chat buffer that opened the menu. In the
;; real environment exit-minibuffer is (throw 'exit nil), so code after exit in
;; the command never runs — actions must be scheduled as a timer before exit.
;; The test simulates the real throw (catch 'exit wraps the command), asserting
;; the RPC is not executed inline and can only fire via the deferred timer.
(ert-deftest dsh-emacs-test-queue-queue-menu-action-not-inline-after-exit ()
  :tags '(dsh-unit)
  (let ((calls nil)
        (deferred nil)
        (chat (generate-new-buffer " *t-queue-chat*"))
        (table (list (cons "[Q] first"
                           (dsh-emacs-test--queue-item "m1" "queued" "first"))
                     (cons "[Q] second"
                           (dsh-emacs-test--queue-item "m2" "queued" "second")))))
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer chat)
          (setq-local dsh-emacs--buffer-session "sess-q")
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method params _cb)
                       (let* ((req (cdr (assq 'request params)))
                              (action (cdr (assq 'action req))))
                         (push (list method
                                     (cdr (assq 'itemId req))
                                     (cdr (assq 'kind action)))
                               calls))))
                    ((symbol-function 'minibuffer-contents)
                     (lambda () ""))
                    ((symbol-function 'run-at-time)
                     (lambda (_delay _repeat fn) (push fn deferred)))
                    ((symbol-function 'minibuffer-selected-window)
                     (lambda () (selected-window))))
            (let ((dsh-emacs--queue-pick-table table))
              (catch 'exit
                (dsh-emacs-queue--menu-delete)))
            ;; exit already threw: the rest of the command is skipped, RPC not run inline
            (ert-info ((format "%s" "queue-menu-action-not-inline-after-exit"))
              (should (null calls)))
            ;; The action can only fire via the timer registered before exit
            (dolist (fn (nreverse deferred)) (funcall fn))
            (ert-info ((format "%s" "queue-menu-delete-runs-in-chat-buffer"))
              (should (equal '("session/updateQueue" "m1" "remove")
                             (car (nreverse calls)))))))
      (when (buffer-live-p chat) (kill-buffer chat)))))

;; x key deletes the whole queue: likewise register the timer first, then exit,
;; and RPC each entry one by one after confirmation
(ert-deftest dsh-emacs-test-queue-queue-delete-all-schedules-before-exit ()
  :tags '(dsh-unit)
  (let ((calls nil)
        (deferred nil)
        (chat (generate-new-buffer " *t-queue-chat*"))
        (table (list (cons "[Q] first"
                           (dsh-emacs-test--queue-item "x1" "queued" "first"))
                     (cons "[Q] second"
                           (dsh-emacs-test--queue-item "x2" "queued" "second")))))
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer chat)
          (setq-local dsh-emacs--buffer-session "sess-q")
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method params _cb)
                       (push (cdr (assq 'itemId
                                        (cdr (assq 'request params))))
                             calls)))
                    ((symbol-function 'y-or-n-p)
                     (lambda (_prompt) t))
                    ((symbol-function 'run-at-time)
                     (lambda (_delay _repeat fn) (push fn deferred)))
                    ((symbol-function 'minibuffer-selected-window)
                     (lambda () (selected-window))))
            (let ((dsh-emacs--queue-pick-table table))
              (catch 'exit
                (dsh-emacs-queue--menu-delete-all)))
            (ert-info ((format "%s" "queue-delete-all-schedules-before-exit"))
              (should (null calls)))
            (dolist (fn (nreverse deferred)) (funcall fn))
            (ert-info ((format "%s" "queue-delete-all-confirms-and-deletes-both"))
              (should (equal '("x1" "x2")
                             (sort (copy-sequence calls) #'string<))))))
      (when (buffer-live-p chat) (kill-buffer chat)))))

;; Queue menu key installation: question-isomorphic use-local-map (copy the
;; current local map + the single key)
(ert-deftest dsh-emacs-test-queue-queue-menu-keys-bound-via-local-map ()
  :tags '(dsh-unit)
  (let ((buf (get-buffer-create " *t-queue-keymap*")))
    (unwind-protect
        (with-current-buffer buf
          (use-local-map minibuffer-local-completion-map)
          (dsh-emacs-queue--chooser-setup-hook)
          (ert-info ((format "%s" "queue-menu-keys-bound-via-local-map"))
            (should (eq (key-binding (kbd "e")) #'dsh-emacs-queue--menu-edit))
            (should (eq (key-binding (kbd "s")) #'dsh-emacs-queue--menu-steer))
            (should (eq (key-binding (kbd "d")) #'dsh-emacs-queue--menu-delete))
            (should (eq (key-binding (kbd "x")) #'dsh-emacs-queue--menu-delete-all))
            (should (eq (key-binding (kbd "RET")) #'dsh-emacs-queue--menu-send))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(provide 'dsh-test-queue)
;;; dsh-test-queue.el ends here
