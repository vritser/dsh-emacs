;;; dsh-emacs-reload.el --- Reload package source without resetting chats -*- lexical-binding: t; -*-

;; Copyright (C) 2026
;; Version: 0.8.0
;; Package-Requires: ((emacs "28.1"))
;; License: GPL-3.0-or-later

;;; Commentary:
;; Development reload preserves live transports and buffer state.  It is not
;; an unload, a migration of existing structs, or a replay of the transcript.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(declare-function dsh-emacs-composer-refresh "dsh-emacs-composer" ())
(declare-function dsh-emacs-events-host-restore "dsh-emacs-events" ())
(declare-function dsh-emacs--composer-delete-guard-install "dsh-emacs-input" ())
(declare-function dsh-emacs-modeline-refresh "dsh-emacs-modeline" ())
(declare-function dsh-emacs-session--render "dsh-emacs-session" ())
(defvar dsh-emacs--interaction-active)
(defvar dsh-emacs--creation-pending)
(defvar dsh-emacs--history-loading)
(defvar dsh-emacs-session--row-cache)

(defconst dsh-emacs-reload--directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing this loaded copy of the package.")

(defvar dsh-emacs-reload--files nil
  "Source files being reloaded, dynamically bound by the command.")

(defvar dsh-emacs-reload--finish-timer nil
  "Pending completion of a reload begun by an older loader.")

(defun dsh-emacs-reload--sources (directory)
  "Read all package sources in DIRECTORY and return dependency order.
Reject unreadable forms and circular top-level package requires before any
running definition changes.  External dependencies are left to `require'."
  (let (entries ordered visited visiting)
    (unless (file-readable-p (expand-file-name "dsh-emacs.el" directory))
      (user-error "No dsh-emacs.el source in %s" directory))
    (dolist (file (directory-files directory t
                                  "\\`dsh-emacs\\(?:-[^.]+\\)?\\.el\\'"))
      (let (dependencies)
        (condition-case err
            (with-temp-buffer
              (insert-file-contents file)
              (delay-mode-hooks (emacs-lisp-mode))
              (goto-char (point-min))
              (while (progn (forward-comment (point-max)) (not (eobp)))
                (pcase (read (current-buffer))
                  (`(require (quote ,feature) . ,_)
                   (push feature dependencies)))))
          (error (error "Cannot read %s: %s" file (error-message-string err))))
        (push (list (intern (file-name-base file)) file dependencies) entries)))
    (setq entries (nreverse entries))
    (cl-labels
        ((visit (entry)
           (unless (memq (car entry) visited)
             (when (memq (car entry) visiting)
               (error "Circular package require: %s" (car entry)))
             (push (car entry) visiting)
             (dolist (dependency (nth 2 entry))
               (when-let* ((other (assq dependency entries)))
                 (visit other)))
             (pop visiting)
             (push (car entry) visited)
             (push (cadr entry) ordered))))
      (dolist (entry entries) (visit entry)))
    (nreverse ordered)))

(defun dsh-emacs-reload--read (stream)
  "Read a source form from STREAM, refreshing maps and face defaults.
Ordinary `defvar' state is retained.  Maps are replaced in place so existing
buffers and text properties keep referring to the updated object.  Face
customizations remain above the new default spec."
  (let ((form (read stream)))
    (if (not (member load-file-name dsh-emacs-reload--files))
        form
      (pcase form
        (`(defvar ,name ,initial . ,_)
         (if (and (boundp name) (keymapp (symbol-value name)))
             `(progn
                ,form
                (let ((new-map ,initial))
                  (unless (keymapp new-map)
                    (error "Reloaded keymap is no longer a keymap: %s" ',name))
                  (setcdr ,name (cdr new-map))))
           form))
        (`(defface ,name ,spec . ,_)
         `(progn ,form (face-spec-set ',name ,spec 'face-defface-spec)))
        (_ form)))))

(defun dsh-emacs-reload--finish ()
  "Complete source reload by reconciling ownership and live presentation.
The current loader calls this synchronously and cancels its queued fallback.
An older loader reaches the same completion through the one deferred callback
registered while loading this file."
  (when (timerp dsh-emacs-reload--finish-timer)
    (cancel-timer dsh-emacs-reload--finish-timer))
  (setq dsh-emacs-reload--finish-timer nil)
  (dsh-emacs-events-host-restore)
  (save-selected-window
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (cond
         ((derived-mode-p 'dsh-emacs-mode)
          (dsh-emacs--composer-delete-guard-install)
          (save-excursion (dsh-emacs-composer-refresh)))
         ((derived-mode-p 'dsh-emacs-session-mode)
          (setq dsh-emacs-session--row-cache nil)
          (dsh-emacs-session--render))))))
  (dsh-emacs-modeline-refresh))

;;;###autoload
(defun dsh-emacs-reload (&optional directory)
  "Reload every dsh-emacs source module and refresh existing presentation.
DIRECTORY defaults to the source directory of this loaded package.  Explicit
.el paths bypass stale bytecode.  Keep chats, drafts, attachments, custom
settings, running connections and timers; never re-enter a major mode.
A reload that renames the client-wide core stream adopts the previous
socket, or closes leftovers and rebuilds it, so chats keep receiving
questions and approvals.

Refresh keymap defaults in place (ad-hoc edits to package maps are replaced),
face defaults, Composer rows, the session list and mode lines.  Existing
transcript text and in-flight lexical callbacks are not replayed or replaced.
Removed definitions stay resident for existing callbacks; restart Emacs for
full removal, changed struct layouts or changed major-mode initialization.

All sources are read before loading, but evaluation is not transactional: an
error during loading can leave some new definitions installed.  Fix the error
and reload again, or restart Emacs.  No server restart or prompt is sent."
  (interactive)
  (when dsh-emacs-reload--files
    (user-error "A dsh-emacs reload is already in progress"))
  (when (or (active-minibuffer-window)
            (bound-and-true-p dsh-emacs--interaction-active))
    (user-error "Finish the active minibuffer interaction before reloading"))
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (and (derived-mode-p 'dsh-emacs-mode 'dsh-emacs-draft-mode)
                 (or (bound-and-true-p dsh-emacs--creation-pending)
                     (bound-and-true-p dsh-emacs--history-loading)))
        (user-error "Wait for session creation or history loading in %s"
                    (buffer-name buffer)))))
  (let ((directory (file-name-as-directory
                    (expand-file-name (or directory dsh-emacs-reload--directory)))))
    (when (file-remote-p directory)
      (user-error "Reload needs a local source directory"))
    (let* ((dsh-emacs-reload--files (dsh-emacs-reload--sources directory))
           (load-path (cons directory load-path))
           (load-read-function #'dsh-emacs-reload--read))
      (dolist (file dsh-emacs-reload--files)
        (load file nil t t))
      (dsh-emacs-reload--finish)
      (message "Reloaded %d dsh-emacs source modules" (length dsh-emacs-reload--files))
      (length dsh-emacs-reload--files))))

;; This file is loaded from inside the previous build's reload body.  That
;; body cannot call the new restore step: redefining a function does not
;; change an invocation already in progress.  The current loader cancels
;; this callback when it completes synchronously; an older loader lets it run.
(when (and dsh-emacs-reload--files
           (not (timerp dsh-emacs-reload--finish-timer)))
  (setq dsh-emacs-reload--finish-timer
        (run-at-time 0 nil #'dsh-emacs-reload--finish)))

(provide 'dsh-emacs-reload)
;;; dsh-emacs-reload.el ends here
