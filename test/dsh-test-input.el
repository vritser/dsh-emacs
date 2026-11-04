;;; dsh-test-input.el --- Input tests -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "28.1"))

(require 'dsh-test-support)

(ert-deftest dsh-emacs-test-input-owner-load-and-consumption ()
  :tags '(dsh-unit)
  (pcase-let ((`(,status . ,output)
               (dsh-test--fresh-process
                '(progn
                   (require 'ert)
                   (let ((before pre-command-hook))
                     (require 'dsh-emacs-input)
                     (should-not (featurep 'dsh-emacs))
                     (should (equal pre-command-hook before))
                     (should-not
                      (advice-member-p #'dsh-emacs--composer-kill-region
                                       'kill-region)))
                   (with-temp-buffer
                     (insert "prefix ")
                     (setq dsh-emacs--input-marker (point-marker))
                     (insert "draft")
                     (should (equal (dsh-emacs--get-input) "draft"))
                     (dsh-emacs--clear-input)
                     (should (equal (buffer-string) "prefix "))
                     (should (equal dsh-emacs--undo-consumed "draft"))
                     (dsh-emacs--replace-input "replacement")
                     (should (equal (dsh-emacs--get-input) "replacement")))))))
    (ert-info (output)
      (should (equal status 0))
      (should (equal output "")))))

(defun dsh-emacs-test--read-char-insert-command ()
  "Read one interactive character, then insert it."
  (interactive)
  (insert (format "%c" (read-char "pick: "))))

(defun dsh-emacs-test--unlisted-insert-command ()
  "An insertion command the pre-command route does not name."
  (interactive)
  (insert "X"))

(defun dsh-emacs-test--user-echo-count (needle)
  "Count transcript user blocks whose body contains NEEDLE.
Blocks are located by the `dsh-emacs-user-message' property, so a restored
input-area draft (which carries no such property) is not counted."
  (let ((prop 'dsh-emacs-user-message)
        (pos (point-min))
        (n 0))
    (while (< pos (point-max))
      (let ((start (if (get-text-property pos prop)
                       pos
                     (next-single-property-change pos prop nil (point-max)))))
        (if (or (null start) (>= start (point-max)))
            (setq pos (point-max))
          (let ((end (or (next-single-property-change start prop nil (point-max))
                         (point-max))))
            (when (string-match-p
                   (regexp-quote needle)
                   (buffer-substring-no-properties start end))
              (setq n (1+ n)))
            (setq pos end)))))
    n))


;; --- Test 16: buffer modes ---
(ert-deftest dsh-emacs-test-input-dsh-emacs-mode-activates ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (ert-info ((format "%s" "dsh-emacs-mode activates"))
      (should (eq major-mode 'dsh-emacs-mode)))
    (ert-info ((format "%s" "input-marker variable exists"))
      (should (local-variable-p 'dsh-emacs--input-marker)))
    (ert-info ((format "%s" "input-marker marker created"))
      (should dsh-emacs--input-marker))))

;; --- Test 17: input area is writable ---
(ert-deftest dsh-emacs-test-input-input-area-writable ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    ;; New sessions install the structural end-of-buffer overlay after the input area.  Inserting at the
    ;; marker must still work even though the prompt itself is read-only.
    (dsh-emacs-modeline-setup)
    (goto-char dsh-emacs--input-marker)
    (insert "test input")
    (should (string= (buffer-substring-no-properties
                      dsh-emacs--input-marker (point-max))
                     "test input\n"))
    (should (string= (dsh-emacs--get-input) "test input"))))

;; --- Test 17b: the input area does not inherit the prompt's accent face ---
(ert-deftest dsh-emacs-test-input-input-prompt-carries-face ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-modeline-setup)
    (let* ((pos (marker-position dsh-emacs--input-marker))
           (prompt-face (get-text-property (1- pos) 'face)))
      ;; Precondition: the ❯ prompt itself carries the accent face.
      (ert-info ((format "%s" "input-prompt-carries-face"))
        (should prompt-face))
      ;; Typing runs `insert-and-inherit' (Emacs 31 `self-insert-command'),
      ;; which copies the previous character's face.  The prompt's
      ;; `rear-nonsticky' list must exclude `face', otherwise manual input
      ;; turns blue while pasted/completed text stays default colored.
      (goto-char pos)
      (insert-and-inherit "t")
      (ert-info ("Input rejects prompt face inheritance")
        (should-not (get-text-property pos 'face))))))

;; --- Test 27e: telega-style scroll discipline (chatbuf buffer-local) ---
(ert-deftest dsh-emacs-test-input-chat-buffer-scroll-discipline ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (ert-info ((format "%s" "chat-buffer-scroll-discipline"))
      (should (and (local-variable-p 'scroll-conservatively (current-buffer))
                   (= 101 scroll-conservatively)
                   (= 0 (or next-screen-context-lines -1))
                   scroll-error-top-bottom)))))

;; --- Test 24: the input anchor occupies its own line (before the bottom
;; structural line) ---
(ert-deftest dsh-emacs-test-input-input-anchor-keeps-own-line ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-modeline-setup)
    ;; The anchor prompt line always ends with a newline and sits right before
    ;; the end-of-buffer newline, so point-max never falls inside the editable input.
    (let ((mode-line-start (overlay-start dsh-emacs--modeline-overlay)))
      (ert-info ((format "%s" "input-anchor-keeps-own-line"))
        (should (and (eq (char-before mode-line-start) ?\n)
                     ;; the anchor prompt is on its own line, before the end-of-buffer newline
                     (save-excursion
                       (goto-char dsh-emacs--input-marker)
                       (eq (char-after (line-beginning-position)) ?❯))))))))

;; --- Test 33: cursor locked to the editable input area ---
(ert-deftest dsh-emacs-test-input-cursor-can-move-up-into-history ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (let ((inhibit-read-only t))
      (save-excursion
        (goto-char (point-min))
        (insert "user  hello\n")
        (put-text-property (point-min) (1- (point)) 'read-only t)))
    (let ((dsh-emacs--current-buffer (current-buffer)))
      (dsh-emacs--ensure-input-marker)
      (let ((mpos (marker-position dsh-emacs--input-marker)))
        ;; Moving up into the read-only transcript to read → should be allowed (the cursor
        ;; stays put)
        (goto-char (point-min))
        (dsh-emacs--lock-cursor-to-input)
        (ert-info ((format "%s" "cursor-can-move-up-into-history"))
          (should (= (point) (point-min))))
        ;; Cursor trying to move below the input area → should be clamped to the input
        ;; area end
        (goto-char (point-max))
        (dsh-emacs--lock-cursor-to-input)
        (let ((input-end (dsh-emacs--input-end)))
          (ert-info ((format "%s" "cursor-cannot-move-below-input"))
            (should (>= (point) mpos)))))
      ;; Typing directly from the read-only history area → should be routed back to the
      ;; input area (avoids text-read-only)
      (let ((this-command 'self-insert-command))
        (goto-char (point-min))
        (dsh-emacs--route-typing-to-input)
        (ert-info ((format "%s" "typing-in-history-routes-to-input"))
          (should (= (point) (marker-position dsh-emacs--input-marker))))))))

;; --- Test 33c: typing from below the input area, and standard insert commands
;; (RET/TAB/insert-char), route back to the editable draft ---
(ert-deftest dsh-emacs-test-input-route-typing-from-below-and-standard-inserts ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-modeline-setup)
    (goto-char dsh-emacs--input-marker)
    (insert "draft")
    (let ((marker (marker-position dsh-emacs--input-marker))
          (input-end (dsh-emacs--input-end)))
      ;; Below the input area (a stray click on the separator): continue at
      ;; the end of the draft, not at its start.
      (goto-char (point-max))
      (let ((this-command 'self-insert-command))
        (dsh-emacs--route-typing-to-input))
      (ert-info ((format "%s" "typing-below-input-routes-to-draft-end"))
        (should (= (point) input-end)))
      ;; Inside the editable draft typing must stay where the cursor is.
      (goto-char (+ marker 2))
      (let ((this-command 'self-insert-command)
            (inside (point)))
        (dsh-emacs--route-typing-to-input)
        (ert-info ((format "%s" "typing-inside-draft-keeps-point"))
          (should (= (point) inside))))
      ;; RET/TAB/insert-char from the transcript route like typing does.
      (dolist (command '(newline indent-for-tab-command insert-char))
        (goto-char (point-min))
        (let ((this-command command))
          (dsh-emacs--route-typing-to-input))
        (ert-info ((format "%s" (format "route-%s-from-history" command)))
          (should (= (point) marker)))))))

;; --- Test 33e: routed newline commands survive the read-only prompt space ---
;; electric-indent's post-self-insert cleanup and `newline-and-indent' both
;; call `delete-horizontal-space'; without a clamp they try to delete the
;; read-only `❯ ' space and fail before the newline lands.
(ert-deftest dsh-emacs-test-input-routed-newlines-keep-the-prompt-space ()
  :tags '(dsh-unit)
  (let ((electric-was electric-indent-mode))
    (unwind-protect
        (progn
          (electric-indent-mode 1)
          (dolist (command '(newline newline-and-indent
                             electric-newline-and-maybe-indent))
            (with-temp-buffer
              (dsh-emacs-mode)
              (dsh-emacs-modeline-setup)
              (let ((inhibit-read-only t))
                (goto-char (point-min))
                (insert "user  old\n")
                (put-text-property (point-min) (1- (point)) 'read-only t))
              (dsh-emacs--ensure-input-marker)
              (let ((marker (marker-position dsh-emacs--input-marker)))
                (goto-char (point-min))
                (let ((this-command command))
                  (dsh-emacs--route-typing-to-input))
                (let ((this-command command))
                  (call-interactively command))
                (ert-info ((format "%s" (format "routed-%s-keeps-prompt-space"
                                                command)))
                  (should (eq (char-before marker) ?\s))
                  (should (equal (buffer-substring-no-properties
                                  marker (1+ marker))
                                 "\n")))))))
      (electric-indent-mode (if electric-was 1 -1)))))

;; Unlisted commands retain the transcript's standard read-only behavior.
(ert-deftest dsh-emacs-test-input-unlisted-command-keeps-history-read-only ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (goto-char (+ (point-min) 2))
    (should-error (command-execute 'dsh-emacs-test--unlisted-insert-command)
                  :type 'text-read-only)
    (should (string-empty-p (dsh-emacs--get-input)))))

;; Explicit extensions route before the command reads interactive input.
(ert-deftest dsh-emacs-test-input-configured-command-reads-once ()
  :tags '(dsh-unit)
  (let ((dsh-emacs-composer-typing-commands
         (cons 'dsh-emacs-test--read-char-insert-command
               dsh-emacs-composer-typing-commands)))
    (with-temp-buffer
      (dsh-emacs-mode)
      (goto-char (+ (point-min) 2))
      (let ((this-command 'dsh-emacs-test--read-char-insert-command)
            (unread-command-events '(?a ?b)))
        (dsh-emacs--route-typing-to-input)
        (command-execute this-command)
        (should (equal (dsh-emacs--get-input) "a"))
        (should (equal unread-command-events '(?b)))))))

(ert-deftest dsh-emacs-test-input-insert-register-from-history-lands-in-input ()
  :tags '(dsh-unit)
  (let ((register-alist '((?a . "hello"))))
    (with-temp-buffer
      (dsh-emacs-mode)
      (goto-char (+ (point-min) 2))
      (let ((this-command 'insert-register)
            (unread-command-events '(?a ?b)))
        (dsh-emacs--route-typing-to-input)
        (call-interactively 'insert-register)
        (should (equal (dsh-emacs--get-input) "hello"))
        (should (equal unread-command-events '(?b)))))))

;; --- Test 33d: submitted text is trimmed like the web composer ---
(ert-deftest dsh-emacs-test-input-submit-trims-message ()
  :tags '(dsh-unit)
  (dolist (mode '(nil queue))
    (with-temp-buffer
      (dsh-emacs-mode)
      (dsh-emacs-modeline-setup)
      (setq-local dsh-emacs--buffer-session "trim-session")
      (let ((draft "  hello  \n")
            (dsh-emacs--input-history nil)
            (dsh-emacs--input-history-by-session (make-hash-table :test #'equal))
            sent callback)
        (dsh-emacs--replace-input draft)
        (cl-letf (((symbol-function 'dsh-emacs-subagent-require) #'ignore)
                  ((symbol-function 'dsh-emacs--busy-p) #'ignore)
                  ((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (_method params cb)
                     (setq sent params callback cb))))
          (dsh-emacs--submit-prompt draft nil mode)
          (let* ((request (alist-get 'request sent))
                 (part (aref (alist-get 'content request) 0)))
            (should (equal (alist-get 'text part) "hello")))
          (should (string-empty-p (dsh-emacs--get-input)))
          (funcall callback nil '((message . "offline")))
          (should (equal (dsh-emacs--get-input) draft)))))))

;; --- Test 33b: cursor clamped at the bottom of the input area — multi-line
;; input is unaffected, and it is independent of the global current-buffer (with
;; multiple sessions, that points at the last opened session) ---
(ert-deftest dsh-emacs-test-input-cursor-clamped-at-input-area-end ()
  :tags '(dsh-unit)
  (let* ((chat (get-buffer-create " *t33b-chat*"))
         (other (generate-new-buffer " *t33b-other*")))
    (unwind-protect
        (progn
          (with-current-buffer chat
            (dsh-emacs-mode)
            (dsh-emacs-modeline-setup)
            ;; Simulates multiple sessions: the global current-buffer points at another
            ;; session
            (setq dsh-emacs--current-buffer other))
          (with-current-buffer chat
            (let ((inhibit-read-only t))
              (goto-char dsh-emacs--input-marker)
              (insert "line one\nline two\nline three"))
            (let ((input-end (dsh-emacs--input-end)))
              ;; Out of bounds (M-> / clicking the bottom area) → clamped back to the input
              ;; area
              ;; end
              (goto-char (point-max))
              (dsh-emacs--lock-cursor-to-input)
              (ert-info ((format "%s" "cursor-clamped-at-input-area-end"))
                (should (= (point) input-end)))
              ;; Cursor position inside multi-line input does not move (unaffected)
              (goto-char dsh-emacs--input-marker)
              (forward-line 1)
              (let ((mid (point)))
                (dsh-emacs--lock-cursor-to-input)
                (ert-info ((format "%s" "cursor-stays-inside-multi-line-input"))
                  (should (= (point) mid))))
              ;; Stopping exactly at the input area end → not falsely clamped
              (goto-char input-end)
              (dsh-emacs--lock-cursor-to-input)
              (ert-info ((format "%s" "cursor-at-input-end-not-moved"))
                (should (= (point) input-end))))))
      (kill-buffer chat)
      (kill-buffer other))))

;; --- Test 33c: no-stop zone at the input line (`❯ ' icon and to its left); the
;; cursor is pulled back to the edit start ---
(ert-deftest dsh-emacs-test-input-cursor-prompt-zone-line-start-clamped ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (let ((dsh-emacs--current-buffer (current-buffer)))
      (let* ((mpos (marker-position dsh-emacs--input-marker))
             (line-start (save-excursion
                           (goto-char mpos)
                           (line-beginning-position))))
        ;; Line start (where `C-a' lands, left of the icon) → pulled to the edit start
        (goto-char line-start)
        (dsh-emacs--lock-cursor-to-input)
        (ert-info ((format "%s" "cursor-prompt-zone-line-start-clamped"))
          (should (= (point) mpos)))
        ;; The icon characters themselves (the two characters before the edit start) →
        ;; pulled to the edit start
        (goto-char (- mpos 2))
        (dsh-emacs--lock-cursor-to-input)
        (ert-info ((format "%s" "cursor-prompt-glyph-clamped"))
          (should (= (point) mpos)))
        ;; Stopping exactly at the edit start → not falsely clamped
        (goto-char mpos)
        (dsh-emacs--lock-cursor-to-input)
        (ert-info ((format "%s" "cursor-edit-start-not-moved"))
          (should (= (point) mpos)))
        ;; Transcript area (above the no-stop zone) → not falsely clamped
        (goto-char (point-min))
        (let ((p (point)))
          (dsh-emacs--lock-cursor-to-input)
          (ert-info ((format "%s" "cursor-transcript-above-untouched"))
            (should (= (point) p))))))))

;; --- Test 33d: input marker repair locates by `❯ ' rather than a fixed skip ---
;; When the queue prefix shares the prompt face with the prompt, the anchor lands
;; at the start of the prefix; the repair must land after `❯ ', not blindly skip
;; forward 2 characters into the prefix.
(ert-deftest dsh-emacs-test-input-prompt-anchor-moves-to-prefix-start ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (let ((inhibit-read-only t))
      (goto-char (dsh-emacs-render--input-anchor-pos))
      (insert (propertize "[next: fix] " 'face 'dsh-emacs-input-prompt-face
                          'read-only t))
      (let ((expect (marker-position dsh-emacs--input-marker)))
        (ert-info ((format "%s" "prompt-anchor-moves-to-prefix-start"))
          (should (= (dsh-emacs-render--input-anchor-pos) (- expect 14))))
        (setq dsh-emacs--input-marker nil)
        (dsh-emacs--ensure-input-marker)
        (ert-info ((format "%s" "marker-repaired-after-prompt-glyph"))
          (should (= (marker-position dsh-emacs--input-marker) expect)))))))

;; --- Test 33e: the input-area cursor must not land on a phantom line below the
;; input line (torn modeline overlay) ---
;; User report (split window): the cursor ran below the input line and could not be
;; moved back; the root cause is that when the modeline structural overlay is torn,
;; `dsh-emacs--input-end' falls back to point-max — and point-max is exactly the
;; phantom line below the input line (after the separating newline), so below-clamp
;; becomes a no-op and the cursor stays stuck below the input line until a reopen /
;; refresh rebuilds the overlay.
;; Invariant: even if the overlay disappears while the separating newline remains,
;; `dsh-emacs--input-end' must not equal point-max; when the cursor sits at
;; point-max (the phantom line), lock must pull it back to the input line.
(ert-deftest dsh-emacs-test-input-input-end-torn-overlay-not-phantom ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-modeline-setup)
    (goto-char dsh-emacs--input-marker)
    (insert "uuu123")
    ;; Tears the overlay but keeps the separating newline after it (simulating
    ;; split-window follow/overlay churn).
    (when dsh-emacs--modeline-overlay
      (delete-overlay dsh-emacs--modeline-overlay)
      (setq dsh-emacs--modeline-overlay nil))
    ;; The separating newline remains → the input end must not fall back to the
    ;; phantom-line point-max.
    (let* ((end (dsh-emacs--input-end))
           (pmax (point-max))
           (input-line (save-excursion
                         (goto-char (marker-position dsh-emacs--input-marker))
                         (line-number-at-pos))))
      (ert-info ((format "%s" "input-end-torn-overlay-not-phantom"))
        (should (and (< end pmax)
                     (eq (char-after end) ?\n))))
      ;; Cursor sits at point-max (the phantom line) → lock must pull it back to the
      ;; input line.
      (goto-char pmax)
      (let ((below (line-number-at-pos (point))))
        (dsh-emacs--lock-cursor-to-input)
        (ert-info ((format "%s" "cursor-torn-overlay-clamped-to-input-line"))
          (should (and (= (point) end)
                       (< (line-number-at-pos (point)) below)
                       (= (line-number-at-pos (point)) input-line))))))))

;; --- Test 44: a chat buffer never shows modified / closing never prompts to
;; save ---
(ert-deftest dsh-emacs-test-input-chat-buffer-insert-keeps-unmodified ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (insert "hello")
    (ert-info ((format "%s" "chat-buffer-insert-keeps-unmodified"))
      (should (not (buffer-modified-p))))))

;; Transcript edits clear the modified flag without forcing mode-line layout.
(ert-deftest dsh-emacs-test-input-chat-edits-do-not-invalidate-the-mode-line ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (let ((invalidations 0)
          (set-modified (symbol-function 'set-buffer-modified-p)))
      (cl-letf (((symbol-function 'set-buffer-modified-p)
                 (lambda (flag)
                   (cl-incf invalidations)
                   (funcall set-modified flag))))
        (insert "hello")
        (put-text-property (- (point) 5) (point) 'face 'bold))
      (ert-info ((format "%s" "chat-edits-do-not-invalidate-the-mode-line"))
        (should (zerop invalidations))
        (should (not (buffer-modified-p)))))))

(ert-deftest dsh-emacs-test-input-kill-query-fn-clears-modified-allows-kill ()
  :tags '(dsh-unit)
  (let ((buf (get-buffer-create " *dsh-mod-test*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (dsh-emacs-mode)
            (insert "x"))
          ;; After external code force-marks the buffer modified, the kill query path
          ;; still lets it through. Contract: only a t from the query function allows the
          ;; kill (returning nil silently blocks it — that was the root cause of the
          ;; previous "cannot close" regression, see test 44b).
          (with-current-buffer buf
            (set-buffer-modified-p t)
            (let ((ret (dsh-emacs--chat-buffer-clear-modified)))
              (ert-info ((format "%s" "kill-query-fn-clears-modified-allows-kill"))
                (should (and (eq ret t) (not (buffer-modified-p)))))))
          ;; Restore the after-change invariant: insertions after a clear still leave the
          ;; buffer unmodified
          (with-current-buffer buf
            (insert "y")
            (ert-info ((format "%s" "chat-buffer-reinsert-stays-clean"))
              (should (not (buffer-modified-p))))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

;; --- Test 44b: the real kill path — the query returns t and the buffer really
;; gets killed ---
(ert-deftest dsh-emacs-test-input-chat-buffer-kill-buffer-succeeds ()
  :tags '(dsh-unit)
  (let ((buf (get-buffer-create " *dsh-kill-test*")))
    (with-current-buffer buf
      (dsh-emacs-mode)
      (insert "x"))
    (let ((res (kill-buffer buf)))
      (ert-info ((format "%s" "chat-buffer-kill-buffer-succeeds"))
        (should (and (eq res t) (not (buffer-live-p buf))))))))

;; --- Test 46: send-or-stop interrupts when busy (session/cancel) and sends
;; when idle ---
(ert-deftest dsh-emacs-test-input-send-or-stop-busy-interrupts-via-cancel ()
  :tags '(dsh-unit)
  (let ((dsh-emacs--input-history nil)
        (dsh-emacs--input-history-pos nil)
        (dsh-emacs--input-history-by-session (make-hash-table :test #'equal))
        (dsh-emacs--current-session "sess-cancel")
        (buf (generate-new-buffer " *dsh-interrupt-test*"))
        (calls nil))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-mode)
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method params _cb)
                       (push (list method params) calls))))
            ;; Busy → pressing C-c C-c again sends session/cancel instead of queueing a
            ;; new message
            (setq-local dsh-emacs--ml-busy t)
            (dsh-emacs-send-or-stop)
            (let* ((call (car calls))
                   (req (cdr (assq 'request (cadr call)))))
              (ert-info ((format "%s" "send-or-stop-busy-interrupts-via-cancel"))
                (should (and (string= "session/cancel" (car call))
                             (string= "sess-cancel"
                                      (cdr (assq 'sessionId req)))))))
            ;; Idle + text present → send session/prompt
            (setq-local dsh-emacs--ml-busy nil)
            (setq calls nil)
            (dsh-emacs--replace-input "hello there")
            (dsh-emacs-send-or-stop)
            (let* ((call (car calls))
                   (req (cdr (assq 'request (cadr call))))
                   (content (cdr (assq 'content req)))
                   (part (and content (aref content 0))))
              (ert-info ((format "%s" "send-or-stop-idle-sends-prompt"))
                (should (and (string= "session/prompt" (car call))
                             (string= "hello there" (cdr (assq 'text part)))))))
            ;; Idle + empty text → no request is sent at all
            (setq calls nil)
            (dsh-emacs--replace-input "   ")
            (dsh-emacs-send-or-stop)
            (ert-info ((format "%s" "send-or-stop-idle-empty-noop"))
              (should (null calls)))))
      (kill-buffer buf))))

;; Regression: undo immediately after sending restores the cleared draft.
(ert-deftest dsh-emacs-test-input-undo-send-has-undo-information ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (setq-local dsh-emacs--buffer-session "undo-submit")
    (let ((dsh-emacs--current-session "undo-submit")
          (dsh-emacs--input-history nil)
          (dsh-emacs--input-history-pos nil)
          (dsh-emacs--input-history-by-session (make-hash-table :test #'equal)))
      (goto-char dsh-emacs--input-marker)
      (insert "draft to send")
      (undo-boundary)
      (run-hooks 'pre-command-hook)
      (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                 (lambda (&rest _) nil))
                ((symbol-function 'dsh-emacs-server-ensure) #'ignore)
                ((symbol-function 'dsh-emacs--busy-p) (lambda () nil)))
        (dsh-emacs-send-or-stop))
      (undo-boundary)
      (let ((last-command 'dsh-emacs-send-or-stop) (this-command 'undo)
            (pending-undo-list nil)
            (undo-equiv-table (make-hash-table :test 'eq))
            (transcript (buffer-substring-no-properties
                         (point-min) dsh-emacs--input-marker)))
        (run-hooks 'pre-command-hook)
        (ert-info ((format "%s" "undo-send-has-undo-information"))
          (should (condition-case nil (progn (undo) t) (user-error nil))))
        (run-hooks 'post-command-hook)
        (ert-info ((format "%s" "undo-send-restores-draft-without-changing-echo"))
          (should (equal (dsh-emacs--get-input) "draft to send"))
          (should (= (point) (dsh-emacs--input-end)))
          (should (equal transcript (buffer-substring-no-properties
                                     (point-min) dsh-emacs--input-marker))))))))

;; --- Test 52g: undo/redo covers the input area, never the transcript ---
;; A chat buffer is a live view: rendered messages, tool cards and streamed
;; bodies must stay out of the undo history (undo binds `inhibit-read-only'
;; itself, so the transcript's read-only property cannot protect it), while
;; typing after `❯ ' stays undoable.
(ert-deftest dsh-emacs-test-input-undo-transcript-write-not-recorded ()
  :tags '(dsh-unit)
  (let ((buf (generate-new-buffer " *dsh-undo*")))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-mode)
          ;; A programmatic transcript write leaves no undo entry at all
          (dsh-emacs-render--insert-chat-message
           "agent reply" 'dsh-emacs-assistant-body-face
           (dsh-emacs-render--input-insert-point) nil 'assistant)
          (ert-info ((format "%s" "undo-transcript-write-not-recorded"))
            (should (null buffer-undo-list)))
          ;; Typing in the input is recorded and undoable (the command loop
          ;; closes the group with an undo boundary after every command)
          (goto-char (dsh-emacs--input-end))
          (insert "draft")
          (undo-boundary)
          (ert-info ((format "%s" "undo-input-edit-recorded"))
            (should (consp buffer-undo-list)))
          (let ((last-command nil) (this-command nil) (pending-undo-list nil)
                (undo-equiv-table (make-hash-table :test 'eq)))
            (undo)
            (ert-info ((format "%s" "undo-clears-the-draft-not-the-transcript"))
              (should (and (string= "" (dsh-emacs--get-input))
                           (string-match-p "agent reply" (buffer-string)))))
            (undo-redo 1)
            (ert-info ((format "%s" "undo-redo-restores-the-draft"))
              (should (and (string= "draft" (dsh-emacs--get-input))
                           (string-match-p "agent reply" (buffer-string)))))))
      (kill-buffer buf))))

;; --- Test 52h: a transcript write rebuilds the input's undo history ---
;; Undo entries hold absolute positions that Emacs does not adjust when text
;; lands elsewhere, so a message rendered above the input leaves the records
;; made for the draft pointing at transcript text.  The stale flag is set by
;; `after-change-functions' and acted on by `pre-command-hook' before the
;; command can use such a record.
(ert-deftest dsh-emacs-test-input-undo-stale-flagged-after-transcript-write ()
  :tags '(dsh-unit)
  (let ((buf (generate-new-buffer " *dsh-undo-shift*")))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-mode)
          (goto-char (dsh-emacs--input-end))
          (insert "first draft")
          (dsh-emacs-render--insert-chat-message
           "streamed reply" 'dsh-emacs-assistant-body-face
           (dsh-emacs-render--input-insert-point) nil 'assistant)
          (ert-info ((format "%s" "undo-stale-flagged-after-transcript-write"))
            (should dsh-emacs--undo-stale))
          ;; `pre-command-hook' runs this before the command can use a record
          (run-hooks 'pre-command-hook)
          (ert-info ((format "%s" "undo-history-rebuilt-around-the-input"))
            (should (and (null dsh-emacs--undo-stale)
                         (equal (list nil (cons (marker-position dsh-emacs--input-marker)
                                                (dsh-emacs--input-end)))
                                buffer-undo-list))))
          (let ((last-command nil) (this-command nil) (pending-undo-list nil)
                (undo-equiv-table (make-hash-table :test 'eq)))
            (undo)
            (ert-info ((format "%s" "undo-after-transcript-write-spares-the-transcript"))
              (should (and (string= "" (dsh-emacs--get-input))
                           (string-match-p "streamed reply" (buffer-string)))))
            (run-hooks 'post-command-hook)
            ;; Undo removed the draft: point is its (now empty) end
            (ert-info ((format "%s" "undo-leaves-point-at-the-input-start"))
              (should (= (point) (marker-position dsh-emacs--input-marker))))
            ;; Repairing the draft must also move the cursor back for typing:
            ;; `undo' parks point at the restored region's start on its own.
            (undo-redo 1)
            (run-hooks 'post-command-hook)
            (ert-info ((format "%s" "redo-parks-point-after-the-restored-draft"))
              (should (and (string= "first draft" (dsh-emacs--get-input))
                           (= (point) (dsh-emacs--input-end)))))))
      (kill-buffer buf))))

;; --- Test 52i: typing after a rebuild is undoable step by step ---
(ert-deftest dsh-emacs-test-input-undo-after-rebuild-drops-the-last-typing ()
  :tags '(dsh-unit)
  (let ((buf (generate-new-buffer " *dsh-undo-steps*")))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-mode)
          (goto-char (dsh-emacs--input-end))
          (insert "draft")
          (dsh-emacs-render--insert-chat-message
           "reply" 'dsh-emacs-assistant-body-face
           (dsh-emacs-render--input-insert-point) nil 'assistant)
          (dsh-emacs--reset-undo-history)
          ;; Typing after the rebuild records normal granular entries
          (goto-char (dsh-emacs--input-end))
          (insert " more")
          (undo-boundary)
          (let ((last-command nil) (this-command nil) (pending-undo-list nil)
                (undo-equiv-table (make-hash-table :test 'eq)))
            (undo)
            (ert-info ((format "%s" "undo-after-rebuild-drops-the-last-typing"))
              (should (string= "draft" (dsh-emacs--get-input))))
            (run-hooks 'post-command-hook)
            (undo-redo 1)
            (run-hooks 'post-command-hook)
            (ert-info ((format "%s" "redo-parks-point-after-the-typing-it-restores"))
              (should (and (string= "draft more" (dsh-emacs--get-input))
                           (= (point) (dsh-emacs--input-end)))))))
      (kill-buffer buf))))

;; --- Test 96: submit-prompt dispatches slash commands ---
(ert-deftest dsh-emacs-test-input-submit-plain-sends-session-prompt ()
  :tags '(dsh-unit)
  (let ((dsh-emacs--input-history nil)
        (dsh-emacs--input-history-pos nil)
        (dsh-emacs--input-history-by-session (make-hash-table :test #'equal))
        (dsh-emacs--current-session "sess-slash")
        (buf (generate-new-buffer " *dsh-slash-submit*"))
        (calls nil))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-mode)
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method params cb)
                       (push (list method params) calls)
                       (if (string= method "commands/execute")
                           (let ((line (cdr (assq 'line params))))
                             (if (equal line "/frobnicate")
                                 (funcall cb t nil)
                               (funcall cb t '((commandId . "c9")
                                               (result . ((kind . "success")
                                                          (text . "done")))))))
                         (funcall cb t '((accepted . t))))))
                    ((symbol-function 'dsh-emacs--ml-busy-set)
                     (lambda (&rest _) nil))
                    ((symbol-function 'dsh-emacs-events-connect)
                     (lambda (_c) nil))
                    ((symbol-function 'dsh-emacs-events--watchdog-start)
                     (lambda () nil)))
            ;; Plain message → session/prompt (the original path is unchanged)
            (dsh-emacs--submit-prompt "hi")
            (let* ((call (car calls))
                   (content (cdr (assq 'content
                                       (cdr (assq 'request (cadr call))))))
                   (part (and content (aref content 0))))
              (ert-info ((format "%s" "submit-plain-sends-session-prompt"))
                (should (and (string= "session/prompt" (car call))
                             (string= "hi" (cdr (assq 'text part)))))))
            ;; Known command → commands.execute, and session/prompt is no longer sent
            (setq calls nil)
            (dsh-emacs--submit-prompt "/compact")
            (let* ((call (car calls))
                   (params (cadr call)))
              (ert-info ((format "%s" "submit-slash-routes-to-execute"))
                (should (and (string= "commands/execute" (car call))
                             (string= "/compact" (cdr (assq 'line params)))
                             ;; Attachment-less command still carries the required
                             ;; 0.1.5 field as an empty tagged array.
                             (equal (cdr (assq 'submittedAttachments params)) [])
                             (null (assq 'images params))
                             (= (length calls) 1)))))
            ;; Slash command with attachments: the attachments go into the tagged
            ;; `submittedAttachments', not into session/prompt's content (the caption text
            ;; still stays in the command line).  The staged list holds one entry
            ;; per attachment — a bare media-type alist would read as two
            ;; dotted pairs, not as one attachment.
            (setq calls nil)
            (dsh-emacs--submit-prompt
             "/compact"
             '(((mediaType . "image/png") (data . "eA=="))))
            (let* ((call (car calls))
                   (params (cadr call)))
              (ert-info ((format "%s" "submit-slash-carries-tagged-attachment"))
                (should (string= "commands/execute" (car call)))
                (should (= (length calls) 1))
                (should (equal (append (cdr (assq 'submittedAttachments params)) nil)
                               '(((type . "image") (mediaType . "image/png")
                                  (data . "eA==")))))))
            ;; Not found in the registry → falls back to a plain message (same semantics as
            ;; the browser)
            (setq calls nil)
            (dsh-emacs--submit-prompt "/frobnicate")
            (let* ((prompt-call (car calls))
                   (content (cdr (assq 'content
                                       (cdr (assq 'request (cadr prompt-call))))))
                   (part (and content (aref content 0))))
              (ert-info ((format "%s" "submit-unknown-slash-falls-back-to-plain"))
                (should (and (= (length calls) 2)
                             (string= "session/prompt" (car prompt-call))
                             (string= "commands/execute" (car (cadr calls)))
                             (string= "/frobnicate" (cdr (assq 'text part)))))))))
      (kill-buffer buf))))

;; --- Test 96b: a slash submit clears the input area immediately (without
;; waiting for the RPC round trip) ---
(ert-deftest dsh-emacs-test-input-submit-slash-clears-and-records-immediately ()
  :tags '(dsh-unit)
  (let ((dsh-emacs--input-history nil)
        (dsh-emacs--input-history-pos nil)
        (dsh-emacs--input-history-by-session (make-hash-table :test #'equal))
        (dsh-emacs--current-session "sess-clear")
        (buf (generate-new-buffer " *dsh-slash-clear*"))
        )
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-mode)
          (setq dsh-emacs--input-history-pos 0)   ; pretend to be in browse state
          (goto-char (point-max))
          (insert "/compact ")
          ;; the rpc never calls back (the real url-retrieve round trip never returns /
          ;; offline): the input must still be cleared and the history recorded ---
          ;; clearing no longer depends on the callback.
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (_m _p _cb) nil)))
            (dsh-emacs--submit-prompt (dsh-emacs--get-input)))
          (ert-info ((format "%s" "submit-slash-clears-and-records-immediately"))
            (should (and (string-empty-p (dsh-emacs--get-input))
                         (string= "/compact" (car dsh-emacs--input-history))
                         (null dsh-emacs--input-history-pos)))))
      (kill-buffer buf))))

;; --- Test 96c: slash transport failure → restore the original text (and do not
;; overwrite new input) ---
(ert-deftest dsh-emacs-test-input-submit-slash-restores-on-transport-failure ()
  :tags '(dsh-unit)
  (let ((dsh-emacs--input-history nil)
        (dsh-emacs--input-history-pos nil)
        (dsh-emacs--input-history-by-session (make-hash-table :test #'equal))
        (dsh-emacs--current-session "sess-fail")
        (buf (generate-new-buffer " *dsh-slash-fail*"))
        (captured nil)
        )
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-mode)
          (goto-char (point-max))
          (insert "/compact")
          ;; Transport failure (ok=nil): the input area is still empty → restore the
          ;; original text for an easy retry
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (_m _p cb) (setq captured cb)
                       (funcall cb nil "boom"))))
            (dsh-emacs--submit-prompt "/compact"))
          (ert-info ((format "%s" "submit-slash-restores-on-transport-failure"))
            (should (string= "/compact" (dsh-emacs--get-input))))
          ;; The callback arrives late, after the user typed new content → do not overwrite
          (goto-char (point-max))
          (insert "/new-typed")
          (funcall captured nil "boom")
          (ert-info ((format "%s" "submit-slash-failure-keeps-new-typing"))
            (should (string-match-p "new-typed" (dsh-emacs--get-input)))))
      (kill-buffer buf))))

;; --- Test 96d: slash submit history is recorded only once (both the miss
;; fallback and the accepted path) ---
(ert-deftest dsh-emacs-test-input-submit-slash-miss-records-history-once ()
  :tags '(dsh-unit)
  (let ((dsh-emacs--input-history nil)
        (dsh-emacs--input-history-pos nil)
        (dsh-emacs--input-history-by-session (make-hash-table :test #'equal))
        (dsh-emacs--current-session "sess-hist")
        (buf (generate-new-buffer " *dsh-slash-hist*"))
        )
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-mode)
          ;; Not found in the registry → falls back to a plain message: history is recorded
          ;; once only, at submit time
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method _p cb)
                       (if (string= method "commands/execute")
                           (funcall cb t nil)
                         (funcall cb t '((accepted . t)))))))
            (dsh-emacs--submit-prompt "/frobnicate"))
          (ert-info ((format "%s" "submit-slash-miss-records-history-once"))
            (should (= 1 (cl-count "/frobnicate" dsh-emacs--input-history
                                   :test #'string=))))
          (setq dsh-emacs--input-history nil)
          ;; Accepted: history is likewise recorded only once (at submit time)
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method _p cb)
                       (if (string= method "commands/execute")
                           (funcall cb t '((commandId . "c9")
                                           (result . ((kind . "success")))))
                         (funcall cb t '((accepted . t)))))))
            (dsh-emacs--submit-prompt "/compact"))
          (ert-info ((format "%s" "submit-slash-admit-records-history-once"))
            (should (= 1 (cl-count "/compact" dsh-emacs--input-history
                                   :test #'string=)))))
      (kill-buffer buf))))

;; --- Test 98p: the plain send path clears the input area on submit,
;; failure restores the draft, no double send on repeated presses ---
;; Regression: `dsh-emacs--submit-plain' originally cleared the input area
;; only in the RPC success callback --- pressing C-c C-c again during the
;; RPC round trip (busy still nil) would send the same message again
;; verbatim (double send), and the success callback's clear would wipe a
;; draft typed during the round trip. Fix: clear on submit (same feel as
;; the command/deferred paths), on transport failure restore the original
;; text only when the input area is still empty, and success no longer
;; touches the input area.
(ert-deftest dsh-emacs-test-input-plain-submit-clears-input-immediately ()
  :tags '(dsh-unit)
  (let ((dsh-emacs--input-history nil)
        (dsh-emacs--input-history-pos nil)
        (dsh-emacs--input-history-by-session (make-hash-table :test #'equal))
        (dsh-emacs--current-session "sess-plain-clear")
        (buf (generate-new-buffer " *dsh-plain-submit-clear*"))
        (cb nil))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-mode)
          (setq-local dsh-emacs--buffer-session "sess-plain-clear")
          (dsh-emacs--ml-busy-clear)
          ;; Scenario 1: clear on submit (without waiting for the RPC to return);
          ;; on failure with the input area still empty → restore the original text
          (goto-char dsh-emacs--input-marker)
          (insert "draft one")
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (_method _params callback) (setq cb callback))))
            (dsh-emacs--submit-plain "draft one"))
          (ert-info ((format "%s" "plain-submit-clears-input-immediately"))
            (should (string-empty-p (dsh-emacs--get-input))))
          (ert-info ((format "%s" "plain-submit-echoes-before-rpc"))
            (should (= 1 (dsh-emacs-test--user-echo-count "draft one"))))
          (funcall cb nil '((error . "boom")))
          (ert-info ((format "%s" "plain-submit-failure-restores-draft"))
            (should (string= "draft one" (dsh-emacs--get-input))))
          (ert-info ((format "%s" "plain-submit-failure-rolls-back-echo"))
            (should (= 0 (dsh-emacs-test--user-echo-count "draft one"))))
          (ert-info ((format "%s" "plain-submit-failure-drops-pending"))
            (should (null dsh-emacs--pending-user-messages)))
          (ert-info ((format "%s" "plain-submit-failure-drops-echo-entry"))
            (should (null dsh-emacs--pending-user-echoes)))
          ;; Scenario 2: failure must not overwrite a draft typed during the round
          ;; trip
          (dsh-emacs--clear-input)
          (setq cb nil)
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (_method _params callback) (setq cb callback))))
            (dsh-emacs--submit-plain "draft two"))
          (insert "newer draft")
          (funcall cb nil '((error . "boom")))
          (ert-info ((format "%s" "plain-submit-failure-keeps-newer-draft"))
            (should (string= "newer draft" (dsh-emacs--get-input))))
          (ert-info ((format "%s" "plain-submit-failure-rolls-back-echo-two"))
            (should (= 0 (dsh-emacs-test--user-echo-count "draft two"))))
          ;; Scenario 3: the success path leaves the echo on screen (the
          ;; canonical `user/message' consumes the pending entry) and never
          ;; touches a draft typed during the round trip
          (dsh-emacs--clear-input)
          (setq cb nil)
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (_method _params callback) (setq cb callback))))
            (dsh-emacs--submit-plain "draft three"))
          (insert "typed during flight")
          (funcall cb t '((ok . t)))
          (ert-info ((format "%s" "plain-submit-success-keeps-newer-draft"))
            (should (string= "typed during flight" (dsh-emacs--get-input))))
          (ert-info ((format "%s" "plain-submit-success-keeps-echo"))
            (should (= 1 (dsh-emacs-test--user-echo-count "draft three"))))
          (dsh-emacs--ml-busy-clear))
      (when (buffer-live-p buf) (kill-buffer buf)))))

;; --- Test 98p2: a consumed echo is never rolled back by a later same-text
;; --- failure ---
;; Once the canonical `user/message' takes over an optimistic echo, its
;; rollback record must retire with the pending entry.  A stale record left
;; behind made a later FAILED re-send of the same text delete the accepted
;; block instead of its own echo.
(ert-deftest dsh-emacs-test-input-echo-consume-setup ()
  :tags '(dsh-unit)
  (let ((dsh-emacs--input-history nil)
        (dsh-emacs--input-history-pos nil)
        (dsh-emacs--input-history-by-session (make-hash-table :test #'equal))
        (buf (generate-new-buffer " *dsh-echo-consume*"))
        (cbs nil))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-mode)
          (setq-local dsh-emacs--buffer-session "sess-echo-consume")
          (dsh-emacs--ml-busy-clear)
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (_m _p callback) (push callback cbs))))
            (dsh-emacs--submit-plain "dup"))
          (ert-info ((format "%s" "echo-consume-setup"))
            (should (= 1 (dsh-emacs-test--user-echo-count "dup")))
            (should (= 1 (length dsh-emacs--pending-user-echoes))))
          ;; The canonical event takes over: pending + rollback record retire,
          ;; the block stays on screen.
          (dsh-emacs-events--dispatch-event
           buf '((type . "user/message") (seq . 1)
                 (data . ((content . [((type . "text") (text . "dup"))])))))
          (ert-info ((format "%s" "echo-consume-drops-rollback-record"))
            (should (null dsh-emacs--pending-user-messages))
            (should (null dsh-emacs--pending-user-echoes))
            (should (= 1 (dsh-emacs-test--user-echo-count "dup"))))
          ;; Re-send the same text under its OWN callback capture — the first
          ;; submit's callback belongs to the consumed entry — and fail it: it
          ;; deletes its own echo and leaves the accepted block untouched.
          (setq cbs nil)
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (_m _p callback) (push callback cbs))))
            (dsh-emacs--submit-plain "dup"))
          (ert-info ((format "%s" "echo-consume-second-echo"))
            (should (= 2 (dsh-emacs-test--user-echo-count "dup"))))
          (funcall (car cbs) nil '((error . "boom")))
          (ert-info ((format "%s" "echo-consume-failure-deletes-own-echo-only"))
            (should (= 1 (dsh-emacs-test--user-echo-count "dup")))
            (should (null dsh-emacs--pending-user-echoes))
            (should (null dsh-emacs--pending-user-messages)))
          (dsh-emacs--ml-busy-clear))
      (when (buffer-live-p buf) (kill-buffer buf)))))

;; --- Test 98p2b: a failed duplicate submit rolls back its OWN echo ---
;; Two in-flight submits of the same text are only distinguishable by the
;; rollback entries they own: the pending list matches by identity while the
;; echo list was looked up by text (`assoc'/`equal'), so when the NEWER submit
;; failed first the older block was deleted and the newer rollback record was
;; left pointing at a live block.
(ert-deftest dsh-emacs-test-input-echo-identity-setup ()
  :tags '(dsh-unit)
  (let ((dsh-emacs--input-history nil)
        (dsh-emacs--input-history-pos nil)
        (dsh-emacs--input-history-by-session (make-hash-table :test #'equal))
        (buf (generate-new-buffer " *dsh-echo-identity*"))
        (cbs nil)
        (first-entry nil)
        (second-entry nil))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-mode)
          (setq-local dsh-emacs--buffer-session "sess-echo-identity")
          (dsh-emacs--ml-busy-clear)
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (_m _p callback) (push callback cbs))))
            (dsh-emacs--submit-plain "dup")
            (setq first-entry (car dsh-emacs--pending-user-echoes))
            (dsh-emacs--submit-plain "dup")
            (setq second-entry (cadr dsh-emacs--pending-user-echoes)))
          (ert-info ((format "%s" "echo-identity-setup"))
            (should (= 2 (length dsh-emacs--pending-user-echoes)))
            (should (= 2 (dsh-emacs-test--user-echo-count "dup"))))
          ;; `cbs' is newest-first, so the second submit's callback fails first.
          (funcall (car cbs) nil '((error . "boom")))
          (ert-info ((format "%s" "echo-identity-failure-rolls-back-own-entry"))
            (should (memq first-entry dsh-emacs--pending-user-echoes))
            (should (null (memq second-entry dsh-emacs--pending-user-echoes)))
            (should (= 1 (dsh-emacs-test--user-echo-count "dup"))))
          (dsh-emacs--ml-busy-clear))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest dsh-emacs-test-input-kill-line-at-input-end-deletes-nothing ()
  :tags '(dsh-unit)
  (dsh-emacs--composer-delete-guard-install)
  (let ((canon "@[My Talk](dsh-session:ab12_CD)"))
    (with-temp-buffer
      (setq-local dsh-emacs--input-marker (point-min-marker))
      (setq-local dsh-emacs--modeline-overlay nil)
      ;; Cursor at the input end: nothing to delete, so input and chip stay and
      ;; the separator newline survives
      (insert "@My Talk")
      (dsh-emacs-reference--session-chip (point-min) (point) canon)
      (insert "\n")                   ; structural separator newline (mode-line)
      (goto-char (1- (point-max)))
      (kill-line)
      (ert-info ((format "%s" "kill-line-at-input-end-deletes-nothing"))
        (should (and (string= (buffer-substring-no-properties (point-min) (point-max))
                              "@My Talk\n")
                     (get-text-property (point-min) 'dsh-emacs-reference-chip))))
      ;; Cursor mid-input: C-k deletes only after point ("ay @My Talk"), keeping
      ;; the "s" before the cursor
      (erase-buffer)
      (insert "say ")
      (let ((chip-start (point)))
        (insert "@My Talk")
        (dsh-emacs-reference--session-chip chip-start (point) canon))
      (insert "\n")
      (goto-char (1+ (point-min)))    ; cursor inside "say " (after 's')
      (kill-line)
      (ert-info ((format "%s" "kill-line-at-input-middle-keeps-point-prefix"))
        (should (and (string= (buffer-substring-no-properties (point-min) (point-max))
                              "s\n")
                     (eq (char-before (point-max)) ?\n)))))))

;; --- M-d (kill-word) / C-d at the input end must not eat the structural
;; separator newline ---
;; Root cause: the structural newline at the input's end is deletable text; a
;; forward `kill-word' / `C-d' at the end removed it, input-end fell back to
;; point-max, the phantom line became the "editable end", the below-clamp
;; stopped working and the cursor was stranded below the input line.
;; `dsh-emacs--composer-delete-guard-install' clips forward deletes at the
;; input boundary (kill-region clip / delete-forward-char cap), so no delete
;; command crosses the newline.
;; Invariant: a forward word/char delete at the input end never removes the
;; separator newline and the cursor locks back onto the input line.
(ert-deftest dsh-emacs-test-input-backward-word-kill-boundary ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-modeline-setup)
    (goto-char dsh-emacs--input-marker)
    (insert "hello world")
    (let ((assert-end (lambda (label)
                        (let ((sep (eq (char-before (point-max)) ?\n)))
                          (dsh-emacs--lock-cursor-to-input)
                          (ert-info ((format "%s" label))
                            (should (and sep
                                         (= (point) (dsh-emacs--input-end)))))))))
      (goto-char (dsh-emacs--input-end))
      (condition-case nil (kill-word 1) (error nil))
      (funcall assert-end "word-kill-at-input-end-keeps-separator")
      (goto-char (dsh-emacs--input-end))
      (condition-case nil (delete-forward-char 1) (error nil))
      (funcall assert-end "delete-forward-at-input-end-keeps-separator")
      ;; normal editing still works: forward kill-word from the start of the last
      ;; word must delete only that word and leave the separator newline intact.
      (goto-char (- (dsh-emacs--input-end) (length "world")))
      (kill-word 1)
      (ert-info ((format "%s" "word-kill-mid-last-word-keeps-separator"))
        (should (and (string= (buffer-substring-no-properties
                               (marker-position dsh-emacs--input-marker) (point-max))
                              "hello \n")
                     (eq (char-before (point-max)) ?\n)))))))

;; Backward word kills must stop at the editable start, including drafts
;; consisting only of punctuation and counts that would reach the transcript.
(ert-deftest dsh-emacs-test-input-backward-word-kill-input-boundary-case-case ()
  :tags '(dsh-unit)
  (dolist (example '(("~/" 1 "" "~/")
                     ("../" 1 "" "../")
                     ("   " 1 "" "   ")
                     ("~/docs" 1 "~/" "docs")
                     ("~/docs" 2 "" "~/docs")
                     ("~/" 5 "" "~/")
                     ("alpha beta" 1 "alpha " "beta")
                     ("" 1 "" "previous kill")))
    (pcase-let ((`(,draft ,count ,expected ,killed) example))
      (with-temp-buffer
        (dsh-emacs-mode)
        (dsh-emacs-modeline-setup)
        (goto-char dsh-emacs--input-marker)
        (insert draft)
        (let ((header (buffer-substring (point-min) dsh-emacs--input-marker))
              (kill-ring '("previous kill"))
              (last-command nil)
              failure)
          (condition-case err
              (backward-kill-word count)
            (error (setq failure err)))
          (ert-info ((format "%s" (format "backward-word-kill-input-boundary-%S-%s" draft count)))
            (should (null failure))
            (should (equal (dsh-emacs--get-input) expected))
            (should (equal (car kill-ring) killed))
            (should (equal-including-properties
                     header (buffer-substring (point-min) dsh-emacs--input-marker)))
            (should (eq (char-before (point-max)) ?\n))
            (should (= (point) (dsh-emacs--input-end)))))))))

;; Crossing both boundaries must preserve the transcript and separator for
;; either region direction; the kill ring receives only the editable draft.
(ert-deftest dsh-emacs-test-input-composer-kill-clips-both-boundaries-case ()
  :tags '(dsh-unit)
  (dolist (backward '(nil t))
    (with-temp-buffer
      (dsh-emacs-mode)
      (dsh-emacs-modeline-setup)
      (goto-char dsh-emacs--input-marker)
      (insert "draft")
      (let ((header (buffer-substring (point-min) dsh-emacs--input-marker))
            (start (- dsh-emacs--input-marker 2))
            (end (point-max))
            (kill-ring nil)
            (last-command nil))
        (goto-char (if backward start end))
        (kill-region (if backward end start) (if backward start end))
        (ert-info ((format "%s" (format "composer-kill-clips-both-boundaries-%s" backward)))
          (should (equal (dsh-emacs--get-input) ""))
          (should (equal (car kill-ring) "draft"))
          (should (equal-including-properties
                   header (buffer-substring (point-min) dsh-emacs--input-marker)))
          (should (eq (char-before (point-max)) ?\n))
          (should (= (point) dsh-emacs--input-marker)))))))

(ert-deftest dsh-emacs-test-input-backward-word-kill-non-chat-unchanged ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (insert "hello world")
    (let ((kill-ring nil)
          (last-command nil))
      (backward-kill-word 1)
      (ert-info ((format "%s" "backward-word-kill-non-chat-unchanged"))
        (should (equal (buffer-string) "hello "))
        (should (equal (car kill-ring) "world"))))))

(ert-deftest dsh-emacs-test-input-delete-guard-repairs-missing-advice ()
  :tags '(dsh-unit)
  (dsh-emacs--composer-delete-guard-install)
  (unwind-protect
      (progn
        (advice-remove 'kill-region #'dsh-emacs--composer-kill-region)
        (dsh-emacs--composer-delete-guard-install)
        (should (advice-member-p #'dsh-emacs--composer-kill-region 'kill-region)))
    (unless (advice-member-p #'dsh-emacs--composer-kill-region 'kill-region)
      (advice-add 'kill-region :around #'dsh-emacs--composer-kill-region))))

(provide 'dsh-test-input)
;;; dsh-test-input.el ends here
