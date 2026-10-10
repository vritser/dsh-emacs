;;; dsh-emacs-subagent.el --- Subagent discovery and navigation -*- lexical-binding: t; -*-

;; Copyright (C) 2026
;; Author: dsh-emacs contributors
;; Version: 0.6.0
;; Package-Requires: ((emacs "27.1"))
;; License: GPL-3.0-or-later

;;; Commentary:
;; Durable catalogs and sequenced projections share the host control stream.
;; Session summaries supply live activity and Agent availability independently.

;;; Code:
(require 'cl-lib)
(require 'xref)
(require 'dsh-emacs-protocol)
(require 'dsh-emacs-tokens)

(declare-function dsh-emacs--session-list-args "dsh-emacs" ())
(defvar dsh-emacs--sessions)
(defvar dsh-emacs--chat-buffers)
(defvar dsh-emacs--buffer-session)
(defvar dsh-emacs--buffer-subagent)
(defvar dsh-emacs--subagent-input-read-only)
(defvar dsh-emacs-sessions-buffer)
(declare-function dsh-emacs-events--host-repaint "dsh-emacs-events" ())
(declare-function dsh-emacs--rpc-request "dsh-emacs" (method params))
(declare-function dsh-emacs--completing-read-ordered "dsh-emacs" (prompt collection &rest args))
(declare-function dsh-emacs--rpc-async "dsh-emacs" (method params callback))
(declare-function dsh-emacs--chat-session-item "dsh-emacs" (session-id))
(declare-function dsh-emacs--chat-title "dsh-emacs" (session-id))
(declare-function dsh-emacs--active-session-id "dsh-emacs" ())
(declare-function dsh-emacs--subagent-input-update "dsh-emacs" ())
(declare-function dsh-emacs-open-subagent "dsh-emacs" (parent entry &optional other-window))
(declare-function dsh-emacs-open-session "dsh-emacs" (session-id &optional address other-window))
(declare-function nerd-icons-mdicon "nerd-icons" (icon-name &rest args))
(defvar nerd-icons-font-family)

(defvar dsh-emacs--subagent-catalogs (make-hash-table :test #'equal)
  "Session id to projection cells, read state and summary revision.")
(defvar dsh-emacs--subagent-generation 0)
(defvar dsh-emacs--subagent-host-live nil)
(defvar dsh-emacs--subagent-summary-request nil)

(defun dsh-emacs-subagent--cell (id key)
  "Return ID's decoded cell for KEY."
  (alist-get key (plist-get (gethash id dsh-emacs--subagent-catalogs) :cells)))

(defun dsh-emacs-subagent--value (id key)
  "Return ID's projection value for KEY."
  (let ((cell (dsh-emacs-subagent--cell id key)))
    (and cell (dsh-protocol-subagent-cell-value cell))))

(defun dsh-emacs-subagent-apply (id cells)
  "Apply decoded CELLS for ID, rejecting older watermarks independently."
  (let* ((state (gethash id dsh-emacs--subagent-catalogs))
         (stored (plist-get state :cells)))
    (dolist (cell cells)
      (let* ((key (dsh-protocol-subagent-cell-key cell))
             (old (alist-get key stored)))
        (when (or (null old)
                  (> (dsh-protocol-subagent-cell-seq cell)
                     (dsh-protocol-subagent-cell-seq old)))
          (setf (alist-get key stored) cell))))
    (setq state (plist-put state :cells stored))
    (when (and (null (plist-get state :request))
               (let ((catalog (alist-get 'subagentCatalog stored)))
                 (and catalog (dsh-protocol-subagent-cell-present catalog))))
      (setq state (plist-put state :state 'ready)))
    (puthash id state dsh-emacs--subagent-catalogs))
  (dsh-emacs-subagent--changed))

(defun dsh-emacs-subagent-refresh (&optional id)
  "Refresh cold projections for ID, defaulting to the current conversation."
  (interactive)
  (unless id
    (setq id (dsh-emacs--active-session-id))
    (dsh-emacs-subagent--refresh-summaries))
  (unless id (user-error "No conversation is open"))
  (let ((state (gethash id dsh-emacs--subagent-catalogs)))
    (unless (plist-get state :request)
      (let ((token (cons dsh-emacs--subagent-generation nil)))
        (setq state (plist-put state :request token)
              state (plist-put state :state 'loading))
        (puthash id state dsh-emacs--subagent-catalogs)
        (dsh-emacs-subagent--changed)
        (with-current-buffer (get-buffer-create " *dsh-subagent-state*")
          (dsh-emacs--rpc-async
           "session/projections"
           (dsh-protocol-subagent-projections-request id)
           (lambda (ok value)
             (let ((current (gethash id dsh-emacs--subagent-catalogs)))
               (when (and (= (car token) dsh-emacs--subagent-generation)
                          (eq token (plist-get current :request)))
                 (setq current (plist-put current :request nil)
                       current (plist-put current :state (if (and ok value) 'ready 'error))
                       current (plist-put current :error (unless (and ok value) value)))
                 (puthash id current dsh-emacs--subagent-catalogs)
                 (if (and ok value)
                     (dsh-emacs-subagent-apply
                      id (dsh-protocol-subagent-baseline--from-alist value))
                   (dsh-emacs-subagent--changed)))))))))))

(defun dsh-emacs-subagent-summary-changed (id &optional status-only)
  "Record a fresh live summary or removal of ID.
STATUS-ONLY means only the running flag changed, not Agent availability."
  (let ((state (gethash id dsh-emacs--subagent-catalogs)))
    (setq state (plist-put state :summary-revision
                           (1+ (or (plist-get state :summary-revision) 0))))
    (unless status-only
      (setq state (plist-put
                   state :availability-revision
                   (1+ (or (plist-get state :availability-revision) 0)))))
    (puthash id state dsh-emacs--subagent-catalogs))
  (dsh-emacs-subagent--changed))

(defun dsh-emacs-subagent--refresh-summaries ()
  "Refresh Agent availability once for this connected generation."
  (when (and dsh-emacs--subagent-host-live
             (null dsh-emacs--subagent-summary-request))
    (let ((token (cons dsh-emacs--subagent-generation nil))
          (revisions (make-hash-table :test #'equal)))
      (maphash (lambda (id state)
                 (puthash id (cons (plist-get state :summary-revision)
                                   (plist-get state :availability-revision))
                          revisions))
               dsh-emacs--subagent-catalogs)
      (setq dsh-emacs--subagent-summary-request token)
      (with-current-buffer (get-buffer-create " *dsh-subagent-state*")
        (dsh-emacs--rpc-async
         "session/list" (dsh-emacs--session-list-args)
         (lambda (ok value)
           (when (eq token dsh-emacs--subagent-summary-request)
             (setq dsh-emacs--subagent-summary-request nil)
             (if (not ok)
                 (message "Subagent parent availability refresh failed: %S" value)
               (dolist (incoming (dsh-protocol-session-list--from-alist value))
                 (let* ((id (dsh-protocol-session-session-id incoming))
                        (existing (dsh-emacs--chat-session-item id))
                        (state (gethash id dsh-emacs--subagent-catalogs))
                        (before (gethash id revisions)))
                   (when (equal (car before)
                                (plist-get state :summary-revision))
                     (if existing
                         (setf (dsh-protocol-session-running existing)
                               (dsh-protocol-session-running incoming))
                       (push incoming dsh-emacs--sessions)))
                   ;; A status-only frame cannot supersede availability.
                   (when (and existing
                              (equal (cdr before)
                                     (plist-get state :availability-revision)))
                     (setf (dsh-protocol-session-agent-available existing)
                           (dsh-protocol-session-agent-available incoming)))))
               (dsh-emacs-subagent--changed)))))))))

(defun dsh-emacs-subagent-host-reset (&optional connected)
  "Invalidate old generation requests and availability; CONNECTED starts anew."
  (cl-incf dsh-emacs--subagent-generation)
  (setq dsh-emacs--subagent-host-live connected
        dsh-emacs--subagent-summary-request nil)
  (dolist (session dsh-emacs--sessions)
    (setf (dsh-protocol-session-agent-available session) nil))
  (maphash
   (lambda (id state)
     (when (eq (plist-get state :state) 'loading)
       (puthash id (plist-put (plist-put state :state nil) :request nil)
                dsh-emacs--subagent-catalogs)))
   dsh-emacs--subagent-catalogs)
  (dsh-emacs-subagent--changed)
  (when connected (dsh-emacs-subagent--refresh-summaries)))

(defun dsh-emacs-subagent-label (address)
  "Resolve ADDRESS's durable label, with title and id fallbacks."
  (let* ((id (dsh-protocol-subagent-address-child address))
         (identity (dsh-emacs-subagent--value id 'subagent))
         (entry (cl-find id (dsh-emacs-subagent--value
                             (dsh-protocol-subagent-address-parent address)
                             'subagentCatalog)
                         :test #'equal :key #'dsh-protocol-subagent-entry-id)))
    (or (and identity (dsh-protocol-subagent-identity-label identity))
        (and entry (dsh-protocol-subagent-entry-label entry))
        (dsh-emacs--chat-title id) id)))

(defun dsh-emacs-subagent-address (parent entry)
  "Build ENTRY's address using its direct PARENT, resolving unknown mode."
  (let* ((id (dsh-protocol-subagent-entry-id entry))
         (identity (dsh-emacs-subagent--value id 'subagent)))
    (dsh-protocol-subagent-address-create
     parent id (or (and identity (dsh-protocol-subagent-identity-mode identity))
                   (dsh-protocol-subagent-entry-mode entry)))))

(defun dsh-emacs-subagent-input-reason (address)
  "Return why ADDRESS cannot accept input, or nil when it can."
  (cond
   ((not (equal (dsh-protocol-subagent-address-mode address) "continuable"))
    "Read-only subagent execution record")
   ((not dsh-emacs--subagent-host-live) "Parent availability pending (disconnected)")
   (t
    (let* ((parent (dsh-emacs--chat-session-item
                    (dsh-protocol-subagent-address-parent address)))
           (available (and parent (dsh-protocol-session-agent-available parent))))
      (cond ((eq available t) nil)
            ((eq available :unavailable) "Parent Agent unavailable")
            (t "Parent availability pending; run dsh-emacs-subagent-refresh"))))))

(defun dsh-emacs-subagent-require (action &optional session-id)
  "Check ACTION against the current child's capabilities or SESSION-ID."
  (let* ((address (bound-and-true-p dsh-emacs--buffer-subagent))
         (session (and session-id (dsh-emacs--chat-session-item session-id))))
    (when (or address (and session (dsh-protocol-session-origin session)))
      (pcase action
        ('send
         (when-let* ((reason (and address (dsh-emacs-subagent-input-reason address))))
           (user-error "%s" reason)))
        ('stop
         (unless (and address (equal (dsh-protocol-subagent-address-mode address)
                                     "continuable"))
           (user-error "One-shot subagents cannot be interrupted")))
        (_ (user-error "This command is unavailable in a subagent conversation"))))))

(defun dsh-emacs-subagent--changed ()
  "Update open child composers and mode lines after state changes."
  (when (boundp 'dsh-emacs--chat-buffers)
    (maphash
     (lambda (_id buffer)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (when (bound-and-true-p dsh-emacs--buffer-subagent)
             (let ((identity (dsh-emacs-subagent--value
                              dsh-emacs--buffer-session 'subagent)))
               (when identity
                 (setf (dsh-protocol-subagent-address-mode dsh-emacs--buffer-subagent)
                       (dsh-protocol-subagent-identity-mode identity))))
             (dsh-emacs--subagent-input-update)))))
     dsh-emacs--chat-buffers))
  (when-let* ((buffer (and (boundp 'dsh-emacs-sessions-buffer)
                          (get-buffer dsh-emacs-sessions-buffer))))
    (with-current-buffer buffer
      (when (derived-mode-p 'dsh-emacs-session-mode)
        (dsh-emacs-events--host-repaint))))
  (force-mode-line-update t))

(defun dsh-emacs-subagent--label (entry)
  "Display label for ENTRY."
  (or (dsh-protocol-subagent-entry-label entry)
      (dsh-protocol-subagent-entry-id entry)))

(defun dsh-emacs-subagent--activity (id)
  "Describe ID without treating a missing summary as idle."
  (let ((session (dsh-emacs--chat-session-item id))
        (timing (dsh-emacs-subagent--value id 'subagentTiming)))
    (cond ((and session (dsh-protocol-session-running session)) "running")
          ((and timing (dsh-protocol-subagent-timing-completed timing)) "completed")
          (session "idle")
          (t "unknown"))))

(defun dsh-emacs-subagent--annotation (parent entry)
  "Describe ENTRY under PARENT for minibuffer completion."
  (let* ((id (dsh-protocol-subagent-entry-id entry))
         (activity (dsh-emacs-subagent--activity id))
         (timing (dsh-emacs-subagent--value id 'subagentTiming))
         (usage (dsh-emacs-subagent--value id 'tokenUsage)))
    (concat
     "  " (dsh-protocol-subagent-address-mode
           (dsh-emacs-subagent-address parent entry)) "  " activity
     (when timing
       (let* ((since (dsh-protocol-subagent-timing-active-since timing))
              (end (if (and dsh-emacs--subagent-host-live
                            (equal activity "running"))
                       (* 1000 (float-time))
                     (dsh-protocol-subagent-timing-active-through timing))))
         (format "  %.1fs"
                 (/ (+ (dsh-protocol-subagent-timing-settled-ms timing)
                       (if (and since end) (max 0 (- end since)) 0))
                    1000.0))))
     (when usage
       (format "  %s total tok (incl. cache)"
               (dsh-emacs-subagent-token-total usage))))))

(defun dsh-emacs-subagent--read ()
  "Read a direct child of this conversation, returning (PARENT . ENTRY).
Use the current completion frontend with no additional minibuffer keys."
  (let ((parent (dsh-emacs--active-session-id)))
    (unless parent (user-error "No conversation is open"))
    (unless (dsh-emacs-subagent--cell parent 'subagentCatalog)
      (let* ((generation dsh-emacs--subagent-generation)
             (response (dsh-emacs--rpc-request
                        "session/projections"
                        (dsh-protocol-subagent-projections-request parent))))
        (unless (= generation dsh-emacs--subagent-generation)
          (user-error "Connection changed while reading subagents; try again"))
        (unless (and (car response) (cdr response))
          (user-error "Cannot read subagents: %S" (cdr response)))
        (dsh-emacs-subagent-apply
         parent (dsh-protocol-subagent-baseline--from-alist (cdr response)))))
    (let* ((entries (dsh-emacs-subagent--value parent 'subagentCatalog))
           (table (mapcar (lambda (entry)
                            (cons (format "%s [%s]" (dsh-emacs-subagent--label entry)
                                          (dsh-protocol-subagent-entry-id entry))
                                  entry)) entries)))
      (unless table (user-error "No subagents for this conversation"))
      (dsh-emacs-subagent--refresh-summaries)
      (dolist (entry entries)
        (unless (plist-get (gethash (dsh-protocol-subagent-entry-id entry)
                                    dsh-emacs--subagent-catalogs) :state)
          (dsh-emacs-subagent-refresh (dsh-protocol-subagent-entry-id entry))))
      (let* ((completion-extra-properties
              (list :annotation-function
                    (lambda (candidate)
                      (when-let* ((entry (cdr (assoc candidate table))))
                        (dsh-emacs-subagent--annotation parent entry)))))
             (choice (dsh-emacs--completing-read-ordered
                      "Subagent: " table nil t)))
        (unless (assoc choice table) (user-error "No subagent selected"))
        (cons parent (cdr (assoc choice table)))))))

(defun dsh-emacs-subagent-open-parent ()
  "Open the direct parent, recording the actual departure in xref."
  (interactive)
  (let ((id (and dsh-emacs--buffer-subagent
                 (dsh-protocol-subagent-address-parent dsh-emacs--buffer-subagent)))
        owner)
    (unless id (user-error "No parent conversation"))
    (maphash
     (lambda (parent _state)
       (dolist (entry (dsh-emacs-subagent--value parent 'subagentCatalog))
         (when (equal id (dsh-protocol-subagent-entry-id entry))
           (setq owner (cons parent entry)))))
     dsh-emacs--subagent-catalogs)
    (if owner
        (dsh-emacs-open-subagent (car owner) (cdr owner))
      (let ((marker (point-marker)))
        (dsh-emacs-open-session id)
        (xref-push-marker-stack marker)))))

(defun dsh-emacs-subagent-stop ()
  "Choose and request interruption of a continuable child."
  (interactive)
  (pcase-let* ((`(,parent . ,entry) (dsh-emacs-subagent--read))
               (address (dsh-emacs-subagent-address parent entry)))
    (unless (equal (dsh-protocol-subagent-address-mode address) "continuable")
      (user-error "One-shot subagents cannot be interrupted"))
    (unless (equal (dsh-emacs-subagent--activity
                    (dsh-protocol-subagent-address-child address)) "running")
      (user-error "This subagent is not known to be running"))
    (when (y-or-n-p (format "Stop %s? " (dsh-emacs-subagent--label entry)))
      (dsh-emacs--rpc-async
       "subagents/interruptByParent" (dsh-protocol-subagent-stop-request address)
       (lambda (ok value)
         (if ok (message "Subagent stop requested")
           (message "Subagent stop failed: %S" value)))))))

(defun dsh-emacs-subagent-describe ()
  "Choose a child and describe its cumulative token components."
  (interactive)
  (pcase-let* ((`(,parent . ,entry) (dsh-emacs-subagent--read))
               (id (dsh-protocol-subagent-entry-id entry)))
    (with-help-window "*DSH Subagent Details*"
      (princ (format "%s\nSession: %s\nDirect parent: %s\nMode: %s\nCreated: %s\nActivity: %s\n"
                     (dsh-emacs-subagent--label entry) id parent
                     (dsh-protocol-subagent-address-mode (dsh-emacs-subagent-address parent entry))
                     (dsh-protocol-subagent-entry-created-at entry)
                     (dsh-emacs-subagent--activity id)))
      (when-let* ((usage (dsh-emacs-subagent--value id 'tokenUsage)))
        (princ (format "Session cumulative tokens (not a billing estimate):\nUncached input: %d\nOutput: %d\nCache read: %d\nCache write: %d\n"
                       (dsh-protocol-token-usage-input usage)
                       (dsh-protocol-token-usage-output usage)
                       (dsh-protocol-token-usage-cache-read usage)
                       (dsh-protocol-token-usage-cache-write usage)))))))

;;;###autoload
(defun dsh-emacs-list-subagents (&optional other-window)
  "Choose a direct child and open its conversation.
With prefix OTHER-WINDOW, open in another window.  `M-,' returns via xref.
Run this command in a child conversation to choose from its own children."
  (interactive "P")
  (pcase-let ((`(,parent . ,entry) (dsh-emacs-subagent--read)))
    (dsh-emacs-open-subagent parent entry other-window)))

(defvar dsh-emacs-subagent-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mode-line mouse-1] #'dsh-emacs-list-subagents)
    map))

(defun dsh-emacs-subagent-indicator ()
  "Mode-line child count and lineage for the current chat."
  (let* ((id (bound-and-true-p dsh-emacs--buffer-session))
         (catalog (and id (dsh-emacs-subagent--value id 'subagentCatalog)))
         (address (bound-and-true-p dsh-emacs--buffer-subagent))
         (running (cl-count-if
                   (lambda (entry)
                     (equal (dsh-emacs-subagent--activity
                             (dsh-protocol-subagent-entry-id entry)) "running")) catalog)))
    (concat
     (when address
       (format " [%s › %s]"
               (or (dsh-emacs--chat-title (dsh-protocol-subagent-address-parent address))
                   (dsh-protocol-subagent-address-parent address))
               (format "%s · %s" (dsh-emacs-subagent-label address)
                       (dsh-protocol-subagent-address-mode address))))
     (when catalog
       (let ((label
              (or
               (when (and (display-graphic-p) (image-type-available-p 'svg))
                 (let* ((rgb (color-values (or (face-foreground 'dsh-emacs-modeline-face nil t)
                                               (face-foreground 'default nil t))))
                        (color (and rgb (apply #'format "#%02x%02x%02x"
                                               (mapcar (lambda (v) (/ v 256)) rgb)))))
                   (when color
                     (propertize
                      " " 'display
                      (create-image
                       (concat
                        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 16 16\" fill=\"none\" stroke=\""
                        color "\" stroke-width=\"1\" stroke-linecap=\"round\" stroke-linejoin=\"round\">"
                        "<g transform=\"rotate(90 8 8)\">"
                        "<path d=\"M8 3C8 .8 4.7 .7 4.2 2.8C2 2.3 .9 4.4 2.1 6C.2 7 .2 9 2.1 10C.9 11.6 2 13.7 4.2 13.2C4.7 15.3 8 15.2 8 13Z\"/>"
                        "<path d=\"M2.1 6C3.4 5.5 4.5 6.1 4.5 7.3M8 5.5h2l1.5-2h1.4M8 8h4.9M8 10.5h2l1.5 2h1.4\"/>"
                        "<circle cx=\"14\" cy=\"3.5\" r=\"1.1\"/>"
                        "<circle cx=\"14\" cy=\"8\" r=\"1.1\"/>"
                        "<circle cx=\"14\" cy=\"12.5\" r=\"1.1\"/></g></svg>")
                       'svg t :ascent 'center :height 1.0)))))
               (when (and (or (featurep 'nerd-icons) (require 'nerd-icons nil t))
                          (if (display-graphic-p)
                              (find-font (font-spec :family nerd-icons-font-family))
                            (char-displayable-p #xf062c)))
                 (nerd-icons-mdicon "nf-md-source_branch" :height 1.0 :v-adjust 0
                                    :face 'dsh-emacs-modeline-face))
               "Sub")))
         (propertize (concat
                      (propertize (concat " " label)
                                  'face 'dsh-emacs-modeline-face)
                      (propertize " " 'display '(space :relative-width 0.5))
                      (propertize (number-to-string (length catalog))
                                  'face '(:inherit dsh-emacs-modeline-face
                                          :weight bold)))
                     'local-map dsh-emacs-subagent-map 'mouse-face 'mode-line-highlight
                     'help-echo (format "%d subagents, %d running; mouse-1 to choose"
                                        (length catalog) running)))))))

(provide 'dsh-emacs-subagent)
;;; dsh-emacs-subagent.el ends here
