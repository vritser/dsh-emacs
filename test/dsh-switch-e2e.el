;;; dsh-switch-e2e.el --- Manual dual-service acceptance -*- lexical-binding: t; -*-
;; Package-Requires: ((emacs "28.1"))
;;; Commentary:
;; Use two disposable services: this creates an empty session on each visit.
;; Set DSH_URL_A, DSH_TOKEN_A, DSH_URL_B, DSH_TOKEN_B in the environment.
;; Run: emacs -Q --batch -L . -l test/dsh-switch-e2e.el
;; No provider credentials or model requests are needed; servers are not stopped.
;;; Code:
(require 'dsh-emacs)
(dolist (name '("DSH_URL_A" "DSH_URL_B"))
  (unless (getenv name) (error "Set %s to a disposable test service" name)))
(setq dsh-emacs-server-auto-start nil dsh-emacs-server-start-on-init nil)
(defun dsh-switch-e2e--wait (predicate)
  (let ((deadline (+ (float-time) 15)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (unless (funcall predicate) (error "Lifecycle wait timed out: %S" (dsh-emacs-connection-state)))))
(let ((origin (generate-new-buffer " *lifecycle-owner*")) old-chat old-generation)
  (unwind-protect
      (with-current-buffer origin
        (dolist (suffix '("A" "B" "A"))
          (let (completed outcome)
            (dsh-emacs-connect (getenv (concat "DSH_URL_" suffix))
                               :token (getenv (concat "DSH_TOKEN_" suffix))
                               :callback (lambda (ok result)
                                           (setq outcome (cons ok result) completed t)))
            (dsh-switch-e2e--wait (lambda () completed))
            (unless (car outcome) (error "Connect failed: %S" outcome))
            (unless (eq (plist-get (dsh-emacs-session-snapshot) :status) 'ready)
              (error "Snapshot unavailable"))
            (when old-chat
              (when (buffer-live-p old-chat) (error "Old chat survived retirement"))
              (when (= old-generation dsh-emacs--server-generation)
                (error "Connection identity reused")))
            (let* ((reply (dsh-emacs--rpc-request
                           "session/create" '((request . ((cwd . "/workspace") (agentPreset . "standard"))))))
                   (sid (dsh-protocol-session-session-id
                         (dsh-protocol-session--from-alist (cdr reply)))))
              (unless (and (car reply) sid) (error "Session create failed"))
              (dsh-emacs-open-session sid)
              (setq old-chat (gethash sid dsh-emacs--chat-buffers)
                    old-generation dsh-emacs--server-generation)
              (dsh-switch-e2e--wait (lambda () (with-current-buffer old-chat dsh-emacs--event-ready)))
              (with-current-buffer old-chat
                (goto-char (dsh-emacs--input-end)) (insert "keep this draft")
                (unless (condition-case nil (progn (dsh-emacs-disconnect) nil)
                          (user-error t))
                  (error "Disconnect discarded draft"))
                (dsh-emacs--clear-input))
              (dsh-switch-e2e--wait (lambda () (null dsh-emacs--server-requests)))
              (with-current-buffer origin (dsh-emacs-disconnect))
              (unless (eq (plist-get (dsh-emacs-connection-state) :status) 'disconnected)
                (error "Disconnect incomplete"))
              (princ (format "PASS %s connect/snapshot/chat/draft refusal/disconnect\n" suffix))))))
    (when (buffer-live-p origin) (kill-buffer origin))))

;;; dsh-switch-e2e.el ends here
