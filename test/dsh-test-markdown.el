;;; dsh-test-markdown.el --- Markdown tests -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "28.1"))

(require 'dsh-test-support)

;; --- Test 11: Markdown functions exist ---
(ert-deftest dsh-emacs-test-markdown-markdown-render-function-exists ()
  :tags '(dsh-unit)
  (ert-info ((format "%s" "markdown-render function exists"))
    (should (fboundp 'dsh-emacs-markdown-render))))

(ert-deftest dsh-emacs-test-markdown-markdown-render-applies-faces ()
  :tags '(dsh-unit)
  (let ((rendered (dsh-emacs-markdown-render "# title\n**bold** `code`")))
    (ert-info ((format "%s" "markdown-render-applies-faces"))
      (should (and (string= rendered "title\nbold code\n")
                   (eq (get-text-property 0 'face rendered)
                       'dsh-emacs-markdown-header-1)
                   (eq (get-text-property 6 'face rendered)
                       'dsh-emacs-markdown-bold)
                   (eq (get-text-property 11 'face rendered)
                       'dsh-emacs-markdown-inline-code))))))

(ert-deftest dsh-emacs-test-markdown-markdown-nested-and-alternate-markup ()
  :tags '(dsh-unit)
  (let ((rendered (dsh-emacs-markdown-render
                   "__bold__ _italic_ ~~gone~~ **_both_**")))
    (let ((both-face (get-text-property 17 'face rendered)))
      (ert-info ((format "%s" "markdown-nested-and-alternate-markup"))
        (should (and (string= rendered "bold italic gone both\n")
                     (eq (get-text-property 0 'face rendered)
                         'dsh-emacs-markdown-bold)
                     (eq (get-text-property 5 'face rendered)
                         'dsh-emacs-markdown-italic)
                     (eq (get-text-property 12 'face rendered)
                         'dsh-emacs-markdown-strikethrough)
                     (listp both-face)
                     (memq 'dsh-emacs-markdown-bold both-face)
                     (memq 'dsh-emacs-markdown-italic both-face)))))))

(ert-deftest dsh-emacs-test-markdown-bold-next-to-text-and-punctuation ()
  :tags '(dsh-unit)
  (dolist (fixture '(("这是**重点**内容" "这是重点内容" "重点")
                     ("（**重点**）" "（重点）" "重点")
                     ("**重点**（说明）" "重点（说明）" "重点")
                     ("word**bold**tail" "wordboldtail" "bold")
                     ("\\\\**重点**" "\\\\重点" "重点")
                     ("（__重点__）" "（重点）" "重点")
                     ("(**one**),**two**!" "(one),two!" "two")))
    (pcase-let* ((`(,source ,plain ,body) fixture)
                 (rendered (dsh-emacs-markdown-render source))
                 (start (string-match (regexp-quote body) rendered)))
      (ert-info ((format "source: %S" source))
        (should (equal (substring-no-properties rendered)
                       (concat plain "\n")))
        (should start)
        (dotimes (offset (length body))
          (should (memq 'dsh-emacs-markdown-bold
                        (ensure-list
                         (get-text-property (+ start offset)
                                            'face rendered)))))))))

(ert-deftest dsh-emacs-test-markdown-bold-keeps-literal-delimiters ()
  :tags '(dsh-unit)
  (dolist (source '("word__literal__tail" "** leading**" "**trailing **"
                    "a**\"quoted\"**b" "\\**literal**" "**literal\\**"
                    "**unclosed"))
    (let ((rendered (dsh-emacs-markdown-render source)))
      (ert-info ((format "source: %S" source))
        (should (equal (substring-no-properties rendered)
                       (concat source "\n")))
        (should-not (text-property-not-all 0 (length rendered)
                                           'face nil rendered))))))

(ert-deftest dsh-emacs-test-markdown-markdown-table-render ()
  :tags '(dsh-unit)
  (let ((rendered (dsh-emacs-markdown-render
                   "| Name | Value |\n| --- | ---: |\n| **foo** | `bar` |")))
    (ert-info ((format "%s" "markdown-table-render"))
      (should (and (string-match-p "│ Name │ Value │" rendered)
                   (string-match-p "├" rendered)
                   (string-match-p "foo" rendered)
                   (not (string-match-p "\\*\\*" rendered))
                   (not (string-match-p "`" rendered)))))))

;; Pixel paths use the target frame even when it is not the selected frame.
(ert-deftest dsh-emacs-test-markdown-table-pixel-paths-use-the-destination-frame ()
  :tags '(dsh-unit)
  (let* ((window (selected-window))
         (frame (window-frame window)))
    (cl-letf (((symbol-function 'display-graphic-p)
               (lambda (&optional target) (eq target frame)))
              ((symbol-function 'dsh-emacs-markdown--table-measure-string)
               (lambda (str _window)
                 (cond ((equal str " ") 10)
                       ((equal str "MMMMMMMMMM")
                        (if (get-text-property 0 'face str) 200 100))
                       (t 30)))))
      (ert-info ((format "%s" "table-pixel-paths-use-the-destination-frame"))
        (should (= (dsh-emacs-markdown--table-display-width :str "中" :window window) 3))
        (should (= (dsh-emacs-markdown--table-wrap-char-width
                    (propertize "a" 'face 'bold) 0 window) 2.0))
        (should (equal (dsh-emacs-markdown--pad-table-string
                        :str "中" :width 4 :window window) "中 "))))))

;; Font measurements are shared within one table, never across renders.
(ert-deftest dsh-emacs-test-markdown-table-metrics-use-current-render-fonts ()
  :tags '(dsh-unit)
  (save-window-excursion
    (with-temp-buffer
      (let* ((window (split-window-right))
             (source (concat "| " (propertize "AAAA" 'face 'bold)
                             " | 中文 |\n|---|---|\n| plain | 中文 |\n"))
             (default-height 16)
             (spaces 0)
             (faces 0)
             height-windows first second)
        (set-window-buffer window (current-buffer))
        (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                  ((symbol-function 'dsh-emacs-markdown--table-measure-line-height)
                   (lambda (win str)
                     (push win height-windows)
                     (if (equal str "A") default-height 20)))
                  ((symbol-function 'dsh-emacs-markdown--table-measure-string)
                   (lambda (str _window)
                     (when (equal str " ") (cl-incf spaces))
                     (when (and (equal str "MMMMMMMMMM")
                                (get-text-property 0 'face str))
                       (cl-incf faces))
                     (* 10 (string-width str)))))
          (setq first (dsh-emacs-markdown--render-table-source
                       :source source :window window)
                default-height 18
                second (dsh-emacs-markdown--render-table-source
                        :source source :window window)))
        (ert-info ((format "%s" "table-metrics-use-current-render-fonts"))
          (should (equal (get-text-property (string-match "中" first) 'display first)
                         '(height 0.8)))
          (should (equal (get-text-property (string-match "中" second) 'display second)
                         '(height 0.9)))
          (should (= spaces 2))
          (should (= faces 2))
          (should (cl-every (lambda (win) (eq win window)) height-windows)))))))

;; The compatibility pixel probe must measure beyond the window's width.
(ert-deftest dsh-emacs-test-markdown-table-measure-full-width-on-emacs-27 ()
  :tags '(dsh-unit)
  (save-window-excursion
    (with-temp-buffer
      (set-window-buffer (selected-window) (current-buffer))
      (let ((emacs-major-version 27)
            measured)
        (cl-letf (((symbol-function 'window-text-pixel-size)
                   (lambda (_window _from _to &optional x-limit &rest _)
                     (setq measured x-limit)
                     (cons (if (eq x-limit t) 3500 560) 10))))
          (ert-info ((format "%s" "table-measure-full-width-on-emacs-27"))
            (should (= (dsh-emacs-markdown--table-measure-string
                        (make-string 500 ?W) (selected-window)) 3500))
            (should (eq measured t))))))))

;; Emacs 31 can measure in the destination's font context without editing it.
(ert-deftest dsh-emacs-test-markdown-table-measure-without-destination-edits ()
  :tags '(dsh-unit)
  (save-window-excursion
    (with-temp-buffer
      (insert "draft")
      (let* ((source (current-buffer))
             (window (split-window-right))
             (selected (selected-window))
             (tick (buffer-modified-tick))
             (emacs-major-version 31)
             measured)
        (set-window-buffer window source)
        (cl-letf (((symbol-function 'string-pixel-width)
                   (lambda (str buffer)
                     (setq measured (list str buffer (selected-window)))
                     3500)))
          (let ((width (dsh-emacs-markdown--table-measure-string
                        (make-string 500 ?W) window)))
            (ert-info ((format "%s" "table-measure-without-destination-edits"))
              (should (= width 3500))
              (should (equal measured (list (make-string 500 ?W) source window)))
              (should (= tick (buffer-modified-tick)))
              (should (eq selected (selected-window))))))))))

;; Pixel measurement is temporary even when the display primitive fails.
(ert-deftest dsh-emacs-test-markdown-table-measure-result-case-case ()
  :tags '(dsh-unit)
  (dolist (fail '(nil t))
    (dolist (modified '(nil t))
      (save-window-excursion
        (with-temp-buffer
          (buffer-enable-undo)
          (insert (propertize "draft 草稿" 'face 'italic))
          (goto-char 3)
          (setq-local face-remapping-alist '((default (:height 1.5) default)))
          (set-buffer-modified-p modified)
          (setq buffer-undo-list nil)
          (let* ((emacs-major-version 27)
                 (selected (selected-window))
                 (window (split-window-right))
                 (source (current-buffer))
                 (tick (buffer-chars-modified-tick))
                 (before (buffer-string))
                 (end (copy-marker (point-max) t))
                 (buffer-read-only t)
                 result caught)
            (set-window-buffer window (current-buffer))
            (cl-letf (((symbol-function 'window-text-pixel-size)
                       (lambda (_window from to &rest _)
                         (unless (and (not (eq (current-buffer) source))
                                      (equal face-remapping-alist
                                             (buffer-local-value
                                              'face-remapping-alist source))
                                      (equal (buffer-substring-no-properties from to)
                                             "probe 中文"))
                           (error "Wrong measurement range"))
                         (if fail (error "Measurement failed") '(42 . 10)))))
              (condition-case err
                  (setq result (dsh-emacs-markdown--table-measure-string
                                "probe 中文" window))
                (error (setq caught err))))
            (ert-info ((format "%s" (format "table-measure-result-%s-%s" fail modified)))
              (should (if fail (equal caught '(error "Measurement failed"))
                        (and (null caught) (= result 42)))))
            (ert-info ((format "%s" (format "table-measure-restores-draft-%s-%s" fail modified)))
              (should (equal-including-properties before (buffer-string)))
              (should (= tick (buffer-chars-modified-tick)))
              (should (eq (window-buffer window) source))
              (should (eq (selected-window) selected))
              (should (= (point) 3))
              (should (= end (1+ (length before))))
              (should (eq (buffer-modified-p) modified))
              (should (null buffer-undo-list))
              (should buffer-read-only))
            (set-marker end nil)))))))

(ert-deftest dsh-emacs-test-markdown-emphasis-keeps-real-left-context-case ()
  :tags '(dsh-unit)
  (dolist (text '("word*literal*" "word_underscore_" "word__literal__"
                  "5*3 and 6*4"))
    (with-temp-buffer
      (insert text)
      (dsh-emacs-markdown-replace-markup)
      (ert-info ((format "%s" (format "emphasis-keeps-real-left-context-%s" text)))
        (should (equal (buffer-substring-no-properties (point-min) (point-max)) text))))))

;; Plain text needs no emphasis passes, and repeated formatting is write-free.
(ert-deftest dsh-emacs-test-markdown-markdown-plain-text-skips-emphasis-passes ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (insert "plain 中文 text\nnext line")
    (let ((calls 0))
      (cl-letf (((symbol-function 'dsh-emacs-markdown--replace-bolds)
                 (lambda (&rest _) (cl-incf calls) nil))
                ((symbol-function 'dsh-emacs-markdown--replace-italics)
                 (lambda (&rest _) (cl-incf calls) nil))
                ((symbol-function 'dsh-emacs-markdown--replace-strikethroughs)
                 (lambda (&rest _) (cl-incf calls) nil)))
        (dsh-emacs-markdown-replace-markup))
      (ert-info ((format "%s" "markdown-plain-text-skips-emphasis-passes"))
        (should (= calls 0))
        (should (equal (buffer-substring-no-properties (point-min) (point-max))
                       "plain 中文 text\nnext line"))))
    (let ((tick (buffer-modified-tick)))
      (dsh-emacs-markdown-replace-markup)
      (ert-info ((format "%s" "markdown-unchanged-plain-text-does-not-write"))
        (should (= tick (buffer-modified-tick)))))))

;; A resource scan skips plain runs instead of testing every character.
(ert-deftest dsh-emacs-test-markdown-resource-scan-skips-plain-runs ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (insert (make-string 2000 ?a) "\n"
            "plain " (make-string 2000 ?b) "\n"
            "[link](https://example.test)\n")
    (let ((checks 0)
          (scan (symbol-function 'dsh-emacs-markdown--in-avoid-range-p)))
      (cl-letf (((symbol-function 'dsh-emacs-markdown--in-avoid-range-p)
                 (lambda (&rest args)
                   (setq checks (1+ checks))
                   (apply scan args))))
        (should (= (length (dsh-emacs-markdown--inline-resources)) 1)))
      (ert-info ((format "avoid-range checks: %d" checks))
        ;; One check per line start and interesting character, not one per
        ;; buffer character.
        (should (< checks 20))))))

(ert-deftest dsh-emacs-test-markdown-resource-scan-crosses-field-boundaries ()
  :tags '(dsh-unit)
  (let ((inhibit-field-text-motion nil)
        (line-end (symbol-function 'line-end-position))
        (calls 0)
        rendered opened)
    (cl-letf (((symbol-function 'line-end-position)
               (lambda (&rest args)
                 ;; Bound the failed scan so this regression cannot hang ERT.
                 (when (> (cl-incf calls) 100)
                   (ert-fail "Resource scan stuck at a field boundary"))
                 (apply line-end args))))
      (setq rendered
            (dsh-emacs-markdown-convert
             (concat (propertize "aaaa" 'field 'first)
                     (propertize "bbbb [la" 'field 'second)
                     (propertize "bel](https://example.test/pa" 'field 'third)
                     (propertize "th)\n" 'field 'fourth)))))
    (should (equal (substring-no-properties rendered) "aaaabbbb label\n"))
    (should (eq (get-text-property 0 'field rendered) 'first))
    (should (eq (get-text-property 4 'field rendered) 'second))
    (let ((command (lookup-key (get-text-property 9 'keymap rendered)
                               (kbd "RET"))))
      (should (commandp command))
      (cl-letf (((symbol-function 'browse-url)
                 (lambda (url &rest _) (setq opened url))))
        (call-interactively command)))
    (should (equal opened "https://example.test/path"))
    (should-not inhibit-field-text-motion)))

(ert-deftest dsh-emacs-test-markdown-markdown-yank-handler-inserts-plain-text ()
  :tags '(dsh-unit)
  (let ((styled (with-temp-buffer
                  (insert "**bold**")
                  (dsh-emacs-markdown-replace-markup)
                  (buffer-string))))
    (with-temp-buffer
      (insert-for-yank styled)
      (ert-info ((format "%s" "markdown-yank-handler-inserts-plain-text"))
        (should (equal (buffer-string) "bold"))
        (should (null (text-properties-at (point-min))))))))

;; --- Test 71: pure-function coverage reinforcement (markdown tables /
;; render-trim / tokens / http hint) ---
;; Pure-logic blind spots exposed by the coverage report
;; (scripts/check-coverage.el): markdown table allocation, display width,
;; longest word, render--trim boundaries, format-cost branches, usage-p,
;; http-error-hint.
(ert-deftest dsh-emacs-test-markdown-table-allocate-keeps-when-no-shrink ()
  :tags '(dsh-unit)
  (let ((pass-n 0))
    ;; markdown table: width allocation (verbatim when there is slack)
    (ert-info ((format "%s" "table-allocate-keeps-when-no-shrink"))
      (should (equal '(5 5) (dsh-emacs-markdown--table-allocate-widths '(5 5) '(2 2) 18))))
    ;; when compression is needed, allocate by shrinkable ratio, never below
    ;; min-widths
    (ert-info ((format "%s" "table-allocate-shrinks-to-fit"))
      (should (equal '(3 3 3) (dsh-emacs-markdown--table-allocate-widths '(10 10 10) '(3 3 3) 20))))
    ;; return min-widths directly when the shrinkable amount is 0
    (ert-info ((format "%s" "table-allocate-min-bound"))
      (should (equal '(10 3) (dsh-emacs-markdown--table-allocate-widths '(10 3) '(10 3) 10))))
    ;; total width = each column + 3 (padding both sides + separator pipe),
    ;; plus the leading pipe
    (ert-info ((format "%s" "table-total-width-counts-borders"))
      (should (= 15 (dsh-emacs-markdown--table-total-width '(4 4)))))
    ;; longest word (no window: the string-width path)
    (ert-info ((format "%s" "table-longest-word-ascii"))
      (should (= 9 (dsh-emacs-markdown--table-longest-word :str "alpha beta-long gamma"))))
    ;; longest word of an empty string = 0
    (ert-info ((format "%s" "table-longest-word-empty"))
      (should (= 0 (dsh-emacs-markdown--table-longest-word :str ""))))
    ;; display width: ASCII goes through string-width; Chinese counted by character
    (ert-info ((format "%s" "table-display-width-char-count"))
      (should (and (= 7 (dsh-emacs-markdown--table-display-width :str "abc def"))
                   (= 8 (dsh-emacs-markdown--table-display-width :str "中文测试")))))
    ;; render--trim: collapse whitespace + truncate with an ellipsis
    (ert-info ((format "%s" "render-trim-folds-and-ellipsizes"))
      (should (equal "hello …" (dsh-emacs-render--trim "  hello   world  " 6))))
    ;; render--trim: multi-line/tab collapsing
    (ert-info ((format "%s" "render-trim-folds-newlines"))
      (should (equal "…" (dsh-emacs-render--trim "a\nb\tc" 0))))
    ;; format-cost branches
    (ert-info ((format "%s" "format-cost-branches"))
      (should (and (equal "$0.000" (dsh-emacs-format-cost nil))
                   (equal "<$0.001" (dsh-emacs-format-cost 0.0005))
                   (equal "$0.000" (dsh-emacs-format-cost "x"))
                   (equal "$1.234" (dsh-emacs-format-cost 1.234)))))
    ;; http-error-hint: 4xx/5xx hint that the RPC does not exist, other codes
    ;; short form, non-error empty
    (ert-info ((format "%s" "http-error-hint-branches"))
      (should (and (string-match-p "HTTP 404" (dsh-emacs--http-error-hint '(error http 404)))
                   (string-match-p "HTTP 500" (dsh-emacs--http-error-hint '(error http 500)))
                   (equal " (HTTP 302)" (dsh-emacs--http-error-hint '(error http 302)))
                   (equal "" (dsh-emacs--http-error-hint nil)))))
    pass-n))

;; Code blocks reuse one fontification buffer per mode: the mode is set up
;; once, and a previous block's text or faces never leak into the next.
(ert-deftest dsh-emacs-test-markdown-markdown-highlight-reuses-mode-buffer ()
  :tags '(dsh-unit)
  (let* ((buffer (get-buffer " *dsh-emacs-markdown-fontify:emacs-lisp-mode*"))
         (setups 0)
         (count (lambda (&rest _) (cl-incf setups))))
    (when buffer (kill-buffer buffer))
    (advice-add 'emacs-lisp-mode :before count)
    (unwind-protect
        (let* ((first (dsh-emacs-markdown--highlight-code "\"open string" "elisp"))
               (second (dsh-emacs-markdown--highlight-code "(foo)" "elisp")))
          (ert-info ((format "%s" "markdown-highlight-reuses-mode-buffer"))
            (should (= setups 1))
            (should (memq 'font-lock-string-face
                          (ensure-list (get-text-property 1 'face first))))
            (should (equal-including-properties
                     second (dsh-emacs-markdown--highlight-code "(foo)" "emacs-lisp")))
            (should (string= second "(foo)"))
            (should (not (memq 'font-lock-string-face
                               (ensure-list (get-text-property 1 'face second)))))))
      (advice-remove 'emacs-lisp-mode count))))

;; Emacs draws adjacent characters whose `display' values are `eq' once, so
;; nested `>>' would collapse into a single bar if both shared one object.
(ert-deftest dsh-emacs-test-markdown-markdown-nested-blockquote-bars-stay-distinct ()
  :tags '(dsh-unit)
  (let* ((rendered (dsh-emacs-markdown-render ">> nested\n"))
         (first (get-text-property 0 'display rendered))
         (second (get-text-property 1 'display rendered)))
    (ert-info ((format "%s" "markdown-nested-blockquote-bars-stay-distinct"))
      (should (stringp first))
      (should (equal first second))
      (should (not (eq first second))))))

(ert-deftest dsh-emacs-test-markdown-image-destinations ()
  :tags '(dsh-unit)
  (dolist (case '(("%s" ".png")
                  ("<%s>" ".png")
                  ("<%s>" " preview (dark).png")
                  ("<file://%s>" " preview (dark).png")))
    (let* ((file (make-temp-file "dsh-image-" nil (cadr case)))
           (image (list 'image :file file))
           opened)
      (unwind-protect
          (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                    ((symbol-function 'image-supported-file-p)
                     (lambda (path) (equal path file)))
                    ((symbol-function 'create-image)
                     (lambda (path &rest _) (should (equal path file)) image))
                    ((symbol-function 'image-flush) #'ignore)
                    ((symbol-function 'find-file)
                     (lambda (path) (setq opened path))))
            (let* ((source (format "![preview](%s)" (format (car case) file)))
                   (rendered (dsh-emacs-markdown-render source))
                   (map (get-text-property 0 'keymap rendered)))
              (ert-info ((format "destination=%s" source))
                (should (equal rendered "preview\n"))
                (should (eq (get-text-property 0 'display rendered) image))
                (should (keymapp map))
                (funcall (lookup-key map (kbd "RET")))
                (should (equal opened file)))))
        (delete-file file)))))

(ert-deftest dsh-emacs-test-markdown-image-rendering-boundaries ()
  :tags '(dsh-unit)
  (let ((file (make-temp-file "dsh-image-" nil ".png")))
    (unwind-protect
        (dolist (case '(inline fenced terminal missing remote))
          (let* ((url (pcase case
                        ('missing (concat file ".missing"))
                        ('remote "https://example.invalid/image.png")
                        (_ file)))
                 (markup (format "![preview](<%s>)" url))
                 (source (format (pcase case
                                   ('inline "`%s`")
                                   ('fenced "```text\n%s\n```")
                                   (_ "%s"))
                                 markup)))
            (cl-letf (((symbol-function 'display-graphic-p)
                       (lambda (&rest _) (not (eq case 'terminal))))
                      ((symbol-function 'image-supported-file-p) (lambda (_) t))
                      ((symbol-function 'create-image)
                       (lambda (&rest _) (ert-fail "Image must stay unrendered"))))
              (ert-info ((format "boundary=%s" case))
                (should (string-match-p
                         (regexp-quote markup)
                         (dsh-emacs-markdown-render source)))))))
      (delete-file file))))

;; Extensions are deliberately prefix-distinct: `regexp-opt' factors a common
;; prefix ("aaaimg" "bbimg" compile to \(?:aaa\|bb\)img), so a literal
;; extension must survive in the compiled regexp for the checks below.
(ert-deftest dsh-emacs-test-markdown-markdown-image-path-regexp-cache ()
  :tags '(dsh-unit)
  (let ((dsh-emacs-markdown--image-path-regexp nil)
        (image-file-name-extensions (list "zzimg")))
    (with-temp-buffer
      (dsh-emacs-markdown--replace-image-file-paths)
      (let ((cached dsh-emacs-markdown--image-path-regexp))
        (dsh-emacs-markdown--replace-image-file-paths)
        (let ((reused (eq cached dsh-emacs-markdown--image-path-regexp)))
          (setq image-file-name-extensions (list "yyimg"))
          (dsh-emacs-markdown--replace-image-file-paths)
          (ert-info ((format "%s" "markdown-image-path-regexp-cache"))
            (should reused)
            (should (string-match-p "zzimg" (cdr cached)))
            (should (string-match-p "yyimg" (cdr dsh-emacs-markdown--image-path-regexp)))
            (should (not (string-match-p
                          "zzimg" (cdr dsh-emacs-markdown--image-path-regexp))))))))))

(ert-deftest dsh-emacs-test-markdown-markdown-image-path-regexp-cache-tracks-edits ()
  :tags '(dsh-unit)
  (let ((dsh-emacs-markdown--image-path-regexp nil)
        (image-file-name-extensions (list "qqimg" "wwimg")))
    (dsh-emacs-markdown--replace-image-file-paths)   ; warm the cache
    (let ((first (cdr dsh-emacs-markdown--image-path-regexp)))
      ;; Ordinary configuration: a new list object with the same contents.
      (setq image-file-name-extensions (list "qqimg" "wwimg"))
      (dsh-emacs-markdown--replace-image-file-paths)
      ;; In-place mutation of the very list the cache was built from: the
      ;; variable still reads `qqimg', so keying the cache on identity would
      ;; serve the regexp above and never learn about `eeimg'.
      (setcar (cdr image-file-name-extensions) "eeimg")
      (dsh-emacs-markdown--replace-image-file-paths)
      (let ((rebuilt (cdr dsh-emacs-markdown--image-path-regexp)))
        (ert-info ((format "%s" "markdown-image-path-regexp-cache-tracks-edits"))
          (should (and (string-match-p rebuilt "/tmp/pic.qqimg") t))
          (should (not (string-match-p rebuilt "/tmp/pic.wwimg")))
          (should (and (string-match-p rebuilt "/tmp/pic.eeimg") t)))))))

;; --- Test 72: markdown parsing layer pure-function reinforcement (coverage
;; report class A blind spots) ---
;; Target: deconstruct / highlight-code / table-min-widths / shorten-cwd /
;; insert-read-only / resolve-image-url / parse-local-link (needs temp files).
(ert-deftest dsh-emacs-test-markdown-markdown-deconstruct-splits-face-runs ()
  :tags '(dsh-unit)
  (let ((tmpdir (make-temp-file "dsh-cov" t)))
    (unwind-protect
        (progn
          ;; markdown--deconstruct: splitting into contiguous face runs
          (ert-info ((format "%s" "markdown-deconstruct-splits-face-runs"))
            (should (equal '(("my" (dsh-emacs-markdown-italic))
                             (" " nil)
                             ("text" (dsh-emacs-markdown-bold)))
                           (dsh-emacs-markdown--deconstruct
                            (dsh-emacs-markdown-convert "_my_ **text**")))))
          ;; highlight-code: a real mode (elisp) font-locks the face,
          ;; unknown language verbatim
          (let ((hl (dsh-emacs-markdown--highlight-code "(defun f () 1)" "elisp")))
            (ert-info ((format "%s" "markdown-highlight-elisp-applies-face"))
              (should (and (string= hl "(defun f () 1)")
                           (get-text-property 1 'face hl)))))
          (ert-info ((format "%s" "markdown-highlight-unknown-lang-pass-through"))
            (should (equal "abc" (dsh-emacs-markdown--highlight-code "abc" "nolangxyz"))))
          ;; table-min-widths: longest word per column
          (ert-info ((format "%s" "markdown-table-min-widths-longest-word"))
            (should (equal '(6 3)
                           (dsh-emacs-markdown--table-min-widths
                            :processed-rows '(("hdr" "a b" "ccc")
                                              ("row" "longer" "dd"))))))
          ;; shorten-cwd: home prefix -> ~, deep path -> ../last two segments
          (ert-info ((format "%s" "shorten-cwd-home-prefix"))
            (should (equal "~/src/foo"
                           (dsh-emacs-session--shorten-cwd
                            (format "%s/src/foo" (expand-file-name "~"))))))
          (ert-info ((format "%s" "shorten-cwd-deep-path"))
            (should (equal "../d/e" (dsh-emacs-session--shorten-cwd "/a/b/c/d/e"))))
          ;; insert-read-only: text carries read-only + face properties
          (with-temp-buffer
            (dsh-emacs-render--insert-read-only "hi" 'dsh-emacs-test-face)
            (ert-info ((format "%s" "render-insert-read-only-props"))
              (should (and (equal t (get-text-property 1 'read-only))
                           (eq 'dsh-emacs-test-face (get-text-property 1 'face))))))
          ;; resolve-image-url: local file in its various forms,
          ;; nil when it does not exist
          (let ((f (expand-file-name "img.png" tmpdir)))
            (with-temp-file f)
            (ert-info ((format "%s" "resolve-image-url-file-uri"))
              (should (equal f (dsh-emacs-markdown--resolve-image-url
                                (concat "file://" f)))))
            (ert-info ((format "%s" "resolve-image-url-absolute"))
              (should (equal f (dsh-emacs-markdown--resolve-image-url f))))
            (ert-info ((format "%s" "resolve-image-url-missing-nil"))
              (should (null (dsh-emacs-markdown--resolve-image-url
                             (concat tmpdir "/missing.png"))))))
          ;; parse-local-link: file:// URI, file: prefix,
          ;; relative path + line number, nil for non-local
          (let ((f (expand-file-name "foo.el" tmpdir)))
            (with-temp-file f)
            (let ((parsed (dsh-emacs-markdown--parse-local-link
                           (concat f "#L10"))))
              (ert-info ((format "%s" "parse-local-link-hash-line"))
                (should (and (equal (expand-file-name f) (car parsed))
                             (equal 10 (cadr parsed))))))
            (let ((parsed (dsh-emacs-markdown--parse-local-link
                           (concat "file://" f ":5"))))
              (ert-info ((format "%s" "parse-local-link-file-colon"))
                (should (and (equal (expand-file-name f) (car parsed))
                             (equal 5 (cadr parsed))))))
            (ert-info ((format "%s" "parse-local-link-remote-nil"))
              (should (null (dsh-emacs-markdown--parse-local-link
                             "https://example.com/path"))))))
      (delete-directory tmpdir t))))

(ert-deftest dsh-emacs-test-markdown-resource-markers-end-before-emphasis ()
  :tags '(dsh-unit)
  (let ((scan (symbol-function 'dsh-emacs-markdown--inline-resources))
        (bold (symbol-function 'dsh-emacs-markdown--replace-bolds))
        resources checked opened)
    (with-temp-buffer
      (insert "[**label**](https://example.test) ![raw](missing**file**.png)")
      (cl-letf (((symbol-function 'dsh-emacs-markdown--inline-resources)
                 (lambda (&rest args)
                   (setq resources (apply scan args))))
                ((symbol-function 'dsh-emacs-markdown--replace-bolds)
                 (lambda (&rest args)
                   (should (= (length resources) 2))
                   ;; Resolved labels carry identity in text properties;
                   ;; only raw destinations still need moving parse markers.
                   (dolist (marker (seq-take (car resources) 4))
                     (should-not (marker-buffer marker)))
                   (dolist (marker (seq-take (cadr resources) 4))
                     (should (eq (marker-buffer marker) (current-buffer))))
                   (setq checked t)
                   (apply bold args))))
        (dsh-emacs-markdown-replace-markup :render-images nil))
      (should checked)
      (should (equal (buffer-string) "label ![raw](missing**file**.png)"))
      (should (memq 'dsh-emacs-markdown-bold
                    (ensure-list (get-text-property 1 'face))))
      (should (get-text-property 1 'dsh-emacs-markdown-frozen))
      (let ((command (lookup-key (get-text-property 1 'keymap) (kbd "RET"))))
        (should (commandp command))
        (cl-letf (((symbol-function 'browse-url)
                   (lambda (url &rest _) (setq opened url))))
          (call-interactively command)))
      (should (equal opened "https://example.test")))))

;; Markdown destinations in angle brackets are syntax, not part of the path.
;; Exercise the rendered RET command, including a destination containing `)'.
(ert-deftest dsh-emacs-test-markdown-markdown-angle-link-label-case ()
  :tags '(dsh-unit)
  (let ((directory (make-temp-file "dsh-link" t)))
    (unwind-protect
        (dolist (name '("source.el" "source (draft).el"))
          (let ((file (expand-file-name name directory)))
            (with-temp-file file (insert "first\nsecond\nthird\n"))
            (with-temp-buffer
              (insert (dsh-emacs-markdown-convert
                       (format "[source](<%s#L2>)" file)))
              (goto-char (point-min))
              (let ((command (lookup-key (get-text-property (point) 'keymap)
                                         (kbd "RET")))
                    opened browsed)
                (ert-info ((format "%s" (format "markdown-angle-link-label-%s" name)))
                  (should (equal (buffer-string) "source")))
                (cl-letf (((symbol-function 'find-file)
                           (lambda (path &rest _)
                             (setq opened path)
                             (erase-buffer)
                             (insert-file-contents path)))
                          ((symbol-function 'browse-url)
                           (lambda (url &rest _) (setq browsed url))))
                  (call-interactively command))
                (ert-info ((format "%s" (format "markdown-angle-link-ret-%s" name)))
                  (should (equal opened file))
                  (should (null browsed))
                  (should (= (line-number-at-pos) 2)))))))
      (delete-directory directory t))))

(ert-deftest dsh-emacs-test-markdown-line-range-links-open-locally ()
  :tags '(dsh-unit)
  (let* ((directory (make-temp-file "dsh-link-range" t))
         (file (expand-file-name "source.el" directory)))
    (unwind-protect
        (progn
          (with-temp-file file (insert "first\nsecond\nthird\nfourth\n"))
          (dolist (target (list "source.el#L2-L3" "source.el#L2-3"
                                "source.el:2-3" "file:source.el#L2-L3"
                                (concat file "#L2-L3")
                                (concat "file://" file "#L2-L3")
                                (concat "file://" file ":2-3")))
            (ert-info ((format "line-range target: %s" target))
              (with-temp-buffer
                (setq default-directory (file-name-as-directory directory))
                (insert (dsh-emacs-markdown-convert
                         (format "[`some-function`](<%s>)" target)))
                (goto-char (point-min))
                (should (equal (buffer-string) "some-function"))
                (let ((command (lookup-key
                                (get-text-property (point) 'keymap)
                                (kbd "RET")))
                      opened browsed)
                  (should (commandp command))
                  (cl-letf (((symbol-function 'find-file)
                             (lambda (path &rest _)
                               (setq opened path)
                               (erase-buffer)
                               (insert-file-contents path)))
                            ((symbol-function 'browse-url)
                             (lambda (url &rest _) (setq browsed url))))
                    (call-interactively command))
                  (should (equal opened file))
                  (should-not browsed)
                  (should (= (line-number-at-pos) 2))
                  (should (equal (buffer-substring
                                  (line-beginning-position) (line-end-position))
                                 "second")))))))
      (delete-directory directory t))))

(ert-deftest dsh-emacs-test-markdown-bare-image-path-is-literal ()
  :tags '(dsh-unit)
  (let ((file (make-temp-file "dsh-bare-%20#tag-" nil ".png")))
    (unwind-protect
        (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                  ((symbol-function 'image-supported-file-p) (lambda (_) t))
                  ((symbol-function 'create-image)
                   (lambda (path &rest _) (list 'image :file path)))
                  ((symbol-function 'image-flush) #'ignore))
          (let ((rendered (dsh-emacs-markdown-render file)))
            (should (equal (get-text-property 0 'display rendered)
                           (list 'image :file file)))
            (should (keymapp (get-text-property 0 'keymap rendered)))))
      (delete-file file))))

(ert-deftest dsh-emacs-test-markdown-image-local-path-boundaries ()
  :tags '(dsh-unit)
  (let* ((directory (make-temp-file "dsh-image-url-" t))
         (default-directory (file-name-as-directory directory)))
    (unwind-protect
        (progn
          (dolist (name '("image.png" "space name.png" "percent%20.png"
                          "hash#name.png" "caf\u00e9.png"))
            (with-temp-file (expand-file-name name directory)))
          (dolist (case '(("image.png" "image.png")
                          ("./image.png" "image.png")
                          ("space%20name.png" "space name.png")
                          ("percent%2520.png" "percent%20.png")
                          ("hash%23name.png" "hash#name.png")
                          ("caf%C3%A9.png" "caf\u00e9.png")
                          ("file:space%20name.png" "space name.png")))
            (ert-info ((car case))
              (should (equal (dsh-emacs-markdown--resolve-image-url (car case))
                             (expand-file-name (cadr case) directory)))))
          (dolist (url (list (concat "file://remote.invalid" directory "/image.png")
                             "https://example.invalid/image.png" directory
                             "image%00.png" "image%ZZ.png" "image%FF.png"))
            (ert-info (url)
              (should-not (dsh-emacs-markdown--resolve-image-url url)))))
      (delete-directory directory t))))

(ert-deftest dsh-emacs-test-markdown-local-target-boundaries ()
  :tags '(dsh-unit)
  (let* ((directory (make-temp-file "dsh-target-" t))
         (default-directory (file-name-as-directory directory)))
    (unwind-protect
        (progn
          (dolist (name '("source.el" "space name.el" "percent%20.el" "hash#L24.el"))
            (with-temp-file (expand-file-name name directory)
              (insert "first\nsecond\nthird\n")))
          (dolist (case '(("space%20name.el" "space name.el" nil nil)
                          ("percent%2520.el" "percent%20.el" nil nil)
                          ("hash%23L24.el" "hash#L24.el" nil nil)
                          ("source.el#L2-L3" "source.el" 2 nil)
                          ("source.el#L2-3" "source.el" 2 nil)
                          ("source.el:2:3" "source.el" 2 3)
                          ("source.el#L2C3" "source.el" 2 3)
                          ("file:source.el:2" "source.el" 2 nil)))
            (ert-info ((car case))
              (should (equal (dsh-emacs-markdown--parse-local-link (car case))
                             (cons (expand-file-name (cadr case) directory)
                                   (cddr case))))))
          (should (equal (dsh-emacs-markdown--parse-local-link
                          (concat "file://localhost" directory "/space%20name.el#L2"))
                         (list (expand-file-name "space name.el" directory) 2 nil)))
          (dolist (url '("source.el#L0" "source.el#L02" "source.el#L2-L1"
                         "source.el:0" "source.el:2:0" "source.el#heading"
                         "file://remote.invalid/tmp/source.el"
                         "//remote.invalid/a.el" "/ssh:host:/tmp/source.el"
                         "source%ZZ.el" "source%00.el" "source.el?query"))
            (ert-info (url)
              (should-not (dsh-emacs-markdown--parse-local-link url)))))
      (delete-directory directory t))))

(ert-deftest dsh-emacs-test-markdown-local-link-errors-stay-local ()
  :tags '(dsh-unit)
  (cl-letf (((symbol-function 'browse-url)
             (lambda (&rest _) (ert-fail "Must not browse a local or unsafe URL"))))
    (dolist (url '("./missing-source.el#L2" "javascript:alert(1)"
                   "data:text/html,hello" "file://remote.invalid/tmp/source.el"))
      (ert-info (url)
        (should-error (dsh-emacs-markdown--open-link url) :type 'user-error)))))

(ert-deftest dsh-emacs-test-markdown-local-link-position-and-routing ()
  :tags '(dsh-unit)
  (let ((file (make-temp-file "dsh-position-" nil ".el")))
    (unwind-protect
        (progn
          (with-temp-file file (insert "first\nsecond\twide\nthird\n"))
          (dolist (case '(("#L2C3" 2 2) (":2:999" 2 11) ("#L999C999" 4 0)))
            (with-temp-buffer
              (insert-file-contents file)
              (goto-char (point-min))
              (forward-line 2)
              (narrow-to-region (point) (point-max))
              (cl-letf (((symbol-function 'find-file)
                         (lambda (path) (should (equal path file)))))
                (dsh-emacs-markdown--open-link (concat file (car case))))
              (should-not (buffer-narrowed-p))
              (should (= (line-number-at-pos) (cadr case)))
              (should (= (- (point) (line-beginning-position)) (caddr case)))))
          (let (opened)
            (cl-letf (((symbol-function 'browse-url) (lambda (url) (push url opened)))
                      ((symbol-function 'find-file)
                       (lambda (&rest _) (ert-fail "External URL opened locally"))))
              (dolist (url '("https://example.com/a#L2" "HTTP://example.com" "mailto:a@example.com"))
                (dsh-emacs-markdown--open-link url)))
            (should (equal (reverse opened)
                           '("https://example.com/a#L2" "HTTP://example.com" "mailto:a@example.com")))))
      (delete-file file))))

;; Table wrapping must measure each character once, retaining layout and faces.
(ert-deftest dsh-emacs-test-markdown-table-wrap-single-measure-case ()
  :tags '(dsh-unit)
  (dolist (case '(("alpha beta gamma" 8 ("alpha" "beta" "gamma"))
                  ("你好世界 hello" 5 ("你好" "世界" "hello"))
                  ("a⚠️ b" 3 ("a⚠️" "b"))
                  ("abcdefgh" 3 ("abc" "def" "gh"))
                  ("a\tb" 4 ("a" "b"))
                  ("á b" 2 ("á" "b"))
                  ("ab  " 10 ("ab  "))
                  ("界" 1 ("界"))
                  ("" 4 (""))))
    (pcase-let ((`(,text ,width ,expected) case))
      (let ((calls 0)
            (measure (symbol-function 'dsh-emacs-markdown--table-wrap-char-width)))
        (cl-letf (((symbol-function 'dsh-emacs-markdown--table-wrap-char-width)
                   (lambda (&rest args)
                     (setq calls (1+ calls))
                     (apply measure args))))
          (ert-info ((format "%s" (format "table-wrap-single-measure-%S" text)))
            (should (equal (dsh-emacs-markdown--table-wrap-text text width) expected))
            (should (= calls (length text)))))))))

(ert-deftest dsh-emacs-test-markdown-table-wrap-preserves-face-dependent-width-and-properties ()
  :tags '(dsh-unit)
  (let* ((styled (propertize "WW" 'face 'bold))
         (text (concat styled " xx")))
    (cl-letf (((symbol-function 'dsh-emacs-markdown--table-wrap-char-width)
               (lambda (str pos &optional _window)
                 (if (get-text-property pos 'face str) 2 1))))
      (ert-info ((format "%s" "table-wrap-preserves-face-dependent-width-and-properties"))
        (should (equal-including-properties
                 (dsh-emacs-markdown--table-wrap-text text 4)
                 (list styled "xx")))))))

(ert-deftest dsh-emacs-test-markdown-inline-runs-match-exact-width ()
  :tags '(dsh-unit)
  (dolist (case '(("`plain`" "plain")
                  ("``one ` two``" "one ` two")
                  ("```one `` two ` three```" "one `` two ` three")
                  ("``one ``` two``" "one ``` two")
                  ("``one ` two" "one ` two")
                  ("``one``` tail" "one``` tail")
                  ("`one`` tail" "one`` tail")
                  ("`` ``" " ")
                  ("``" "")))
    (with-temp-buffer
      (insert (car case))
      (let ((ranges (dsh-emacs-markdown--inline-code-ranges)))
        (ert-info ((car case))
          (should (= (length ranges) 1))
          (should (equal (buffer-substring (caar ranges) (cdar ranges))
                         (cadr case))))))))

(ert-deftest dsh-emacs-test-markdown-inline-runs-protect-images-and-markup ()
  :tags '(dsh-unit)
  (let ((file (make-temp-file "dsh-inline-runs-" nil ".png")))
    (unwind-protect
        (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                  ((symbol-function 'image-supported-file-p) (lambda (_) t))
                  ((symbol-function 'create-image)
                   (lambda (&rest _) (ert-fail "Inline code became an image"))))
          (dolist (ticks '("`" "``" "```" "````"))
            (let* ((body (format "![x](<%s>) **bold** [link](<%s>)" file file))
                   (rendered (dsh-emacs-markdown-render
                              (concat "code: " ticks body ticks))))
              (ert-info (ticks)
                (should (equal rendered (concat "code: " body "\n")))
                (should (eq (get-text-property 6 'face rendered)
                            'dsh-emacs-markdown-inline-code))
                (should-not (text-property-not-all
                             6 (+ 6 (length body))
                             'dsh-emacs-markdown-frozen t rendered))
                (should-not (text-property-not-all
                             0 (length rendered) 'display nil rendered))
                (should-not (text-property-not-all
                             0 (length rendered) 'keymap nil rendered))))))
      (delete-file file))))

(ert-deftest dsh-emacs-test-markdown-inline-runs-preserve-markers-and-literals ()
  :tags '(dsh-unit)
  (dolist (ticks '("`" "``" "```"))
    (with-temp-buffer
      (let* ((body (if (equal ticks "`") "a **b**" "a `b` **c**"))
             (width (length ticks)))
        (insert ticks body ticks " tail")
        (let ((start (copy-marker (1+ width)))
              (middle (copy-marker (+ 3 width)))
              (end (copy-marker (+ 1 width (length body)))))
          (dsh-emacs-markdown--style-inline-code)
          (should (equal (buffer-string) (concat body " tail")))
          (should (= start 1))
          (should (= middle 3))
          (should (= end (1+ (length body))))
          (should (equal (buffer-substring start end) body))
          ;; Frozen literal ticks must not become new delimiters on a rerender.
          (let ((once (buffer-string)))
            (dsh-emacs-markdown--style-inline-code)
            (should (equal-including-properties (buffer-string) once)))
          (mapc (lambda (marker) (set-marker marker nil))
                (list start middle end)))))))

(ert-deftest dsh-emacs-test-markdown-inline-runs-keep-unmatched-line-local ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (insert "``one `literal`\n`next`\n``two``` tail")
    (should (equal (mapcar (lambda (range)
                             (buffer-substring (car range) (cdr range)))
                           (dsh-emacs-markdown--inline-code-ranges))
                   '("one `literal`" "next" "two``` tail")))
    (dsh-emacs-markdown--style-inline-code)
    (should (equal (buffer-string)
                   "``one `literal`\nnext\n``two``` tail"))))

(ert-deftest dsh-emacs-test-markdown-inline-runs-streaming-protection ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (insert "code: ``**bold** [link](<missing.el>) `literal` ")
    (let ((pending (buffer-string)))
      (dsh-emacs-markdown-replace-markup)
      (should (equal (buffer-string) pending)))
    (goto-char (point-max))
    (insert "``\n")
    (dsh-emacs-markdown-replace-markup)
    (should (equal (buffer-string)
                   "code: **bold** [link](<missing.el>) `literal` \n"))
    (should (get-text-property 7 'dsh-emacs-markdown-frozen))
    (should-not (text-property-not-all (point-min) (point-max) 'keymap nil))))

(ert-deftest dsh-emacs-test-markdown-resource-destinations-preserve-literal-markup ()
  :tags '(dsh-unit)
  (let* ((directory (make-temp-file "dsh-resource-" t))
         (default-directory (file-name-as-directory directory)))
    (unwind-protect
        (dolist (name '("a *draft*.el" "a _draft_.el" "a ~~draft~~.el"
                        "a `draft`.el" "a (draft).el"))
          (let ((file (expand-file-name name directory)) opened)
            (with-temp-file file (insert "target\n"))
            (let* ((rendered (dsh-emacs-markdown-convert
                              (format "[a *label*](<%s> \"a `title`\")" file)))
                   (command (lookup-key (get-text-property 0 'keymap rendered)
                                        (kbd "RET"))))
              (should (equal rendered "a label"))
              (should (memq 'dsh-emacs-markdown-italic
                            (ensure-list (get-text-property 2 'face rendered))))
              (should (commandp command))
              (cl-letf (((symbol-function 'find-file)
                         (lambda (path &rest _) (setq opened path))))
                (call-interactively command))
              (should (equal opened file)))))
      (delete-directory directory t))))

(ert-deftest dsh-emacs-test-markdown-resource-balanced-destinations-and-titles ()
  :tags '(dsh-unit)
  (dolist (case '(("[x](https://example.test/a(b(c)))" "https://example.test/a(b(c))")
                  ("[x](https://example.test/a\\(b\\) \"title\")" "https://example.test/a(b)")
                  ("[x](<https://example.test/a(b)> 'title')" "https://example.test/a(b)")
                  ("[x](https://example.test/a (title))" "https://example.test/a")
                  ("[x](https://example.test/a\\*b)" "https://example.test/a*b")))
    (let* ((rendered (dsh-emacs-markdown-convert (car case)))
           (command (lookup-key (get-text-property 0 'keymap rendered) (kbd "RET")))
           opened)
      (should (equal rendered "x"))
      (should (commandp command))
      (cl-letf (((symbol-function 'dsh-emacs-markdown--open-link)
                 (lambda (url) (setq opened url))))
        (call-interactively command))
      (should (equal opened (cadr case))))))

(ert-deftest dsh-emacs-test-markdown-resource-link-captures-render-directory ()
  :tags '(dsh-unit)
  (let* ((directory (make-temp-file "dsh-resource-cwd-" t))
         (file (expand-file-name "source.el" directory)) command opened)
    (unwind-protect
        (progn
          (with-temp-file file (insert "target\n"))
          (let* ((default-directory (file-name-as-directory directory))
                 (rendered (dsh-emacs-markdown-convert "[x](source.el)")))
            (setq command (lookup-key (get-text-property 0 'keymap rendered)
                                      (kbd "RET"))))
          (with-temp-buffer
            (setq default-directory temporary-file-directory)
            (cl-letf (((symbol-function 'find-file)
                       (lambda (path &rest _) (setq opened path)))
                      ((symbol-function 'browse-url)
                       (lambda (&rest _) (ert-fail "Relative target drifted"))))
              (call-interactively command)))
          (should (equal opened file)))
      (delete-directory directory t))))

(ert-deftest dsh-emacs-test-markdown-resource-single-line-and-code-boundaries ()
  :tags '(dsh-unit)
  (dolist (source '("[first\nsecond](https://example.test)"
                    "![first\nsecond](image.png)"
                    "[x](<a\nb>)" "[x](url \"first\nsecond\")"))
    (should (equal (dsh-emacs-markdown-convert source) source)))
  (let ((rendered (dsh-emacs-markdown-convert
                   "`[x](https://example.test)`\n```\n[x](https://example.test)\n```\n")))
    (should-not (get-text-property 0 'keymap rendered))
    (let ((body (string-match "\\[x\\]" rendered 1)))
      (should body)
      (should-not (get-text-property body 'keymap rendered))))
  (dolist (source '("[x](a&amp;b)" "[x](<a<b>)" "[x](url \"unterminated)"))
    (should (equal (dsh-emacs-markdown-convert source) source))))

(ert-deftest dsh-emacs-test-markdown-resource-images-and-linked-image-target ()
  :tags '(dsh-unit)
  (let* ((directory (make-temp-file "dsh-resource-image-" t))
         (file (expand-file-name "a _draft_ `v` (1).png" directory))
         seen opened)
    (unwind-protect
        (progn
          (with-temp-file file (insert "image fixture"))
          (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                    ((symbol-function 'image-supported-file-p) (lambda (_) t))
                    ((symbol-function 'create-image)
                     (lambda (path &rest _) (setq seen path) '(image :type png)))
                    ((symbol-function 'image-flush) #'ignore))
            (let* ((rendered (dsh-emacs-markdown-convert
                              (format "[![alt](<%s>)](https://example.test/outer)" file)))
                   (command (lookup-key (get-text-property 0 'keymap rendered)
                                        (kbd "RET"))))
              (should (equal seen file))
              (should (equal rendered "alt"))
              (should (equal (get-text-property 0 'display rendered) '(image :type png)))
              (cl-letf (((symbol-function 'dsh-emacs-markdown--open-link)
                         (lambda (url) (setq opened url))))
                (call-interactively command))
              (should (equal opened "https://example.test/outer")))))
      (delete-directory directory t))))

(ert-deftest dsh-emacs-test-markdown-resource-rendered-label-is-not-reparsed ()
  :tags '(dsh-unit)
  (with-temp-buffer
    (insert "[[inner](https://example.test/inner)](https://example.test/outer)")
    (dsh-emacs-markdown-replace-markup)
    (should (equal (buffer-string) "[inner](https://example.test/inner)"))
    (dsh-emacs-markdown-replace-markup :force t)
    (should (equal (buffer-string) "[inner](https://example.test/inner)"))
    (let ((command (lookup-key (get-text-property (point-min) 'keymap) (kbd "RET")))
          opened)
      (cl-letf (((symbol-function 'dsh-emacs-markdown--open-link)
                 (lambda (url) (setq opened url))))
        (call-interactively command))
      (should (equal opened "https://example.test/outer")))))

(ert-deftest dsh-emacs-test-markdown-resource-stream-parity ()
  :tags '(dsh-unit)
  (dolist (case '(("[x](<https://example.test/a *draft*.el> \"title\")\n"
                   "https://example.test/a *draft*.el")
                  ("[x](<https://example.test/a `draft`.el>)\n"
                   "https://example.test/a `draft`.el")
                  ("[first\nsecond](https://example.test)\n" nil)
                  ("[x](https://example.test/a(b(c)))\n"
                   "https://example.test/a(b(c))")))
    (pcase-let* ((`(,source ,target) case)
                 (expected (dsh-emacs-markdown-convert source)))
      (should (equal expected (if target "x\n" source)))
      (should (eq (keymapp (get-text-property 0 'keymap expected)) (and target t)))
      (dolist (size '(1 3 7))
        (with-temp-buffer
          (let ((state (list :scan nil :pending nil :kind nil :watermark nil))
                (pos 0))
            (while (< pos (length source))
              (goto-char (point-max))
              (insert (substring source pos (min (+ pos size) (length source))))
              (setq pos (+ pos size))
              (dsh-emacs-markdown-replace-markup :stream-state state))
            (dsh-emacs-markdown-replace-markup :stream-state state :final t)
            (should (equal (buffer-string) expected))
            (should (eq (keymapp (get-text-property (point-min) 'keymap)) (and target t)))
            (when target
              (let ((command (lookup-key (get-text-property (point-min) 'keymap)
                                         (kbd "RET")))
                    opened)
                (should (commandp command))
                (cl-letf (((symbol-function 'dsh-emacs-markdown--open-link)
                           (lambda (url) (setq opened url))))
                  (call-interactively command))
                (should (equal opened target))))))))))

(ert-deftest dsh-emacs-test-markdown-resource-bounded-syntax ()
  :tags '(dsh-unit)
  (let ((url (concat "https://example.test/" (make-string 32 ?\()
                     "x" (make-string 32 ?\)))))
    (should (equal (dsh-emacs-markdown-convert (format "[x](%s)" url)) "x"))
    (let ((source (format "[x](%s)" (concat url "(extra)"))))
      (should (equal (dsh-emacs-markdown-convert source) "x"))))
  (dolist (source (list (concat "[x](" (make-string 33 ?\() "x"
                                (make-string 33 ?\)) ")")
                        "[x](<a _literal_ &amp;b>)"
                        "[x](<a `literal` &#38;b>)"))
    (let ((rendered (dsh-emacs-markdown-convert source)))
      (should (equal rendered source))
      (should-not (get-text-property 0 'keymap rendered)))))

(ert-deftest dsh-emacs-test-markdown-resource-space-image-compatibility ()
  :tags '(dsh-unit)
  (let* ((directory (make-temp-file "dsh-space-image-" t))
         (default-directory (file-name-as-directory directory))
         (file (expand-file-name "a _draft_.png" directory)) seen)
    (unwind-protect
        (progn
          (with-temp-file file (insert "image fixture"))
          (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                    ((symbol-function 'image-supported-file-p) (lambda (_) t))
                    ((symbol-function 'create-image)
                     (lambda (path &rest _) (setq seen path) '(image :type png)))
                    ((symbol-function 'image-flush) #'ignore))
            (should (equal (dsh-emacs-markdown-convert "![x](./a _draft_.png)") "x"))
            (should (equal seen file))))
      (delete-directory directory t)))
  (dolist (source '("[x](./a b.el)" "![x](./a (b).png)"
                    "before ![x](./a b.png)"))
    (should (equal (dsh-emacs-markdown-convert source) source))))

(ert-deftest dsh-emacs-test-markdown-resource-destination-backtick-code-boundary ()
  :tags '(dsh-unit)
  (let ((rendered (dsh-emacs-markdown-convert
                   "[x](<https://example.test/a`b>) `[hidden](bad)` [y](https://example.test/y)")))
    (should (equal rendered "x [hidden](bad) y"))
    (should (keymapp (get-text-property 0 'keymap rendered)))
    (should-not (get-text-property 3 'keymap rendered))
    (should (keymapp (get-text-property (1- (length rendered)) 'keymap rendered)))))

(ert-deftest dsh-emacs-test-markdown-resource-emphasis-in-label ()
  :tags '(dsh-unit)
  (dolist (case '(("**label**" dsh-emacs-markdown-bold)
                  ("*label*" dsh-emacs-markdown-italic)
                  ("~~label~~" dsh-emacs-markdown-strikethrough)
                  ("`label`" dsh-emacs-markdown-inline-code)))
    (let* ((rendered (dsh-emacs-markdown-convert
                      (format "[%s](https://example.test/a(b))" (car case))))
           (command (lookup-key (get-text-property 0 'keymap rendered) (kbd "RET")))
           opened)
      (should (equal rendered "label"))
      (should (memq (cadr case) (ensure-list (get-text-property 0 'face rendered))))
      (should (get-text-property 0 'dsh-emacs-markdown-frozen rendered))
      (should-not (text-property-not-all
                   0 (length rendered) 'dsh-emacs-markdown-resource nil rendered))
      (should (commandp command))
      (cl-letf (((symbol-function 'dsh-emacs-markdown--open-link)
                 (lambda (url) (setq opened url))))
        (call-interactively command))
      (should (equal opened "https://example.test/a(b)")))))

(ert-deftest dsh-emacs-test-markdown-resource-link-face-leads-label-styling ()
  :tags '(dsh-unit)
  (dolist (case '(("**label**" dsh-emacs-markdown-bold)
                  ("*label*" dsh-emacs-markdown-italic)
                  ("~~label~~" dsh-emacs-markdown-strikethrough)
                  ("`label`" dsh-emacs-markdown-inline-code)))
    (let* ((rendered (dsh-emacs-markdown-convert
                      (format "[%s](https://example.test/x)" (car case))))
           (face (ensure-list (get-text-property 0 'face rendered))))
      (should (equal rendered "label"))
      (should (eq (car face) 'dsh-emacs-markdown-link))
      (should (memq (cadr case) face)))))

(ert-deftest dsh-emacs-test-markdown-resource-emphasis-around-link ()
  :tags '(dsh-unit)
  (dolist (case '(("**" dsh-emacs-markdown-bold)
                  ("*" dsh-emacs-markdown-italic)
                  ("~~" dsh-emacs-markdown-strikethrough)))
    (let* ((rendered (dsh-emacs-markdown-convert
                      (format "%ssee [file](<https://example.test/a *literal*>) now%s"
                              (car case) (car case))))
           (command (lookup-key (get-text-property 4 'keymap rendered) (kbd "RET")))
           opened)
      (should (equal rendered "see file now"))
      (dolist (position '(0 4 9))
        (should (memq (cadr case)
                      (ensure-list (get-text-property position 'face rendered)))))
      (should-not (get-text-property 0 'keymap rendered))
      (should-not (get-text-property 9 'keymap rendered))
      (should (get-text-property 4 'dsh-emacs-markdown-frozen rendered))
      (should-not (get-text-property 0 'dsh-emacs-markdown-frozen rendered))
      (should (commandp command))
      (cl-letf (((symbol-function 'dsh-emacs-markdown--open-link)
                 (lambda (url) (setq opened url))))
        (call-interactively command))
      (should (equal opened "https://example.test/a *literal*")))))

(ert-deftest dsh-emacs-test-markdown-resource-emphasis-stream-around-link ()
  :tags '(dsh-unit)
  (let ((source "**see [file](https://example.test) now**\n"))
    (dolist (size '(1 3 7))
      (with-temp-buffer
        (let ((state (list :scan nil :pending nil :kind nil :watermark nil))
              (pos 0))
          (while (< pos (length source))
            (goto-char (point-max))
            (insert (substring source pos (min (+ pos size) (length source))))
            (setq pos (+ pos size))
            (dsh-emacs-markdown-replace-markup :stream-state state))
          (dsh-emacs-markdown-replace-markup :stream-state state :final t)
          (should (equal (buffer-string) "see file now\n"))
          (dolist (position '(1 5 10))
            (should (memq 'dsh-emacs-markdown-bold
                          (ensure-list (get-text-property position 'face)))))
          (should (keymapp (get-text-property 5 'keymap)))
          (should-not (get-text-property 10 'keymap)))))))

(provide 'dsh-test-markdown)
;;; dsh-test-markdown.el ends here
