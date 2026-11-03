;;; dsh-test-support.el --- Shared unit-test fixtures -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "28.1"))

(require 'cl-lib)
(require 'ert)

(defconst dsh-emacs-test-directory
  (file-name-directory (or load-file-name buffer-file-name)))
(defconst dsh-emacs-test-root
  (file-name-directory (directory-file-name dsh-emacs-test-directory)))
(add-to-list 'load-path dsh-emacs-test-root)
(require 'dsh-emacs)

(defun dsh-test--fresh-process (form)
  "Evaluate FORM in a fresh Emacs; return (STATUS . OUTPUT)."
  (with-temp-buffer
    (let ((status
           (call-process
            (expand-file-name invocation-name invocation-directory)
            nil (list t t) nil "-Q" "--batch" "-L" dsh-emacs-test-root
            "--eval" (prin1-to-string form))))
      (cons status (buffer-string)))))

(defun dsh-test--generate-autoloads (source loaddefs)
  "Generate LOADDEFS for SOURCE in its temporary directory.
Use the current generator when available, with the Emacs 28 fallback."
  (let ((inhibit-message t))
    (if (require 'loaddefs-gen nil t)
        (loaddefs-generate (file-name-directory source) loaddefs)
      (require 'autoload)
      (with-temp-buffer
        (insert ";;; -*- lexical-binding: t; -*-\n")
        (autoload-generate-file-autoloads source (current-buffer) loaddefs)
        (write-region (point-min) (point-max) loaddefs nil 'silent)))))

(defun dsh-test-equal-text-p (left right)
  "Compare text and property values in LEFT and RIGHT structurally.
Emacs 28's `equal-including-properties' compares string property values
by identity, so independently rendered but equivalent snapshots differ."
  (and (equal left right)
       (let ((pos 0)
             (end (length left)))
         (catch 'different
           (while (< pos end)
             (let ((left-props (text-properties-at pos left))
                   (right-props (text-properties-at pos right)))
               (unless (and (= (length left-props) (length right-props))
                            (cl-loop for (key value) on left-props by #'cddr
                                     always (and (plist-member right-props key)
                                                 (equal-including-properties
                                                  value (plist-get right-props key)))))
                 (throw 'different nil)))
             (setq pos (min (next-property-change pos left end)
                            (next-property-change pos right end))))
           t))))

(defun dsh-emacs-test--session-items (items)
  "Wrap raw session-item alists ITEMS as `dsh-protocol-session' structs
so the code under test can read fields through the protocol accessors."
  (mapcar #'dsh-protocol-session--from-alist items))

(defun dsh-test--faces-at (pos)
  "Return the `face' property at POS as a list (nil when unset).
Lets face assertions read uniformly whether the property holds one face
symbol or an ordered list."
  (ensure-list (get-text-property pos 'face)))

(defun dsh-test-completion-items (coll)
  "Return COLL's completion strings (text properties stripped).
COLL is a completion table (possibly metadata-wrapped), so extract
candidates as the UI would via `all-completions', not by destructuring."
  (mapcar #'substring-no-properties (all-completions "" coll)))

;; --- Test 29: dsh web style tool lines — variant icon + IN/OUT ioCard + status
;; dot ---
(defun dsh-emacs-test--tool-block-text (namespace-id block-id)
  "Return the UI block text for NAMESPACE-ID and BLOCK-ID, or nil."
  (when-let* ((b (dsh-emacs-ui-find-block namespace-id block-id)))
    (buffer-substring-no-properties (car b) (cdr b))))

(defun dsh-emacs-test--tool-call-event (seq call-id name args)
  "Build a `tool/call' event alist."
  (list (cons "type" "tool/call")
        (cons "seq" seq)
        (cons "data"
              (list (cons "callId" call-id)
                    (cons "name" name)
                    (cons "arguments" args)))))

(defun dsh-emacs-test--tool-result-event (seq call-id is-error exit-code text
                                              &optional error)
  "Build a `tool/result' event alist.
ERROR, when given, is the settled `data.error' alist (dsh 0.1.6's
optional `{name, code, reason?}')."
  (list (cons "type" "tool/result")
        (cons "seq" seq)
        (cons "data"
              (append
               (list (cons "message"
                           (list (cons "callId" call-id)
                                 (cons "content"
                                       (vector (list (cons "type" "tool-result")
                                                     (cons "isError" (if is-error t :json-false))
                                                     (cons "exitCode" exit-code)
                                                     (cons "content"
                                                           (vector (list (cons "type" "text")
                                                                         (cons "text" text))))))))))
               (and error (list (cons "error" error)))))))

;;; ---------------------------------------------------------------------------
;;; Queue/steering (session/queue): protocol conversion, mirror diff,
;;; management helpers
;;; ---------------------------------------------------------------------------
(defun dsh-emacs-test--queue-item (id placement text &optional kind with-attachment)
  "Build one `dsh-protocol-queue-item' struct for tests.
PLACEMENT is the wire string (\"queued\"/\"steering\"/\"context\") or nil;
KIND defaults to \"user\"; WITH-ATTACHMENT marks a content list that carries a
non-text block, so the client withholds its edit cell for the item."
  (make-dsh-protocol-queue-item
   :id id
   :placement (and placement (intern placement))
   :text (or text "")
   :kind (or kind "user")
   :text-only (not with-attachment)))

(defun dsh-emacs-test--inbox-message (id text &optional kind)
  "Build one wire `inbox' `UserMessage' alist for tests.
ID is the message id, TEXT its single text block, KIND its source kind
\(default \"user\")."
  (list (cons 'id id)
        (cons 'content (vector (list (cons 'type "text") (cons 'text text))))
        (cons 'source (list (cons 'kind (or kind "user"))))))

(defun dsh-test-composer-next-row ()
  "Return the displayed Next Message row in this buffer, or nil."
  (when-let* ((beg (text-property-any (point-min) (point-max)
                                      'dsh-emacs-composer-next-row t)))
    (buffer-substring beg (next-single-property-change
                           beg 'dsh-emacs-composer-next-row nil (point-max)))))

(defun dsh-test-reference--session-uri (session-id)
  "Return the canonical `dsh-session:' URI for SESSION-ID.
Mirrors the host's `encodeSessionReferenceUri': base64url of the JSON string
literal, padding stripped — the test-only inverse of
`dsh-protocol-session-uri--from-string'."
  (let* ((b64 (base64-encode-string
               (encode-coding-string (json-encode session-id) 'utf-8) t))
         (plain (replace-regexp-in-string "=" "" b64 t t))
         (dash (replace-regexp-in-string "+" "-" plain t t))
         (url (replace-regexp-in-string "/" "_" dash t t)))
    (concat "dsh-session:" url)))

;; Execution feedback: exercise the public event path, not just status setters.
(defun dsh-test--execution-event (type seq data)
  "Make a durable execution fixture with TYPE, SEQ and wire DATA."
  `((type . ,type) (seq . ,seq) (data . ,data)))

(provide 'dsh-test-support)
;;; dsh-test-support.el ends here
