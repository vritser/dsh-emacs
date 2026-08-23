;;; dsh-test.el --- dsh-emacs 单元测试（新模块化结构） -*- lexical-binding: t; -*-
(setq debug-on-error t)
;; Batch/cron runs have no working gcc: `cl-letf' on a built-in subr like
;; `completing-read' would otherwise demand a native trampoline compile and
;; die with "native-ice (error invoking gcc driver)".  Disabling the
;; trampoline falls back to the (slower) non-compiled advice path.
(when (boundp 'comp-enable-subr-trampolines)
  (setq comp-enable-subr-trampolines nil))
(add-to-list 'load-path (expand-file-name ".." (file-name-directory load-file-name)))

;; 加载所有模块
(require 'dsh-emacs)

(defvar dsh-test-results '())

(defun dsh-test-pass (name)
  (push (cons name t) dsh-test-results)
  (princ (format "PASS: %s\n" name)))

(defun dsh-test-fail (name detail)
  (push (cons name nil) dsh-test-results)
  (princ (format "FAIL: %s -- %s\n" name detail)))

;; --- 测试 1: 模块加载 ---
(when (featurep 'dsh-emacs)
  (dsh-test-pass "dsh-emacs loaded"))

(when (featurep 'dsh-emacs-faces)
  (dsh-test-pass "dsh-emacs-faces loaded"))

(when (featurep 'dsh-emacs-tokens)
  (dsh-test-pass "dsh-emacs-tokens loaded"))

(when (featurep 'dsh-emacs-render)
  (dsh-test-pass "dsh-emacs-render loaded"))

(when (featurep 'dsh-emacs-footer)
  (dsh-test-pass "dsh-emacs-footer loaded"))

(when (featurep 'dsh-emacs-session)
  (dsh-test-pass "dsh-emacs-session loaded"))

(when (featurep 'dsh-emacs-markdown)
  (dsh-test-pass "dsh-emacs-markdown loaded"))

;; --- 测试 2: Token 格式化 ---
(when (string= "1.2k" (dsh-emacs-format-tokens 1234))
  (dsh-test-pass "format-tokens 1234"))

(when (string= "1.5M" (dsh-emacs-format-tokens 1500000))
  (dsh-test-pass "format-tokens 1500000"))

(when (string= "100" (dsh-emacs-format-tokens 100))
  (dsh-test-pass "format-tokens 100"))

;; --- 测试 3: Token 结构 ---
(let ((usage (dsh-emacs-make-usage)))
  (when (and (= 0 (dsh-emacs-usage-input usage))
             (= 0 (dsh-emacs-usage-output usage)))
    (dsh-test-pass "usage-create")))

(let ((usage (dsh-emacs-make-usage 100 50)))
  (when (and (= 100 (dsh-emacs-usage-input usage))
             (= 50 (dsh-emacs-usage-output usage)))
    (dsh-test-pass "usage-create with args")))

;; --- 测试 4: Token 累加 ---
(let ((u1 (dsh-emacs-make-usage 100 50))
      (u2 (dsh-emacs-make-usage 200 100)))
  (dsh-emacs-usage-add u1 u2)
  (when (and (= 300 (dsh-emacs-usage-input u1))
             (= 150 (dsh-emacs-usage-output u1)))
    (dsh-test-pass "usage-add")))

;; --- 测试 5: 上下文百分比 ---
(let ((pct (dsh-emacs-format-ctx-percent 1000 0 0 2000)))
  (when (and (= 50.0 pct)
             (string= "50.0%" (dsh-emacs-format-percent pct)))
    (dsh-test-pass "format-ctx-percent")))

(let ((pct (dsh-emacs-format-ctx-percent 3000 0 0 2000)))
  (when (= 100.0 pct)
    (dsh-test-pass "format-ctx-percent capped at 100")))

;; --- 测试 5b: usage 解析（真实 dsh 事件形状：data.usage + camelCase）---
(let* ((event '(("type" . "assistant/message")
                ("seq" . 103)
                ("data" . (("usage" . (("inputTokens" . 626)
                                       ("outputTokens" . 155)
                                       ("cacheReadTokens" . 7168)))))))
       (usage (dsh-emacs-usage-from-event event)))
  (when (and (= 626 (dsh-emacs-usage-input usage))
             (= 155 (dsh-emacs-usage-output usage))
             (= 7168 (dsh-emacs-usage-cache-read usage)))
    (dsh-test-pass "usage-from-event parses real data.usage")))

(let* ((usage (dsh-emacs-usage-from-event
               '(("type" . "assistant/message")
                 ("data" . (("message" . (("content" . "no usage here"))))))))
       (all-zero (and (= 0 (dsh-emacs-usage-input usage))
                      (= 0 (dsh-emacs-usage-output usage)))))
  (when all-zero
    (dsh-test-pass "usage-from-event no-usage yields zero")))

;; --- 测试 5c: footer 事件累计与渲染 ---
(let (txt)
  (setq dsh-emacs--footer-usage nil)
  (dsh-emacs-footer-note-event
   '(("type" . "assistant/message")
     ("data" . (("usage" . (("inputTokens" . 100) ("outputTokens" . 20)))))))
  (dsh-emacs-footer-note-event
   '(("type" . "assistant/message")
     ("data" . (("usage" . (("inputTokens" . 200)
                            ("outputTokens" . 40)
                            ("cacheReadTokens" . 3500)))))))
  ;; Non-message events must not touch the accumulator.
  (dsh-emacs-footer-note-event
   '(("type" . "user/message") ("data" . (("content" . "hi")))))
  (when (and dsh-emacs--footer-usage
             (= 300 (dsh-emacs-usage-input dsh-emacs--footer-usage))
             (= 60 (dsh-emacs-usage-output dsh-emacs--footer-usage))
             (= 3500 (dsh-emacs-usage-cache-read dsh-emacs--footer-usage)))
    (dsh-test-pass "footer-note-event accumulates assistant/message usage"))
  (setq txt (dsh-emacs-footer-format))
  (when (and (string-match "↑300" txt) (string-match "↓60" txt)
             (string-match "CH92%" txt))
    (dsh-test-pass "footer-format renders accumulated tokens")))

;; --- 测试 5d: request/context 喂 model 与 context window ---
(let ((rc '(("type" . "request/context")
            ("seq" . 42)
            ("data" . (("provider" . "qwen-token-plan")
                       ("model" . "deepseek-v4-flash-0731")
                       ("contextWindow" . 1000000)))))
      (before (or (bound-and-true-p dsh-emacs--footer-model) "none")))
  (dsh-emacs-footer-note-request rc)
  (when (and (equal "deepseek-v4-flash-0731" dsh-emacs--footer-model)
             (= 1000000 dsh-emacs--footer-context-window))
    (dsh-test-pass "note-request feeds model and context window")))

;; --- 测试 5e: model-effort 组合与 modeinline 括号 ---
(let ((txt (progn
             (setq dsh-emacs--footer-model "m1"
                   dsh-emacs--footer-effort "standard")
             (dsh-emacs-footer-format))))
  (when (string-match "m1-standard" txt)
    (dsh-test-pass "model-effort combined in model segment")))
(let* ((txt (progn
              (dsh-emacs-footer-set-effort nil)
              (dsh-emacs-footer--modeinline))))
  (when (and (string-prefix-p "(" txt) (string-match-p ") *$" txt)
             (string-match "CH92%%" txt))
    (dsh-test-pass "modeinline wraps stats in parens and escapes percent")))

;; --- 测试 6: 面孔定义 ---
(when (facep 'dsh-emacs-user-face)
  (dsh-test-pass "user-face exists"))

(when (facep 'dsh-emacs-assistant-face)
  (dsh-test-pass "assistant-face exists"))

(when (facep 'dsh-emacs-tool-pending-face)
  (dsh-test-pass "tool-pending-face exists"))

(when (facep 'dsh-emacs-tool-success-face)
  (dsh-test-pass "tool-success-face exists"))

(when (facep 'dsh-emacs-tool-error-face)
  (dsh-test-pass "tool-error-face exists"))

(when (facep 'dsh-emacs-footer-face)
  (dsh-test-pass "footer-face exists"))

(when (facep 'dsh-emacs-session-title-face)
  (dsh-test-pass "session-title-face exists"))

;; --- 测试 7: UI 渲染 ---
(with-temp-buffer
  (let ((frag (dsh-emacs-ui-make-fragment
               :namespace-id "test"
               :block-id "1"
               :label-left "👤 你"
               :label-right "12:00"
               :body "你好"
               :style 'rounded)))
    (when (and frag
               (string= "test" (map-elt frag :namespace-id))
               (string= "1" (map-elt frag :block-id)))
      (dsh-test-pass "ui-make-fragment"))))

;; --- 测试 8: 事件渲染器函数存在 ---
(when (fboundp 'dsh-emacs-render-event)
  (dsh-test-pass "render-event function exists"))

(when (fboundp 'dsh-emacs-render-history-events)
  (dsh-test-pass "render-history-events function exists"))

(when (fboundp 'dsh-emacs-render-user-message)
  (dsh-test-pass "render-user-message function exists"))

(when (fboundp 'dsh-emacs-render-assistant-message)
  (dsh-test-pass "render-assistant-message function exists"))

(when (fboundp 'dsh-emacs-render-tool-call)
  (dsh-test-pass "render-tool-call function exists"))

(when (fboundp 'dsh-emacs-render-tool-result)
  (dsh-test-pass "render-tool-result function exists"))

;; --- 测试 9: Footer 函数存在 ---
(when (fboundp 'dsh-emacs-footer-format)
  (dsh-test-pass "footer-format function exists"))

(when (fboundp 'dsh-emacs-footer-setup)
  (dsh-test-pass "footer-setup function exists"))

(when (fboundp 'dsh-emacs-footer-update)
  (dsh-test-pass "footer-update function exists"))

(when (fboundp 'dsh-emacs-footer-set-usage)
  (dsh-test-pass "footer-set-usage function exists"))

;; --- 测试 10: 会话列表函数存在 ---
(when (fboundp 'dsh-emacs-session--render)
  (dsh-test-pass "session--render function exists"))

(when (fboundp 'dsh-emacs-session--shorten-cwd)
  (dsh-test-pass "session--shorten-cwd function exists"))

(when (fboundp 'dsh-emacs-open-session-at-point)
  (dsh-test-pass "open-session-at-point function exists"))

;; --- 测试 11: Markdown 函数存在 ---
(when (fboundp 'dsh-emacs-markdown-render)
  (dsh-test-pass "markdown-render function exists"))

(let ((rendered (dsh-emacs-markdown-render "# title\n**bold** `code`")))
  (when (and (string= rendered "title\nbold code\n")
             (eq (get-text-property 0 'face rendered)
                 'dsh-emacs-markdown-header-1)
             (eq (get-text-property 6 'face rendered)
                 'dsh-emacs-markdown-bold)
             (eq (get-text-property 11 'face rendered)
                 'dsh-emacs-markdown-inline-code))
    (dsh-test-pass "markdown-render-applies-faces")))

(let ((rendered (dsh-emacs-markdown-render
                 "__bold__ _italic_ ~~gone~~ **_both_**")))
  (let ((both-face (get-text-property 17 'face rendered)))
    (when (and (string= rendered "bold italic gone both\n")
               (eq (get-text-property 0 'face rendered)
                   'dsh-emacs-markdown-bold)
               (eq (get-text-property 5 'face rendered)
                   'dsh-emacs-markdown-italic)
               (eq (get-text-property 12 'face rendered)
                   'dsh-emacs-markdown-strikethrough)
               (listp both-face)
               (memq 'dsh-emacs-markdown-bold both-face)
               (memq 'dsh-emacs-markdown-italic both-face))
      (dsh-test-pass "markdown-nested-and-alternate-markup"))))

(let ((rendered (dsh-emacs-markdown-render
                 "| Name | Value |\n| --- | ---: |\n| **foo** | `bar` |")))
  (when (and (string-match-p "│ Name │ Value │" rendered)
             (string-match-p "├" rendered)
             (string-match-p "foo" rendered)
             (not (string-match-p "\\*\\*" rendered))
             (not (string-match-p "`" rendered)))
    (dsh-test-pass "markdown-table-render")))

;; --- 测试 12: 主入口函数 ---
(when (fboundp 'dsh-emacs)
  (dsh-test-pass "dsh-emacs main function exists"))

(when (fboundp 'dsh-emacs-new-session)
  (dsh-test-pass "dsh-emacs-new-session function exists"))

(when (fboundp 'dsh-emacs-open-session)
  (dsh-test-pass "dsh-emacs-open-session function exists"))

(when (fboundp 'dsh-emacs-health)
  (dsh-test-pass "dsh-emacs-health function exists"))

;; --- 测试 13: RPC 函数 ---
(when (fboundp 'dsh-emacs--rpc-request)
  (dsh-test-pass "rpc-request function exists"))

(when (fboundp 'dsh-emacs--rpc-async)
  (dsh-test-pass "rpc-async function exists"))

;; --- 测试 14: RPC JSON 布尔值和空 payload ---
(let ((request (dsh-emacs--wrap-request "session.list" nil)))
  (when (string-match-p "\"payload\":{}" request)
    (dsh-test-pass "rpc-empty-payload-is-object")))

(let* ((response (json-read-from-string
                  "{\"result\":{\"ok\":false,\"error\":{\"code\":\"bad-request\"}}}"))
       (unwrapped (dsh-emacs--unwrap-response response)))
  (when (and (not (car unwrapped))
             (equal (cdr (assq 'code (cdr unwrapped))) "bad-request"))
    (dsh-test-pass "rpc-false-result-is-error")))

;; --- 测试 15: JSON 数组与工作目录 ---
(when (and (equal '(a b) (dsh-emacs--sequence-list [a b]))
           (equal "assistant/message"
                  (dsh-emacs-render--aget "type"
                                           '((type . "assistant/message")))))
  (dsh-test-pass "json-array-and-symbol-keys-supported"))

(let ((dsh-emacs-default-cwd "~/"))
  (when (file-name-absolute-p (dsh-emacs--absolute-cwd nil))
    (dsh-test-pass "session-cwd-is-absolute")))

(when (stringp (dsh-emacs-session--compact-time (* (float-time) 1000)))
  (dsh-test-pass "session-time-formats-milliseconds"))

(when (and (stringp (dsh-emacs--client-time-zone))
           (not (string-empty-p (dsh-emacs--client-time-zone)))
           (dsh-emacs--valid-iana-time-zone-p
            (dsh-emacs--client-time-zone)))
  (dsh-test-pass "client-time-zone-is-iana"))

(let ((process-environment (copy-sequence process-environment)))
  (setenv "TZ" "CST")
  (when (dsh-emacs--valid-iana-time-zone-p
         (dsh-emacs--client-time-zone))
    (dsh-test-pass "ambiguous-time-zone-is-replaced")))

;; --- 测试 16: 缓冲模式 ---
(with-temp-buffer
  (dsh-emacs-mode)
  (when (eq major-mode 'dsh-emacs-mode)
    (dsh-test-pass "dsh-emacs-mode activates"))
  (when (local-variable-p 'dsh-emacs--input-marker)
    (dsh-test-pass "input-marker variable exists"))
  (when dsh-emacs--input-marker
    (dsh-test-pass "input-marker marker created")))

;; --- 测试 17: 输入区域可写 ---
(with-temp-buffer
  (dsh-emacs-mode)
  ;; New sessions install the footer after the input area.  Inserting at the
  ;; marker must still work even though the prompt itself is read-only.
  (dsh-emacs-footer-setup)
  (goto-char dsh-emacs--input-marker)
  (condition-case err
      (progn
        (insert "测试输入")
        (if (and (string= (buffer-substring-no-properties
                           dsh-emacs--input-marker (point-max))
                          "测试输入\n")
                 (string= (dsh-emacs--get-input) "测试输入"))
            (dsh-test-pass "input-area-writable")
          (dsh-test-fail "input-area-writable"
                         "文本未插入到输入区域")))
    (error
     (dsh-test-fail "input-area-writable" (error-message-string err)))))

;; --- 测试 18: UTF-8 response decoding ---
(with-temp-buffer
  (set-buffer-multibyte nil)
  (insert (encode-coding-string "你好 😊" 'utf-8))
  (goto-char (point-min))
  (dsh-emacs--decode-response-body)
  (when (string= (buffer-string) "你好 😊")
    (dsh-test-pass "rpc-response-decodes-utf8")))

;; --- 测试 19: assistant replies remain in history order ---
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-footer-setup)
  (let ((first (json-read-from-string
                "{\"event\":{\"type\":\"assistant/message\",\"seq\":1,\"data\":{\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"reply-1\"}]}}}}"))
        (second (json-read-from-string
                 "{\"event\":{\"type\":\"assistant/message\",\"seq\":2,\"data\":{\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"reply-2\"}]}}}}")))
    (dsh-emacs-render-history-events (list first second))
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      (when (and (< (string-match "reply-1" text)
                    (string-match "reply-2" text))
                 (string-match "reply-1\n" text)
                 (string-match "reply-2\n" text))
        (dsh-test-pass "assistant-replies-keep-order")))))

;; --- 测试 20: chat prefix and rendered Markdown ---
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-footer-setup)
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
      (when (and (string-match "❯ hello" text)
                 (member 'dsh-emacs-markdown-header-1
                         (if (listp title-face) title-face (list title-face)))
                 (member 'dsh-emacs-markdown-bold
                         (if (listp bold-face) bold-face (list bold-face))))
        (dsh-test-pass "chat-prefix-and-markdown-render")))))

;; --- 测试 21: assistant 流式增量渲染 ---
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-footer-setup)
  (let ((chunk-1 (json-read-from-string
                  "{\"type\":\"assistant/chunk\",\"seq\":1,\"data\":{\"turn\":1,\"step\":1,\"chunk\":{\"type\":\"text-delta\",\"index\":1,\"text\":\"hello **bold\"}}}"))
        (chunk-2 (json-read-from-string
                  "{\"type\":\"assistant/chunk\",\"seq\":2,\"data\":{\"turn\":1,\"step\":1,\"chunk\":{\"type\":\"text-delta\",\"index\":1,\"text\":\" text**\"}}}"))
        (final (json-read-from-string
                "{\"type\":\"assistant/message\",\"seq\":3,\"data\":{\"turn\":1,\"step\":1,\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"hello **bold text**\"}]}}}")))
    (dsh-emacs-render-event chunk-1)
    (let ((partial (buffer-substring-no-properties (point-min) (point-max))))
      (when (string-match-p "hello \\*\\*bold" partial)
        (dsh-test-pass "assistant-stream-keeps-incomplete-markup")))
    (dsh-emacs-render-event chunk-2)
    (let* ((text (buffer-string))
           (bold-pos (string-match "bold" text))
           (face (and bold-pos (get-text-property bold-pos 'face text))))
      (when (and (not (string-match-p "\\*\\*" (substring-no-properties text)))
                 (member 'dsh-emacs-markdown-bold
                         (if (listp face) face (list face))))
        (dsh-test-pass "assistant-stream-renders-completed-markup")))
    (dsh-emacs-render-event final)
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      (when (and (null dsh-emacs--streaming-assistant)
                 (= (cl-count ?b text)
                    1))
        (dsh-test-pass "assistant-stream-final-event-does-not-duplicate")))))

;; --- 测试 21b: thinking / reasoning 流式渲染 ---
(when dsh-emacs-show-reasoning
  (dsh-test-pass "thinking-show-reasoning-defaults-on"))

(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-footer-setup)
  (dsh-emacs-render-event
   (json-read-from-string
    "{\"type\":\"assistant/chunk\",\"seq\":1,\"data\":{\"turn\":1,\"step\":1,\"chunk\":{\"type\":\"block-start\",\"index\":0,\"blockType\":\"reasoning\"}}}"))
  (dsh-emacs-render-event
   (json-read-from-string
    "{\"type\":\"assistant/chunk\",\"seq\":2,\"data\":{\"turn\":1,\"step\":1,\"chunk\":{\"type\":\"reasoning-delta\",\"index\":0,\"text\":\"think step one\"}}}"))
  (dsh-emacs-render-event
   (json-read-from-string
    "{\"type\":\"assistant/chunk\",\"seq\":3,\"data\":{\"turn\":1,\"step\":1,\"chunk\":{\"type\":\"reasoning-delta\",\"index\":0,\"text\":\" then two\"}}}"))
  (let ((text (buffer-substring-no-properties (point-min) (point-max))))
    (when (and (string-match-p "✶ Think" text)
               (string-match-p "think step one then two" text))
      (dsh-test-pass "thinking-stream-renders-live-block"))))

(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-footer-setup)
  (dsh-emacs-render-event
   (json-read-from-string
    "{\"type\":\"assistant/chunk\",\"seq\":1,\"data\":{\"turn\":1,\"step\":1,\"chunk\":{\"type\":\"reasoning-delta\",\"index\":0,\"text\":\"step\"}}}"))
  (dsh-emacs-render-event
   (json-read-from-string
    "{\"type\":\"assistant/message\",\"seq\":2,\"data\":{\"turn\":1,\"step\":1,\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"reasoning\",\"text\":\"final thinking\"},{\"type\":\"text\",\"text\":\"reply body\"}]}}}"))
  (let ((text (buffer-substring-no-properties (point-min) (point-max))))
    (when (and (string-match-p "✶ Think" text)
               (string-match-p "reply body" text)
               (null dsh-emacs--streaming-thinking)
               (= (cl-count ?✶ text) 1))
      (dsh-test-pass "thinking-final-replaces-stream-single-block"))))

(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-footer-setup)
  (dsh-emacs-render-event
   (json-read-from-string
    "{\"type\":\"assistant/message\",\"seq\":1,\"data\":{\"turn\":1,\"step\":1,\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"reasoning\",\"text\":\"history think\"},{\"type\":\"text\",\"text\":\"history body\"}]}}}"))
  (let ((text (buffer-substring-no-properties (point-min) (point-max))))
    (when (and (string-match-p "✶ Think" text)
               (string-match-p "history body" text)
               (null dsh-emacs--streaming-thinking))
      (dsh-test-pass "thinking-history-renders-final-block"))))

(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-footer-setup)
  (let ((dsh-emacs-show-reasoning nil))
    (dsh-emacs-render-event
     (json-read-from-string
      "{\"type\":\"assistant/chunk\",\"seq\":1,\"data\":{\"turn\":1,\"step\":1,\"chunk\":{\"type\":\"reasoning-delta\",\"index\":0,\"text\":\"should be hidden\"}}}"))
    (dsh-emacs-render-event
     (json-read-from-string
      "{\"type\":\"assistant/message\",\"seq\":2,\"data\":{\"turn\":1,\"step\":1,\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"reasoning\",\"text\":\"hidden\"},{\"type\":\"text\",\"text\":\"shown\"}]}}}"))
  (let ((text (buffer-substring-no-properties (point-min) (point-max))))
    (when (and (null dsh-emacs--streaming-thinking)
               (not (string-match-p "✶ Think" text))
               (string-match-p "shown" text))
      (dsh-test-pass "thinking-disabled-hides-block")))))

(when (>= dsh-emacs-poll-interval 0.5)
  (dsh-test-pass "stream-polling-fallback-is-throttled"))

(with-temp-buffer
  (dsh-emacs-mode)
  (setq dsh-emacs--poll-inflight t)
  (condition-case nil
      (progn
        (dsh-emacs--poll-update)
        (dsh-test-pass "stream-polling-avoids-overlap"))
    (error nil)))

;; --- 测试 22: 丢失输入 marker 后消息仍插入到输入框上方 ---
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-footer-setup)
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
    (when (and reply-pos
               (< reply-pos anchor)
               (save-excursion
                 (goto-char (point-min))
                 (re-search-forward "❯ " nil t)))
      (dsh-test-pass "assistant-below-input-fallback"))))

;; --- 测试 23: 丢失 marker 时流式 chunk 也插入到输入框上方 ---
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-footer-setup)
  (setq-local dsh-emacs--input-marker nil)
  (dsh-emacs-render-event
   (json-read-from-string
    "{\"type\":\"assistant/chunk\",\"seq\":1,\"data\":{\"turn\":1,\"step\":1,\"chunk\":{\"type\":\"text-delta\",\"index\":1,\"text\":\"stream-above-input\"}}}"))
  (let* ((anchor (or (dsh-emacs-render--input-anchor-pos) (point-max)))
         (text (buffer-substring-no-properties (point-min) (point-max)))
         (stream-pos (string-match "stream-above-input" text)))
    (when (and stream-pos
               (< stream-pos anchor))
      (dsh-test-pass "assistant-stream-below-input-fallback"))))

;; --- 测试 25: 位于底部时新消息自动滚动跟随 ---
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-footer-setup)
  (pop-to-buffer (current-buffer))
  (let ((win (get-buffer-window (current-buffer) t)))
    ;; Fill enough content to overflow a small window.
    (dotimes (i 40)
      (dsh-emacs-render-event
       (json-read-from-string
        (format "{\"type\":\"assistant/message\",\"seq\":%d,\"data\":{\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"filler %d filler filler filler filler filler\"}]}}}" (1+ i) i))))
    ;; Pin the view to the bottom.
    (let ((anchor (or (dsh-emacs-render--input-anchor-pos) (point-max))))
      (save-excursion
        (goto-char anchor)
        (forward-line (- (1- (max 1 (window-text-height win)))))
        (set-window-start win (max (point-min) (point))))
      (let ((start-before (window-start win)))
        (dsh-emacs-render-event
         (json-read-from-string
          "{\"type\":\"assistant/message\",\"seq\":1000,\"data\":{\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"fresh follow message\"}]}}}"))
        (dsh-emacs-render--follow-stream)
        (when (> (window-start win) start-before)
          (dsh-test-pass "follow-scrolls-at-bottom"))))))

;; --- 测试 26: 用户上翻时不被拉回底部 ---
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-footer-setup)
  (pop-to-buffer (current-buffer))
  (let ((win (get-buffer-window (current-buffer) t)))
    (dotimes (i 40)
      (dsh-emacs-render-event
       (json-read-from-string
        (format "{\"type\":\"assistant/message\",\"seq\":%d,\"data\":{\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"filler %d filler filler filler filler filler\"}]}}}" (1+ i) i))))
    (set-window-start win 1)          ; user scrolled to the top
    (dsh-emacs-render-event
     (json-read-from-string
      "{\"type\":\"assistant/message\",\"seq\":1000,\"data\":{\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"scrolled-away message\"}]}}}"))
    (dsh-emacs-render--follow-stream)
    (when (= (window-start win) 1)
      (dsh-test-pass "follow-does-not-yank-scrolled-window"))))

;; --- 测试 27: 同 buffer 输入模式（agent-shell 风格） ---
(let ((dsh-emacs-pin-input-to-bottom nil))
  (with-temp-buffer
    (dsh-emacs-mode)
    (dsh-emacs-footer-setup)
    (dsh-emacs-render-event
     (json-read-from-string
      "{\"type\":\"assistant/message\",\"seq\":1,\"data\":{\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"inline reply\"}]}}}"))
    (let* ((text (buffer-substring-no-properties (point-min) (point-max)))
           (reply-pos (string-match "inline reply" text))
           (prompt-pos (string-match "❯ " text))
           (marker-pos (marker-position dsh-emacs--input-marker)))
      (when (and reply-pos prompt-pos
                 (< reply-pos prompt-pos)         ; reply above the prompt
                 (null dsh-emacs--pinned-input-buffer)  ; no separate input window
                 (goto-char marker-pos)
                 (looking-back "❯ " (line-beginning-position)))
        (dsh-test-pass "inline-mode-single-buffer")))))

;; --- 测试 28: WebSocket 握手后的帧仍被消费（实时修复） ---
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-footer-setup)
  (setq dsh-emacs--current-session "s1")   ; match the test frame's sessionId
  (let ((fake-proc (start-process "dsh-test-proc" (current-buffer) "/usr/bin/true"))
        (dispatch-count 0))
    (accept-process-output fake-proc 1)
    (process-put fake-proc 'dsh-emacs-chat-buffer (current-buffer))
    (process-put fake-proc 'dsh-emacs-event-input "")
    (process-put fake-proc 'dsh-emacs-event-ready t)
    (advice-add 'dsh-emacs-events--dispatch-json :before
                (lambda (&rest _) (setq dispatch-count (1+ dispatch-count))))
    (unwind-protect
        (progn
          ;; A valid masked text frame carrying one JSON envelope, arriving
          ;; as a *separate* chunk after the handshake.  Build it with the
          ;; real frame encoder (handles extended lengths like the server's
          ;; real >125-byte frames).
          (let* ((json (format "{\"type\":\"server-request\",\"rpcId\":\"r1\",\"method\":\"session/event\",\"payload\":{\"type\":\"session/event\",\"sessionId\":\"s1\",\"event\":{\"type\":\"assistant/message\",\"seq\":1,\"data\":{\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"hello ws\"}]}}}}}"))
                 (frame (dsh-emacs-events--frame 1
                                                  (encode-coding-string json 'utf-8 t))))
            ;; Simulate the post-handshake filter path: store the raw bytes
            ;; then consume them (frames must be parsed on every chunk).
            (process-put fake-proc 'dsh-emacs-event-input frame)
            (dsh-emacs-events--consume-frames fake-proc))
          (when (and (= dispatch-count 1)          ; exactly one envelope dispatched
                     (string-empty-p (process-get fake-proc 'dsh-emacs-event-input))
                     (string-match-p "hello ws"
                                     (buffer-substring-no-properties (point-min) (point-max))))
            (dsh-test-pass "websocket-frames-consumed-after-handshake")))
      (delete-process fake-proc)
      (advice-remove 'dsh-emacs-events--dispatch-json
                     (lambda (&rest _) (setq dispatch-count (1+ dispatch-count)))))))

;; --- 测试 24: pinned 输入同步后 anchor 仍独占一行 ---
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-footer-setup)
  ;; Simulate what dsh-emacs--sync-pinned-input guarantees: the anchor line
  ;; always ends with a newline so point-max never sits inside the input.
  (let ((footer-start (overlay-start dsh-emacs--footer-overlay)))
    (when (and (eq (char-before footer-start) ?\n)
               ;; the anchor prompt is on its own line, before the footer
               (save-excursion
                 (goto-char dsh-emacs--input-marker)
                 (eq (char-after (line-beginning-position)) ?❯)))
      (dsh-test-pass "input-anchor-keeps-own-line"))))

;; --- 测试 29: dsh web 风格工具行 —— 变体 icon + IN/OUT ioCard + 状态点 ---
(defun dsh-emacs-test--tool-block-text (qualified-id)
  "Return the full text of the UI block with QUALIFIED-ID, or nil."
  (when-let* ((b (dsh-emacs-ui-find-block qualified-id)))
    (buffer-substring-no-properties (car b) (cdr b))))

(defun dsh-emacs-test--tool-call-event (seq call-id name args)
  "Build a `tool/call' event alist."
  (list (cons "type" "tool/call")
        (cons "seq" seq)
        (cons "data"
              (list (cons "callId" call-id)
                    (cons "name" name)
                    (cons "arguments" args)))))

(defun dsh-emacs-test--tool-result-event (seq call-id is-error exit-code text)
  "Build a `tool/result' event alist."
  (list (cons "type" "tool/result")
        (cons "seq" seq)
        (cons "data"
              (list (cons "message"
                          (list (cons "callId" call-id)
                                (cons "content"
                                      (vector (list (cons "type" "tool-result")
                                                    (cons "isError" (if is-error t :json-false))
                                                    (cons "exitCode" exit-code)
                                                    (cons "content"
                                                          (vector (list (cons "type" "text")
                                                                        (cons "text" text)))))))))))))

(defun dsh-emacs-test--tool-result-event-source (seq call-id text)
  "Build a real dsh Web `tool/result' with MESSAGE.SOURCE.CALL-ID."
  (list (cons "type" "tool/result")
        (cons "seq" seq)
        (cons "data"
              (list (cons "message"
                          (list (cons "source" (list (cons "callId" call-id)))
                                (cons "content"
                                      (vector (list (cons "type" "tool-result")
                                                    (cons "isError" :json-false)
                                                    (cons "exitCode" 0)
                                                    (cons "content"
                                                          (vector (list (cons "type" "text")
                                                                        (cons "text" text)))))))))))))

(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-footer-setup)
  (setq-local dsh-emacs-tool-expand-by-default t)
  ;; 1) 工具调用（running）：保留 bash 变体 icon + 齿轮 loading
  (dsh-emacs-render-tool-call
   (dsh-emacs-test--tool-call-event 1 "c1" "bash" "{\"description\":\"list files\",\"command\":\"ls -la\"}"))
  (let* ((ns (dsh-emacs-render--make-namespace))
         (block (dsh-emacs-test--tool-block-text (format "%s-tool-c1" ns))))
    (when (and block
               (string-match-p (regexp-quote "💻 ") block)
               ;; Gear icon at the start of the row
               (string-match-p (regexp-quote "⚙ ") block))
      (dsh-test-pass "tool-running-keeps-variant-icon")))
  ;; 2) 成功结果：body 含 IN / OUT 两段，成功态保留 icon 并显示输出
  (dsh-emacs-render-tool-result
   (dsh-emacs-test--tool-result-event 2 "c1" nil 0 "total 3\ndrwxr-xr-x"))
  (let* ((ns (dsh-emacs-render--make-namespace))
         (block (dsh-emacs-test--tool-block-text (format "%s-tool-c1" ns))))
    (when (and block
               (string-match-p "IN" block)
               (string-match-p "OUT" block)
               (string-match-p (regexp-quote "💻 ") block)
               (string-match-p "drwxr-xr-x" block))
      (dsh-test-pass "tool-success-IN-OUT-body")))
  ;; 3) 错误结果：leading 变成红色状态点 ●
  (dsh-emacs-render-tool-call
   (dsh-emacs-test--tool-call-event 3 "c2" "edit" "{\"path\":\"/tmp/x\"}"))
  (dsh-emacs-render-tool-result
   (dsh-emacs-test--tool-result-event 4 "c2" nil 1 "segmentation fault"))
  (let* ((ns (dsh-emacs-render--make-namespace))
         (block (dsh-emacs-test--tool-block-text (format "%s-tool-c2" ns))))
    (when (and block
               (string-match-p (regexp-quote "● ") block)
               (string-match-p "segmentation fault" block))
      (dsh-test-pass "tool-error-state-dot-leading"))))

;; --- 测试 30: 空白工具结果隐藏 OUT 区段 ---
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-footer-setup)
  (setq-local dsh-emacs-tool-expand-by-default t)
  (dsh-emacs-render-tool-call
   (dsh-emacs-test--tool-call-event 1 "c3" "read" "{\"path\":\"/a/b.txt\"}"))
  (dsh-emacs-render-tool-result
   (dsh-emacs-test--tool-result-event 2 "c3" nil 0 ""))
  (let* ((ns (dsh-emacs-render--make-namespace))
         (block (dsh-emacs-test--tool-block-text (format "%s-tool-c3" ns))))
    (when (and block
               (string-match-p "IN" block)
               (not (string-match-p "OUT" block)))
      (dsh-test-pass "tool-no-output-hides-OUT-section"))))

;; --- 测试 31: 折叠工具行紧凑（无省略号/空白）+ 展开恢复 IN/OUT ---
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-footer-setup)
  ;; 保持默认折叠（未绑定 expand-by-default）
  (dsh-emacs-render-tool-call
   (dsh-emacs-test--tool-call-event 1 "x1" "bash" "{\"description\":\"list\",\"command\":\"ls\"}"))
  (dsh-emacs-render-tool-result
   (dsh-emacs-test--tool-result-event 2 "x1" nil 0 "file-a"))
  (let* ((ns (dsh-emacs-render--make-namespace))
         (block (dsh-emacs-test--tool-block-text (format "%s-tool-x1" ns))))
    (when (and block
               ;; 折叠时仅一行：含表头，不含省略号占位，不含 IN/OUT
               (string-match-p "Bash" block)
               (not (string-match-p "IN" block))
               (not (string-match-p "OUT" block))
               (string-match-p "list" block))
      (dsh-test-pass "tool-collapsed-single-line"))
    ;; 展开应恢复 IN/OUT 正文，再折叠应回到单行
    (dsh-emacs-ui-toggle-fragment)
    (let* ((expanded (dsh-emacs-test--tool-block-text (format "%s-tool-x1" ns))))
      (when (and expanded
                 (string-match-p "IN" expanded)
                 (string-match-p "OUT" expanded)
                 (string-match-p "file-a" expanded))
        (dsh-test-pass "tool-expand-restores-IN-OUT"))
      (dsh-emacs-ui-toggle-fragment)
      (let ((recollapsed (dsh-emacs-test--tool-block-text (format "%s-tool-x1" ns))))
        (when (and recollapsed
                   (not (string-match-p "IN" recollapsed))
                   (string-match-p "Bash" recollapsed))
          (dsh-test-pass "tool-recollapse-single-line"))))))

;; --- 测试 32: 相邻工具行紧凑堆叠（无多余空行） ---
(defun dsh-emacs-test--t32-call (seq id name args)
  (list (cons "type" "tool/call") (cons "seq" seq)
        (cons "data" (list (cons "callId" id) (cons "name" name)
                           (cons "arguments" args)))))
(defun dsh-emacs-test--t32-result (seq id text)
  (list (cons "type" "tool/result") (cons "seq" seq)
        (cons "data" (list (cons "message"
                                 (list (cons "callId" id)
                                       (cons "content"
                                             (vector (list (cons "type" "tool-result")
                                                           (cons "isError" :json-false)
                                                           (cons "exitCode" 0)
                                                           (cons "content"
                                                                 (vector (list (cons "type" "text")
                                                                               (cons "text" text)))))))))))))
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-footer-setup)
  (dsh-emacs-render-tool-call
   (dsh-emacs-test--t32-call 1 "y1" "search" "{\"query\":\"*.md\"}"))
  (dsh-emacs-render-tool-result (dsh-emacs-test--t32-result 2 "y1" "a"))
  (dsh-emacs-render-tool-call
   (dsh-emacs-test--t32-call 3 "y2" "read" "{\"path\":\"/tmp/x\"}"))
  (dsh-emacs-render-tool-result (dsh-emacs-test--t32-result 4 "y2" "b"))
  (when-let* ((line-tool (save-excursion
                             (goto-char (point-min))
                             (when (search-forward "Tool" nil t)
                               (line-number-at-pos (match-beginning 0)))))
              (line-read (save-excursion
                           (goto-char (point-min))
                           (when (search-forward "Read" nil t)
                             (line-number-at-pos (match-beginning 0))))))
    ;; 两个折叠工具应占据相邻两行（无中间空白 / 省略号占位）
    (when (= line-read (1+ line-tool))
      (dsh-test-pass "tool-adjacent-stack-tight"))))

;; --- 测试 33: 光标锁定在可编辑输入区 ---
(with-temp-buffer
  (dsh-emacs-mode)
  (let ((inhibit-read-only t))
    (save-excursion
      (goto-char (point-min))
      (insert "user  hello\n")
      (put-text-property (point-min) (1- (point)) 'read-only t)))
  (let ((dsh-emacs--current-buffer (current-buffer))
        (dsh-emacs-pin-input-to-bottom nil))
    (dsh-emacs--ensure-input-marker)
    (let ((mpos (marker-position dsh-emacs--input-marker)))
      ;; 上移进入只读转录区阅读 → 应被允许（停留在原处）
      (goto-char (point-min))
      (dsh-emacs--lock-cursor-to-input)
      (when (= (point) (point-min))
        (dsh-test-pass "cursor-can-move-up-into-history"))
      ;; 光标试图移到输入区之下 → 应被钳制在输入区末端
      (goto-char (point-max))
      (dsh-emacs--lock-cursor-to-input)
      (let ((input-end (dsh-emacs--input-end)))
        (when (>= (point) mpos)
          (dsh-test-pass "cursor-cannot-move-below-input"))))
    ;; 从只读历史区直接输入 → 应被路由回输入区（避免 text-read-only）
    (let ((this-command 'self-insert-command))
      (goto-char (point-min))
      (dsh-emacs--route-typing-to-input)
      (when (= (point) (marker-position dsh-emacs--input-marker))
        (dsh-test-pass "typing-in-history-routes-to-input")))))

;; --- 测试 34: 运行中工具无 spinner 动画（行首图标）+ 完成后行不消失 ---
(with-temp-buffer
  (dsh-emacs-mode)
  (setq-local dsh-emacs-tool-expand-by-default t)
  (dsh-emacs-render-tool-call
   (dsh-emacs-test--tool-call-event 1 "c1" "bash" "{\"command\":\"ls -la\"}"))
  (let* ((st (dsh-emacs-render--tool-state "c1"))
         (ns (plist-get st :ns))
         (qid (format "%s-%s" ns (dsh-emacs-render--tool-call-block-id "c1"))))
    ;; 初始渲染：行首为变体图标（无 spinner 齿轮），无尾部 …
    (when-let* ((b (dsh-emacs-ui-find-block qid)))
      (let ((txt (buffer-substring-no-properties (car b) (cdr b))))
        (when (and (string-match-p (regexp-quote "💻 ") txt)
                   (not (string-match-p "⚙" txt))
                   (not (string-match-p "…" txt)))
          (dsh-test-pass "running-tool-no-spinner"))))
    ;; 工具完成后行仍正确渲染到同一块（不消失）
    (dsh-emacs-render-tool-result
     (dsh-emacs-test--tool-result-event 2 "c1" nil 0 "total 3\ndrwxrwxr-x"))
    (when-let* ((b (dsh-emacs-ui-find-block qid)))
      (let ((txt (buffer-substring-no-properties (car b) (cdr b))))
        (when (and (string-match-p "IN" txt)
                   (string-match-p "OUT" txt)
                   (string-match-p (regexp-quote "💻 ") txt))
          (dsh-test-pass "tool-row-not-lost-after-result"))))))

;; --- 测试 35: 历史真实 tool/result 使用 message.source.callId ---
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-footer-setup)
  (let ((call (dsh-emacs-test--tool-call-event
               10 "history-call" "bash" "{\"command\":\"pwd\"}"))
        (result (dsh-emacs-test--tool-result-event-source
                 11 "history-call" "/tmp/project")))
    (dsh-emacs-render-history-events
     (list (list (cons "event" call))
           (list (cons "event" result)))
     nil)
    (let ((state (dsh-emacs-render--tool-state "history-call")))
      (when (eq (plist-get state :state) 'success)
        (dsh-test-pass "history-tool-result-no-spinner")))))

;; --- 测试 36: 会话缓冲命名（与列表一致 + dsh 前缀） ---
(let* ((item (list (cons 'sessionId "sess-title-1")
                   (cons 'blank :json-false)
                   (cons 'projections
                         (list (cons 'values
                                     (list (cons 'title "Emacs 改造")))))))
       (old dsh-emacs--sessions))
  (setq dsh-emacs--sessions (list item))
  (when (string= "dsh-Emacs 改造" (dsh-emacs--chat-buffer-name "sess-title-1"))
    (dsh-test-pass "chat-buffer-name-with-title"))
  (setq dsh-emacs--sessions old))

(let ((old dsh-emacs--sessions))
  (setq dsh-emacs--sessions nil)
  (when (string= "dsh: sess-fallback" (dsh-emacs--chat-buffer-name "sess-fallback"))
    (dsh-test-pass "chat-buffer-name-fallback-without-title"))
  (setq dsh-emacs--sessions old))

;; --- 测试 37: 名称清洗（% 与换行） ---
(when (string= "进度50％完成" (dsh-emacs--sanitize-buffer-name "进度50%完成"))
  (dsh-test-pass "sanitize-percent-fullwidth"))

(when (string= "a b" (dsh-emacs--sanitize-buffer-name "a\nb"))
  (dsh-test-pass "sanitize-newline-flatten"))

(when (string= "" (dsh-emacs--sanitize-buffer-name "  "))
  (dsh-test-pass "sanitize-trims-whitespace"))

;; --- 测试 38: 标题含 % 时缓冲名使用全角 ％ ---
(let* ((item (list (cons 'sessionId "sess-pct")
                   (cons 'blank :json-false)
                   (cons 'projections
                         (list (cons 'values
                                     (list (cons 'title "完成50%")))))))
       (old dsh-emacs--sessions))
  (setq dsh-emacs--sessions (list item))
  (when (string= "dsh-完成50％" (dsh-emacs--chat-buffer-name "sess-pct"))
    (dsh-test-pass "chat-buffer-name-escape-percent"))
  (setq dsh-emacs--sessions old))

;; --- 测试 39: 同标题会话名称唯一（<N> 后缀） ---
(let* ((item (list (cons 'sessionId "sess-dup-1")
                   (cons 'blank :json-false)
                   (cons 'projections
                         (list (cons 'values
                                     (list (cons 'title "同题")))))))
       (old dsh-emacs--sessions)
       (b1 (get-buffer-create "dsh-同题"))
       (b2 (get-buffer-create (generate-new-buffer-name "dsh-同题"))))
  (unwind-protect
      (progn
        (setq dsh-emacs--sessions (list item))
        (when (string= "dsh-同题<2>" (buffer-name b2))
          (dsh-test-pass "chat-buffer-name-unique-suffix")))
    (setq dsh-emacs--sessions old)
    (when (buffer-live-p b1) (kill-buffer b1))
    (when (buffer-live-p b2) (kill-buffer b2))))

;; --- 测试 40: 缓存漂移时同步存活缓冲（改名 + 工作区目录） ---
(let* ((item (list (cons 'sessionId "sess-rename")
                   (cons 'blank :json-false)
                   (cons 'cwd "/tmp/proj")
                   (cons 'projections
                         (list (cons 'values
                                     (list (cons 'title "改名后")))))))
       (old dsh-emacs--sessions)
       (buf (get-buffer-create " *dsh-test-sync*")))
  (unwind-protect
      (progn
        (setq dsh-emacs--sessions (list item))
        (with-current-buffer buf
          (setq dsh-emacs--buffer-session "sess-rename")
          (rename-buffer "old-name"))
        (puthash "sess-rename" buf dsh-emacs--chat-buffers)
        (dsh-emacs--chat-buffer-sync "sess-rename")
        (when (string= "dsh-改名后" (buffer-name buf))
          (dsh-test-pass "chat-buffer-sync-renames"))
        (when (and (stringp (buffer-local-value 'default-directory buf))
                   (string= "/tmp/proj/"
                            (buffer-local-value 'default-directory buf)))
          (dsh-test-pass "chat-buffer-sync-sets-default-directory"))
        (remhash "sess-rename" dsh-emacs--chat-buffers))
    (setq dsh-emacs--sessions old)
    (when (buffer-live-p buf) (kill-buffer buf))))

;; --- 测试 40b: 会话工作区路径来源（session.list 的 cwd 字段） ---
(let* ((item (list (cons 'sessionId "sess-cwd")
                   (cons 'blank :json-false)
                   (cons 'cwd "/Users/ed/playground/dsh-emacs")
                   (cons 'projections
                         (list (cons 'values
                                     (list (cons 'title "某会话")))))))
       (old dsh-emacs--sessions))
  (setq dsh-emacs--sessions (list item))
  (when (string= "/Users/ed/playground/dsh-emacs"
                 (dsh-emacs--chat-cwd "sess-cwd"))
    (dsh-test-pass "chat-cwd-from-session-item"))
  (when (null (dsh-emacs--chat-cwd "sess-unknown"))
    (dsh-test-pass "chat-cwd-nil-when-unknown"))
  (setq dsh-emacs--sessions old))

;; --- 测试 41: 标题与列表显示一致 ---
(let* ((item (list (cons 'sessionId "sess-match")
                   (cons 'blank :json-false)
                   (cons 'projections
                         (list (cons 'values
                                     (list (cons 'title "与列表一致")))))))
       (old dsh-emacs--sessions))
  (setq dsh-emacs--sessions (list item))
  (when (string= "与列表一致" (dsh-emacs--chat-title "sess-match"))
    (dsh-test-pass "chat-title-matches-list"))
  (setq dsh-emacs--sessions old))

;; --- 测试 42: format-spec 的 customize 类型可勾选编辑（值往返一致） ---
(require 'cus-edit)
(let* ((spec (custom-variable-type 'dsh-emacs-footer-format-spec))
       (buf (generate-new-buffer " *dsh-widget-test*")))
  (with-current-buffer buf
    (let ((w (widget-create spec)))
      (widget-value-set w '(:separator " • " :segments (model tokens)))
      (when (equal '(:separator " • " :segments (model tokens))
                   (widget-value w))
        (dsh-test-pass "footer-format-spec-widget-roundtrip"))
      ;; 用户取消勾选某个段（subset）同样往返一致
      (widget-value-set w '(:separator " " :segments (model)))
      (when (equal '(:separator " " :segments (model))
                   (widget-value w))
        (dsh-test-pass "footer-format-spec-widget-subset"))))
  (kill-buffer buf))

;; --- 测试 43: 首次打开会话即定位工作区（default-directory） ---
;; 回归：sync 曾在 `setq-local dsh-emacs--buffer-session' 之前调用，
;; 首次打开的缓冲因此被 sync 的守卫静默跳过，default-directory 从未设置
;; 导致 magit 无法定位项目。这里用 stub 屏蔽网络/渲染，走完整 open 路径。
(cl-letf (((symbol-function 'dsh-emacs-events-connect) (lambda (&rest _) nil))
          ((symbol-function 'dsh-emacs--load-history) (lambda (&rest _) nil))
          ((symbol-function 'pop-to-buffer) (lambda (&rest _) nil)))
  (let ((old-sessions dsh-emacs--sessions)
        (old-current-buffer dsh-emacs--current-buffer)
        (old-current-session dsh-emacs--current-session))
    (unwind-protect
        (progn
          (setq dsh-emacs--sessions
                (list (list (cons 'sessionId "sess-open")
                            (cons 'blank :json-false)
                            (cons 'cwd "/tmp/ws")
                            (cons 'agentPreset "standard")
                            (cons 'projections
                                  (list (cons 'values
                                              (list (cons 'title "开场"))))))))
          (dsh-emacs-open-session "sess-open")
          (let ((buf dsh-emacs--current-buffer))
            (when (and (bufferp buf)
                       (string= "/tmp/ws/"
                                (buffer-local-value 'default-directory buf)))
              (dsh-test-pass "open-session-first-open-sets-default-directory"))
            (when (and (bufferp buf) (string= "dsh-开场" (buffer-name buf)))
              (dsh-test-pass "open-session-first-open-names-buffer"))))
      (setq dsh-emacs--sessions old-sessions
            dsh-emacs--current-buffer old-current-buffer
            dsh-emacs--current-session old-current-session)
      (dolist (b (buffer-list))
        (when (and (buffer-local-value 'dsh-emacs--buffer-session b)
                   (string= "sess-open"
                            (buffer-local-value 'dsh-emacs--buffer-session b)))
          (kill-buffer b)))
      (remhash "sess-open" dsh-emacs--chat-buffers))))

;; --- 测试 44: 聊天缓冲从不显示 modified / 关闭不提示保存 ---
(with-temp-buffer
  (dsh-emacs-mode)
  (insert "hello")
  (when (not (buffer-modified-p))
    (dsh-test-pass "chat-buffer-insert-keeps-unmodified")))

(let ((buf (get-buffer-create " *dsh-mod-test*")))
  (unwind-protect
      (progn
        (with-current-buffer buf
          (dsh-emacs-mode)
          (insert "x"))
        ;; 模拟外部代码强制标记 modified 后，kill 查询路径仍能放行。
        ;; 契约：query 函数返回 t 才放行（返回 nil 会静默阻止 kill——
        ;; 这是上一版"关不掉"回归的根因，见测试 44b）。
        (with-current-buffer buf
          (set-buffer-modified-p t)
          (let ((ret (dsh-emacs--chat-buffer-clear-modified)))
            (when (and (eq ret t) (not (buffer-modified-p)))
              (dsh-test-pass "kill-query-fn-clears-modified-allows-kill"))))
        ;; 恢复 after-change 不变量：clear 后若再插入，仍保持 unmodified
        (with-current-buffer buf
          (insert "y")
          (when (not (buffer-modified-p))
            (dsh-test-pass "chat-buffer-reinsert-stays-clean"))))
    (when (buffer-live-p buf) (kill-buffer buf))))

;; --- 测试 44b: 真实 kill 路径——query 返回 t，缓冲确实被杀掉 ---
(let ((buf (get-buffer-create " *dsh-kill-test*")))
  (with-current-buffer buf
    (dsh-emacs-mode)
    (insert "x"))
  (let ((res (kill-buffer buf)))
    (when (and (eq res t) (not (buffer-live-p buf)))
      (dsh-test-pass "chat-buffer-kill-buffer-succeeds"))))

;; --- 测试 45: doom 段包含忙碌动画（回归：动画此前只存在于 vanilla splice，
;; doom-modeline 分支的段漏掉了它，导致动画从未显示） ---
(let ((dsh-emacs--footer-usage (dsh-emacs-make-usage 100 50))
      (dsh-emacs--footer-model "deepseek-v4-flash-0731")
      (dsh-emacs--footer-effort "standard")
      (dsh-emacs--ml-busy t)
      (dsh-emacs--ml-busy-index 4))
  (let ((txt (dsh-emacs-footer--doom-segment)))
    (when (and (string-match-p "deepseek-v4-flash-0731-standard" txt)
               (string-match-p "████" txt)
               ;; 动画在统计之前（紧贴 DSH 模式名之后）
               (< (string-match "████" txt)
                  (string-match "deepseek-v4" txt)))
      (dsh-test-pass "doom-segment-includes-busy-animation"))))

(let ((dsh-emacs--ml-busy nil)
      (dsh-emacs--footer-usage nil))
  (when (string= "" (dsh-emacs-footer--doom-segment))
    (dsh-test-pass "doom-segment-empty-when-idle")))

;; --- 测试 46: send-or-stop 忙碌时打断（session.cancel），空闲时发送 ---
(let ((buf (generate-new-buffer " *dsh-interrupt-test*"))
      (calls nil))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (setq dsh-emacs--current-session "sess-cancel")
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (method params _cb)
                     (push (list method params) calls))))
          ;; 忙碌 → 再按 C-c C-c 应发 session.cancel 而不是排新消息
          (setq-local dsh-emacs--ml-busy t)
          (dsh-emacs-send-or-stop)
          (let ((call (car calls)))
            (when (and (string= "session.cancel" (car call))
                       (string= "sess-cancel"
                                (cdr (assq 'sessionId (cadr call)))))
              (dsh-test-pass "send-or-stop-busy-interrupts-via-cancel")))
          ;; 空闲 + 有文本 → 发送 session.prompt
          (setq-local dsh-emacs--ml-busy nil)
          (setq calls nil)
          (dsh-emacs--replace-input "hello there")
          (dsh-emacs-send-or-stop)
          (let* ((call (car calls))
                 (params (cadr call))
                 (content (cdr (assq 'content params)))
                 (part (and content (aref content 0))))
            (when (and (string= "session.prompt" (car call))
                       (string= "hello there" (cdr (assq 'text part))))
              (dsh-test-pass "send-or-stop-idle-sends-prompt")))
          ;; 空闲 + 空文本 → 不发出任何请求
          (setq calls nil)
          (dsh-emacs--replace-input "   ")
          (dsh-emacs-send-or-stop)
          (when (null calls)
            (dsh-test-pass "send-or-stop-idle-empty-noop"))))
    (kill-buffer buf)))

;; --- 测试 47: 模型目录展开 + selectModel 调用 ---
(let* ((g1 '((id . "g1") (name . "DeepSeek")
             (models . [((id . "m1") (name . "Model One"))
                        ((id . "m2"))])))
       (g2 '((id . "g2") (name . "qwen-token-plan")
             (models . [((id . "m3") (name . "Qwen-M"))])))
       (cands (dsh-emacs--model-candidates `((groups . [,g1 ,g2])))))
  ;; 每项带 (id provider 组名)，provider 取所属组的 id
  (when (equal cands '(("m1" "g1" "DeepSeek" "Model One")
                       ("m2" "g1" "DeepSeek" "m2")
                       ("m3" "g2" "qwen-token-plan" "Qwen-M")))
    (dsh-test-pass "model-candidates-flattened")))

(let ((buf (generate-new-buffer " *dsh-model-test*"))
      (calls nil))
  (unwind-protect
      (with-current-buffer buf
        (setq dsh-emacs--current-session "sess-m")
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (method params cb)
                     (push (list method params) calls)
                     (when (string= method "session.models")
                       (funcall cb
                                t
                                '((current . ((provider . "p1") (model . "m0")))
                                  (groups . [((id . "g1") (name . "DeepSeek")
                                              (models . [((id . "m1")
                                                          (name . "Model One"))]))]))))))
                  ((symbol-function 'completing-read)
                   ;; 用户选择的键是 padded 展示字符串（真实 minibuffer 返回的）
                   (lambda (&rest _)
                     (format "%-28s %-18s %s"
                             "m1" "DeepSeek" "Model One"))))
          (dsh-emacs-select-model)
          (let* ((call (car calls))
                 (params (cadr call)))
            (when (and (string= "session.selectModel" (car call))
                       (string= "m1" (cdr (assq 'model params)))
                       (string= "g1" (cdr (assq 'provider params)))
                       (string= "sess-m" (cdr (assq 'sessionId params))))
              (dsh-test-pass "select-model-sends-selectModel")))))
    (kill-buffer buf)))

;; --- 测试 48: 附件（图片 base64 内联进 session.prompt） ---
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
          (setq dsh-emacs--current-session "sess-a")
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method params _cb)
                       (push (list method params) calls))))
            (dsh-emacs-attach-file png-file "the pixel"))
          (let* ((call (car calls))
                 (params (cadr call))
                 (images (cdr (assq 'images params)))
                 (att (and images (car images)))
                 (content (cdr (assq 'content params)))
                 (part (and content (aref content 0))))
            (when (and (string= "session.prompt" (car call))
                       (string= "the pixel" (cdr (assq 'text part))))
              (dsh-test-pass "attach-sends-caption"))
            (when (and att (string= "image/png" (cdr (assq 'mediaType att)))
                       (string-prefix-p "dsh-test-1px" (cdr (assq 'name att)))
                       (string-suffix-p ".png" (cdr (assq 'name att))))
              (dsh-test-pass "attach-sends-image-part"))
            (when (and att (stringp (cdr (assq 'data att)))
                       ;; 1x1 PNG 的 base64 远长于空字符串
                       (> (length (cdr (assq 'data att))) 20))
              (dsh-test-pass "attach-base64-data")))))
    (delete-file png-file)
    (kill-buffer buf)))

;; --- 测试 49: 代码块复制 ---
(let ((buf (generate-new-buffer " *dsh-copy-block*")))
  (unwind-protect
      (with-current-buffer buf
        (insert "before\n```elisp\n(message \"hi\")\n```\nafter\n")
        (dsh-emacs-markdown-replace-markup :force t :highlight-blocks nil)
        ;; 点落在代码块体内 → 复制
        (goto-char (point-min))
        (when (search-forward "(message" nil t)
          (dsh-emacs-copy-code-block)
          (when (string= "(message \"hi\")" (car kill-ring))
            (dsh-test-pass "copy-code-block-copies-body")))
        ;; 点落在块外 → 明确报错而不是静默
        (goto-char (point-min))
        (let ((err (condition-case e
                       (progn (dsh-emacs-copy-code-block) nil)
                     (error (error-message-string e)))))
          (when (and (stringp err)
                     (string-match-p "not inside" err))
            (dsh-test-pass "copy-code-block-errors-outside"))))
    (kill-buffer buf)))

;; --- 测试 50: fork 会话 ---
(let ((opened nil)
      (listed nil)
      (calls nil))
  (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
             (lambda (method params cb)
               (push (list method params) calls)
               (when (string= method "session.fork")
                 (funcall cb t '((sessionId . "child-1"))))))
            ((symbol-function 'dsh-emacs-open-session)
             (lambda (sid) (setq opened sid)))
            ((symbol-function 'dsh-emacs-list-sessions)
             (lambda () (setq listed t))))
    (dsh-emacs-fork-session "parent-1")
    (let* ((call (car calls))
           (params (cadr call)))
      (when (and (string= "session.fork" (car call))
                 (string= "parent-1" (cdr (assq 'sessionId params))))
        (dsh-test-pass "fork-passes-session-id")))
    (when (string= "child-1" opened)
      (dsh-test-pass "fork-opens-child"))
    (when listed
      (dsh-test-pass "fork-refreshes-list"))))

;; --- 测试 51: 会话列表工作区过滤 ---
(let ((sessions (list (list (cons 'sessionId "s1") (cons 'updatedAt 100)
                            (cons 'projections
                                  (list (cons 'values (list (cons 'title "Alpha"))))))
                      (list (cons 'sessionId "s2") (cons 'updatedAt 200)
                            (cons 'projections
                                  (list (cons 'values (list (cons 'title "Beta"))))))
                      (list (cons 'sessionId "s3") (cons 'updatedAt 300)
                            (cons 'projections
                                  (list (cons 'values (list (cons 'title "Gamma"))))))))
      (workspaces (list (list (cons 'workspaceId "w1") (cons 'title "WS A")
                              (cons 'sessionIds ["s1" "s2"])))))
  ;; 过滤到 w1：只剩 WS A 的成员，Ungrouped 桶被抑制
  ;; 注意：`filtered' 的初始化器必须在 filter 绑定建立后再求值，
  ;; 所以这里用 let*（let 的初始化器在绑定建立前求值，会读到旧值）
  (let* ((dsh-emacs--archived-sessions nil)
         (dsh-emacs-session--filter-ws-id "w1")
         (filtered (dsh-emacs-session--group-sessions sessions workspaces)))
    (when (and (= 1 (length filtered))
               (equal "WS A" (plist-get (car filtered) :label))
               (= 2 (length (plist-get (car filtered) :sessions))))
      (dsh-test-pass "session-filter-restricts-workspace")))
  ;; 无过滤：WS A + Ungrouped 两个桶都在
  (let* ((dsh-emacs--archived-sessions nil)
         (dsh-emacs-session--filter-ws-id nil)
         (grouped (dsh-emacs-session--group-sessions sessions workspaces)))
    (when (and (= 2 (length grouped))
               (cl-some (lambda (g) (equal "WS A" (plist-get g :label))) grouped)
               (cl-some (lambda (g) (equal "Ungrouped" (plist-get g :label))) grouped))
      (dsh-test-pass "session-group-keeps-ungrouped")))
  ;; 渲染层面：过滤生效时其他工作区/未分组会话不可见
  (let ((buf (generate-new-buffer " *dsh-filter-render*")))
    (unwind-protect
        (with-current-buffer buf
          (let ((dsh-emacs--sessions sessions)
                (dsh-emacs--workspaces workspaces)
                (dsh-emacs--archived-sessions nil)
                (dsh-emacs-session--filter-ws-id "w1")
                (dsh-emacs-session--filter-ws-title "WS A"))
            (dsh-emacs-session--render)
            (let ((txt (buffer-substring-no-properties
                           (point-min) (point-max))))
              ;; 行按 recency 排序（Beta 在 Alpha 前），用整段匹配避免顺序依赖
              (when (and (string-match-p "Filter: WS A" txt)
                         (string-match-p "Alpha" txt)
                         (string-match-p "Beta" txt)
                         (not (string-match-p "Gamma" txt)))
                (dsh-test-pass "session-filter-render-hides-other-sessions")))))
      (kill-buffer buf))))

;; --- 测试 52: 输入历史 M-p / M-n ---
(let ((old-hist dsh-emacs--input-history)
      (old-pos dsh-emacs--input-history-pos)
      (old-pending dsh-emacs--input-history-pending)
      (buf (generate-new-buffer " *dsh-hist-test*")))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (dsh-emacs--push-input-history "first")
        (dsh-emacs--push-input-history "second")
        (dsh-emacs--replace-input "typed")
        (dsh-emacs-input-history-back)          ; 最新 "second"
        (when (string= "second" (dsh-emacs--get-input))
          (dsh-test-pass "input-history-back-shows-newest"))
        (dsh-emacs-input-history-back)          ; 更早 "first"
        (when (string= "first" (dsh-emacs--get-input))
          (dsh-test-pass "input-history-back-older"))
        (dsh-emacs-input-history-forward)       ; 回到 "second"
        (when (string= "second" (dsh-emacs--get-input))
          (dsh-test-pass "input-history-forward-newer"))
        (dsh-emacs-input-history-forward)       ; 恢复浏览前输入 "typed"
        (when (string= "typed" (dsh-emacs--get-input))
          (dsh-test-pass "input-history-forward-restores-pending")))
    (kill-buffer buf)
    (setq dsh-emacs--input-history old-hist
          dsh-emacs--input-history-pos old-pos
          dsh-emacs--input-history-pending old-pending)))

;; --- 测试 53: 提交后进入历史（submit 回推 + 状态复位） ---
(let ((old-hist dsh-emacs--input-history)
      (old-pos dsh-emacs--input-history-pos)
      (buf (generate-new-buffer " *dsh-hist2-test*")))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (setq dsh-emacs--current-session "sess-h")
        (setq dsh-emacs--input-history-pos 0)   ; 假装处于浏览态
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (method params cb) (funcall cb t '((accepted . t))))))
          (dsh-emacs--submit-prompt "submitted text"))
        (when (and (string= "submitted text" (car dsh-emacs--input-history))
                   (null dsh-emacs--input-history-pos))
          (dsh-test-pass "submit-prompt-records-history-and-resets")))
    (kill-buffer buf)
    (setq dsh-emacs--input-history old-hist
          dsh-emacs--input-history-pos old-pos)))

;; --- 测试 54: pinned 输入窗在忙碌时也能识别打断状态 ---
(let ((chat (generate-new-buffer " *dsh-pinned-chat*"))
      (pinned (generate-new-buffer " *dsh-pinned-input*")))
  (unwind-protect
      (progn
        (with-current-buffer chat
          (setq-local dsh-emacs--ml-busy t))
        (with-current-buffer pinned
          (setq-local dsh-emacs--input-chat-buffer chat)
          (when (dsh-emacs--busy-p)
            (dsh-test-pass "busy-p-reflects-chat-from-pinned-input"))))
    (kill-buffer chat)
    (kill-buffer pinned)))

;; --- 总结 ---
(princ "\n===== 测试总结 =====\n")
(let ((pass (cl-count-if (lambda (r) (cdr r)) dsh-test-results))
      (fail (cl-count-if (lambda (r) (not (cdr r))) dsh-test-results)))
  (princ (format "通过 %d 项，失败 %d 项\n" pass fail))
  (when (> fail 0)
    (princ "失败的测试:\n")
    (dolist (r (nreverse dsh-test-results))
      (unless (cdr r)
        (princ (format "  - %s: %s\n" (car r) (cdr r)))))))
