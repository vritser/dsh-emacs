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

;;; Code:

(setq debug-on-error t)
(add-to-list 'load-path
             (expand-file-name ".." (file-name-directory load-file-name)))

(require 'cl-lib)
(require 'dsh-emacs)

(defvar dsh-e2e--results nil)
(defvar dsh-e2e--session-id nil)
(defvar dsh-e2e--chat nil)

(setq dsh-emacs-base-url
      (or (getenv "DSH_E2E_URL") dsh-emacs-base-url)
      dsh-emacs-enable-notifications nil
      dsh-emacs-new-session-auto-project nil)

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

(unwind-protect
    (condition-case error-data
        (progn
          (dsh-e2e--rpc "session/list" (dsh-emacs--session-list-args))
          (dsh-e2e--pass "health-check")

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
                              (string-match-p (regexp-quote message)
                                              (buffer-string))))

            (dsh-e2e--rpc
             "session/cancel"
             `((request . ((sessionId . ,dsh-e2e--session-id)))))
            (dsh-e2e--pass "cancel-session")

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
  (when (buffer-live-p dsh-e2e--chat)
    (dsh-emacs-events-disconnect dsh-e2e--chat))
  (when-let* ((list-buffer (get-buffer dsh-emacs-sessions-buffer)))
    (with-current-buffer list-buffer
      (dsh-emacs-events-host-disconnect)))
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

(princ "\n===== E2E summary =====\n")
(let ((passed (cl-count-if #'cadr dsh-e2e--results))
      (failed (cl-count-if-not #'cadr dsh-e2e--results)))
  (princ (format "Passed %d, failed %d\n" passed failed))
  (when (> failed 0)
    (princ "Failures:\n")
    (dolist (result (nreverse dsh-e2e--results))
      (unless (cadr result)
        (princ (format "  - %s: %s\n" (car result) (nth 2 result)))))
    (kill-emacs 1)))

;;; dsh-e2e.el ends here
