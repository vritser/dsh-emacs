;;; dsh-test-render.el --- Render tests -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "28.1"))

(require 'dsh-test-support)

;; --- Test 9: event renderer functions exist ---
(ert-deftest dsh-emacs-test-render-render-event-function-exists ()
  :tags '(dsh-unit)
  (ert-info ((format "%s" "render-event function exists"))
    (should (fboundp 'dsh-emacs-render-event))))

(ert-deftest dsh-emacs-test-render-render-history-events-function-exists ()
  :tags '(dsh-unit)
  (ert-info ((format "%s" "render-history-events function exists"))
    (should (fboundp 'dsh-emacs-render-history-events))))

(ert-deftest dsh-emacs-test-render-render-user-message-function-exists ()
  :tags '(dsh-unit)
  (ert-info ((format "%s" "render-user-message function exists"))
    (should (fboundp 'dsh-emacs-render-user-message))))

(ert-deftest dsh-emacs-test-render-render-assistant-message-function-exists ()
  :tags '(dsh-unit)
  (ert-info ((format "%s" "render-assistant-message function exists"))
    (should (fboundp 'dsh-emacs-render-assistant-message))))

(ert-deftest dsh-emacs-test-render-render-tool-call-function-exists ()
  :tags '(dsh-unit)
  (ert-info ((format "%s" "render-tool-call function exists"))
    (should (fboundp 'dsh-emacs-render-tool-call))))

(ert-deftest dsh-emacs-test-render-render-tool-result-function-exists ()
  :tags '(dsh-unit)
  (ert-info ((format "%s" "render-tool-result function exists"))
    (should (fboundp 'dsh-emacs-render-tool-result))))

;; --- Test 19: assistant replies remain in history order ---
(ert-deftest dsh-emacs-test-render-assistant-replies-keep-order ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-modeline-setup)
    (let ((first (json-read-from-string
                  "{\"event\":{\"type\":\"assistant/message\",\"seq\":1,\"data\":{\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"reply-1\"}]}}}}"))
          (second (json-read-from-string
                   "{\"event\":{\"type\":\"assistant/message\",\"seq\":2,\"data\":{\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"reply-2\"}]}}}}")))
      (dsh-emacs-render-history-events (list first second))
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (ert-info ((format "%s" "assistant-replies-keep-order"))
          (should (and (< (string-match "reply-1" text)
                          (string-match "reply-2" text))
                       (string-match "reply-1\n" text)
                       (string-match "reply-2\n" text))))))))

;; --- Test 20: chat prefix and rendered Markdown ---
(ert-deftest dsh-emacs-test-render-chat-prefix-and-markdown-render ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-modeline-setup)
    (let ((user (json-read-from-string
                 "{\"type\":\"user/message\",\"seq\":1,\"data\":{\"content\":[{\"type\":\"text\",\"text\":\"hello\"}]}}"))
          (assistant (json-read-from-string
                      "{\"type\":\"assistant/message\",\"seq\":2,\"data\":{\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"# title\\n**bold**\"}]}}}")))
      (dsh-emacs-render-event user)
      (dsh-emacs-render-event assistant)
      (let* ((text (buffer-substring (point-min) (point-max)))
             (title-pos (string-match "title" text))
             (bold-pos (string-match "bold" text))
             (title-face (and title-pos (get-text-property (1+ title-pos) 'face text)))
             (bold-face (and bold-pos (get-text-property (1+ bold-pos) 'face text))))
        (ert-info ((format "%s" "chat-prefix-and-markdown-render"))
          (should (and (string-match "\nhello\n" text)
                       (member 'dsh-emacs-markdown-header-1
                               (if (listp title-face) title-face (list title-face)))
                       (member 'dsh-emacs-markdown-bold
                               (if (listp bold-face) bold-face (list bold-face))))))))))

;; Packed stream records reconstruct in order, tool calls included.
(ert-deftest dsh-emacs-test-render-attempt-stream-text-reconstructs ()
  :tags '(dsh-unit)
  (let ((records (dsh-protocol--assistant-records
                  '[((type . "reasoning-chunks") (texts . ["think"]))
                    ((type . "tool-call-chunks") (name . "bash")
                     (args . ["{\"command\":\"ls\"}"]))
                    ((type . "text-chunks") (texts . ["reply"]))])))
    (should (equal (dsh-emacs-render--assistant-stream-text records)
                   "think\n→ bash {\"command\":\"ls\"}\nreply"))))

(ert-deftest dsh-emacs-test-render-attempt-stream-text-respects-reasoning-option ()
  :tags '(dsh-unit)
  (let ((dsh-emacs-show-reasoning nil)
        (records (dsh-protocol--assistant-records
                  '[((type . "reasoning-chunks") (texts . ["hidden think"]))])))
    (should (equal (dsh-emacs-render--assistant-stream-text records) ""))))

;; A live body the attempt settles is taken over, never painted twice.
(ert-deftest dsh-emacs-test-render-attempt-takes-over-live-body ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-modeline-setup)
    (dsh-emacs-render--start-assistant-stream
     '((data . ((turn . 1) (step . 1)))) "live partial")
    (dsh-emacs-render-event
     (json-read-from-string
      "{\"type\":\"assistant/attempt\",\"seq\":5,\"time\":2000,\"data\":{\"turn\":1,\"step\":1,\"stream\":[{\"type\":\"text-chunks\",\"time0\":1,\"index\":0,\"dt\":[1],\"texts\":[\"live partial\"]}]}}"))
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      (ert-info ((format "%s" "attempt-takes-over-live-body"))
        (should (null dsh-emacs--streaming-assistant))
        (should (string-match-p "Incomplete reply" text))
        (should (= 2 (length (split-string text "live partial" nil))))))))

;; Failed attempts own all their blocks, including folded/live reasoning.
(ert-deftest dsh-emacs-test-render-attempt-clears-all-live-blocks ()
  :tags '(dsh-unit)
  (dolist (types '(("reasoning") ("reasoning" "text" "reasoning" "text")))
    (with-temp-buffer
      (dsh-emacs-mode)
      (let ((dsh-emacs-thinking-preview-max 0)
            records)
        (cl-loop for type in types for index from 0
                 for body = (format "failed-%s-%d" type index)
                 do (push `((type . ,(concat type "-chunks"))
                            (index . ,index) (texts . [,body])) records)
                 do (dsh-emacs-render-event
                     `((type . "assistant/chunk")
                       (data . ((turn . 1) (step . 1)
                                (chunk . ((type . ,(concat type "-delta"))
                                          (index . ,index) (text . ,body))))))))
        (goto-char (point-max))
        (insert "keep draft")
        (dsh-emacs-render-event
         `((type . "assistant/attempt") (seq . 5)
           (data . ((turn . 1) (step . 1)
                    (stream . ,(vconcat (nreverse records)))))))
        (ert-info ((format "%s" "attempt-clears-all-live-blocks"))
          (should (null dsh-emacs--streaming-assistant))
          (should (null dsh-emacs--streaming-thinking))
          (should (null dsh-emacs--streamed-step))
          (should (= (how-many "Think" (point-min) (point-max)) 0))
          (should (string-suffix-p "keep draft" (buffer-string))))
        (cl-loop for type in types for index from 0
                 do (ert-info ((format "%s" "attempt-owns-each-failed-block-once"))
                      (should (= (how-many (format "failed-%s-%d" type index)
                                           (point-min) (point-max)) 1))))
        ;; A retry may reuse turn/step and block index zero without any deltas.
        (dsh-emacs-render-event
         '((type . "assistant/chunk")
           (data . ((turn . 1) (step . 1)
                    (chunk . ((type . "block-end") (index . 0)
                              (block . ((type . "reasoning")
                                        (text . "retry-only")))))))))
        (ert-info ((format "%s" "attempt-retry-starts-fresh"))
          (should (= (how-many "retry-only" (point-min) (point-max)) 1))
          (should (equal (plist-get dsh-emacs--streaming-thinking :all) '("retry-only"))))))))

;; Seed boundaries advance the anchor without changing the transcript.
(ert-deftest dsh-emacs-test-render-seed-boundary-consumed-without-divider ()
  :tags '(dsh-unit)
  (dolist (data '("{\"inherited\":true}" "{}"))
    (with-temp-buffer
      (dsh-emacs-mode)
      (dsh-emacs-modeline-setup)
      (let ((before (buffer-string)))
        (ert-info ((format "%s" "seed-boundary-consumed-without-divider"))
          (should (= (dsh-emacs-render-event
                      (json-read-from-string
                       (format "{\"type\":\"session/end-seed\",\"seq\":7,\"data\":%s}"
                               data)))
                     7))
          (should (= dsh-emacs--anchor-seq 7))
          (should (equal (buffer-string) before)))))))

;; deliverables/presented: collected, rendered once at the turn's tail.
(ert-deftest dsh-emacs-test-render-deliverables-decoded-view ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (let ((view (dsh-protocol-deliverables--from-alist
                 '((seq . 71) (data (turn . 8)
                                    (files . [((path . "report.md")
                                               (description . "First"))]))))))
      (should (= 71 (dsh-emacs-render-deliverables view)))
      (should (equal '((8 ("report.md" . "First")))
                     dsh-emacs-render--turn-deliverables)))
    (should (= 72 (dsh-emacs-render-deliverables
                   '((seq . 72) (data (turn . 8) (files . []))))))
    (should (= 73 (dsh-emacs-render-deliverables
                   '((seq . 73) (data (turn . "invalid")
                                      (files . [((path . "ignore.md"))]))))))
    (should (equal '((8 ("report.md" . "First")))
                   dsh-emacs-render--turn-deliverables))))

(ert-deftest dsh-emacs-test-render-deliverables-deferred-until-turn-end ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-modeline-setup)
    (dsh-emacs-render-event
     (json-read-from-string
      "{\"type\":\"assistant/message\",\"seq\":1,\"data\":{\"turn\":1,\"step\":1,\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"closing reply\"}]}}}"))
    (dsh-emacs-render-event
     (json-read-from-string
      "{\"type\":\"deliverables/presented\",\"seq\":2,\"data\":{\"turn\":1,\"callId\":\"c1\",\"files\":[{\"path\":\"report.md\",\"description\":\"Final report\"},{\"path\":\"notes.txt\"}]}}"))
    (ert-info ((format "%s" "deliverables-deferred-until-turn-end"))
      (should (not (string-match-p "Deliverables"
                                   (buffer-substring-no-properties (point-min) (point-max))))))
    (dsh-emacs-render-event
     (json-read-from-string
      "{\"type\":\"turn/end\",\"seq\":3,\"data\":{\"turn\":1,\"reason\":{\"kind\":\"completed\"}}}"))
    (let* ((full (buffer-string))
           (text (buffer-substring-no-properties (point-min) (point-max)))
           (reply (string-match "closing reply" full))
           (row (string-match "Deliverables" full)))
      (ert-info ((format "%s" "deliverables-row-at-turn-tail-collapsed"))
        (should (string-match-p "Deliverables · 2 files" text))
        (should (not (string-match-p "report.md" text)))
        (should (and reply row (< reply row))))
      (ert-info ((format "%s" "deliverables-row-leads-with-green-dot"))
        (should (let ((dot (string-match "●" full)))
                  (and dot
                       (memq 'dsh-emacs-deliverable-dot-face
                             (ensure-list (get-text-property dot 'face full)))))))
      (ert-info ((format "%s" "deliverables-title-uses-own-face"))
        (should (let ((title (string-match "Deliverables" full)))
                  (and title
                       (memq 'dsh-emacs-deliverable-text-face
                             (ensure-list (get-text-property title 'face full)))))))
      ;; Expanding shows the file lines in the bash-card panel surface.
      (goto-char (point-min))
      (search-forward "Deliverables")
      (dsh-emacs-ui-toggle-fragment)
      (setq full (buffer-string)
            text (buffer-substring-no-properties (point-min) (point-max)))
      (let ((path (string-match (regexp-quote "report.md") full)))
        (ert-info ((format "%s" "deliverables-expanded-shows-files"))
          (should (string-match-p "Final report" text))
          (should (string-match-p "notes.txt" text)))
        (ert-info ((format "%s" "deliverables-path-is-clickable"))
          (should (equal '(file . "report.md")
                         (get-text-property path 'dsh-emacs-reference-ref full)))
          (should (memq 'dsh-emacs-reference-face
                        (ensure-list (get-text-property path 'face full)))))))))

;; Repeated declaration of one path keeps one line, latest description.
(ert-deftest dsh-emacs-test-render-deliverables-merge-last-wins ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-modeline-setup)
    (dolist (json '("{\"type\":\"deliverables/presented\",\"seq\":1,\"data\":{\"turn\":4,\"callId\":\"a\",\"files\":[{\"path\":\"out.md\",\"description\":\"old\"}]}}"
                    "{\"type\":\"deliverables/presented\",\"seq\":2,\"data\":{\"turn\":4,\"callId\":\"b\",\"files\":[{\"path\":\"out.md\",\"description\":\"new\"}]}}"
                    "{\"type\":\"turn/end\",\"seq\":3,\"data\":{\"turn\":4,\"reason\":{\"kind\":\"completed\"}}}"))
      (dsh-emacs-render-event (json-read-from-string json)))
    (goto-char (point-min))
    (dsh-emacs-ui-toggle-fragment)
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      (ert-info ((format "%s" "deliverables-merge-last-wins"))
        (should (string-match-p "Deliverables · 1 file" text))
        (should (string-match-p "new" text))
        (should (not (string-match-p "old" text)))
        (should (= 2 (length (split-string text "out.md" nil))))))))

;; A snapshot tail cut before turn/end still renders the row (batch end),
;; and the flush clears the state so a later turn/end cannot render twice.
(ert-deftest dsh-emacs-test-render-deliverables-flushed-at-batch-end ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-modeline-setup)
    (dsh-emacs-render-history-events
     (list (list (cons "event"
                       (json-read-from-string
                        "{\"type\":\"deliverables/presented\",\"seq\":1,\"data\":{\"turn\":7,\"callId\":\"c\",\"files\":[{\"path\":\"out.txt\"}]}}"))))
     nil)
    (ert-info ((format "%s" "deliverables-flushed-at-batch-end"))
      (should (string-match-p "Deliverables · 1 file"
                              (buffer-substring-no-properties (point-min) (point-max)))))
    (goto-char (point-min))
    (dsh-emacs-ui-toggle-fragment)
    (ert-info ((format "%s" "deliverables-batch-row-expands"))
      (should (string-match-p "out.txt"
                              (buffer-substring-no-properties (point-min) (point-max)))))
    (dsh-emacs-render-event
     (json-read-from-string
      "{\"type\":\"turn/end\",\"seq\":2,\"data\":{\"turn\":7,\"reason\":{\"kind\":\"completed\"}}}"))
    (ert-info ((format "%s" "deliverables-flush-does-not-double-render"))
      (should (null dsh-emacs-render--turn-deliverables))
      (should (= 1 (cl-count ?● (buffer-substring-no-properties (point-min) (point-max))))))))

;; A newline inside a model-written description cannot fake a second file.
(ert-deftest dsh-emacs-test-render-deliverable-description-flattened ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-modeline-setup)
    (dolist (json '("{\"type\":\"deliverables/presented\",\"seq\":1,\"data\":{\"turn\":1,\"callId\":\"c\",\"files\":[{\"path\":\"a.md\",\"description\":\"one\\ntwo\"}]}}"
                    "{\"type\":\"turn/end\",\"seq\":2,\"data\":{\"turn\":1,\"reason\":{\"kind\":\"completed\"}}}"))
      (dsh-emacs-render-event (json-read-from-string json)))
    (goto-char (point-min))
    (dsh-emacs-ui-toggle-fragment)
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      (ert-info ((format "%s" "deliverable-description-flattened"))
        (should (string-match-p "a.md — one two" text))))))

;; The reference module owns the clickable file-path presentation.
(ert-deftest dsh-emacs-test-render-reference-file-link-propertizes ()
  :tags '(dsh-unit)
  (ert-info ((format "%s" "reference-file-link-propertizes"))
    (should (let ((span (dsh-emacs-reference-file-link "a.md")))
              (and (equal '(file . "a.md")
                          (get-text-property 0 'dsh-emacs-reference-ref span))
                   (eq 'dsh-emacs-reference-face (get-text-property 0 'face span)))))
    (should (equal "" (dsh-emacs-reference-file-link "")))))

;; The row title carries its own hue: it must not blend into the green dot,
;; and must not read as a second link color next to the clickable paths.
(ert-deftest dsh-emacs-test-render-deliverables-title-color-differs-from-dot ()
  :tags '(dsh-unit)
  (ert-info ((format "%s" "deliverables-title-color-differs-from-dot"))
    (should (let ((title (face-foreground 'dsh-emacs-deliverable-text-face nil t))
                  (dot (face-foreground 'dsh-emacs-deliverable-dot-face nil t)))
              (and title dot (not (equal title dot)))))))

(ert-deftest dsh-emacs-test-render-deliverables-title-color-differs-from-link ()
  :tags '(dsh-unit)
  (ert-info ((format "%s" "deliverables-title-color-differs-from-link"))
    (should (let ((title (face-foreground 'dsh-emacs-deliverable-text-face nil t))
                  (link (face-foreground 'dsh-emacs-reference-face nil t)))
              (and title link (not (equal title link)))))))

;; --- Test 27g: one blank line before and after user messages; assistant
;; messages still stay tight ---
(ert-deftest dsh-emacs-test-render-user-message-spaced-above-and-below ()
  :tags '(dsh-unit)
  (let ((buf (generate-new-buffer " *t27g-layout*")))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-mode)
          (dsh-emacs-modeline-setup)
          (dsh-emacs-render-event
           (json-read-from-string
            "{\"type\":\"assistant/message\",\"seq\":1,\"data\":{\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"a1\"}]}}}"))
          (dsh-emacs-render-event
           (json-read-from-string
            "{\"type\":\"assistant/message\",\"seq\":2,\"data\":{\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"a2\"}]}}}"))
          (dsh-emacs-render-event
           (json-read-from-string
            "{\"type\":\"user/message\",\"seq\":3,\"data\":{\"content\":[{\"type\":\"text\",\"text\":\"u1\"}]}}"))
          (dsh-emacs-render-event
           (json-read-from-string
            "{\"type\":\"assistant/message\",\"seq\":4,\"data\":{\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"a3\"}]}}}"))
          (let* ((user-line
                  (save-excursion
                    (goto-char (point-min))
                    (when (search-forward "u1" nil t)
                      (line-number-at-pos (line-beginning-position)))))
                 (above-blank
                  (and user-line
                       (save-excursion
                         (goto-char (point-min))
                         (forward-line (- user-line 2))
                         (looking-at-p "[ \t]*$"))))
                 (below-blank
                  (and user-line
                       (save-excursion
                         (goto-char (point-min))
                         (forward-line user-line)
                         (looking-at-p "[ \t]*$"))))
                 (a1-line (save-excursion
                            (goto-char (point-min))
                            (when (search-forward "a1" nil t)
                              (line-number-at-pos (line-beginning-position)))))
                 (a2-line (save-excursion
                            (goto-char (point-min))
                            (when (search-forward "a2" nil t)
                              (line-number-at-pos (line-beginning-position))))))
            (ert-info ((format "%s" "user-message-spaced-above-and-below"))
              (should (and above-blank below-blank))
              (should (string-match-p "a2\n\nu1" (buffer-string))))
            ;; Adjacent assistant messages still stay tight (no blank line)
            (ert-info ((format "%s" "assistant-messages-remain-flush"))
              (should (and a1-line a2-line (= a2-line (1+ a1-line)))))))
      (kill-buffer buf))))

(ert-deftest dsh-emacs-test-render-user-message-beginning-of-line ()
  :tags '(dsh-unit)
  (save-window-excursion
    (with-temp-buffer
      ;; Keyboard macros run in the selected window's buffer, and exercise
      ;; command-loop point adjustment around display replacements.
      (switch-to-buffer (current-buffer))
      (dsh-emacs-mode)
      (use-local-map (copy-keymap (current-local-map)))
      (local-set-key (kbd "C-a") #'beginning-of-line)
      (dsh-emacs-render-user-message
       '((type . "user/message") (seq . 1)
         (data . ((content . [((type . "text")
                              (text . "first question\nsecond line"))])))))
      (dolist (text '("first question" "second line"))
        (goto-char (point-min))
        (search-forward text)
        (let ((start (line-beginning-position)))
          (execute-kbd-macro (kbd "C-a"))
          (should (= (point) start))
          ;; Repeated C-a must stay on the same message line.
          (execute-kbd-macro (kbd "C-a"))
          (should (= (point) start)))))))

(ert-deftest dsh-emacs-test-render-user-message-copy-line-plain-text ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-render-user-message
     '((type . "user/message") (seq . 1)
       (data . ((content . [((type . "text")
                            (text . "first question\n❯ literal prompt"))])))))
    (let ((kill-ring nil)
          (interprogram-cut-function nil)
          (interprogram-paste-function nil))
      (dolist (text '("first question" "❯ literal prompt"))
        (goto-char (point-min))
        (search-forward text)
        (copy-region-as-kill (line-beginning-position) (line-end-position))
        (should (equal (substring-no-properties (car kill-ring)) text))
        ;; Native yank, including a copy command's direct buffer-substring
        ;; path, must not transplant transcript styling or identity.
        (let ((raw (buffer-substring (line-beginning-position)
                                     (line-end-position))))
          (dolist (copied (list (car kill-ring) raw))
            (with-temp-buffer
              (insert-for-yank copied)
              (should (equal (buffer-string) text))
              (should-not (text-properties-at (point-min))))))))))

(defconst dsh-emacs-test--work-events
  '(((type . "turn/start") (seq . 100) (data . ((turn . 7))))
    ((type . "user/message") (seq . 101)
     (data . ((content . [((type . "text") (text . "Task question"))]))))
    ((type . "assistant/message") (seq . 102)
     (data . ((turn . 7) (step . 1)
              (message . ((content . [((type . "text")
                                       (text . "**Intermediate work**"))]))))))
    ((type . "tool/call") (seq . 103)
     (data . ((turn . 7) (step . 1) (callId . "work-tool")
              (name . "read") (arguments . "{\"path\":\"work.txt\"}"))))
    ((type . "assistant/message") (seq . 104)
     (data . ((turn . 7) (step . 2)
              (message . ((content . [((type . "reasoning")
                                       (text . "Final reasoning"))
                                      ((type . "text")
                                       (text . "**Final answer**"))]))))))
    ((type . "turn/end") (seq . 105)
     (data . ((turn . 7) (reason . ((kind . "completed")))))))
  "A task with opening input, intermediate work, tool and final answer.")

(ert-deftest dsh-emacs-test-render-work-details-live-and-history ()
  :tags '(dsh-unit)
  (dolist (delivery '(live history prepend))
    (with-temp-buffer
      (dsh-emacs-mode)
      (let* ((dsh-emacs-reply-footer-items nil)
             (dsh-emacs-stream-markdown-limit 1)
             (entries (mapcar (lambda (event) (list (cons 'event event)))
                              dsh-emacs-test--work-events)))
        (pcase delivery
          ('live
           (dolist (event (butlast dsh-emacs-test--work-events))
             (dsh-emacs-render-event event))
           (should-not (dsh-emacs-ui-find-block "sess-global" "work-details-7"))
           (dsh-emacs-render-event (car (last dsh-emacs-test--work-events))))
          ('history (dsh-emacs-render-history-events entries))
          ('prepend
           (dsh-emacs-render-history-events (nthcdr 4 entries))
           (should (dsh-emacs-ui-find-block "sess-global" "work-details-7"))
           (let* ((dsh-emacs--history-insert-marker
                   (dsh-emacs-render--history-prepend-marker))
                  (position (marker-position dsh-emacs--history-insert-marker)))
             (dsh-emacs-render-history-events
              (cl-subseq entries 0 4) nil 104 :insert-before position :follow-p nil)
             (set-marker dsh-emacs--history-insert-marker nil))))
        (while dsh-emacs--markdown-pending
          (dsh-emacs-render--run-markdown (current-buffer)))
        (let* ((header (dsh-emacs-ui-find-block "sess-global" "work-details-7"))
               (tool (dsh-emacs-ui-find-block "sess-global" "tool-work-tool"))
               (answer (text-property-any (point-min) (point-max)
                                          'dsh-emacs-message-seq 104)))
          (should header)
          (should tool)
          (should answer)
          (should-not (invisible-p (car header)))
          (should-not (invisible-p answer))
          (should (invisible-p (car tool)))
          (goto-char (point-min))
          (search-forward "Intermediate work")
          (should (invisible-p (1- (point))))
          (goto-char (point-min))
          (search-forward "Task question")
          (should-not (invisible-p (1- (point))))
          (let ((button (button-at (car header))))
            (should button)
            (button-activate button)
            (should (invisible-p (car tool)))
            (let* ((activity (car (plist-get (gethash 7 dsh-emacs-render--reply-turns)
                                             :activity-overlays)))
                   (control (dsh-emacs-ui-find-block
                             "sess-global" (overlay-get activity 'block-id))))
              (should control)
              (should-not (invisible-p (car control)))
              (button-activate (button-at (car control))))
            (should-not (invisible-p (car tool)))
            (should (map-elt (get-text-property (car tool) 'dsh-emacs-ui-state)
                             :collapsed))
            ;; A reconnect with no new events must retain the reader's choice.
            (dsh-emacs-render-history-events entries)
            (should-not (invisible-p (car tool)))
            (button-activate button)
            (should (invisible-p (car tool))))
          (should (= (how-many "^Completed" (point-min) (point-max)) 1))
          (dsh-emacs-render--reset-tool-tracking)
          (should-not (invisible-p (text-property-any
                                    (point-min) (point-max)
                                    'dsh-emacs-message-seq 102)))
          (should-not (dsh-emacs-ui-find-block "sess-global" "work-details-7")))))))

(ert-deftest dsh-emacs-test-render-history-publishes-settled-work-details ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (let* ((inhibit-redisplay nil)
           (entries (mapcar (lambda (event) (list (cons 'event event)))
                            dsh-emacs-test--work-events))
           (fold (symbol-function 'dsh-emacs-render--work-details))
           yielded folded)
      (cl-letf (((symbol-function 'sit-for)
                 (lambda (&rest _)
                   (setq yielded t)
                   ;; The intermediate reply exists before turn/end; it must
                   ;; not be published while its final fold is still pending.
                   (should (text-property-any (point-min) (point-max)
                                              'dsh-emacs-message-seq 102))
                   (should-not (dsh-emacs-ui-find-block
                                "sess-global" "work-details-7"))
                   (should inhibit-redisplay)))
                ((symbol-function 'dsh-emacs-render--work-details)
                 (lambda (turn state)
                   (should inhibit-redisplay)
                   (funcall fold turn state)
                   (setq folded t))))
        (dsh-emacs-render-history-events entries))
      (should yielded)
      (should folded)
      (should-not inhibit-redisplay)
      (should (= dsh-emacs--anchor-seq 105))
      (should (invisible-p (text-property-any (point-min) (point-max)
                                             'dsh-emacs-message-seq 102)))
      (should-not (invisible-p (text-property-any (point-min) (point-max)
                                                 'dsh-emacs-message-seq 104)))
      (should (dsh-emacs-ui-find-block "sess-global" "work-details-7")))))

(ert-deftest dsh-emacs-test-render-history-restores-redisplay-on-error ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (let ((inhibit-redisplay nil)
          entered)
      (cl-letf (((symbol-function 'dsh-emacs-render-event)
                 (lambda (_event)
                   (setq entered inhibit-redisplay)
                   (error "History rendering failed"))))
        (should-error
         (dsh-emacs-render-history-events
          (list (list (cons 'event (car dsh-emacs-test--work-events)))))))
      (should entered)
      (should-not inhibit-redisplay))))

(ert-deftest dsh-emacs-test-render-work-details-completion-duration ()
  :tags '(dsh-unit)
  (dolist (case '((250000 "Completed in 4m 10s")
                  (7000 "Completed in 7s")
                  (3661000 "Completed in 1h 1m 1s")
                  (-1000 "Completed") (nil "Completed")))
    (with-temp-buffer
      (dsh-emacs-mode)
      (let ((events (copy-tree dsh-emacs-test--work-events t)))
        (setf (alist-get 'time (car events)) 1000)
        (when (car case)
          (setf (alist-get 'time (car (last events))) (+ 1000 (car case))))
        (dolist (event events) (dsh-emacs-render-event event))
        (let* ((header (dsh-emacs-ui-find-block "sess-global" "work-details-7"))
               (caption (lambda ()
                          (let ((button (button-at (car header))))
                            (buffer-substring-no-properties
                             (button-start button) (- (button-end button) 2))))))
          (should (equal (funcall caption) (cadr case)))
          (button-activate (button-at (car header)))
          (should (equal (funcall caption) (cadr case))))))))

(ert-deftest dsh-emacs-test-render-work-details-partial-history ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (let ((entries (mapcar (lambda (event) (list (cons 'event event)))
                           dsh-emacs-test--work-events)))
      ;; The default message window commonly begins inside a long task.
      (dsh-emacs-render-history-events (nthcdr 3 entries))
      (let* ((state (gethash 7 dsh-emacs-render--reply-turns))
             (header (dsh-emacs-ui-find-block "sess-global" "work-details-7"))
             (overlay (plist-get state :work-overlay)))
        (should-not (plist-get state :start-seq))
        (should header)
        (should (overlay-buffer overlay))
        (should-not (invisible-p (text-property-any
                                  (point-min) (point-max)
                                  'dsh-emacs-message-seq 104)))
        (button-activate (button-at (car header)))
        (let* ((dsh-emacs--history-insert-marker
                (dsh-emacs-render--history-prepend-marker))
               (position (marker-position dsh-emacs--history-insert-marker)))
          (dsh-emacs-render-history-events
           (cl-subseq entries 0 3) nil 103 :insert-before position :follow-p nil)
          (set-marker dsh-emacs--history-insert-marker nil))
        (should (eq overlay (plist-get (gethash 7 dsh-emacs-render--reply-turns)
                                       :work-overlay)))
        (should-not (overlay-get overlay 'invisible))
        (should (= (how-many "^Completed" (point-min) (point-max)) 1))
        (setq header (dsh-emacs-ui-find-block "sess-global" "work-details-7"))
        (button-activate (button-at (car header)))
        (goto-char (point-min))
        (search-forward "Intermediate work")
        (should (invisible-p (1- (point))))
        (goto-char (point-min))
        (search-forward "Task question")
        (should-not (invisible-p (1- (point))))))))

(ert-deftest dsh-emacs-test-render-activity-summary ()
  :tags '(dsh-unit)
  (dolist (case '((nil . "Analysis completed")
                  (("read") . "Read files")
                  (("todo_write" "bash") . "Updated the plan and ran commands")
                  (("read" "bash" "grep") . "Read files, ran commands, searched code")
                  (("read" "bash" "grep" "other")
                   . "Read files, ran commands, searched code, etc.")
                  (("edit" "bash" "other" "grep")
                   . "Edited files, ran commands, called tools, etc.")
                  (("grep" "read" "read") . "Read files and searched code")
                  (("read_image") . "Read images")
                  (("file_inspect") . "Searched code")
                  (("write") . "Wrote files")
                  (("apply_patch") . "Edited files")
                  (("terminal_write") . "Ran commands")
                  (("run_code") . "Ran code")
                  (("web_search") . "Searched the web")
                  (("web_fetch") . "Visited web pages")
                  (("subagent_codex") . "Coordinated subagents")
                  (("create_goal") . "Updated the plan")
                  (("ask_user_question") . "Asked questions")))
    (should (equal (dsh-emacs-render--activity-summary
                    (cl-loop for name in (car case) for id from 1
                             collect (cons id name)))
                   (cdr case))))
  (should (equal (dsh-emacs-render--activity-summary
                  '(("a" . "read") ("a" . "read")
                    ("b" . "bash") ("c" . "bash")))
                 "Ran commands and read files")))

(ert-deftest dsh-emacs-test-render-work-details-compaction-membership ()
  :tags '(dsh-unit)
  (dolist (delivery '(live history prepend))
    (with-temp-buffer
      (dsh-emacs-mode)
      (goto-char (point-max))
      (insert "UNSENT DRAFT")
      (let* ((dsh-emacs-reply-footer-items nil)
             (final (copy-tree (nth 4 dsh-emacs-test--work-events) t))
             (events (append
                      (cl-subseq dsh-emacs-test--work-events 0 3)
                      '(((type . "tool/call") (seq . 103)
                         (data . ((turn . 7) (callId . "shell") (name . "bash")
                                  (arguments . "{\"command\":\"printf test\"}"))))
                        ((type . "tool/call") (seq . 104)
                         (data . ((turn . 7) (callId . "custom-one") (name . "custom"))))
                        ((type . "compaction/summary") (seq . 105)
                         (data . ((compactionId . "activity")
                                  (summary . [((type . "text") (text . "Compaction notes"))]))))
                        ((type . "tool/call") (seq . 106)
                         (data . ((turn . 7) (callId . "custom-two") (name . "custom")))))
                      (list final)
                      '(((type . "turn/end") (seq . 108)
                         (data . ((turn . 7) (reason . ((kind . "aborted")))))))))
             entries prior)
        (setf (alist-get 'seq final) 107)
        (setq entries (mapcar (lambda (event) (list (cons 'event event))) events))
        (pcase delivery
          ('live
           (dolist (event (butlast events)) (dsh-emacs-render-event event))
           (should-not (plist-get (gethash 7 dsh-emacs-render--reply-turns)
                                  :activity-overlays))
           (should-not (invisible-p (car (dsh-emacs-ui-find-block
                                          "sess-global" "compaction-summary-activity"))))
           (dsh-emacs-render-event (car (last events))))
          ('history (dsh-emacs-render-history-events entries))
          ('prepend
           (dsh-emacs-render-history-events (nthcdr 6 entries))
           (setq prior (car (plist-get (gethash 7 dsh-emacs-render--reply-turns)
                                       :activity-overlays)))
           (should prior)
           (dsh-emacs-ui--set-work-details-expanded prior t)
           (let* ((dsh-emacs--history-insert-marker (dsh-emacs-render--history-prepend-marker))
                  (position (marker-position dsh-emacs--history-insert-marker)))
             (dsh-emacs-render-history-events
              (cl-subseq entries 0 6) nil 106 :insert-before position :follow-p nil)
             (set-marker dsh-emacs--history-insert-marker nil))))
        (let* ((state (gethash 7 dsh-emacs-render--reply-turns))
               (groups (plist-get state :activity-overlays))
               (group (car groups))
               (compaction (dsh-emacs-ui-find-block "sess-global" "compaction-summary-activity")))
          (should (= (length groups) 1))
          (should (equal (overlay-get group 'dsh-emacs-work-label)
                         "Called tools and ran commands"))
          (should compaction)
          (should-not (plist-get state :work-overlay))
          (if (eq delivery 'prepend)
              (progn (should (eq group prior)) (should-not (invisible-p (car compaction))))
            (should (invisible-p (car compaction))))
          (dsh-emacs-ui--set-work-details-expanded group t)
          (should-not (invisible-p (car compaction)))
          (should (map-elt (get-text-property (car compaction) 'dsh-emacs-ui-state) :collapsed))
          (goto-char (car compaction))
          (dsh-emacs-ui-toggle-fragment)
          (dsh-emacs-render--work-details 7 state)
          (should (eq group (car (plist-get state :activity-overlays))))
          (should-not (overlay-get group 'invisible))
          (should (equal (overlay-get group 'dsh-emacs-work-label)
                         "Called tools and ran commands"))
          (goto-char (point-min))
          (search-forward "Compaction notes")
          (should-not (invisible-p (1- (point))))
          (should (string-suffix-p "UNSENT DRAFT" (buffer-string)))
          (let ((answer (text-property-any
                         (point-min) (point-max) 'dsh-emacs-message-seq 107)))
            (should answer)
            (should-not (invisible-p answer))))))))

(ert-deftest dsh-emacs-test-render-work-details-compaction-only ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dolist (event (append
                    (cl-subseq dsh-emacs-test--work-events 0 2)
                    '(((type . "compaction/summary") (seq . 102)
                       (data . ((compactionId . "only") (summary . []))))
                      ((type . "turn/end") (seq . 103)
                       (data . ((turn . 7) (reason . ((kind . "aborted")))))))))
      (dsh-emacs-render-event event))
    (let* ((groups (plist-get (gethash 7 dsh-emacs-render--reply-turns) :activity-overlays))
           (card (dsh-emacs-ui-find-block "sess-global" "compaction-summary-only")))
      (should (= (length groups) 1))
      (should (equal (overlay-get (car groups) 'dsh-emacs-work-label) "Analysis completed"))
      (should card)
      (should (invisible-p (car card)))
      (dsh-emacs-ui--set-work-details-expanded (car groups) t)
      (should-not (invisible-p (car card))))))

(ert-deftest dsh-emacs-test-render-work-details-activity-tail-updates ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (goto-char (point-max))
    (insert "UNSENT DRAFT")
    (dolist (event (append (cl-subseq dsh-emacs-test--work-events 0 4)
                           '(((type . "turn/end") (seq . 105)
                              (data . ((turn . 7) (reason . ((kind . "aborted")))))))))
      (dsh-emacs-render-event event))
    (let* ((state (gethash 7 dsh-emacs-render--reply-turns))
           (group (car (plist-get state :activity-overlays))))
      (should group)
      (should (equal (overlay-get group 'dsh-emacs-work-label) "Read files"))
      (dsh-emacs-ui--set-work-details-expanded group t)
      (goto-char (car (dsh-emacs-ui-find-block "sess-global" "tool-work-tool")))
      (dsh-emacs-ui-toggle-fragment)
      (dsh-emacs-render-event
       '((type . "tool/result") (seq . 106)
         (data . ((turn . 7) (step . 1)
                  (message . ((source . ((callId . "work-tool")))
                              (content . [((type . "tool-result") (isError . :json-false)
                                           (content . [((type . "text")
                                                        (text . "Late tool output"))]))])))))))
      (dsh-emacs-render--work-details 7 state)
      (should (eq group (car (plist-get state :activity-overlays))))
      (should-not (overlay-get group 'invisible))
      (let ((tool (dsh-emacs-ui-find-block "sess-global" "tool-work-tool")))
        (should tool)
        (should (<= (cdr tool) (overlay-end group))))
      (should (string-suffix-p "UNSENT DRAFT" (buffer-string)))
      (should-not (invisible-p (1- (point-max)))))))

(ert-deftest dsh-emacs-test-render-work-details-stopped-turns ()
  :tags '(dsh-unit)
  (dolist (reason '("error" "aborted" "interrupted"))
    (dolist (delivery '(live history prepend))
      (with-temp-buffer
        (dsh-emacs-mode)
        (let* ((events (append
                        (copy-tree (cl-subseq dsh-emacs-test--work-events 0 4) t)
                        (list
                         '((type . "assistant/attempt") (seq . 104)
                           (data . ((turn . 7) (step . 2) (stream . []))))
                         `((type . "turn/end") (seq . 105) (time . 5000)
                           (data . ((turn . 7)
                                    (reason . ((kind . ,reason)
                                               (error . ((message . "Provider unavailable")))))))))))
               (entries (mapcar (lambda (event) (list (cons 'event event))) events))
               (caption (if (equal reason "error") "Failed" "Stopped")))
          (setf (alist-get 'time (car events)) 1000)
          (goto-char (point-max))
          (insert "UNSENT DRAFT")
          (pcase delivery
            ('live (dolist (event events) (dsh-emacs-render-event event)))
            ('history (dsh-emacs-render-history-events entries))
            ('prepend
             (dsh-emacs-render-history-events (nthcdr 4 entries))
             (let* ((dsh-emacs--history-insert-marker
                     (dsh-emacs-render--history-prepend-marker))
                    (position (marker-position dsh-emacs--history-insert-marker)))
               (dsh-emacs-render-history-events
                (cl-subseq entries 0 4) nil 104 :insert-before position :follow-p nil)
               (set-marker dsh-emacs--history-insert-marker nil))))
          (ert-info ((format "reason=%s delivery=%s" reason delivery))
            (let* ((header (dsh-emacs-ui-find-block "sess-global" "work-details-7"))
                   (state (gethash 7 dsh-emacs-render--reply-turns))
                   (overlay (car (plist-get state :activity-overlays))))
              (should header)
              (should-not (plist-get state :work-overlay))
              (should-not (button-at (car header)))
              (should overlay)
              (should-not (plist-get state :answer-seq))
              (should-not (string-match-p
                           "4s" (buffer-substring-no-properties (car header) (cdr header))))
              (should (string-match-p (regexp-quote caption)
                                      (buffer-substring-no-properties (car header) (cdr header))))
              (should-not (invisible-p (text-property-any (point-min) (point-max)
                                                          'dsh-emacs-message-seq 102)))
              (let ((attempt (dsh-emacs-ui-find-block "sess-global" "evt-104")))
                (should attempt)
                (should-not (invisible-p (car attempt)))
                (should (invisible-p (car (dsh-emacs-ui-find-block "sess-global" "tool-work-tool")))))
              (goto-char (point-min))
              (search-forward "Task question")
              (should-not (invisible-p (1- (point))))
              (when (equal reason "error")
                (goto-char (point-min))
                (search-forward "Provider unavailable")
                (should-not (invisible-p (1- (point)))))
              (should (string-suffix-p "UNSENT DRAFT" (buffer-string)))
              (should-not (invisible-p (1- (point-max))))
              ;; A later successful round must remain outside the stopped one.
              (dsh-emacs-render-event
               '((type . "turn/start") (seq . 106) (data . ((turn . 8)))))
              (dsh-emacs-render-event
               '((type . "assistant/message") (seq . 107)
                 (data . ((turn . 8) (step . 1)
                          (message . ((content . [((type . "text")
                                                   (text . "Recovered answer"))])))))))
              (dsh-emacs-render-event
               '((type . "turn/end") (seq . 108)
                 (data . ((turn . 8) (reason . ((kind . "completed")))))))
              (should-not (invisible-p (text-property-any (point-min) (point-max)
                                                          'dsh-emacs-message-seq 107)))
              (button-activate
               (button-at (car (dsh-emacs-ui-find-block
                                "sess-global" (overlay-get overlay 'block-id)))))
              (should-not (overlay-get overlay 'invisible))
              (dsh-emacs-render-history-events entries)
              (should-not (overlay-get overlay 'invisible)))))))))

(ert-deftest dsh-emacs-test-render-work-details-interleaved-input ()
  :tags '(dsh-unit)
  (dolist (reason '("completed" "aborted"))
    (dolist (delivery '(live history prepend))
      (with-temp-buffer
        (dsh-emacs-mode)
        (let* ((final (copy-tree (nth 4 dsh-emacs-test--work-events) t))
               (end (copy-tree (nth 5 dsh-emacs-test--work-events) t))
               (events (append
                        (copy-tree (cl-subseq dsh-emacs-test--work-events 0 4) t)
                        '(((type . "user/message") (seq . 104)
                           (data . ((content . [((type . "text")
                                                 (text . "Mid-turn guidance"))]))))
                          ((type . "assistant/message") (seq . 105)
                           (data . ((turn . 7) (step . 2)
                                    (message . ((content . [((type . "text")
                                                             (text . "More work"))]))))))
                          ((type . "user/message") (seq . 106)
                           (data . ((content . [((type . "text")
                                                 (text . "Second clarification"))]))))
                          ((type . "tool/call") (seq . 107)
                           (data . ((turn . 7) (step . 3) (callId . "extra")
                                    (name . "read") (arguments . "{}")))))
                        (list final end)))
               (entries (mapcar (lambda (event) (list (cons 'event event))) events)))
          (setf (alist-get 'seq final) 108
                (alist-get 'seq end) 109
                (alist-get 'kind (alist-get 'reason (alist-get 'data end))) reason)
          (when (equal reason "aborted")
            (setf (alist-get 'type final) "assistant/attempt"))
          (pcase delivery
            ('live (dolist (event events) (dsh-emacs-render-event event)))
            ('history (dsh-emacs-render-history-events entries))
            ('prepend
             (dsh-emacs-render-history-events (nthcdr 4 entries))
             (let* ((dsh-emacs--history-insert-marker
                     (dsh-emacs-render--history-prepend-marker))
                    (position (marker-position dsh-emacs--history-insert-marker)))
               (dsh-emacs-render-history-events
                (cl-subseq entries 0 4) nil 104 :insert-before position :follow-p nil)
               (set-marker dsh-emacs--history-insert-marker nil))))
          (ert-info ((format "reason=%s delivery=%s" reason delivery))
            (let* ((state (gethash 7 dsh-emacs-render--reply-turns))
                   (groups (plist-get state :activity-overlays))
                   (header (dsh-emacs-ui-find-block "sess-global" "work-details-7")))
              (should header)
              (should-not (button-at (car header)))
              (should-not (plist-get state :work-overlay))
              (should (= (length groups) 2))
              (dolist (seq '(102 105))
                (should-not (invisible-p (text-property-any (point-min) (point-max)
                                                            'dsh-emacs-message-seq seq))))
              (dolist (id '("tool-work-tool" "tool-extra"))
                (should (invisible-p (car (dsh-emacs-ui-find-block "sess-global" id)))))
              (dolist (text '("Task question" "Mid-turn guidance" "Second clarification"))
                (goto-char (point-min))
                (search-forward text)
                (should-not (invisible-p (1- (point))))
                (should-not (invisible-p (point))))
              (when (equal reason "completed")
                (should-not (invisible-p (text-property-any (point-min) (point-max)
                                                            'dsh-emacs-message-seq 108))))
              ;; Search opens only the matching activity, not the whole turn.
              (funcall (overlay-get (cadr groups) 'isearch-open-invisible) (cadr groups))
              (should (overlay-get (car groups) 'invisible))
              (should-not (overlay-get (cadr groups) 'invisible))
              (dsh-emacs-render--work-details 7 state)
              (should (eq (cadr groups) (cadr (plist-get state :activity-overlays))))
              (should-not (overlay-get (cadr groups) 'invisible))
              (dsh-emacs-ui-expand-all)
              (should-not (overlay-get (car groups) 'invisible))
              (dsh-emacs-ui-collapse-all)
              (should (overlay-get (car groups) 'invisible))
              (should-not (invisible-p (text-property-any (point-min) (point-max)
                                                          'dsh-emacs-message-seq 105)))
              (dsh-emacs-render--release-work-details state)
              (should-not (dsh-emacs-ui-find-block "sess-global" "work-details-7"))
              (should-not (cl-find-if
                           (lambda (candidate)
                             (overlay-get candidate 'isearch-open-invisible))
                           (overlays-in (point-min) (point-max)))))))))))

(ert-deftest dsh-emacs-test-render-work-details-eligibility ()
  :tags '(dsh-unit)
  (dolist (case '(disabled active forked unknown
                           no-final later-step later-tool))
    (with-temp-buffer
      (dsh-emacs-mode)
      (let* ((dsh-emacs-fold-work-details (not (eq case 'disabled)))
             (events (copy-tree dsh-emacs-test--work-events t))
             (end (car (last events)))
             (final (nth 4 events)))
        (pcase case
          ('active (setq events (butlast events)))
          ((or 'forked 'unknown)
           (setf (alist-get 'reason (alist-get 'data end))
                 (list (cons 'kind (symbol-name case)))))
          ('no-final
           (setf (alist-get 'content (alist-get 'message (alist-get 'data final)))
                 [((type . "reasoning") (text . "No final prose"))]))
          ((or 'later-step 'later-tool)
           (setf (alist-get 'seq end) 107)
           (setq events
                 (append (butlast events)
                         (list (if (eq case 'later-step)
                                   '((type . "step/start") (seq . 106)
                                     (data . ((turn . 7) (step . 3))))
                                 '((type . "tool/call") (seq . 106)
                                   (data . ((turn . 7) (step . 3)
                                            (callId . "later") (name . "read")
                                            (arguments . "{}"))))))
                         (list end)))))
        (dolist (event events) (dsh-emacs-render-event event))
        (ert-info ((format "Fold eligibility: %s" case))
          (let ((foldable (memq case '(no-final later-step later-tool)))
                (header (dsh-emacs-ui-find-block "sess-global" "work-details-7")))
            (should (eq (not (null header)) (not (null foldable))))
            (goto-char (point-min))
            (search-forward "Intermediate work")
            (should (eq (not (null (invisible-p (1- (point)))))
                        (not (null foldable))))))))))

(ert-deftest dsh-emacs-test-render-work-details-stream-keeps-final-and-draft ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (let ((dsh-emacs-stream-markdown-limit 1))
      (dolist (event (cl-subseq dsh-emacs-test--work-events 0 4))
        (dsh-emacs-render-event event))
      (dsh-emacs-render-event
       '((type . "assistant/chunk") (seq . 104)
         (data . ((turn . 7) (step . 2)
                  (chunk . ((type . "reasoning-delta") (index . 0)
                            (text . "Final reasoning")))))))
      (dsh-emacs-render-event
       '((type . "assistant/chunk") (seq . 105)
         (data . ((turn . 7) (step . 2)
                  (chunk . ((type . "text-delta") (index . 1)
                            (text . "**Final answer**")))))))
      (dsh-emacs-render--flush-stream)
      (let ((final (copy-tree (nth 4 dsh-emacs-test--work-events) t))
            (end (copy-tree (nth 5 dsh-emacs-test--work-events) t)))
        (setf (alist-get 'seq final) 106
              (alist-get 'seq end) 107)
        (dsh-emacs-render-event final)
        (dsh-emacs-render-event end))
      (while dsh-emacs--markdown-pending
        (dsh-emacs-render--run-markdown (current-buffer)))
      (should (dsh-emacs-ui-find-block "sess-global" "work-details-7"))
      (goto-char (point-min))
      (search-forward "Final answer")
      (should-not (invisible-p (1- (point))))
      (goto-char (point-min))
      (search-forward "Think")
      (should (invisible-p (1- (point))))
      (goto-char (point-min))
      (search-forward "Copy")
      (should-not (invisible-p (1- (point))))
      (goto-char (point-max))
      (insert "Unsent draft")
      (should-not (invisible-p (1- (point))))
      (dsh-emacs-render-event
       '((type . "user/message") (seq . 108)
         (data . ((content . [((type . "text") (text . "Next task"))])))))
      (goto-char (point-min))
      (search-forward "Next task")
      (should-not (invisible-p (1- (point))))
      (should (string-suffix-p "Unsent draft" (buffer-string))))))

(ert-deftest dsh-emacs-test-render-work-details-trim-releases-overlay ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dolist (event dsh-emacs-test--work-events)
      (dsh-emacs-render-event event))
    (let* ((state (gethash 7 dsh-emacs-render--reply-turns))
           (overlay (plist-get state :work-overlay))
           (origin (plist-get state :work-start))
           (dsh-emacs-max-buffer-size 30))
      (should (overlay-buffer overlay))
      (dsh-emacs-render--trim-buffer)
      (should-not (overlay-buffer overlay))
      (should-not (marker-buffer origin))
      (should-not (dsh-emacs-ui-find-block "sess-global" "work-details-7"))
      (should-not (invisible-p dsh-emacs--input-marker)))))

(ert-deftest dsh-emacs-test-render-work-details-trim-keeps-tool-only-owner ()
  :tags '(dsh-unit)
  (dolist (reason '("completed" "aborted"))
    (dolist (cleanup '(reset disable))
      (with-temp-buffer
        (dsh-emacs-mode)
        (let ((dsh-emacs-max-buffer-size nil)
              (dsh-emacs-fold-work-details t))
          (dsh-emacs-render-event
           `((type . "user/message") (seq . 1)
             (data (content . [((type . "text")
                                (text . ,(make-string 20000 ?x)))]))))
          (dolist (event
                   (list (nth 0 dsh-emacs-test--work-events)
                         (nth 3 dsh-emacs-test--work-events)
                         `((type . "turn/end") (seq . 105)
                           (data (turn . 7) (reason (kind . ,reason))))))
            (dsh-emacs-render-event event))
          (let* ((state (gethash 7 dsh-emacs-render--reply-turns))
                 (groups (plist-get state :activity-overlays))
                 (outer (plist-get state :work-overlay))
                 (group (car groups))
                 (group-id (overlay-get group 'block-id)))
            (should-not (plist-get state :reply-seq))
            (should (overlay-buffer group))
            (let ((dsh-emacs-max-buffer-size 15000))
              (dsh-emacs-render--trim-buffer))
            (should (> (plist-get state :work-start) (point-min)))
            (should (eq state (gethash 7 dsh-emacs-render--reply-turns)))
            (should (eq groups (plist-get state :activity-overlays)))
            (should (overlay-buffer group))
            (pcase cleanup
              ('reset (dsh-emacs-render--reset-tool-tracking))
              ('disable
               (let ((dsh-emacs-fold-work-details nil))
                 (dsh-emacs-render--work-details
                  7 (gethash 7 dsh-emacs-render--reply-turns)))))
            (should-not (overlay-buffer group))
            (should-not (and outer (overlay-buffer outer)))
            (should-not (dsh-emacs-ui-find-block "sess-global" group-id))
            (should-not (dsh-emacs-ui-find-block
                         "sess-global" "work-details-7"))))))))

(ert-deftest dsh-emacs-test-render-work-details-no-empty-control ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (let ((final (copy-tree (nth 4 dsh-emacs-test--work-events) t)))
      (setf (alist-get 'content (alist-get 'message (alist-get 'data final)))
            [((type . "text") (text . "Just the answer"))])
      (dolist (event (list (nth 0 dsh-emacs-test--work-events)
                           (nth 1 dsh-emacs-test--work-events) final
                           (nth 5 dsh-emacs-test--work-events)))
        (dsh-emacs-render-event event))
      (let ((header (dsh-emacs-ui-find-block "sess-global" "work-details-7")))
        (should header)
        (should-not (button-at (car header))))
      (goto-char (point-min))
      (search-forward "Just the answer")
      (should-not (invisible-p (1- (point)))))))

(ert-deftest dsh-emacs-test-render-work-details-independent-turns ()
  :tags '(dsh-unit)
  (dolist (footers '(nil (copy)))
    (with-temp-buffer
      (dsh-emacs-mode)
      (let* ((dsh-emacs-reply-footer-items footers)
             (second (copy-tree dsh-emacs-test--work-events t)))
        (dolist (event second)
          (cl-incf (alist-get 'seq event) 100)
          (when (alist-get 'turn (alist-get 'data event))
            (setf (alist-get 'turn (alist-get 'data event)) 8)))
        (setf (alist-get 'callId (alist-get 'data (nth 3 second))) "second-tool")
        (dsh-emacs-render-history-events
         (mapcar (lambda (event) (list (cons 'event event)))
                 (append dsh-emacs-test--work-events second)))
        (let* ((first (gethash 7 dsh-emacs-render--reply-turns))
               (second (gethash 8 dsh-emacs-render--reply-turns))
               (one (plist-get first :work-overlay))
               (two (plist-get second :work-overlay)))
          (should (overlay-buffer one))
          (should (overlay-buffer two))
          (should (< (overlay-end one) (overlay-start two)))
          (dolist (seq '(104 204))
            (should-not (invisible-p (text-property-any
                                      (point-min) (point-max)
                                      'dsh-emacs-message-seq seq))))
          (let ((header (dsh-emacs-ui-find-block "sess-global" "work-details-7")))
            (button-activate (button-at (car header))))
          (should-not (invisible-p (overlay-start one)))
          (should (invisible-p (overlay-start two))))))))

(defun dsh-emacs-test--render-trigger-splice
    (seq target removed &optional outcome entries)
  "Return an `agent/inbox/spliced' event at SEQ for TARGET.
REMOVED is the removed count, OUTCOME an optional wire outcome, and ENTRIES
a list of (ID KIND TEXT) inserted messages."
  (list (cons 'type "agent/inbox/spliced") (cons 'seq seq)
        (cons 'data
              (append
               (list (cons 'target target) (cons 'start 0))
               (when removed (list (cons 'removedCount removed)))
               (when outcome (list (cons 'outcome outcome)))
               (list
                (cons 'inserted
                      (vconcat
                       (mapcar
                        (lambda (entry)
                          (list (cons 'id (nth 0 entry))
                                (cons 'source
                                      (list (cons 'kind (nth 1 entry))))
                                (cons 'content
                                      (vector
                                       (list (cons 'type "text")
                                             (cons 'text (nth 2 entry)))))))
                        entries))))))))

(defun dsh-emacs-test--render-trigger-message
    (seq id kind text &optional provider)
  "Return a `user/message' for ID at SEQ with source KIND and body TEXT.
PROVIDER is recorded on the source for webhook titles."
  (let ((source (append (list (cons 'kind kind))
                        (when provider (list (cons 'provider provider))))))
    (list (cons 'type "user/message") (cons 'seq seq)
          (cons 'data
                (list (cons 'id id) (cons 'source source)
                      (cons 'content
                            (vector (list (cons 'type "text")
                                          (cons 'text text)))))))))

(defun dsh-emacs-test--turn-trigger-events
    (seq turn time kind &optional provider process)
  "Return events from SEQ for TURN woken by a claimed KIND notice.
PROVIDER distinguishes a GitHub webhook; PROCESS adds a settled Think block
so the turn owns a foldable activity."
  (let* ((text (format "%s notice body" (or provider kind)))
         (id (format "notice-%s-%s" turn (or provider kind))))
    (list
     (dsh-emacs-test--render-trigger-splice
      seq "next-turn" nil nil (list (list id kind text)))
     (list (cons 'type "turn/start") (cons 'seq (1+ seq)) (cons 'time time)
           (cons 'data (list (cons 'turn turn))))
     (dsh-emacs-test--render-trigger-splice (+ seq 2) "next-turn" 1)
     (list (cons 'type "step/start") (cons 'seq (+ seq 3)) (cons 'time time)
           (cons 'data (list (cons 'turn turn) (cons 'step 1))))
     (dsh-emacs-test--render-trigger-message (+ seq 4) id kind text provider)
     (list (cons 'type "assistant/message") (cons 'seq (+ seq 5))
           (cons 'time (+ time 1000))
           (cons 'data
                 (list (cons 'turn turn) (cons 'step 1)
                       (cons 'message
                             (list
                              (cons 'content
                                    (vconcat
                                     (when process
                                       (vector (list (cons 'type "reasoning")
                                                     (cons 'text "checked"))))
                                     (vector
                                      (list (cons 'type "text")
                                            (cons 'text
                                                  (format "Answer for %s."
                                                          (or provider
                                                              kind))))))))))))
     (list (cons 'type "turn/end") (cons 'seq (+ seq 6))
           (cons 'time (+ time 2000))
           (cons 'data (list (cons 'turn turn)
                             (cons 'reason
                                   (list (cons 'kind "completed")))))))))

(defun dsh-emacs-test--human-turn-events (seq turn time)
  "Return events from SEQ for a plain human TURN with one answer."
  (list
   (list (cons 'type "turn/start") (cons 'seq seq) (cons 'time time)
         (cons 'data (list (cons 'turn turn))))
   (list (cons 'type "step/start") (cons 'seq (1+ seq)) (cons 'time time)
         (cons 'data (list (cons 'turn turn) (cons 'step 1))))
   (list (cons 'type "user/message") (cons 'seq (+ seq 2)) (cons 'time time)
         (cons 'data
               (list (cons 'id (format "human-%s" turn))
                     (cons 'source (list (cons 'kind "user")))
                     (cons 'content
                           (vector (list (cons 'type "text")
                                         (cons 'text "Question")))))))
   (list (cons 'type "assistant/message") (cons 'seq (+ seq 3))
         (cons 'time (+ time 500))
         (cons 'data
               (list (cons 'turn turn) (cons 'step 1)
                     (cons 'message
                           (list (cons 'content
                                       (vector
                                        (list (cons 'type "text")
                                              (cons 'text
                                                    "Earlier answer.")))))))))
   (list (cons 'type "turn/end") (cons 'seq (+ seq 4))
         (cons 'time (+ time 1000))
         (cons 'data (list (cons 'turn turn)
                           (cons 'reason (list (cons 'kind "completed"))))))))

(ert-deftest dsh-emacs-test-render-turn-trigger-notice ()
  :tags '(dsh-unit)
  (dolist (delivery '(live history prepend reconnect))
    (with-temp-buffer
      (dsh-emacs-mode)
      (setq-local dsh-emacs--buffer-session "turn-trigger")
      (let* ((dsh-emacs-reply-footer-items nil)
             (base 1793007494000)
             (early (dsh-emacs-test--human-turn-events 1 1 base))
             (wake (dsh-emacs-test--turn-trigger-events
                    10 2 (+ base 2000) "agent-message" nil t))
             (events (append early wake))
             (entries (mapcar (lambda (event) (list (cons 'event event)))
                              events)))
        (pcase delivery
          ('live (dolist (event events) (dsh-emacs-render-event event)))
          ('history (dsh-emacs-render-history-events entries))
          ('prepend
           ;; Render the woken turn first, then page the earlier turn above it.
           (dsh-emacs-render-history-events (nthcdr (length early) entries))
           (let* ((dsh-emacs--history-insert-marker
                   (dsh-emacs-render--history-prepend-marker))
                  (position (marker-position dsh-emacs--history-insert-marker)))
             (dsh-emacs-render-history-events
              (cl-subseq entries 0 (length early)) nil 10
              :insert-before position :follow-p nil)
             (set-marker dsh-emacs--history-insert-marker nil)))
          ('reconnect
           (dsh-emacs-render-history-events entries)
           (dsh-emacs-render-history-events entries)))
        (ert-info ((format "turn-trigger-%s" delivery))
          (should (string-match-p "Earlier answer\\." (buffer-string)))
          (should (string-match-p "Answer for agent-message\\."
                                  (buffer-string)))
          (should (= (how-many "Task message received"
                               (point-min) (point-max))
                     1))
          ;; Folded by default: the model-facing notice body is not shown.
          (should-not (string-match-p "agent-message notice body"
                                      (buffer-string)))
          (goto-char (point-min))
          (search-forward "Task message received")
          (let ((trigger (match-beginning 0)))
            (should-not (invisible-p trigger))
            ;; The trigger stays above the settled turn's own disclosure.
            (goto-char trigger)
            (search-forward "Completed in")
            (should (< trigger (match-beginning 0)))
            (let* ((state (gethash 2 dsh-emacs-render--reply-turns))
                   (overlay (plist-get state :work-overlay)))
              (should overlay)
              (should (< trigger (overlay-start overlay)))
              ;; The settled work is hidden; the attribution row is not.
              (should (invisible-p (overlay-start overlay))))
            ;; Expanding restores the recorded notice; the answer stays.
            (goto-char trigger)
            (dsh-emacs-ui-toggle-fragment)
            (should (string-match-p "agent-message notice body"
                                    (buffer-string)))
            (should (string-match-p "Answer for agent-message\\."
                                    (buffer-string)))
            (should (= (how-many "Task message received"
                                 (point-min) (point-max))
                       1))))))))

(ert-deftest dsh-emacs-test-render-turn-trigger-opening-batch ()
  :tags '(dsh-unit)
  ;; The opening batch is the non-canceled claims between turn/start and the
  ;; first step/start.  A hidden injection spends a slot, not the attribution.
  (with-temp-buffer
    (dsh-emacs-mode)
    (let ((base 1793007494000))
      (dolist (event
               (list
                (list (cons 'type "turn/start") (cons 'seq 1)
                      (cons 'time base) (cons 'data (list (cons 'turn 1))))
                (dsh-emacs-test--render-trigger-splice 2 "next-step" 1)
                (dsh-emacs-test--render-trigger-splice 3 "next-turn" 1)
                (list (cons 'type "step/start") (cons 'seq 4)
                      (cons 'time base)
                      (cons 'data (list (cons 'turn 1) (cons 'step 1))))
                (dsh-emacs-test--render-trigger-message
                 5 "ctx-1" "agent-instructions" "hidden context body")
                (dsh-emacs-test--render-trigger-message
                 6 "wake-1" "agent-message" "wake body")))
        (dsh-emacs-render-event event))
      (should (= (how-many "Task message received" (point-min) (point-max))
                 1))
      (should-not (string-match-p "hidden context body" (buffer-string)))
      (should-not (string-match-p "wake body" (buffer-string))))
    ;; A later step's claim is not part of the opening batch.
    (with-temp-buffer
      (dsh-emacs-mode)
      (let ((base 1793007494000))
        (dolist (event
                 (list
                  (list (cons 'type "turn/start") (cons 'seq 1)
                        (cons 'time base)
                        (cons 'data (list (cons 'turn 1))))
                  (dsh-emacs-test--render-trigger-splice 2 "next-step" 1)
                  (list (cons 'type "step/start") (cons 'seq 3)
                        (cons 'time base)
                        (cons 'data (list (cons 'turn 1) (cons 'step 1))))
                  (dsh-emacs-test--render-trigger-message
                   4 "ctx-1" "agent-instructions" "hidden context body")
                  (list (cons 'type "step/end") (cons 'seq 5)
                        (cons 'time base)
                        (cons 'data (list (cons 'turn 1) (cons 'step 1))))
                  (dsh-emacs-test--render-trigger-splice 6 "next-step" 1)
                  (list (cons 'type "step/start") (cons 'seq 7)
                        (cons 'time base)
                        (cons 'data (list (cons 'turn 1) (cons 'step 2))))
                  (dsh-emacs-test--render-trigger-message
                   8 "steer-1" "agent-message" "steer body")))
          (dsh-emacs-render-event event))
        (should-not (string-match-p "Task message received"
                                    (buffer-string)))
        (should-not (string-match-p "steer body" (buffer-string)))))))

(ert-deftest dsh-emacs-test-render-turn-trigger-prepend-keeps-tail-state ()
  :tags '(dsh-unit)
  ;; A prepended page must not clear the live tail's attribution state.
  (with-temp-buffer
    (dsh-emacs-mode)
    (setq-local dsh-emacs--buffer-session "turn-trigger-prepend")
    (let ((base 1793007494000))
      ;; A settled page gives the buffer a prepend anchor.
      (dsh-emacs-render-history-events
       (mapcar (lambda (event) (list (cons 'event event)))
               (dsh-emacs-test--human-turn-events 1 1 base)))
      ;; The tail starts a turn and lost only the queue insertion.
      (dolist (event
               (list
                (list (cons 'type "turn/start") (cons 'seq 10)
                      (cons 'time base) (cons 'data (list (cons 'turn 2))))
                (dsh-emacs-test--render-trigger-splice 11 "next-turn" 1)
                (list (cons 'type "step/start") (cons 'seq 12)
                      (cons 'time base)
                      (cons 'data (list (cons 'turn 2) (cons 'step 1))))))
        (dsh-emacs-render-event event))
      (let* ((entries
              (mapcar (lambda (event) (list (cons 'event event)))
                      (dsh-emacs-test--human-turn-events 30 3 base)))
             (dsh-emacs--history-insert-marker
              (dsh-emacs-render--history-prepend-marker))
             (position (marker-position dsh-emacs--history-insert-marker)))
        (dsh-emacs-render-history-events entries nil 100
                                         :insert-before position
                                         :follow-p nil)
        (set-marker dsh-emacs--history-insert-marker nil))
      ;; The tail's turn bound and its claim slot survive the older page.
      (should (= dsh-emacs-render--turn-start-seq 10))
      (should (= dsh-emacs-render--turn-claim-slots 1))
      (dsh-emacs-render-event
       (dsh-emacs-test--render-trigger-message
        13 "tail-wake" "agent-message" "tail body"))
      (should (= (how-many "Task message received" (point-min) (point-max))
                 1))
      (should-not (string-match-p "tail body" (buffer-string))))))

(ert-deftest dsh-emacs-test-render-turn-trigger-idle-steer ()
  :tags '(dsh-unit)
  (dolist (case '(step-1 step-2 human-batch next-turn-claim
                  claim-before-turn missing-step))
    (with-temp-buffer
      (dsh-emacs-mode)
      (let* ((base 1793007494000)
             (id "idle-notice")
             (message (dsh-emacs-test--render-trigger-message
                       6 id "agent-message" "idle notice body"))
             (events
              (pcase case
                ('claim-before-turn
                 (list
                  (dsh-emacs-test--render-trigger-splice
                   1 "next-step" nil nil (list (list id "agent-message"
                                                      "idle notice body")))
                  (dsh-emacs-test--render-trigger-splice 2 "next-step" 1)
                  (list (cons 'type "turn/start") (cons 'seq 3)
                        (cons 'time base) (cons 'data (list (cons 'turn 1))))
                  (list (cons 'type "step/start") (cons 'seq 4)
                        (cons 'time base)
                        (cons 'data (list (cons 'turn 1) (cons 'step 1))))
                  message))
                ('next-turn-claim
                 (list
                  (dsh-emacs-test--render-trigger-splice
                   1 "next-turn" nil nil '(("other" "agent-message" "other")))
                  (list (cons 'type "turn/start") (cons 'seq 2)
                        (cons 'time base) (cons 'data (list (cons 'turn 1))))
                  (dsh-emacs-test--render-trigger-splice 3 "next-turn" 1)
                  (dsh-emacs-test--render-trigger-splice
                   4 "next-step" nil nil (list (list id "agent-message"
                                                      "idle notice body")))
                  (dsh-emacs-test--render-trigger-splice 5 "next-step" 1)
                  (list (cons 'type "step/start") (cons 'seq 6)
                        (cons 'time base)
                        (cons 'data (list (cons 'turn 1) (cons 'step 1))))
                  (dsh-emacs-test--render-trigger-message
                   7 id "agent-message" "idle notice body")))
                (_
                 (append
                  (list
                   (list (cons 'type "turn/start") (cons 'seq 1)
                         (cons 'time base) (cons 'data (list (cons 'turn 1))))
                   (when (not (eq case 'missing-step))
                     (list (cons 'type "step/start") (cons 'seq 2)
                           (cons 'time base)
                           (cons 'data (list (cons 'turn 1)
                                             (cons 'step
                                                   (if (eq case 'step-2) 2 1))))))
                   (dsh-emacs-test--render-trigger-splice
                    3 "next-step" nil nil
                    (if (eq case 'human-batch)
                        (list (list id "agent-message" "idle notice body")
                              (list "human-1" "user" "human steer body"))
                      (list (list id "agent-message" "idle notice body"))))
                   (dsh-emacs-test--render-trigger-splice
                    4 "next-step" (if (eq case 'human-batch) 2 1)))
                  (list message))))))
        (dolist (event events)
          (dsh-emacs-render-event event))
        (ert-info ((format "turn-trigger-idle-steer-%s" case))
          (should-not (string-match-p "idle notice body" (buffer-string)))
          (if (eq case 'step-1)
              (should (string-match-p "Task message received"
                                      (buffer-string)))
            (should-not (string-match-p "Task message received"
                                        (buffer-string)))))))))

(ert-deftest dsh-emacs-test-render-turn-trigger-truncated-claim ()
  :tags '(dsh-unit)
  ;; A page can begin at turn/start, keeping the claim but losing the inbox
  ;; insertion; the turn's first known waking input still gets its row.
  (dolist (case '(("agent-message" . t) ("user" . nil)
                  ("runtime-context" . nil)))
    (with-temp-buffer
      (dsh-emacs-mode)
      (let* ((base 1793007494000)
             (events
              (list
               (list (cons 'type "turn/start") (cons 'seq 1)
                     (cons 'time base) (cons 'data (list (cons 'turn 1))))
               (dsh-emacs-test--render-trigger-splice 2 "next-turn" 1)
               (list (cons 'type "step/start") (cons 'seq 3)
                     (cons 'time base)
                     (cons 'data (list (cons 'turn 1) (cons 'step 1))))
               (dsh-emacs-test--render-trigger-message
                4 "notice-1" (car case) "truncated body")
               ;; A later notice is not the opener, so it stays hidden.
               (dsh-emacs-test--render-trigger-message
                5 "notice-2" "agent-message" "later body")
               (list (cons 'type "assistant/message") (cons 'seq 6)
                     (cons 'time (+ base 1000))
                     (cons 'data
                           (list (cons 'turn 1) (cons 'step 1)
                                 (cons 'message
                                       (list (cons 'content
                                                   (vector
                                                    (list (cons 'type "text")
                                                          (cons 'text
                                                                "Answer.")))))))))
               (list (cons 'type "turn/end") (cons 'seq 7)
                     (cons 'time (+ base 2000))
                     (cons 'data (list (cons 'turn 1)
                                       (cons 'reason
                                             (list (cons 'kind
                                                         "completed")))))))))
        (dolist (event events)
          (dsh-emacs-render-event event))
        (ert-info ((format "turn-trigger-truncated-%s" (car case)))
          (should (eq (and (string-match-p "Task message received"
                                           (buffer-string))
                           t)
                      (cdr case)))
          (unless (equal (car case) "user")
            (should-not (string-match-p "truncated body" (buffer-string))))
          (should-not (string-match-p "later body" (buffer-string)))))))
  ;; A complete claim that names another id cannot use the opener fallback.
  (with-temp-buffer
    (dsh-emacs-mode)
    (let ((base 1793007494000))
      (dolist (event
               (list
                (dsh-emacs-test--render-trigger-splice
                 1 "next-turn" nil nil
                 '(("other" "agent-message" "other body")))
                (list (cons 'type "turn/start") (cons 'seq 2)
                      (cons 'time base) (cons 'data (list (cons 'turn 1))))
                (dsh-emacs-test--render-trigger-splice 3 "next-turn" 1)
                (list (cons 'type "step/start") (cons 'seq 4)
                      (cons 'time base)
                      (cons 'data (list (cons 'turn 1) (cons 'step 1))))
                (dsh-emacs-test--render-trigger-message
                 5 "unclaimed" "agent-message" "unclaimed body")))
        (dsh-emacs-render-event event))
      (should-not (string-match-p "Task message received" (buffer-string)))
      (should-not (string-match-p "unclaimed body" (buffer-string))))))

(ert-deftest dsh-emacs-test-render-turn-trigger-source-titles ()
  :tags '(dsh-unit)
  (dolist (case '(("agent-message" nil "Task message received")
                  ("team-message" nil "Team message received")
                  ("subagent-settled" nil "Subtask status updated")
                  ("webhook" "github" "GitHub event received")
                  ("webhook" "custom" "External event received")
                  ("webhook" nil "External event received")
                  ("schedule" nil "Automation task")
                  ("tool-jobs" nil "Background task updated")
                  ("cordis-host-runner" nil "Plugin status updated")
                  ("custom-extension" nil "Execution requested")))
    (with-temp-buffer
      (dsh-emacs-mode)
      (dolist (event (dsh-emacs-test--turn-trigger-events
                      1 1 1793007494000 (nth 0 case) (nth 1 case)))
        (dsh-emacs-render-event event))
      (ert-info ((format "turn-trigger-title-%s" case))
        (let ((title (nth 2 case)))
          (should (string-match-p (regexp-quote title) (buffer-string)))
          (should (= (how-many (regexp-quote title) (point-min) (point-max))
                     1))
          (goto-char (point-min))
          (search-forward title)
          (let ((trigger (match-beginning 0)))
            (should-not (invisible-p trigger))
            (goto-char trigger)
            (search-forward "Completed in")
            ;; A turn whose only process is the waking notice has nothing to
            ;; disclose; dsh web renders the disabled Completed row after the
            ;; trigger, not an orphan row before it.
            (should (< trigger (match-beginning 0)))
            (should-not (get-text-property (match-beginning 0)
                                           'dsh-emacs-work-details))
            (should-not (plist-get
                         (gethash 1 dsh-emacs-render--reply-turns)
                         :work-overlay))))))))

(ert-deftest dsh-emacs-test-render-turn-trigger-requires-claim ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dolist (event
             (list
              ;; Queued for the next turn but never claimed: not a trigger.
              (dsh-emacs-test--render-trigger-splice
               1 "next-turn" nil nil '(("n1" "agent-message" "unclaimed body")))
              (dsh-emacs-test--render-trigger-message
               2 "n1" "agent-message" "unclaimed body")
              ;; A canceled claim admits nothing.
              (dsh-emacs-test--render-trigger-splice
               3 "next-turn" nil nil '(("n2" "agent-message" "canceled body")))
              (dsh-emacs-test--render-trigger-splice 4 "next-turn" 1 "canceled")
              (dsh-emacs-test--render-trigger-message
               5 "n2" "agent-message" "canceled body")
              ;; Requeued work is not the claim that opened the turn.
              (dsh-emacs-test--render-trigger-splice
               6 "next-turn" nil nil '(("n3" "agent-message" "requeued body")))
              (dsh-emacs-test--render-trigger-splice 7 "next-turn" 1)
              (dsh-emacs-test--render-trigger-splice
               8 "next-turn" nil nil '(("n3" "agent-message" "requeued body")))
              (dsh-emacs-test--render-trigger-message
               9 "n3" "agent-message" "requeued body")
              ;; A next-step admission without a step location is not a
              ;; turn trigger (the idle-steer rule needs step 1).
              (dsh-emacs-test--render-trigger-splice
               10 "next-step" nil nil '(("n4" "agent-message" "steered body")))
              (dsh-emacs-test--render-trigger-splice 11 "next-step" 1)
              (dsh-emacs-test--render-trigger-message
               12 "n4" "agent-message" "steered body")
              ;; A human message keeps its conversation bubble.
              (dsh-emacs-test--render-trigger-splice
               13 "next-turn" nil nil '(("h1" "user" "human body")))
              (dsh-emacs-test--render-trigger-splice 14 "next-turn" 1)
              (dsh-emacs-test--render-trigger-message 15 "h1" "user" "human body")
              ;; The goal round keeps its own notice.
              (dsh-emacs-test--render-trigger-splice
               16 "next-turn" nil nil '(("g1" "goal" "goal body")))
              (dsh-emacs-test--render-trigger-splice 17 "next-turn" 1)
              (dsh-emacs-test--render-trigger-message 18 "g1" "goal" "goal body")
              ;; The claimed agent message is the only trigger.
              (dsh-emacs-test--render-trigger-splice
               19 "next-turn" nil nil '(("n5" "agent-message" "waking body")))
              (dsh-emacs-test--render-trigger-splice 20 "next-turn" 1)
              (dsh-emacs-test--render-trigger-message
               21 "n5" "agent-message" "waking body")))
      (dsh-emacs-render-event event))
    (ert-info ((format "%s" "turn-trigger-only-next-turn-claims"))
      (should (string-match-p "human body" (buffer-string)))
      (should (string-match-p "Continuing goal" (buffer-string)))
      (should (= (how-many "Task message received" (point-min) (point-max)) 1))
      (dolist (hidden '("unclaimed body" "canceled body" "requeued body"
                        "steered body" "waking body"))
        (should-not (string-match-p hidden (buffer-string)))))))

(ert-deftest dsh-emacs-test-render-work-details-prepend-during-active-task ()
  :tags '(dsh-unit)
  (dolist (human-input '(t nil))
    (with-temp-buffer
      (dsh-emacs-mode)
      (let ((older (copy-tree dsh-emacs-test--work-events t)))
        (dolist (event older)
          (cl-decf (alist-get 'seq event) 50)
          (when (alist-get 'turn (alist-get 'data event))
            (setf (alist-get 'turn (alist-get 'data event)) 6)))
        (setf (alist-get 'callId (alist-get 'data (nth 3 older))) "older-tool")
        (unless human-input
          (setq older (cl-remove-if
                       (lambda (event)
                         (equal (alist-get 'type event) "user/message"))
                       older)))
        (dolist (event (cl-subseq dsh-emacs-test--work-events 0 4))
          (unless (and (not human-input)
                       (equal (alist-get 'type event) "user/message"))
            (dsh-emacs-render-event event)))
        (let* ((dsh-emacs--history-insert-marker
                (dsh-emacs-render--history-prepend-marker))
               (position (marker-position dsh-emacs--history-insert-marker)))
          (dsh-emacs-render-history-events
           (mapcar (lambda (event) (list (cons 'event event))) older)
           nil 100 :insert-before position :follow-p nil)
          (set-marker dsh-emacs--history-insert-marker nil))
        (dolist (event (nthcdr 4 dsh-emacs-test--work-events))
          (dsh-emacs-render-event event))
        (should (dsh-emacs-ui-find-block "sess-global" "work-details-7"))
        (dolist (seq '(54 104))
          (should-not (invisible-p (text-property-any
                                    (point-min) (point-max)
                                    'dsh-emacs-message-seq seq))))
        (should (< (overlay-end (plist-get
                                (gethash 6 dsh-emacs-render--reply-turns)
                                :work-overlay))
                   (overlay-start (plist-get
                                  (gethash 7 dsh-emacs-render--reply-turns)
                                  :work-overlay))))))))

;; Reply footers summarize a turn, not the session or just its last step.
(ert-deftest dsh-emacs-test-render-footer-option-can-disable-row ()
  :tags '(dsh-unit)
  (let* ((start '((type . "turn/start") (seq . 100) (time . 1000)
                  (data . ((turn . 7)))))
         (first '((type . "assistant/message") (seq . 101)
                  (data . ((turn . 7) (step . 1)
                           (usage . ((inputTokens . 10) (outputTokens . 20)
                                     (cacheReadTokens . 30) (cacheWriteTokens . 40)))
                           (message . ((content . [((type . "text")
                                                    (text . "earlier reply"))])))))))
         (last '((type . "assistant/message") (seq . 102)
                 (data . ((turn . 7) (step . 2)
                          (usage . ((inputTokens . 1) (outputTokens . 2)
                                    (cacheReadTokens . 3) (cacheWriteTokens . 4)))
                          (message . ((content . [((type . "text")
                                                   (text . "**final reply**"))])))))))
         (end '((type . "turn/end") (seq . 103) (time . 3500)
                (data . ((turn . 7)))))
         (events (mapcar (lambda (event) (list (cons 'event event)))
                         (list start first last end))))
    (dolist (items '(nil (duration copy) (copy fork usage duration)))
      (with-temp-buffer
        (dsh-emacs-mode)
        (setq dsh-emacs--buffer-session "footer-parent")
        (let ((dsh-emacs-reply-footer-items items)
              (dsh-emacs-stream-markdown-limit 1)
              forked)
          (dsh-emacs-render-history-events events)
          (while dsh-emacs--markdown-pending
            (dsh-emacs-render--run-markdown (current-buffer)))
          (let ((row (dsh-emacs-ui-find-block "sess-global" "reply-footer-7")))
            (ert-info ((format "%s" "footer-option-can-disable-row"))
              (should (eq (null row) (null items))))
            (when row
              (let ((text (buffer-substring-no-properties (car row) (cdr row))))
                (ert-info ((format "%s" "footer-order-and-per-turn-statistics"))
                  (should (string-match-p
                           (if (eq (car items) 'duration) "Time 2.5s  ·  Copy"
                             "Copy  ·  Fork  ·  Tokens 110  ·  Time 2.5s") text))
                  (should (= (how-many "Copy" (point-min) (point-max)) 1))
                  (should (not (get-text-property (car row) 'dsh-emacs-assistant-message)))
                  (should (not (get-text-property (car row) 'dsh-emacs-message-seq))))
                (goto-char (car row))
                (search-forward "Copy")
                (button-activate (button-at (1- (point))))
                (ert-info ((format "%s" "footer-copy-keeps-markdown-and-excludes-chrome"))
                  (should (equal (current-kill 0) "**final reply**")))
                (when (memq 'fork items)
                  (goto-char (car row))
                  (search-forward "Fork")
                  (cl-letf (((symbol-function 'dsh-emacs-fork-session)
                             (lambda (session seq) (setq forked (list session seq)))))
                    (button-activate (button-at (1- (point)))))
                  (ert-info ((format "%s" "footer-fork-targets-the-final-reply"))
                    (should (equal forked '("footer-parent" 102)))))))))))
    ;; A tail with no turn/start must not claim to contain all turn usage.
    ;; Prepending the older page updates the existing footer in place.
    (with-temp-buffer
      (dsh-emacs-mode)
      (let ((dsh-emacs-reply-footer-items '(usage duration)))
        (dsh-emacs-render-history-events (nthcdr 2 events))
        (ert-info ((format "%s" "footer-partial-history-is-explicit"))
          (should (string-match-p "Tokens ≥10  ·  Time —" (buffer-string))))
        (let* ((dsh-emacs--history-insert-marker
                (dsh-emacs-render--history-prepend-marker))
               (position (marker-position dsh-emacs--history-insert-marker)))
          (dsh-emacs-render-history-events (cl-subseq events 0 2) nil 102
                                           :insert-before position :follow-p nil)
          (set-marker dsh-emacs--history-insert-marker nil))
        (ert-info ((format "%s" "footer-older-page-completes-stats-without-duplicates"))
          (should (string-match-p "Tokens 110  ·  Time 2.5s" (buffer-string)))
          (should (= (how-many "Tokens" (point-min) (point-max)) 1)))
        (dsh-emacs-render-history-events events)
        (ert-info ((format "%s" "footer-reconnect-does-not-double-count"))
          (should (string-match-p "Tokens 110  ·  Time 2.5s" (buffer-string)))
          (should (= (how-many "Tokens" (point-min) (point-max)) 1)))))
    (with-temp-buffer
      (dsh-emacs-mode)
      (setq dsh-emacs--buffer-subagent
            (dsh-protocol-subagent-address-create "parent" "child" "continuable"))
      (dsh-emacs-render-history-events events)
      (ert-info ((format "%s" "footer-subagent-hides-fork-but-keeps-copy"))
        (should (string-match-p "Copy" (buffer-string)))
        (should (not (string-match-p "Fork" (buffer-string))))))))

;; Consecutive replies without a rendered human message share one visible footer.
(ert-deftest dsh-emacs-test-render-footer-continuations-latest-only-case-case ()
  :tags '(dsh-unit)
  (dolist (delivery '(live history prepend reconnect))
    (dolist (items '((copy fork usage duration) (usage duration)))
      (with-temp-buffer
        (dsh-emacs-mode)
        (setq-local dsh-emacs--buffer-session "footer-continuations")
        (let* ((dsh-emacs-reply-footer-items items)
               (events
                '(((type . "turn/start") (seq . 1) (time . 0) (data . ((turn . 1))))
                  ((type . "user/message") (seq . 2)
                   (data . ((content . [((type . "text") (text . "Question"))]))))
                  ((type . "assistant/message") (seq . 3)
                   (data . ((turn . 1) (step . 1)
                            (usage . ((inputTokens . 100) (outputTokens . 2)))
                            (message . ((content . [((type . "text")
                                                     (text . "**Main answer**"))]))))))
                  ((type . "turn/end") (seq . 4) (time . 1000) (data . ((turn . 1))))
                  ((type . "turn/start") (seq . 5) (time . 2000) (data . ((turn . 2))))
                  ((type . "user/message") (seq . 6)
                   (data . ((source . ((kind . "subagent-settled")))
                            (content . [((type . "text") (text . "Hidden child notice"))]))))
                  ((type . "assistant/message") (seq . 7)
                   (data . ((turn . 2) (step . 1)
                            (usage . ((inputTokens . 10) (outputTokens . 2)))
                            (message . ((content . [((type . "text")
                                                     (text . "**Follow-up**"))]))))))
                  ((type . "turn/end") (seq . 8) (time . 4000) (data . ((turn . 2))))))
               (entries (mapcar (lambda (event) (list (cons 'event event))) events))
               (ns (dsh-emacs-render--make-namespace)))
          (pcase delivery
            ('live (dolist (event events) (dsh-emacs-render-event event)))
            ('prepend
             (dsh-emacs-render-history-events (nthcdr 4 entries))
             (let* ((dsh-emacs--history-insert-marker
                     (dsh-emacs-render--history-prepend-marker))
                    (position (marker-position dsh-emacs--history-insert-marker)))
               (dsh-emacs-render-history-events
                (cl-subseq entries 0 4) nil 5 :insert-before position :follow-p nil)
               (set-marker dsh-emacs--history-insert-marker nil)))
            (_ (dsh-emacs-render-history-events entries)
               (when (eq delivery 'reconnect)
                 (dsh-emacs-render-history-events entries))))
          (ert-info ((format "%s" (format "footer-continuations-latest-only-%s-%s" delivery items)))
            (should (null (dsh-emacs-ui-find-block ns "reply-footer-1")))
            (should (dsh-emacs-ui-find-block ns "reply-footer-2"))
            (should (= (how-many "Tokens" (point-min) (point-max)) 1))
            (should (string-match-p "Tokens 12  ·  Time 2.0s" (buffer-string)))
            (should (string-match-p "Main answer" (buffer-string)))
            (should (string-match-p "Follow-up" (buffer-string)))
            (should (not (string-match-p "Hidden child notice" (buffer-string)))))
          (when (memq 'copy items)
            (goto-char (point-min))
            (search-forward "Copy")
            (let ((button (button-at (1- (point)))))
              (button-activate button)
              (ert-info ((format "%s" "footer-continuations-copy-target-stays-last-reply"))
                (should (equal (current-kill 0) "**Follow-up**"))
                (should (= (button-get button 'dsh-emacs-reply-seq) 7))))
            (goto-char (point-min))
            (search-forward "Fork")
            (let (forked)
              (cl-letf (((symbol-function 'dsh-emacs-fork-session)
                         (lambda (session seq) (setq forked (list session seq)))))
                (button-activate (button-at (1- (point)))))
              (ert-info ((format "%s" "footer-continuations-fork-target-stays-last-reply"))
                (should (equal forked '("footer-continuations" 7))))))
          ;; No completed text in a subsequent turn must not steal the toolbar.
          (dsh-emacs-render-event
           '((type . "turn/start") (seq . 9) (data . ((turn . 3)))))
          (ert-info ((format "%s" "footer-continuations-pending-turn-keeps-last-footer"))
            (should (dsh-emacs-ui-find-block ns "reply-footer-2")))
          (dsh-emacs-render-event
           '((type . "assistant/message") (seq . 10)
             (data . ((turn . 3) (message . ((content . [])))))))
          (dsh-emacs-render-event
           '((type . "turn/end") (seq . 11) (data . ((turn . 3)))))
          (ert-info ((format "%s" "footer-continuations-empty-turn-keeps-last-footer"))
            (should (dsh-emacs-ui-find-block ns "reply-footer-2"))
            (should (null (dsh-emacs-ui-find-block ns "reply-footer-3"))))
          ;; A visible human message, including an optimistic echo, splits groups.
          (dsh-emacs-render-user-message
           '((type . "user/message") (seq . 12)
             (data . ((content . [((type . "text") (text . "New question"))])))))
          (dsh-emacs-render-event
           '((type . "assistant/message") (seq . 13)
             (data . ((turn . 4) (step . 1)
                      (message . ((content . [((type . "text") (text . "New answer"))])))))))
          (dsh-emacs-render-event
           '((type . "turn/end") (seq . 14) (data . ((turn . 4)))))
          ;; Repainting older facts must neither resurrect an obsolete toolbar
          ;; nor remove the toolbar on the far side of a human message.
          (dolist (turn '(1 2))
            (dsh-emacs-render--reply-footer turn (gethash turn dsh-emacs-render--reply-turns)))
          (ert-info ((format "%s" "footer-continuations-preserve-human-boundaries-on-repaint"))
            (should (null (dsh-emacs-ui-find-block ns "reply-footer-1")))
            (should (dsh-emacs-ui-find-block ns "reply-footer-2"))
            (should (dsh-emacs-ui-find-block ns "reply-footer-4"))
            (should (= (how-many "Tokens" (point-min) (point-max)) 2)))
          (dsh-emacs-render-event
           '((type . "user/message") (seq . 15)
             (data . ((source . ((kind . "goal")))
                      (content . [((type . "text") (text . "Automatic goal round"))])))))
          (dsh-emacs-render-event
           '((type . "assistant/message") (seq . 16)
             (data . ((turn . 5) (step . 1)
                      (message . ((content . [((type . "text") (text . "Goal follow-up"))])))))))
          (dsh-emacs-render-event
           '((type . "turn/end") (seq . 17) (data . ((turn . 5)))))
          (ert-info ((format "%s" "footer-continuations-goal-notice-is-not-human-boundary"))
            (should (string-match-p "Continuing goal" (buffer-string)))
            (should (dsh-emacs-ui-find-block ns "reply-footer-2"))
            (should (null (dsh-emacs-ui-find-block ns "reply-footer-4")))
            (should (dsh-emacs-ui-find-block ns "reply-footer-5"))
            (should (= (how-many "Tokens" (point-min) (point-max)) 2))))))))

;; A streamed reply can straddle a human message.  Its final segment owns
;; its group, even when an older turn is repainted after a history prepend.
(ert-deftest dsh-emacs-test-render-footer-split-reply-before-prepend ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (setq-local dsh-emacs--buffer-session "footer-split-reply")
    (let ((dsh-emacs-reply-footer-items '(copy usage)))
      (dolist (event
               '(((type . "user/message") (seq . 2)
                  (data . ((content . [((type . "text") (text . "Question"))]))))
                 ((type . "assistant/message") (seq . 3)
                  (data . ((turn . 1) (step . 1)
                           (message . ((content . [((type . "text") (text . "Answer"))]))))))
                 ((type . "turn/end") (seq . 4) (data . ((turn . 1))))
                 ((type . "assistant/chunk") (seq . 5)
                  (data . ((turn . 2) (step . 1)
                           (chunk . ((type . "text-delta") (index . 0) (text . "Before\n"))))))
                 ((type . "assistant/chunk") (seq . 6)
                  (data . ((turn . 2) (step . 1)
                           (chunk . ((type . "reasoning-delta") (index . 1) (text . "Think\n"))))))
                 ((type . "user/message") (seq . 7)
                  (data . ((content . [((type . "text") (text . "New question"))]))))
                 ((type . "assistant/chunk") (seq . 8)
                  (data . ((turn . 2) (step . 1)
                           (chunk . ((type . "text-delta") (index . 2) (text . "After\n"))))))
                 ((type . "assistant/message") (seq . 9)
                  (data . ((turn . 2) (step . 1)
                           (message . ((content . [((type . "text") (text . "Before\n"))
                                                   ((type . "reasoning") (text . "Think\n"))
                                                   ((type . "text") (text . "After\n"))]))))))
                 ((type . "turn/end") (seq . 10) (data . ((turn . 2))))))
        (dsh-emacs-render-event event)
        (dsh-emacs-render--flush-stream)
        (dsh-emacs-render--flush-thinking))
      (let* ((ns (dsh-emacs-render--make-namespace))
             (dsh-emacs--history-insert-marker
              (dsh-emacs-render--history-prepend-marker))
             (position (marker-position dsh-emacs--history-insert-marker)))
        (ert-info ((format "%s" "footer-split-reply-before-prepend"))
          (should (dsh-emacs-ui-find-block ns "reply-footer-1"))
          (should (dsh-emacs-ui-find-block ns "reply-footer-2")))
        (dsh-emacs-render-history-events
         '(((event . ((type . "turn/start") (seq . 1) (data . ((turn . 1)))))))
         nil 2 :insert-before position :follow-p nil)
        (set-marker dsh-emacs--history-insert-marker nil)
        (ert-info ((format "%s" "footer-split-reply-prepend-preserves-both-groups"))
          (should (dsh-emacs-ui-find-block ns "reply-footer-1"))
          (should (dsh-emacs-ui-find-block ns "reply-footer-2"))
          (should (= (how-many "Tokens" (point-min) (point-max)) 2)))))))

;; Rejecting an optimistic input merges its neighboring groups.  A completed
;; background follow-up wins; an unfinished one must leave the old row alone.
(ert-deftest dsh-emacs-test-render-footer-before-rollback-case ()
  :tags '(dsh-unit)
  (dolist (completed '(nil t))
    (with-temp-buffer
      (dsh-emacs-mode)
      (setq-local dsh-emacs--buffer-session "footer-rollback")
      (let ((dsh-emacs-reply-footer-items '(copy usage))
            (ns (dsh-emacs-render--make-namespace)))
        (dsh-emacs-render-event
         '((type . "user/message") (seq . 1)
           (data . ((content . [((type . "text") (text . "Question"))])))))
        (dsh-emacs-render-event
         '((type . "assistant/message") (seq . 2)
           (data . ((turn . 1) (step . 1)
                    (message . ((content . [((type . "text") (text . "Answer"))])))))))
        (dsh-emacs-render-event
         '((type . "turn/end") (seq . 3) (data . ((turn . 1)))))
        (let ((echo (dsh-emacs--render-user-message-optimistic "Rejected question" nil)))
          (dsh-emacs-render-event
           '((type . "assistant/message") (seq . 4)
             (data . ((turn . 2) (step . 1)
                      (message . ((content . [((type . "text") (text . "Follow-up"))])))))))
          (when completed
            (dsh-emacs-render-event
             '((type . "turn/end") (seq . 5) (data . ((turn . 2))))))
          (ert-info ((format "%s" (format "footer-before-rollback-%s" completed)))
            (should (dsh-emacs-ui-find-block ns "reply-footer-1"))
            (should (= (how-many "Tokens" (point-min) (point-max)) (if completed 2 1))))
          (dsh-emacs--discard-user-message-echo echo)
          (ert-info ((format "%s" (format "footer-rollback-reconciles-merged-group-%s" completed)))
            (should (not (string-match-p "Rejected question" (buffer-string))))
            (should (string-match-p "Answer" (buffer-string)))
            (should (string-match-p "Follow-up" (buffer-string)))
            (should (= (how-many "Tokens" (point-min) (point-max)) 1))
            (should (dsh-emacs-ui-find-block ns (if completed "reply-footer-2" "reply-footer-1")))
            (should (null (dsh-emacs-ui-find-block ns (if completed "reply-footer-1" "reply-footer-2")))))
          (goto-char (point-min))
          (search-forward "Copy")
          (button-activate (button-at (1- (point))))
          (ert-info ((format "%s" (format "footer-rollback-copy-target-%s" completed)))
            (should (equal (current-kill 0) (if completed "Follow-up" "Answer")))))))))

;; Deliverables belong above the footer, including expanded file lists.
(ert-deftest dsh-emacs-test-render-footer-after-deliverables-case-case ()
  :tags '(dsh-unit)
  (dolist (history '(nil t))
    (with-temp-buffer
      (dsh-emacs-mode)
      (let ((dsh-emacs-stream-markdown-limit 1)
            (events
             '(((type . "turn/start") (seq . 1) (data . ((turn . 1))))
               ((type . "deliverables/presented") (seq . 2)
                (data . ((turn . 1) (callId . "present-1")
                         (files . [((path . "report.md"))]))))
               ((type . "assistant/message") (seq . 3)
                (data . ((turn . 1) (step . 1)
                         (message . ((content . [((type . "text")
                                                  (text . "**final answer**"))]))))))
               ((type . "turn/end") (seq . 4) (data . ((turn . 1))))
               ((type . "user/message") (seq . 5)
                (data . ((content . [((type . "text")
                                      (text . "next question"))])))))))
        (if history
            (dsh-emacs-render-history-events
             (mapcar (lambda (event) (list (cons 'event event))) events))
          (dolist (event events)
            (dsh-emacs-render-event event)))
        (while dsh-emacs--markdown-pending
          (dsh-emacs-render--run-markdown (current-buffer)))
        (dotimes (expanded 2)
          (when (= expanded 1)
            (goto-char (point-min))
            (search-forward "Deliverables")
            (dsh-emacs-ui-toggle-fragment)
            (dsh-emacs-render--reply-footer
             1 (gethash 1 dsh-emacs-render--reply-turns)))
          (let* ((text (buffer-substring-no-properties (point-min) (point-max)))
                 (reply (string-match "final answer" text))
                 (delivery (string-match "Deliverables" text))
                 (footer (string-match "Copy" text))
                 (next (string-match "next question" text)))
            (ert-info ((format "%s" (format "footer-after-deliverables-%s-%s"
                                            (if history "history" "live")
                                            (if (= expanded 1) "expanded" "collapsed"))))
              (should (and reply delivery footer next (< reply delivery footer next)))
              (should (or (= expanded 0)
                          (let ((file (string-match "report.md" text)))
                            (and file (< delivery file footer)))))
              (should (= (how-many "Copy" (point-min) (point-max)) 1)))))))))

;; A turn may end after diagnostics or tools, without another text reply.
(ert-deftest dsh-emacs-test-render-footer-after-turn-tail-case-case ()
  :tags '(dsh-unit)
  (dolist (history '(nil t prepend reconnect))
    (dolist (case
             '(("tool" "tail.txt"
                ((type . "tool/call") (seq . 3)
                 (data . ((turn . 1) (step . 1) (callId . "tail-tool")
                          (name . "read") (arguments . "{\"path\":\"tail.txt\"}")))))
               ("attempt" "Incomplete reply"
                ((type . "assistant/attempt") (seq . 3)
                 (data . ((turn . 1) (step . 2) (stream . [])))))
               ("compaction" "Context compaction failed"
                ((type . "compaction/end") (seq . 3)
                 (data . ((turn . 1) (compactionId . "tail-compaction")
                          (error . "compression failed")))))
               ("thinking" "Think"
                ((type . "assistant/message") (seq . 3)
                 (data . ((turn . 1) (step . 2)
                          (message . ((content . [((type . "reasoning")
                                                   (text . "unfinished reasoning"))])))))))
               ("error" "Model error")))
      (with-temp-buffer
        (dsh-emacs-mode)
        (pcase-let* ((`(,name ,label . ,tail) case)
                     (dsh-emacs-stream-markdown-limit 1)
                     (events
                      (append
                       '(((type . "turn/start") (seq . 1) (data . ((turn . 1))))
                         ((type . "assistant/message") (seq . 2)
                          (data . ((turn . 1) (step . 1)
                                   (message . ((content . [((type . "text")
                                                            (text . "**last text**"))])))))))
                       tail
                       `(((type . "turn/end") (seq . 4)
                          (data . ((turn . 1)
                                   (reason . ,(if (equal name "error")
                                                  '((kind . "error") (error . "provider failed"))
                                                '((kind . "completed")))))))
                         ((type . "user/message") (seq . 5)
                          (data . ((content . [((type . "text")
                                                (text . "next question"))]))))))))
          (let ((entries (mapcar (lambda (event) (list (cons 'event event))) events)))
            (pcase history
              ('nil (dolist (event events) (dsh-emacs-render-event event)))
              ('prepend
               (dsh-emacs-render-history-events (nthcdr 2 entries))
               (let* ((dsh-emacs--history-insert-marker
                       (dsh-emacs-render--history-prepend-marker))
                      (position (marker-position dsh-emacs--history-insert-marker)))
                 (dsh-emacs-render-history-events
                  (cl-subseq entries 0 2) nil 3 :insert-before position :follow-p nil)
                 (set-marker dsh-emacs--history-insert-marker nil)))
              (_ (dsh-emacs-render-history-events entries)
                 (when (eq history 'reconnect)
                   (dsh-emacs-render-history-events entries)))))
          (while dsh-emacs--markdown-pending
            (dsh-emacs-render--run-markdown (current-buffer)))
          (let* ((text (buffer-substring-no-properties (point-min) (point-max)))
                 (tail-pos (string-match (regexp-quote label) text))
                 (footer (string-match "Copy" text))
                 (next (string-match "next question" text)))
            (ert-info ((format "%s" (format "footer-after-turn-tail-%s-%s" name history)))
              (should (and tail-pos footer next (< tail-pos footer next)))
              (should (= (how-many "Copy" (point-min) (point-max)) 1)))
            (goto-char (point-min))
            (search-forward "Copy")
            (button-activate (button-at (1- (point))))
            (ert-info ((format "%s" "footer-tail-keeps-last-text-copy-target"))
              (should (equal (current-kill 0) "**last text**")))))))))

;; A live completed reply may still be waiting for idle Markdown. The footer
;; must survive that replacement and must not become part of the message.
(ert-deftest dsh-emacs-test-render-footer-absent-during-live-stream ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (let ((dsh-emacs-stream-markdown-limit 1)
          (dsh-emacs-reply-footer-items '(copy fork usage duration)))
      (dsh-emacs-render-event
       '((type . "turn/start") (seq . 1) (time . 5000) (data . ((turn . 1)))))
      (dsh-emacs-render--start-assistant-stream
       '((data . ((turn . 1) (step . 1)))) "**stream answer**\n")
      (ert-info ((format "%s" "footer-absent-during-live-stream"))
        (should (not (string-match-p "Tokens" (buffer-string)))))
      (dsh-emacs-render-event
       '((type . "assistant/message") (seq . 2)
         (data . ((turn . 1) (step . 1)
                  (message . ((content . [((type . "text")
                                           (text . "**stream answer**\n"))])))))))
      (dsh-emacs-render-event
       '((type . "turn/end") (seq . 3) (time . 67000) (data . ((turn . 1)))))
      (while dsh-emacs--markdown-pending
        (dsh-emacs-render--run-markdown (current-buffer)))
      (ert-info ((format "%s" "footer-live-idle-formatting-keeps-row-and-unknown-usage"))
        (should (string-match-p "stream answer" (buffer-string)))
        (should (string-match-p "Tokens —  ·  Time 1m02s" (buffer-string)))
        (should (= (how-many "Copy" (point-min) (point-max)) 1)))
      (dsh-emacs-copy-last-assistant-message)
      (ert-info ((format "%s" "footer-never-enters-copy-last-reply"))
        (should (equal (current-kill 0) "stream answer")))
      (dsh-emacs-render--reset-tool-tracking)
      (ert-info ((format "%s" "footer-state-clears-on-full-reload"))
        (should (null dsh-emacs-render--reply-turns))))))

;; Synthetic fork endings must not turn old timestamps into a huge duration.
(ert-deftest dsh-emacs-test-render-footer-fork-end-has-no-elapsed-endpoint ()
  :tags '(dsh-unit)
  (let ((event (dsh-protocol-reply-event--from-alist
                '((type . "turn/end") (seq . 9) (time . 999999)
                  (data . ((turn . 1) (reason . ((kind . "forked")))))))))
    (ert-info ((format "%s" "footer-fork-end-has-no-elapsed-endpoint"))
      (should (null (dsh-protocol-reply-event-time event))))))

;; A footer is painted after its history batch, so a following question may
;; already own the leading blank line the footer's padding also reserves.
(ert-deftest dsh-emacs-test-render-footer-history-keeps-one-blank-line ()
  :tags '(dsh-unit)
  (dolist (tail '(reply fragment))
    (with-temp-buffer
      (dsh-emacs-mode)
      (let* ((dsh-emacs-fold-work-details nil)
             (dsh-emacs-reply-footer-items '(copy))
             (dsh-emacs-stream-markdown-limit 1)
             (events
              (append
               '(((type . "turn/start") (seq . 1) (time . 1000)
                  (data . ((turn . 1))))
                 ((type . "user/message") (seq . 2)
                  (data . ((content . [((type . "text") (text . "First"))]))))
                 ((type . "assistant/message") (seq . 3)
                  (data . ((turn . 1) (step . 1)
                           (message . ((content . [((type . "text")
                                                    (text . "ANSWER"))])))))))
               (when (eq tail 'fragment)
                 '(((type . "tool/call") (seq . 4)
                    (data . ((turn . 1) (step . 2) (callId . "after")
                             (name . "read")
                             (arguments . "{\"path\":\"x\"}"))))))
               '(((type . "turn/end") (seq . 5) (time . 5000)
                  (data . ((turn . 1) (reason . ((kind . "completed"))))))
                 ((type . "user/message") (seq . 6)
                  (data . ((content . [((type . "text")
                                        (text . "Second"))]))))))))
        (dsh-emacs-render-history-events
         (mapcar (lambda (event) (list (cons 'event event))) events))
        (while dsh-emacs--markdown-pending
          (dsh-emacs-render--run-markdown (current-buffer)))
        (let ((text (buffer-substring-no-properties (point-min) (point-max))))
          (ert-info ((format "footer history tail=%s" tail))
            (should (string-match-p "\nCopy\n\nSecond" text))
            (should-not (string-match-p "\nCopy\n\n\nSecond" text))))))))

;; The muted row must not inherit the fragment title's bold weight.
(ert-deftest dsh-emacs-test-render-footer-uses-normal-weight-meta-face ()
  :tags '(dsh-unit)
  (should (eq 'normal
              (face-attribute 'dsh-emacs-reply-meta-face :weight nil nil)))
  (with-temp-buffer
    (dsh-emacs-mode)
    (let ((dsh-emacs-fold-work-details nil)
          (dsh-emacs-reply-footer-items '(copy)))
      (dsh-emacs-render-history-events
       (mapcar (lambda (event) (list (cons 'event event)))
               '(((type . "turn/start") (seq . 1) (time . 1000)
                  (data . ((turn . 1))))
                 ((type . "user/message") (seq . 2)
                  (data . ((content . [((type . "text") (text . "Q"))]))))
                 ((type . "assistant/message") (seq . 3)
                  (data . ((turn . 1) (step . 1)
                           (message . ((content . [((type . "text")
                                                    (text . "A"))]))))))
                 ((type . "turn/end") (seq . 4) (time . 5000)
                  (data . ((turn . 1) (reason . ((kind . "completed")))))))))
      (goto-char (point-min))
      (search-forward "Copy")
      (let ((face (get-text-property (1- (point)) 'face)))
        ;; Reply meta must precede the title face that `--label-merge' appends.
        (should (eq 'dsh-emacs-reply-meta-face
                    (if (listp face) (car face) face)))))))

;; --- Test 98o: a non-envelope failure response (vendor error body passed
;; through) unwraps into a message ---
(ert-deftest dsh-emacs-test-render-unwrap-leaked-error-body-surfaces-message ()
  :tags '(dsh-unit)
  (let* ((response (json-read-from-string
                    "{\"message\":\"Allocated quota exceeded, please increase your quota limit.\",\"code\":\"insufficient_quota\"}"))
         (unwrapped (dsh-protocol-rpc-result--from-alist response)))
    (ert-info ((format "%s" "unwrap-leaked-error-body-surfaces-message"))
      (should (and (null (car unwrapped))
                   (string-match-p "Allocated quota exceeded" (cdr unwrapped)))))))

;; --- Test 101: todo plan row --- parse / one row per event (like a tool
;; card) / collapse ---
;; 101a: full snapshot collapse: drop empty content, unknown status
;; defaults to pending, counts are correct
(ert-deftest dsh-emacs-test-render-todo-parse-drops-invalid-defaults-status ()
  :tags '(dsh-unit)
  (let ((l (dsh-protocol-todos--from-alist
            "{\"todos\":[{\"content\":\"a\",\"status\":\"pending\"},{\"content\":\"b\",\"status\":\"in_progress\"},{\"content\":\"c\",\"status\":\"completed\"},{\"content\":\"\",\"status\":\"completed\"},{\"content\":\"d\"}]}")))
    (ert-info ((format "%s" "todo-parse-drops-invalid-defaults-status"))
      (should (and (= (length l) 4)
                   (equal (dsh-emacs-render--todo-counts l) '(1 1 2))
                   (string-match-p "1/4 completed" (dsh-emacs-render--todo-summary l)))))))

;; 101b: the first todo_write renders **one** todo row (with
;; progress/pending glyphs), it does not create an ordinary tool card
(ert-deftest dsh-emacs-test-render-todo-row-renders-on-write-no-card ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-modeline-setup)
    (setq-local dsh-emacs-todo-expand-by-default t)
    (dsh-emacs-render-tool-call
     (dsh-emacs-test--tool-call-event 1 "t1" "todo_write"
                                      "{\"todos\":[{\"content\":\"A\",\"status\":\"in_progress\"},{\"content\":\"B\",\"status\":\"pending\"}]}"))
    (let ((txt (buffer-string)))
      (ert-info ((format "%s" "todo-row-renders-on-write-no-card"))
        (should (and (dsh-emacs-ui-find-block dsh-emacs--todo-namespace "t1")
                     ;; items are ☐ checkboxes (in_progress/pending) with status words
                     (string-match-p (regexp-quote "☐") txt)
                     (string-match-p "in progress" txt)
                     (string-match-p "pending" txt)
                     ;; Leading icon is the dsh-web checklist icon (fallback "▤" in
                     ;; non-graphical Emacs), not the old "☑".
                     (string-match-p (regexp-quote "▤") txt)
                     (not (string-match-p (regexp-quote "☑") txt))
                     (not (string-match-p "tool-t1" txt))))))))

;; 101c: every todo_write renders a new row (like a tool card),
;; accumulating with the conversation, no overwriting
(ert-deftest dsh-emacs-test-render-todo-each-write-renders-new-row ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-modeline-setup)
    (setq-local dsh-emacs-todo-expand-by-default t)
    (dsh-emacs-render-tool-call
     (dsh-emacs-test--tool-call-event 1 "t1" "todo_write"
                                      "{\"todos\":[{\"content\":\"A\",\"status\":\"in_progress\"},{\"content\":\"B\",\"status\":\"pending\"}]}"))
    (dsh-emacs-render-tool-call
     (dsh-emacs-test--tool-call-event 2 "t2" "todo_write"
                                      "{\"todos\":[{\"content\":\"A\",\"status\":\"completed\"},{\"content\":\"B\",\"status\":\"in_progress\"},{\"content\":\"C\",\"status\":\"pending\"}]}"))
    (let ((txt (buffer-string)))
      (ert-info ((format "%s" "todo-each-write-renders-new-row"))
        (should (and (dsh-emacs-ui-find-block dsh-emacs--todo-namespace "t1")
                     (dsh-emacs-ui-find-block dsh-emacs--todo-namespace "t2")
                     (string-match-p "1/3 completed" txt)
                     (string-match-p (regexp-quote "C") txt)
                     (string-match-p (regexp-quote "☑") txt)))))))

;; 101d: resetting the session clears the latest todo snapshot state
(ert-deftest dsh-emacs-test-render-todo-reset-clears-list ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-modeline-setup)
    (dsh-emacs-render-tool-call
     (dsh-emacs-test--tool-call-event 1 "t1" "todo_write"
                                      "{\"todos\":[{\"content\":\"A\",\"status\":\"pending\"}]}"))
    (dsh-emacs-render--reset-tool-tracking)
    (ert-info ((format "%s" "todo-reset-clears-list"))
      (should (null dsh-emacs--todo-list)))))

;; 101e: a todo row can be collapsed/expanded (default collapsed: header
;; only, checklist hidden)
(ert-deftest dsh-emacs-test-render-todo-row-collapsed-by-default ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-modeline-setup)
    (setq-local dsh-emacs-todo-expand-by-default nil)
    (dsh-emacs-render-tool-call
     (dsh-emacs-test--tool-call-event 1 "t1" "todo_write"
                                      "{\"todos\":[{\"content\":\"Alpha\",\"status\":\"in_progress\"},{\"content\":\"Beta\",\"status\":\"pending\"}]}"))
    (let* ((b (dsh-emacs-ui-find-block dsh-emacs--todo-namespace "t1"))
           (blk (and b (buffer-substring-no-properties (car b) (cdr b)))))
      (ert-info ((format "%s" "todo-row-collapsed-by-default"))
        (should (and b (string-match-p "Todo" blk)
                     (not (string-match-p (regexp-quote "Alpha") (buffer-string))))))
      ;; Expand: the checklist appears (with status glyphs)
      (goto-char (car b))
      (dsh-emacs-ui-toggle-fragment)
      (let ((txt (buffer-string)))
        (ert-info ((format "%s" "todo-row-expands-on-toggle"))
          (should (and (string-match-p (regexp-quote "Alpha") txt)
                       (string-match-p (regexp-quote "☐") txt)))))
      ;; Collapse again: the checklist is hidden again
      (goto-char (car b))
      (dsh-emacs-ui-toggle-fragment)
      (ert-info ((format "%s" "todo-row-recollapses-on-toggle"))
        (should (not (string-match-p (regexp-quote "Alpha") (buffer-string))))))))

;; 101f: summary-only mode: show only counts/progress, hide checklist
;; details and the collapse toggle
(ert-deftest dsh-emacs-test-render-todo-summary-only-hides-details ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-modeline-setup)
    (setq-local dsh-emacs-todo-summary-only t)
    (dsh-emacs-render-tool-call
     (dsh-emacs-test--tool-call-event 1 "t1" "todo_write"
                                      "{\"todos\":[{\"content\":\"Alpha\",\"status\":\"in_progress\"},{\"content\":\"Beta\",\"status\":\"pending\"},{\"content\":\"Gamma\",\"status\":\"completed\"}]}"))
    (let* ((b (dsh-emacs-ui-find-block dsh-emacs--todo-namespace "t1"))
           (blk (and b (buffer-substring-no-properties (car b) (cdr b)))))
      (ert-info ((format "%s" "todo-summary-only-hides-details"))
        (should (and b
                     (string-match-p "1/3 completed" (buffer-string))
                     (not (string-match-p (regexp-quote "Alpha") (buffer-string)))
                     (not (string-match-p (regexp-quote "Beta") (buffer-string)))
                     (not (string-match-p (regexp-quote "Gamma") (buffer-string))))))
      ;; Text segment (title) in green `dsh-emacs-todo-text-face' (not italic)
      (ert-info ((format "%s" "todo-row-text-green"))
        (should (and b
                     (let ((m (string-match "Todo" blk)))
                       (and m
                            (let ((f (get-text-property (+ (car b) m) 'face)))
                              (or (eq f 'dsh-emacs-todo-text-face)
                                  (memq 'dsh-emacs-todo-text-face
                                        (if (listp f) f (list f))))))))))
      ;; Leading icon in tool purple `dsh-emacs-tool-icon-face'
      (ert-info ((format "%s" "todo-icon-purple-face"))
        (should (and b
                     (let ((f (get-text-property (car b) 'face)))
                       (or (eq f 'dsh-emacs-tool-icon-face)
                           (memq 'dsh-emacs-tool-icon-face
                                 (if (listp f) f (list f))))))))
      ;; The collapse toggle should have no effect: repeated toggling must not
      ;; reveal the checklist
      (goto-char (car b))
      (dsh-emacs-ui-toggle-fragment)
      (dsh-emacs-ui-toggle-fragment)
      (ert-info ((format "%s" "todo-summary-only-no-toggle"))
        (should (not (string-match-p (regexp-quote "Alpha") (buffer-string))))))))

;; --- Test 121: model-only surface replacement copies do not enter the human
;; record ---
;; A surface event is either `append' (entered the transcript at its own log
;; position) or `{op:"replace"}' (shadows an existing range so the MODEL sees
;; the newer copy). Replacements are the wrong source for a human transcript:
;; dsh compaction checkpoints are `user/message' copies already skipped by the
;; source-kind filter, but a pruned `tool/result' shares its `callId' with the
;; record it shadows and has no source filter, so without this check the same
;; tool card is painted twice.
(ert-deftest dsh-emacs-test-render-render-replacement-predicate ()
  :tags '(dsh-unit)
  (ert-info ((format "%s" "render-replacement-predicate"))
    (should (dsh-protocol-replacement--from-alist
             '((type . "tool/result")
               (surfaceOp . ((op . "replace") (startSeq . 2) (endSeq . 2))))))
    (should (not (dsh-protocol-replacement--from-alist
                  '((type . "tool/result") (surfaceOp . "append")))))
    (should (not (dsh-protocol-replacement--from-alist '((type . "tool/result")))))))

(ert-deftest dsh-emacs-test-render-render-skips-replacement-tool-result ()
  :tags '(dsh-unit)
  (let ((buf (generate-new-buffer " *dsh-replacement*")))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs-mode)
          (setq-local dsh-emacs-tool-expand-by-default t)
          (dsh-emacs-render-tool-call
           '(("type" . "tool/call") ("seq" . 1)
             ("data" . (("turn" . 1) ("step" . 1) ("callId" . "c-rep")
                        ("name" . "bash")
                        ("arguments" . "{\"command\":\"echo original\"}")))))
          (dsh-emacs-events--dispatch-event
           (current-buffer)
           (list (cons "type" "tool/result") (cons "seq" 2)
                 (cons "surfaceOp" (list (cons "op" "replace")
                                         (cons "startSeq" 2) (cons "endSeq" 2)))
                 (cons "data"
                       (list (cons "message"
                                   (list (cons "source" (list (cons "callId" "c-rep")))
                                         (cons "content"
                                               (vector (list (cons "type" "tool-result")
                                                             (cons "isError" :json-false)
                                                             (cons "exitCode" 0)
                                                             (cons "content"
                                                                   (vector (list (cons "type" "text")
                                                                                 (cons "text" "PRUNED-COPY")))))))))))))
          (ert-info ((format "%s" "render-skips-replacement-tool-result"))
            (should (not (string-search "PRUNED-COPY" (buffer-string))))
            (should (string-search "echo original" (buffer-string)))
            (should (= dsh-emacs--anchor-seq 2)))
          ;; Control: an append-origin result on another call still paints.
          (dsh-emacs-render-tool-call
           '(("type" . "tool/call") ("seq" . 3)
             ("data" . (("turn" . 1) ("step" . 1) ("callId" . "c-app")
                        ("name" . "bash")
                        ("arguments" . "{\"command\":\"echo second\"}")))))
          (dsh-emacs-events--dispatch-event
           (current-buffer)
           (list (cons "type" "tool/result") (cons "seq" 4)
                 (cons "surfaceOp" "append")
                 (cons "data"
                       (list (cons "message"
                                   (list (cons "source" (list (cons "callId" "c-app")))
                                         (cons "content"
                                               (vector (list (cons "type" "tool-result")
                                                             (cons "isError" :json-false)
                                                             (cons "exitCode" 0)
                                                             (cons "content"
                                                                   (vector (list (cons "type" "text")
                                                                                 (cons "text" "APPEND-COPY")))))))))))))
          (ert-info ((format "%s" "render-keeps-append-tool-result"))
            (should (string-search "APPEND-COPY" (buffer-string)))
            (should (= dsh-emacs--anchor-seq 4))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest dsh-emacs-test-render-notification-without-dbus-uses-message ()
  :tags '(dsh-unit)
  (let ((system-type 'gnu/linux)
        (dsh-emacs-enable-notifications t)
        (original-featurep (symbol-function 'featurep))
        (original-require (symbol-function 'require))
        (calls 0)
        notice)
    (cl-letf (((symbol-function 'w32-notification-notify) nil)
              ((symbol-function 'ns-do-applescript) nil)
              ((symbol-function 'featurep)
               (lambda (feature &optional subfeature)
                 (and (not (eq feature 'dbusbind))
                      (funcall original-featurep feature subfeature))))
              ((symbol-function 'require)
               (lambda (feature &rest args)
                 (if (eq feature 'notifications)
                     t
                   (apply original-require feature args))))
              ((symbol-function 'executable-find) #'ignore)
              ((symbol-function 'dsh-emacs-notify--visible-p) #'ignore)
              ((symbol-function 'notifications-notify)
               (lambda (&rest _) (cl-incf calls)))
              ((symbol-function 'message)
               (lambda (format-string &rest args)
                 (setq notice (apply #'format format-string args)))))
      (with-temp-buffer
        (rename-buffer " *dsh-notify-no-dbus*" t)
        (dsh-emacs-notify--post nil "Run finished")
        (should (= calls 0))
        (should (equal notice
                       "dsh:  *dsh-notify-no-dbus* — Run finished"))))))

(provide 'dsh-test-render)
;;; dsh-test-render.el ends here
