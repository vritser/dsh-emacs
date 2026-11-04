;;; dsh-emacs-attachments.el --- Attachment acquisition, staging and uploads -*- lexical-binding: t; -*-

;; Copyright (C) 2026 vritser
;; Author: vritser
;; Version: 0.7.0
;; License: GPL-3.0-or-later
;; Package-Requires: ((emacs "28.1"))

;;; Commentary:
;; Owns attachment options, acquisition, the single buffer-local staged set,
;; media integration and submit-time file uploads.  The entry point owns the
;; send transaction, input/undo and rollback eligibility.  Composer reads the
;; staged set directly and delegates its remove action to this owner.
;; Interactive command autoloads initialize the full package's chat context;
;; loading this module alone does not install chat media handlers.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'mailcap)
(require 'dnd)
(require 'dsh-emacs-protocol)
(require 'dsh-emacs-server)
(require 'dsh-emacs-subagent)

;; Composer requires this owner, so repaint is a cyclic runtime seam.
(declare-function dsh-emacs-composer-refresh "dsh-emacs-composer" ())
(defvar dsh-emacs--input-marker)

;; `yank-media-preferred-types' is Emacs 31+ and is not declared here: a
;; load-time `defvar' would shadow the package's default.  Its one use site
;; guards on `boundp' and suppresses the byte-compiler warning instead.

(defcustom dsh-emacs-attach-media-types
  '("image/png" "image/jpeg" "image/webp" "image/gif")
  "Image media types sent as inline image attachments.

A file whose type is in this set rides the prompt as an image (the host
validates it against this set, plus byte/pixel limits of its own).  Every
other file is uploaded to the host at submit time and reaches the model as
a file attachment — see `dsh-emacs-attach-file'."
  :type '(repeat string)
  :group 'dsh-emacs)

(defcustom dsh-emacs-attach-max-file-size (* 32 1024 1024)
  "Largest file (in bytes) `dsh-emacs-attach-file' uploads.

A file attachment is read into this Emacs process and posted to the
session's host in one request, so the limit protects Emacs memory as much
as the host.  A larger file is refused with `user-error' before anything is
read; images in `dsh-emacs-attach-media-types' are not governed by it
\(they have their own host-side limits).  nil removes the check."
  :type '(choice (const :tag "No limit" nil) integer)
  :group 'dsh-emacs)

(defvar-local dsh-emacs--pending-attachments nil
  "Attachments staged for this buffer's next prompt, in staging order.
Each element is one staged entry (an image alist, or a local file entry
uploaded at submit time) — see `dsh-emacs--submit-prompt'.  The Composer
renders them as one read-only row; `C-c C-c' consumes them, `C-c C-d'
discards them.")

(defun dsh-emacs--file-attachment (file)
  "Read FILE into a wire-ready image attachment alist, or nil.

The dsh host accepts base64 image uploads inline in `session/prompt'
(media type, bytes and pixel limits are enforced server-side).  The
base64 is emitted without line breaks: the wire field is validated as
one continuous base64 run."
  (let* ((media (ignore-errors
                  (mailcap-file-name-to-mime-type
                   (file-name-nondirectory file))))
         (supported (and media (member media dsh-emacs-attach-media-types))))
    (when (and supported (file-readable-p file))
      (let ((bytes (dsh-emacs--binary-file-string file)))
        (dsh-protocol-image-attachment
         media bytes (file-name-nondirectory file))))))

;; A non-image attachment is a *staged file entry*: metadata only, no
;; bytes.  The host admits a file into a prompt as a one-time receipt
;; minted by the upload route, so the bytes leave this machine at submit
;; time (`dsh-emacs--upload-file') — never when the draft is composed,
;; and never as base64 in the prompt.  See rpc.md §4.17.

(defun dsh-emacs--attachment-file-p (attachment)
  "Non-nil when staged ATTACHMENT is a local file awaiting upload."
  (and (consp attachment) (assq 'file attachment)))

(defun dsh-emacs--staged-file-attachment (file)
  "Return FILE as a staged local file attachment, or nil.
The entry \((file . PATH) (name . N) (bytes . B)) carries metadata only,
so a draft never keeps a copy of the file.  A path that is not a readable
regular file, or is larger than `dsh-emacs-attach-max-file-size', yields
nil."
  (when (and (file-regular-p file) (file-readable-p file))
    (let ((size (file-attribute-size (file-attributes file))))
      (when (or (null dsh-emacs-attach-max-file-size)
                (<= size dsh-emacs-attach-max-file-size))
        (list (cons 'file (expand-file-name file))
              (cons 'name (file-name-nondirectory file))
              (cons 'bytes size))))))

(defun dsh-emacs--attachable-file (file)
  "Return FILE as a staged attachment: an accepted image inline, else a file.
An image whose type is in `dsh-emacs-attach-media-types' carries its
base64 bytes inline (the host gives it to the model as an image); every
other file becomes a staged file entry uploaded at submit time.  Nil when
FILE cannot be attached, which is what `dsh-emacs-attach-file' reports."
  (let ((media (ignore-errors
                 (mailcap-file-name-to-mime-type
                  (file-name-nondirectory file)))))
    (if (and media (member media dsh-emacs-attach-media-types))
        (dsh-emacs--file-attachment file)
      (dsh-emacs--staged-file-attachment file))))

(defun dsh-emacs--upload-file (session-id attachment callback)
  "Upload local file ATTACHMENT for SESSION-ID; CALLBACK gets (OK RECEIPT ERROR).
The bytes POST to the host's raw upload route as
`application/octet-stream' (rpc.md §4.17) and the answer carries the
one-time receipt the prompt must submit.  CALLBACK receives OK non-nil
and the `dsh-protocol-file-receipt' as RECEIPT when the host accepted the
upload, else ERROR: the route's own error object (`{code, message,
details}'), a message-bearing alist for local validation, read or startup
errors, or nil for transport failures already reported by HTTP."
  (let* ((path (cdr (assq 'file attachment)))
         (name (or (cdr (assq 'name attachment))
                   (file-name-nondirectory path)))
         (url (format "%s/api/session/uploadFileBinary?sessionId=%s&name=%s"
                      (dsh-emacs--server-base-url)
                      (url-hexify-string session-id)
                      (url-hexify-string name)))
         (callback-started nil)
         (startup-error nil))
    (message "Uploading %s…" name)
    (condition-case err
        (progn
          ;; A staged file may have disappeared or grown since composition.
          (unless (dsh-emacs--staged-file-attachment path)
            (user-error "File is unreadable or exceeds attachment size limit: %s"
                        path))
          (dsh-emacs--http-post
           url "application/octet-stream" (dsh-emacs--binary-file-string path)
           (lambda (body)
             ;; A synchronous response must not turn downstream callback
             ;; exceptions into a second, failed upload completion.
             (setq callback-started t)
             ;; The route has its own {ok, value|error} discriminant.
             (pcase-let ((`(,ok . ,value)
                          (dsh-protocol-rpc-result--from-alist body :direct-p t)))
               (if ok
                   (funcall callback t
                            (dsh-protocol-file-receipt--from-alist value) nil)
                 (funcall callback nil nil value))))))
      (error
       (if callback-started
           (signal (car err) (cdr err))
         (setq startup-error err))))
    (when startup-error
      (funcall callback nil nil
               (list (cons 'message (error-message-string startup-error)))))))

(defun dsh-emacs--upload-attachments (session-id attachments callback)
  "Upload the staged files of ATTACHMENTS, then resolve every part.
Image entries become inline parts without a round trip; file entries
upload one after another, so PARTS always follows the staged order.
CALLBACK receives (OK PARTS ERROR): on success PARTS is the complete
tagged content-part list; on failure OK is nil and ERROR is the failing
upload's value, with no part list (the caller restores its draft)."
  (unless session-id
    (user-error "No active session to attach a file to"))
  (let ((pending attachments)
        (parts nil))
    (cl-labels
     ((next ()
        (if (null pending)
            (funcall callback t (nreverse parts) nil)
          (let* ((entry pending)
                 (attachment (car entry)))
            (setq pending (cdr pending))
            (if (dsh-emacs--attachment-file-p attachment)
                (dsh-emacs--upload-file
                 session-id attachment
                 (lambda (ok receipt err)
                   (if ok
                       (progn
                         ;; Keep authoritative display metadata separate
                         ;; from the local name used for retry uploads.
                         (let ((file (dsh-protocol-file-receipt-file receipt)))
                           (when (or file (assq 'uploaded-file attachment))
                             (setf (alist-get 'uploaded-file (car entry)) file)))
                         (push (dsh-protocol-file-content-part receipt)
                               parts)
                         (next))
                     (funcall callback nil nil err))))
              (push (dsh-protocol-image-content-part attachment) parts)
              (next))))))
     (next))))

;;; Clipboard images
;;
;; `C-c C-v' stages the system clipboard's image for the next prompt.  The
;; selection surface differs per platform: X11/pgtk publish image MIME targets
;; that `gui-get-selection' returns as-is, while macOS exposes TIFF only — a
;; media type the dsh host does not accept — so those bytes are converted with
;; the system `sips' tool before they leave this machine.

(defun dsh-emacs--binary-file-string (file)
  "Return FILE's bytes as a unibyte string, without coding conversion."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (buffer-string)))

(defun dsh-emacs--write-binary-file (file bytes)
  "Write the unibyte string BYTES to FILE without coding conversion."
  (let ((coding-system-for-write 'binary))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert bytes)
      (write-region (point-min) (point-max) file nil 'silent))))

(defun dsh-emacs--bytes-prefix-p (prefix bytes)
  "Non-nil when unibyte BYTES start with the unibyte string PREFIX."
  (and (>= (length bytes) (length prefix))
       (string= prefix (substring bytes 0 (length prefix)))))

(defun dsh-emacs--image-bytes-match-p (media-type bytes)
  "Non-nil when unibyte BYTES carry MEDIA-TYPE's magic number.
Guards against a selection that advertises a flavor but returns
something else, which `create-image' and the host would both reject."
  (pcase media-type
    ("image/png" (dsh-emacs--bytes-prefix-p
                  (unibyte-string 137 80 78 71 13 10 26 10) bytes))
    ("image/jpeg" (dsh-emacs--bytes-prefix-p
                   (unibyte-string 255 216 255) bytes))
    ("image/gif" (dsh-emacs--bytes-prefix-p
                  (unibyte-string 71 73 70 56) bytes))
    ("image/webp" (and (>= (length bytes) 12)
                       (dsh-emacs--bytes-prefix-p
                        (unibyte-string 82 73 70 70) bytes)
                       (dsh-emacs--bytes-prefix-p
                        (unibyte-string 87 69 66 80)
                        (substring bytes 8))))
    ("image/tiff" (or (dsh-emacs--bytes-prefix-p
                       (unibyte-string 73 73 42 0) bytes)
                      (dsh-emacs--bytes-prefix-p
                       (unibyte-string 77 77 0 42) bytes)))
    (_ nil)))

(defun dsh-emacs--selection-bytes (media-type)
  "Return the clipboard's MEDIA-TYPE bytes (unibyte), or nil.
MEDIA-TYPE is a MIME string such as \"image/png\".  A selection API
error, a non-string result and an empty flavor all mean \"the
clipboard carries no such type\"."
  (let ((data (condition-case nil
                  (gui-get-selection 'CLIPBOARD (intern media-type))
                (error nil))))
    (and (stringp data) (not (string-empty-p data)) data)))

(defun dsh-emacs--tiff-bytes-to-png (tiff)
  "Convert unibyte TIFF bytes to PNG bytes with macOS `sips', or nil.
`create-image' can display TIFF, but the dsh host accepts only the
media types in `dsh-emacs-attach-media-types'; `sips' is the system
image converter, so no extra dependency is needed.  Returns nil when
TIFF is malformed, `sips' is unavailable, or the conversion fails."
  (when-let* ((sips (executable-find "sips"))
              ((dsh-emacs--image-bytes-match-p "image/tiff" tiff)))
    (let ((dir (make-temp-file "dsh-clipboard-" t)))
      (unwind-protect
          (let ((tiff-file (expand-file-name "clip.tiff" dir))
                (png-file (expand-file-name "clip.png" dir)))
            (dsh-emacs--write-binary-file tiff-file tiff)
            (when (and (zerop (call-process sips nil nil nil
                                            "-s" "format" "png"
                                            tiff-file "--out" png-file))
                       (file-readable-p png-file))
              (let ((png (dsh-emacs--binary-file-string png-file)))
                (and (dsh-emacs--image-bytes-match-p "image/png" png)
                     png))))
        (delete-directory dir t)))))

(defun dsh-emacs--clipboard-image ()
  "Return (MEDIA-TYPE . BYTES) for the clipboard's image, or nil.
Accepted media types are tried directly first (X11/pgtk expose them);
macOS exposes only TIFF on the pasteboard, so that flavor is converted
to PNG only when PNG is accepted.  BYTES is the encoded image data
as a unibyte string."
  (or (cl-loop for media in dsh-emacs-attach-media-types
               for bytes = (dsh-emacs--selection-bytes media)
               when (and bytes (dsh-emacs--image-bytes-match-p media bytes))
               return (cons media bytes))
      (when-let* (((member "image/png" dsh-emacs-attach-media-types))
                  (tiff (dsh-emacs--selection-bytes "image/tiff"))
                  (png (dsh-emacs--tiff-bytes-to-png tiff)))
        (cons "image/png" png))))

(defun dsh-emacs--clipboard-image-present-p ()
  "Non-nil when the clipboard advertises any image flavor at all.
A cheap TARGETS probe that reads no image bytes; it only sharpens the
error wording, distinguishing \"nothing to paste\" from \"the image's
type is not accepted\"."
  (let ((targets (condition-case nil
                     (gui-get-selection 'CLIPBOARD 'TARGETS)
                   (error nil))))
    (and (sequencep targets)
         (cl-some (lambda (target)
                    (and (symbolp target)
                         (string-prefix-p "image/" (symbol-name target))))
                  (append targets nil)))))

(defun dsh-emacs--clipboard-image-name (media-type)
  "Return a display name for a pasted MEDIA-TYPE clipboard image."
  (format-time-string
   (concat "pasted-%Y%m%d-%H%M%S."
           (pcase media-type
             ("image/png" "png")
             ("image/jpeg" "jpg")
             ("image/webp" "webp")
             ("image/gif" "gif")
             (_ "img")))))

;;; Staged attachments (Composer row)

(defun dsh-emacs-pending-attachments ()
  "Return this buffer's staged (not yet sent) attachments.
Each element is one staged entry, as `dsh-emacs--submit-prompt' takes:
an image alist \((mediaType . M) (data . B64) (name? . N)), or a local
file entry \((file . PATH) (name . N) (bytes . B)).  The Composer renders
them from this list, so it is the single source of truth for the row,
never a copy."
  dsh-emacs--pending-attachments)

(defun dsh-emacs--attachments-summary (attachments)
  "Return the names of staged ATTACHMENTS, or a count when none are named.
This is the message text of a blank-input send and the feedback of a
staging or removal step, so it names the files themselves instead of
reporting an attachment count."
  (let ((names (delq nil (mapcar (lambda (attachment)
                                   (cdr (assq 'name attachment)))
                                 attachments))))
    (if names
        (mapconcat #'identity names ", ")
      (format "%d attachment%s" (length attachments)
              (if (= 1 (length attachments)) "" "s")))))

(defun dsh-emacs--set-pending-attachments (attachments)
  "Replace this buffer's staged set with ATTACHMENTS and repaint its row.
Callers own admission checks and failed-submit restoration eligibility."
  (setq dsh-emacs--pending-attachments attachments)
  (dsh-emacs-composer-refresh))

(defun dsh-emacs--stage-attachments (attachments)
  "Append ATTACHMENTS to this buffer's staged set and repaint the row."

  (dsh-emacs-subagent-require 'mutate)
  (when attachments
    (dsh-emacs--set-pending-attachments
     (append dsh-emacs--pending-attachments attachments))
    (message "%s staged · C-c C-c sends · C-c C-d discards"
             (dsh-emacs--attachments-summary attachments))))

(defun dsh-emacs--remove-attachment (attachment)
  "Drop staged ATTACHMENT, one entry of `dsh-emacs-pending-attachments'.
The Composer's per-file remove cell calls this with the very entry it
rendered, so only that entry goes; `dsh-emacs-clear-attachments'
(C-c C-d) still drops the whole set.  A no-op when ATTACHMENT is not
staged."
  (when (memq attachment dsh-emacs--pending-attachments)
    (dsh-emacs--set-pending-attachments
     (delq attachment dsh-emacs--pending-attachments))
    (message "%s removed" (dsh-emacs--attachments-summary (list attachment)))))

(defun dsh-emacs--ensure-chat-buffer ()
  "Signal a `user-error' unless the current buffer is a chat buffer."
  (unless (and dsh-emacs--input-marker
               (marker-buffer dsh-emacs--input-marker))
    (user-error "Not in a dsh chat buffer")))

(defun dsh-emacs--stage-clipboard-image (image)
  "Stage clipboard IMAGE (a (MEDIA-TYPE . BYTES) pair) as an attachment."
  (dsh-emacs--stage-attachments
   (list (dsh-protocol-image-attachment
          (car image) (cdr image)
          (dsh-emacs--clipboard-image-name (car image))))))

;;;###autoload (autoload 'dsh-emacs-attach-clipboard-image "dsh-emacs" nil t)
(defun dsh-emacs-attach-clipboard-image ()
  "Stage the system clipboard's image for the next message (C-c C-v).
The image joins the pending attachments shown above the input; the
next `C-c C-c' sends it with the typed caption (the image name when
the caption is empty), and `C-c C-d' discards it.  Only the media
types in `dsh-emacs-attach-media-types' are accepted; a macOS TIFF
pasteboard image is converted to PNG when PNG is accepted.  Plain
`yank' is unaffected."
  (interactive)
  (dsh-emacs-subagent-require 'mutate)
  (dsh-emacs--ensure-chat-buffer)
  (let ((image (dsh-emacs--clipboard-image)))
    (unless image
      (user-error "%s"
                  (if (dsh-emacs--clipboard-image-present-p)
                      "Clipboard image type is not in dsh-emacs-attach-media-types"
                    "No image in the clipboard")))
    (dsh-emacs--stage-clipboard-image image)))

;;;###autoload (autoload 'dsh-emacs-paste "dsh-emacs" nil t)
(defun dsh-emacs-paste ()
  "Paste into the chat input: the clipboard image if there is one, else text.
Bound to `s-v' in chat buffers, where stock Emacs maps the key
to `yank'.  A clipboard carrying an image stages it exactly like `C-c C-v';
otherwise this yanks text like `yank'.  The image wins when the clipboard
carries both flavors, matching what a chat paste gesture means; `C-y' stays
a plain text yank, so a clipboard holding an image and text (a copied
picture and its URL, say) can still paste the text."
  (interactive)
  (dsh-emacs--ensure-chat-buffer)
  (if-let* ((image (dsh-emacs--clipboard-image)))
      (dsh-emacs--stage-clipboard-image image)
    (call-interactively #'yank)))

(defun dsh-emacs--yank-media-handler (media-type data)
  "`yank-media' handler: stage clipboard DATA as a pending attachment.
MEDIA-TYPE is the selection's MIME symbol and DATA its bytes.  Types
the host accepts are taken as-is; TIFF is converted to PNG through
`dsh-emacs--tiff-bytes-to-png'; anything else is refused."
  (dsh-emacs--ensure-chat-buffer)
  (let* ((media (symbol-name media-type))
         (converted (cond
                     ((not (stringp data)) nil)
                     ;; Only host-accepted types pass through as-is; a TIFF
                     ;; selection ALSO matches its own magic number, and must
                     ;; take the conversion branch instead.
                     ((and (member media dsh-emacs-attach-media-types)
                           (dsh-emacs--image-bytes-match-p media data))
                      (cons media data))
                     ((and (member "image/png" dsh-emacs-attach-media-types)
                           (member media '("image/tiff" "image/tif")))
                      (when-let* ((png (dsh-emacs--tiff-bytes-to-png data)))
                        (cons "image/png" png))))))
    (unless converted
      (user-error "Unsupported clipboard media type: %s" media))
    (dsh-emacs--stage-clipboard-image converted)))

;;;###autoload (autoload 'dsh-emacs-clear-attachments "dsh-emacs" nil t)
(defun dsh-emacs-clear-attachments ()
  "Discard this buffer's staged attachments (C-c C-d)."
  (interactive)
  (dsh-emacs--ensure-chat-buffer)
  (if (null dsh-emacs--pending-attachments)
      (message "No staged attachments")
    (dsh-emacs--set-pending-attachments nil)
    (message "Attachments discarded")))

;;;###autoload (autoload 'dsh-emacs-attach-file "dsh-emacs" nil t)
(defun dsh-emacs-attach-file (file)
  "Stage FILE for the next message (C-c C-a).
Repeat to add more files.  Write the caption in the chat input, then use
`C-c C-c' to send the text and all staged attachments together; `C-c C-d'
discards the staged set.

An image whose type is in `dsh-emacs-attach-media-types' rides the prompt
inline as an image.  Every other file is uploaded to the host at submit
time and reaches the model as a file attachment; such a file must be a
readable regular file no larger than `dsh-emacs-attach-max-file-size'."
  (interactive
   (progn
     (dsh-emacs-subagent-require 'mutate)
     (dsh-emacs--ensure-chat-buffer)
     (list (read-file-name "File to attach: " default-directory nil t))))
  (dsh-emacs-subagent-require 'mutate)
  (dsh-emacs--ensure-chat-buffer)
  (let ((attachment (dsh-emacs--attachable-file file)))
    (unless attachment
      (user-error "Cannot attach %s (not a readable file, or above `dsh-emacs-attach-max-file-size')"
                  file))
    (dsh-emacs--stage-attachments (list attachment))))

(defun dsh-emacs--dnd-attach (event)
  "Stage files from a `drag-n-drop' EVENT for the next message."
  (interactive "e")
  (dsh-emacs-subagent-require 'mutate)
  (dsh-emacs--ensure-chat-buffer)
  (let* ((files (and (listp event) (nth 1 event)))
         (paths (and files
                     (delq nil (mapcar (lambda (f) (dnd-get-local-file-name f t))
                                       (if (listp files) files (list files)))))))
    (unless paths (user-error "No files in drop event"))
    (if (not (y-or-n-p (format "Stage %d file(s) for the next message? "
                               (length paths))))
        (message "Attach cancelled")
      (let ((attachments (delq nil (mapcar #'dsh-emacs--attachable-file paths))))
        (if (null attachments)
            (message "No attachable files among the dropped files")
          (dsh-emacs--stage-attachments attachments))))))

(defun dsh-emacs--setup-attachments ()
  "Install this chat buffer's optional media handlers and preferences."
  ;; Clipboard images may also arrive through stock `yank-media' (Emacs 29+),
  ;; which dispatches by media type to a buffer-local handler.  The handler is
  ;; registered per chat buffer, so it can never stage an image from an
  ;; unrelated mode's `yank-media'.
  (when (fboundp 'yank-media-handler)
    (yank-media-handler "image/.*" #'dsh-emacs--yank-media-handler)
    ;; A macOS pasteboard exposes TIFF only, which the stock preferred-types
    ;; list omits; prefer it in chat buffers so a plain `M-x yank-media' does
    ;; not stop at "no preferred MIME type to yank".  The list itself is
    ;; Emacs 31+; older versions have no such knob.
    (when (boundp 'yank-media-preferred-types)
      (with-suppressed-warnings ((free-variable yank-media-preferred-types))
        (setq-local yank-media-preferred-types
                    (cons 'image/tiff yank-media-preferred-types))))))

(provide 'dsh-emacs-attachments)
;;; dsh-emacs-attachments.el ends here
