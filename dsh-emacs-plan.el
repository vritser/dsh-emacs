;;; dsh-emacs-plan.el --- Plan documents and review actions -*- lexical-binding: t; -*-

;; Copyright (C) 2026
;; Author: dsh-emacs contributors
;; Version: 0.5.0
;; Package-Requires: ((emacs "27.1"))
;; License: GPL-3.0-or-later

;;; Commentary:
;; A plan is a document to read before answering its review request.  Pending
;; requests belong to their chat; document windows may be closed and reopened
;; independently.  All decisions use the existing question waterfall.

;;; Code:
(declare-function dsh-emacs-subagent-require "dsh-emacs-subagent"
                  (action &optional session-id))

(require 'cl-lib)
(require 'button)
(require 'dsh-emacs-faces)
(require 'dsh-emacs-protocol)
(require 'dsh-emacs-markdown)

(declare-function dsh-emacs--events-result-async "dsh-emacs"
                  (client-id event-id outcome callback))
(declare-function dsh-emacs-notify--post "dsh-emacs-render"
                  (session-id body &optional buffer))
(defvar dsh-emacs-events--client-id)

(defvar-local dsh-emacs-plan--pending nil
  "Pending review plists owned by this chat buffer.")
(defvar-local dsh-emacs-plan--chat nil
  "The chat owning this document buffer.")
(defvar-local dsh-emacs-plan--identity nil
  "Call id, or waterfall id for an unlogged plan, of this document.")
(defvar-local dsh-emacs-plan--text nil
  "Original Markdown of this document.")
(defvar-local dsh-emacs-plan--review nil
  "Review request associated with this document, including its final status.")

(defvar dsh-emacs-plan-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "C-c C-c") #'dsh-emacs-plan-approve)
    (define-key map (kbd "C-c C-k") #'dsh-emacs-plan-request-changes)
    (define-key map (kbd "C-c C-z") #'dsh-emacs-plan-back-to-chat)
    map)
  "Keymap for a submitted plan document.")

(define-derived-mode dsh-emacs-plan-mode special-mode "dsh Plan"
  "Read a submitted plan and explicitly approve it or request changes."
  (setq-local truncate-lines nil)
  (visual-line-mode 1))

(defun dsh-emacs-plan--title (text)
  "Return the first Markdown heading of TEXT, or a generic title."
  (if (string-match "^#+[ \t]+\\(.+\\)$" text)
      (string-trim (match-string 1 text))
    "Plan"))

(defun dsh-emacs-plan--button (button)
  "Run the document action stored on BUTTON."
  (call-interactively (button-get button 'dsh-emacs-plan--action)))

(defun dsh-emacs-plan--paint ()
  "Refresh document actions and Markdown, keeping the reader's position."
  (let ((inhibit-read-only t)
        (position (point))
        (review dsh-emacs-plan--review))
    (erase-buffer)
    (insert (propertize
             (concat "Plan · " (if review (plist-get review :status)
                                 "Submitted document"))
             'face 'dsh-emacs-meta-face)
            "\n\n")
    (when (and review (not (plist-get review :retired))
               (not (plist-get review :busy)))
      (insert-text-button "Approve and execute" 'follow-link t
                          'action #'dsh-emacs-plan--button
                          'dsh-emacs-plan--action #'dsh-emacs-plan-approve)
      (insert "    ")
      (insert-text-button "Request changes" 'follow-link t
                          'action #'dsh-emacs-plan--button
                          'dsh-emacs-plan--action #'dsh-emacs-plan-request-changes)
      (insert "    "))
    (insert-text-button "Back to chat" 'follow-link t
                        'action #'dsh-emacs-plan--button
                        'dsh-emacs-plan--action #'dsh-emacs-plan-back-to-chat)
    (insert "\n\n" (dsh-emacs-markdown-render dsh-emacs-plan--text))
    (goto-char (min position (point-max)))
    (set-buffer-modified-p nil)))

(defun dsh-emacs-plan--show (chat identity text &optional review)
  "Display CHAT's plan IDENTITY and TEXT, optionally with REVIEW actions."
  (let* ((review
          (or review
              (and (buffer-live-p chat)
                   (cl-find identity
                            (buffer-local-value 'dsh-emacs-plan--pending chat)
                            :key (lambda (item) (plist-get item :identity))
                            :test #'equal))))
         (buffer
          (or (cl-find-if
               (lambda (buffer)
                 (with-current-buffer buffer
                   (and (eq major-mode 'dsh-emacs-plan-mode)
                        (eq dsh-emacs-plan--chat chat)
                        (equal dsh-emacs-plan--identity identity))))
               (buffer-list))
              (generate-new-buffer
               (format "*dsh Plan: %s*" (dsh-emacs-plan--title text))))))
    (with-current-buffer buffer
      (unless (eq major-mode 'dsh-emacs-plan-mode)
        (dsh-emacs-plan-mode))
      (setq dsh-emacs-plan--chat chat
            dsh-emacs-plan--identity identity
            dsh-emacs-plan--text text)
      (when (buffer-live-p chat)
        (setq default-directory (buffer-local-value 'default-directory chat)))
      (when review
        (setq dsh-emacs-plan--review review)
        (setf (plist-get review :buffer) buffer))
      (dsh-emacs-plan--paint))
    (display-buffer buffer '(display-buffer-pop-up-window))
    buffer))

(defun dsh-emacs-plan-review ()
  "Reopen a pending plan review belonging to the current chat."
  (interactive)
  (let* ((chat (or dsh-emacs-plan--chat (current-buffer)))
         (pending (and (buffer-live-p chat)
                       (buffer-local-value 'dsh-emacs-plan--pending chat)))
         (review (car pending)))
    (unless review (user-error "No pending plan review in this chat"))
    (pop-to-buffer
     (dsh-emacs-plan--show
      chat (plist-get review :identity)
      (dsh-protocol-question-detail (plist-get review :question)) review))))

(defun dsh-emacs-plan-back-to-chat ()
  "Return to the plan's chat input without answering its review."
  (interactive)
  (unless (buffer-live-p dsh-emacs-plan--chat)
    (user-error "This plan's chat is closed"))
  (pop-to-buffer dsh-emacs-plan--chat)
  (goto-char (point-max)))

(defun dsh-emacs-plan--request (chat event-id session-id questions)
  "Handle a supported plan review from QUESTIONS; return nil for ordinary asks.
CHAT owns EVENT-ID from SESSION-ID.  Only the host's explicit intent opts a
single, non-multiple question into document review, just as in dsh Web.  A
plan-review intent whose shape the document interface cannot present reports
the fallback rather than silently reusing the question reader."
  (when (= (length questions) 1)
    (let* ((question (dsh-protocol--struct
                      #'dsh-protocol-question-p
                      #'dsh-protocol-question--from-alist (car questions)))
           (text (dsh-protocol-question-detail question))
           (approve (dsh-protocol-question-approve-label question))
           (options (dsh-protocol-question-options question)))
      (when (equal (dsh-protocol-question-intent-kind question) "plan-review")
        (if (not (and (stringp text) (not (string-empty-p (string-trim text)))
                      (stringp approve) (not (string-empty-p approve))
                      (<= (length options) 2)
                      (= (cl-count approve options
                                   :key #'dsh-protocol-question-option-label
                                   :test #'equal)
                         1)
                      (not (dsh-protocol-question-multi-select question))))
            (progn
              (message "Unsupported plan review shape; using the question reader")
              nil)
          (with-current-buffer chat
            (let* ((call-id (dsh-protocol-question-call-id question))
                   ;; An absent or empty call id is no identity: fall back to
                   ;; the waterfall id rather than colliding every document.
                   (identity (if (and (stringp call-id)
                                      (not (string-empty-p call-id)))
                                 call-id
                               event-id))
                   (existing (cl-find identity dsh-emacs-plan--pending
                                      :key (lambda (item)
                                             (plist-get item :identity))
                                      :test #'equal)))
              (cond
               ;; The host re-issued the waterfall for the same submitted
               ;; document: move the single pending request onto the newest
               ;; event id so a decision (or retry) targets the live
               ;; waterfall.
               ((and existing
                     (not (equal event-id (plist-get existing :event-id))))
                (setf (plist-get existing :event-id) event-id
                      (plist-get existing :question) question
                      (plist-get existing :client-id)
                      dsh-emacs-events--client-id
                      (plist-get existing :status) "Pending review")
                (dsh-emacs-plan--show chat identity text existing))
               ;; The same waterfall replayed: keep the request as it is.
               (existing nil)
               (t
                (let ((review (list :chat chat :event-id event-id
                                    :identity identity :question question
                                    :client-id dsh-emacs-events--client-id
                                    :status "Pending review" :busy nil
                                    :retired nil :expired nil :buffer nil)))
                  (push review dsh-emacs-plan--pending)
                  (add-hook 'kill-buffer-hook
                            #'dsh-emacs-plan--chat-closed nil t)
                  (add-hook 'change-major-mode-hook
                            #'dsh-emacs-plan--chat-closed nil t)
                  (dsh-emacs-plan--show chat identity text review)
                  (dsh-emacs-notify--post
                   session-id
                   (concat "Plan ready: " (dsh-emacs-plan--title text))
                   chat))))))
          t)))))

(defun dsh-emacs-plan--retire (review status)
  "Retire REVIEW with STATUS while keeping its readable document."
  (setf (plist-get review :retired) t
        (plist-get review :busy) nil
        (plist-get review :status) status)
  (let ((chat (plist-get review :chat))
        (buffer (plist-get review :buffer)))
    (when (buffer-live-p chat)
      (with-current-buffer chat
        (setq dsh-emacs-plan--pending (delq review dsh-emacs-plan--pending))))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (eq dsh-emacs-plan--review review)
          (dsh-emacs-plan--paint))))))

(defun dsh-emacs-plan--cancel (&optional event-id)
  "Retire EVENT-ID, or all plan reviews when the connection is retired."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (dolist (review (copy-sequence dsh-emacs-plan--pending))
        (when (or (null event-id)
                  (equal event-id (plist-get review :event-id)))
          (unless event-id (setf (plist-get review :expired) t))
          (dsh-emacs-plan--retire
           review (if event-id "Review closed" "Disconnected — review expired")))))))

(defun dsh-emacs-plan--chat-closed ()
  "Hand pending reviews back to the host when their chat is closed.
A review whose decision is already on the wire is retired without a handoff:
its own outcome answers the waterfall."
  (dolist (review (copy-sequence dsh-emacs-plan--pending))
    (let ((busy (plist-get review :busy)))
      (setf (plist-get review :expired) t)
      (dsh-emacs-plan--retire review "Chat closed — review expired")
      (when (and (not busy)
                 (equal (plist-get review :client-id)
                        dsh-emacs-events--client-id))
        (dsh-emacs--events-result-async
         (plist-get review :client-id) (plist-get review :event-id)
         '((kind . "next"))
         (lambda (ok value)
           (unless ok (message "Plan handoff failed: %s" value))))))))

(defun dsh-emacs-plan--answer (approve)
  "Answer this document's live request; APPROVE nil requests changes."
  (let* ((review dsh-emacs-plan--review)
         (chat (plist-get review :chat))
         (client (plist-get review :client-id)))
    (unless (and review (not (plist-get review :retired))
                 (buffer-live-p chat)
                 (memq review (buffer-local-value 'dsh-emacs-plan--pending chat))
                 client (equal client dsh-emacs-events--client-id))
      (user-error "This plan review is no longer pending"))
    (with-current-buffer chat (dsh-emacs-subagent-require 'mutate))
    (when (plist-get review :busy)
      (user-error "A plan decision is already being sent"))
    (setf (plist-get review :busy) t
          (plist-get review :status) "Sending decision…")
    (dsh-emacs-plan--paint)
    (let* ((question (plist-get review :question))
           (outcome
            (if approve
                `((kind . "result")
                  (value . ((answers .
                                     [((id . ,(dsh-protocol-question-id question))
                                       (selected .
                                                 [,(dsh-protocol-question-approve-label
                                                    question)]))]))))
              '((kind . "rejected")
                (error . ((name . "cancelled")
                          (message . "User requested plan changes"))))))
           (done
            (lambda (ok value)
              (when (and (buffer-live-p chat)
                         (not (plist-get review :expired))
                         (equal client dsh-emacs-events--client-id))
                (if ok
                    (progn
                      (dsh-emacs-plan--retire
                       review (if approve "Approved" "Changes requested"))
                      (unless approve
                        (pop-to-buffer chat)
                        (goto-char (point-max))
                        (message "Describe the changes in the chat input")))
                  (unless (plist-get review :retired)
                    (setf (plist-get review :busy) nil
                          (plist-get review :status)
                          (format "Decision failed: %s" value))
                    (when (buffer-live-p (plist-get review :buffer))
                      (with-current-buffer (plist-get review :buffer)
                        (dsh-emacs-plan--paint))))
                  (message "Plan decision failed: %s" value))))))
      (condition-case err
          (dsh-emacs--events-result-async
           client (plist-get review :event-id) outcome done)
        (error (funcall done nil (error-message-string err)))))))

(defun dsh-emacs-plan-approve ()
  "Approve the displayed plan and let the agent begin implementation."
  (interactive)
  (dsh-emacs-plan--answer t))

(defun dsh-emacs-plan-request-changes ()
  "Dismiss plan review and return to chat to write feedback."
  (interactive)
  (dsh-emacs-plan--answer nil))

(provide 'dsh-emacs-plan)
;;; dsh-emacs-plan.el ends here
