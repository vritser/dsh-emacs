;;; dsh-emacs-history.el --- Browse the chat transcript -*- lexical-binding: t; -*-

;; Copyright (C) 2025-2026
;; Author: dsh-emacs contributors
;; URL: https://github.com/vritser/dsh-emacs
;; Version: 0.7.0
;; License: GPL-3.0-or-later
;; Package-Requires: ((emacs "28.1"))

;;; Commentary:

;; Older-page loading and navigation share the rendered transcript.  Reading
;; positions belong to windows; pagination belongs to the session buffer.

;;; Code:

(require 'cl-lib)
(require 'dsh-emacs-server)
(require 'dsh-emacs-render)

(defvar dsh-emacs--buffer-session)
(defvar dsh-emacs--buffer-subagent)
(defvar dsh-emacs--input-marker)
(declare-function dsh-emacs--seed-input-history "dsh-emacs"
                  (events session-id &optional older))
(declare-function dsh-emacs--active-session-id "dsh-emacs" ())

(defun dsh-emacs-imenu-create-user-index ()
  "Build an Imenu index of loaded user questions.
Targets are advancing markers so a menu opened before an older page lands
still jumps to the original question.  Labels include line numbers to
identify repeated questions."
  (let (index)
    (save-excursion
      (goto-char (point-min))
      (while (< (point) (point-max))
        (when (get-text-property (point) 'dsh-emacs-user-message)
          (let* ((content (buffer-substring-no-properties
                           (point) (line-end-position)))
                 (preview (if (> (length content) 60)
                              (concat (substring content 0 57) "...")
                            content)))
            (push (cons (format "%d: %s" (line-number-at-pos) preview)
                        (copy-marker (point) t))
                  index)))
        (goto-char (next-single-property-change
                    (point) 'dsh-emacs-user-message nil (point-max)))))
    (nreverse index)))

(defun dsh-emacs-goto-latest ()
  "Return this window to the draft and resume following new output.
Other windows keep their reading positions; the draft is left untouched."
  (interactive)
  (unless (and (markerp dsh-emacs--input-marker)
               (marker-buffer dsh-emacs--input-marker))
    (user-error "This buffer has no chat input"))
  (goto-char (point-max))
  (recenter -1))

(defcustom dsh-emacs-history-window 30
  "Maximum messages per history request, including the opening snapshot.
Opening a fresh chat completes only the latest round;
`dsh-emacs-history-rounds' controls manual older-history loads.  Long rounds
are completed with additional bounded requests.  A smaller batch reduces
per-response parsing work but requires more network round trips."
  :type 'integer
  :group 'dsh-emacs)

(defcustom dsh-emacs-history-rounds 3
  "Number of complete earlier human rounds fetched by
`dsh-emacs-load-older-history'.  A human round is a turn containing a
user-authored message; child- and goal-woken turns belong to the human round
that preceded them.  A partially visible oldest round counts as the first
round to complete.
A prefix argument overrides this value for one load.  Opening a fresh chat
always completes only the latest round, independently of this option."
  :type 'natnum
  :group 'dsh-emacs)

(defvar-local dsh-emacs--history-loading nil
  "Current round-loading request plist, or nil.
Its `:token' cons distinguishes late callbacks from canceled or superseded
loads, so mutating the request plist in place cannot make an in-flight
response look current.")

(defun dsh-emacs--history-load-active-p (request)
  "Return non-nil while REQUEST is this buffer's current round load."
  (eq (plist-get request :token)
      (plist-get dsh-emacs--history-loading :token)))

(defun dsh-emacs--load-older-history-page (buffer page-value)
  "Prepend one older history page, described by PAGE-VALUE, to BUFFER.
Runs as the `session/page' callback: renders the page above the currently
loaded transcript, keeps the loaded window viewport in place, extends the
pagination frontier, and seeds `M-p' recall from the page's user messages."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq dsh-emacs--history-loading nil)
      (let* ((page (dsh-protocol--struct #'dsh-protocol-history-page-p
                                         #'dsh-protocol-history-page--from-alist
                                         page-value))
             (entries (dsh-protocol-history-page-records page))
             (rendered 0)
             (cursor (dsh-protocol-history-page-oldest page)))
        (when (and entries (integerp cursor))
          ;; The prepend marker must exist before the first render: every
          ;; renderer resolves its insertion position through it.  The page
          ;; sits below the live frontier, and the renderer leaves
          ;; `dsh-emacs--anchor-seq' alone for a prepend, so a live frame
          ;; cannot replay the loaded page.
          (setq dsh-emacs--history-insert-marker
                (dsh-emacs-render--history-prepend-marker))
          (let ((saved-point (copy-marker (point) t))
                (views (cl-loop
                        for window in (get-buffer-window-list buffer nil t)
                        collect (list window
                                      (copy-marker (window-start window) t)
                                      (copy-marker (window-point window) t)
                                      (window-vscroll window t)
                                      (window-hscroll window)))))
            (unwind-protect
                ;; Bind the page flag around the render: it is what tells the
                ;; renderers this batch is settled history (the insertion
                ;; marker is positional and may legitimately be nil).
                (let ((dsh-emacs--history-page t)
                      (dsh-emacs-ui--following-windows-function #'ignore))
                  (setq rendered
                        (dsh-emacs-render-history-events
                         entries nil dsh-emacs--history-earliest-seq
                         :insert-before
                         (and dsh-emacs--history-insert-marker
                              (marker-position dsh-emacs--history-insert-marker))
                         :follow-p nil)))
              ;; Insertion-type t keeps the old text even when a window starts
              ;; exactly at the prepend boundary.  Restore only views of this
              ;; buffer, without restoring the user's whole window layout.
              (goto-char saved-point)
              (set-marker saved-point nil)
              (pcase-dolist (`(,window ,start ,point ,vscroll ,hscroll) views)
                (when (and (window-live-p window)
                           (eq (window-buffer window) buffer))
                  (set-window-point window point)
                  (set-window-start window start t)
                  (set-window-vscroll window vscroll t)
                  (set-window-hscroll window hscroll))
                (set-marker start nil)
                (set-marker point nil))
              (when (markerp dsh-emacs--history-insert-marker)
                (set-marker dsh-emacs--history-insert-marker nil))
              (setq dsh-emacs--history-insert-marker nil))))
        (if (and entries (integerp cursor))
            (progn
              (setq dsh-emacs--history-earliest-seq cursor)
              (setq dsh-emacs--history-has-more
                    (dsh-protocol-history-page-has-more page))
              (dsh-emacs--seed-input-history
               entries (or dsh-emacs--buffer-session
                           (dsh-emacs--active-session-id)) t)
              (let ((rounds (dsh-protocol-history-page-rounds page)))
                (message "%s%s"
                         (cond
                          (rounds
                           (format "Loaded rounds %d–%d (%d round%s)"
                                   (caar rounds) (car (car (last rounds)))
                                   (length rounds)
                                   (if (= (length rounds) 1) "" "s")))
                          (dsh-emacs--history-has-more
                           (format "Loaded %d history event%s (no round boundaries)"
                                   rendered (if (= rendered 1) "" "s")))
                          (t "Beginning of history"))
                         (cond
                          (dsh-emacs--history-has-more
                           "; C-c C-o loads earlier rounds")
                          (rounds "; beginning of history")
                          (t "")))))
          (setq dsh-emacs--history-has-more nil)
          (message "No older messages remain"))))))

(defun dsh-emacs-history--fetch-rounds (buffer request)
  "Continue REQUEST until its complete human rounds are in BUFFER.
Stage records without changing the transcript or its pagination cursor;
failed, canceled and superseded requests can therefore be retried safely."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (dsh-emacs--history-load-active-p request)
        (message "Loading older rounds… %d/%d rounds ready; C-c C-o cancels"
                 (length (plist-get request :rounds))
                 (plist-get request :target))
        (condition-case err
            (dsh-emacs--rpc-async
             "session/page"
             (dsh-protocol-history-page-request
              (plist-get request :session) (plist-get request :address)
              (plist-get request :through) (plist-get request :before)
              (plist-get request :limit)
              (- (plist-get request :target)
                 (length (plist-get request :rounds))))
             (lambda (ok value)
               (when (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (when (dsh-emacs--history-load-active-p request)
                     (condition-case err
                         (dsh-emacs-history--consume-rounds-page
                          buffer request ok value)
                       (error
                        (setq dsh-emacs--history-loading nil)
                        (set-marker (plist-get request :point) nil)
                        (message "Could not load rounds: %s"
                                 (error-message-string err)))))))))
          (error
           (setq dsh-emacs--history-loading nil)
           (set-marker (plist-get request :point) nil)
           (message "Could not load rounds: %s"
                    (error-message-string err))))))))

(defun dsh-emacs-history--consume-rounds-page (buffer request ok value)
  "Consume one `session/page' VALUE for REQUEST in BUFFER.
Stage it and either fetch more until the human-round target is met or publish
the kept range.  Signals on transport, identity, ordering or budget errors."
  (unless (and ok (listp value))
    (error "History request failed: %s" (dsh-emacs-rpc-error-text value)))
  (unless (and (equal dsh-emacs--buffer-session (plist-get request :session))
               (equal dsh-emacs--buffer-subagent (plist-get request :address))
               (equal dsh-emacs--history-earliest-seq
                      (plist-get request :frontier)))
    (error "History changed while loading; retry from the current view"))
  (let* ((page (dsh-protocol-history-page--from-alist value))
         (records (dsh-protocol-history-page-records page))
         (oldest (dsh-protocol-history-page-oldest page))
         (newest (dsh-protocol-history-page-newest page))
         (more (dsh-protocol-history-page-has-more page))
         (all (append records (plist-get request :records)))
         (rounds (dsh-protocol-history-human-rounds all))
         (target (plist-get request :target)))
    (when (or (and more (null records))
              (and oldest (>= newest (plist-get request :before))))
      (error "History page did not move backwards"))
    (setf (plist-get request :records) all
          (plist-get request :rounds) rounds)
    (if (and more (< (length rounds) target))
        (progn
          (setf (plist-get request :before) oldest)
          (dsh-emacs-history--fetch-rounds buffer request))
      (dsh-emacs-history--publish-rounds-page
       buffer request page all rounds))))

(defun dsh-emacs-history--publish-rounds-page (buffer request page all rounds)
  "Publish the kept human ROUNDS from ALL records for REQUEST in BUFFER.
At most the requested number of human rounds is kept, and the page starts at
the oldest kept human round's `turn/start'; leading child or goal turns are
deferred to the next page."
  (let* ((target (plist-get request :target))
         (kept (if (>= (length rounds) target)
                   (last rounds target)
                 rounds))
         (start (car kept))
         (start-seq (and start (nth 1 start)))
         (start-record (and start (nth 2 start)))
         (trimmed (and start-record (memq start-record all)))
         (oldest (dsh-protocol-history-page-oldest page))
         (more (dsh-protocol-history-page-has-more page)))
    (when trimmed
      (setq more (or more (not (eq trimmed all)))
            all trimmed
            oldest start-seq))
    (let* ((window (plist-get request :window))
           (point (plist-get request :point))
           (visit (and (window-live-p window)
                       (eq window (selected-window))
                       (eq (window-buffer window) buffer)
                       (= (window-point window) point))))
      (dsh-emacs--load-older-history-page
       buffer
       (dsh-protocol--make-history-page
        :records all
        :oldest (or oldest (plist-get request :before))
        :has-more more
        :rounds kept))
      (when (and visit all)
        (push-mark (marker-position point) t)
        (when-let* ((start (dsh-emacs-render--history-prepend-marker)))
          (goto-char start)
          (recenter 0)
          (set-marker start nil)))
      (set-marker point nil))))

(defun dsh-emacs-load-older-history (&optional rounds)
  "Load ROUNDS complete earlier human rounds, default
`dsh-emacs-history-rounds'.  A human round is a turn containing a user-authored
message, so child- and goal-woken turns are loaded with the round that
preceded them.  With a prefix argument, use that many rounds.  A partial
oldest round counts as the first round to complete.  Long rounds are fetched
in bounded batches;
the transcript changes only when the requested range or session start is
reached.  Invoke again while loading to cancel without moving the cursor.
The initiating window visits the newly loaded range if its point has not
moved during the request; other windows retain their reading positions."
  (interactive (list (and current-prefix-arg
                          (prefix-numeric-value current-prefix-arg))))
  (cond
   ((not (bound-and-true-p dsh-emacs--buffer-session))
    (user-error "Older history is only available inside a chat buffer"))
   (dsh-emacs--history-loading
    (set-marker (plist-get dsh-emacs--history-loading :point) nil)
    (setq dsh-emacs--history-loading nil)
    (message "History loading canceled; no rounds added"))
   ((not (and (boundp 'dsh-emacs--input-marker)
              (markerp dsh-emacs--input-marker)))
    (message "This chat buffer has no transcript to extend"))
   ((null dsh-emacs--history-earliest-seq)
    (message "No earlier history is known for this session yet"))
   ((not dsh-emacs--history-has-more)
    (message "No older rounds remain"))
   ((null dsh-emacs--history-cursor)
    (message "This session has no history cursor yet"))
   (t
    (dsh-emacs-history--start-load (or rounds dsh-emacs-history-rounds) t))))

(defun dsh-emacs-history--start-load (count &optional visit)
  "Fetch COUNT complete rounds before this buffer's history frontier.
When VISIT is non-nil, visit the new range if the initiating window has not
moved.  Automatic opening loads leave all reading and draft positions alone."
  (unless (and (integerp count) (> count 0))
    (user-error "Round count must be a positive integer"))
  (unless (and (integerp dsh-emacs-history-window) (> dsh-emacs-history-window 0))
    (user-error "History batch size must be a positive integer"))
  (setq dsh-emacs--history-loading
        (list :token (list 'dsh-emacs-history-load)
              :target count :before dsh-emacs--history-earliest-seq
              :frontier dsh-emacs--history-earliest-seq
              :through dsh-emacs--history-cursor :session dsh-emacs--buffer-session
              :address dsh-emacs--buffer-subagent :limit dsh-emacs-history-window
              :point (copy-marker (point) t)
              :window (and visit (get-buffer-window (current-buffer) t))
              :records nil :rounds nil))
  (dsh-emacs-history--fetch-rounds (current-buffer) dsh-emacs--history-loading))

(provide 'dsh-emacs-history)
;;; dsh-emacs-history.el ends here
