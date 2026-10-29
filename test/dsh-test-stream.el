;;; dsh-test-stream.el --- Stream tests -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "28.1"))

(require 'dsh-test-support)

(ert-deftest dsh-emacs-test-stream-preserves-user-message-spacing ()
  :tags '(dsh-unit)
  (dolist (role '(user assistant))
    (dolist (kind '("text-delta" "reasoning-delta"))
      (with-temp-buffer
        (dsh-emacs-mode)
        (goto-char dsh-emacs--input-marker)
        (insert "KEEP DRAFT")
        (if (eq role 'user)
            (dsh-emacs--render-user-message-optimistic "Question" nil)
          (dsh-emacs-render--insert-chat-message
           "Question" 'dsh-emacs-assistant-body-face nil "preceding" 'assistant))
        (goto-char (point-min))
        (search-forward "Question")
        (let ((end (point))
              (seq 0))
          (dolist (delta '("partial" " more"))
            (dsh-emacs-render-event
             `((type . "assistant/chunk") (seq . ,(cl-incf seq))
               (data . ((turn . 1) (step . 1)
                        (chunk . ((type . ,kind) (index . 0) (text . ,delta)))))))
            (if (equal kind "text-delta")
                (dsh-emacs-render--flush-stream)
              (dsh-emacs-render--flush-thinking))
            (let ((state (if (equal kind "text-delta")
                             dsh-emacs--streaming-assistant
                           dsh-emacs--streaming-thinking)))
              (ert-info ((format "%s after %s: %s" kind role delta))
                (should (equal (buffer-substring-no-properties
                                end (plist-get state :start))
                               (if (eq role 'user) "\n\n" "\n")))
                (should (equal (dsh-emacs--get-input) "KEEP DRAFT"))))))))))

;; Async insertion at the prompt's beginning stretches hl-line over the new
;; transcript until the next command.  Exercise real overlays, not text faces.
(ert-deftest dsh-emacs-test-stream-output-keeps-input-highlight-on-input ()
  :tags '(dsh-unit)
  (dolist (highlight '(local global both none))
    (dolist (background '(nil t))
      (let ((global-hl-line-mode nil)
            (global-hl-line-overlays nil)
            (global-hl-line-sticky-flag nil)
            (hl-line-sticky-flag nil)
            (hl-line-overlay-buffer nil))
        (save-window-excursion
          (with-temp-buffer
            ;; Global hl-line excludes internal buffers on newer Emacs.
            (rename-buffer "*dsh-stream-highlight-test*" t)
            (switch-to-buffer (current-buffer))
            (dsh-emacs-mode)
            (dsh-emacs-modeline-setup)
            (goto-char dsh-emacs--input-marker)
            (insert "KEEP DRAFT")
            (when (memq highlight '(local both))
              (hl-line-mode 1))
            (when (memq highlight '(global both))
              (setq-local global-hl-line-mode t)
              (global-hl-line-highlight))
            (let ((overlays (delq nil (list hl-line-overlay
                                            global-hl-line-overlay)))
                  (window (selected-window))
                  (event '((data . ((turn . 1) (step . 1))))))
              (should (= (length overlays)
                         (pcase highlight ('both 2) ('none 0) (_ 1))))
              (when background
                (set-window-buffer window (get-buffer-create "*scratch*")))
              ;; No post-command hook between these writes: first paint,
              ;; batched reasoning, folding/tool insertion, and text streaming.
              (dolist (phase '(thinking thinking-batch tool text text-batch))
                (pcase phase
                  ('thinking
                   (dsh-emacs-render--start-thinking-stream event "reasoning"))
                  ('thinking-batch
                   (dsh-emacs-render--start-thinking-stream event " more")
                   (dsh-emacs-render--flush-thinking))
                  ('tool
                   (dsh-emacs-events--dispatch-event
                    (current-buffer)
                    (dsh-emacs-test--tool-call-event
                     1 "highlight-tool" "read_file" "{\"path\":\"README.md\"}")))
                  ('text
                   (dsh-emacs-render--start-assistant-stream event "answer"))
                  ('text-batch
                   (dsh-emacs-render--start-assistant-stream event " more")
                   (dsh-emacs-render--flush-stream)))
                (ert-info ((format "%s, background=%s, phase=%s"
                                   highlight background phase))
                  (should (equal (dsh-emacs--get-input) "KEEP DRAFT"))
                  (should (= (point) (+ dsh-emacs--input-marker 10)))
                  (should (equal (delq nil (list hl-line-overlay
                                                 global-hl-line-overlay))
                                 overlays))
                  (dolist (overlay overlays)
                    (should (eq (overlay-get overlay 'window) window))
                    (should (= (overlay-start overlay)
                               (line-beginning-position)))
                    (should (= (overlay-end overlay)
                               (line-beginning-position 2)))))))))))))

;; Streaming tables stay raw until their boundary; open fences only scan
;; newly arrived lines.  Finalization must still produce the complete body.
(ert-deftest dsh-emacs-test-stream-stream-table-defers-reflow ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (let* ((event '((data . ((turn . 1) (step . 1)))))
           (header "| A | B |\n|---|---|\n")
           (row "| alpha | beta |\n")
           (renders 0)
           (render (symbol-function 'dsh-emacs-markdown--render-table)))
      (cl-letf (((symbol-function 'dsh-emacs-markdown--render-table)
                 (lambda (table) (cl-incf renders) (funcall render table))))
        (dsh-emacs-render--start-assistant-stream event header)
        (dotimes (_ 40)
          (dsh-emacs-render--start-assistant-stream event row)
          (dsh-emacs-render--flush-stream))
        (ert-info ((format "%s" "stream-table-defers-reflow"))
          (should (= renders 0))
          (should (string-match-p "| alpha | beta |" (buffer-string))))
        ;; The last timer has already fired: finalization still needs to render.
        (dsh-emacs-render--finish-assistant-stream
         event (concat header (apply #'concat (make-list 40 row))))
        (ert-info ((format "%s" "stream-table-finalizes-once-without-pending-timer"))
          (should (= renders 1))
          (should (string-match-p "alpha" (buffer-string)))
          (should (text-property-not-all (point-min) (point-max)
                                         'dsh-emacs-markdown-table-source nil)))))))

(ert-deftest dsh-emacs-test-stream-stream-open-fence-renders-card-at-opening-line ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (let* ((event '((data . ((turn . 1) (step . 1)))))
           (header "```elisp\n")
           (row "(message \"**literal**\")\n")
           (scanned 0)
           (parses 0)
           (scan (symbol-function 'dsh-emacs-markdown--source-block-ranges)))
      ;; Opening the fence is the one call that renders: it writes the card
      ;; chrome before any body line exists, so the card is already on screen.
      (dsh-emacs-render--start-assistant-stream event header)
      (dsh-emacs-render--flush-stream)
      (ert-info ((format "%s" "stream-open-fence-renders-card-at-opening-line"))
        (should (not (string-match-p "```" (buffer-string))))
        (should (string-match-p "elisp ⧉" (buffer-string))))
      (cl-letf (((symbol-function 'dsh-emacs-markdown--source-block-ranges)
                 (lambda ()
                   (cl-incf parses)
                   (cl-incf scanned (- (point-max) (point-min)))
                   (funcall scan))))
        (dotimes (_ 80)
          (dsh-emacs-render--start-assistant-stream event row)
          (dsh-emacs-render--flush-stream)))
      (ert-info ((format "%s" "stream-open-fence-avoids-repeated-full-scans"))
        (should (= scanned 0))
        (should (string-match-p (regexp-quote row) (buffer-string))))
      (ert-info ((format "%s" "stream-open-fence-skips-empty-markdown-passes"))
        (should (= parses 0)))
      (dsh-emacs-render--start-assistant-stream event "```\n")
      (dsh-emacs-render--flush-stream)
      (ert-info ((format "%s" "stream-closed-fence-renders-with-literal-body"))
        (should (not (string-match-p "```" (buffer-string))))
        (should (string-match-p (regexp-quote "**literal**") (buffer-string)))
        (should (text-property-not-all (point-min) (point-max)
                                       'dsh-emacs-markdown-source-block-body nil)))
      (dsh-emacs-render--finish-assistant-stream
       event (concat header (apply #'concat (make-list 80 row)) "```\n")))))

;; Regression: closing a text block must yield to pending keyboard input.
(ert-deftest dsh-emacs-test-stream-stream-block-close-yields-to-input ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (let* ((dsh-emacs-stream-markdown-limit 8)
           (event '((data . ((turn . 1) (step . 1)))))
           (state (dsh-emacs-render--start-assistant-stream event "**before**\n"))
           (runner (symbol-function 'dsh-emacs-render--run-markdown))
           (attempts 0)
           completed)
      (let ((unread-command-events '(?x)))
        ;; Bound a broken retry loop so the regression fails instead of hanging.
        (catch 'stalled
          (cl-letf (((symbol-function 'dsh-emacs-render--run-markdown)
                     (lambda (&rest args)
                       (if (> (cl-incf attempts) 2)
                           (throw 'stalled nil)
                         (apply runner args)))))
            (dsh-emacs-render--start-thinking-stream event "thinking"))
          (setq completed t))
        (ert-info ((format "%s" "stream-block-close-yields-to-input"))
          (should completed)
          (should (equal unread-command-events '(?x)))))
      (when completed
        (ert-info ((format "%s" "stream-closed-block-keeps-deferred-work"))
          (should (memq state dsh-emacs--markdown-pending)))
        (dsh-emacs-render--run-markdown (current-buffer))
        (let ((text (buffer-substring-no-properties (point-min) (point-max))))
          (ert-info ((format "%s" "stream-closed-block-formats-before-thinking"))
            (should (string-match-p "before\n.*Think\nthinking" text))
            (should (not (string-match-p (regexp-quote "**before**") text))))))
      (dsh-emacs-render--cancel-markdown))))

;; A corrected final body cancels old deferred work and keeps nearby thinking.
(ert-deftest dsh-emacs-test-stream-stream-repair-cancels-committed-job ()
  :tags '(dsh-unit)
  (dolist (finish-early '(nil t))
    (with-temp-buffer
      (dsh-emacs-mode)
      (let* ((dsh-emacs-stream-markdown-limit 8)
             (dsh-emacs-thinking-expand-by-default t)
             (event '((data . ((turn . 1) (step . 1)))))
             (old (dsh-emacs-render--start-assistant-stream event "**wrong**\n")))
        (dsh-emacs-render--start-thinking-stream event "keep thinking")
        (when finish-early (dsh-emacs-render--run-markdown (current-buffer)))
        (dsh-emacs-render--start-assistant-stream event "old tail")
        (dsh-emacs-render--finish-assistant-stream event "**correct**\n")
        (ert-info ((format "%s" "stream-repair-cancels-committed-job"))
          (should (not (memq old dsh-emacs--markdown-pending))))
        (dsh-emacs-render--run-markdown (current-buffer))
        (let ((text (buffer-substring-no-properties (point-min) (point-max))))
          (ert-info ((format "%s" "stream-repair-keeps-thinking-without-old-text"))
            (should (string-match-p "correct" text))
            (should (string-match-p "keep thinking" text))
            (should (not (string-match-p "wrong\\|old tail\\|\\*\\*" text)))))))))

;; Regression: Markdown after a streamed closing fence must still render.
(ert-deftest dsh-emacs-test-stream-stream-fence-tail-matches-complete-markdown ()
  :tags '(dsh-unit)
  (dolist (final '(nil t))
    (with-temp-buffer
      (dsh-emacs-mode)
      (let* ((event '((data . ((turn . 1) (step . 1)))))
             (first "```text\nx\n")
             (tail "```\n**BOLD**\n\n# TITLE\n\n```text\ny\n```\n")
             (source (concat first tail))
             (expected (dsh-emacs-markdown-render source))
             (state (dsh-emacs-render--start-assistant-stream event first))
             (start (copy-marker (plist-get state :start))))
        (dsh-emacs-render--flush-stream)
        (dsh-emacs-render--start-assistant-stream event tail)
        (unless final (dsh-emacs-render--flush-stream))
        (dsh-emacs-render--finish-assistant-stream event source)
        (ert-info ((format "%s" "stream-fence-tail-matches-complete-markdown"))
          (should (equal (substring-no-properties expected)
                         (buffer-substring-no-properties
                          start (+ start (length expected))))))
        (goto-char start)
        (search-forward "BOLD")
        (ert-info ((format "%s" "stream-fence-tail-retains-bold-face"))
          (should (memq 'dsh-emacs-markdown-bold
                        (get-text-property (1- (point)) 'face))))))))

;; A streamed code block is append-only: once its card chrome is written at
;; the opening fence, every later flush adds text at the tail and nothing the
;; user has already seen is rewritten (no line break is ever inserted into
;; shown text).  The renderer's trailing separator sits after the stream body,
;; so the body region is what must stay stable.
(defun dsh-test--stream-body-text ()
  (let ((end (plist-get dsh-emacs--streaming-assistant :end)))
    (buffer-substring-no-properties
     (point-min) (if (markerp end) (marker-position end) (point-max)))))

(ert-deftest dsh-emacs-test-stream-stream-open-fence-body-appends-without-rewriting ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (let* ((event '((data . ((turn . 1) (step . 1)))))
           (row "(message \"hi\")\n")
           previous)
      (dsh-emacs-render--start-assistant-stream event "Before.\n\n```elisp\n")
      (dsh-emacs-render--flush-stream)
      (dsh-emacs-render--start-assistant-stream event row)
      (dsh-emacs-render--flush-stream)
      (setq previous (dsh-test--stream-body-text))
      (dotimes (_ 20)
        (dsh-emacs-render--start-assistant-stream event row)
        (dsh-emacs-render--flush-stream)
        (let ((now (dsh-test--stream-body-text)))
          (ert-info ((format "%s" "stream-open-fence-body-appends-without-rewriting"))
            (should (string-prefix-p previous now)))
          (setq previous now)))
      (dsh-emacs-render--start-assistant-stream event "```\nAfter.\n")
      (dsh-emacs-render--flush-stream)
      ;; Closing consumes the fence line and appends the panel's bottom line;
      ;; everything above the fence line is untouched.
      (ert-info ((format "%s" "stream-close-appends-below-the-body"))
        (should (string-prefix-p previous (dsh-test--stream-body-text)))))))

;; A block whose chrome is written by the deferred (idle) render must hand its
;; open state to the live stream: otherwise the next pass re-reads the body as
;; markdown (`*x*' loses its asterisks) and leaves the closing fence raw.
(ert-deftest dsh-emacs-test-stream-stream-deferred-open-fence-hands-over-the-block ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (let* ((dsh-emacs-stream-markdown-limit 8)
           (event '((data . ((turn . 1) (step . 1)))))
           (text "intro\n```text\n*x*\n| a | b |\n```\n")
           (expected (with-temp-buffer
                       (insert text)
                       (dsh-emacs-markdown-replace-markup
                        :base-face 'dsh-emacs-assistant-body-face)
                       (buffer-substring-no-properties (point-min) (point-max))))
           (state (dsh-emacs-render--start-assistant-stream
                   event "intro\n```text\n*x*\n"))
           body-start)
      (dsh-emacs-render--run-markdown (current-buffer))
      (ert-info ((format "%s" "stream-deferred-open-fence-hands-over-the-block"))
        (should (plist-get (plist-get state :markdown) :open-block)))
      (dsh-emacs-render--start-assistant-stream event "| a | b |\n```\n")
      (dsh-emacs-render--flush-stream)
      (setq body-start (copy-marker (plist-get state :start)))
      (dsh-emacs-render--finish-assistant-stream event text)
      (while dsh-emacs--markdown-pending
        (dsh-emacs-render--run-markdown (current-buffer)))
      (ert-info ((format "%s" "stream-deferred-open-fence-keeps-the-body-raw"))
        (should (equal expected
                       (buffer-substring-no-properties
                        body-start (+ body-start (length expected)))))))))

;; A repaired final body re-renders from scratch: `--reset-markdown-state' has
;; to drop the block it was streaming, or the queued final pass is skipped and
;; the body keeps its raw fences.
(ert-deftest dsh-emacs-test-stream-stream-forced-final-repair-formats-the-body ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (let* ((dsh-emacs-stream-markdown-limit 100)
           (event '((data . ((turn . 1) (step . 1)))))
           (final (concat "```text\n" (make-string 300 ?a) "\n```\n"))
           (state (dsh-emacs-render--start-assistant-stream event "```text\n"))
           body-start)
      (setq body-start (copy-marker (plist-get state :start)))
      (dsh-emacs-render--finish-assistant-stream event final)
      (while dsh-emacs--markdown-pending
        (dsh-emacs-render--run-markdown (current-buffer)))
      (ert-info ((format "%s" "stream-forced-final-repair-formats-the-body"))
        (should (not (string-match-p
                      "```"
                      (buffer-substring-no-properties body-start (point-max)))))))))

;; A closer and the next opener in one flush must not leave the first block
;; looking open: both cards render, with no fence line left raw.
(ert-deftest dsh-emacs-test-stream-stream-closer-closes-before-the-next-opener ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (let* ((event '((data . ((turn . 1) (step . 1)))))
           (text "```a\nx\n```\n```b\ny\n```\n")
           (expected (with-temp-buffer
                       (insert text)
                       (dsh-emacs-markdown-replace-markup
                        :base-face 'dsh-emacs-assistant-body-face)
                       (buffer-substring-no-properties (point-min) (point-max))))
           (state (dsh-emacs-render--start-assistant-stream event "```a\nx\n"))
           body-start)
      (dsh-emacs-render--start-assistant-stream event "```\n```b\ny\n")
      (dsh-emacs-render--flush-stream)
      ;; The closer ends the first block and the remainder opens the next card
      ;; in the same flush: the live block must belong to b, not a.
      (ert-info ((format "%s" "stream-closer-closes-before-the-next-opener"))
        (should (equal "b" (plist-get (plist-get (plist-get state :markdown)
                                                 :open-block)
                                      :lang))))
      (dsh-emacs-render--start-assistant-stream event "```\n")
      (dsh-emacs-render--flush-stream)
      (setq body-start (copy-marker (plist-get state :start)))
      (dsh-emacs-render--finish-assistant-stream event text)
      (ert-info ((format "%s" "stream-closer-and-next-opener-in-one-flush"))
        (should (equal expected
                       (buffer-substring-no-properties
                        body-start (+ body-start (length expected)))))))))

;; An open block never goes back to the idle queue: its flush only styles the
;; characters that just arrived, and deferring it would re-read code as
;; markdown in a temp buffer that cannot see the block.
(ert-deftest dsh-emacs-test-stream-stream-open-fence-never-defers ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (let* ((dsh-emacs-stream-markdown-limit 8)
           (event '((data . ((turn . 1) (step . 1)))))
           (row "(message \"hi\")\n")
           (state (dsh-emacs-render--start-assistant-stream event "```text\n")))
      (dsh-emacs-render--flush-stream)
      (dotimes (_ 30)
        (dsh-emacs-render--start-assistant-stream event row)
        (dsh-emacs-render--flush-stream))
      (ert-info ((format "%s" "stream-open-fence-never-defers"))
        (should (plist-get (plist-get state :markdown) :open-block))
        (should (null (memq state dsh-emacs--markdown-pending))))
      (dsh-emacs-render--finish-assistant-stream
       event (concat "```text\n" (apply #'concat (make-list 30 row)) "```\n")))))

;; Reformatting a partial line must not accumulate the assistant base face.
(ert-deftest dsh-emacs-test-stream-stream-partial-line-keeps-one-assistant-base-face ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (let ((event '((data . ((turn . 1) (step . 1))))))
      (dotimes (_ 20)
        (dsh-emacs-render--start-assistant-stream event "**bold** text ")
        (dsh-emacs-render--flush-stream))
      (let* ((start (plist-get dsh-emacs--streaming-assistant :start))
             (face (get-text-property start 'face)))
        (ert-info ((format "%s" "stream-partial-line-keeps-one-assistant-base-face"))
          (should (equal face '(dsh-emacs-markdown-bold dsh-emacs-assistant-body-face)))
          (should (equal (get-text-property start 'font-lock-face) face))))
      (dsh-emacs-render--flush-stream nil t))))

;; Replacement blocks must mirror the final face, including the base face.
(ert-deftest dsh-emacs-test-stream-stream-case-mirrors-complete-base-face ()
  :tags '(dsh-unit)
  (dolist (case '(("code" "```text\nbody\n```\n" "body")
                  ("table" "| A | B |\n|---|---|\n| alpha | beta |\n" "alpha")))
    (pcase-let ((`(,kind ,text ,needle) case))
      (with-temp-buffer
        (dsh-emacs-mode)
        (dsh-emacs-render--start-assistant-stream
         '((data . ((turn . 1) (step . 1)))) text)
        (dsh-emacs-render--flush-stream nil t)
        (goto-char (point-min))
        (search-forward needle)
        (let* ((pos (- (point) (length needle)))
               (face (get-text-property pos 'face)))
          (ert-info ((format "%s" (format "stream-%s-mirrors-complete-base-face" kind)))
            (should (= (cl-count 'dsh-emacs-assistant-body-face
                                 (if (listp face) face (list face))) 1))
            (should (equal face (get-text-property pos 'font-lock-face)))))))))

;; Long partial lines stay visible without reparsing every subsequent delta.
(ert-deftest dsh-emacs-test-stream-stream-long-partial-line-has-bounded-immediate-work ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (let ((dsh-emacs-stream-markdown-limit 256)
          (event '((data . ((turn . 1) (step . 1)))))
          (formatter (symbol-function 'dsh-emacs-markdown-replace-markup))
          (scanned 0))
      (cl-letf (((symbol-function 'dsh-emacs-markdown-replace-markup)
                 (lambda (&rest args)
                   (cl-incf scanned (- (point-max) (point-min)))
                   (apply formatter args))))
        (dotimes (_ 100)
          (dsh-emacs-render--start-assistant-stream event "**bold** text ")
          (dsh-emacs-render--flush-stream)))
      (ert-info ((format "%s" "stream-long-partial-line-has-bounded-immediate-work"))
        (should (< scanned 8000))
        (should (string-match-p (regexp-quote "**bold** text ") (buffer-string))))
      (let ((dsh-emacs-stream-markdown-limit nil))
        (dsh-emacs-render--flush-stream nil t))
      (ert-info ((format "%s" "stream-long-partial-line-final-styling-is-complete"))
        (should (equal (buffer-substring-no-properties
                        (plist-get dsh-emacs--streaming-assistant :start)
                        (plist-get dsh-emacs--streaming-assistant :end))
                       (apply #'concat (make-list 100 "bold text "))))))))

;; Large final blocks stay visible, then receive complete styling at idle.
(ert-deftest dsh-emacs-test-stream-stream-large-block-is-deferred-case ()
  :tags '(dsh-unit)
  (dolist (text '("```elisp\n(message \"hello\")\n```\n"
                  "| A | B |\n|---|---|\n| **alpha** | beta |\n"))
    (with-temp-buffer
      (dsh-emacs-mode)
      (let* ((dsh-emacs-stream-markdown-limit 8)
             (event '((data . ((turn . 1) (step . 1)))))
             (expected (with-temp-buffer
                         (insert text)
                         (dsh-emacs-markdown-replace-markup
                          :base-face 'dsh-emacs-assistant-body-face)
                         (buffer-string)))
             state body-start)
        (setq state (dsh-emacs-render--start-assistant-stream event text))
        (setq body-start (marker-position (plist-get state :start)))
        (dsh-emacs-render--finish-assistant-stream event text)
        (ert-info ((format "%s" (format "stream-large-block-is-deferred-%s" (substring text 0 3))))
          (should (memq state dsh-emacs--markdown-pending))
          (should (and (marker-buffer (plist-get state :start))
                       (equal (buffer-substring-no-properties
                               (plist-get state :start) (plist-get state :end)) text)))
          (should (null dsh-emacs--streaming-assistant)))
        (when (fboundp 'dsh-emacs-render--run-markdown)
          (dsh-emacs-render--run-markdown (current-buffer))
          (ert-info ((format "%s" "stream-deferred-final-matches-synchronous-formatting"))
            (should (equal (substring-no-properties expected)
                           (buffer-substring-no-properties
                            body-start (+ body-start (length expected)))))
            (should (cl-loop for i below (length expected)
                             always (and (equal (get-text-property i 'face expected)
                                                (get-text-property (+ body-start i) 'face))
                                         (equal (get-text-property i 'font-lock-face expected)
                                                (get-text-property (+ body-start i)
                                                                   'font-lock-face)))))
            (should (null dsh-emacs--markdown-pending))
            (should (null dsh-emacs--markdown-timer))
            (should (null (marker-buffer (plist-get state :start))))
            (should (null (marker-buffer (plist-get state :end))))))))))

;; A large final-only/history message uses the same idle formatting path.
(ert-deftest dsh-emacs-test-stream-assistant-final-only-message-defers-large-markdown ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (let ((dsh-emacs-stream-markdown-limit 8)
          (text "```text\nfrom history\n```"))
      (dsh-emacs-render-assistant-message
       `((seq . 7)
         (data . ((turn . 1) (step . 1)
                  (message . ((content . [((type . "text") (text . ,text))])))))))
      (ert-info ((format "%s" "assistant-final-only-message-defers-large-markdown"))
        (should (= (length dsh-emacs--markdown-pending) 1))
        (should (string-match-p "```text" (buffer-string))))
      (when dsh-emacs--markdown-pending
        (let* ((state (car dsh-emacs--markdown-pending))
               (start (marker-position (plist-get state :start)))
               (event-id (plist-get state :event-id))
               (expected (dsh-emacs-markdown-render text)))
          (dsh-emacs-render--run-markdown (current-buffer))
          (ert-info ((format "%s" "assistant-final-only-idle-result-retains-event-identity"))
            (should (equal (buffer-substring-no-properties start (+ start (length expected)))
                           (substring-no-properties expected)))
            (should (equal (get-text-property start 'dsh-emacs-event-block) event-id))
            (should (null dsh-emacs--markdown-pending))))))))

;; Compatibility table probes must not invalidate the queued reply's snapshot.
(ert-deftest dsh-emacs-test-stream-idle-table-completes-on-emacs-case ()
  :tags '(dsh-unit)
  (dolist (version '(27 30))
    (save-window-excursion
      (with-temp-buffer
        (dsh-emacs-mode)
        (set-window-buffer (selected-window) (current-buffer))
        (let ((dsh-emacs-stream-markdown-limit 8)
              (emacs-major-version version)
              (event '((data . ((turn . 1) (step . 1)))))
              (text "| A | B |\n|---|---|\n| alpha | beta |\n")
              (measurements 0))
          (dsh-emacs-render--start-assistant-stream event text)
          (dsh-emacs-render--finish-assistant-stream event text)
          (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                    ((symbol-function 'window-text-pixel-size)
                     (lambda (_window from to &rest _)
                       (cl-incf measurements)
                       (cons (* 10 (- to from)) 16)))
                    ((symbol-function 'buffer-text-pixel-size)
                     (lambda (buffer &rest _)
                       (cl-incf measurements)
                       (cons (* 10 (buffer-size buffer)) 16))))
            (dsh-emacs-render--run-markdown (current-buffer)))
          (ert-info ((format "%s" (format "idle-table-completes-on-emacs-%s" version)))
            (should (> measurements 0))
            (should (text-property-not-all (point-min) (point-max)
                                           'dsh-emacs-markdown-table-source nil))
            (should (null dsh-emacs--markdown-pending))
            (should (null dsh-emacs--markdown-timer))))))))

;; Timer attempts wait for actual idleness, without repeatedly firing at an
;; expired idle deadline or preventing the command loop from consuming input.
(ert-deftest dsh-emacs-test-stream-stream-markdown-timer-yields-while-the-user-is-active ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (let* ((dsh-emacs-stream-markdown-limit 8)
           (state (dsh-emacs-render--start-assistant-stream
                   '((data . ((turn . 1) (step . 1))))
                   "```text\nqueued text\n```\n"))
           (before (buffer-string)))
      (cl-letf (((symbol-function 'current-idle-time) (lambda () nil)))
        (dsh-emacs-render--run-markdown (current-buffer) t))
      (ert-info ((format "%s" "stream-markdown-timer-yields-while-the-user-is-active"))
        (should (equal-including-properties before (buffer-string)))
        (should (memq state dsh-emacs--markdown-pending))
        (should (memq dsh-emacs--markdown-timer timer-list))
        (should (not (memq dsh-emacs--markdown-timer timer-idle-list))))
      (cl-letf (((symbol-function 'current-idle-time) (lambda () '(0 1 0 0))))
        (dsh-emacs-render--run-markdown (current-buffer) t))
      (ert-info ((format "%s" "stream-markdown-timer-completes-when-idle"))
        (should (null dsh-emacs--markdown-pending))
        (should (string-match-p "text ⧉" (buffer-string)))))))

;; Input can discard a partly prepared result without touching the transcript.
(ert-deftest dsh-emacs-test-stream-stream-interrupted-preparation-never-publishes-partial-text ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (let* ((dsh-emacs-stream-markdown-limit 8)
           (event '((data . ((turn . 1) (step . 1)))))
           (text "```elisp\n(message \"hello\")\n```\n")
           (state (dsh-emacs-render--start-assistant-stream event text))
           (before (buffer-string))
           (tick (buffer-chars-modified-tick)))
      (dsh-emacs-render--finish-assistant-stream event text)
      (cl-letf (((symbol-function 'dsh-emacs-markdown-replace-markup)
                 (lambda (&rest _)
                   (insert "unfinished preparation")
                   (throw throw-on-input t))))
        (dsh-emacs-render--run-markdown (current-buffer)))
      (ert-info ((format "%s" "stream-interrupted-preparation-never-publishes-partial-text"))
        (should (equal-including-properties before (buffer-string)))
        (should (= tick (buffer-chars-modified-tick)))
        (should (memq state dsh-emacs--markdown-pending))
        (should (timerp dsh-emacs--markdown-timer)))
      (dsh-emacs-render--run-markdown (current-buffer))
      (ert-info ((format "%s" "stream-interrupted-preparation-retries-to-completion"))
        (should (null dsh-emacs--markdown-pending))
        (should (string-match-p "elisp ⧉" (buffer-string)))
        (should (not (string-match-p "unfinished preparation" (buffer-string))))))))

;; Regression: streamed replies protect their trailing separators as well.
(ert-deftest dsh-emacs-test-stream-stream-body-and-separators-are-read-only ()
  :tags '(dsh-unit)
  (dolist (limit '(8 100000))
    (dolist (chunks '(("hello" " world\nsecond line")
                      ("```elisp\n(message" " \"hello\")\n```\n**tail**")
                      ("| A | B |\n|---|---|\n" "| alpha | beta |\n")))
      (with-temp-buffer
        (dsh-emacs-mode)
        (goto-char (dsh-emacs--input-end))
        (insert "draft")
        (let* ((dsh-emacs-stream-markdown-limit limit)
               (event '((data . ((turn . 1) (step . 1)))))
               (state (dsh-emacs-render--start-assistant-stream
                       event (car chunks)))
               (start (copy-marker (plist-get state :start)))
               (end (copy-marker (+ 2 (plist-get state :end)))))
          (dolist (phase '(first append final idle))
            (pcase phase
              ('append
               (dsh-emacs-render--start-assistant-stream event (cadr chunks))
               (dsh-emacs-render--flush-stream))
              ('final
               (dsh-emacs-render--finish-assistant-stream
                event (apply #'concat chunks)))
              ('idle
               (dsh-emacs-render--run-markdown (current-buffer))))
            (let ((before (buffer-substring-no-properties start end)))
              (ert-info ((format "%s" "stream-body-and-separators-are-read-only"))
                (should (null (text-property-not-all start end 'read-only t))))
              (dolist (pos (list (- end 2) (1- end)))
                (goto-char pos)
                (ert-info ((format "%s" "stream-separator-rejects-insertion"))
                  (should (condition-case nil
                              (progn (insert "\n") nil)
                            (text-read-only t))))
                (ert-info ((format "%s" "stream-separator-rejects-deletion"))
                  (should (condition-case nil
                              (progn (delete-char 1) nil)
                            (text-read-only t)))))
              (ert-info ((format "%s" "stream-separators-survive-edit-attempts"))
                (should (equal before (buffer-substring-no-properties start end)))
                (should (equal "draft" (dsh-emacs--get-input))))))
          (goto-char (dsh-emacs--input-end))
          (insert " more")
          (ert-info ((format "%s" "stream-separator-protection-keeps-input-editable"))
            (should (equal "draft more" (dsh-emacs--get-input)))))))))

;; A corrected final reply replaces the source of queued work.
(ert-deftest dsh-emacs-test-stream-stream-deferred-correction-is-protected-immediately ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (let* ((dsh-emacs-stream-markdown-limit 8)
           (event '((data . ((turn . 1) (step . 1)))))
           (state (dsh-emacs-render--start-assistant-stream
                   event "```text\nobsolete\n```\n")))
      (dsh-emacs-render--finish-assistant-stream
       event "```text\ncorrected\n```\n")
      (ert-info ((format "%s" "stream-deferred-correction-is-protected-immediately"))
        (should (get-text-property (plist-get state :start) 'read-only))
        (should (equal (get-text-property (plist-get state :start) 'dsh-emacs-event-block)
                       (plist-get state :event-id))))
      (dsh-emacs-render--run-markdown (current-buffer))
      (ert-info ((format "%s" "stream-deferred-correction-cannot-publish-obsolete-text"))
        (should (string-match-p "corrected" (buffer-string)))
        (should (not (string-match-p "obsolete" (buffer-string))))
        (should (null dsh-emacs--markdown-pending))))))

;; Completing an earlier job keeps later replies and the draft intact.
(ert-deftest dsh-emacs-test-stream-stream-queued-reply-does-not-expand-into-the-next-message ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (let ((dsh-emacs-stream-markdown-limit 8)
          (inhibit-read-only t))
      (goto-char (point-max))
      (insert "draft")
      (dolist (step '(1 2))
        (let ((event `((data . ((turn . 1) (step . ,step)))))
              (text (format "```text\nreply %s\n```\n" step)))
          (dsh-emacs-render--start-assistant-stream event text)
          (dsh-emacs-render--finish-assistant-stream event text)))
      (let ((first (car dsh-emacs--markdown-pending)))
        (ert-info ((format "%s" "stream-queued-reply-does-not-expand-into-the-next-message"))
          (should (equal (buffer-substring-no-properties
                          (plist-get first :start) (plist-get first :end))
                         "```text\nreply 1\n```\n"))))
      (dsh-emacs-render--run-markdown (current-buffer))
      (ert-info ((format "%s" "stream-idle-callback-finishes-one-reply-at-a-time"))
        (should (= (length dsh-emacs--markdown-pending) 1)))
      (let ((second (car dsh-emacs--markdown-pending)))
        (ert-info ((format "%s" "stream-idle-publish-preserves-the-next-job-boundaries"))
          (should (equal (buffer-substring-no-properties
                          (plist-get second :start) (plist-get second :end))
                         "```text\nreply 2\n```\n"))))
      (dsh-emacs-render--run-markdown (current-buffer))
      (ert-info ((format "%s" "stream-idle-results-preserve-order-and-draft"))
        (should (< (string-match "reply 1" (buffer-string))
                   (string-match "reply 2" (buffer-string))))
        (should (equal (dsh-emacs--get-input) "draft"))
        (should (null dsh-emacs--markdown-pending))))))

;; A completed idle job retains the partial-line frontier for later chunks.
(ert-deftest dsh-emacs-test-stream-stream-resumes-markdown-after-a-midstream-idle-result ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (let* ((dsh-emacs-stream-markdown-limit 16)
           (event '((data . ((turn . 1) (step . 1)))))
           (first "```text\nfirst block\n```\n\nafter **part")
           (last "ial**\nlast line")
           (state (dsh-emacs-render--start-assistant-stream event first))
           (start (marker-position (plist-get state :start)))
           (expected (dsh-emacs-markdown-convert (concat first last))))
      (dsh-emacs-render--run-markdown (current-buffer))
      (dsh-emacs-render--start-assistant-stream event last)
      (dsh-emacs-render--finish-assistant-stream event (concat first last))
      (when dsh-emacs--markdown-pending
        (dsh-emacs-render--run-markdown (current-buffer)))
      (ert-info ((format "%s" "stream-resumes-markdown-after-a-midstream-idle-result"))
        (should (equal (substring-no-properties expected)
                       (buffer-substring-no-properties start (+ start (length expected)))))
        (should (null dsh-emacs--markdown-pending))))))

;; Internal preparation errors surface, leaving the raw reply intact.
(ert-deftest dsh-emacs-test-stream-stream-idle-errors-preserve-raw-text-and-report-failure ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (let* ((dsh-emacs-stream-markdown-limit 8)
           (event '((data . ((turn . 1) (step . 1)))))
           (text "```text\nraw reply\n```\n")
           (state (dsh-emacs-render--start-assistant-stream event text))
           (before (buffer-string)) reported)
      (dsh-emacs-render--finish-assistant-stream event text)
      (cl-letf (((symbol-function 'dsh-emacs-markdown-replace-markup)
                 (lambda (&rest _) (error "Broken formatter")))
                ((symbol-function 'message)
                 (lambda (format &rest args)
                   (setq reported (apply #'format format args)))))
        (dsh-emacs-render--run-markdown (current-buffer)))
      (ert-info ((format "%s" "stream-idle-errors-preserve-raw-text-and-report-failure"))
        (should (equal-including-properties before (buffer-string)))
        (should (string-match-p "Broken formatter" reported))
        (should (null dsh-emacs--markdown-pending))
        (should (null (marker-buffer (plist-get state :start))))))))

;; Publishing markup preserves positions inside unchanged code content.
(ert-deftest dsh-emacs-test-stream-stream-idle-publish-keeps-positions-in-unchanged-code ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (let* ((dsh-emacs-stream-markdown-limit 8)
           (event '((data . ((turn . 1) (step . 1)))))
           (text "```text\nalpha beta gamma\n```\n")
           marker)
      (dsh-emacs-render--start-assistant-stream event text)
      (save-excursion
        (goto-char (point-min))
        (search-forward "beta")
        (setq marker (copy-marker (- (point) 4))))
      (dsh-emacs-render--finish-assistant-stream event text)
      (dsh-emacs-render--run-markdown (current-buffer))
      (ert-info ((format "%s" "stream-idle-publish-keeps-positions-in-unchanged-code"))
        (should (and (<= (+ marker 4) (point-max))
                     (equal (buffer-substring-no-properties marker (+ marker 4)) "beta"))))
      (ert-info ((format "%s" "stream-idle-publish-does-not-poison-coding-buffers"))
        (should (equal (decode-coding-string (unibyte-string #xE1) 'iso-8859-1) "á")))
      (set-marker marker nil))))

;; Teardown releases pending jobs and their timers instead of publishing later.
(ert-deftest dsh-emacs-test-stream-stream-idle-work-cancels-on-case ()
  :tags '(dsh-unit)
  (dolist (boundary '(reset kill mode))
    (let ((buffer (generate-new-buffer " *dsh-markdown-lifecycle*"))
          state timer stream-timer caught)
      (unwind-protect
          (with-current-buffer buffer
            (dsh-emacs-mode)
            (let ((dsh-emacs-stream-markdown-limit 8))
              (setq state (dsh-emacs-render--start-assistant-stream
                           '((data . ((turn . 1) (step . 1))))
                           "```text\nqueued\n```\n")
                    timer dsh-emacs--markdown-timer)
              (dsh-emacs-render--start-assistant-stream
               '((data . ((turn . 1) (step . 1)))) "pending delta")
              (setq stream-timer (plist-get state :timer)))
            (condition-case err
                (pcase boundary
                  ('reset (dsh-emacs-render--reset-tool-tracking))
                  ('kill (kill-buffer buffer))
                  ('mode (fundamental-mode)))
              (error (setq caught err)))
            (ert-info ((format "%s" (format "stream-idle-work-cancels-on-%s" boundary)))
              (should (null caught))
              (should (timerp stream-timer))
              (should (not (memq stream-timer timer-list)))
              (should (null (plist-get state :pending)))
              (should (timerp timer))
              (should (not (memq timer timer-list)))
              (should (null (marker-buffer (plist-get state :start))))
              (should (null (marker-buffer (plist-get state :end))))))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (setq dsh-emacs--streaming-assistant nil))
          (kill-buffer buffer))))))

;; Emphasis scanning can skip the prefix preceding its first delimiter.
(ert-deftest dsh-emacs-test-stream-stream-emphasis-skips-delimiter-free-prefix ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (let ((event '((data . ((turn . 1) (step . 1)))))
          (prefix (concat (make-string 3000 ?a) " "))
          (bold (symbol-function 'dsh-emacs-markdown--replace-bolds))
          (scanned 0))
      (dsh-emacs-render--start-assistant-stream event prefix)
      (cl-letf (((symbol-function 'dsh-emacs-markdown--replace-bolds)
                 (lambda (&rest args)
                   (cl-incf scanned (- (point-max) (point-min)))
                   (apply bold args))))
        (dotimes (_ 20)
          (dsh-emacs-render--start-assistant-stream event "**bold** text ")
          (dsh-emacs-render--flush-stream)))
      (ert-info ((format "%s" "stream-emphasis-skips-delimiter-free-prefix"))
        (should (< scanned 1000))
        (should (equal (buffer-substring-no-properties
                        (plist-get dsh-emacs--streaming-assistant :start)
                        (plist-get dsh-emacs--streaming-assistant :end))
                       (concat prefix (apply #'concat (make-list 20 "bold text "))))))
      (dsh-emacs-render--flush-stream nil t))))

;; Chunk boundaries do not change final Markdown text or its visual faces.
(ert-deftest dsh-emacs-test-stream-stream-markdown-parity-case-case ()
  :tags '(dsh-unit)
  (cl-loop for (tag source) in
           '(("mixed" "**before**\n| A | B |\n|---|---|\n| `a|b` | **中** |\n\nafter\n")
             ("table-tail" "| A | B |\n|---|---|\n|x|y|")
             ("fence" "```elisp\n(message \"**literal**\")\n```")
             ("nested-fence" "````text\n```\nbody\n```\n````\n")
             ("inline-and-table" "`inline`\n|a|b|\n|c|d|\n\n```text\nraw\n```\n"))
           do
           (let ((expected (with-temp-buffer
                             (insert source)
                             (dsh-emacs-markdown-replace-markup)
                             (buffer-string))))
             (dolist (size '(1 2 7 31))
               (with-temp-buffer
                 (let ((state (list :scan nil :pending nil :kind nil :watermark nil))
                       (pos 0))
                   (while (< pos (length source))
                     (goto-char (point-max))
                     (insert (substring source pos (min (+ pos size) (length source))))
                     (setq pos (+ pos size))
                     (dsh-emacs-markdown-replace-markup :stream-state state))
                   (dsh-emacs-markdown-replace-markup :stream-state state :final t)
                   (let ((actual (buffer-string)))
                     (ert-info ((format "%s" (format "stream-markdown-parity-%s-%s" tag size)))
                       (should (equal (substring-no-properties actual)
                                      (substring-no-properties expected)))
                       (should (cl-loop for i below (min (length actual) (length expected))
                                        always (equal (get-text-property i 'face actual)
                                                      (get-text-property i 'face expected))))
                       (should (null (plist-get state :scan)))
                       (should (null (plist-get state :pending)))
                       (should (null (plist-get state :watermark)))))))))))

(ert-deftest dsh-emacs-test-stream-bare-image-waits-for-line-boundary ()
  :tags '(dsh-unit)
  (let ((file (make-temp-file "dsh-stream-`draft`-~~image~~-" nil ".png")))
    (unwind-protect
        (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                  ((symbol-function 'image-supported-file-p) (lambda (_) t))
                  ((symbol-function 'create-image)
                   (lambda (path &rest _) (list 'image :file path)))
                  ((symbol-function 'image-flush) #'ignore))
          (dolist (suffix '(".more\n" "\n" ""))
            (with-temp-buffer
              (dsh-emacs-mode)
              (let* ((event '((data . ((turn . 1) (step . 1)))))
                     (state (dsh-emacs-render--start-assistant-stream event file))
                     (start (plist-get state :start)))
                (ert-info ((format "suffix=%S" suffix))
                  (should-not (get-text-property start 'display))
                  (should-not (get-text-property start 'keymap))
                  (dsh-emacs-render--start-assistant-stream event suffix)
                  (dsh-emacs-render--flush-stream nil t)
                  (should (equal (buffer-substring-no-properties
                                  start (plist-get state :end))
                                 (concat file suffix)))
                  (if (string-prefix-p ".more" suffix)
                      (progn
                        (should-not (get-text-property start 'display))
                        (should-not (get-text-property start 'keymap)))
                    (should (equal (get-text-property start 'display)
                                   (list 'image :file file)))
                    (should (keymapp (get-text-property start 'keymap)))))))))
      (delete-file file))))

;; Teardown finalizes deferred markup even after the formatting timer fired.
(ert-deftest dsh-emacs-test-stream-stream-table-finalizes-on-case ()
  :tags '(dsh-unit)
  (dolist (boundary '(turn-end disconnect reset switch))
    (with-temp-buffer
      (let ((event '((data . ((turn . 1) (step . 1)))))
            (table "|a|b|\n|c|d|\n"))
        (dsh-emacs-render--start-assistant-stream event table)
        (dsh-emacs-render--flush-stream)
        (pcase boundary
          ('turn-end (dsh-emacs-render-turn-end '((data . nil))))
          ('disconnect (dsh-emacs-events-disconnect))
          ('reset (dsh-emacs-render--reset-tool-tracking))
          ('switch (dsh-emacs-render--start-assistant-stream
                    '((data . ((turn . 2) (step . 1)))) "next")))
        (ert-info ((format "%s" (format "stream-table-finalizes-on-%s" boundary)))
          (should (text-property-not-all (point-min) (point-max)
                                         'dsh-emacs-markdown-table-source nil)))
        (dsh-emacs-render--flush-stream nil t)))))

;; --- Test 21: assistant streaming incremental rendering ---
(ert-deftest dsh-emacs-test-stream-assistant-stream-keeps-incomplete-markup ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-modeline-setup)
    (let ((chunk-1 (json-read-from-string
                    "{\"type\":\"assistant/chunk\",\"seq\":1,\"data\":{\"turn\":1,\"step\":1,\"chunk\":{\"type\":\"text-delta\",\"index\":1,\"text\":\"hello **bold\"}}}"))
          (chunk-2 (json-read-from-string
                    "{\"type\":\"assistant/chunk\",\"seq\":2,\"data\":{\"turn\":1,\"step\":1,\"chunk\":{\"type\":\"text-delta\",\"index\":1,\"text\":\" text**\"}}}"))
          (final (json-read-from-string
                  "{\"type\":\"assistant/message\",\"seq\":3,\"data\":{\"turn\":1,\"step\":1,\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"hello **bold text**\"}]}}}")))
      (dsh-emacs-render-event chunk-1)
      (let ((partial (buffer-substring-no-properties (point-min) (point-max))))
        (ert-info ((format "%s" "assistant-stream-keeps-incomplete-markup"))
          (should (string-match-p "hello \\*\\*bold" partial))))
      (dsh-emacs-render-event chunk-2)
      (dsh-emacs-render--flush-stream)
      (let* ((text (buffer-string))
             (bold-pos (string-match "bold" text))
             (face (and bold-pos (get-text-property bold-pos 'face text))))
        (ert-info ((format "%s" "assistant-stream-renders-completed-markup"))
          (should (and (not (string-match-p "\\*\\*" (substring-no-properties text)))
                       (member 'dsh-emacs-markdown-bold
                               (if (listp face) face (list face)))))))
      (dsh-emacs-render-event final)
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (ert-info ((format "%s" "assistant-stream-final-event-does-not-duplicate"))
          (should (and (null dsh-emacs--streaming-assistant)
                       (= (cl-count ?b text)
                          1))))))))

;; --- Test 21b: thinking / reasoning stream rendering ---
;; Regression: live Think text is read-only before its final fragment exists.
(ert-deftest dsh-emacs-test-stream-thinking-live-header-body-and-separator-are-read-only ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (goto-char (dsh-emacs--input-end))
    (insert "draft")
    (let ((event '((data . ((turn . 1) (step . 1))))))
      (dolist (chunk '("first" " second" "\nthird\n"))
        (let ((state (dsh-emacs-render--start-thinking-stream event chunk)))
          (dsh-emacs-render--flush-thinking)
          (let* ((start (marker-position (plist-get state :start)))
                 (end (marker-position (plist-get state :end)))
                 (body (save-excursion (goto-char start)
                                       (line-beginning-position 2)))
                 (before (buffer-substring-no-properties start (1+ end))))
            (ert-info ((format "%s" "thinking-live-header-body-and-separator-are-read-only"))
              (should (null (text-property-not-all start (1+ end) 'read-only t))))
            (dolist (pos (list start body (1- end) end))
              (goto-char pos)
              (ert-info ((format "%s" "thinking-live-block-rejects-insertion"))
                (should (condition-case nil
                            (progn (insert "\n") nil)
                          (text-read-only t))))
              (ert-info ((format "%s" "thinking-live-block-rejects-deletion"))
                (should (condition-case nil
                            (progn (delete-char 1) nil)
                          (text-read-only t)))))
            (ert-info ((format "%s" "thinking-live-block-survives-edit-attempts"))
              (should (equal before (buffer-substring-no-properties start (1+ end))))
              (should (equal "draft" (dsh-emacs--get-input)))))))
      (goto-char (dsh-emacs--input-end))
      (insert " more")
      (ert-info ((format "%s" "thinking-live-protection-keeps-input-editable"))
        (should (equal "draft more" (dsh-emacs--get-input)))))))

(ert-deftest dsh-emacs-test-stream-thinking-burst-defers-buffer-edits ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (let ((icons 0)
          (event '((data . ((turn . 1) (step . 1))))))
      (cl-letf (((symbol-function 'dsh-emacs-render--think-icon)
                 (lambda () (cl-incf icons) "✶")))
        (dotimes (_ 100)
          (dsh-emacs-render--start-thinking-stream event "x")))
      (ert-info ((format "%s" "thinking-burst-defers-buffer-edits"))
        (should (equal (buffer-string) "✶ Think\nx\n"))
        (should (= (length (plist-get dsh-emacs--streaming-thinking :chunks)) 99)))
      (let ((writes 0))
        (add-hook 'after-change-functions (lambda (&rest _) (cl-incf writes)) nil t)
        (dsh-emacs-render--flush-thinking)
        (ert-info ((format "%s" "thinking-burst-flushes-one-edit"))
          (should (= writes 1))
          (should (null (plist-get dsh-emacs--streaming-thinking :timer)))))
      (ert-info ((format "%s" "thinking-stream-builds-header-once"))
        (should (= icons 1))
        (should (equal (buffer-string) (concat "✶ Think\n" (make-string 100 ?x) "\n")))))))

(ert-deftest dsh-emacs-test-stream-follow-keeps-unchanged-window-start ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (insert "body\ninput")
      (goto-char (point-max))
      (set-window-start (selected-window) 1)
      (let ((writes 0))
        (cl-letf (((symbol-function 'dsh-emacs-render--input-anchor-pos)
                   (lambda () 6))
                  ((symbol-function 'set-window-start)
                   (lambda (&rest _) (cl-incf writes))))
          (dotimes (_ 100) (dsh-emacs-render--follow-stream)))
        (ert-info ((format "%s" "follow-keeps-unchanged-window-start"))
          (should (= writes 0)))))))

(ert-deftest dsh-emacs-test-stream-thinking-switch-flushes-old-step ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (let ((event '((data . ((turn . 1) (step . 1))))))
      (dsh-emacs-render--start-thinking-stream event "first")
      (dsh-emacs-render--start-thinking-stream event " queued")
      (dsh-emacs-render--start-thinking-stream
       '((data . ((turn . 1) (step . 2)))) "second")
      (ert-info ((format "%s" "thinking-switch-flushes-old-step"))
        (should (string-match-p "first queued" (buffer-string))))
      (dsh-emacs-render--start-thinking-stream
       '((data . ((turn . 1) (step . 2)))) " tail")
      (dsh-emacs-render-event '((type . "unknown-boundary")))
      (ert-info ((format "%s" "thinking-event-boundary-flushes"))
        (should (string-match-p "second tail" (buffer-string)))
        (should (null (plist-get dsh-emacs--streaming-thinking :timer))))
      (dsh-emacs-render--start-thinking-stream
       '((data . ((turn . 1) (step . 2)))) " disconnect")
      (dsh-emacs-render--flush-stream)
      (ert-info ((format "%s" "thinking-teardown-flushes"))
        (should (string-match-p "second tail disconnect" (buffer-string)))
        (should (null (plist-get dsh-emacs--streaming-thinking :timer)))))))

(ert-deftest dsh-emacs-test-stream-thinking-show-reasoning-defaults-on ()
  :tags '(dsh-unit)
  (ert-info ((format "%s" "thinking-show-reasoning-defaults-on"))
    (should dsh-emacs-show-reasoning)))

(ert-deftest dsh-emacs-test-stream-thinking-stream-renders-live-block ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-modeline-setup)
    (dsh-emacs-render-event
     (json-read-from-string
      "{\"type\":\"assistant/chunk\",\"seq\":1,\"data\":{\"turn\":1,\"step\":1,\"chunk\":{\"type\":\"block-start\",\"index\":0,\"blockType\":\"reasoning\"}}}"))
    (dsh-emacs-render-event
     (json-read-from-string
      "{\"type\":\"assistant/chunk\",\"seq\":2,\"data\":{\"turn\":1,\"step\":1,\"chunk\":{\"type\":\"reasoning-delta\",\"index\":0,\"text\":\"think step one\"}}}"))
    (dsh-emacs-render-event
     (json-read-from-string
      "{\"type\":\"assistant/chunk\",\"seq\":3,\"data\":{\"turn\":1,\"step\":1,\"chunk\":{\"type\":\"reasoning-delta\",\"index\":0,\"text\":\" then two\"}}}"))
    (dsh-emacs-render--flush-thinking)
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      (ert-info ((format "%s" "thinking-stream-renders-live-block"))
        (should (and (string-match-p "✶ Think" text)
                     (string-match-p "think step one then two" text)))))))

(ert-deftest dsh-emacs-test-stream-thinking-final-replaces-stream-single-block ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-modeline-setup)
    (dsh-emacs-render-event
     (json-read-from-string
      "{\"type\":\"assistant/chunk\",\"seq\":1,\"data\":{\"turn\":1,\"step\":1,\"chunk\":{\"type\":\"reasoning-delta\",\"index\":0,\"text\":\"step\"}}}"))
    (dsh-emacs-render-event
     (json-read-from-string
      "{\"type\":\"assistant/message\",\"seq\":2,\"data\":{\"turn\":1,\"step\":1,\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"reasoning\",\"text\":\"final thinking\"},{\"type\":\"text\",\"text\":\"reply body\"}]}}}"))
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      (ert-info ((format "%s" "thinking-final-replaces-stream-single-block"))
        (should (and (string-match-p "✶ Think" text)
                     (string-match-p "reply body" text)
                     (null dsh-emacs--streaming-thinking)
                     (= (cl-count ?✶ text) 1)))))))

;; Reasoning first supplied by the final message still precedes its body.
(ert-deftest dsh-emacs-test-stream-thinking-history-renders-final-block-before-text ()
  :tags '(dsh-unit)
  (dolist (stream '(nil t))
    (with-temp-buffer
      (dsh-emacs-mode)
      (when stream
        (dsh-emacs-render--start-assistant-stream
         '((data . ((turn . 1) (step . 1)))) "history body"))
      (dsh-emacs-render-event
       '((type . "assistant/message") (seq . 1)
         (data . ((turn . 1) (step . 1)
                  (message . ((role . "assistant")
                              (content . [((type . "reasoning") (text . "history think"))
                                          ((type . "text") (text . "history body"))])))))))
      (let ((text (buffer-string)))
        (ert-info ((format "%s" "thinking-history-renders-final-block-before-text"))
          (should (and (string-match "Think" text) (string-match "history body" text)
                       (< (string-match "Think" text) (string-match "history body" text))))
          (should (null dsh-emacs--streaming-thinking)))))))

(ert-deftest dsh-emacs-test-stream-thinking-disabled-hides-block ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-modeline-setup)
    (let ((dsh-emacs-show-reasoning nil))
      (dsh-emacs-render-event
       (json-read-from-string
        "{\"type\":\"assistant/chunk\",\"seq\":1,\"data\":{\"turn\":1,\"step\":1,\"chunk\":{\"type\":\"reasoning-delta\",\"index\":0,\"text\":\"should be hidden\"}}}"))
      (dsh-emacs-render-event
       (json-read-from-string
        "{\"type\":\"assistant/message\",\"seq\":2,\"data\":{\"turn\":1,\"step\":1,\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"reasoning\",\"text\":\"hidden\"},{\"type\":\"text\",\"text\":\"shown\"}]}}}"))
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (ert-info ((format "%s" "thinking-disabled-hides-block"))
          (should (and (null dsh-emacs--streaming-thinking)
                       (not (string-match-p "✶ Think" text))
                       (string-match-p "shown" text))))))))

;; Providers can defer all block-end chunks until after the answer's deltas.
;; Closing an already displayed block must not append it a second time.
;; With no deltas, block-end still supplies the content exactly once.
(ert-deftest dsh-emacs-test-stream-block-end-case-keeps-case-once-in-order ()
  :tags '(dsh-unit)
  (dolist (deltas '(t nil))
    (with-temp-buffer
      (dsh-emacs-mode)
      (let ((dsh-emacs-thinking-expand-by-default t)
            (dsh-emacs-thinking-preview-max 0))
        ;; Block indices are reused by the next step.
        (dotimes (step 2)
          (let ((content
                 (vector
                  `((type . "reasoning") (text . ,(format "why-%d-a" step)))
                  `((type . "text") (text . ,(format "answer-%d-a" step)))
                  `((type . "reasoning") (text . ,(format "why-%d-b" step)))
                  `((type . "text") (text . ,(format "answer-%d-b" step))))))
            (dolist (phase (if deltas '(start delta end) '(start end)))
              (cl-loop for block across content for index from 0
                       for type = (cdr (assq 'type block))
                       for chunk = (pcase phase
                                     ('start `((type . "block-start")
                                               (index . ,index) (blockType . ,type)))
                                     ('delta `((type . ,(concat type "-delta"))
                                               (index . ,index)
                                               (text . ,(cdr (assq 'text block)))))
                                     ('end `((type . "block-end")
                                             (index . ,index) (block . ,block))))
                       do (dsh-emacs-render-event
                           `((type . "assistant/chunk")
                             (data . ((turn . 1) (step . ,step)
                                      (chunk . ,chunk)))))))
            (dsh-emacs-render-event
             `((type . "assistant/message")
               (data . ((turn . 1) (step . ,step)
                        (message . ((role . "assistant") (content . ,content)))))))
            (let ((previous (point-min)))
              (cl-loop for block across content
                       for body = (cdr (assq 'text block))
                       do (ert-info ((format "%s" (format "block-end-%s-keeps-%s-once-in-order"
                                                          (if deltas "delayed" "fallback") body)))
                            (should (= (how-many body (point-min) (point-max)) 1))
                            (should (save-excursion
                                      (goto-char previous)
                                      (when (search-forward body nil t)
                                        (setq previous (point))))))))
            (ert-info ((format "%s" "block-end-final-clears-live-step"))
              (should (null dsh-emacs--streamed-step))
              (should (null dsh-emacs--streaming-thinking))
              (should (null dsh-emacs--streaming-assistant)))))))))

;; Deltas may alternate between still-open protocol blocks.  An earlier
;; reasoning block must keep its identity after the answer starts.
(ert-deftest dsh-emacs-test-stream-overlapping-blocks-keep-live-answer-together ()
  :tags '(dsh-unit)
  (dolist (limit '(nil 8))
    (with-temp-buffer
      (dsh-emacs-mode)
      (let ((dsh-emacs-stream-markdown-limit limit)
            (dsh-emacs-thinking-expand-by-default t)
            (dsh-emacs-thinking-preview-max 0))
        (dolist (chunk '(((type . "reasoning-delta") (index . 0)
                          (text . "The test confirms the expected failure."))
                         ((type . "text-delta") (index . 1) (text . "RED"))
                         ((type . "reasoning-delta") (index . 0)
                          (text . " Check the test file."))
                         ((type . "text-delta") (index . 1)
                          (text . " confirmed (200 frames → 200 repaints)."))))
          (dsh-emacs-render-event
           `((type . "assistant/chunk")
             (data . ((turn . 1) (step . 1) (chunk . ,chunk))))))
        (dsh-emacs-render--flush-stream)
        (ert-info ((format "%s" "overlapping-blocks-keep-live-answer-together"))
          (should (= (how-many "Think" (point-min) (point-max)) 1))
          (should (string-match-p "RED confirmed (200 frames → 200 repaints)."
                                  (buffer-string)))
          (should (string-match-p "failure. Check the test file." (buffer-string))))
        (dsh-emacs-render-event
         '((type . "assistant/message")
           (data . ((turn . 1) (step . 1)
                    (message . ((content . [((type . "reasoning")
                                             (text . "The test confirms the expected failure. Check the test file."))
                                            ((type . "text")
                                             (text . "RED confirmed (200 frames → 200 repaints)."))])))))))
        (while dsh-emacs--markdown-pending
          (dsh-emacs-render--run-markdown (current-buffer)))
        (ert-info ((format "%s" "overlapping-blocks-settle-without-duplicates"))
          (should (= (how-many "Think" (point-min) (point-max)) 1))
          (should (= (how-many "RED confirmed" (point-min) (point-max)) 1))
          (should (string-match-p "failure. Check the test file." (buffer-string))))))))

;; The default collapsed row also updates in place, keeping the user's fold
;; choice and the draft while another reasoning block is still live.
(ert-deftest dsh-emacs-test-stream-late-reasoning-preserves-fold-draft-and-live-block ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs--setup-input-area)
    (dsh-emacs--replace-input "unsent draft")
    (let ((dsh-emacs-thinking-expand-by-default nil))
      (dolist (chunk '(((type . "reasoning-delta") (index . 0) (text . "first"))
                       ((type . "text-delta") (index . 1) (text . "answer"))
                       ((type . "reasoning-delta") (index . 2) (text . "second"))
                       ((type . "reasoning-delta") (index . 0) (text . " tail"))))
        (dsh-emacs-render-event
         `((type . "assistant/chunk")
           (data . ((turn . 1) (step . 1) (chunk . ,chunk))))))
      (let* ((block (car (plist-get dsh-emacs--streamed-step :thinking-blocks)))
             (range (dsh-emacs-ui-find-block (car block) (cdr block)))
             (state (get-text-property (car range) 'dsh-emacs-ui-state)))
        (ert-info ((format "%s" "late-reasoning-preserves-fold-draft-and-live-block"))
          (should (map-elt state :collapsed))
          (should (equal (map-elt state :body) "first tail"))
          (should (equal (plist-get dsh-emacs--streamed-step :reasoning) "first tail"))
          (should (= (plist-get dsh-emacs--streaming-thinking :index) 2))
          (should (= (how-many "Think" (point-min) (point-max)) 2))
          (should (equal (dsh-emacs--get-input) "unsent draft"))))
      (dsh-emacs-render--close-live-thinking-block)
      (ert-info ((format "%s" "late-reasoning-keeps-final-block-separators"))
        (should (equal (plist-get dsh-emacs--streamed-step :reasoning)
                       "first tail\nsecond"))))))

;; Final reasoning corrections replace or remove both live and folded blocks.
(ert-deftest dsh-emacs-test-stream-thinking-final-corrects-or-removes-old-content ()
  :tags '(dsh-unit)
  (dolist (final '("corrected reasoning" ""))
    (dolist (answer '("reply" ""))
      (dolist (limit '(nil 8))
        (with-temp-buffer
          (dsh-emacs-mode)
          (let ((dsh-emacs-stream-markdown-limit limit)
                (dsh-emacs-thinking-expand-by-default t)
                (dsh-emacs-thinking-preview-max 0)
                (final-answer (if (string-empty-p answer) "" "finished reply"))
                (event '((data . ((turn . 1) (step . 1))))))
            (dsh-emacs-render--start-thinking-stream event "obsolete reasoning")
            (dsh-emacs-render--start-assistant-stream event answer)
            (dsh-emacs-render-assistant-message
             `((data . ((turn . 1) (step . 1)
                        (message . ((content . [((type . "reasoning") (text . ,final))
                                                ((type . "text") (text . ,final-answer))])))))))
            (dotimes (_ 5)
              (when dsh-emacs--markdown-pending
                (dsh-emacs-render--run-markdown (current-buffer))))
            (let ((text (buffer-string)))
              (ert-info ((format "%s" "thinking-final-corrects-or-removes-old-content"))
                (should (not (string-match-p "obsolete reasoning" text)))
                (should (= (how-many "Think" (point-min) (point-max))
                           (if (string-empty-p final) 0 1)))
                (should (or (string-empty-p final) (string-match-p final text)))
                (should (null dsh-emacs--streaming-thinking)))
              (when (and (not (string-empty-p final))
                         (not (string-empty-p answer)))
                (ert-info ((format "%s" "thinking-correction-stays-above-answer"))
                  (should (and (string-match final text)
                               (string-match final-answer text)
                               (< (string-match final text) (string-match final-answer text)))))))))))))

;; Regression: unchanged interleaved blocks keep their order at finalization.
(ert-deftest dsh-emacs-test-stream-stream-final-keeps-one-think-per-block ()
  :tags '(dsh-unit)
  (dolist (types '(("reasoning" "reasoning" "text")
                   ("text" "text" "reasoning" "text")
                   ("text" "reasoning" "text" "reasoning" "text")
                   ("reasoning" "text" "reasoning" "text" "reasoning")))
    (dolist (limit '(nil 8))
      (with-temp-buffer
        (dsh-emacs-mode)
        (let ((dsh-emacs-stream-markdown-limit limit)
              (dsh-emacs-thinking-expand-by-default t)
              (dsh-emacs-thinking-preview-max 0)
              (seq 0)
              content)
          (dolist (type types)
            (let ((text (format "%s-%d" type (cl-incf seq))))
              (push `((type . ,type) (text . ,text)) content)
              (dsh-emacs-render-event
               `((type . "assistant/chunk") (seq . ,seq)
                 (data . ((turn . 1) (step . 1)
                          (chunk . ((type . ,(concat type "-delta"))
                                    (index . ,(1- seq)) (text . ,text))))))))
            (dsh-emacs-render--flush-stream)
            (dsh-emacs-render--flush-thinking))
          (dsh-emacs-render-event
           `((type . "assistant/message") (seq . 6)
             (data . ((turn . 1) (step . 1)
                      (message . ((role . "assistant")
                                  (content . ,(vconcat (nreverse content)))))))))
          (dotimes (_ 6)
            (when dsh-emacs--markdown-pending
              (dsh-emacs-render--run-markdown (current-buffer))))
          (let ((text (buffer-substring-no-properties (point-min) (point-max)))
                (previous 0))
            (ert-info ((format "%s" "stream-final-keeps-one-think-per-block"))
              (should (= (cl-count ?✶ text) (cl-count "reasoning" types :test #'equal))))
            (cl-loop for type in types for index from 1
                     for pos = (string-match (format "%s-%d" type index) text)
                     do (ert-info ((format "%s" "stream-final-keeps-block-order"))
                          (should pos)
                          (should (> pos previous))
                          (should (= (how-many (format "%s-%d" type index)
                                               (point-min) (point-max)) 1)))
                     do (setq previous (or pos previous)))))))))

;; A step can carry several protocol blocks.  Each owns its own transcript
;; region: the text stream's Markdown passes must never reach a reasoning body
;; that sits between two text blocks, and the authoritative message must not
;; re-render or delete a block that already streamed.
(ert-deftest dsh-emacs-test-stream-thinking-body-keeps-raw-markdown ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-modeline-setup)
    (let ((dsh-emacs-thinking-expand-by-default t))
      (dsh-emacs-render-event
       (json-read-from-string
        "{\"type\":\"assistant/chunk\",\"seq\":1,\"data\":{\"turn\":1,\"step\":1,\"chunk\":{\"type\":\"text-delta\",\"index\":0,\"text\":\"first answer\\n\"}}}"))
      (dsh-emacs-render--flush-stream)
      (dsh-emacs-render-event
       (json-read-from-string
        "{\"type\":\"assistant/chunk\",\"seq\":2,\"data\":{\"turn\":1,\"step\":1,\"chunk\":{\"type\":\"reasoning-delta\",\"index\":1,\"text\":\"| a | b |\\n|---|---|\\n\"}}}"))
      (dsh-emacs-render--flush-thinking)
      (dsh-emacs-render-event
       (json-read-from-string
        "{\"type\":\"assistant/chunk\",\"seq\":3,\"data\":{\"turn\":1,\"step\":1,\"chunk\":{\"type\":\"text-delta\",\"index\":2,\"text\":\"second answer\\n\"}}}"))
      (dsh-emacs-render--flush-stream)
      (let* ((text (buffer-substring-no-properties (point-min) (point-max)))
             (first (string-match "first answer" text))
             (think (string-match "✶ Think" text))
             (second (string-match "second answer" text)))
        (ert-info ((format "%s" "thinking-body-keeps-raw-markdown"))
          (should (string-match-p (regexp-quote "| a | b |") text))
          (should (not (string-match-p "├───" text))))
        (ert-info ((format "%s" "thinking-blocks-stack-in-arrival-order"))
          (should (and first think second (< first think second)))))
      (dsh-emacs-render-event
       (json-read-from-string
        "{\"type\":\"assistant/message\",\"seq\":4,\"data\":{\"turn\":1,\"step\":1,\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"first answer\\n\"},{\"type\":\"reasoning\",\"text\":\"| a | b |\\n|---|---|\\n\"},{\"type\":\"text\",\"text\":\"second answer\\n\"}]}}}"))
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (ert-info ((format "%s" "thinking-interleaved-final-keeps-every-block"))
          (should (= (cl-count ?✶ text) 1))
          (should (string-match-p "first answer" text))
          (should (string-match-p "second answer" text))
          (should (not (string-match-p "├───" text))))))))

;; A text block that ends before reasoning is a finished body: the final
;; message must not repaint it when it matches what streamed.
(ert-deftest dsh-emacs-test-stream-thinking-final-does-not-repaint-committed-text ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-modeline-setup)
    (let ((dsh-emacs-thinking-expand-by-default t))
      (dsh-emacs-render-event
       (json-read-from-string
        "{\"type\":\"assistant/chunk\",\"seq\":1,\"data\":{\"turn\":1,\"step\":1,\"chunk\":{\"type\":\"text-delta\",\"index\":0,\"text\":\"only answer\\n\"}}}"))
      (dsh-emacs-render--flush-stream)
      (dsh-emacs-render-event
       (json-read-from-string
        "{\"type\":\"assistant/chunk\",\"seq\":2,\"data\":{\"turn\":1,\"step\":1,\"chunk\":{\"type\":\"reasoning-delta\",\"index\":1,\"text\":\"why\\n\"}}}"))
      (dsh-emacs-render--flush-thinking)
      (dsh-emacs-render-event
       (json-read-from-string
        "{\"type\":\"assistant/message\",\"seq\":3,\"data\":{\"turn\":1,\"step\":1,\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"only answer\\n\"},{\"type\":\"reasoning\",\"text\":\"why\\n\"}]}}}"))
      (let* ((text (buffer-substring-no-properties (point-min) (point-max)))
             (copies 0)
             (pos 0))
        (while (string-match "only answer" text pos)
          (setq copies (1+ copies)
                pos (match-end 0)))
        (ert-info ((format "%s" "thinking-final-does-not-repaint-committed-text"))
          (should (= (cl-count ?✶ text) 1))
          (should (= copies 1))
          (should (null dsh-emacs--streamed-step)))))))

;; Two reasoning blocks around a text block: when the authoritative text
;; diverges and the middle body is dropped, neither Think block may go with it.
(ert-deftest dsh-emacs-test-stream-thinking-two-blocks-survive-a-divergent-repair ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-modeline-setup)
    (let ((dsh-emacs-thinking-expand-by-default t))
      (dsh-emacs-render-event
       (json-read-from-string
        "{\"type\":\"assistant/chunk\",\"seq\":1,\"data\":{\"turn\":1,\"step\":1,\"chunk\":{\"type\":\"reasoning-delta\",\"index\":0,\"text\":\"think A\\n\"}}}"))
      (dsh-emacs-render--flush-thinking)
      (dsh-emacs-render-event
       (json-read-from-string
        "{\"type\":\"assistant/chunk\",\"seq\":2,\"data\":{\"turn\":1,\"step\":1,\"chunk\":{\"type\":\"text-delta\",\"index\":1,\"text\":\"text one\\n\"}}}"))
      (dsh-emacs-render--flush-stream)
      (dsh-emacs-render-event
       (json-read-from-string
        "{\"type\":\"assistant/chunk\",\"seq\":3,\"data\":{\"turn\":1,\"step\":1,\"chunk\":{\"type\":\"reasoning-delta\",\"index\":2,\"text\":\"think B\\n\"}}}"))
      (dsh-emacs-render--flush-thinking)
      (dsh-emacs-render-event
       (json-read-from-string
        "{\"type\":\"assistant/message\",\"seq\":4,\"data\":{\"turn\":1,\"step\":1,\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"reasoning\",\"text\":\"think A\\n\"},{\"type\":\"reasoning\",\"text\":\"think B\\n\"},{\"type\":\"text\",\"text\":\"text one.\"}]}}}"))
      (let* ((text (buffer-substring-no-properties (point-min) (point-max)))
             (a (string-match "think A" text))
             (b (string-match "think B" text)))
        (ert-info ((format "%s" "thinking-two-blocks-survive-a-divergent-repair"))
          (should (= (cl-count ?✶ text) 2))
          (should (and a b (< a b)))
          (should (string-match-p "text one" text)))))))

;; --- Test 22: messages still insert above the input box after the input marker
;; is lost ---
(ert-deftest dsh-emacs-test-stream-assistant-below-input-fallback ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-modeline-setup)
    ;; Simulate the failure where the prompt marker is gone; message rendering
    ;; must relocate the anchor by face instead of appending below the input.
    (setq-local dsh-emacs--input-marker nil)
    (dsh-emacs-render-event
     (json-read-from-string
      (concat "{\"type\":\"assistant/message\",\"seq\":1,"
              "\"data\":{\"message\":{\"content\":[{\"type\":\"text\","
              "\"text\":\"reply-above-input\"}]}}}")))
    (let* ((anchor (or (dsh-emacs-render--input-anchor-pos) (point-max)))
           (text (buffer-substring-no-properties (point-min) (point-max)))
           (reply-pos (string-match "reply-above-input" text)))
      (ert-info ((format "%s" "assistant-below-input-fallback"))
        (should (and reply-pos
                     (< reply-pos anchor)
                     (save-excursion
                       (goto-char (point-min))
                       (re-search-forward "❯ " nil t))))))))

;; --- Test 23: streaming chunks also insert above the input box when the marker
;; is lost ---
(ert-deftest dsh-emacs-test-stream-assistant-stream-below-input-fallback ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-modeline-setup)
    (setq-local dsh-emacs--input-marker nil)
    (dsh-emacs-render-event
     (json-read-from-string
      "{\"type\":\"assistant/chunk\",\"seq\":1,\"data\":{\"turn\":1,\"step\":1,\"chunk\":{\"type\":\"text-delta\",\"index\":1,\"text\":\"stream-above-input\"}}}"))
    (let* ((anchor (or (dsh-emacs-render--input-anchor-pos) (point-max)))
           (text (buffer-substring-no-properties (point-min) (point-max)))
           (stream-pos (string-match "stream-above-input" text)))
      (ert-info ((format "%s" "assistant-stream-below-input-fallback"))
        (should (and stream-pos
                     (< stream-pos anchor)))))))

;; --- Test 55: thinking face has no explicit background (inherits
;; the theme background) ---
(ert-deftest dsh-emacs-test-stream-thinking-face-no-background ()
  :tags '(dsh-unit)
  (let ((bg (face-attribute 'dsh-emacs-thinking-face :background nil)))
    (ert-info ((format "%s" "thinking-face-no-background"))
      (should (or (null bg)
                  (memq bg '(unspecified unspecified-bg)))))))

;; --- Test 56: in a think line only the label carries thinking-face;
;; preview and expanded body use the muted thinking-body-face
;; (regression: the whole block was covered by thinking-face, so
;; preview / body inherited the label's orange bold) ---
(ert-deftest dsh-emacs-test-stream-thinking-label-gets-thinking-face ()
  :tags '(dsh-unit)
  (let ((buf (generate-new-buffer " *dsh-think-face*"))
        (dsh-emacs-thinking-expand-by-default t))
    (unwind-protect
        (with-current-buffer buf
          (insert "###HEAD\n")
          (dsh-emacs-render--render-thinking-block
           "t" "b1" "first body line\nsecond body line" 1 (point-max))
          (goto-char (point-min))
          (ert-info ((format "%s" "thinking-label-gets-thinking-face"))
            (should (and (search-forward "Think" nil t)
                         (memq 'dsh-emacs-thinking-face
                               (dsh-test--faces-at (match-beginning 0)))
                         ;; the title keeps the fragment title face (bold)
                         (memq 'dsh-emacs-ui-label-face
                               (dsh-test--faces-at (match-beginning 0))))))
          ;; The icon (start of the label line) likewise keeps thinking-face:
          ;; the terminal glyph fallback must not turn grey, and the graphical
          ;; SVG is already colored with the thinking color
          (goto-char (point-min))
          (ert-info ((format "%s" "thinking-label-icon-gets-thinking-face"))
            (should (and (search-forward "✶" nil t)
                         (memq 'dsh-emacs-thinking-face
                               (dsh-test--faces-at (match-beginning 0))))))
          (goto-char (point-min))
          (ert-info ((format "%s" "thinking-preview-uses-body-face"))
            (should (and (search-forward "first body line" nil t)
                         (memq 'dsh-emacs-thinking-body-face
                               (dsh-test--faces-at (match-beginning 0)))
                         (not (memq 'dsh-emacs-thinking-face
                                    (dsh-test--faces-at (match-beginning 0))))
                         ;; the preview is a summary, not a title: it must not inherit
                         ;; the title's bold weight
                         (not (memq 'dsh-emacs-ui-label-face
                                    (dsh-test--faces-at (match-beginning 0)))))))
          ;; Same for expanded body lines: body face, not label face
          (goto-char (point-min))
          (ert-info ((format "%s" "thinking-body-uses-body-face"))
            (should (and (search-forward "second body line" nil t)
                         (memq 'dsh-emacs-thinking-body-face
                               (dsh-test--faces-at (match-beginning 0)))
                         (not (memq 'dsh-emacs-thinking-face
                                    (dsh-test--faces-at (match-beginning 0))))))))
      (kill-buffer buf))))

;; In `simple` the Think title joins the other event-row labels on the muted
;; grey face.  The live dot keeps the thinking accent; the completed fragment's
;; dot settles to the same grey.
(ert-deftest dsh-emacs-test-stream-simple-think-complete-dot-is-gray ()
  :tags '(dsh-unit)
  (let ((dsh-emacs-render-style 'simple))
    (with-temp-buffer
      (dsh-emacs-mode)
      (dsh-emacs-modeline-setup)
      (dsh-emacs-render--render-thinking-block
       "t" "b1" "reason" 1 (point-max))
      (goto-char (point-min))
      (ert-info ((format "%s" "simple-think-fragment-title-is-neutral"))
        (should (search-forward "Think" nil t))
        (should (memq 'dsh-emacs-event-row-face
                      (dsh-test--faces-at (match-beginning 0))))
        (should-not (memq 'dsh-emacs-thinking-face
                          (dsh-test--faces-at (match-beginning 0)))))
      (goto-char (point-min))
      (ert-info ((format "%s" "simple-think-fragment-dot-is-gray"))
        (should (search-forward "●" nil t))
        (should (memq 'dsh-emacs-event-row-face
                      (dsh-test--faces-at (match-beginning 0))))
        (should-not (memq 'dsh-emacs-thinking-face
                          (dsh-test--faces-at (match-beginning 0))))))
    (with-temp-buffer
      (dsh-emacs-mode)
      (dsh-emacs-modeline-setup)
      (dsh-emacs-render--start-thinking-stream
       '((data . ((turn . 1) (step . 1)))) "live reasoning")
      (goto-char (point-min))
      (ert-info ((format "%s" "simple-live-think-title-is-neutral"))
        (should (search-forward "Think" nil t))
        (should (memq 'dsh-emacs-event-row-face
                      (dsh-test--faces-at (match-beginning 0))))
        (should-not (memq 'dsh-emacs-thinking-face
                          (dsh-test--faces-at (match-beginning 0)))))
      (goto-char (point-min))
      (ert-info ((format "%s" "simple-live-think-dot-keeps-accent"))
        (should (search-forward "●" nil t))
        (should (memq 'dsh-emacs-thinking-face
                      (dsh-test--faces-at (match-beginning 0))))))))

;; The think body during streaming (waiting for a response) likewise
;; uses the muted body face; only the header label keeps thinking-face.
(ert-deftest dsh-emacs-test-stream-thinking-stream-body-uses-body-face ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-render--start-thinking-stream
     '((data . ((turn . 1) (step . 1)))) "live reasoning")
    (dsh-emacs-render--flush-thinking)
    (goto-char (point-min))
    (ert-info ((format "%s" "thinking-stream-body-uses-body-face"))
      (should (and (search-forward "live reasoning" nil t)
                   (memq 'dsh-emacs-thinking-body-face
                         (dsh-test--faces-at (match-beginning 0)))
                   (not (memq 'dsh-emacs-thinking-face
                              (dsh-test--faces-at (match-beginning 0)))))))))

;; A burst writes once per flush; finalization reuses the painted body.
(ert-deftest dsh-emacs-test-stream-stream-coalesces-markdown-burst ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (let ((event '((data . ((turn . 1) (step . 1)))))
          (calls 0) (forced 0) (writes 0) (anchors 0)
          (anchor (symbol-function 'dsh-emacs-render--input-anchor-pos))
          (render (symbol-function 'dsh-emacs-markdown-replace-markup)))
      (cl-letf (((symbol-function 'dsh-emacs-markdown-replace-markup)
                 (lambda (&rest args)
                   (setq calls (1+ calls))
                   (when (plist-get args :force) (setq forced (1+ forced)))
                   (apply render args)))
                ((symbol-function 'dsh-emacs-render--input-anchor-pos)
                 (lambda () (setq anchors (1+ anchors)) (funcall anchor))))
        (dsh-emacs-render--start-assistant-stream event "hello")
        (add-hook 'after-change-functions
                  (lambda (&rest _) (setq writes (1+ writes))) nil t)
        (dotimes (_ 10)
          (dsh-emacs-render--start-assistant-stream event " world")
          (dsh-emacs-render--follow-stream))
        (ert-info ((format "%s" "stream-coalesces-markdown-burst"))
          (should (= calls 1)))
        (let* ((state dsh-emacs--streaming-assistant)
               (end (marker-position (plist-get state :end))))
          (ert-info ((format "%s" "stream-burst-defers-writes-and-follow"))
            (should (equal (buffer-substring-no-properties
                            (plist-get state :start) end) "hello"))
            (should (= writes 0))
            (should (= anchors 0))
            (should (get-text-property (1- end) 'read-only))))
        (dsh-emacs-render--finish-assistant-stream
         event (concat "hello" (apply #'concat (make-list 10 " world"))))
        (ert-info ((format "%s" "stream-final-flushes-without-full-rewrite"))
          (should (= calls 2))
          (should (= forced 0))
          (should (null dsh-emacs--streaming-assistant))
          (should (string-match-p (concat "hello" (apply #'concat (make-list 10 " world")))
                                  (buffer-string))))))))

;; The renderer owns and reuses the Markdown frontier across real flushes.
(ert-deftest dsh-emacs-test-stream-stream-renderer-retains-incremental-frontier ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (let ((event '((data . ((turn . 1) (step . 1)))))
          (scanned 0)
          (stream-end (symbol-function 'dsh-emacs-markdown--stream-end)))
      (cl-letf (((symbol-function 'dsh-emacs-markdown--stream-end)
                 (lambda (state)
                   (setq scanned
                         (+ scanned (- (point-max)
                                       (or (plist-get state :scan) (point-min)))))
                   (funcall stream-end state))))
        (dsh-emacs-render--start-assistant-stream event "```text\n")
        (let* ((markdown (plist-get dsh-emacs--streaming-assistant :markdown))
               (scan (plist-get markdown :scan)))
          (dotimes (_ 20)
            (dsh-emacs-render--start-assistant-stream event "row\n")
            (dsh-emacs-render--flush-stream))
          (ert-info ((format "%s" "stream-renderer-retains-incremental-frontier"))
            (should (= scanned (+ 8 (* 20 4))))
            (should (markerp scan))
            (should (eq markdown (plist-get dsh-emacs--streaming-assistant :markdown)))
            (should (eq scan (plist-get markdown :scan))))
          (dsh-emacs-render--finish-assistant-stream
           event (concat "```text\n" (apply #'concat (make-list 20 "row\n")) "```"))
          (ert-info ((format "%s" "stream-corrected-final-releases-frontier"))
            (should (null (plist-get markdown :scan)))
            (should (null (plist-get markdown :pending)))
            (should (text-property-not-all (point-min) (point-max)
                                           'dsh-emacs-markdown-frozen nil))))))))

;; Advancing the live frontier must not rewrite the stable reply prefix.
(ert-deftest dsh-emacs-test-stream-stream-frontier-does-not-invalidate-stable-prefix ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (let ((event '((data . ((turn . 1) (step . 1)))))
          (put (symbol-function 'put-text-property))
          (prefix-writes 0))
      (dsh-emacs-render--start-assistant-stream event "**stable**\n")
      (let* ((state dsh-emacs--streaming-assistant)
             (markdown (plist-get state :markdown))
             (start (marker-position (plist-get state :start)))
             (stable (buffer-substring start (plist-get state :end))))
        (cl-letf (((symbol-function 'put-text-property)
                   (lambda (beg end prop value &optional object)
                     (when (and (not object) (= beg start))
                       (cl-incf prefix-writes))
                     (funcall put beg end prop value object))))
          (dotimes (_ 10)
            (dsh-emacs-render--start-assistant-stream event "next\n")
            (dsh-emacs-render--flush-stream)))
        (ert-info ((format "%s" "stream-frontier-does-not-invalidate-stable-prefix"))
          (should (= prefix-writes 0))
          (should (equal-including-properties
                   stable (buffer-substring start (+ start (length stable))))))
        (let ((watermark (plist-get markdown :watermark)))
          (ert-info ((format "%s" "stream-frontier-tracks-rendered-tail"))
            (should (markerp watermark))
            (should (equal watermark (plist-get state :end))))
          (dsh-emacs-render--finish-assistant-stream
           event (concat "**stable**\n" (apply #'concat (make-list 10 "next\n"))))
          (ert-info ((format "%s" "stream-final-releases-render-frontier"))
            (should (null (plist-get markdown :watermark)))
            (should (or (not (markerp watermark)) (null (marker-buffer watermark))))))))))

;; Timer callbacks write to their owner once, preserving draft and properties.
(ert-deftest dsh-emacs-test-stream-stream-burst-keeps-one-timer ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (goto-char (point-max))
    (insert "draft\n草稿")
    (let ((owner (current-buffer))
          (event '((data . ((turn . 1) (step . 1)))))
          (insertions 0))
      (dsh-emacs-render--start-assistant-stream event "你好")
      (dsh-emacs-render--start-assistant-stream event " world")
      (let ((timer (plist-get dsh-emacs--streaming-assistant :timer)))
        (dsh-emacs-render--start-assistant-stream event "\n下一行")
        (ert-info ((format "%s" "stream-burst-keeps-one-timer"))
          (should (eq timer (plist-get dsh-emacs--streaming-assistant :timer))))
        (add-hook 'after-change-functions
                  (lambda (start end old)
                    (when (and (zerop old) (< start end))
                      (setq insertions (1+ insertions)))) nil t)
        (with-temp-buffer
          (insert "other buffer")
          (apply (timer--function timer) (timer--args timer))
          (ert-info ((format "%s" "stream-timer-does-not-write-to-current-buffer"))
            (should (equal (buffer-string) "other buffer"))))
        (let* ((state dsh-emacs--streaming-assistant)
               (end (marker-position (plist-get state :end)))
               (text (buffer-substring-no-properties (plist-get state :start) end)))
          (ert-info ((format "%s" "stream-timer-inserts-once-with-transcript-properties"))
            (should (eq owner (current-buffer)))
            (should (= insertions 1))
            (should (equal text "你好 world\n下一行"))
            (should (get-text-property (1- end) 'read-only))
            (should (equal (get-text-property (1- end) 'dsh-emacs-event-block)
                           (plist-get state :event-id)))
            (should (not (memq timer timer-list)))
            (should (null (plist-get state :timer)))
            (should (equal (buffer-substring-no-properties dsh-emacs--input-marker
                                                           (point-max))
                           "draft\n草稿"))))
        (dsh-emacs-render--flush-stream nil t)))))

;; Event dispatch must flush text at boundaries without unbatching reasoning.
(ert-deftest dsh-emacs-test-stream-stream-boundary-publishes-text-before-reasoning ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (let ((text-event '((type . "assistant/chunk")
                        (data . ((turn . 1) (step . 1)
                                 (chunk . ((type . "text-delta") (text . "answer")))))))
          (think-event '((type . "assistant/chunk")
                         (data . ((turn . 1) (step . 1)
                                  (chunk . ((type . "reasoning-delta") (text . "think"))))))))
      (dsh-emacs-render-event text-event)
      (dsh-emacs-render-event text-event)
      (dsh-emacs-render-event think-event)
      (ert-info ((format "%s" "stream-boundary-publishes-text-before-reasoning"))
        (should (null (plist-get dsh-emacs--streaming-assistant :timer)))
        (should (string-match-p "answeranswer" (buffer-string))))
      (dsh-emacs-render-event think-event)
      (dsh-emacs-render-event think-event)
      (ert-info ((format "%s" "stream-dispatch-preserves-reasoning-batching"))
        (should (= (length (plist-get dsh-emacs--streaming-thinking :chunks)) 2)))
      (dsh-emacs-render-event text-event)
      (ert-info ((format "%s" "stream-text-publishes-pending-reasoning"))
        (should (null (plist-get dsh-emacs--streaming-thinking :timer)))
        (should (string-match-p "thinkthinkthink" (buffer-string))))
      (dsh-emacs-render--finish-assistant-stream text-event "corrected")
      (ert-info ((format "%s" "stream-correction-discards-unpainted-text"))
        (should (string-match-p "corrected" (buffer-string)))
        (should (not (string-match-p "answer" (buffer-string))))
        (should (null dsh-emacs--streaming-assistant))))))

;; Pending Markdown timers must not outlive their transcript.
(ert-deftest dsh-emacs-test-stream-stream-disconnect-flushes-and-cancels-timer ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (let ((event '((data . ((turn . 1) (step . 1))))) timer)
      (dsh-emacs-render--start-assistant-stream event "hello ")
      (dsh-emacs-render--start-assistant-stream event "**world**")
      (setq timer (plist-get dsh-emacs--streaming-assistant :timer))
      (dsh-emacs-events-disconnect)
      (ert-info ((format "%s" "stream-disconnect-flushes-and-cancels-timer"))
        (should (timerp timer))
        (should (not (memq timer timer-list)))
        (should (not (string-match-p "\\*\\*" (buffer-string))))))))

(ert-deftest dsh-emacs-test-stream-mode-reinitialization-cancels-owned-timers ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (let ((event '((data . ((turn . 1) (step . 1))))) formatting)
      (unwind-protect
          (progn
            (dsh-emacs-render--start-assistant-stream event "hello ")
            (dsh-emacs-render--start-assistant-stream event "world")
            (setq formatting (plist-get dsh-emacs--streaming-assistant :timer))
            (dsh-emacs-mode)
            (ert-info ((format "%s" "mode-reinitialization-cancels-owned-timers"))
              (should (not (memq formatting timer-list)))))
        (when formatting (cancel-timer formatting))))))

(provide 'dsh-test-stream)
;;; dsh-test-stream.el ends here
