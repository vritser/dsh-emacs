;;; dsh-emacs-switch.el --- Project service profiles for dsh -*- lexical-binding: t; -*-

;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (dsh-emacs "0.9.0"))
;; License: GPL-3.0-or-later

;;; Commentary:
;; An optional package using only public dsh APIs.  Resolvers supply current
;; addresses and credentials; this package knows nothing about containers.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'url-parse)
(require 'url-util)
(require 'dsh-emacs)

(defgroup dsh-emacs-switch nil
  "Explicit switching between project services."
  :group 'dsh-emacs)

(defcustom dsh-emacs-switch-profiles nil
  "Profiles as plists with :id, :label, :root and :resolve.
The resolver is a zero-argument function called in the project's local root.
It returns (:url URL), optionally with :token TOKEN.  Resolve credentials
afresh each time; do not store tokens in labels or in this profile list."
  :type '(repeat sexp)
  :group 'dsh-emacs-switch)

(defvar dsh-emacs-switch--profile nil
  "Stable id of the most recently connected profile.")
(defvar dsh-emacs-switch--sessions nil
  "Alist of profile ids and last chosen root session ids, in memory only.")
(defvar-local dsh-emacs-switch--pending nil
  "Non-nil while this coordination buffer owns a connection attempt.")

(defun dsh-emacs-switch--choose-session (profile)
  "Open PROFILE's last known root session, or ask from the ready snapshot."
  (let* ((id (plist-get profile :id))
         (last (cdr (assoc id dsh-emacs-switch--sessions)))
         (sessions (plist-get (dsh-emacs-session-snapshot) :sessions))
         (selected
          (if (and last (dsh-emacs-session-exists-p last)) last
            (when sessions
              (let* ((choices
                      (mapcar (lambda (session)
                                (let ((sid (dsh-protocol-session-session-id session)))
                                  (cons (format "%s [%s]"
                                                (or (dsh-protocol-session-title-value session) sid)
                                                sid) sid))) sessions))
                     (answer (completing-read "Session: " choices nil t)))
                (cdr (assoc answer choices)))))))
    (if selected
        (progn
          (setf (alist-get id dsh-emacs-switch--sessions nil nil #'equal) selected)
          (dsh-emacs-open-session selected))
      (dsh-emacs))))

;;;###autoload
(defun dsh-emacs-switch (&optional profile-id)
  "Resolve PROFILE-ID, disconnect safely and connect to its current service.
Interactively choose a profile.  Resolve before disconnect so a resolver
failure preserves the current service.  The core refuses unsent content.
The persistent coordination buffer owns the attempt until it completes;
closing that buffer cancels it through the core's origin-lifetime contract."
  (interactive)
  (dolist (api '(dsh-emacs-connect dsh-emacs-disconnect dsh-emacs-connection-state
                                   dsh-emacs-session-snapshot dsh-emacs-session-exists-p
                                   dsh-emacs-current-session))
    (unless (fboundp api)
      (user-error "dsh-emacs-switch requires the dsh-emacs 0.9 lifecycle API")))
  (unless dsh-emacs-switch-profiles (user-error "Configure dsh-emacs-switch-profiles"))
  (let* ((choices
          (mapcar (lambda (profile)
                    (cons (format "%s [%s]" (or (plist-get profile :label)
                                                (plist-get profile :id))
                                  (plist-get profile :id)) profile))
                  dsh-emacs-switch-profiles))
         (profile (if profile-id
                      (cl-find profile-id dsh-emacs-switch-profiles
                               :key (lambda (item) (plist-get item :id)) :test #'equal)
                    (cdr (assoc (completing-read "dsh service: " choices nil t) choices))))
         (root (and profile (plist-get profile :root)))
         (resolver (and profile (plist-get profile :resolve)))
         (coordinator (get-buffer-create " *dsh-switch*")))
    (when (and (stringp root) (file-remote-p root))
      (user-error "Profile root must be local to Emacs"))
    (unless (and profile (stringp (plist-get profile :id))
                 (not (string-empty-p (plist-get profile :id)))
                 (functionp resolver) (stringp root) (file-directory-p root))
      (user-error "Profile needs an id, existing local root and resolver function"))
    (unless (= (length dsh-emacs-switch-profiles)
               (length (delete-dups (mapcar (lambda (item) (plist-get item :id))
                                            dsh-emacs-switch-profiles))))
      (user-error "Profile ids must be unique"))
    (when (buffer-local-value 'dsh-emacs-switch--pending coordinator)
      (user-error "A profile connection is already in progress"))
    (setq root (file-name-as-directory (expand-file-name root)))
    (let* ((default-directory root)
           (resolved (condition-case nil (funcall resolver)
                       (error (user-error "Service resolver failed; current connection preserved"))))
           (url (plist-get resolved :url))
           (token (plist-get resolved :token))
           (parsed (and (stringp url) (url-generic-parse-url url))))
      (unless (and parsed (member (url-type parsed) '("http" "https"))
                   (url-host parsed) (not (string-empty-p (url-host parsed)))
                   (or (null token) (and (stringp token) (not (string-empty-p token)))))
        (user-error "Resolver must return an http(s) URL and optional nonempty token"))
      (when-let* ((query (cdr (url-path-and-query parsed)))
                  (url-token (cadr (assoc "token" (url-parse-query-string query))))
                  ((plist-member resolved :token))
                  ((not (equal token url-token))))
        (user-error "Resolver URL token conflicts with its explicit token"))
      (when (and dsh-emacs-switch--profile
                 (eq (plist-get (dsh-emacs-session-snapshot) :status) 'ready))
        (when-let* ((session (dsh-emacs-current-session))
                    ((dsh-emacs-session-exists-p session)))
          (setf (alist-get dsh-emacs-switch--profile dsh-emacs-switch--sessions
                           nil nil #'equal) session)))
      (dsh-emacs-disconnect)
      (with-current-buffer coordinator
        (setq default-directory root
              dsh-emacs-switch--pending t)
        (condition-case err
            (apply #'dsh-emacs-connect url
                   (append (when (plist-member resolved :token) (list :token token))
                           (list :callback
                                 (lambda (ok result)
                                   (setq dsh-emacs-switch--pending nil)
                                   (if (not ok)
                                       (message "dsh service connection failed: %s"
                                                (plist-get result :message))
                                     (setq dsh-emacs-switch--profile (plist-get profile :id))
                                     (dsh-emacs-switch--choose-session profile))))))
          ((error quit)
           (setq dsh-emacs-switch--pending nil)
           (signal (car err) (cdr err))))))))

(provide 'dsh-emacs-switch)
;;; dsh-emacs-switch.el ends here
