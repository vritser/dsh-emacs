;;; dsh-emacs-provider.el --- Add providers with minibuffer prompts -*- lexical-binding: t; -*-

;; Copyright (C) 2026 vritser
;; Author: vritser
;; Version: 0.5.0
;; License: GPL-3.0-or-later
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:
;; A small command surface for pi-ai catalog routes and custom providers.
;; Settings and credentials stay on the connected host; no configuration UI.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'url-parse)
(require 'dsh-emacs-protocol)
(require 'dsh-emacs-server)

(declare-function dsh-emacs--rpc-async "dsh-emacs" (method params callback))

(defun dsh-emacs-provider--request (server method args callback &optional failure)
  "Call METHOD with ARGS on SERVER and pass its value to CALLBACK.
Reject a changed connection before each call and callback.  FAILURE names
partial success when a credential write follows a saved profile."
  (unless (equal server (dsh-emacs--server-base-url))
    (user-error "%s: server changed"
                (or failure "Provider configuration cancelled")))
  (dsh-emacs--rpc-async
   method args
   (lambda (ok value)
     (condition-case err
         (cond
          ((not (equal server (dsh-emacs--server-base-url)))
           (message "%s: server changed; check the original server"
                    (or failure "Provider operation finished")))
          ((not ok)
           (let ((problem (dsh-protocol-rpc-error--from-alist value)))
             ;; Credential refusals must not echo a possibly secret-bearing
             ;; server diagnostic.  The error code is sufficient here.
             (message "%s: %s"
                      (or failure "Provider configuration failed")
                      (or (and (not (equal method "credentials/set"))
                               (dsh-protocol-rpc-error-message problem))
                          (dsh-protocol-rpc-error-code problem)
                          "request failed; check the server before retrying"))))
          (t (funcall callback value)))
       (quit (message "Provider configuration cancelled"))
       (error (message "Provider configuration: %s"
                       (error-message-string err)))))))

;;;###autoload
(defun dsh-emacs-add-provider ()
  "Add a provider to the connected dsh server through minibuffer prompts.
Select a pi-ai catalog provider or type a new route name.  Custom routes
need an endpoint, a supported protocol and comma-separated model IDs.
API keys use `read-passwd' and the server's separate credential store.
Selecting an existing route can update its endpoint and API key while
preserving its other settings.  No active chat session is required."
  (interactive)
  (dsh-emacs-server-ensure)
  (let ((server (dsh-emacs--server-base-url)))
    (dsh-emacs-provider--request
     server "settings/describe" nil
     (lambda (value)
       (let* ((catalog
               (dsh-protocol-provider-settings-catalog--from-alist value))
              (sections
               (cl-remove-if-not
                #'dsh-protocol-provider-settings-protocols
                (dsh-protocol-provider-settings-catalog-sections catalog))))
         (unless (dsh-protocol-provider-settings-catalog-writable catalog)
           (user-error "Server settings are read-only"))
         (unless sections
           (user-error "Server exposes no compatible provider configuration"))
         (dsh-emacs-provider--request
          server "llm/listConfigurableProviders" nil
          (lambda (directory)
            (dsh-emacs-provider--choose
             server sections
             (mapcar #'dsh-protocol-configurable-provider--from-alist
                     (append directory nil))))))))))

(defun dsh-emacs-provider--choose (server sections directory)
  "Choose a route from DIRECTORY and its owner in SECTIONS on SERVER."
  (let* ((candidates
          (cl-loop for entry in directory
                   when (cl-find
                         (dsh-protocol-configurable-provider-namespace entry)
                         sections :key #'dsh-protocol-provider-settings-name
                         :test #'equal)
                   collect (dsh-protocol-configurable-provider-id entry)))
         (provider (string-trim
                    (completing-read "Provider (or new name): "
                                     candidates nil nil)))
         (entry (cl-find provider directory
                         :key #'dsh-protocol-configurable-provider-id
                         :test #'equal))
         (section
          (if entry
              (cl-find (dsh-protocol-configurable-provider-namespace entry)
                       sections :key #'dsh-protocol-provider-settings-name
                       :test #'equal)
            (if (cdr sections)
                (let ((name (completing-read
                             "Provider configuration: "
                             (mapcar #'dsh-protocol-provider-settings-name
                                     sections) nil t)))
                  (cl-find name sections
                           :key #'dsh-protocol-provider-settings-name
                           :test #'equal))
              (car sections))))
         (path (if entry (dsh-protocol-configurable-provider-path entry)
                 (list "providers" provider))))
    (unless (string-match-p "\\`[a-z][a-z0-9]*\\(?:-[a-z0-9]+\\)*\\'" provider)
      (user-error "Provider name must use lowercase letters, digits and hyphens"))
    (unless (and section (equal path (list "providers" provider)))
      (user-error "Provider %s needs its own setup; use dsh-emacs-open-web"
                  provider))
    (let* ((profile (cdr (assoc provider
                                (dsh-protocol-provider-settings-profiles section))))
           (ref (or (and profile
                         (dsh-protocol-provider-profile-key-ref profile))
                    (concat (upcase (replace-regexp-in-string
                                     "-" "_" provider)) "_API_KEY"))))
      (dsh-emacs-provider--request
       server "credentials/describe" `((refs . ,(vector ref)))
       (lambda (value)
         (dsh-emacs-provider--edit
          server section provider profile
          (or (null entry)
              (dsh-protocol-configurable-provider-declared entry))
          ref (dsh-protocol-provider-credential--from-alist value ref)))))))

(defun dsh-emacs-provider--edit (server section provider profile custom ref credential)
  "Read and save PROVIDER on SERVER in SECTION.
PROFILE is its existing configuration, CUSTOM marks a non-catalog route,
and CREDENTIAL describes the write-only API key named by REF."
  (let* ((old-endpoint (and profile
                            (dsh-protocol-provider-profile-endpoint profile)))
         (endpoint (string-trim
                    (read-string (cond (old-endpoint "Base URL (empty keeps current): ")
                                       (custom "Base URL: ")
                                       (t "Base URL (empty keeps provider default): "))
                                 old-endpoint)))
         (parsed (and (not (string-empty-p endpoint))
                      (url-generic-parse-url endpoint)))
         (fields nil))
    (unless (or (and (or old-endpoint (not custom)) (string-empty-p endpoint))
                (and parsed (member (url-type parsed) '("http" "https"))
                     (url-host parsed) (not (string-empty-p (url-host parsed)))))
      (user-error "Provider endpoint must be an HTTP or HTTPS URL"))
    (unless (or (string-empty-p endpoint) (equal endpoint old-endpoint))
      (push (cons 'baseURL endpoint) fields))
    (unless profile
      (when custom
        (push (cons 'api (completing-read
                          "Protocol: "
                          (dsh-protocol-provider-settings-protocols section)
                          nil t nil nil
                          (car (dsh-protocol-provider-settings-protocols section))))
              fields))
      (let ((models (delete-dups
                     (split-string
                      (read-string
                       (if custom "Model IDs (comma-separated): "
                         "Model IDs (comma-separated; empty keeps catalog): "))
                      "[,[:space:]]+" t))))
        (when (and custom (null models))
          (user-error "A custom provider needs at least one model ID"))
        (when models
          (push (cons 'models (vconcat (mapcar (lambda (id) `((id . ,id))) models)))
                fields))))
    (let* ((configured (dsh-protocol-provider-credential-configured credential))
           (key (and (dsh-protocol-provider-credential-writable credential)
                     (string-trim
                      (read-passwd
                       (format "API key for %s (%s): " provider
                               (if configured
                                   (format "empty keeps %s; typing replaces it" ref)
                                 "empty uses provider-native authentication"))))))
           (stores-key (and key (not (string-empty-p key)))))
      (when (and (or stores-key configured)
                 (not (and profile
                           (equal ref (dsh-protocol-provider-profile-key-ref profile)))))
        (push (cons 'apiKeyEnv ref) fields))
      (when (and (not (dsh-protocol-provider-credential-writable credential))
                 (not configured))
        (user-error "Credential %s is unavailable and read-only" ref))
      (let ((ops (if profile
                     (vconcat
                      (mapcar (lambda (field)
                                `((op . "set")
                                  (path . ,(vector "providers" provider
                                                   (symbol-name (car field))))
                                  (value . ,(cdr field))))
                              fields))
                   (vector `((op . "set") (path . ,(vector "providers" provider))
                             (value . ,(or fields (make-hash-table))))))))
        (dsh-emacs-provider--request
         server "settings/mutate"
         `((ns . ,(dsh-protocol-provider-settings-name section))
           (expectedRevision . ,(dsh-protocol-provider-settings-revision section))
           (ops . ,ops))
         (lambda (_value)
           (if stores-key
               (dsh-emacs-provider--request
                server "credentials/set" `((ref . ,ref) (value . ,key))
                (lambda (_value)
                  (message "Provider %s saved; use C-c C-m to select a model"
                           provider))
                (format "Provider %s saved, API key not confirmed; run dsh-emacs-add-provider again to retry"
                        provider))
             (message "Provider %s saved; use C-c C-m to select a model"
                      provider))))))))

(provide 'dsh-emacs-provider)
;;; dsh-emacs-provider.el ends here
