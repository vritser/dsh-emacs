;;; dsh-test-attachments.el --- Attachments tests -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "28.1"))

(require 'dsh-test-support)

;; Terminal-only Emacs builds omit this graphical capability variable.
(defvar image-types)

(ert-deftest dsh-emacs-test-attachments-data-preparation-without-entry-point ()
  :tags '(dsh-unit)
  (let ((file (make-temp-file "dsh-attachment-owner-" nil ".log")))
    (unwind-protect
        (progn
          (with-temp-file file (insert "payload"))
          (pcase-let ((`(,status . ,output)
                       (dsh-test--fresh-process
                        `(progn
                           (require 'ert)
                           (require 'dsh-emacs-attachments)
                           (should-not (featurep 'dsh-emacs))
                           (should-not (featurep 'dsh-emacs-composer))
                           (should-not (dsh-emacs-pending-attachments))
                           (should
                            (equal (dsh-emacs--attachable-file ,file)
                                   '((file . ,file)
                                     (name . ,(file-name-nondirectory file))
                                     (bytes . 7))))
                           (should (equal (dsh-emacs--binary-file-string ,file)
                                          "payload"))))))
            (ert-info (output)
              (should (equal status 0))
              (should (equal output "")))))
      (delete-file file))))

(ert-deftest dsh-emacs-test-attachments-autoload-initializes-coordinator ()
  :tags '(dsh-unit)
  (let* ((directory (make-temp-file "dsh-attachment-autoload-" t))
         (source (expand-file-name "dsh-emacs-attachments.el" directory))
         (loaddefs (expand-file-name "dsh-attachment-autoloads.el" directory)))
    (unwind-protect
        (progn
          (copy-file (expand-file-name "dsh-emacs-attachments.el"
                                       dsh-emacs-test-root)
                     source)
          (dsh-test--generate-autoloads source loaddefs)
          (dolist (command '(dsh-emacs-attach-file dsh-emacs-attach-clipboard-image
                                                   dsh-emacs-paste dsh-emacs-clear-attachments))
            (let ((form
                   `(progn
                      (require 'ert)
                      (load ,loaddefs nil t)
                      (should-not (featurep 'dsh-emacs))
                      (should (autoloadp (symbol-function ',command)))
                      (should
                       (equal (should-error (call-interactively ',command)
                                            :type 'user-error)
                              '(user-error "Not in a dsh chat buffer")))
                      (should (featurep 'dsh-emacs)))))
              (pcase-let ((`(,status . ,output)
                           (dsh-test--fresh-process form)))
                (ert-info ((format "%s: %s" command output))
                  (should (equal status 0)))))))
      (delete-directory directory t))))

(ert-deftest dsh-emacs-test-attachments-mode-reinitialization-clears-staging ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs--stage-attachments
     '(((file . "/tmp/not-uploaded") (name . "draft.log") (bytes . 7))))
    (should (dsh-emacs-pending-attachments))
    (dsh-emacs-mode)
    (should-not (dsh-emacs-pending-attachments))))

(defun dsh-test--has-text-property-p (prop)
  "Non-nil when some character in the current buffer carries PROP."
  (let ((pos (point-min))
        (found nil))
    (while (and (not found) (< pos (point-max)))
      (setq found (get-text-property pos prop))
      (unless found
        (setq pos (or (next-single-property-change pos prop)
                      (point-max)))))
    found))


;; --- Test 48: attachments (image base64 inlined into session/prompt) ---
(ert-deftest dsh-emacs-test-attachments-attach-image-stages-without-sending ()
  :tags '(dsh-unit)
  (let ((png-file (make-temp-file "dsh-test-1px" nil ".png"))
        (calls nil)
        (buf (generate-new-buffer " *dsh-attach-test*")))
    (unwind-protect
        (progn
          (with-temp-file png-file
            (set-buffer-multibyte nil)
            (insert (base64-decode-string
                     "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")))
          (with-current-buffer buf
            (dsh-emacs-mode)
            (setq dsh-emacs--current-session "sess-a")
            (setq-local dsh-emacs--buffer-session "sess-a")
            (dsh-emacs--ml-busy-clear)
            (dsh-emacs--replace-input "the pixel")
            (cl-letf (((symbol-function 'dsh-emacs-server-ensure) #'ignore)
                      ((symbol-function 'dsh-emacs--rpc-async)
                       (lambda (method params _cb)
                         (push (list method params) calls))))
              (dsh-emacs-attach-file png-file)
              (ert-info ((format "%s" "attach-image-stages-without-sending"))
                (should (null calls))
                (should (= 1 (length (dsh-emacs-pending-attachments))))
                (should (equal "the pixel" (dsh-emacs--get-input))))
              (dsh-emacs-send-or-stop))
            (let* ((call (car calls))
                   (params (cadr call))
                   (req (cdr (assq 'request params)))
                   (images (cdr (assq 'images params)))
                   (content (cdr (assq 'content req)))
                   (part (and content (aref content 0)))
                   (img (and content (> (length content) 1)
                             (aref content 1))))
              ;; Canonical wire shape (rpc.md §4.1): an image is a content
              ;; `{type:'image', mediaType, data, name}' block; there is no top-level images
              ;; field (the host schema strips it and the image never reaches the model).
              (ert-info ((format "%s" "attach-sends-caption"))
                (should (and (string= "session/prompt" (car call))
                             (null images)
                             (string= "the pixel" (cdr (assq 'text part))))))
              (ert-info ((format "%s" "attach-sends-image-part"))
                (should (and img
                             (string= "image" (cdr (assq 'type img)))
                             (string= "image/png" (cdr (assq 'mediaType img)))
                             (string-prefix-p "dsh-test-1px" (cdr (assq 'name img)))
                             (string-suffix-p ".png" (cdr (assq 'name img))))))
              (ert-info ((format "%s" "attach-base64-data"))
                (should (and img (stringp (cdr (assq 'data img)))
                             ;; The base64 of a 1x1 PNG is far longer than an empty string
                             (> (length (cdr (assq 'data img))) 20)
                             ;; No newlines: the wire base64 is one continuous string
                             (not (string-match-p "\n" (cdr (assq 'data img))))))))))
      (delete-file png-file)
      (kill-buffer buf))))

;; --- Test 48b: the image block of user/message renders as an [image]
;; placeholder (inline base64) ---
(ert-deftest dsh-emacs-test-attachments-image-inline-renders-placeholder ()
  :tags '(dsh-unit)
  (let ((png-b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")
        (buf (generate-new-buffer " *dsh-image-inline*")))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-mode)
          (dsh-emacs-modeline-setup)
          (dsh-emacs-render-event
           (json-read-from-string
            (concat "{\"type\":\"user/message\",\"seq\":1,\"data\":{\"content\":["
                    "{\"type\":\"text\",\"text\":\"the pixel\"},"
                    "{\"type\":\"image\",\"mediaType\":\"image/png\","
                    "\"data\":\"" png-b64 "\",\"name\":\"pixel.png\"}]}}")))
          (let* ((text (buffer-substring (point-min) (point-max)))
                 (pos (string-match "\\[image: pixel\\.png\\]" text))
                 (stash (and pos (get-text-property
                                  (1+ pos) 'dsh-emacs-image-data text)))
                 (img-id (and pos (get-text-property
                                   (1+ pos) 'dsh-emacs-image-id text))))
            ;; No graphics display in batch mode: display is not set, but the bytes
            ;; must already be in the placeholder, so RET-open works; body and
            ;; placeholder each take a line.
            (ert-info ((format "%s" "image-inline-renders-placeholder"))
              (should (and pos img-id
                           (string-match "the pixel\n\\[image: pixel.png\\]" text)
                           (equal stash (base64-decode-string png-b64)))))))
      (kill-buffer buf))))

;; --- Test 48b2: several image blocks share one gallery row (web-style
;; thumbnails), each keeping its own identity and stashed bytes ---
(ert-deftest dsh-emacs-test-attachments-image-gallery-row ()
  :tags '(dsh-unit)
  (let ((png-b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")
        (buf (generate-new-buffer " *dsh-image-gallery*")))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-mode)
          (dsh-emacs-modeline-setup)
          (dsh-emacs-render-event
           (json-read-from-string
            (concat "{\"type\":\"user/message\",\"seq\":3,\"data\":{\"content\":["
                    "{\"type\":\"text\",\"text\":\"two shots\"},"
                    "{\"type\":\"image\",\"mediaType\":\"image/png\","
                    "\"data\":\"" png-b64 "\",\"name\":\"a.png\"},"
                    "{\"type\":\"image\",\"mediaType\":\"image/png\","
                    "\"data\":\"" png-b64 "\",\"name\":\"b.png\"}]}}")))
          (let* ((text (buffer-substring (point-min) (point-max)))
                 (a-pos (string-match "\\[image: a\\.png\\]" text))
                 (b-pos (string-match "\\[image: b\\.png\\]" text))
                 (a-id (and a-pos (get-text-property
                                   (1+ a-pos) 'dsh-emacs-image-id text)))
                 (b-id (and b-pos (get-text-property
                                   (1+ b-pos) 'dsh-emacs-image-id text)))
                 (a-stash (and a-pos (get-text-property
                                      (1+ a-pos) 'dsh-emacs-image-data text))))
            ;; Both pictures occupy ONE row (a space, not a newline, between
            ;; them), so a multi-image message reads as a gallery rather than
            ;; a stack of full-width pictures; the async fill-in still finds
            ;; each slot by its own id.
            (ert-info ((format "%s" "image-gallery-row"))
              (should (string-match
                       "two shots\n\\[image: a\\.png\\] \\[image: b\\.png\\]"
                       text))
              (should (and a-id b-id (not (equal a-id b-id))))
              (should (equal a-stash (base64-decode-string png-b64))))))
      (kill-buffer buf))))

;; --- Test 48b3: a lone image uses the same thumbnail bounds as a gallery
;; image (one style for every image count) ---
(ert-deftest dsh-emacs-test-attachments-image-thumbnail-size-uniform ()
  :tags '(dsh-unit)
  (let ((png-b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")
        (buf (generate-new-buffer " *dsh-image-size*"))
        (dsh-emacs-render-image-thumbnail-lines 3)
        (image-types '(png))
        (sizes nil))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-mode)
          (dsh-emacs-modeline-setup)
          ;; Supply PNG support as well as a graphical display: terminal-only
          ;; builds omit `image-types'.  Capture bounds without decoding images.
          (cl-letf (((symbol-function 'display-graphic-p)
                     (lambda (&optional _frame) t))
                    ((symbol-function 'frame-char-height)
                     (lambda (&optional _frame) 20))
                    ((symbol-function 'create-image)
                     (lambda (_data _type &optional _data-p &rest props)
                       (push (cons (plist-get props :max-width)
                                   (plist-get props :max-height))
                             sizes)
                       nil)))
            (dsh-emacs-render-event
             (json-read-from-string
              (concat "{\"type\":\"user/message\",\"seq\":4,\"data\":{\"content\":["
                      "{\"type\":\"text\",\"text\":\"one\"},"
                      "{\"type\":\"image\",\"mediaType\":\"image/png\","
                      "\"data\":\"" png-b64 "\",\"name\":\"one.png\"}]}}")))
            (dsh-emacs-render-event
             (json-read-from-string
              (concat "{\"type\":\"user/message\",\"seq\":5,\"data\":{\"content\":["
                      "{\"type\":\"text\",\"text\":\"two\"},"
                      "{\"type\":\"image\",\"mediaType\":\"image/png\","
                      "\"data\":\"" png-b64 "\",\"name\":\"a.png\"},"
                      "{\"type\":\"image\",\"mediaType\":\"image/png\","
                      "\"data\":\"" png-b64 "\",\"name\":\"b.png\"}]}}")))
            (ert-info ((format "%s" "image-thumbnail-size-uniform"))
              ;; Newest first: the two gallery tiles, then the lone image.
              ;; Three 20-pixel text lines bound both dimensions to 60 pixels.
              (should (equal sizes '((60 . 60) (60 . 60) (60 . 60)))))))
      (kill-buffer buf))))

;; --- Test 48c: attachmentId reference block goes through
;; session/attachment backfill placeholder ---
(ert-deftest dsh-emacs-test-attachments-image-ref-fetched-via-session-attachment ()
  :tags '(dsh-unit)
  (let ((png-b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")
        (buf (generate-new-buffer " *dsh-image-ref*"))
        (calls nil))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-mode)
          (dsh-emacs-modeline-setup)
          (setq dsh-emacs--buffer-session "sess-ref")
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method params cb)
                       (push (list method params) calls)
                       (funcall cb t `((data . ,png-b64))))))
            (dsh-emacs-render-event
             (json-read-from-string
              (concat "{\"type\":\"user/message\",\"seq\":2,\"data\":{\"content\":["
                      "{\"type\":\"text\",\"text\":\"look\"},"
                      "{\"type\":\"image\",\"attachmentId\":\"att-1\","
                      "\"mediaType\":\"image/png\",\"name\":\"remote.png\"}]}}"))))
          (let* ((text (buffer-substring (point-min) (point-max)))
                 (pos (string-match "\\[image: remote\\.png\\]" text))
                 (call (car calls))
                 (req (cdr (assq 'request (cadr call))))
                 (stash (and pos (get-text-property
                                  (1+ pos) 'dsh-emacs-image-data text))))
            (ert-info ((format "%s" "image-ref-fetched-via-session-attachment"))
              (should (and (equal (car call) "session/attachment")
                           (equal (cdr (assq 'sessionId req)) "sess-ref")
                           (equal (cdr (assq 'attachmentId req)) "att-1")
                           (string-match "look\n\\[image: remote.png\\]" text)
                           (equal stash (base64-decode-string png-b64)))))))
      (kill-buffer buf))))

;; --- Test 48d: optimistic echo inlines the local attachment as
;; an image block (shown immediately, no RPC needed) ---
(ert-deftest dsh-emacs-test-attachments-image-optimistic-echo-inline ()
  :tags '(dsh-unit)
  (let ((png-b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")
        (buf (generate-new-buffer " *dsh-image-optimistic*")))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-mode)
          (dsh-emacs-modeline-setup)
          (setq dsh-emacs--buffer-session "sess-opt")
          (dsh-emacs--render-user-message-optimistic
           "the pixel"
           (list (list (cons 'mediaType "image/png")
                       (cons 'data png-b64)
                       (cons 'name "pixel.png"))))
          (let* ((text (buffer-substring (point-min) (point-max)))
                 (pos (string-match "\\[image: pixel\\.png\\]" text))
                 (stash (and pos (get-text-property
                                  (1+ pos) 'dsh-emacs-image-data text))))
            (ert-info ((format "%s" "image-optimistic-echo-inline"))
              (should (and (string-match "the pixel\n\\[image: pixel.png\\]" text)
                           (equal stash (base64-decode-string png-b64)))))))
      (kill-buffer buf))))

;; --- Test 48e: clipboard paste stages an attachment and a Composer row,
;; and the next send consumes both ---
(ert-deftest dsh-emacs-test-attachments-paste-stages-one-attachment ()
  :tags '(dsh-unit)
  (let* ((png-b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")
         (png-bytes (base64-decode-string png-b64))
         (calls nil)
         (buf (generate-new-buffer " *dsh-paste*")))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-mode)
          (dsh-emacs-modeline-setup)
          (setq dsh-emacs--buffer-session "sess-paste")
          (cl-letf (((symbol-function 'gui-get-selection)
                     (lambda (_sel type &rest _)
                       (and (eq type 'image/png) png-bytes))))
            (dsh-emacs-attach-clipboard-image))
          (let* ((staged (dsh-emacs-pending-attachments))
                 (attachment (car staged))
                 (name (cdr (assq 'name attachment))))
            (ert-info ((format "%s" "paste-stages-one-attachment"))
              (should (= 1 (length staged)))
              (should (equal "image/png" (cdr (assq 'mediaType attachment))))
              (should (equal png-b64 (cdr (assq 'data attachment))))
              (should (string-match-p "\\`pasted-.*\\.png\\'" name)))
            (ert-info ((format "%s" "paste-renders-composer-row"))
              (should (string-match-p
                       (regexp-quote name)
                       (buffer-substring-no-properties (point-min) (point-max))))
              (should (dsh-test--has-text-property-p
                       'dsh-emacs-composer-attachments-row)))
            ;; The leading icon must be the SVG clip (or the text fallback),
            ;; never a glyphless emoji box.
            (ert-info ((format "%s" "attachment-icon-avoids-glyphless-emoji"))
              (should (not (string-match-p
                            "🖼" (buffer-substring-no-properties (point-min) (point-max))))))
            ;; The caption rides along and the staging area empties.
            (goto-char dsh-emacs--input-marker)
            (insert "look at this")
            (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                       (lambda (method params _cb)
                         (push (list method params) calls)))
                      ((symbol-function 'dsh-emacs--busy-p) (lambda () nil)))
              (dsh-emacs-send-or-stop))
            (let* ((call (car calls))
                   (req (cdr (assq 'request (cadr call))))
                   (content (cdr (assq 'content req)))
                   (img (and (> (length content) 1) (aref content 1))))
              (ert-info ((format "%s" "paste-send-includes-image"))
                (should (equal "session/prompt" (car call)))
                (should (equal "look at this" (cdr (assq 'text (aref content 0)))))
                (should (equal "image" (cdr (assq 'type img))))
                (should (equal png-b64 (cdr (assq 'data img))))
                (should (equal name (cdr (assq 'name img)))))
              (ert-info ((format "%s" "paste-send-consumes-staging"))
                (should (null (dsh-emacs-pending-attachments)))
                (should (not (dsh-test--has-text-property-p
                              'dsh-emacs-composer-attachments-row)))))))
      (kill-buffer buf))))

(ert-deftest dsh-emacs-test-attachments-icon-renders-as-image ()
  :tags '(dsh-unit)
  (skip-unless (image-type-available-p 'svg))
  (with-temp-buffer
    (dsh-emacs-mode)
    (setq dsh-emacs--pending-attachments
          '(((name . "pasted.png") (mediaType . "image/png") (data . ""))))
    (dsh-emacs-composer-refresh)
    (let* ((property 'dsh-emacs-composer-attachments-row)
           (start (text-property-any (point-min) (point-max) property t)))
      (should start)
      (let ((end (next-single-property-change start property nil (point-max))))
        (should (cl-loop for pos from start below end
                         thereis (eq 'image (car-safe
                                             (get-text-property pos 'display)))))))))

;; --- Test 48f: a `!' line carrying a staged image goes to the model, not
;; the local shell ---
(ert-deftest dsh-emacs-test-attachments-paste-shell-line-goes-to-model ()
  :tags '(dsh-unit)
  (let* ((png-b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")
         (calls nil)
         (shell nil)
         (buf (generate-new-buffer " *dsh-paste-shell*")))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-mode)
          (dsh-emacs-modeline-setup)
          (setq dsh-emacs--buffer-session "sess-paste-shell")
          (setq dsh-emacs--pending-attachments
                (list (list (cons 'mediaType "image/png")
                            (cons 'data png-b64)
                            (cons 'name "pasted.png"))))
          (dsh-emacs-composer-refresh)
          (goto-char dsh-emacs--input-marker)
          (insert "!echo hi")
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method params _cb)
                       (push (list method params) calls)))
                    ((symbol-function 'dsh-emacs-shell-submit)
                     (lambda (&rest _) (setq shell t)))
                    ((symbol-function 'dsh-emacs--busy-p) (lambda () nil)))
            (dsh-emacs-send-or-stop))
          (ert-info ((format "%s" "paste-shell-line-goes-to-model"))
            (should (equal "session/prompt" (car (car calls))))
            (should (null shell))))
      (kill-buffer buf))))

;; --- Test 48g: an empty caption falls back to the staged image's name ---
(ert-deftest dsh-emacs-test-attachments-paste-empty-caption-uses-name ()
  :tags '(dsh-unit)
  (let* ((png-b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")
         (calls nil)
         (buf (generate-new-buffer " *dsh-paste-caption*")))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-mode)
          (dsh-emacs-modeline-setup)
          (setq dsh-emacs--buffer-session "sess-paste-caption")
          (setq dsh-emacs--pending-attachments
                (list (list (cons 'mediaType "image/png")
                            (cons 'data png-b64)
                            (cons 'name "pasted.png"))))
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method params _cb)
                       (push (list method params) calls)))
                    ((symbol-function 'dsh-emacs--busy-p) (lambda () nil)))
            (dsh-emacs-send-or-stop))
          (let* ((req (cdr (assq 'request (cadr (car calls)))))
                 (content (cdr (assq 'content req))))
            (ert-info ((format "%s" "paste-empty-caption-uses-name"))
              (should (equal "pasted.png" (cdr (assq 'text (aref content 0))))))))
      (kill-buffer buf))))

;; --- Test 48h: C-c C-d discards staged attachments and the row ---
(ert-deftest dsh-emacs-test-attachments-clear-attachments-discards-staged ()
  :tags '(dsh-unit)
  (let* ((png-b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")
         (buf (generate-new-buffer " *dsh-paste-clear*")))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-mode)
          (dsh-emacs-modeline-setup)
          (setq dsh-emacs--pending-attachments
                (list (list (cons 'mediaType "image/png")
                            (cons 'data png-b64)
                            (cons 'name "pasted.png"))))
          (dsh-emacs-composer-refresh)
          (dsh-emacs-clear-attachments)
          (ert-info ((format "%s" "clear-attachments-discards-staged"))
            (should (null (dsh-emacs-pending-attachments)))
            (should (not (dsh-test--has-text-property-p
                          'dsh-emacs-composer-attachments-row)))))
      (kill-buffer buf))))

;; --- Attachment row: file names only, one remove cell per file ---
(ert-deftest dsh-emacs-test-attachments-attachments-row-lists-file-names-only ()
  :tags '(dsh-unit)
  (let* ((first '((file . "/tmp/row-a.log") (name . "row-a.log") (bytes . 3)))
         (second '((file . "/tmp/row-b.txt") (name . "row-b.txt") (bytes . 4)))
         (buf (generate-new-buffer " *dsh-attach-row*")))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-mode)
          (dsh-emacs-modeline-setup)
          (setq dsh-emacs--buffer-session "sess-row")
          (setq dsh-emacs--pending-attachments (list first second))
          (dsh-emacs-composer-refresh)
          (let ((text (buffer-substring-no-properties (point-min) (point-max))))
            (ert-info ((format "%s" "attachments-row-lists-file-names-only"))
              (should (string-match-p "row-a\\.log" text))
              (should (string-match-p "row-b\\.txt" text))
              (should (not (string-match-p "attachment" text)))
              (should (= 2 (cl-count ?✕ text)))))
          (let* ((row-prop 'dsh-emacs-composer-attachments-row)
                 (cells (cl-loop for pos from (point-min) below (point-max)
                                 when (and (get-text-property pos row-prop)
                                           (get-text-property pos 'keymap))
                                 collect pos)))
            (ert-info ((format "%s" "attachments-row-has-one-remove-cell-per-file"))
              (should (= 2 (length
                            (cl-delete-duplicates
                             (mapcar (lambda (pos)
                                       (get-text-property pos 'keymap)) cells)
                             :test #'eq)))))
            (let* ((start (car cells))
                   (end (next-single-property-change start 'mouse-face))
                   (label (buffer-substring-no-properties start end)))
              (ert-info ("Only the remove glyph highlights and accepts clicks")
                (should (eq (get-text-property start 'mouse-face) 'highlight))
                (should (equal label "✕"))
                (dolist (pos (list (1- start) end))
                  (should (eq (char-after pos) ?\s))
                  (should-not (get-text-property pos 'mouse-face))
                  (should-not (get-text-property pos 'keymap)))))
            ;; Click the second file's ✕: only that file leaves the set.
            (let* ((cell (car (last cells)))
                   (cmd (lookup-key (get-text-property cell 'keymap) [mouse-1])))
              (ert-info ((format "%s" "attachments-row-remove-cell-is-clickable"))
                (should (functionp cmd))
                (should (equal "Remove row-b.txt · C-c C-d discards all"
                               (get-text-property cell 'help-echo))))
              (call-interactively cmd)))
          (let ((text (buffer-substring-no-properties (point-min) (point-max))))
            (ert-info ((format "%s" "attachments-row-remove-drops-only-its-file"))
              (should (equal (list first) (dsh-emacs-pending-attachments)))
              (should (string-match-p "row-a\\.log" text))
              (should (not (string-match-p "row-b\\.txt" text)))
              (should (= 1 (cl-count ?✕ text))))))
      (kill-buffer buf))))

;; --- A blank input sends the staged file names as the message text ---
(ert-deftest dsh-emacs-test-attachments-blank-caption-uses-staged-file-names ()
  :tags '(dsh-unit)
  (let* ((first '((file . "/tmp/cap-a.log") (name . "cap-a.log") (bytes . 3)))
         (second '((file . "/tmp/cap-b.txt") (name . "cap-b.txt") (bytes . 4)))
         (uploaded nil)
         (calls nil)
         (buf (generate-new-buffer " *dsh-attach-caption*")))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-mode)
          (dsh-emacs-modeline-setup)
          (setq dsh-emacs--buffer-session "sess-caption-names")
          (setq dsh-emacs--pending-attachments (list first second))
          (cl-letf (((symbol-function 'dsh-emacs--upload-file)
                     (lambda (_session attachment callback)
                       (push (cdr (assq 'name attachment)) uploaded)
                       (funcall callback
                                t
                                (dsh-protocol-file-receipt--from-alist
                                 `((receiptId . ,(cdr (assq 'name attachment)))))
                                nil)))
                    ((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method params _cb)
                       (push (list method params) calls)))
                    ((symbol-function 'dsh-emacs--busy-p) (lambda () nil)))
            (dsh-emacs-send-or-stop))
          (let* ((req (cdr (assq 'request (cadr (car calls)))))
                 (content (cdr (assq 'content req))))
            (ert-info ((format "%s" "blank-caption-uses-staged-file-names"))
              (should (equal "cap-a.log, cap-b.txt" (cdr (assq 'text (aref content 0)))))
              (should (equal '("cap-a.log" "cap-b.txt") (reverse uploaded))))))
      (kill-buffer buf))))

;; --- Test 48i: yank-media handler stages accepted types, refuses others ---
(ert-deftest dsh-emacs-test-attachments-yank-media-handler-stages ()
  :tags '(dsh-unit)
  (let* ((png-b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")
         (buf (generate-new-buffer " *dsh-paste-yank*")))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-mode)
          (dsh-emacs-modeline-setup)
          (cl-letf (((symbol-function 'dsh-emacs--clipboard-image-name)
                     (lambda (_media) "yanked.png")))
            (dsh-emacs--yank-media-handler
             'image/png (base64-decode-string png-b64))
            (ert-info ((format "%s" "yank-media-handler-stages"))
              (should (equal `(((mediaType . "image/png") (data . ,png-b64)
                                (name . "yanked.png")))
                             (dsh-emacs-pending-attachments))))
            (ert-info ((format "%s" "yank-media-handler-refuses-unsupported"))
              (should (equal "Unsupported clipboard media type: image/bmp"
                             (condition-case e
                                 (progn (dsh-emacs--yank-media-handler 'image/bmp "x") nil)
                               (user-error (error-message-string e))))))
            ;; A TIFF selection matches its own magic number, but the host does
            ;; not accept TIFF: it must be converted, never staged as-is.
            (cl-letf (((symbol-function 'executable-find) (lambda (_) "/usr/bin/sips"))
                      ((symbol-function 'call-process)
                       (lambda (_p _i _d _disp &rest args)
                         (dsh-emacs--write-binary-file
                          (cadr (member "--out" args))
                          (base64-decode-string png-b64))
                         0)))
              (setq dsh-emacs--pending-attachments nil)
              (dsh-emacs--yank-media-handler
               'image/tiff (concat (unibyte-string 73 73 42 0) "rest"))
              (ert-info ((format "%s" "yank-media-handler-converts-tiff"))
                (should (equal `(((mediaType . "image/png") (data . ,png-b64)
                                  (name . "yanked.png")))
                               (dsh-emacs-pending-attachments)))))))
      (kill-buffer buf))))

(defvar yank-media-preferred-types)

(ert-deftest dsh-emacs-test-attachments-yank-media-prefers-tiff-in-chat ()
  :tags '(dsh-unit)
  (skip-unless (>= emacs-major-version 31))
  (with-temp-buffer
    (dsh-emacs-mode)
    (should (memq 'image/tiff yank-media-preferred-types))))

;; --- Test 48j: clipboard reading (magic bytes, direct MIME targets,
;; macOS TIFF -> PNG fallback) ---
(ert-deftest dsh-emacs-test-attachments-image-bytes-match-magic ()
  :tags '(dsh-unit)
  (let* ((png-b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")
         (png-bytes (base64-decode-string png-b64))
         (tiff-bytes (concat (unibyte-string 73 73 42 0) "rest")))
    (ert-info ((format "%s" "image-bytes-match-magic"))
      (should (dsh-emacs--image-bytes-match-p "image/png" png-bytes))
      (should (not (dsh-emacs--image-bytes-match-p "image/jpeg" png-bytes)))
      (should (dsh-emacs--image-bytes-match-p "image/tiff" tiff-bytes))
      (should (not (dsh-emacs--image-bytes-match-p "image/tiff" (unibyte-string 1 2 3 4))))
      (should (dsh-emacs--image-bytes-match-p
               "image/webp"
               (concat (unibyte-string 82 73 70 70 0 0 0 0 87 69 66 80) "x")))
      (should (null (dsh-emacs--image-bytes-match-p
                     "image/webp" (unibyte-string 82 73 70 70)))))
    ;; A direct PNG flavor wins over the macOS TIFF flavor.
    (cl-letf (((symbol-function 'gui-get-selection)
               (lambda (_sel type &rest _)
                 (cond ((eq type 'image/png) png-bytes)
                       ((eq type 'image/tiff) tiff-bytes)))))
      (ert-info ((format "%s" "clipboard-prefers-png"))
        (should (equal (cons "image/png" png-bytes) (dsh-emacs--clipboard-image)))))
    ;; TIFF-only pasteboard (macOS) converts through `sips'.
    (cl-letf (((symbol-function 'gui-get-selection)
               (lambda (_sel type &rest _)
                 (and (eq type 'image/tiff) tiff-bytes)))
              ((symbol-function 'executable-find) (lambda (_) "/usr/bin/sips"))
              ((symbol-function 'call-process)
               (lambda (_prog _infile _dest _display &rest args)
                 (dsh-emacs--write-binary-file
                  (cadr (member "--out" args)) png-bytes)
                 0)))
      (ert-info ((format "%s" "clipboard-tiff-converts-to-png"))
        (should (equal (cons "image/png" png-bytes) (dsh-emacs--clipboard-image)))))
    (cl-letf (((symbol-function 'gui-get-selection) (lambda (&rest _) "")))
      (ert-info ((format "%s" "clipboard-no-image"))
        (should (null (dsh-emacs--clipboard-image)))))))

;; --- Test 48k: `s-v` pastes the clipboard image when there is
;; one, and yanks text otherwise ---
(ert-deftest dsh-emacs-test-attachments-s-v-bound-in-chat ()
  :tags '(dsh-unit)
  (let* ((png-b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")
         (png-bytes (base64-decode-string png-b64))
         (yanked nil)
         (buf (generate-new-buffer " *dsh-paste-key*")))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-mode)
          (dsh-emacs-modeline-setup)
          (setq dsh-emacs--buffer-session "sess-paste-key")
          (ert-info ((format "%s" "s-v-bound-in-chat"))
            (should (eq #'dsh-emacs-paste (key-binding (kbd "s-v")))))
          ;; An image on the clipboard is staged, never yanked as text.
          (cl-letf (((symbol-function 'gui-get-selection)
                     (lambda (_sel type &rest _)
                       (and (eq type 'image/png) png-bytes)))
                    ((symbol-function 'yank)
                     (lambda () (interactive) (setq yanked t))))
            (dsh-emacs-paste))
          (ert-info ((format "%s" "s-v-pastes-image"))
            (should (= 1 (length (dsh-emacs-pending-attachments))))
            (should (null yanked)))
          ;; A text-only clipboard falls back to the stock yank.
          (setq dsh-emacs--pending-attachments nil
                yanked nil)
          (cl-letf (((symbol-function 'gui-get-selection) (lambda (&rest _) ""))
                    ((symbol-function 'yank)
                     (lambda () (interactive) (setq yanked t))))
            (dsh-emacs-paste))
          (ert-info ((format "%s" "s-v-yanks-text-without-image"))
            (should (null (dsh-emacs-pending-attachments)))
            (should yanked)))
      (kill-buffer buf))))

;; --- Test 48l: the paste error says which problem it is ---
(ert-deftest dsh-emacs-test-attachments-paste-errors-unaccepted-type ()
  :tags '(dsh-unit)
  (let ((buf (generate-new-buffer " *dsh-paste-msg*")))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-mode)
          (dsh-emacs-modeline-setup)
          (setq dsh-emacs--buffer-session "sess-paste-msg")
          ;; An image flavor is on the clipboard but none is accepted.
          (cl-letf (((symbol-function 'gui-get-selection)
                     (lambda (_sel type &rest _)
                       (and (eq type 'TARGETS) [TARGETS image/bmp]))))
            (ert-info ((format "%s" "paste-errors-unaccepted-type"))
              (should (equal "Clipboard image type is not in dsh-emacs-attach-media-types"
                             (condition-case e
                                 (progn (dsh-emacs-attach-clipboard-image) nil)
                               (user-error (error-message-string e)))))))
          ;; Nothing image-shaped on the clipboard at all.
          (cl-letf (((symbol-function 'gui-get-selection)
                     (lambda (_sel type &rest _)
                       (and (eq type 'TARGETS) [TARGETS STRING]))))
            (ert-info ((format "%s" "paste-errors-no-image"))
              (should (equal "No image in the clipboard"
                             (condition-case e
                                 (progn (dsh-emacs-attach-clipboard-image) nil)
                               (user-error (error-message-string e))))))))
      (kill-buffer buf))))

;; --- Test 48m: an attachment-bearing prompt never enters the M-p recall
;; list (neither its synthesized caption nor a typed one); text-only does ---
(ert-deftest dsh-emacs-test-attachments-paste-synth-caption-not-in-history ()
  :tags '(dsh-unit)
  (let* ((png-b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")
         (attachment (list (cons 'mediaType "image/png")
                           (cons 'data png-b64)
                           (cons 'name "shot.png")))
         (history nil)
         (buf (generate-new-buffer " *dsh-paste-history*")))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-mode)
          (dsh-emacs-modeline-setup)
          (setq dsh-emacs--buffer-session "sess-paste-history")
          (cl-letf (((symbol-function 'dsh-emacs--push-input-history)
                     (lambda (text) (push text history)))
                    ((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (_method _params cb) (funcall cb t nil)))
                    ((symbol-function 'dsh-emacs--busy-p) (lambda () nil))
                    ((symbol-function 'dsh-emacs-server-ensure) #'ignore)
                    ((symbol-function 'dsh-emacs-events--watchdog-start) #'ignore)
                    ((symbol-function 'dsh-emacs-render--follow-stream) #'ignore)
                    ((symbol-function 'dsh-emacs--ml-busy-set) #'ignore)
                    ((symbol-function 'dsh-emacs--render-user-message-optimistic)
                     (lambda (&rest _) nil)))
            ;; Empty input with a staged image: the wire caption is the image
            ;; name, but M-p must not offer it back.
            (setq dsh-emacs--pending-attachments (list attachment))
            (dsh-emacs-send-or-stop)
            (ert-info ((format "%s" "paste-synth-caption-not-in-history"))
              (should (null history)))
            ;; A typed caption still rides an image, which M-p cannot replay:
            ;; it is not recorded either.
            (setq dsh-emacs--pending-attachments (list attachment)
                  history nil)
            (dsh-emacs--replace-input "look at this")
            (dsh-emacs-send-or-stop)
            (ert-info ((format "%s" "paste-typed-caption-not-in-history"))
              (should (null history)))
            ;; Plain text with no attachments is recorded as usual.
            (setq dsh-emacs--pending-attachments nil
                  history nil)
            (dsh-emacs--replace-input "just words")
            (dsh-emacs-send-or-stop)
            (ert-info ((format "%s" "text-prompt-recorded-in-history"))
              (should (equal '("just words") history)))))
      (kill-buffer buf))))

;; --- Test 48n: a failure callback invoked synchronously (before the submit
;; returns) still restores the whole draft, text and images together ---
(ert-deftest dsh-emacs-test-attachments-sync-failure-restores-draft-case ()
  :tags '(dsh-unit)
  (dolist (path '(plain deferred command))
    (with-temp-buffer
      (dsh-emacs-mode)
      (dsh-emacs-modeline-setup)
      (setq dsh-emacs--buffer-session "sync-fail")
      (let* ((image (list (cons 'mediaType "image/png")
                          (cons 'data "b2xk") (cons 'name "shot.png")))
             (caption (if (eq path 'command) "/test" "look at this")))
        (setq dsh-emacs--pending-attachments (list image))
        (dsh-emacs--replace-input caption)
        (cl-letf (((symbol-function 'dsh-emacs-server-ensure) #'ignore)
                  ((symbol-function 'dsh-emacs--busy-p) (lambda () nil))
                  ((symbol-function 'dsh-emacs--render-user-message-optimistic)
                   (lambda (&rest _) nil))
                  ;; The failure lands inside the submit call, before
                  ;; `dsh-emacs-send-or-stop' regains control.
                  ((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (_method _params cb) (funcall cb nil "rejected"))))
          (let ((current-prefix-arg (and (eq path 'deferred) '(4))))
            (dsh-emacs-send-or-stop)))
        (ert-info ((format "%s" (format "sync-failure-restores-draft-%s" path)))
          (should (equal (dsh-emacs--get-input) caption))
          (should (equal (dsh-emacs-pending-attachments) (list image))))))))

;; A submit that throws instead of reaching its callback must restore the
;; consumed draft and let the error surface.
(ert-deftest dsh-emacs-test-attachments-sync-signal-restores-draft ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-modeline-setup)
    (setq dsh-emacs--buffer-session "sync-signal")
    (let ((image (list (cons 'mediaType "image/png")
                       (cons 'data "b2xk") (cons 'name "shot.png"))))
      (setq dsh-emacs--pending-attachments (list image))
      (dsh-emacs--replace-input "look at this")
      (cl-letf (((symbol-function 'dsh-emacs-server-ensure) #'ignore)
                ((symbol-function 'dsh-emacs--busy-p) (lambda () nil))
                ((symbol-function 'dsh-emacs--submit-prompt)
                 (lambda (&rest _) (error "submit blew up"))))
        (ert-info ((format "%s" "sync-signal-restores-draft"))
          (should (equal "submit blew up"
                         (condition-case e (progn (dsh-emacs-send-or-stop) nil)
                           (error (error-message-string e)))))
          (should (equal "look at this" (dsh-emacs--get-input)))
          (should (equal (list image) (dsh-emacs-pending-attachments))))))))

;; Failed submissions restore text and images as one draft, never mixing an
;; old caption/image with a new draft composed while the RPC was in flight.
(ert-deftest dsh-emacs-test-attachments-failed-case-preserves-case-draft ()
  :tags '(dsh-unit)
  (dolist (path '(plain deferred command))
    (dolist (new-draft '(empty text image))
      (with-temp-buffer
        (dsh-emacs-mode)
        (setq dsh-emacs--buffer-session "restore-test")
        (let* ((old-image '((mediaType . "image/png") (data . "b2xk")
                            (name . "old.png")))
               (new-image '((mediaType . "image/png") (data . "bmV3")
                            (name . "new.png")))
               (caption (if (eq path 'command) "/test" "old caption"))
               callback)
          (setq dsh-emacs--pending-attachments (list old-image))
          (dsh-emacs--replace-input caption)
          (cl-letf (((symbol-function 'dsh-emacs-server-ensure) #'ignore)
                    ((symbol-function 'dsh-emacs--busy-p) (lambda () nil))
                    ((symbol-function 'dsh-emacs--render-user-message-optimistic)
                     (lambda (&rest _) nil))
                    ((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (_method _params cb) (setq callback cb))))
            (let ((current-prefix-arg (and (eq path 'deferred) '(4))))
              (dsh-emacs-send-or-stop))
            (pcase new-draft
              ('text (dsh-emacs--replace-input "new caption"))
              ('image (dsh-emacs--stage-attachments (list new-image))))
            (funcall callback nil "rejected")
            (ert-info ((format "%s" (format "failed-%s-preserves-%s-draft" path new-draft)))
              (should (equal (dsh-emacs--get-input)
                             (pcase new-draft ('empty caption) ('text "new caption")
                                    ('image ""))))
              (should (equal (dsh-emacs-pending-attachments)
                             (pcase new-draft ('empty (list old-image)) ('text nil)
                                    ('image (list new-image))))))))))))

;; TIFF conversion must obey the acceptance list in both paste entry points.
(ert-deftest dsh-emacs-test-attachments-clipboard-tiff-obeys-types-case ()
  :tags '(dsh-unit)
  (dolist (allowed '(nil ("image/jpeg")))
    (with-temp-buffer
      (dsh-emacs-mode)
      (let ((dsh-emacs-attach-media-types allowed)
            (conversions 0))
        (cl-letf (((symbol-function 'dsh-emacs--selection-bytes)
                   (lambda (media) (and (equal media "image/tiff") "tiff")))
                  ((symbol-function 'dsh-emacs--tiff-bytes-to-png)
                   (lambda (_) (setq conversions (1+ conversions)) "png")))
          (ert-info ((format "%s" (format "clipboard-tiff-obeys-types-%S" allowed)))
            (should (null (dsh-emacs--clipboard-image))))
          (ert-info ((format "%s" (format "yank-tiff-obeys-types-%S" allowed)))
            (should (condition-case nil
                        (progn (dsh-emacs--yank-media-handler 'image/tiff "tiff") nil)
                      (user-error t))))
          (ert-info ((format "%s" (format "disallowed-png-never-converted-%S" allowed)))
            (should (= conversions 0))
            (should (null (dsh-emacs-pending-attachments)))))))))

;; --- Test 122a: staged file attachments -- the entry model ---
;; An accepted image carries inline base64; every other file becomes a
;; metadata-only staged entry uploaded at submit time (see 122b-122e).
(ert-deftest dsh-emacs-test-attachments-attachable-file-inlines-image ()
  :tags '(dsh-unit)
  (let* ((png-b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")
         (png (make-temp-file "dsh-fa-img" nil ".png"))
         (txt (make-temp-file "dsh-fa-note" nil ".txt"))
         (big (make-temp-file "dsh-fa-big" nil ".bin")))
    (unwind-protect
        (progn
          (with-temp-file png
            (set-buffer-multibyte nil)
            (insert (base64-decode-string png-b64)))
          (with-temp-file txt (insert "notes\n"))
          (with-temp-file big (insert (make-string 32 ?x)))
          (let ((image (dsh-emacs--attachable-file png))
                (file (dsh-emacs--attachable-file txt)))
            (ert-info ((format "%s" "attachable-file-inlines-image"))
              (should (equal image
                             `((mediaType . "image/png") (data . ,png-b64)
                               (name . ,(file-name-nondirectory png)))))
              (should (equal (dsh-protocol-image-content-part image)
                             `((type . "image") (mediaType . "image/png")
                               (data . ,png-b64)
                               (name . ,(file-name-nondirectory png))))))
            (ert-info ((format "%s" "attachable-file-stages-other-file"))
              (should (equal (expand-file-name txt) (cdr (assq 'file file))))
              (should (equal (file-name-nondirectory txt) (cdr (assq 'name file))))
              (should (equal 6 (cdr (assq 'bytes file))))
              (should (dsh-emacs--attachment-file-p file))
              (should (null (dsh-protocol-image-content-part file)))
              (should (null (dsh-emacs--attachment-file-p image))))
            ;; The cap refuses before anything is read; nil lifts it.
            (let ((dsh-emacs-attach-max-file-size 8))
              (ert-info ((format "%s" "staged-file-attachment-honors-size-cap"))
                (should (null (dsh-emacs--attachable-file big)))))
            (let ((dsh-emacs-attach-max-file-size nil))
              (ert-info ((format "%s" "staged-file-attachment-cap-nil-is-no-limit"))
                (should (dsh-emacs--attachment-file-p (dsh-emacs--attachable-file big)))))
            (ert-info ((format "%s" "attachable-file-refuses-missing-path"))
              (should (null (dsh-emacs--attachable-file
                             (expand-file-name "dsh-fa-missing" temporary-file-directory)))))))
      (delete-file png)
      (delete-file txt)
      (delete-file big))))

;; --- Test 122b: the raw upload route posts the exact bytes and reads the
;; receipt (rpc.md §4.17) ---
(ert-deftest dsh-emacs-test-attachments-upload-file-posts-raw-bytes ()
  :tags '(dsh-unit)
  (let* ((file (make-temp-file "dsh-upload" nil ".pdf"))
         (entry (list (cons 'file file) (cons 'name "report.pdf")
                      (cons 'bytes 5)))
         (requests nil)
         (pending nil)
         (response nil)
         (result 'unset))
    (unwind-protect
        (progn
          (with-temp-file file
            (set-buffer-multibyte nil)
            (insert (unibyte-string 0 1 2 255 65)))
          (cl-labels
              ((stub ()
                 (lambda (url callback &optional _args _silent _inhibit)
                   (push (list url (copy-sequence url-request-extra-headers)
                               url-request-method url-request-data)
                         requests)
                   (setq pending callback
                         response (generate-new-buffer " *dsh-upload-http*"))))
               (answer (body)
                 (with-current-buffer response
                   (setq-local url-http-response-status 200)
                   (insert "HTTP/1.1 200 OK\ncontent-type: application/json\n\n"
                           body)
                   (funcall pending nil))
                 (when (buffer-live-p response) (kill-buffer response))
                 (setq response nil)))
            (cl-letf (((symbol-function 'url-retrieve) (stub)))
              (dsh-emacs--upload-file
               "sess-up" entry
               (lambda (ok value error) (setq result (list ok value error))))
              (answer "{\"ok\":true,\"value\":{\"receiptId\":\"r-9\",\"file\":{\"attachmentId\":\"sha256:9\",\"name\":\"report.pdf\",\"bytes\":5}}}"))
            (let* ((req (car requests))
                   (ref (dsh-protocol-file-receipt-file (nth 1 result))))
              (ert-info ((format "%s" "upload-file-posts-raw-bytes"))
                (should (equal "POST" (nth 2 req)))
                (should (equal "application/octet-stream"
                               (cdr (assoc "Content-Type" (nth 1 req)))))
                (should (string-match-p
                         "/api/session/uploadFileBinary\\?sessionId=sess-up&name=report\\.pdf\\'"
                         (car req)))
                (should (equal (unibyte-string 0 1 2 255 65) (nth 3 req))))
              (ert-info ((format "%s" "upload-file-parses-receipt"))
                (should (eq t (car result)))
                (should (equal "r-9" (dsh-protocol-file-receipt-receipt-id (nth 1 result))))
                (should (equal "report.pdf" (dsh-protocol-file-ref-name ref)))
                (should (equal 5 (dsh-protocol-file-ref-bytes ref)))
                (should (equal "sha256:9" (dsh-protocol-file-ref-attachment-id ref)))
                (should (null (nth 2 result)))))
            ;; The route reports its own failure inside a 200 body.
            (setq result 'unset requests nil)
            (cl-letf (((symbol-function 'url-retrieve) (stub)))
              (dsh-emacs--upload-file
               "sess-up" entry
               (lambda (ok value error) (setq result (list ok value error))))
              (answer "{\"ok\":false,\"error\":{\"code\":\"session/not-found\",\"message\":\"no session\"}}"))
            (ert-info ((format "%s" "upload-file-surfaces-route-error"))
              (should (null (car result)))
              (should (null (nth 1 result)))
              (should (equal "session/not-found" (cdr (assq 'code (nth 2 result)))))
              (should (equal "no session" (cdr (assq 'message (nth 2 result))))))
            ;; A transport failure reaches the same callback with nil.
            (setq result 'unset)
            (cl-letf (((symbol-function 'url-retrieve) (stub)))
              (dsh-emacs--upload-file
               "sess-up" entry
               (lambda (ok value error) (setq result (list ok value error))))
              (with-current-buffer response
                (funcall pending '(:error (error http 400))))
              (when (buffer-live-p response) (kill-buffer response))
              (setq response nil))
            (ert-info ((format "%s" "upload-file-transport-failure-reports-nil"))
              (should (equal '(nil nil nil) result)))))
      (delete-file file))))

;; --- Test 122c: mixed staged attachments resolve in staged order, one file
;; upload after another ---
(ert-deftest dsh-emacs-test-attachments-upload-attachments-resolves-in-staged-order ()
  :tags '(dsh-unit)
  (let* ((image '((mediaType . "image/png") (extra . "keep")
                  (data . "eA==") (name . "shot.png")))
         (fa (list (cons 'file "/tmp/a.pdf") (cons 'name "a.pdf") (cons 'bytes 1)))
         (fb (list (cons 'file "/tmp/b.log") (cons 'name "b.log") (cons 'bytes 2)))
         (uploaded nil)
         (parts 'unset))
    (cl-letf (((symbol-function 'dsh-emacs--upload-file)
               (lambda (_session attachment callback)
                 (push (cdr (assq 'name attachment)) uploaded)
                 (funcall callback
                          t
                          (dsh-protocol-file-receipt--from-alist
                           `((receiptId . ,(concat "r-" (cdr (assq 'name attachment))))
                             (file . ((attachmentId . "sha256:remote")
                                      (name . "remote.txt") (bytes . 9)))))
                          nil))))
      (dsh-emacs--upload-attachments
       "sess-up" (list image fa fb)
       (lambda (ok value error) (setq parts (list ok value error)))))
    (ert-info ((format "%s" "upload-attachments-resolves-in-staged-order"))
      (should (eq t (car parts)))
      (should (equal (nth 1 parts)
                     '(((type . "image") (mediaType . "image/png")
                        (extra . "keep") (data . "eA==") (name . "shot.png"))
                       ((type . "file") (receiptId . "r-a.pdf"))
                       ((type . "file") (receiptId . "r-b.log")))))
      (should (eq image (cdr (car (nth 1 parts)))))
      (should (equal image '((mediaType . "image/png") (extra . "keep")
                             (data . "eA==") (name . "shot.png"))))
      (should (null (nth 2 parts)))
      (should (equal '("a.pdf" "b.log") (nreverse uploaded))))))

;; A failing upload stops the chain and reports no parts.
(ert-deftest dsh-emacs-test-attachments-upload-attachments-stops-on-failure ()
  :tags '(dsh-unit)
  (let* ((fa (list (cons 'file "/tmp/a.pdf") (cons 'name "a.pdf") (cons 'bytes 1)))
         (fb (list (cons 'file "/tmp/b.log") (cons 'name "b.log") (cons 'bytes 2)))
         (calls 0)
         (out 'unset))
    (cl-letf (((symbol-function 'dsh-emacs--upload-file)
               (lambda (_session attachment callback)
                 (setq calls (1+ calls))
                 (funcall callback nil nil
                          (list (cons 'code "session/attachment-invalid")
                                (cons 'message "File was not uploaded for this session."))))))
      (dsh-emacs--upload-attachments
       "sess-up" (list fa fb)
       (lambda (ok value error) (setq out (list ok value error)))))
    (ert-info ((format "%s" "upload-attachments-stops-on-failure"))
      (should (equal 1 calls))
      (should (null (car out)))
      (should (null (nth 1 out)))
      (should (equal "session/attachment-invalid" (cdr (assq 'code (nth 2 out))))))
    ;; No session to upload into is a user error, thrown synchronously so the
    ;; send path can restore the draft.
    (ert-info ((format "%s" "upload-attachments-requires-session"))
      (should (condition-case nil
                  (progn (dsh-emacs--upload-attachments nil (list fa) #'ignore) nil)
                (user-error t))))))

;; --- Test 122d: a staged file reaches session/prompt as a receipt part ---
(ert-deftest dsh-emacs-test-attachments-submit-prompt-uploads-then-sends-receipt ()
  :tags '(dsh-unit)
  (let ((buf (generate-new-buffer " *dsh-file-submit*"))
        (calls nil)
        (uploaded nil))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-mode)
          (setq dsh-emacs--current-session "sess-file")
          (setq-local dsh-emacs--buffer-session "sess-file")
          (dsh-emacs--ml-busy-clear)
          (let ((entry (list (cons 'file "/tmp/report.pdf")
                             (cons 'name "report.pdf") (cons 'bytes 5))))
            (cl-letf (((symbol-function 'dsh-emacs--upload-file)
                       (lambda (session attachment callback)
                         (push (list session (cdr (assq 'name attachment))) uploaded)
                         (funcall callback
                                  t
                                  (dsh-protocol-file-receipt--from-alist
                                   '((receiptId . "r-1")))
                                  nil)))
                      ((symbol-function 'dsh-emacs--rpc-async)
                       (lambda (method params cb)
                         (push (list method params) calls)
                         (funcall cb t '((accepted . t))))))
              (dsh-emacs--submit-prompt "please read" (list entry)))
            (let* ((call (car calls))
                   (params (cadr call))
                   (content (cdr (assq 'content
                                       (cdr (assq 'request params)))))
                   (block (and content (> (length content) 1)
                               (aref content 1))))
              (ert-info ((format "%s" "submit-prompt-uploads-then-sends-receipt"))
                (should (equal '(("sess-file" "report.pdf")) (nreverse uploaded)))
                (should (equal "session/prompt" (car call)))
                (should (equal "please read" (cdr (assq 'text (aref content 0)))))
                (should (equal '((type . "file") (receiptId . "r-1"))
                               (append block nil)))
                (should (null (assq 'data block))))
              ;; The optimistic echo is kept when the canonical event arrives, so
              ;; it must already name and size the file.
              (ert-info ((format "%s" "submit-prompt-echoes-file-chip"))
                (should (string-match-p
                         "\\[file: report\\.pdf · 5 B\\]"
                         (buffer-substring-no-properties (point-min) (point-max))))))))
      (kill-buffer buf))))

;; --- Test 122e: a failed upload restores the draft and sends nothing ---
(ert-deftest dsh-emacs-test-attachments-submit-prompt-upload-failure-restores-draft ()
  :tags '(dsh-unit)
  (let ((buf (generate-new-buffer " *dsh-file-fail*"))
        (calls nil))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-mode)
          (setq dsh-emacs--current-session "sess-file-fail")
          (setq-local dsh-emacs--buffer-session "sess-file-fail")
          (dsh-emacs--ml-busy-clear)
          (let ((entry (list (cons 'file "/tmp/big.pdf")
                             (cons 'name "big.pdf") (cons 'bytes 9)))
                (fail (lambda (_session _attachment callback)
                        (funcall callback
                                 nil nil
                                 (list (cons 'code "session/attachment-invalid")
                                       (cons 'message "File was not uploaded."))))))
            ;; File submission clears the input before uploading (so it cannot
            ;; be double-sent); even a synchronous failure restores both.
            (goto-char dsh-emacs--input-marker)
            (insert "captain")
            (cl-letf (((symbol-function 'dsh-emacs--upload-file) fail)
                      ((symbol-function 'dsh-emacs--rpc-async)
                       (lambda (method params _cb)
                         (push (list method params) calls))))
              (dsh-emacs--submit-prompt "captain" (list entry)))
            (ert-info ((format "%s" "submit-prompt-upload-failure-restores-draft"))
              (should (string= "captain" (dsh-emacs--get-input)))
              (should (equal (list entry) (dsh-emacs-pending-attachments)))
              (should (null calls)))
            ;; A newer draft typed meanwhile is never clobbered — and the
            ;; consumed attachment set is not re-staged under it.
            (dsh-emacs--clear-input)
            (setq dsh-emacs--pending-attachments nil)
            (let ((pending nil))
              (cl-letf (((symbol-function 'dsh-emacs--upload-file)
                         (lambda (_session _attachment callback)
                           (setq pending callback)))
                        ((symbol-function 'dsh-emacs--rpc-async)
                         (lambda (method params _cb)
                           (push (list method params) calls))))
                (dsh-emacs--submit-prompt "captain" (list entry))
                (dsh-emacs--replace-input "newer draft")
                (funcall pending nil nil '((message . "Upload failed")))))
            (ert-info ((format "%s" "submit-prompt-upload-failure-keeps-newer-draft"))
              (should (string= "newer draft" (dsh-emacs--get-input)))
              (should (null (dsh-emacs-pending-attachments)))
              (should (null calls)))))
      (kill-buffer buf))))

;; --- Test 122f: a durable file block renders as a size-labelled chip ---
(ert-deftest dsh-emacs-test-attachments-user-message-renders-file-chip ()
  :tags '(dsh-unit)
  (let ((buf (generate-new-buffer " *dsh-file-render*")))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-mode)
          (dsh-emacs-modeline-setup)
          (dsh-emacs-render-event
           (json-read-from-string
            (concat "{\"type\":\"user/message\",\"seq\":3,\"data\":{\"content\":["
                    "{\"type\":\"text\",\"text\":\"have a look\"},"
                    "{\"type\":\"file\",\"attachment\":{\"attachmentId\":\"sha256:a\","
                    "\"name\":\"notes.txt\",\"bytes\":2048}}]}}")))
          (let* ((text (buffer-substring-no-properties (point-min) (point-max)))
                 (pos (string-match "\\[file: notes\\.txt · 2\\.0 KB\\]" text)))
            (ert-info ((format "%s" "user-message-renders-file-chip"))
              (should pos)
              (should (string-match-p "have a look\n\\[file: notes\\.txt · 2\\.0 KB\\]" text))
              (should (null (get-text-property pos 'keymap (buffer-substring (point-min)
                                                                             (point-max))))))))
      (kill-buffer buf))))

;; --- Test 122g: protocol file reference / upload receipt and byte sizes ---
(ert-deftest dsh-emacs-test-attachments-protocol-file-receipt-parses ()
  :tags '(dsh-unit)
  (let* ((receipt (dsh-protocol-file-receipt--from-alist
                   '((receiptId . "r-1")
                     (file . ((attachmentId . "sha256:a")
                              (name . "n.pdf") (bytes . 12))))))
         (ref (dsh-protocol-file-receipt-file receipt))
         (empty (dsh-protocol-file-receipt--from-alist nil)))
    (ert-info ((format "%s" "protocol-file-receipt-parses"))
      (should (equal "r-1" (dsh-protocol-file-receipt-receipt-id receipt)))
      (should (equal "sha256:a" (dsh-protocol-file-ref-attachment-id ref)))
      (should (equal "n.pdf" (dsh-protocol-file-ref-name ref)))
      (should (equal 12 (dsh-protocol-file-ref-bytes ref))))
    (ert-info ((format "%s" "protocol-file-receipt-nil-safe"))
      (should (null (dsh-protocol-file-receipt-receipt-id empty)))
      (should (null (dsh-protocol-file-receipt-file empty))))
    (ert-info ((format "%s" "format-bytes-scales"))
      (should (equal "512 B" (dsh-emacs-format-bytes 512)))
      (should (equal "2.0 KB" (dsh-emacs-format-bytes 2048)))
      (should (equal "5.0 MB" (dsh-emacs-format-bytes (* 5 1024 1024))))
      (should (equal "?" (dsh-emacs-format-bytes nil)))
      (should (equal "?" (dsh-emacs-format-bytes "x"))))))

;; --- Test 122h: repeated `C-c C-a' stages files until an explicit send ---
(ert-deftest dsh-emacs-test-attachments-attach-picker-requires-existing-file ()
  :tags '(dsh-unit)
  (let* ((file (make-temp-file "dsh-attach-entry" nil ".log"))
         (second-file (make-temp-file "dsh-attach-second" nil ".txt"))
         (buf (generate-new-buffer " *dsh-attach-entry*"))
         (uploaded nil)
         (server-checks 0)
         (calls nil))
    (unwind-protect
        (progn
          (with-temp-file file (insert "log line\n"))
          (with-temp-file second-file (insert "second file\n"))
          (with-current-buffer buf
            (dsh-emacs-mode)
            (setq dsh-emacs--current-session "sess-entry")
            (setq-local dsh-emacs--buffer-session "sess-entry")
            (dsh-emacs--ml-busy-clear)
            (dsh-emacs--replace-input "see the logs")
            (cl-letf (((symbol-function 'dsh-emacs-server-ensure)
                       (lambda () (cl-incf server-checks)))
                      ((symbol-function 'dsh-emacs--upload-file)
                       (lambda (_session attachment callback)
                         (push (cdr (assq 'name attachment)) uploaded)
                         (funcall callback
                                  t
                                  (dsh-protocol-file-receipt--from-alist
                                   `((receiptId . ,(format "r-%d" (length uploaded)))))
                                  nil)))
                      ((symbol-function 'dsh-emacs--rpc-async)
                       (lambda (method params cb)
                         (push (list method params) calls)
                         (funcall cb t '((accepted . t)))))
                      ((symbol-function 'read-file-name)
                       (lambda (_prompt _dir _default mustmatch &rest _)
                         (ert-info ((format "%s" "attach-picker-requires-existing-file"))
                           (should mustmatch))
                         file))
                      ((symbol-function 'read-string)
                       (lambda (&rest _) (error "Unexpected caption prompt"))))
              (call-interactively #'dsh-emacs-attach-file)
              (dsh-emacs-attach-file second-file)
              (ert-info ((format "%s" "attach-files-append-without-network-or-input-changes"))
                (should (zerop server-checks))
                (should (null uploaded))
                (should (null calls))
                (should (equal "see the logs" (dsh-emacs--get-input)))
                (should (equal (list file second-file)
                               (mapcar (lambda (entry) (cdr (assq 'file entry)))
                                       (dsh-emacs-pending-attachments)))))
              (dsh-emacs-send-or-stop))
            (let* ((params (cadr (car calls)))
                   (content (cdr (assq 'content
                                       (cdr (assq 'request params))))))
              (ert-info ((format "%s" "attach-files-upload-together-on-send"))
                (should (= 1 (length calls)))
                (should (equal "session/prompt" (caar calls)))
                (should (equal (list (file-name-nondirectory file)
                                     (file-name-nondirectory second-file))
                               (reverse uploaded)))
                (should (= 3 (length content)))
                (should (equal "see the logs" (cdr (assq 'text (aref content 0)))))
                (should (equal '((type . "file") (receiptId . "r-1"))
                               (aref content 1)))
                (should (equal '((type . "file") (receiptId . "r-2"))
                               (aref content 2)))
                (should (null (dsh-emacs-pending-attachments)))))))
      (delete-file file)
      (delete-file second-file)
      (kill-buffer buf))))

;; Attachment acquisition preserves the existing draft on cancel/rejection,
;; and a multi-file drop appends to clipboard staging without a network call.
(ert-deftest dsh-emacs-test-attachments-attach-cancel-or-invalid-keeps-draft ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs--replace-input "keep this caption")
    (let* ((image '((mediaType . "image/png") (data . "eA==")
                    (name . "clipboard.png")))
           (first '((file . "/tmp/first.log") (name . "first.log") (bytes . 3)))
           (second '((file . "/tmp/second.txt") (name . "second.txt") (bytes . 4)))
           (confirm t))
      (dsh-emacs--stage-attachments (list image))
      (cl-letf (((symbol-function 'dsh-emacs-server-ensure)
                 (lambda () (error "Staging must not start the server")))
                ((symbol-function 'dsh-emacs--submit-prompt)
                 (lambda (&rest _) (error "Staging must not submit")))
                ((symbol-function 'dnd-get-local-file-name)
                 (lambda (path &rest _) path))
                ((symbol-function 'dsh-emacs--attachable-file)
                 (lambda (path)
                   (cond ((equal path "/tmp/first.log") first)
                         ((equal path "/tmp/second.txt") second))))
                ((symbol-function 'y-or-n-p) (lambda (&rest _) confirm))
                ((symbol-function 'read-file-name)
                 (lambda (&rest _) (signal 'quit nil))))
        (let ((cancelled nil) (rejected nil))
          (condition-case nil
              (call-interactively #'dsh-emacs-attach-file)
            (quit (setq cancelled t)))
          (condition-case nil
              (dsh-emacs-attach-file "/tmp/invalid")
            (user-error (setq rejected t)))
          (ert-info ((format "%s" "attach-cancel-or-invalid-keeps-draft"))
            (should cancelled)
            (should rejected)
            (should (equal (list image) (dsh-emacs-pending-attachments)))
            (should (equal "keep this caption" (dsh-emacs--get-input)))))
        (dsh-emacs--dnd-attach
         '(drag-n-drop ("/tmp/first.log" "/tmp/invalid" "/tmp/second.txt")))
        (ert-info ((format "%s" "drop-appends-valid-files-in-order"))
          (should (equal (list image first second) (dsh-emacs-pending-attachments)))
          (should (equal "keep this caption" (dsh-emacs--get-input))))
        (setq confirm nil)
        (dsh-emacs--dnd-attach '(drag-n-drop ("/tmp/first.log")))
        (ert-info ((format "%s" "drop-cancel-keeps-staged-set"))
          (should (equal (list image first second) (dsh-emacs-pending-attachments))))
        (dsh-emacs-clear-attachments)
        (ert-info ((format "%s" "discard-mixed-attachments-keeps-caption"))
          (should (null (dsh-emacs-pending-attachments)))
          (should (equal "keep this caption" (dsh-emacs--get-input))))))))

;; Reject acquisition before opening the picker or reading files in contexts
;; that cannot own staged attachments.
(ert-deftest dsh-emacs-test-attachments-attachment-acquisition-rejects-case ()
  :tags '(dsh-unit)
  (dolist (context '(outside-chat subagent))
    (with-temp-buffer
      (when (eq context 'subagent)
        (dsh-emacs-mode)
        (setq-local dsh-emacs--buffer-subagent t))
      (cl-letf (((symbol-function 'read-file-name)
                 (lambda (&rest _) (error "Unexpected file picker")))
                ((symbol-function 'dsh-emacs--attachable-file)
                 (lambda (&rest _) (error "Unexpected file read"))))
        (dolist (invoke (list (lambda () (call-interactively #'dsh-emacs-attach-file))
                              (lambda () (dsh-emacs-attach-file "/tmp/first.log"))
                              (lambda () (dsh-emacs--dnd-attach
                                          '(drag-n-drop ("/tmp/first.log"))))))
          (let ((rejected nil))
            (condition-case nil
                (funcall invoke)
              (user-error (setq rejected t)))
            (ert-info ((format "%s" (format "attachment-acquisition-rejects-%s" context)))
              (should rejected)
              (should (null (dsh-emacs-pending-attachments))))))))))

;; Upload completion must not consume a draft composed after sending, across
;; plain, queued, steering, and slash-command/fallback dispatch.
(ert-deftest dsh-emacs-test-attachments-upload-clears-original-draft-case ()
  :tags '(dsh-unit)
  (dolist (route '(plain queue steer command))
    (with-temp-buffer
      (dsh-emacs-mode)
      (setq-local dsh-emacs--buffer-session "upload-draft")
      (let ((upload-callback nil) (command-callback nil) (request nil)
            (caption (if (eq route 'command) "/unknown caption" "caption"))
            (entry '((file . "/tmp/report?.txt")
                     (name . "report?.txt") (bytes . 1)))
            (new-image '((mediaType . "image/png") (data . "eA==")
                         (name . "next.png")))
            (dsh-emacs-busy-enter-behavior 'queue))
        (cl-letf (((symbol-function 'dsh-emacs-server-ensure) #'ignore)
                  ((symbol-function 'dsh-emacs--busy-p)
                   (lambda () (eq route 'queue)))
                  ((symbol-function 'dsh-emacs--upload-file)
                   (lambda (_session _attachment callback)
                     (setq upload-callback callback)))
                  ((symbol-function 'dsh-emacs-command-execute)
                   (lambda (_session _line _parts callback)
                     (setq command-callback callback)))
                  ((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (_method params _callback) (setq request params))))
          (dsh-emacs--replace-input caption)
          (dsh-emacs--stage-attachments (list entry))
          (let ((current-prefix-arg (and (eq route 'steer) '(4))))
            (dsh-emacs-send-or-stop))
          (ert-info ((format "%s" (format "upload-clears-original-draft-%s" route)))
            (should (equal "" (dsh-emacs--get-input)))
            (should (null (dsh-emacs-pending-attachments))))
          (dsh-emacs--replace-input "next draft")
          (dsh-emacs--stage-attachments (list new-image))
          (funcall upload-callback t
                   (dsh-protocol-file-receipt--from-alist
                    '((receiptId . "receipt")
                      (file . ((name . "report_.txt") (bytes . 2048))))) nil)
          (ert-info ((format "%s" (format "upload-preserves-new-draft-%s" route)))
            (should (equal "next draft" (dsh-emacs--get-input)))
            (should (equal (list new-image) (dsh-emacs-pending-attachments))))
          (when command-callback
            (funcall command-callback t nil nil))
          (let* ((payload (cdr (assq 'request request)))
                 (content (cdr (assq 'content payload))))
            (ert-info ((format "%s" (format "upload-dispatches-original-message-%s" route)))
              (should (equal caption (cdr (assq 'text (aref content 0)))))
              (should (equal '((type . "file") (receiptId . "receipt"))
                             (aref content 1)))
              (should (equal (if (eq route 'steer) "steer" "queue")
                             (cdr (assq 'mode payload))))
              (should (equal "next draft" (dsh-emacs--get-input)))))
          (when (memq route '(plain command))
            (ert-info ((format "%s" (format "upload-echo-uses-host-metadata-%s" route)))
              (should (string-match-p (regexp-quote "[file: report_.txt · 2.0 KB]")
                                      (buffer-string)))
              (should (equal "report?.txt" (cdr (assq 'name entry))))
              (should (equal 1 (cdr (assq 'bytes entry))))
              (should (null (assq 'uploaded-file entry))))))))))

;; Every submit kind retains the consumed input through later reply writes.
(ert-deftest dsh-emacs-test-attachments-case-submit-resets-history-navigation ()
  :tags '(dsh-unit)
  (dolist (kind '(plain image file))
    (dolist (scenario '(("draft to send" nil)
                        ("draft to send" "next draft")
                        ("" nil)))
      (with-temp-buffer
        (dsh-emacs-mode)
        (setq-local dsh-emacs--buffer-session "upload-undo")
        (let ((caption (car scenario))
              (new-draft (cadr scenario))
              upload-callback)
          (cl-letf (((symbol-function 'dsh-emacs-server-ensure) #'ignore)
                    ((symbol-function 'dsh-emacs--busy-p) (lambda () nil))
                    ((symbol-function 'dsh-emacs--upload-file)
                     (lambda (_session _attachment callback)
                       (setq upload-callback callback)))
                    ((symbol-function 'dsh-emacs--rpc-async) #'ignore))
            (dsh-emacs--replace-input caption)
            (dsh-emacs--stage-attachments
             (pcase kind
               ('file '(((file . "/tmp/undo.txt") (name . "undo.txt") (bytes . 1))))
               ('image '(((mediaType . "image/png") (data . "eA==") (name . "a.png"))))))
            (setq dsh-emacs--input-history-pos 0
                  dsh-emacs--input-history-pending "old draft")
            (undo-boundary)
            (run-hooks 'pre-command-hook)
            (dsh-emacs-send-or-stop)
            ;; Empty plain input is a no-op, not a submission.
            (unless (and (eq kind 'plain) (string-empty-p caption))
              (ert-info ((format "%s" (format "%s-submit-resets-history-navigation" kind)))
                (should (null dsh-emacs--input-history-pos))
                (should (null dsh-emacs--input-history-pending))))
            (when new-draft (dsh-emacs--replace-input new-draft))
            (when upload-callback
              (funcall upload-callback t
                       (dsh-protocol-file-receipt--from-alist
                        '((receiptId . "undo-receipt"))) nil))
            ;; Another transcript write before undo shifts the marker again.
            (dsh-emacs-render--insert-chat-message
             "agent reply" 'dsh-emacs-assistant-body-face
             (dsh-emacs-render--input-insert-point) nil 'assistant)
            (undo-boundary)
            (let ((last-command 'dsh-emacs-send-or-stop) (this-command 'undo)
                  (pending-undo-list nil)
                  (undo-equiv-table (make-hash-table :test 'eq))
                  (transcript (buffer-substring-no-properties
                               (point-min) dsh-emacs--input-marker)))
              (run-hooks 'pre-command-hook)
              (ert-info ((format "%s" (format "%s-submit-undo-has-record-only-for-caption" kind)))
                (should (eq (not (string-empty-p caption))
                            (condition-case nil (progn (undo) t) (user-error nil)))))
              (run-hooks 'post-command-hook)
              (ert-info ((format "%s" (format "%s-submit-undo-preserves-transcript" kind)))
                (should (equal transcript (buffer-substring-no-properties
                                           (point-min) dsh-emacs--input-marker)))
                (should (equal (if new-draft "" caption)
                               (dsh-emacs--get-input)))
                (should (null (dsh-emacs-pending-attachments))))
              (when (and (not new-draft) (not (string-empty-p caption)))
                (ert-info ((format "%s" (format "%s-undo-takes-ownership" kind)))
                  (should (null dsh-emacs--undo-consumed)))
                (undo-redo 1)
                (ert-info ((format "%s" (format "%s-redo-clears-restored-caption" kind)))
                  (should (equal "" (dsh-emacs--get-input)))
                  (should (null (dsh-emacs-pending-attachments)))
                  (should (equal transcript (buffer-substring-no-properties
                                             (point-min) dsh-emacs--input-marker))))
                (setq dsh-emacs--undo-stale t)
                (dsh-emacs--reset-undo-history)
                (ert-info ((format "%s" (format "%s-redo-does-not-rearm-consumption" kind)))
                  (should (null buffer-undo-list))))
              ;; A later transcript write must not resurrect the consumed caption
              ;; after editing/undo has taken ownership of the input.
              (when new-draft
                (setq dsh-emacs--undo-stale t)
                (dsh-emacs--reset-undo-history)
                (ert-info ((format "%s" (format "%s-submit-does-not-revive-old-caption" kind)))
                  (should (null buffer-undo-list)))))))))))

;; Editing back to empty relinquishes consumption; replacement submissions
;; and callbacks must not recover older text.  Exercise real dispatch/rollback.
(ert-deftest dsh-emacs-test-attachments-case-undo-transition-case ()
  :tags '(dsh-unit)
  (dolist (kind '(plain image file))
    (dolist (transition '(edit-empty failure reversed-completion))
      (with-temp-buffer
        (dsh-emacs-mode)
        (setq-local dsh-emacs--buffer-session "undo-transition")
        (setq-local dsh-emacs--event-ready t)
        (let ((attachment
               (pcase kind
                 ('image '((mediaType . "image/png") (data . "eA==") (name . "a.png")))
                 ('file '((file . "/tmp/undo.txt") (name . "undo.txt") (bytes . 1)))))
              uploads requests)
          (cl-letf (((symbol-function 'dsh-emacs-server-ensure) #'ignore)
                    ((symbol-function 'dsh-emacs--busy-p) (lambda () nil))
                    ((symbol-function 'dsh-emacs-events--watchdog-start) #'ignore)
                    ((symbol-function 'dsh-emacs--upload-file)
                     (lambda (_session _attachment callback) (push callback uploads)))
                    ((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (_method _params callback) (push callback requests))))
            (dsh-emacs--replace-input "first")
            (when attachment (dsh-emacs--stage-attachments (list attachment)))
            (dsh-emacs-send-or-stop)
            (pcase transition
              ('edit-empty
               (dsh-emacs--replace-input "new draft")
               ;; An ordinary deletion, not another submission.
               (delete-region dsh-emacs--input-marker (dsh-emacs--input-end)))
              ('reversed-completion
               (dsh-emacs--replace-input "second")
               (when attachment (dsh-emacs--stage-attachments (list attachment)))
               (dsh-emacs-send-or-stop)))
            ;; Newest upload settles first.  No completion may capture input.
            (dolist (callback uploads)
              (funcall callback t
                       (dsh-protocol-file-receipt--from-alist
                        '((receiptId . "transition-receipt"))) nil))
            ;; A newer history navigation belongs to the user, not the callback.
            (setq dsh-emacs--input-history-pos 2
                  dsh-emacs--input-history-pending "navigation draft")
            (dolist (callback requests)
              (funcall callback (not (eq transition 'failure)) nil))
            (dsh-emacs-render--insert-chat-message
             "reply after completion" 'dsh-emacs-assistant-body-face
             (dsh-emacs-render--input-insert-point) nil 'assistant)
            (run-hooks 'pre-command-hook)
            (let ((start (marker-position dsh-emacs--input-marker)))
              (ert-info ((format "%s" (format "%s-undo-transition-%s" kind transition)))
                (should (pcase transition
                          ('edit-empty (null buffer-undo-list))
                          ('failure
                           (and (equal "first" (dsh-emacs--get-input))
                                (null dsh-emacs--undo-consumed)
                                (equal buffer-undo-list
                                       (list nil (cons start (dsh-emacs--input-end))))
                                (equal (and attachment (list attachment))
                                       (dsh-emacs-pending-attachments))))
                          ('reversed-completion
                           (and (equal "" (dsh-emacs--get-input))
                                (equal buffer-undo-list (list nil (cons "second" (- start)))))))))
              (unless (eq transition 'failure)
                (ert-info ((format "%s" (format "%s-completion-keeps-new-navigation-%s"
                                                kind transition)))
                  (should (equal 2 dsh-emacs--input-history-pos))
                  (should (equal "navigation draft" dsh-emacs--input-history-pending)))))))))))

;; Consumption preserves editor text/properties, not reference wire expansion.
;; Rebuilding the input layout starts a new undo lifetime.
(ert-deftest dsh-emacs-test-attachments-consumed-reference-keeps-editor-properties ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (goto-char dsh-emacs--input-marker)
    (insert (propertize "@short" 'dsh-emacs-reference-canonical "@file:long/path"))
    (dsh-emacs--clear-input)
    (dsh-emacs-render--insert-chat-message
     "reply" 'dsh-emacs-assistant-body-face
     (dsh-emacs-render--input-insert-point) nil 'assistant)
    (dsh-emacs--reset-undo-history)
    (let ((text (car (cadr buffer-undo-list))))
      (ert-info ((format "%s" "consumed-reference-keeps-editor-properties"))
        (should (equal "@short" text))
        (should (equal "@file:long/path" (get-text-property 0 'dsh-emacs-reference-canonical text)))))
    (dsh-emacs--setup-input-area)
    (dsh-emacs-render--insert-chat-message
     "reloaded" 'dsh-emacs-assistant-body-face
     (dsh-emacs-render--input-insert-point) nil 'assistant)
    (dsh-emacs--reset-undo-history)
    (ert-info ((format "%s" "new-input-layout-forgets-consumption"))
      (should (null dsh-emacs--undo-consumed))
      (should (null buffer-undo-list)))))

;; A read error for a later file happens after the send command has returned.
(ert-deftest dsh-emacs-test-attachments-later-file-read-error-restores-draft ()
  :tags '(dsh-unit)
  (let* ((file (make-temp-file "dsh-later-upload" nil ".txt"))
         (entry (dsh-emacs--staged-file-attachment file)))
    (unwind-protect
        (with-temp-buffer
          (dsh-emacs-mode)
          (setq-local dsh-emacs--buffer-session "upload-read-error")
          (let ((pending nil) (reads 0) (sent nil) (escaped nil) messages)
            (cl-letf (((symbol-function 'message)
                       (lambda (format-string &rest args)
                         (push (apply #'format format-string args) messages)))
                      ((symbol-function 'dsh-emacs-server-ensure) #'ignore)
                      ((symbol-function 'dsh-emacs--busy-p) (lambda () nil))
                      ((symbol-function 'dsh-emacs--binary-file-string)
                       (lambda (_path)
                         (setq reads (1+ reads))
                         (if (= reads 1) "a"
                           (signal 'file-error '("File became unreadable")))))
                      ((symbol-function 'dsh-emacs--http-post)
                       (lambda (_url _type _body callback) (setq pending callback)))
                      ((symbol-function 'dsh-emacs--rpc-async)
                       (lambda (&rest _) (setq sent t))))
              (dsh-emacs--replace-input "two files")
              (dsh-emacs--stage-attachments (list entry (copy-tree entry)))
              (dsh-emacs-send-or-stop)
              (condition-case err
                  (funcall pending '((ok . t) (value . ((receiptId . "r1")))))
                (error (setq escaped err)))
              (ert-info ((format "%s" "later-file-read-error-restores-draft"))
                (should (null escaped))
                (should (null sent))
                (should (= 2 reads))
                (should (equal "File upload failed: File became unreadable" (car messages)))
                (should (= 1 (cl-count-if
                              (lambda (text) (string-prefix-p "File upload failed:" text))
                              messages)))
                (should (equal "two files" (dsh-emacs--get-input)))
                (should (equal (list entry entry) (dsh-emacs-pending-attachments)))))))
      (delete-file file))))

;; Upload startup errors report failure, but errors inside a synchronously
;; invoked consumer callback must propagate without a second callback.
(ert-deftest dsh-emacs-test-attachments-upload-start-error-reaches-failure-callback ()
  :tags '(dsh-unit)
  (let* ((file (make-temp-file "dsh-upload-boundary" nil ".txt"))
         (entry (dsh-emacs--staged-file-attachment file)))
    (unwind-protect
        (progn
          (let ((result 'unset) (escaped nil) (failure nil) (messages nil))
            (cl-letf (((symbol-function 'dsh-emacs--http-post)
                       (lambda (&rest _) (error "Request startup failed")))
                      ((symbol-function 'message)
                       (lambda (format-string &rest args)
                         (push (apply #'format format-string args) messages))))
              (condition-case err
                  (dsh-emacs--upload-file
                   "session" entry
                   (lambda (ok _receipt err) (setq result ok failure err)))
                (error (setq escaped err))))
            (ert-info ((format "%s" "upload-start-error-reaches-failure-callback"))
              (should (null escaped))
              (should (null result))
              (should (equal "Request startup failed" (cdr (assq 'message failure))))
              (should (equal (list (format "Uploading %s…" (cdr (assq 'name entry))))
                             messages))))
          (let ((calls 0) (escaped nil))
            (cl-letf (((symbol-function 'dsh-emacs--http-post)
                       (lambda (_url _type _body callback)
                         (funcall callback
                                  '((ok . t) (value . ((receiptId . "r"))))))))
              (condition-case err
                  (dsh-emacs--upload-file
                   "session" entry
                   (lambda (&rest _) (setq calls (1+ calls))
                     (error "Consumer failed")))
                (error (setq escaped err))))
            (ert-info ((format "%s" "upload-does-not-mask-consumer-error"))
              (should (= calls 1))
              (should (equal escaped '(error "Consumer failed")))))
          (with-temp-file file (insert "file has grown"))
          (let ((dsh-emacs-attach-max-file-size 1)
                (read-p nil) (posted nil) (result 'unset))
            (cl-letf (((symbol-function 'dsh-emacs--binary-file-string)
                       (lambda (_path) (setq read-p t) "file has grown"))
                      ((symbol-function 'dsh-emacs--http-post)
                       (lambda (&rest _) (setq posted t))))
              (dsh-emacs--upload-file
               "session" entry
               (lambda (ok _receipt _error) (setq result ok))))
            (ert-info ((format "%s" "upload-rechecks-size-before-reading"))
              (should (null read-p))
              (should (null posted))
              (should (null result)))))
      (delete-file file))))

;; `yank-media-preferred-types' is Emacs 31+; loading the package must not
;; shadow its default list, and a chat buffer must keep the TIFF addition.
(ert-deftest dsh-emacs-test-attachments-yank-media-keeps-preferred-types ()
  :tags '(dsh-unit)
  (skip-unless (>= emacs-major-version 31))
  (with-temp-buffer
    (dsh-emacs-mode)
    (ert-info ((format "%s" "yank-media-keeps-preferred-types"))
      (should (memq 'image/tiff yank-media-preferred-types))
      (should (> (length yank-media-preferred-types) 1)))))

(provide 'dsh-test-attachments)
;;; dsh-test-attachments.el ends here
