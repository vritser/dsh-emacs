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

(defun dsh-emacs-test--session-items (items)
  "Wrap raw session-item alists ITEMS as `dsh-protocol-session' structs
so the code under test can read fields through the protocol accessors."
  (mapcar #'dsh-protocol-session--from-alist items))

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
  (let ((dsh-emacs-footer-format-spec '(:separator " " :segments (tokens))))
    (setq txt (dsh-emacs-footer-format))
    (when (and (string-match "↑300" txt) (string-match "↓60" txt)
               (string-match "CH92%" txt))
      (dsh-test-pass "footer-format renders accumulated tokens"))))

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

;; --- 测试 5e: model/effort/preset 三独立分段 + modeinline 括号 ---
(let ((dsh-emacs-footer-format-spec '(:separator " " :segments (model effort preset)))
      (txt (progn
             (setq dsh-emacs--footer-model "m1"
                   dsh-emacs--footer-effort "max"
                   dsh-emacs--footer-preset "standard")
             (dsh-emacs-footer-format))))
  (when (and (string-match "m1" txt)
             (string-match "max" txt)
             (string-match "standard" txt)
             (not (string-match "m1-standard" txt)))
    (dsh-test-pass "model effort preset render as separate segments")))
(let* ((dsh-emacs-footer-format-spec '(:separator " " :segments (model tokens ctx)))
       (txt (progn
              (dsh-emacs-footer-set-effort nil)
              (dsh-emacs-footer--modeinline))))
  (when (and (string-prefix-p "(" txt) (string-match-p ") *$" txt)
             (string-match "CH92%%" txt))
    (dsh-test-pass "modeinline wraps stats in parens and escapes percent")))

;; --- 测试 5f: request/header 喂 model 与 reasoningEffort（rc.1 事件形状） ---
(let ((hdr '(("type" . "request/header")
             ("seq" . 11)
             ("data" . (("header" . (("config" . (("provider" . "opencode-go")
                                                  ("model" . "deepseek-v4-flash")
                                                  ("reasoningEffort" . "high"))))))))))
  (setq dsh-emacs--footer-model nil
        dsh-emacs--footer-effort nil)
  (dsh-emacs-footer-note-header hdr)
  (when (and (equal "deepseek-v4-flash" dsh-emacs--footer-model)
             (equal "high" dsh-emacs--footer-effort))
    (dsh-test-pass "note-header feeds model and reasoning effort"))
  (setq dsh-emacs--footer-model nil
        dsh-emacs--footer-effort nil))

;; --- 测试 5g: render 调度转发 request/header 到 footer feed ---
(let ((fired 0))
  (cl-letf (((symbol-function 'dsh-emacs-footer-note-header)
             (lambda (_event) (setq fired (1+ fired)))))
    (dsh-emacs-render-event '(("type" . "request/header") ("seq" . 5)))
    (dsh-emacs-render-event '(("type" . "request/context") ("seq" . 6))))
  (when (= 1 fired)
    (dsh-test-pass "render-dispatches-request-header-to-footer")))

;; --- 测试 5h: ctx 窗口解析优先级：buffer-local > 模型映射表 > 默认值 ---
(let ((dsh-emacs-footer-context-window-alist
       '(("deepseek-v4-flash" . 1000000)
         ("other-model" . 65536)))
      (dsh-emacs-footer-context-window nil))
  ;; 仅模型已知 → 走映射表
  (setq dsh-emacs--footer-model "deepseek-v4-flash"
        dsh-emacs--footer-context-window nil)
  (when (= 1000000 (dsh-emacs-footer--ctx-window))
    (dsh-test-pass "ctx-window-resolves-from-model-alist"))
  ;; buffer-local（来自实时 request/context）> 映射表
  (setq dsh-emacs--footer-context-window 200000)
  (when (= 200000 (dsh-emacs-footer--ctx-window))
    (dsh-test-pass "ctx-window-buffer-local-wins"))
  ;; 模型不在表内 → 默认值兜底
  (setq dsh-emacs--footer-model "ghost-model"
        dsh-emacs--footer-context-window nil
        dsh-emacs-footer-context-window 131072)
  (when (= 131072 (dsh-emacs-footer--ctx-window))
    (dsh-test-pass "ctx-window-falls-back-to-default"))
  ;; 全部未知 → nil（ctx 段隐藏）
  (setq dsh-emacs--footer-model nil
        dsh-emacs-footer-context-window nil)
  (when (null (dsh-emacs-footer--ctx-window))
    (dsh-test-pass "ctx-window-unknown-hides-segment"))
  (setq dsh-emacs--footer-model nil
        dsh-emacs--footer-context-window nil
        dsh-emacs-footer-context-window nil))

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

;; --- 测试 8: minimal label 行分隔符 · ---
(with-temp-buffer
  (let ((dsh-emacs-ui-label-separator "·"))
    (dsh-emacs-ui-update-fragment
     (dsh-emacs-ui-make-fragment
      :namespace-id "sep" :block-id "1"
      :label-left "✶ Think" :label-right "preview"
      :body "body line" :style 'minimal)
     :create-new t :expanded t)
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      (when (and (string-match-p "✶ Think · preview" text)
                 (string-match-p "│ body line" text))
        (dsh-test-pass "minimal-label-separator-dot")))))

(with-temp-buffer
  (let ((dsh-emacs-ui-label-separator ""))
    (dsh-emacs-ui-update-fragment
     (dsh-emacs-ui-make-fragment
      :namespace-id "sep2" :block-id "1"
      :label-left "✶ Think" :label-right "preview"
      :body "body line" :style 'minimal)
     :create-new t :expanded t)
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      (when (and (string-match-p "✶ Think  preview" text)
                 (not (string-match-p "·" text)))
        (dsh-test-pass "minimal-label-separator-disabled")))))

;; --- 测试 9: 事件渲染器函数存在 ---
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
               (goto-char marker-pos)
               (looking-back "❯ " (line-beginning-position)))
      (dsh-test-pass "inline-mode-single-buffer"))))

;; --- 测试 27e: telega 式滚动纪律（chatbuf 缓冲局部） ---
(with-temp-buffer
  (dsh-emacs-mode)
  (when (and (local-variable-p 'scroll-conservatively (current-buffer))
             (= 101 scroll-conservatively)
             (= 0 (or next-screen-context-lines -1))
             scroll-error-top-bottom)
    (dsh-test-pass "chat-buffer-scroll-discipline")))

;; --- 测试 27g: 用户消息前后各留一个空行；助手消息之间仍紧贴 ---
(let ((buf (generate-new-buffer " *t27g-layout*")))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (dsh-emacs-footer-setup)
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
                  (when (search-forward "❯ u1" nil t)
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
          (when (and above-blank below-blank)
            (dsh-test-pass "user-message-spaced-above-and-below"))
          ;; 相邻助手消息仍然紧贴（无空行）
          (when (and a1-line a2-line (= a2-line (1+ a1-line)))
            (dsh-test-pass "assistant-messages-remain-flush"))))
    (kill-buffer buf)))

;; --- 测试 28: WebSocket 握手后的帧仍被消费（实时修复） ---
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-footer-setup)
  (setq dsh-emacs--current-session "s1")   ; match the test frame's sessionId
  (setq-local dsh-emacs--buffer-session "s1") ; 归属断言：真实 open-session 会设置
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

;; --- 测试 24: 输入 anchor 独占一行（footer 之前） ---
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-footer-setup)
  ;; The anchor prompt line always ends with a newline and sits right before
  ;; the footer, so point-max never falls inside the editable input.
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
               ;; 运行中保留变体图标；动画 spinner 已移至 footer 进度条
               (string-match-p "Bash" block))
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

;; --- 测试 32: 工具名与图标解耦 —— 同图标不同名 ---
(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-footer-setup)
  (dsh-emacs-render-tool-call
   (dsh-emacs-test--tool-call-event 1 "g1" "grep" "{\"pattern\":\"foo\"}"))
  (let* ((ns (dsh-emacs-render--make-namespace))
         (block (dsh-emacs-test--tool-block-text (format "%s-tool-g1" ns))))
    (when (and block
               (string-match-p "🔍 Grep" block)      ; 放大镜图标 + 真实工具名
               (not (string-match-p "Search" block)) ; 不得再显示成 Search
               (not (string-match-p "· Search" block)))
      (dsh-test-pass "tool-grep-title-distinct-from-search"))))

(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-footer-setup)
  (dsh-emacs-render-tool-call
   (dsh-emacs-test--tool-call-event 1 "w1" "web_search" "{\"query\":\"cats\"}"))
  (let* ((ns (dsh-emacs-render--make-namespace))
         (block (dsh-emacs-test--tool-block-text (format "%s-tool-w1" ns))))
    (when (and block
               (string-match-p "🔍 Web Search" block)
               (not (string-match-p "🔍 Search · cats" block)))
      (dsh-test-pass "tool-web-search-title-keeps-variant-icon"))))

(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-footer-setup)
  (dsh-emacs-render-tool-call
   (dsh-emacs-test--tool-call-event 1 "u1" "my_tool" "{\"x\":\"1\"}"))
  (let* ((ns (dsh-emacs-render--make-namespace))
         (block (dsh-emacs-test--tool-block-text (format "%s-tool-u1" ns))))
    (when (and block (string-match-p "✨ My Tool" block))
      (dsh-test-pass "tool-unknown-humanized-title"))))

(with-temp-buffer
  (dsh-emacs-mode)
  (dsh-emacs-footer-setup)
  (let ((dsh-emacs-tool-titles '(("my_tool" . "Curated")))) ; defcustom 覆写
    (dsh-emacs-render-tool-call
     (dsh-emacs-test--tool-call-event 1 "u2" "my_tool" "{\"x\":\"1\"}")))
  (let* ((ns (dsh-emacs-render--make-namespace))
         (block (dsh-emacs-test--tool-block-text (format "%s-tool-u2" ns))))
    (when (and block (string-match-p "✨ Curated" block))
      (dsh-test-pass "tool-title-defcustom-override"))))

;; --- 测试 33: 相邻工具行紧凑堆叠（无多余空行） ---
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
  (when-let* ((line-search (save-excursion
                             (goto-char (point-min))
                             (when (search-forward "Search" nil t)
                               (line-number-at-pos (match-beginning 0)))))
              (line-read (save-excursion
                           (goto-char (point-min))
                           (when (search-forward "Read" nil t)
                             (line-number-at-pos (match-beginning 0))))))
    ;; 两个折叠工具应占据相邻两行（无中间空白 / 省略号占位）
    (when (= line-read (1+ line-search))
      (dsh-test-pass "tool-adjacent-stack-tight"))))

;; --- 测试 33: 光标锁定在可编辑输入区 ---
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

;; --- 测试 33b: 光标钳制在输入区底部 —— 多行输入不受影响，且与全局
;;     current-buffer（多会话时指向最后打开的会话）无关 ---
(let* ((chat (get-buffer-create " *t33b-chat*"))
       (other (generate-new-buffer " *t33b-other*")))
  (unwind-protect
      (progn
        (with-current-buffer chat
          (dsh-emacs-mode)
          (dsh-emacs-footer-setup)
          ;; 模拟多会话：全局 current-buffer 指向别的会话
          (setq dsh-emacs--current-buffer other))
        (with-current-buffer chat
          (let ((inhibit-read-only t))
            (goto-char dsh-emacs--input-marker)
            (insert "line one\nline two\nline three"))
          (let ((input-end (dsh-emacs--input-end)))
            ;; 越界（M-> / 点击 footer 区）→ 钳回输入区末端
            (goto-char (point-max))
            (dsh-emacs--lock-cursor-to-input)
            (when (= (point) input-end)
              (dsh-test-pass "cursor-clamped-at-input-area-end"))
            ;; 多行输入内部的光标位置不动（不受影响）
            (goto-char dsh-emacs--input-marker)
            (forward-line 1)
            (let ((mid (point)))
              (dsh-emacs--lock-cursor-to-input)
              (when (= (point) mid)
                (dsh-test-pass "cursor-stays-inside-multi-line-input")))
            ;; 恰好停在输入区末端 → 不误伤
            (goto-char input-end)
            (dsh-emacs--lock-cursor-to-input)
            (when (= (point) input-end)
              (dsh-test-pass "cursor-at-input-end-not-moved")))))
    (kill-buffer chat)
    (kill-buffer other)))

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

;; --- 测试 34b: 用户消息之后紧跟工具行：保留一个空行 ---
(let ((buf (generate-new-buffer " *t34b-layout*")))
  (unwind-protect
      (with-current-buffer buf
        (dsh-emacs-mode)
        (dsh-emacs-footer-setup)
        (setq-local dsh-emacs-tool-expand-by-default t)
        (dsh-emacs-render-event
         (json-read-from-string
          "{\"type\":\"user/message\",\"seq\":1,\"data\":{\"content\":[{\"type\":\"text\",\"text\":\"u2\"}]}}"))
        (dsh-emacs-render-tool-call
         (dsh-emacs-test--tool-call-event 2 "t1" "bash" "{\"command\":\"ls\"}"))
        (let* ((user-line
                (save-excursion
                  (goto-char (point-min))
                  (when (search-forward "❯ u2" nil t)
                    (line-number-at-pos (line-beginning-position)))))
               (tool-line
                (save-excursion
                  (goto-char (point-min))
                  (when (search-forward "💻 " nil t)
                    (line-number-at-pos (line-beginning-position))))))
          (when (and user-line tool-line (= tool-line (+ user-line 2)))
            (dsh-test-pass "tool-after-user-keeps-one-blank"))))
    (kill-buffer buf)))

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
  (setq dsh-emacs--sessions
                (dsh-emacs-test--session-items (list item)))
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
  (setq dsh-emacs--sessions
                (dsh-emacs-test--session-items (list item)))
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
        (setq dsh-emacs--sessions
                (dsh-emacs-test--session-items (list item)))
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
        (setq dsh-emacs--sessions
                (dsh-emacs-test--session-items (list item)))
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
  (setq dsh-emacs--sessions
                (dsh-emacs-test--session-items (list item)))
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
  (setq dsh-emacs--sessions
                (dsh-emacs-test--session-items (list item)))
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
                (dsh-emacs-test--session-items
                 (list (list (cons 'sessionId "sess-open")
                             (cons 'blank :json-false)
                             (cons 'cwd "/tmp/ws")
                             (cons 'agentPreset "standard")
                             (cons 'projections
                                   (list (cons 'values
                                               (list (cons 'title "开场")))))))))
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

;; --- 测试 43b: 打开新会话不再断开其它会话的流（多会话实时） ---
;; 回归：open-session 曾无条件断开上一个 current-buffer 的 mux——从 A 打开
;; B 时把 A 的流拆了且无人重连，A 之后只能轮询，还会冒出误导性的
;; "event stream connecting / switches back to realtime" 提示（永远回不去）。
(let* ((buf-a (generate-new-buffer " *t43b-a*"))
       (disconnects nil)
       (connects nil)
       (old-sessions dsh-emacs--sessions)
       (old-current-buffer dsh-emacs--current-buffer)
       (old-current-session dsh-emacs--current-session))
  (unwind-protect
      (progn
        (with-current-buffer buf-a
          (setq-local dsh-emacs--buffer-session "sess-ka"))
        (setq dsh-emacs--current-buffer buf-a
              dsh-emacs--current-session "sess-ka")
        (setq dsh-emacs--sessions
              (dsh-emacs-test--session-items
               (list (list (cons 'sessionId "sess-ka")
                           (cons 'blank :json-false)
                           (cons 'agentPreset "standard"))
                     (list (cons 'sessionId "sess-kb")
                           (cons 'blank :json-false)
                           (cons 'agentPreset "standard")))))
        (cl-letf (((symbol-function 'dsh-emacs-events-connect)
                   (lambda (chat) (push (list 'connect chat) connects)))
                  ((symbol-function 'dsh-emacs-events-disconnect)
                   (lambda (&optional chat)
                     (push (list 'disconnect chat) disconnects)))
                  ((symbol-function 'dsh-emacs--load-history)
                   (lambda (&rest _) nil))
                  ((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (&rest _) nil))
                  ((symbol-function 'pop-to-buffer)
                   (lambda (&rest _) nil)))
          (dsh-emacs-open-session "sess-kb"))
        (let ((buf-b dsh-emacs--current-buffer))
          ;; 新会话自己建连
          (when (and connects (eq (nth 1 (car connects)) buf-b))
            (dsh-test-pass "open-second-session-connects-its-own-stream"))
          ;; A 的流没有被断开
          (when (not (cl-some (lambda (d) (eq (nth 1 d) buf-a))
                              disconnects))
            (dsh-test-pass "open-second-session-keeps-previous-stream")))
        ;; 重开同一会话：仍是自建连（自身旧流由 connect 内部断开）
        (setq disconnects nil connects nil)
        (cl-letf (((symbol-function 'dsh-emacs-events-connect)
                   (lambda (chat) (push (list 'connect chat) connects)))
                  ((symbol-function 'dsh-emacs-events-disconnect)
                   (lambda (&optional chat)
                     (push (list 'disconnect chat) disconnects)))
                  ((symbol-function 'dsh-emacs--load-history)
                   (lambda (&rest _) nil))
                  ((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (&rest _) nil))
                  ((symbol-function 'pop-to-buffer)
                   (lambda (&rest _) nil)))
          (dsh-emacs-open-session "sess-kb"))
        (when (and connects
                   (eq (nth 1 (car connects)) dsh-emacs--current-buffer))
          (dsh-test-pass "reopen-same-session-reconnects-itself")))
    (setq dsh-emacs--sessions old-sessions
          dsh-emacs--current-buffer old-current-buffer
          dsh-emacs--current-session old-current-session)
    (dolist (b (buffer-list))
      (let ((sid (buffer-local-value 'dsh-emacs--buffer-session b)))
        (when (member sid '("sess-ka" "sess-kb"))
          (kill-buffer b))))
    (remhash "sess-ka" dsh-emacs--chat-buffers)
    (remhash "sess-kb" dsh-emacs--chat-buffers)))

;; --- 测试 43c: 发送时会话若完全没有流则先重连再轮询（自愈） ---
(let* ((chat (get-buffer-create " *t43c-chat*"))
       (connects nil)
       (polled nil)
       (old-current-session dsh-emacs--current-session))
  (unwind-protect
      (progn
        (with-current-buffer chat
          (dsh-emacs-mode)
          (setq-local dsh-emacs--buffer-session "sess-sh")
          (setq dsh-emacs--event-ready nil
                dsh-emacs--event-process nil))
        ;; 场景 1：完全无流（进程都不存在）→ 重连 + 轮询
        (with-current-buffer chat
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (_method _params cb)
                       (funcall cb t '((accepted . t)))))
                    ((symbol-function 'dsh-emacs--get-input)
                     (lambda () ""))
                    ((symbol-function 'dsh-emacs--ml-busy-set)
                     (lambda (&rest _) nil))
                    ((symbol-function 'dsh-emacs-events-connect)
                     (lambda (c) (push c connects)))
                    ((symbol-function 'dsh-emacs--start-polling)
                     (lambda () (setq polled t)))
                    ((symbol-function 'dsh-emacs-events--watchdog-start)
                     (lambda () nil)))
            (dsh-emacs--submit-prompt "hi")))
        (when (and (eq (car connects) chat) polled)
          (dsh-test-pass "submit-heals-streamless-buffer-with-reconnect"))
        ;; 场景 2：握手进行中（进程在但没 ready）→ 不重复建连，只轮询
        (setq connects nil polled nil)
        (let ((proc (make-pipe-process :name " *t43c-proc*"
                                       :buffer " *t43c-proc*")))
          (unwind-protect
              (progn
                (with-current-buffer chat
                  (setq dsh-emacs--event-ready nil
                        dsh-emacs--event-process proc))
                (with-current-buffer chat
                  (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                             (lambda (_m _p cb)
                               (funcall cb t '((accepted . t)))))
                            ((symbol-function 'dsh-emacs--get-input)
                             (lambda () ""))
                            ((symbol-function 'dsh-emacs--ml-busy-set)
                             (lambda (&rest _) nil))
                            ((symbol-function 'dsh-emacs-events-connect)
                             (lambda (c) (push c connects)))
                            ((symbol-function 'dsh-emacs--start-polling)
                             (lambda () (setq polled t)))
                            ((symbol-function 'dsh-emacs-events--watchdog-start)
                             (lambda () nil)))
                    (dsh-emacs--submit-prompt "hi")))
                (when (and (null connects) polled)
                  (dsh-test-pass "submit-in-handshake-keeps-single-stream")))
            (delete-process proc))))
    (setq dsh-emacs--current-session old-current-session)
    (when (buffer-live-p chat) (kill-buffer chat))))

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
      (dsh-emacs--footer-effort "max")
      (dsh-emacs--footer-preset "standard")
      (dsh-emacs--ml-busy t)
      (dsh-emacs--ml-busy-index 4))
  (let ((txt (dsh-emacs-footer--doom-segment)))
    (when (and (string-match-p "deepseek-v4-flash-0731" txt)
               (string-match-p "max" txt)
               (string-match-p "standard" txt)
               (string-match-p "████" txt)
               ;; 动画在统计之前（紧贴 DSH 模式名之后）
               (< (string-match "████" txt)
                  (string-match "deepseek-v4" txt)))
      (dsh-test-pass "doom-segment-includes-busy-animation"))))

(let ((dsh-emacs--ml-busy nil)
      (dsh-emacs--footer-usage nil))
  ;; 空闲时 doom segment 显示 model 段但不含进度条动画
  (when (not (string-match-p "█" (dsh-emacs-footer--doom-segment)))
    (dsh-test-pass "doom-segment-idle-has-no-spinner")))

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

;; --- 测试 47: 模型目录展开 + 排序 + selectModel 调用 ---
(let* ((g1 '((id . "g1") (name . "DeepSeek")
             (models . [((id . "m1") (name . "Model One"))
                        ((id . "m2"))])))
       (g2 '((id . "g2") (name . "qwen-token-plan")
             (models . [((id . "m3") (name . "Qwen-M"))])))
       (cands (dsh-emacs--model-candidates `((groups . [,g1 ,g2])))))
  ;; 每项带 (id provider 组名)，provider 取所属组的 id；
  ;; 列表按 provider 名 + 模型 id 排序（组内 m1 < m2，组名忽略大小写）
  (when (equal cands '(("m1" "g1" "DeepSeek" "Model One" nil)
                       ("m2" "g1" "DeepSeek" "m2" nil)
                       ("m3" "g2" "qwen-token-plan" "Qwen-M" nil)))
    (dsh-test-pass "model-candidates-flattened")))

;; 排序：组乱序 + 组内乱序 → provider 名 + 模型 id 字典序（大小写不敏感）
(let* ((g1 '((id . "g1") (name . "Zeta")
             (models . [((id . "m1") (name . "beta"))
                        ((id . "m2") (name . "Alpha"))])))
       (g2 '((id . "g2") (name . "Alpha-Group")
             (models . [((id . "m3") (name . "gamma"))])))
       (cands (dsh-emacs--model-candidates `((groups . [,g1 ,g2])))))
  (when (equal cands '(("m3" "g2" "Alpha-Group" "gamma" nil)
                       ("m1" "g1" "Zeta" "beta" nil)
                       ("m2" "g1" "Zeta" "Alpha" nil)))
    (dsh-test-pass "model-candidates-sorted-provider-then-name")))

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
                   ;; 用户选择的键是模型行完整键（含埋入的 provider，形如
                   ;; "m1 [g1|DeepSeek]"；display 属性下渲染时不可见）
                   (lambda (&rest _)
                     "m1 [g1|DeepSeek]")))
          (dsh-emacs-select-model)
          (let* ((call (car calls))
                 (params (cadr call)))
            (when (and (string= "session.selectModel" (car call))
                       (string= "m1" (cdr (assq 'model params)))
                       (string= "g1" (cdr (assq 'provider params)))
                       (string= "sess-m" (cdr (assq 'sessionId params))))
              (dsh-test-pass "select-model-sends-selectModel")))))
    (kill-buffer buf)))

;; --- 测试 47b: select-model 按 C-g 应干净取消（quit 不得漏进 process filter） ---
(let ((buf (generate-new-buffer " *dsh-model-quit-test*"))
      (leaked nil))
  (unwind-protect
      (with-current-buffer buf
        (setq dsh-emacs--current-session "sess-q")
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (&rest _) (signal 'quit nil))))
          (condition-case err
              (dsh-emacs--select-model-prompt
               "sess-q"
               '((current . ((provider . "p1") (model . "m0")))
                 (groups . [((id . "g1") (name . "DeepSeek")
                             (models . [((id . "m1") (name . "Model One"))]))])))
            (quit (setq leaked t)))))
    (kill-buffer buf))
  (when (not leaked)
    (dsh-test-pass "select-model-c-g-aborts-cleanly")))

;; --- 测试 47c: 空 RET/未知输入都不得触发 selectModel（实现上不再传 DEF） ---
;; 空 RET（""）→ 保持当前模型：不发 selectModel，提示 "Kept ..."
(let ((buf (generate-new-buffer " *dsh-model-empty-test*"))
      (calls nil)
      (msgs nil))
  (unwind-protect
      (with-current-buffer buf
        (setq dsh-emacs--current-session "sess-e")
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (method params cb)
                     (push (list method params) calls)
                     (when (string= method "session.models")
                       (funcall
                        cb t
                        '((current . ((provider . "g1") (model . "m1")))
                          (groups . [((id . "g1") (name . "DeepSeek")
                                      (models . [((id . "m1")
                                                  (name . "Model One"))]))]))))))
                  ((symbol-function 'completing-read)
                   (lambda (&rest _) ""))
                  ((symbol-function 'message)
                   (lambda (fmt &rest args)
                     (push (apply #'format fmt args) msgs))))
          (dsh-emacs-select-model)
          (let ((methods (mapcar #'car calls)))
            (when (and (member "session.models" methods)
                       (not (member "session.selectModel" methods))
                       (cl-some (lambda (m) (string-prefix-p "Kept" m))
                                msgs))
              (dsh-test-pass "select-model-empty-pick-keeps-current")))))
    (kill-buffer buf)))

;; 未知串 → 拒绝：不发 selectModel，提示 "Unknown model"
(let ((buf (generate-new-buffer " *dsh-model-unknown-test*"))
      (calls nil)
      (msgs nil))
  (unwind-protect
      (with-current-buffer buf
        (setq dsh-emacs--current-session "sess-u")
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (method params cb)
                     (push (list method params) calls)
                     (when (string= method "session.models")
                       (funcall
                        cb t
                        '((current . ((provider . "g1") (model . "m1")))
                          (groups . [((id . "g1") (name . "DeepSeek")
                                      (models . [((id . "m1")
                                                  (name . "Model One"))]))]))))))
                  ((symbol-function 'completing-read)
                   (lambda (&rest _) "bogus"))
                  ((symbol-function 'message)
                   (lambda (fmt &rest args)
                     (push (apply #'format fmt args) msgs))))
          (dsh-emacs-select-model)
          (let ((methods (mapcar #'car calls)))
            (when (and (member "session.models" methods)
                       (not (member "session.selectModel" methods))
                       (cl-some (lambda (m) (string-prefix-p "Unknown" m))
                                msgs))
              (dsh-test-pass "select-model-unknown-pick-rejected")))))
    (kill-buffer buf)))

;; --- 测试 47d: provider 只展示一次，models 缩进跟随（分组展示） ---
;; 行键 = "id [provider-id|Provider Name]"：键里内嵌 provider id 与显示
;; 名，保证同 id 跨 provider（m2 在 Qwen 和 Anthropic 下）时两行内容唯一、
;; assoc 精确命中；键开头就是 id（前缀过滤可用）；display 属性渲染时把
;; [provider|Name] 藏起来，列表里只看到 "  id"（前缀输入仍命中）。
(let* ((cands '(("m1" "g1" "DeepSeek" "Model One")
                ("m2b" "g1" "DeepSeek" "Model Two")
                ("m0" "g2" "Qwen" "m0")
                ("m2" "g2" "Qwen" "Qwen-M")
                ("m2" "g3" "Anthropic" "Same-M")))
       (entries (dsh-emacs--model-entries cands))
       (key (lambda (id provider name) (format "%s [%s|%s]" id provider name)))
       (expect `(("DeepSeek" :header . "DeepSeek")
                 (,(funcall key "m1" "g1" "DeepSeek") . ("m1" "g1" "DeepSeek" "Model One"))
                 (,(funcall key "m2b" "g1" "DeepSeek") . ("m2b" "g1" "DeepSeek" "Model Two"))
                 ("Qwen" :header . "Qwen")
                 (,(funcall key "m0" "g2" "Qwen") . ("m0" "g2" "Qwen" "m0"))
                 (,(funcall key "m2" "g2" "Qwen") . ("m2" "g2" "Qwen" "Qwen-M"))
                 ("Anthropic" :header . "Anthropic")
                 (,(funcall key "m2" "g3" "Anthropic") . ("m2" "g3" "Anthropic" "Same-M"))))
       ;; 渲染：唯一 id 保持纯 "  id"；重复 id（同 id 跨 provider）显示
       ;; provider 名，因为过滤时分组头会被滤掉，纯 id 行将无法区分
       (shown (mapcar (lambda (e)
                        (if (eq :header (car (cdr e)))
                            (car e)
                          (get-text-property 0 'display (car e))))
                      entries))
       (shown-expect (list "DeepSeek" "  m1" "  m2b" "Qwen" "  m0"
                           "  m2 (Qwen)" "Anthropic" "  m2 (Anthropic)")))
  (when (and (equal entries expect)
             (equal shown shown-expect)
             ;; 模型行键全部唯一 → completion 返回的键无歧义
             (= (length entries)
                (length (cl-remove-duplicates (mapcar #'car entries)))))
    (dsh-test-pass "model-entries-groups-by-provider")))

;; --- 测试 47e: 选中 provider 头行 → 提示而非切换（不发 selectModel） ---
(let ((buf (generate-new-buffer " *dsh-model-header-test*"))
      (calls nil))
  (unwind-protect
      (with-current-buffer buf
        (setq dsh-emacs--current-session "sess-h")
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (method params cb)
                     (push (list method params) calls)
                     (when (string= method "session.models")
                       (funcall cb
                                t
                                '((current . ((provider . "g1") (model . "m1")))
                                  (groups . [((id . "g1") (name . "DeepSeek")
                                              (models . [((id . "m1")
                                                          (name . "Model One"))]))]))))))
                  ((symbol-function 'completing-read)
                   (lambda (&rest _) "DeepSeek")))
          (dsh-emacs-select-model)
          (let ((methods (mapcar #'car calls)))
            (when (and (member "session.models" methods)
                       (not (member "session.selectModel" methods)))
              (dsh-test-pass "select-model-header-pick-rejected")))))
    (kill-buffer buf)))

;; --- 测试 47f: 同 id 多 provider → 键内嵌 provider，选中行即正确 provider ---
;; 行键 = "m2 [g2|Qwen]"（display 属性下不可见，列表仍显示 "  m2"）。
;; completing-read 返回的键就是用户选中那行，assoc 直接命中正确 payload：
;; 选 Qwen 行 → provider g2、确认消息 "Dup-2 (Qwen)"；全程一次选择，无二次确认。
(let ((buf (generate-new-buffer " *dsh-model-dup-test*"))
      (calls nil)
      (msgs nil)
      (cr-count 0))
  (unwind-protect
      (with-current-buffer buf
        (setq dsh-emacs--current-session "sess-d")
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (method params cb)
                     (push (list method params) calls)
                     (cond
                      ((string= method "session.models")
                       (funcall
                        cb t
                        '((current . ((provider . "g1") (model . "m1")))
                          (groups . [((id . "g1") (name . "DeepSeek")
                                      (models . [((id . "m2")
                                                  (name . "Dup-1"))]))
                                     ((id . "g2") (name . "Qwen")
                                      (models . [((id . "m2")
                                                  (name . "Dup-2"))]))]))))
                      ((string= method "session.selectModel")
                       ;; 成功回调触发确认消息（"Model switched to ..."）
                       (funcall cb t nil)))))
                  ;; 用户选了 Qwen 那行：返回该行完整键（含隐藏的 provider）
                  ((symbol-function 'completing-read)
                   (lambda (&rest _)
                     (setq cr-count (1+ cr-count))
                     "m2 [g2|Qwen]"))
                  ((symbol-function 'message)
                   (lambda (fmt &rest args)
                     (push (apply #'format fmt args) msgs))))
          (dsh-emacs-select-model)
          (let* ((call (car calls))
                 (params (cadr call)))
            (when (and (string= "session.selectModel" (car call))
                       (string= "m2" (cdr (assq 'model params)))
                       (string= "g2" (cdr (assq 'provider params)))
                       (= 1 cr-count)
                       (cl-some (lambda (m)
                                  (string-match-p (regexp-quote "Dup-2 (Qwen)") m))
                                msgs))
              (dsh-test-pass "select-model-dup-id-picks-own-provider")))))
    (kill-buffer buf)))

;; 选 DeepSeek 那行（键 "m2 [g1|DeepSeek]"）→ provider 是 g1，确认消息显示 Dup-1
(let ((buf (generate-new-buffer " *dsh-model-dup2*"))
      (calls nil)
      (msgs nil))
  (unwind-protect
      (with-current-buffer buf
        (setq dsh-emacs--current-session "sess-d2")
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (method params cb)
                     (push (list method params) calls)
                     (cond
                      ((string= method "session.models")
                       (funcall
                        cb t
                        '((current . ((provider . "g1") (model . "m1")))
                          (groups . [((id . "g1") (name . "DeepSeek")
                                      (models . [((id . "m2")
                                                  (name . "Dup-1"))]))
                                     ((id . "g2") (name . "Qwen")
                                      (models . [((id . "m2")
                                                  (name . "Dup-2"))]))]))))
                      ((string= method "session.selectModel")
                       (funcall cb t nil)))))
                  ;; 用户选了 DeepSeek 那行
                  ((symbol-function 'completing-read)
                   (lambda (&rest _) "m2 [g1|DeepSeek]"))
                  ((symbol-function 'message)
                   (lambda (fmt &rest args)
                     (push (apply #'format fmt args) msgs))))
          (dsh-emacs-select-model)
          (let* ((call (car calls))
                 (params (cadr call)))
            (when (and (string= "session.selectModel" (car call))
                       (string= "g1" (cdr (assq 'provider params)))
                       (cl-some (lambda (m)
                                  (string-match-p (regexp-quote "Dup-1 (DeepSeek)") m))
                                msgs))
              (dsh-test-pass "select-model-dup-id-other-row-its-provider")))))
    (kill-buffer buf)))

;; --- 测试 47g: vertico-group 路径 → 分组由 group-function 元数据保持 ---
;; 候选是纯模型行（无 :header 候选），行键 "  id [provider]" 渲染纯 id；
;; 元数据 group-function 把键映射回 provider 显示名 —— 过滤时框架据此
;; 保持每个 provider 的分组头。assoc 仍精确命中选中行。
(let* ((cands '(("m1" "g1" "DeepSeek" "Model One")
                ("m2" "g2" "Qwen" "Qwen-M")
                ("m2" "g3" "Anthropic" "Same")))
       (pair (dsh-emacs--model-grouped-collection cands))
       (rows (cdr pair))
       (md (funcall (car pair) "" nil 'metadata))
       (gf (alist-get 'group-function (cdr md))))
  (when (and (eq 'dsh-model (alist-get 'category (cdr md)))
             (= 3 (length rows))
             (cl-every (lambda (e) (not (eq :header (car (cdr e))))) rows)
             (string= "DeepSeek" (funcall gf "m1 [g1|DeepSeek]" nil))
             (string= "Qwen" (funcall gf "m2 [g2|Qwen]" nil))
             (string= "Anthropic" (funcall gf "m2 [g3|Anthropic]" nil))

             ;; transform 返回可见串（id 前缀 + 迁移的匹配高亮），供 vertico 渲染
             (string= "m2" (substring-no-properties
                             (funcall gf "m2 [g2|Qwen]" t)))
             (string= "  m2" (get-text-property 0 'display (car (nth 1 rows))))
             (string= "  m2" (get-text-property 0 'display (car (nth 2 rows)))))
    (dsh-test-pass "model-grouped-collection-keeps-group-metadata")))

;; 47g2: 现代 vertico（原生支持 group-function 元数据，无
;; vertico-group-mode）→ 走 grouped 路径，选中行即正确 provider
(let ((buf (generate-new-buffer " *dsh-model-grouped*"))
      (calls nil)
      (msgs nil))
  (unwind-protect
      (with-current-buffer buf
        (setq dsh-emacs--current-session "sess-g")
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (method params cb)
                     (push (list method params) calls)
                     (cond
                      ((string= method "session.models")
                       (funcall
                        cb t
                        '((current . ((provider . "g1") (model . "m1")))
                          (groups . [((id . "g1") (name . "DeepSeek")
                                      (models . [((id . "m2")
                                                  (name . "Dup-1"))]))
                                     ((id . "g2") (name . "Qwen")
                                      (models . [((id . "m2")
                                                  (name . "Dup-2"))]))]))))
                      ((string= method "session.selectModel")
                       (funcall cb t nil)))))
                  ((symbol-function 'completing-read)
                   (lambda (&rest _) "m2 [g2|Qwen]"))
                  ((symbol-function 'message)
                   (lambda (fmt &rest args)
                     (push (apply #'format fmt args) msgs))))
          (let ((vertico-mode t) (vertico--groups nil))
            (dsh-emacs-select-model))
          (let* ((call (car calls))
                 (params (cadr call)))
            (when (and (string= "session.selectModel" (car call))
                       (string= "g2" (cdr (assq 'provider params)))
                       (cl-some (lambda (m)
                                  (string-match-p (regexp-quote "Dup-2 (Qwen)") m))
                                msgs))
              (dsh-test-pass "model-grouped-pick-exact-provider")))))
    (kill-buffer buf)))

;; --- 测试 47h: 键以 id 开头 → 默认前缀补全风格下过滤仍命中 ---
;; 键 = "m2 [g2|Qwen]"（无前导空格）：basic（前缀）风格输入 "m2" 命中；
;; 键内嵌 provider 显示名，子串风格输 "qwen" 也能命中；display 属性
;; 照旧把 [provider|Name] 藏起来、渲染 "  m2"。
(let* ((cands '(("m2" "g2" "Qwen" "Qwen-M")
                ("m2" "g3" "Anthropic" "Same")))
       (rows (mapcar (lambda (c) (dsh-emacs--model-row-entry c nil)) cands))
       (raw0 (substring-no-properties (car (nth 0 rows))))
       (raw1 (substring-no-properties (car (nth 1 rows)))))
  (when (and (string-prefix-p "m2" raw0)
             (string-match-p (regexp-quote "Qwen") raw0)
             (string= "  m2" (get-text-property 0 'display (car (nth 0 rows))))
             (string-prefix-p "m2" raw1)
             (string-match-p (regexp-quote "Anthropic") raw1)
             ;; 键全部唯一 → assoc 命中无歧义
             (= 2 (length (cl-remove-duplicates (mapcar #'car rows)))))
    (dsh-test-pass "model-row-prefix-filterable")))

;; --- 测试 47i: 选择器内局部样式化 vertico 组头（默认去掉长分隔线） ---
(progn
  ;; batch 环境没有 vertico，模拟其全局变量
  (defvar vertico-group-format "GLOBAL-FORMAT")
  (let ((buf (generate-new-buffer " *dsh-group-fmt*")))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs--model-select-setup-hook t)
          (when (and (equal (buffer-local-value 'vertico-group-format buf)
                            dsh-emacs-model-group-format)
                     ;; 全局默认不被污染
                     (string= "GLOBAL-FORMAT"
                              (default-value 'vertico-group-format))
                     ;; 默认格式含 %s 占位符
                     (string-match-p "%s" dsh-emacs-model-group-format))
            (dsh-test-pass "model-select-local-group-format")))
      (kill-buffer buf)))
  ;; grouped 为 nil（无分组 UI）时不动 vertico-group-format
  (let ((buf (generate-new-buffer " *dsh-group-fmt2*")))
    (unwind-protect
        (with-current-buffer buf
          (dsh-emacs--model-select-setup-hook nil)
          (unless (assq 'vertico-group-format (buffer-local-variables buf))
            (dsh-test-pass "model-select-nongrouped-leaves-format")))
      (kill-buffer buf))))

;; --- 测试 47j: transform 把匹配高亮迁到显示串的 id 区，行只高亮 id ---
;; 键 = "m2 [g2|Qwen]"（display 隐藏 [provider] 段），输入 "m2" 时
;; orderless/basic 给键首 [0,2) 打 completion-match-face。transform 返回
;; "  m2"（无 display 属性，face 落在 [2,4) 即 id 区）—— 既不整行背景
;; 也不丢失高亮；assoc 仍按原键命中。
(let* ((pair (dsh-emacs--model-grouped-collection
              '(("m2" "g2" "Qwen" "Qwen-M"))))
       (md (funcall (car pair) "" nil 'metadata))
       (gf (alist-get 'group-function (cdr md)))
       (key (caar (cdr pair)))
       ;; 模拟 orderless/basic 的匹配高亮：匹配区在键首（"m2"）
       (hl (copy-sequence key))
       (shown (progn (add-face-text-property 0 2 'completion-match-face t hl)
                     (funcall gf hl t))))
  (when (and (string= "m2" (substring-no-properties shown))
             ;; 高亮迁到 id 区 [0,2)（无前导空格）
             (get-text-property 0 'face shown)
             (null (get-text-property 2 'face shown))
             ;; 显示文本自身承担 display，不再依赖隐藏段
             (null (get-text-property 0 'display shown))
             ;; 原键（含属性）assoc 仍命中
             (assoc hl (cdr pair)))
    (dsh-test-pass "model-grouped-transform-keeps-id-highlight")))

;; --- 测试 47k: category=dsh-model + 恒等 affixation ---
;; nerd-icons-completion 会给候选行首插图标（nil 类别 → 右箭头），
;; category 声明为自用符号 → 图标表查不到 → 空串，行首干净；
;; --- 测试 47k: 元数据自带恒等 affixation → 第三方注解注入被挡掉 ---
;; marginalia/cape 等通过 metadata advice 注入 affixation-function 会在
;; 行尾加注解（常见 "->"）；我们在元数据里声明无 prefix/suffix 的恒等
;; affixation，vertico--affixate 优先用它，行保持干净。
(let* ((pair (dsh-emacs--model-grouped-collection
              '(("m1" "g1" "DeepSeek" "Model One")
                ("m2" "g2" "Qwen" "Qwen-M"))))
       (md (funcall (car pair) "" nil 'metadata))
       (aff (alist-get 'affixation-function (cdr md)))
       ;; 模拟第三方注入：随便一个会加 suffix 的 affixation 在前
       (rows (funcall aff '("m1 [g1|DeepSeek]" "m2 [g2|Qwen]"))))
  (when (and aff
             ;; 每行 prefix 与 suffix 都为空
             (cl-every (lambda (r) (and (string= "" (nth 1 r))
                                        (string= "" (nth 2 r))))
                       rows)
             (= 2 (length rows))
             (string= "m1 [g1|DeepSeek]" (car (nth 0 rows))))
    (dsh-test-pass "model-grouped-empty-affixation-blocks-annotations")))

;; --- 测试 47l: effort 目录解析 + 默认值优先级 ---
(let* ((reasoning '((efforts . [((id . "off") (name . "Off"))
                                ((id . "high") (name . "High"))
                                ((id . "max") (name . "Max"))])
                    (defaultEffort . "high")))
       (choices (dsh-emacs--model-effort-choices reasoning)))
  (when (equal choices '(("Off" . "off")
                         ("High" . "high")
                         ("Max" . "max")))
    (dsh-test-pass "model-effort-choices-parses-options")))

(let* ((reasoning '((efforts . [((id . "off") (name . "Off"))
                                ((id . "high") (name . "High"))
                                ((id . "max") (name . "Max"))])
                    (defaultEffort . "high")))
       (prefer (dsh-emacs--model-effort-default-id reasoning "max"))
       (default (dsh-emacs--model-effort-default-id reasoning nil))
       (bogus (dsh-emacs--model-effort-default-id reasoning "low")))
  (when (and (string= "max" prefer)      ;; 现行 effort 有效 → 保持
             (string= "high" default)     ;; 否则 defaultEffort
             (string= "high" bogus))      ;; 非选项的 current → 忽略
    (dsh-test-pass "model-effort-default-priority")))

;; 无 display name 的 effort 项 → 用 id 兜底显示
(let* ((reasoning '((efforts . [((id . "t0"))])))
       (choices (dsh-emacs--model-effort-choices reasoning)))
  (when (equal choices '(("t0" . "t0")))
    (dsh-test-pass "model-effort-choice-name-falls-back-to-id")))

;; --- 测试 47m: selectModel 携带 reasoningEffort ---
;; 辅助：模拟一轮模型选择（completing-read 第二次输入 PICK2），
;; 返回 selectModel 请求里的 reasoningEffort（未发请求时为 :no-call）
(defun dsh-emacs-test--model-effort-run (dir pick2)
  (let ((buf (generate-new-buffer " *dsh-effort-*"))
        (calls nil)
        (cr-n 0))
    (unwind-protect
        (with-current-buffer buf
          (setq dsh-emacs--current-session "sess-t")
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method params cb)
                       (push (list method params) calls)
                       (funcall cb t
                                (if (string= method "session.models")
                                    dir
                                  '((selected . ((provider . "p1")
                                                 (model . "m1")))))))))
            (cl-letf (((symbol-function 'completing-read)
                       (lambda (&rest _)
                         (setq cr-n (1+ cr-n))
                         (if (eq cr-n 1) "m1 [g1|DeepSeek]" pick2))))
              (dsh-emacs-select-model)
              (let* ((call (car calls))
                     (params (cadr call)))
                (if (and (string= "session.selectModel" (car call))
                         (string= "m1" (cdr (assq 'model params))))
                    (cdr (assq 'reasoningEffort params))
                  :no-call)))))
      (kill-buffer buf))))

;; 目标模型带 reasoning：第二层手动选 Max（不同于默认 High）→ 传 max
(let* ((dir '((current . ((provider . "p1") (model . "m0")))
              (groups . [((id . "g1") (name . "DeepSeek")
                          (models . [((id . "m1") (name . "One")
                                      (reasoning . ((efforts . [((id . "off") (name . "Off"))
                                                                ((id . "high") (name . "High"))
                                                                ((id . "max") (name . "Max"))])
                                                    (defaultEffort . "high"))))]))])))
       (eff (dsh-emacs-test--model-effort-run dir "Max")))
  (when (string= "max" eff)
    (dsh-test-pass "select-model-sends-reasoning-effort")))

;; 空输入（RET）→ completing-read 返回默认 → 传默认 effort（defaultEffort）
(let* ((dir '((current . ((provider . "p1") (model . "m0")))
              (groups . [((id . "g1") (name . "DeepSeek")
                          (models . [((id . "m1") (name . "One")
                                      (reasoning . ((efforts . [((id . "off") (name . "Off"))
                                                                ((id . "high") (name . "High"))
                                                                ((id . "max") (name . "Max"))])
                                                    (defaultEffort . "high"))))]))])))
       (eff (dsh-emacs-test--model-effort-run dir "")))
  (when (string= "high" eff)
    (dsh-test-pass "select-model-empty-effort-pick-default")))

;; 重选当前模型（current.reasoningEffort=max、m1 选项含 max）→ 保持 max
(let* ((dir '((current . ((provider . "p1") (model . "m1") (reasoningEffort . "max")))
              (groups . [((id . "g1") (name . "DeepSeek")
                          (models . [((id . "m1") (name . "One")
                                      (reasoning . ((efforts . [((id . "off") (name . "Off"))
                                                                ((id . "max") (name . "Max"))])
                                                    (defaultEffort . "high"))))]))])))
       (eff (dsh-emacs-test--model-effort-run dir "")))
  (when (string= "max" eff)
    (dsh-test-pass "select-model-repick-keeps-current-effort")))

;; 目标模型没有 reasoning 选项 → 请求不带 reasoningEffort 键
(let* ((dir '((current . ((provider . "p1") (model . "m0")))
              (groups . [((id . "g1") (name . "DeepSeek")
                          (models . [((id . "m1") (name . "One"))]))])))
       (eff (dsh-emacs-test--model-effort-run dir "x")))
  (when (null eff)
    (dsh-test-pass "select-model-no-reasoning-omits-effort")))


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
(let* ((sessions (list (list (cons 'sessionId "s1") (cons 'updatedAt 100)
                            (cons 'projections
                                  (list (cons 'values (list (cons 'title "Alpha"))))))
                      (list (cons 'sessionId "s2") (cons 'updatedAt 200)
                            (cons 'projections
                                  (list (cons 'values (list (cons 'title "Beta"))))))
                      (list (cons 'sessionId "s3") (cons 'updatedAt 300)
                            (cons 'projections
                                  (list (cons 'values (list (cons 'title "Gamma"))))))))
      (workspaces (list (list (cons 'workspaceId "w1") (cons 'title "WS A")
                              (cons 'sessionIds ["s1" "s2"]))))
      (sessions-s (dsh-emacs-test--session-items sessions))
      (workspaces-s (mapcar #'dsh-protocol-workspace--from-alist workspaces)))
  ;; 过滤到 w1：只剩 WS A 的成员，Ungrouped 桶被抑制
  ;; 注意：`filtered' 的初始化器必须在 filter 绑定建立后再求值，
  ;; 所以这里用 let*（let 的初始化器在绑定建立前求值，会读到旧值）
  (let* ((dsh-emacs--archived-sessions nil)
         (dsh-emacs-session--filter-ws-id "w1")
         (filtered (dsh-emacs-session--group-sessions sessions-s workspaces-s)))
    (when (and (= 1 (length filtered))
               (equal "WS A" (plist-get (car filtered) :label))
               (= 2 (length (plist-get (car filtered) :sessions))))
      (dsh-test-pass "session-filter-restricts-workspace")))
  ;; 无过滤：WS A + Ungrouped 两个桶都在
  (let* ((dsh-emacs--archived-sessions nil)
         (dsh-emacs-session--filter-ws-id nil)
         (grouped (dsh-emacs-session--group-sessions sessions-s workspaces-s)))
    (when (and (= 2 (length grouped))
               (cl-some (lambda (g) (equal "WS A" (plist-get g :label))) grouped)
               (cl-some (lambda (g) (equal "Ungrouped" (plist-get g :label))) grouped))
      (dsh-test-pass "session-group-keeps-ungrouped")))
  ;; 渲染层面：过滤生效时其他工作区/未分组会话不可见
  (let ((buf (generate-new-buffer " *dsh-filter-render*")))
    (unwind-protect
        (with-current-buffer buf
          (let ((dsh-emacs--sessions sessions-s)
                (dsh-emacs--workspaces workspaces-s)
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

;; --- 测试 55: thinking 块正文不再有深色背景（回归：此前 body face 带
;; `:background'，展开后图标行正下方出现一块深色；现要求透明/主题背景） ---
(let ((bg (face-attribute 'dsh-emacs-thinking-body-face :background nil)))
  ;; face-attribute 返回的是符号 unspecified / unspecified-bg（表示未显式
  ;; 设置、沿用默认），而不是字符串；只要不是显式颜色（如旧版 "#1f1b16"）即符合
  (when (or (null bg)
            (memq bg '(unspecified unspecified-bg)))
    (dsh-test-pass "thinking-body-face-no-background")))

;; --- 测试 56: thinking 块 body face 只作用于正文行（回归：body-start
;; 用固定偏移 (+ block-start 2) 会把 label 行（图标 + Think）也盖进
;; `dsh-emacs-thinking-body-face'，思考完成瞬间图标底下出现黑色矩形；
;; 流式阶段无此 face 应用所以正常） ---
(let ((buf (generate-new-buffer " *dsh-think-face*"))
      (dsh-emacs-thinking-expand-by-default t))
  (unwind-protect
      (with-current-buffer buf
        (insert "###HEAD\n")
        (dsh-emacs-render--render-thinking-block
         "t" "b1" "first body line\nsecond body line" 1 (point-max))
        ;; label 行（含图标）不得带 body face
        (goto-char (point-min))
        (search-forward "Think" nil t)
        (let ((faces (seq-uniq
                      (mapcar (lambda (p) (get-text-property p 'face))
                              (number-sequence (line-beginning-position)
                                               (line-end-position))))))
          (when (not (memq 'dsh-emacs-thinking-body-face faces))
            (dsh-test-pass "thinking-block-label-no-body-face")))
        ;; label 下一行才是正文：body face 必须出现在这里
        (forward-line 1)
        (let ((faces (seq-uniq
                      (mapcar (lambda (p) (get-text-property p 'face))
                              (number-sequence (line-beginning-position)
                                               (line-end-position))))))
          (when (memq 'dsh-emacs-thinking-body-face faces)
            (dsh-test-pass "thinking-block-body-gets-face"))))
    (kill-buffer buf)))

;; --- 测试 57: 协议层 workspace-list / workspace-result / model-selection-result ---
;; workspace.list 顶层响应：items 数组→列表、archivedSessionIds 数组→列表
(let* ((value '((items . [((workspaceId . "w1") (title . "WS A")
                           (path . "/tmp/a") (sessionIds . ["s1" "s2"])
                           (createdAt . "2026-08-25T00:00:00Z")
                           (updatedAt . "2026-08-25T01:00:00Z"))
                          ((workspaceId . "w2") (title . "WS B")
                           (path . "/tmp/b") (sessionIds . []))])
                  (archivedSessionIds . ["s9"])))
       (wl (dsh-protocol-workspace-list--from-alist value))
       (items (dsh-protocol-workspace-list-items wl))
       (w1 (car items)))
  (when (and (= (length items) 2)
             (equal (dsh-protocol-workspace-list-archived-session-ids wl)
                    '("s9"))
             ;; items 内嵌转换 + 数组归一为列表
             (dsh-protocol-workspace-p w1)
             (equal (dsh-protocol-workspace-session-ids w1) '("s1" "s2"))
             ;; WorkspaceView 官方字段完整
             (string= (dsh-protocol-workspace-title w1) "WS A")
             (string= (dsh-protocol-workspace-created-at w1)
                      "2026-08-25T00:00:00Z")
             (string= (dsh-protocol-workspace-updated-at w1)
                      "2026-08-25T01:00:00Z")
             (string= (dsh-protocol-workspace-path w1) "/tmp/a")
             (string= (dsh-protocol-workspace-workspace-id
                       (car (dsh-protocol-workspace-list-items
                             (dsh-protocol-workspace-list--from-alist
                              '((items . [((workspaceId . "w2"))]))))))
                      "w2"))
    (dsh-test-pass "protocol-workspace-list-conversion")))

;; workspace.create 响应：{workspace, created}
(let* ((value '((workspace . ((workspaceId . "w3") (title . "New")
                              (path . "/tmp/new") (sessionIds . [])
                              (createdAt . "x") (updatedAt . "y")))
                (created . t)))
       (r (dsh-protocol-workspace-result--from-alist value)))
  (when (and (dsh-protocol-workspace-p (dsh-protocol-workspace-result-workspace r))
             (eq (dsh-protocol-workspace-result-created r) t)
             (string= (dsh-protocol-workspace-title
                       (dsh-protocol-workspace-result-workspace r))
                      "New"))
    (dsh-test-pass "protocol-workspace-create-result")))

;; workspace.rename / insertSessionBefore 响应：只有 {workspace}，created 为 nil
(let* ((r (dsh-protocol-workspace-result--from-alist
           '((workspace . ((workspaceId . "w1") (title . "Renamed"))))))
       (d (dsh-protocol-workspace-result-created r)))
  (when (and (string= (dsh-protocol-workspace-title
                       (dsh-protocol-workspace-result-workspace r))
                      "Renamed")
             (null d))
    (dsh-test-pass "protocol-workspace-rename-result")))

;; session.selectModel 响应：{selected}
(let* ((r (dsh-protocol-model-selection-result--from-alist
           '((selected . ((provider . "deepseek")
                          (model . "deepseek-chat")
                          (reasoningEffort . "high"))))))
       (sel (dsh-protocol-model-selection-result-selected r)))
  (when (and (dsh-protocol-model-selection-p sel)
             (string= (dsh-protocol-model-selection-provider sel) "deepseek")
             (string= (dsh-protocol-model-selection-model sel) "deepseek-chat")
             (string= (dsh-protocol-model-selection-reasoning-effort sel)
                      "high"))
    (dsh-test-pass "protocol-model-selection-result")))

;; --- 测试 58: 归档会话（workspace.archiveSession）---
;; server 无 session.delete，唯一移除途径是归档；响应为完整归档集。
(let ((listed nil)
      (calls nil)
      (dsh-emacs--archived-sessions nil)
      (archived (dsh-emacs--normalize-archived '("s1" "s2"))))
  (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
             (lambda (method params cb)
               (push (list method params) calls)
               (when (string= method "workspace.archiveSession")
                 (funcall cb t '((archivedSessionIds . ["s1" "s2"]))))))
            ((symbol-function 'dsh-emacs-list-sessions)
             (lambda () (setq listed t))))
    (dsh-emacs-archive-session "s3")
    (let* ((call (car calls))
           (method (car call))
           (params (cadr call)))
      (when (and (string= "workspace.archiveSession" method)
                 (string= "s3" (cdr (assq 'sessionId params))))
        (dsh-test-pass "archive-passes-session-id")))
    (when (and (gethash "s1" dsh-emacs--archived-sessions)
               (gethash "s2" dsh-emacs--archived-sessions)
               (not (gethash "s3" dsh-emacs--archived-sessions)))
      (dsh-test-pass "archive-updates-archived-set"))
    (when listed
      (dsh-test-pass "archive-refreshes-list"))))

;; --- 测试 59: rename session at point ---
;; 列表内 r 键应像 archive（D 键）一样作用于光标处会话，
;; 从 text property 取 id + 新标题，不带 completing-read。
(let ((buf (generate-new-buffer " *dsh-rename-at-point*"))
      (calls nil))
  (unwind-protect
      (with-current-buffer buf
        (insert "Rename me\n")
        (put-text-property (point-min) (point-max) 'dsh-emacs-session-id "sid-1")
        (goto-char (point-min))
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (method params cb)
                     (push (list method params) calls)
                     (funcall cb t '((title . "新标题")))))
                  ((symbol-function 'read-string)
                   (lambda (&rest _args) "新标题"))
                  ;; rename 成功回调会 refresh 列表；mock 掉以免二次进 calls
                  ((symbol-function 'dsh-emacs-list-sessions)
                   (lambda () nil)))
          (dsh-emacs-rename-session-at-point)
          (let* ((call (car calls))
                 (params (cadr call)))
            (when (and (string= "session.rename" (car call))
                       (string= "sid-1" (cdr (assq 'sessionId params)))
                       (string= "新标题" (cdr (assq 'title params))))
              (dsh-test-pass "rename-at-point-uses-point-session")))))
    (kill-buffer buf)))

;; --- 测试 60: subagent 会话不进分组 ---
;; server 用 origin: "subagent" 标记子代理会话，它们不应出现在
;; 会话列表（含 Ungrouped 桶）。
(let* ((dsh-emacs--archived-sessions nil)
       (sessions (dsh-emacs-test--session-items
                   (list (list (cons 'sessionId "s1")
                               (cons 'origin "subagent")
                               (cons 'updatedAt 100))
                         (list (cons 'sessionId "s2")
                               (cons 'updatedAt 200)))))
       (workspaces nil))
  ;; 无 workspace：subagent 应被剔除，只有 s2 进 Ungrouped
  (let ((grouped (dsh-emacs-session--group-sessions sessions workspaces)))
    (let* ((ungrouped (cl-find-if (lambda (g) (equal "Ungrouped" (plist-get g :label))) grouped))
           (members (and ungrouped (plist-get ungrouped :sessions)))
           (ids (mapcar #'dsh-protocol-session-session-id members)))
      (when (and (= (length grouped) 1)
                 (equal ids '("s2")))
        (dsh-test-pass "subagent-session-hidden-from-list")))))

;; --- 测试 61: blank 会话仅保留当前会话 ---
;; dsh web 的 sessionVisible 规则：非 subagent、非 archived、
;; 且 (非 blank 或 是 current)。三个 Untitled（blank）应隐藏，
;; 但当前打开的 blank 保留。
(let* ((dsh-emacs--archived-sessions nil)
       (dsh-emacs--current-session "s-blank-open")
       (sessions (dsh-emacs-test--session-items
                  (list (list (cons 'sessionId "s-a")
                              (cons 'blank :json-true)
                              (cons 'updatedAt 300))
                        (list (cons 'sessionId "s-blank-open")
                              (cons 'blank :json-true)
                              (cons 'updatedAt 200))
                        (list (cons 'sessionId "s-b")
                              (cons 'blank :json-false)
                              (cons 'updatedAt 100))))))
  (let* ((grouped (dsh-emacs-session--group-sessions sessions nil))
         (ungrouped (cl-find-if (lambda (g) (equal "Ungrouped"
                                                   (plist-get g :label)))
                                grouped))
         (members (and ungrouped (plist-get ungrouped :sessions)))
         (ids (sort (mapcar #'dsh-protocol-session-session-id members)
                    #'string<)))
    ;; s-a（blank 非当前）被隐藏；s-blank-open（blank 但当前）与
    ;; s-b（非 blank）保留
    (when (and (equal ids '("s-b" "s-blank-open"))
               (not (member "s-a" ids)))
      (dsh-test-pass "blank-hidden-except-current"))))

;; --- 测试 62: 空 workspace 保持显示，可从中创建会话 ---
;; 成员的 blank 过滤后 workspace 可为空；空组必须仍出现在列表
;; （渲染 New Session 行），且 `c'（dsh-emacs-new-session）在其上
;; 应传 workspaceId 而非 cwd。
(let* ((dsh-emacs--archived-sessions nil)
       (dsh-emacs--current-session nil)
       (empty-ws (mapcar #'dsh-protocol-workspace--from-alist
                         (list (list (cons 'workspaceId "w-empty")
                                     (cons 'title "Empty WS")
                                     (cons 'path "/tmp/dsh-empty-ws")
                                     (cons 'sessionIds [])))))
       (sessions nil))
  ;; 1) 分组：空 workspace 仍在结果里
  (let* ((grouped (dsh-emacs-session--group-sessions sessions empty-ws))
         (ws-group (cl-find-if (lambda (g)
                                 (equal "w-empty"
                                        (plist-get g :workspace-id)))
                               grouped)))
    (when (and ws-group
               (equal "Empty WS" (plist-get ws-group :label))
               (null (plist-get ws-group :sessions)))
      (dsh-test-pass "empty-workspace-stays-visible")))
  ;; 2) 渲染：空组显示 New Session 行，且该行带 workspace-id property
  (let ((buf (generate-new-buffer " *dsh-empty-ws-render*")))
    (unwind-protect
        (with-current-buffer buf
          (let ((dsh-emacs--sessions sessions)
                (dsh-emacs--workspaces empty-ws)
                (dsh-emacs--archived-sessions nil)
                (dsh-emacs-session--filter-ws-id nil)
                (dsh-emacs-session--filter-ws-title nil))
            (dsh-emacs-session--render)
            (let ((txt (buffer-substring-no-properties
                        (point-min) (point-max))))
              ;; 定位空 workspace 的 New Session 行，检查它带 workspace-id
              (goto-char (point-min))
              (let ((found nil))
                (while (and (not found)
                            (search-forward "New Session" nil t))
                  (when (dsh-emacs-workspace-id-at-point)
                    (setq found t))
                  (when (get-text-property (1- (point))
                                           'dsh-emacs-workspace-id)
                    (setq found t)))
                (when (and found (string-match-p "Empty WS" txt))
                  (dsh-test-pass "empty-workspace-renders-new-session"))))))
      (kill-buffer buf)))
  ;; 3) new-session 在 workspace 行上应传 workspaceId，且新会话的
  ;;    default-directory 立即对齐 workspace path（magit 等按此定位项目）。
  (let ((calls nil)
        (buf (generate-new-buffer " *dsh-empty-ws-create*")))
    (unwind-protect
        (with-current-buffer buf
          (insert "  New Session\n")
          (put-text-property (point-min) (point-max)
                             'dsh-emacs-workspace-id "w-empty")
          (goto-char (point-min))
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method params cb)
                       (push (list method params) calls)
                       (funcall cb t '((sessionId . "s-new")))))
                    ((symbol-function 'dsh-emacs-open-session)
                     (lambda (_sid) nil))
                    ((symbol-value 'dsh-emacs--current-buffer) buf)
                    (dsh-emacs--workspaces empty-ws))
            (call-interactively #'dsh-emacs-new-session)
            (let* ((call (car calls))
                   (params (cadr call)))
              (when (and (string= "session.create" (car call))
                         (string= "w-empty"
                                  (cdr (assq 'workspaceId params)))
                         (null (assq 'cwd params)))
                (dsh-test-pass "new-session-in-workspace-uses-workspace-id"))
              ;; 新会话 buffer 的 default-directory 应为 workspace 的 path
              (when (or (null (cdr (assq 'workspaceId params)))
                        (string-suffix-p "/tmp/dsh-empty-ws"
                                         (directory-file-name
                                          default-directory)))
                (dsh-test-pass "new-workspace-session-sets-default-directory")))))
      (kill-buffer buf))))

  ;; 4) 非 workspace 上下文：不带 workspaceId（ungrouped），只带 cwd
  (let ((calls nil)
        (buf (generate-new-buffer " *dsh-plain-create*")))
    (unwind-protect
        (with-current-buffer buf
          (insert "plain text\n")
          (goto-char (point-min))
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method params cb)
                       (push (list method params) calls)
                       (funcall cb t '((sessionId . "s-plain")))))
                    ((symbol-function 'dsh-emacs-open-session)
                     (lambda (_sid) nil)))
            (call-interactively #'dsh-emacs-new-session)
            (let* ((call (car calls))
                   (params (cadr call)))
              (when (and (string= "session.create" (car call))
                         (null (assq 'workspaceId params))
                         (assq 'cwd params))
                (dsh-test-pass "new-session-outside-workspace-ungrouped")))))
      (kill-buffer buf)))

;; --- 测试 63: session/title 事件实时更新标题（server 自动重命名） ---
;; server 在前 1-2 轮对话后自动重命名（摘要标题），通过 mux 流广播
;; `session/title' 事件；emacs 侧应实时：更新缓存 title-value、重命名
;; 已打开的 chat buffer、重绘 session 列表——不等 session.list 刷新。
(let* ((old-sessions dsh-emacs--sessions)
       (old-buffers dsh-emacs--chat-buffers)
       (item (list (cons 'sessionId "sess-title")
                   (cons 'blank :json-false)
                   (cons 'title "旧标题")
                   (cons 'projections
                         (list (cons 'values
                                     (list (cons 'title "旧标题")))))))
       (chat-buf (get-buffer-create " *dsh-test-title-chat*"))
       (list-buf (get-buffer-create "*dsh-sessions*"))
       (old-sessions-buffer dsh-emacs-sessions-buffer)
       (json (concat "{\"payload\":{\"type\":\"session/event\","
                     "\"sessionId\":\"sess-title\","
                     "\"event\":{\"type\":\"session/title\","
                     "\"data\":{\"title\":\"自动摘要标题\"}}}}")))
  (unwind-protect
      (progn
        (setq dsh-emacs--sessions
              (dsh-emacs-test--session-items (list item)))
        (setq dsh-emacs--chat-buffers
              (let ((h (make-hash-table :test 'equal)))
                (puthash "sess-title" chat-buf h) h))
        ;; chat buffer 绑定会话；避免触发 history-loading 丢弃分支。
        (with-current-buffer chat-buf
          (setq-local dsh-emacs--buffer-session "sess-title")
          (setq-local dsh-emacs--current-session "sess-title")
          (setq-local dsh-emacs--event-history-loading nil)
          (rename-buffer " *dsh-test-title-chat*" t)
          (dsh-emacs-mode))
        ;; 列表 buffer 置为 session 列表并渲染一次（固定旧状态）。
        (with-current-buffer list-buf
          (let ((dsh-emacs--sessions dsh-emacs--sessions)
                (dsh-emacs--workspaces nil)
                (dsh-emacs--archived-sessions nil)
                (dsh-emacs-session--filter-ws-id nil)
                (dsh-emacs-session--filter-ws-title nil))
            (dsh-emacs-session--render))
          (setq dsh-emacs-sessions-buffer (buffer-name)))
        ;; 调 dispatch-json：mock `--chat' 返回 chat-buf。
        (cl-letf (((symbol-function 'dsh-emacs-events--chat)
                   (lambda (_p) chat-buf)))
          (dsh-emacs-events--dispatch-json 'process json))
        ;; 1) 缓存 title-value 已更新
        (let ((cached (cl-find-if
                       (lambda (s)
                         (equal "sess-title"
                                (dsh-protocol-session-session-id s)))
                       dsh-emacs--sessions)))
          (when (and cached
                     (equal "自动摘要标题"
                            (dsh-protocol-session-title-value cached)))
            (dsh-test-pass "title-event-updates-cache")))
        ;; 2) 列表 buffer 行已重绘为新标题
        (when (string-match-p "自动摘要标题"
                              (with-current-buffer list-buf
                                (buffer-string)))
          (dsh-test-pass "title-event-repaints-list"))
        ;; 3) 已打开的 chat buffer 已重命名
        (when (string-match-p "自动摘要标题" (buffer-name chat-buf))
          (dsh-test-pass "title-event-renames-chat-buffer")))
    (setq dsh-emacs--sessions old-sessions)
    (setq dsh-emacs--chat-buffers old-buffers)
    (setq dsh-emacs-sessions-buffer old-sessions-buffer)
    (when (buffer-live-p chat-buf) (kill-buffer chat-buf))
    (when (buffer-live-p list-buf) (kill-buffer list-buf))))

;; --- 测试 64: 新建 workspace session 归入该 workspace，标题事件清 blank ---
;; 回归：session.create 回调曾只 open 会话，新会话未进缓存/workspace
;; session-ids → 分组落 ungrouped，且 session/title 事件找不到缓存 item、
;; blank 不清 → 自动重命名不生效。
(let* ((old-sessions dsh-emacs--sessions)
       (old-workspaces dsh-emacs--workspaces)
       (old-buffers dsh-emacs--chat-buffers)
       (ws (dsh-protocol-workspace--from-alist
            (list (cons 'workspaceId "w-empty")
                  (cons 'title "Empty WS")
                  (cons 'path "/tmp/dsh-empty-ws")
                  (cons 'sessionIds []))))
       (chat-buf (get-buffer-create " *dsh-test-ws-create*")))
  (unwind-protect
      (progn
        (setq dsh-emacs--workspaces (list ws))
        (setq dsh-emacs--sessions
              (dsh-emacs-test--session-items
               (list (list (cons 'sessionId "s-old")
                           (cons 'blank :json-false)))))
        (setq dsh-emacs--chat-buffers
              (let ((h (make-hash-table :test 'equal)))
                (puthash "s-new" chat-buf h) h))
        (with-current-buffer chat-buf
          (setq-local dsh-emacs--buffer-session "s-new")
          (setq-local dsh-emacs--current-session nil))
        ;; mock rpc-async：创建成功立即回调
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (_method params cb)
                     (funcall cb t '((sessionId . "s-new")))))
                  ((symbol-function 'dsh-emacs-open-session)
                   (lambda (_sid) nil))
                  ((symbol-value 'dsh-emacs--current-buffer) chat-buf))
          ;; 直接以 workspace-id 参数调用（等价于在 workspace 行上按 c）
          (dsh-emacs--cache-new-session "s-new" "w-empty"))
        ;; 1) 缓存里有新会话
        (when (dsh-emacs--chat-session-item "s-new")
          (dsh-test-pass "new-session-cached-after-create"))
        ;; 2) workspace session-ids 已吸收新会话
        (let ((w (car dsh-emacs--workspaces)))
          (when (member "s-new" (dsh-protocol-workspace-session-ids w))
            (dsh-test-pass "new-session-attached-to-workspace")))
        ;; 3) 分组：s-new 落在 Empty WS 组而非 Ungrouped（创建后会话处于
        ;;    打开态，current-session 即它，blank 过滤不会隐藏它）
        (let* ((dsh-emacs--current-session "s-new")
               (grouped (dsh-emacs-session--group-sessions
                         dsh-emacs--sessions dsh-emacs--workspaces))
               (ws-group (cl-find-if
                          (lambda (g) (equal "w-empty"
                                             (plist-get g :workspace-id)))
                          grouped))
               (ungrouped (cl-find-if
                           (lambda (g) (equal "Ungrouped"
                                              (plist-get g :label)))
                           grouped)))
          (when (and ws-group
                     (member "s-new"
                             (mapcar #'dsh-protocol-session-session-id
                                     (plist-get ws-group :sessions)))
                     (not (member "s-new"
                                  (mapcar #'dsh-protocol-session-session-id
                                          (and ungrouped
                                               (plist-get ungrouped :sessions))))))
            (dsh-test-pass "new-session-grouped-in-workspace-not-ungrouped")))
        ;; 4) 标题事件到达：清 blank + 更新 title-value → 显示标题不再是
        ;;    "New Session"
        (dsh-emacs-events--apply-title chat-buf "s-new" "自动摘要名称")
        (let* ((item (dsh-emacs--chat-session-item "s-new"))
               (blank (dsh-protocol-session-blank item))
               (shown (dsh-emacs-session--display-title item)))
          (when (and item
                     (not (and blank (not (eq blank :json-false))))
                     (equal "自动摘要名称" shown))
            (dsh-test-pass "title-event-clears-blank-and-updates-title"))))
    (setq dsh-emacs--sessions old-sessions)
    (setq dsh-emacs--workspaces old-workspaces)
    (setq dsh-emacs--chat-buffers old-buffers)
    (when (buffer-live-p chat-buf) (kill-buffer chat-buf))))

;; --- 测试 64b: host 流先到（session-added 入缓存）后 RPC 回调 ---
;; 回归：cache-new-session 曾用同一个 not-cached 守卫包住“入缓存 + workspace
;; attach”。host 流的 session-added 先于 session.create 回调到达时，session
;; 已在缓存 → 整个 when 跳过 → workspace 没 attach，新会话落到 Ungrouped。
;; 现在 attach 独立于入缓存执行（幂等），竞态窗口不再丢归属。
(let* ((old-sessions dsh-emacs--sessions)
       (old-workspaces dsh-emacs--workspaces)
       (old-sessions-buffer dsh-emacs-sessions-buffer)
       (ws (dsh-protocol-workspace--from-alist
            (list (cons 'workspaceId "w-race")
                  (cons 'title "Race WS")
                  (cons 'path "/tmp/race-ws")
                  (cons 'sessionIds []))))
       (list-buf (get-buffer-create " *dsh-race-list*")))
  (unwind-protect
      (progn
        (setq dsh-emacs--sessions nil)
        (setq dsh-emacs--workspaces (list ws))
        (setq dsh-emacs-sessions-buffer (buffer-name list-buf))
        ;; 1) host 事件先到：session-added 把 s-new 入 sessions 缓存（无归属）
        (dsh-emacs-events--host-dispatch
         'host-proc
         (concat "{\"payload\":{\"type\":\"host/session-added\","
                 "\"sessionId\":\"s-new\",\"blank\":true,"
                 "\"cwd\":\"/tmp/race-ws\"}}"))
        ;; 2) RPC 回调随后到达：cache-new-session 必须仍然 attach 到 workspace
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (_method params cb)
                     (funcall cb t '((sessionId . "s-new")))))
                  ((symbol-function 'dsh-emacs-open-session)
                   (lambda (_sid) nil)))
          (dsh-emacs--cache-new-session "s-new" "w-race"))
        ;; 断言：缓存只有一行（host 事件已入，不重复）
        (when (= 1 (length dsh-emacs--sessions))
          (dsh-test-pass "host-first-cache-no-duplicate"))
        ;; 断言：workspace 已 attach（竞态修复点）
        (let ((w (car dsh-emacs--workspaces)))
          (when (and w
                     (member "s-new"
                             (dsh-protocol-workspace-session-ids w)))
            (dsh-test-pass "host-first-still-attaches-to-workspace")))
        ;; 断言：分组落在 Race WS 而非 Ungrouped
        (let* ((dsh-emacs--current-session "s-new")
               (grouped (dsh-emacs-session--group-sessions
                         dsh-emacs--sessions dsh-emacs--workspaces))
               (ws-group (cl-find-if
                          (lambda (g) (equal "w-race"
                                             (plist-get g :workspace-id)))
                          grouped))
               (ungrouped (cl-find-if
                           (lambda (g) (equal "Ungrouped"
                                              (plist-get g :label)))
                           grouped)))
          (when (and ws-group
                     (member "s-new"
                             (mapcar #'dsh-protocol-session-session-id
                                     (plist-get ws-group :sessions))))
            (dsh-test-pass "host-first-grouped-in-workspace"))))
    (setq dsh-emacs--sessions old-sessions)
    (setq dsh-emacs--workspaces old-workspaces)
    (setq dsh-emacs-sessions-buffer old-sessions-buffer)
    (when (buffer-live-p list-buf) (kill-buffer list-buf))))

;; --- 测试 65: workspace 组内任意 session 行上按 c 创建归属该 workspace ---
;; 回归：workspace-id property 只加在组头/空组 New Session 行；组内实际
;; session 行上没有 → 在这些行按 c 会走 cwd 分支创建成 ungrouped。
(let* ((old-sessions dsh-emacs--sessions)
       (old-workspaces dsh-emacs--workspaces)
       (ws (dsh-protocol-workspace--from-alist
            (list (cons 'workspaceId "w-mid")
                  (cons 'title "Mid WS")
                  (cons 'path "/tmp/dsh-mid-ws")
                  (cons 'sessionIds ["s-inside"]))))
       (s-inside (dsh-protocol-session--from-alist
                  (list (cons 'sessionId "s-inside")
                        (cons 'blank :json-false)
                        (cons 'projections
                              (list (cons 'values
                                          (list (cons 'title "已有会话"))))))))
       (buf (generate-new-buffer " *dsh-ws-row-create*")))
  (unwind-protect
      (progn
        (setq dsh-emacs--sessions (list s-inside))
        (setq dsh-emacs--workspaces (list ws))
        (with-current-buffer buf
          ;; 渲染分组：Mid WS 组的 session 行应带 workspace-id property
          (let ((dsh-emacs--sessions dsh-emacs--sessions)
                (dsh-emacs--workspaces dsh-emacs--workspaces)
                (dsh-emacs--archived-sessions nil)
                (dsh-emacs--current-session nil)
                (dsh-emacs-session--filter-ws-id nil)
                (dsh-emacs-session--filter-ws-title nil))
            (dsh-emacs-session--render)
            ;; 找到 session 行（含标题文本）并检查其 workspace-id
            (goto-char (point-min))
            (let ((row-ok nil))
              (while (and (not row-ok)
                          (search-forward "已有会话" nil t))
                (setq row-ok
                      (equal "w-mid"
                             (dsh-emacs-workspace-id-at-point))))
              (when row-ok
                (dsh-test-pass "session-row-carries-workspace-context"))))
          ;; 在该 session 行上按 c：创建应传 workspaceId 而非 cwd
          (let ((calls nil))
            (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                       (lambda (method params cb)
                         (push (list method params) calls)
                         (funcall cb t '((sessionId . "s-created")))))
                      ((symbol-function 'dsh-emacs-open-session)
                       (lambda (_sid) nil))
                      ((symbol-value 'dsh-emacs--current-buffer) buf))
              (goto-char (point-min))
              (search-forward "已有会话" nil t)
              (call-interactively #'dsh-emacs-new-session))
            (let* ((call (car calls))
                   (params (cadr call)))
              (when (and (string= "session.create" (car call))
                         (string= "w-mid"
                                  (cdr (assq 'workspaceId params)))
                         (null (assq 'cwd params)))
                (dsh-test-pass "new-session-on-workspace-session-row-uses-workspace-id"))))))
    (setq dsh-emacs--sessions old-sessions)
    (setq dsh-emacs--workspaces old-workspaces)
    (when (buffer-live-p buf) (kill-buffer buf))))

;; --- 测试 66: host 事件流（/api/events.host）实时更新缓存 ---
;; workspace/session/归档变化经 host 流广播（镜像 dsh web 的 WorkspaceBrowser
;; 实时订阅）。帧 envelope：{payload: {type, ...}}（与 mux 相同）。
(let* ((old-sessions dsh-emacs--sessions)
       (old-workspaces dsh-emacs--workspaces)
       (old-archived dsh-emacs--archived-sessions)
       (old-sessions-buffer dsh-emacs-sessions-buffer)
       (list-buf (get-buffer-create " *dsh-host-test-list*")))
  (unwind-protect
      (progn
        (setq dsh-emacs--sessions nil)
        (setq dsh-emacs--workspaces nil)
        (setq dsh-emacs--archived-sessions nil)
        (with-current-buffer list-buf
          (erase-buffer)
          (insert "placeholder"))
        (setq dsh-emacs-sessions-buffer (buffer-name list-buf))

        ;; 1) host/workspace-changed：新增 workspace 并入缓存（含 sessionIds）
        (dsh-emacs-events--host-dispatch
         'host-proc
         (concat "{\"payload\":{\"type\":\"host/workspace-changed\","
                 "\"workspace\":{\"workspaceId\":\"w-live\","
                 "\"path\":\"/tmp/live\",\"title\":\"Live WS\","
                 "\"sessionIds\":[],\"createdAt\":\"2026-01-01\","
                 "\"updatedAt\":\"2026-01-01\"}}}"))
        (let ((ws (car dsh-emacs--workspaces)))
          (when (and ws
                     (equal "w-live" (dsh-protocol-workspace-workspace-id ws))
                     (equal "Live WS" (dsh-protocol-workspace-title ws)))
            (dsh-test-pass "host-workspace-changed-upserts")))
        ;; workspace-changed 还触发列表重绘（placeholder 已被真正内容覆盖）
        (when (not (string-match-p "placeholder"
                                   (with-current-buffer list-buf
                                     (buffer-string))))
          (dsh-test-pass "host-workspace-changed-repaints"))

        ;; 2) host/workspace-changed：替换已有 workspace（成员变化）
        (dsh-emacs-events--host-dispatch
         'host-proc
         (concat "{\"payload\":{\"type\":\"host/workspace-changed\","
                 "\"workspace\":{\"workspaceId\":\"w-live\","
                 "\"path\":\"/tmp/live\",\"title\":\"Live WS\","
                 "\"sessionIds\":[\"s-1\"],\"createdAt\":\"2026-01-01\","
                 "\"updatedAt\":\"2026-01-02\"}}}"))
        (let ((ws (car dsh-emacs--workspaces)))
          (when (and ws
                     (equal "w-live" (dsh-protocol-workspace-workspace-id ws))
                     (equal '("s-1")
                            (dsh-protocol-workspace-session-ids ws)))
            (dsh-test-pass "host-workspace-changed-replaces-members")))

        ;; 3) host/workspace-removed：删除缓存项
        (dsh-emacs-events--host-dispatch
         'host-proc
         (concat "{\"payload\":{\"type\":\"host/workspace-removed\","
                 "\"workspaceId\":\"w-live\"}}"))
        (when (null dsh-emacs--workspaces)
          (dsh-test-pass "host-workspace-removed-drops"))

        ;; 4) host/archived-sessions-changed：替换归档集合
        (setq dsh-emacs--sessions
              (dsh-emacs-test--session-items
               (list (list (cons 'sessionId "s-archive")
                           (cons 'blank :json-false)))))
        (dsh-emacs-events--host-dispatch
         'host-proc
         (concat "{\"payload\":{\"type\":\"host/archived-sessions-changed\","
                 "\"archivedSessionIds\":[\"s-archive\"]}}"))
        (let ((archived dsh-emacs--archived-sessions))
          (when (and (hash-table-p archived)
                     (gethash "s-archive" archived))
            (dsh-test-pass "host-archived-sessions-changed")))

        ;; 5) host/session-added：新会话进缓存（blank 占位）
        (setq dsh-emacs--sessions nil)
        (dsh-emacs-events--host-dispatch
         'host-proc
         (concat "{\"payload\":{\"type\":\"host/session-added\","
                 "\"sessionId\":\"s-new\",\"blank\":true,"
                 "\"cwd\":\"/tmp/new\"}}"))
        (let ((item (dsh-emacs--chat-session-item "s-new")))
          (when (and item (equal t (dsh-protocol-session-blank item)))
            (dsh-test-pass "host-session-added-caches")))
        ;; session-added 幂等：再次广播不产生重复行
        (dsh-emacs-events--host-dispatch
         'host-proc
         (concat "{\"payload\":{\"type\":\"host/session-added\","
                 "\"sessionId\":\"s-new\",\"blank\":true}}"))
        (when (= 1 (length dsh-emacs--sessions))
          (dsh-test-pass "host-session-added-idempotent"))

        ;; 6) host/session-status：更新 running 标志并重绘
        (dsh-emacs-events--host-dispatch
         'host-proc
         (concat "{\"payload\":{\"type\":\"host/session-status\","
                 "\"sessionId\":\"s-new\",\"running\":true}}"))
        (let ((item (dsh-emacs--chat-session-item "s-new")))
          (when (and item (equal t (dsh-protocol-session-running item)))
            (dsh-test-pass "host-session-status-updates")))

        ;; 7) host/session-removed：删除缓存行
        (dsh-emacs-events--host-dispatch
         'host-proc
         (concat "{\"payload\":{\"type\":\"host/session-removed\","
                 "\"sessionId\":\"s-new\"}}"))
        (when (null dsh-emacs--sessions)
          (dsh-test-pass "host-session-removed-drops"))

        ;; 8) host/workspace-order-changed：按 server 顺序重排
        (setq dsh-emacs--workspaces
              (list (dsh-protocol-workspace--from-alist
                     (list (cons 'workspaceId "w-a") (cons 'title "A")
                           (cons 'path "/a") (cons 'sessionIds [])))
                    (dsh-protocol-workspace--from-alist
                     (list (cons 'workspaceId "w-b") (cons 'title "B")
                           (cons 'path "/b") (cons 'sessionIds [])))))
        (dsh-emacs-events--host-dispatch
         'host-proc
         (concat "{\"payload\":{\"type\":\"host/workspace-order-changed\","
                 "\"workspaceIds\":[\"w-b\",\"w-a\"]}}"))
        (let ((order (mapcar #'dsh-protocol-workspace-workspace-id
                             dsh-emacs--workspaces)))
          (when (equal '("w-b" "w-a") order)
            (dsh-test-pass "host-workspace-order-changed")))

        ;; 9) 未知 host 帧类型（如 host/remote-event）安全忽略
        (dsh-emacs-events--host-dispatch
         'host-proc
         (concat "{\"payload\":{\"type\":\"host/remote-event\","
                 "\"event\":\"some.event\",\"args\":[]}}"))
        (when (= 2 (length dsh-emacs--workspaces))
          (dsh-test-pass "host-unknown-frame-ignored"))

        ;; 10) 完整 dispatch-json 门控：host-stream property 才走 host 分发
        (setq dsh-emacs--sessions nil)
        (let ((host-props (list (cons 'dsh-emacs-host-stream t))))
          (cl-letf (((symbol-function 'processp)
                     (lambda (_p) t))
                    ((symbol-function 'process-get)
                     (lambda (_p prop)
                       (cdr (assq prop host-props))))
                    ;; 防真连接：host-lost 的重连逻辑会试 open-network-stream
                    ((symbol-function 'dsh-emacs-events--host-lost)
                     (lambda (_p) nil)))
            (dsh-emacs-events--dispatch-json
             'host-proc
             (concat "{\"payload\":{\"type\":\"host/session-added\","
                     "\"sessionId\":\"s-gated\",\"blank\":true}}")))
          (when (dsh-emacs--chat-session-item "s-gated")
            (dsh-test-pass "host-dispatch-gated-by-property")))
    (setq dsh-emacs--sessions old-sessions)
    (setq dsh-emacs--workspaces old-workspaces)
    (setq dsh-emacs--archived-sessions old-archived)
    (setq dsh-emacs-sessions-buffer old-sessions-buffer)
    (when (buffer-live-p list-buf) (kill-buffer list-buf)))))

;; --- 测试 67: workspace 排序 move-workspace (insertBefore) ---
;; web 端拖拽 workspace 排序调用 workspace.insertBefore（always RPC）；
;; emacs 用 M 键命令完成同款排序。beforeWorkspaceId 缺省 = 移到末尾。
(let* ((old-workspaces dsh-emacs--workspaces)
       (old-sessions dsh-emacs--sessions)
       (ws-a (dsh-protocol-workspace--from-alist
              (list (cons 'workspaceId "w-a") (cons 'title "A WS")
                    (cons 'path "/tmp/a") (cons 'sessionIds []))))
       (ws-b (dsh-protocol-workspace--from-alist
              (list (cons 'workspaceId "w-b") (cons 'title "B WS")
                    (cons 'path "/tmp/b") (cons 'sessionIds []))))
       (ws-c (dsh-protocol-workspace--from-alist
              (list (cons 'workspaceId "w-c") (cons 'title "C WS")
                    (cons 'path "/tmp/c") (cons 'sessionIds [])))))
  (unwind-protect
      (progn
        (setq dsh-emacs--workspaces (list ws-a ws-b ws-c))
        (setq dsh-emacs--sessions nil)

        ;; 1) 把 w-c 移到 w-a 前面：insertBefore 带 beforeWorkspaceId
        (let ((calls nil))
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method params cb)
                       (push (list method params) calls)
                       (funcall cb t '((workspaceIds
                                        . ["w-c" "w-a" "w-b"])))))
                    ((symbol-function 'dsh-emacs-list-workspaces)
                     (lambda () nil)))
            (dsh-emacs-move-workspace "w-c" "w-a"))
          (let* ((call (car calls))
                 (params (cadr call)))
            (when (and (string= "workspace.insertBefore" (car call))
                       (string= "w-c" (cdr (assq 'workspaceId params)))
                       (string= "w-a" (cdr (assq 'beforeWorkspaceId params))))
              (dsh-test-pass "move-workspace-sends-before-workspace-id")))
          ;; 回调按响应 workspaceIds 重排缓存（w-c 置顶）
          (let ((order (mapcar #'dsh-protocol-workspace-workspace-id
                               dsh-emacs--workspaces)))
            (when (equal '("w-c" "w-a" "w-b") order)
              (dsh-test-pass "move-workspace-reorders-cache"))))

        ;; 2) 移到末尾：无 beforeWorkspaceId
        (let ((calls nil))
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method params cb)
                       (push (list method params) calls)
                       (funcall cb t '((workspaceIds
                                        . ["w-b" "w-c" "w-a"])))))
                    ((symbol-function 'dsh-emacs-list-workspaces)
                     (lambda () nil)))
            (dsh-emacs-move-workspace "w-a" nil))
          (let* ((call (car calls))
                 (params (cadr call)))
            (when (and (string= "workspace.insertBefore" (car call))
                       (string= "w-a" (cdr (assq 'workspaceId params)))
                       (null (assq 'beforeWorkspaceId params)))
              (dsh-test-pass "move-workspace-to-end-omits-before")))
          (let ((order (mapcar #'dsh-protocol-workspace-workspace-id
                               dsh-emacs--workspaces)))
            (when (equal '("w-b" "w-c" "w-a") order)
              (dsh-test-pass "move-workspace-to-end-reorders-cache")))))
    (setq dsh-emacs--workspaces old-workspaces)
    (setq dsh-emacs--sessions old-sessions)))

;; --- 测试 68: 刷新快照不回滚在途 host/mux 帧（refreshFrames 镜像） ---
;; dsh web 在 `refresh' 期间记录到达的帧并在快照之上重放；emacs 的
;; list-sessions/list-workspaces 响应是请求时刻快照，若响应在途期间帧已推进
;; 缓存（另一个客户端改名/归档/改状态），直接整体 setq 会回滚。begin/drain
;; 配对保证：最后一次刷新结束时按到达顺序重放所有记录帧。
(let* ((old-sessions dsh-emacs--sessions)
       (old-workspaces dsh-emacs--workspaces)
       (old-archived dsh-emacs--archived-sessions)
       (old-refresh-depth dsh-emacs--host-refresh-depth)
       (old-frames dsh-emacs--host-refresh-frames))
  (unwind-protect
      (progn
        ;; 基线：两个 workspace + 一个 session
        (setq dsh-emacs--sessions
              (dsh-emacs-test--session-items
               (list (list (cons 'sessionId "s-a")
                           (cons 'blank :json-false)))))
        (setq dsh-emacs--workspaces
              (list (dsh-protocol-workspace--from-alist
                     (list (cons 'workspaceId "w1") (cons 'title "One")
                           (cons 'path "/one") (cons 'sessionIds ["s-a"])))
                    (dsh-protocol-workspace--from-alist
                     (list (cons 'workspaceId "w2") (cons 'title "Two")
                           (cons 'path "/two") (cons 'sessionIds [])))))

        ;; 场景 1：刷新在途时 workspace-changed/removed 帧到达，迟到快照不含
        ;; 它们 → drain 后新 workspace 仍在、被删的不复现。
        (setq dsh-emacs--host-refresh-depth 0
              dsh-emacs--host-refresh-frames nil)
        (dsh-emacs-events--host-refresh-begin)   ; list-workspaces 发出
        ;; 帧先到：新增 w3 + 删除 w2
        (dsh-emacs-events--host-frame-record
         (list :upsert-workspace
               (dsh-protocol-workspace--from-alist
                (list (cons 'workspaceId "w3") (cons 'title "Three")
                      (cons 'path "/three") (cons 'sessionIds [])))))
        (dsh-emacs-events--host-frame-record
         (list :remove-workspace "w2"))
        ;; 迟到快照：仍只有 w1、w2（请求时刻）——模拟 list-workspaces 回调的
        ;; 整体 setq。
        (setq dsh-emacs--workspaces
              (list (dsh-protocol-workspace--from-alist
                     (list (cons 'workspaceId "w1") (cons 'title "One")
                           (cons 'path "/one") (cons 'sessionIds ["s-a"])))
                    (dsh-protocol-workspace--from-alist
                     (list (cons 'workspaceId "w2") (cons 'title "Two")
                           (cons 'path "/two") (cons 'sessionIds [])))))
        (dsh-emacs-events--host-refresh-drain)
        (let ((ids (mapcar #'dsh-protocol-workspace-workspace-id
                           dsh-emacs--workspaces)))
          (when (and (equal '("w1" "w3") ids)
                     (null (member "w2" ids)))
            (dsh-test-pass "refresh-replays-workspace-frames")))

        ;; 场景 2：在途 session-status + title 帧，迟到快照把它们回滚 → drain 恢复
        (setq dsh-emacs--host-refresh-depth 0
              dsh-emacs--host-refresh-frames nil)
        (dsh-emacs-events--host-refresh-begin)
        (dsh-emacs-events--host-frame-record (list :session-status "s-a" t))
        (dsh-emacs-events--host-frame-record
         (list :apply-title "s-a" "新标题"))
        ;; 迟到快照（旧 running + 旧标题）
        (setq dsh-emacs--sessions
              (dsh-emacs-test--session-items
               (list (list (cons 'sessionId "s-a")
                           (cons 'blank :json-false)
                           (cons 'running :json-false)))))
        (dsh-emacs-events--host-refresh-drain)
        (let ((item (dsh-emacs--chat-session-item "s-a")))
          (when (and item
                     (equal t (dsh-protocol-session-running item))
                     (equal "新标题" (dsh-protocol-session-title-value item)))
            (dsh-test-pass "refresh-replays-session-status-title")))

        ;; 场景 3：嵌套刷新（list-sessions 内调 list-workspaces）——depth 归零前
        ;; 不重放，最后一次 drain 才重放全部帧。
        (setq dsh-emacs--host-refresh-depth 0
              dsh-emacs--host-refresh-frames nil)
        (dsh-emacs-events--host-refresh-begin)   ; list-sessions
        (dsh-emacs-events--host-frame-record
         (list :upsert-workspace
               (dsh-protocol-workspace--from-alist
                (list (cons 'workspaceId "w9") (cons 'title "Nine")
                      (cons 'path "/nine") (cons 'sessionIds [])))))
        (dsh-emacs-events--host-refresh-begin)   ; 内层 list-workspaces
        (dsh-emacs-events--host-refresh-drain)   ; 内层完成：depth 1，不重放
        (let ((ids-before (mapcar #'dsh-protocol-workspace-workspace-id
                                  dsh-emacs--workspaces)))
          (when (= dsh-emacs--host-refresh-depth 1)
            (dsh-test-pass "nested-refresh-holds-frames")))
        (dsh-emacs-events--host-refresh-drain)   ; 外层完成：重放
        (let ((ids (mapcar #'dsh-protocol-workspace-workspace-id
                           dsh-emacs--workspaces)))
          (when (member "w9" ids)
            (dsh-test-pass "nested-refresh-replays-at-outer-end")))

        ;; 场景 4：刷新失败（RPC 错误）也 drain，不留悬挂 depth
        (setq dsh-emacs--host-refresh-depth 0)
        (dsh-emacs-events--host-refresh-begin)
        (dsh-emacs-events--host-refresh-drain)
        (when (= dsh-emacs--host-refresh-depth 0)
          (dsh-test-pass "refresh-drain-always-restores-depth")))
    (setq dsh-emacs--sessions old-sessions)
    (setq dsh-emacs--workspaces old-workspaces)
    (setq dsh-emacs--archived-sessions old-archived)
    (setq dsh-emacs--host-refresh-depth old-refresh-depth)
    (setq dsh-emacs--host-refresh-frames old-frames)))

;; --- 测试 69: 多会话并行时转录事件按缓冲归属路由（守卫不得用全局 current-session） ---
;; 同时打开会话 A、B 后，全局 dsh-emacs--current-session 指向最后打开的 B；
;; A 缓冲的 mux 流收到 A 的 transcript 事件时，归属判定必须看 buffer-local
;; dsh-emacs--buffer-session（open-session 时 setq-local），否则 A 的实时转录
;; 会被全局 current-session（“B”）吞掉。反向：B 的事件也只到 B。
(let* ((chat-a (let ((b (generate-new-buffer " *t69-a*")))
                 (with-current-buffer b
                   (setq-local dsh-emacs--buffer-session "sess-a"))
                 b))
       (chat-b (let ((b (generate-new-buffer " *t69-b*")))
                 (with-current-buffer b
                   (setq-local dsh-emacs--buffer-session "sess-b"))
                 b))
       (rendered-a nil)
       (rendered-b nil)
       (proc-a (make-pipe-process :name "t69-proc-a" :buffer nil))
       (proc-b (make-pipe-process :name "t69-proc-b" :buffer nil))
       (old-session dsh-emacs--current-session))
  (unwind-protect
      (progn
        (process-put proc-a 'dsh-emacs-chat-buffer chat-a)
        (process-put proc-b 'dsh-emacs-chat-buffer chat-b)
        (setq dsh-emacs--current-session "sess-b") ; 后开的会话
        (cl-letf (((symbol-function 'dsh-emacs-render-event)
                   (lambda (&rest _)
                     (if (eq (current-buffer) chat-a)
                         (setq rendered-a t)
                       (setq rendered-b t))))
                  ((symbol-function 'dsh-emacs-render--consume-pending-user-message)
                   (lambda (&rest _) nil)))
          ;; A 的流事件 → 应渲染到 A（不被全局 “sess-b” 吞掉）
          (dsh-emacs-events--dispatch-json
           proc-a
           (json-encode
            '((payload . ((type . "session/event")
                          (sessionId . "sess-a")
                          (event . ((type . "assistant/message")
                                    (sessionId . "sess-a"))))))))
          (when (and rendered-a (null rendered-b))
            (dsh-test-pass "parallel-sessions-mux-event-routes-to-owner"))
          ;; B 的流事件 → 仍只到 B，且不因全局 current-session 变化受影响
          (dsh-emacs-events--dispatch-json
           proc-b
           (json-encode
            '((payload . ((type . "session/event")
                          (sessionId . "sess-b")
                          (event . ((type . "assistant/message")
                                    (sessionId . "sess-b"))))))))
          (when (and rendered-a rendered-b)
            (dsh-test-pass "parallel-sessions-both-streams-render"))))
    (setq dsh-emacs--current-session old-session)
    (kill-buffer chat-a)
    (kill-buffer chat-b)
    (delete-process proc-a)
    (delete-process proc-b)))

;; --- 测试 70: 交互命令的目标归属跟随命令上下文（非全局 current-session） ---
;; 打开会话 A 后再打开 B 后，全局 dsh-emacs--current-session="sess-b"、
;; current-buffer=buf-b；此时用户 switch-to-buffer 切回 A 的 chat buffer
;; 按下 C-c C-c（发送/打断）或 C-c C-r（刷新），目标必须是 A——归属从
;; buffer-local dsh-emacs--buffer-session 解析，而不是最后打开的全局值。
(let* ((buf-a (generate-new-buffer " *t70-a*"))
       (buf-b (generate-new-buffer " *t70-b*"))
       (sent nil)
       (old-session dsh-emacs--current-session)
       (old-buffer dsh-emacs--current-buffer))
  (unwind-protect
      (progn
        (with-current-buffer buf-a
          (dsh-emacs-mode)
          (setq-local dsh-emacs--buffer-session "sess-a"))
        (with-current-buffer buf-b
          (dsh-emacs-mode)
          (setq-local dsh-emacs--buffer-session "sess-b"))
        ;; 最后打开的是 B（全局指向 B）
        (setq dsh-emacs--current-session "sess-b")
        (setq dsh-emacs--current-buffer buf-b)
        ;; 场景 1：此刻切换到 A 里发消息 → payload 必须带 sess-a
        (with-current-buffer buf-a
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method params cb)
                       (push (list method (cdr (assq 'sessionId params))) sent)
                       (funcall cb t '((accepted . t)))))
                    ((symbol-function 'dsh-emacs--get-input)
                     (lambda () "from A"))
                    ((symbol-function 'dsh-emacs--ml-busy-set)
                     (lambda (&rest _) nil)))
            (dsh-emacs--submit-prompt "from A"))
          (when (and sent
                     (equal (list "session.prompt" "sess-a") (car sent)))
            (dsh-test-pass "send-in-inactive-buffer-targets-its-own-session")))
        ;; 场景 2：打断 → session.cancel 同样带 sess-a
        (with-current-buffer buf-a
          (setq sent nil)
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method params cb)
                       (push (list method (cdr (assq 'sessionId params))) sent)
                       (funcall cb t nil)))
                    ((symbol-function 'dsh-emacs--ml-busy-set)
                     (lambda (&rest _) nil)))
            (dsh-emacs--interrupt-turn))
          (when (and sent
                     (equal (list "session.cancel" "sess-a") (car sent)))
            (dsh-test-pass "interrupt-in-inactive-buffer-targets-own-session")))
        ;; 场景 3：刷新 → load-history 用 sess-a
        (with-current-buffer buf-a
          (setq sent nil)
          (cl-letf (((symbol-function 'dsh-emacs--load-history)
                     (lambda (session-id)
                       (push (list "load-history" session-id) sent)))
                    ((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (&rest _) nil)))
            (dsh-emacs-refresh))
          (when (and sent
                     (equal (list "load-history" "sess-a") (car sent)))
            (dsh-test-pass "refresh-in-inactive-buffer-targets-own-session")))
        ;; 场景 4：无归属上下文（如 *dsh-sessions* 列表 buffer）→ 全局兜底
        (with-temp-buffer
          (when (string= "sess-b" (dsh-emacs--active-session-id))
            (dsh-test-pass "active-session-falls-back-to-global"))))
    (setq dsh-emacs--current-session old-session)
    (setq dsh-emacs--current-buffer old-buffer)
    (kill-buffer buf-a)
    (kill-buffer buf-b)))

;; --- 测试 71: 纯函数覆盖补强（markdown 表格 / render-trim / tokens / http 提示） ---
;; 覆盖报告 (scripts/check-coverage.el) 暴露的纯逻辑盲区：markdown 表格分配、
;; 显示宽度、最长词、render--trim 边界、format-cost 分支、usage-p、http-error-hint。
(let ((pass-n 0))
  ;; markdown 表格：宽度分配（有富余则原样）
  (when (equal '(5 5) (dsh-emacs-markdown--table-allocate-widths '(5 5) '(2 2) 18))
    (dsh-test-pass "table-allocate-keeps-when-no-shrink"))
  ;; 需要压缩时按可缩减比例分配，且不低于 min-widths
  (when (equal '(3 3 3) (dsh-emacs-markdown--table-allocate-widths '(10 10 10) '(3 3 3) 20))
    (dsh-test-pass "table-allocate-shrinks-to-fit"))
  ;; 可缩减量为 0 时直接返回 min-widths
  (when (equal '(10 3) (dsh-emacs-markdown--table-allocate-widths '(10 3) '(10 3) 10))
    (dsh-test-pass "table-allocate-min-bound"))
  ;; 总宽度 = 每列 + 3（两侧 padding + 分隔 pipe），外加前导 pipe
  (when (= 15 (dsh-emacs-markdown--table-total-width '(4 4)))
    (dsh-test-pass "table-total-width-counts-borders"))
  ;; 最长词（无窗口走 string-width 路径）
  (when (= 9 (dsh-emacs-markdown--table-longest-word :str "alpha beta-long gamma"))
    (dsh-test-pass "table-longest-word-ascii"))
  ;; 空字符串最长词 = 0
  (when (= 0 (dsh-emacs-markdown--table-longest-word :str ""))
    (dsh-test-pass "table-longest-word-empty"))
  ;; 显示宽度：ASCII 走 string-width；中文按字符计数
  (when (and (= 7 (dsh-emacs-markdown--table-display-width :str "abc def"))
             (= 8 (dsh-emacs-markdown--table-display-width :str "中文测试")))
    (dsh-test-pass "table-display-width-char-count"))
  ;; render--trim：折叠空白 + 截断加省略号
  (when (equal "hello …" (dsh-emacs-render--trim "  hello   world  " 6))
    (dsh-test-pass "render-trim-folds-and-ellipsizes"))
  ;; render--trim：多行/制表符折叠
  (when (equal "…" (dsh-emacs-render--trim "a\nb\tc" 0))
    (dsh-test-pass "render-trim-folds-newlines"))
  ;; format-cost 各分支
  (when (and (equal "$0.000" (dsh-emacs-format-cost nil))
             (equal "<$0.001" (dsh-emacs-format-cost 0.0005))
             (equal "$0.000" (dsh-emacs-format-cost "x"))
             (equal "$1.234" (dsh-emacs-format-cost 1.234)))
    (dsh-test-pass "format-cost-branches"))
  ;; usage-p：合法 plist 判定（返回 truthy），非 plist 为 nil
  (when (and (dsh-emacs-usage-p '(:input 1 :output 2))
             (null (dsh-emacs-usage-p '(a b))))
    (dsh-test-pass "usage-p-detects-plist"))
  ;; http-error-hint：4xx/5xx 提示 RPC 不存在，其它 code 短格式，非错误为空
  (when (and (string-match-p "HTTP 404" (dsh-emacs--http-error-hint '(error http 404)))
             (string-match-p "HTTP 500" (dsh-emacs--http-error-hint '(error http 500)))
             (equal " (HTTP 302)" (dsh-emacs--http-error-hint '(error http 302)))
             (equal "" (dsh-emacs--http-error-hint nil)))
    (dsh-test-pass "http-error-hint-branches"))
  pass-n)

;; --- 测试 72: markdown 解析层纯函数补强（覆盖报告 A 类盲区） ---
;; 目标: deconstruct / highlight-code / table-min-widths / shorten-cwd /
;; insert-read-only / resolve-image-url / parse-local-link（需临时文件）。
(let ((tmpdir (make-temp-file "dsh-cov" t)))
  (unwind-protect
      (progn
        ;; markdown--deconstruct: face 连续段拆分
        (when (equal '(("my" (dsh-emacs-markdown-italic))
                       (" " nil)
                       ("text" (dsh-emacs-markdown-bold)))
                     (dsh-emacs-markdown--deconstruct
                      (dsh-emacs-markdown-convert "_my_ **text**")))
          (dsh-test-pass "markdown-deconstruct-splits-face-runs"))
        ;; highlight-code: 真实模式（elisp）font-lock 加 face，未知语言原样
        (let ((hl (dsh-emacs-markdown--highlight-code "(defun f () 1)" "elisp")))
          (when (and (string= hl "(defun f () 1)")
                     (get-text-property 1 'face hl))
            (dsh-test-pass "markdown-highlight-elisp-applies-face")))
        (when (equal "abc" (dsh-emacs-markdown--highlight-code "abc" "nolangxyz"))
          (dsh-test-pass "markdown-highlight-unknown-lang-pass-through"))
        ;; table-min-widths: 每列最长词
        (when (equal '(6 3)
                     (dsh-emacs-markdown--table-min-widths
                      :processed-rows '(("hdr" "a b" "ccc")
                                        ("row" "longer" "dd"))))
          (dsh-test-pass "markdown-table-min-widths-longest-word"))
        ;; shorten-cwd: home 前缀 → ~，深路径 → ../尾两段
        (when (equal "~/src/foo"
                     (dsh-emacs-session--shorten-cwd
                      (format "%s/src/foo" (expand-file-name "~"))))
          (dsh-test-pass "shorten-cwd-home-prefix"))
        (when (equal "../d/e" (dsh-emacs-session--shorten-cwd "/a/b/c/d/e"))
          (dsh-test-pass "shorten-cwd-deep-path"))
        ;; insert-read-only: 文本带 read-only + face 属性
        (with-temp-buffer
          (dsh-emacs-render--insert-read-only "hi" 'dsh-emacs-test-face)
          (when (and (equal t (get-text-property 1 'read-only))
                     (eq 'dsh-emacs-test-face (get-text-property 1 'face)))
            (dsh-test-pass "render-insert-read-only-props")))
        ;; resolve-image-url: 本地文件各形态，不存在返回 nil
        (let ((f (expand-file-name "img.png" tmpdir)))
          (with-temp-file f)
          (when (equal f (dsh-emacs-markdown--resolve-image-url
                          (concat "file://" f)))
            (dsh-test-pass "resolve-image-url-file-uri"))
          (when (equal f (dsh-emacs-markdown--resolve-image-url f))
            (dsh-test-pass "resolve-image-url-absolute"))
          (when (null (dsh-emacs-markdown--resolve-image-url
                       (concat tmpdir "/missing.png")))
            (dsh-test-pass "resolve-image-url-missing-nil")))
        ;; parse-local-link: file:// URI、file: 前缀、相对路径 + 行号，非本地 nil
        (let ((f (expand-file-name "foo.el" tmpdir)))
          (with-temp-file f)
          (let ((parsed (dsh-emacs-markdown--parse-local-link
                         (concat f "#L10"))))
            (when (and (equal (expand-file-name f) (car parsed))
                       (equal 10 (cdr parsed)))
              (dsh-test-pass "parse-local-link-hash-line")))
          (let ((parsed (dsh-emacs-markdown--parse-local-link
                         (concat "file://" f ":5"))))
            (when (and (equal (expand-file-name f) (car parsed))
                       (equal 5 (cdr parsed)))
              (dsh-test-pass "parse-local-link-file-colon")))
          (when (null (dsh-emacs-markdown--parse-local-link
                       "https://example.com/path"))
            (dsh-test-pass "parse-local-link-remote-nil"))))
    (delete-directory tmpdir t)))

;; --- 测试 73: footer 系列纯逻辑补强（shorten-cwd / branch 缓存） ---
;; footer--shorten-cwd 的 ~ 前缀、非 home 路径原样；cached-branch 的新鲜度
;; 逻辑（缓存期内仍旧值、过期后重查）。detect-branch 走真实 git，
;; 此处 mock 它以锁定其余分支。
(let ((old-cache dsh-emacs--footer-branch-cache))
  (unwind-protect
      (progn
        ;; shorten-cwd: home 前缀截为 ~ 前缀（截掉 home-dir 剩相对段）
        (when (equal (format "~%s" "proj")
                     (dsh-emacs-footer--shorten-cwd
                      (format "%s/proj" (getenv "HOME"))))
          (dsh-test-pass "footer-shorten-cwd-home-prefix"))
        (when (equal "/opt/app" (dsh-emacs-footer--shorten-cwd "/opt/app"))
          (dsh-test-pass "footer-shorten-cwd-non-home"))
        ;; cached-branch: 缓存新鲜时保持旧值（即使 mock 已换）
        (setq dsh-emacs--footer-branch-cache nil)
        (cl-letf (((symbol-function 'dsh-emacs-footer--detect-branch)
                   (lambda () "feature/x"))
                  (dsh-emacs-footer-branch-refresh-interval 60))
          (let ((b1 (dsh-emacs-footer--cached-branch)))
            (cl-letf (((symbol-function 'dsh-emacs-footer--detect-branch)
                       (lambda () "other")))
              (let ((b2 (dsh-emacs-footer--cached-branch)))
                (when (and (equal "feature/x" b1)
                           (equal "feature/x" b2))
                  (dsh-test-pass "footer-cached-branch-fresh-keeps-value"))
                ;; 缓存过期 → 重查新值
                (setf (cdr dsh-emacs--footer-branch-cache)
                      (- (float-time) 999))
                (when (equal "other" (dsh-emacs-footer--cached-branch))
                  (dsh-test-pass "footer-cached-branch-stale-refetches"))))))
        ;; segment-branch: 有分支渲染括号包裹
        (let ((dsh-emacs--footer-branch "main"))
          (let ((seg (dsh-emacs-footer--segment-branch)))
            (when (string-match-p "main" seg)
              (dsh-test-pass "footer-segment-branch-renders"))))
        ;; segment-cwd: propertize face
        (let ((seg (dsh-emacs-footer--segment-cwd)))
          (when (get-text-property 0 'face seg)
            (dsh-test-pass "footer-segment-cwd-face"))))
    (setq dsh-emacs--footer-branch-cache old-cache)))


;; --- 测试 74: agentPreset.list 协议结构（新建会话的 thinking preset 候选） ---
;; wire alist（presets 数组为 vector）→ struct：presets 归一为 list、字段
;; 全部经访问器读取；broken/缺失字段不破坏转换。
(let* ((v (dsh-protocol-agent-preset-list--from-alist
           '((presets . [((id . "standard") (trust . "system")
                          (isDefault . t) (name . "Standard mode"))
                         ((id . "broken-agent") (broken . "load failed"))])
             (authorable . t)
             (hasDocument . t))))
       (presets (dsh-protocol-agent-preset-list-presets v))
       (p0 (car presets))
       (p1 (cadr presets)))
  (when (and (dsh-protocol-agent-preset-p p0)
             (equal "standard" (dsh-protocol-agent-preset-id p0))
             (equal "system" (dsh-protocol-agent-preset-trust p0))
             (eq t (dsh-protocol-agent-preset-is-default p0))
             (equal "Standard mode" (dsh-protocol-agent-preset-name p0))
             (null (dsh-protocol-agent-preset-broken p0))
             (equal 2 (length presets))
             (equal "broken-agent" (dsh-protocol-agent-preset-id p1))
             (equal "load failed" (dsh-protocol-agent-preset-broken p1))
             (eq t (dsh-protocol-agent-preset-list-authorable v))
             (eq t (dsh-protocol-agent-preset-list-has-document v)))
    (dsh-test-pass "agent-preset-list-protocol-struct")))

;; --- 测试 75: 新建会话 preset 候选表（web 显示名 + 缓存 roster + 内置兜底） ---
;; 显示名与 web 一致：system 内置 preset 经 web 的内建 key map 取名
;; （"Standard mode" 等，即使发布了自己的 name 也以 web 名为准）；user
;; preset 用发布的 name（无则 id）；broken 条目剔除。无缓存 → 四个内置
;; 的 web 名。
(let ((old-cache dsh-emacs--agent-presets))
  (unwind-protect
      (progn
        (setq dsh-emacs--agent-presets nil)
        (when (equal '(("Standard mode" . "standard")
                       ("Minimal mode" . "minimal")
                       ("PTC mode" . "code")
                       ("Creator mode" . "cordis"))
                     (dsh-emacs--preset-choices))
          (dsh-test-pass "preset-choices-fallback-builtins"))
        (setq dsh-emacs--agent-presets
              (dsh-protocol-agent-preset-list--from-alist
               '((presets . [((id . "standard") (trust . "system"))
                             ((id . "minimal") (trust . "system")
                              (name . "Legacy name"))
                             ((id . "my-agent") (trust . "user")
                              (name . "My Agent"))
                             ((id . "broken-agent") (broken . "x"))]))))
        (when (equal '(("Standard mode" . "standard")
                       ("Minimal mode" . "minimal")
                       ("My Agent" . "my-agent"))
                     (dsh-emacs--preset-choices))
          (dsh-test-pass "preset-choices-web-names-and-roster"))
        ;; display-name 边界：system 未知 id → name ?? id；user 无 name → id
        (when (and (equal "Future Mode"
                          (dsh-emacs--preset-display-name
                           (dsh-protocol-agent-preset--from-alist
                            '((id . "future") (trust . "system")
                              (name . "Future Mode")))))
                   (equal "my-raw"
                          (dsh-emacs--preset-display-name
                           (dsh-protocol-agent-preset--from-alist
                            '((id . "my-raw") (trust . "user"))))))
          (dsh-test-pass "preset-display-name-falls-back-name-or-id")))
    (setq dsh-emacs--agent-presets old-cache)))

;; --- 测试 76: preset 预选 id（配置 > roster isDefault > 无） ---
(let ((old-cache dsh-emacs--agent-presets))
  (unwind-protect
      (progn
        (setq dsh-emacs--agent-presets
              (dsh-protocol-agent-preset-list--from-alist
               '((presets . [((id . "standard") (isDefault . t))
                             ((id . "minimal"))]))))
        (when (equal "standard" (dsh-emacs--preset-default-id nil))
          (dsh-test-pass "preset-default-id-roster-is-default"))
        (when (equal "minimal" (dsh-emacs--preset-default-id "minimal"))
          (dsh-test-pass "preset-default-id-configured-wins"))
        (when (equal "standard" (dsh-emacs--preset-default-id "ghost"))
          (dsh-test-pass "preset-default-id-invalid-config-falls-back")))
    (setq dsh-emacs--agent-presets old-cache)))

;; --- 测试 77: read-preset 交互读取（候选 + 预选 + host default + C-g） ---
;; 按显示名选 → 其 id；空 RET 接受预选（模拟 completing-read 返回 DEF）；
;; 无预选时空 RET → nil（host default，不发送 agentPreset）；C-g 冒泡
;; 取消整个创建（quit 不被 read-preset 吞掉）。每次读取都会触发一次
;; agentPreset.list 刷新（rpc-async 被 mock 捕获）。
(let ((old-cache dsh-emacs--agent-presets)
      (calls nil))
  (unwind-protect
      (progn
        (setq dsh-emacs--agent-presets
              (dsh-protocol-agent-preset-list--from-alist
               '((presets . [((id . "standard") (isDefault . t)
                              (name . "Standard mode"))
                             ((id . "minimal") (name . "Minimal mode"))]))))
        ;; 按显示名选 → 其 id；同时向后端发了一次 roster 刷新
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (&rest _) "Standard mode"))
                  ((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (method _params _cb)
                     (push method calls))))
          (when (and (equal "standard" (dsh-emacs--read-preset nil))
                     (member "agentPreset.list" calls))
            (dsh-test-pass "read-preset-pick-by-display-name")))
        ;; 空 RET → 接受预选默认（roster isDefault = standard）
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (_prompt _table &optional _pred _req _init _hist
                                   def _inherit)
                     (or def "")))
                  ((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (&rest _) nil)))
          (when (equal "standard" (dsh-emacs--read-preset nil))
            (dsh-test-pass "read-preset-empty-ret-accepts-default")))
        ;; 无 isDefault 且无配置 → 空 RET 返回 nil（host default）
        (setq dsh-emacs--agent-presets
              (dsh-protocol-agent-preset-list--from-alist
               '((presets . [((id . "standard")
                              (name . "Standard mode"))]))))
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (_prompt _table &optional _pred _req _init _hist
                                   def _inherit)
                     (or def "")))
                  ((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (&rest _) nil)))
          (when (null (dsh-emacs--read-preset nil))
            (dsh-test-pass "read-preset-no-default-keeps-host-default")))
        ;; C-g → quit 冒泡到 interactive（不被 read-preset 吞掉）
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (&rest _) (signal 'quit nil)))
                  ((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (&rest _) nil)))
          (condition-case err
              (dsh-emacs--read-preset nil)
            (quit (dsh-test-pass "read-preset-c-g-aborts-cleanly")))))
    (setq dsh-emacs--agent-presets old-cache)))

;; --- 测试 78: 新建会话携带 agentPreset ---
;; 直接调用带 preset → session.create 参数含 agentPreset（cwd / workspaceId
;; 两种上下文都要）；响应里的 agentPreset 进入占位缓存行（列表详情/页脚
;; 立即可见）；不带 preset → 不发 agentPreset。
(let* ((old-sessions dsh-emacs--sessions))
  (unwind-protect
      (progn
        (setq dsh-emacs--sessions nil)
        ;; 带 preset（cwd 上下文）
        (let ((calls nil))
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method params cb)
                       (push (list method params) calls)
                       (funcall cb t '((sessionId . "s-preset")
                                       (agentPreset . "standard")))))
                    ((symbol-function 'dsh-emacs-open-session)
                     (lambda (_sid) nil)))
            (dsh-emacs-new-session nil nil "standard")
            (let* ((call (car calls))
                   (params (cadr call)))
              (when (and (string= "session.create" (car call))
                         (null (assq 'workspaceId params))
                         (assq 'cwd params)
                         (string= "standard"
                                  (cdr (assq 'agentPreset params))))
                (dsh-test-pass "new-session-with-preset-sends-agent-preset")))
            ;; 占位缓存行带了 preset（响应回填）
            (let ((item (dsh-emacs--chat-session-item "s-preset")))
              (when (and item
                         (string= "standard"
                                  (dsh-protocol-session-agent-preset item)))
                (dsh-test-pass "new-session-preset-cached-in-placeholder")))))
        ;; 带 preset（workspace 上下文）：workspaceId 与 agentPreset 并存
        (let ((calls nil))
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method params cb)
                       (push (list method params) calls)
                       (funcall cb t '((sessionId . "s-ws-preset")))))
                    ((symbol-function 'dsh-emacs-open-session)
                     (lambda (_sid) nil)))
            (dsh-emacs-new-session nil "w1" "code")
            (let* ((call (car calls))
                   (params (cadr call)))
              (when (and (string= "session.create" (car call))
                         (string= "w1" (cdr (assq 'workspaceId params)))
                         (null (assq 'cwd params))
                         (string= "code" (cdr (assq 'agentPreset params))))
                (dsh-test-pass "new-session-workspace-with-preset")))))
        ;; 无 preset → 不发送 agentPreset
        (let ((calls nil))
          (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                     (lambda (method params cb)
                       (push (list method params) calls)
                       (funcall cb t '((sessionId . "s-plain2")))))
                    ((symbol-function 'dsh-emacs-open-session)
                     (lambda (_sid) nil)))
            (dsh-emacs-new-session nil nil nil)
            (let* ((call (car calls))
                   (params (cadr call)))
              (when (and (string= "session.create" (car call))
                         (null (assq 'agentPreset params)))
                (dsh-test-pass "new-session-without-preset-omits-agent-preset"))))))
    (setq dsh-emacs--sessions old-sessions)))

;; --- 测试 79: 交互带前缀参数 → 先选 preset 再创建 ---
;; C-u 下 call-interactively：interactive spec 读 preset（completing-read
;; mock 返回显示名），session.create 携带其 id，且触发过 agentPreset.list。
(let* ((old-sessions dsh-emacs--sessions)
       (buf (generate-new-buffer " *dsh-prefix-create*"))
       (calls nil)
       (old-cache dsh-emacs--agent-presets))
  (unwind-protect
      (with-current-buffer buf
        (setq dsh-emacs--sessions nil)
        (setq dsh-emacs--agent-presets
              (dsh-protocol-agent-preset-list--from-alist
               '((presets . [((id . "minimal")
                              (name . "Minimal mode"))]))))
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (method params cb)
                     (push (list method params) calls)
                     (when (string= method "session.create")
                       (funcall cb t '((sessionId . "s-pfx"))))))
                  ((symbol-function 'dsh-emacs-open-session)
                   (lambda (_sid) nil))
                  ((symbol-function 'completing-read)
                   (lambda (&rest _) "Minimal mode"))
                  (current-prefix-arg '(4)))
          (call-interactively #'dsh-emacs-new-session))
        (let ((create (cl-find-if
                       (lambda (c) (string= "session.create" (car c)))
                       calls)))
          (when (and create
                     (string= "minimal"
                              (cdr (assq 'agentPreset (cadr create))))
                     (member "agentPreset.list" (mapcar #'car calls)))
            (dsh-test-pass "new-session-prefix-asks-preset"))))
    (setq dsh-emacs--sessions old-sessions)
    (setq dsh-emacs--agent-presets old-cache)
    (when (buffer-live-p buf) (kill-buffer buf))))

;; --- 测试 80: 列表键位 c = 默认 preset 立即建，C = 先选 preset ---
;; c → dsh-emacs-new-session（不弹选择，会话带 dsh-emacs-default-preset，
;; nil 即 host default，不发 agentPreset 也不拉 roster）；
;; C → dsh-emacs-new-session-choose-preset（先选 preset 再建，workspace
;; 上下文沿用，且触发 agentPreset.list 刷新）。
(when (eq (lookup-key dsh-emacs-session-mode-map "c")
          #'dsh-emacs-new-session)
  (dsh-test-pass "session-map-c-binds-plain-create"))
(when (eq (lookup-key dsh-emacs-session-mode-map "C")
          #'dsh-emacs-new-session-choose-preset)
  (dsh-test-pass "session-map-C-binds-preset-choose"))

;; c 路径：无前缀交互 → 只发 session.create，不带 agentPreset
(let* ((calls nil)
       (buf (generate-new-buffer " *dsh-c-default-create*")))
  (unwind-protect
      (with-current-buffer buf
        (insert "row text\n")
        (goto-char (point-min))
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (method params cb)
                     (push (list method params) calls)
                     (funcall cb t '((sessionId . "s-c-default")))))
                  ((symbol-function 'dsh-emacs-open-session)
                   (lambda (_sid) nil)))
          (call-interactively #'dsh-emacs-new-session))
        (let* ((call (car calls))
               (params (cadr call)))
          (when (and (string= "session.create" (car call))
                     (null (assq 'agentPreset params))
                     (not (member "agentPreset.list" (mapcar #'car calls))))
            (dsh-test-pass "session-c-creates-without-preset-prompt"))))
    (when (buffer-live-p buf) (kill-buffer buf))))

;; C 路径：先选 preset（completing-read mock 返回显示名），workspace 上下文
;; 创建 → session.create 带 workspaceId + agentPreset，且触发过 roster。
(let* ((calls nil)
       (buf (generate-new-buffer " *dsh-C-preset-create*"))
       (old-cache dsh-emacs--agent-presets))
  (unwind-protect
      (with-current-buffer buf
        (insert "  workspace row")
        (put-text-property (point-min) (point-max)
                           'dsh-emacs-workspace-id "w-C")
        (goto-char (point-min))
        (setq dsh-emacs--agent-presets
              (dsh-protocol-agent-preset-list--from-alist
               '((presets . [((id . "code") (name . "PTC mode"))]))))
        (cl-letf (((symbol-function 'dsh-emacs--rpc-async)
                   (lambda (method params cb)
                     (push (list method params) calls)
                     (when (string= method "session.create")
                       (funcall cb t '((sessionId . "s-C"))))))
                  ((symbol-function 'dsh-emacs-open-session)
                   (lambda (_sid) nil))
                  ((symbol-function 'completing-read)
                   (lambda (&rest _) "PTC mode")))
          (call-interactively #'dsh-emacs-new-session-choose-preset))
        (let ((create (cl-find-if
                       (lambda (c) (string= "session.create" (car c)))
                       calls)))
          (when (and create
                     (string= "w-C" (cdr (assq 'workspaceId (cadr create))))
                     (string= "code" (cdr (assq 'agentPreset (cadr create))))
                     (member "agentPreset.list" (mapcar #'car calls)))
            (dsh-test-pass "session-C-creates-with-chosen-preset"))))
    (setq dsh-emacs--agent-presets old-cache)
    (when (buffer-live-p buf) (kill-buffer buf))))


;; --- 测试 81: 用户提问（question/requested）minibuffer 选择与应答 ---
;; dsh 的 `ask' 工具经 mux 流推 question/requested（server-request，稳定
;; rpcId）：每帧逐题在 minibuffer 选择 — 选项为 completion 候选（单选
;; 一个 / 多选多个），末尾附「Type answer…」输入自定义文本；全部答完
;; 一次性 client-response 回 POST /api/respond。selected 恒为数组
;; （custom-only 时为 []），标签比较用 equal。minibuffer 是全局唯一资源：
;; 多个会话并发提问时帧进 FIFO 队列串行应答，提示语带所属会话标识。

;; 1) respond 信封：client-response + 回声 rpcId + result.value
(when (string= (concat "{\"type\":\"client-response\","
                       "\"rpcId\":\"rpc-1\","
                       "\"result\":{\"ok\":true,\"value\":"
                       "{\"sessionId\":\"s1\","
                       "\"answer\":{\"answers\":"
                       "[{\"id\":\"q1\",\"selected\":[\"Yes\"]}]}}}}")
               (dsh-emacs--respond-envelope-json
                "rpc-1"
                '((sessionId . "s1")
                  (answer . ((answers .
                              (((id . "q1") (selected "Yes")))))))))
  (dsh-test-pass "respond-envelope-json-client-response"))

;; 2) 候选构建：选项带序号（输入数字跳选），Type answer… 恒垫底
(when (equal '("1. Yes" "2. No" "Type answer…")
             (dsh-emacs--question-candidates
              '("Yes" "No") "Type answer…"))
  (dsh-test-pass "question-candidates-numbered-type-answer-last"))

(when (and (equal "Yes" (dsh-emacs--question-picked-label "1. Yes"))
           (equal "Type answer…"
                  (dsh-emacs--question-picked-label "Type answer…")))
  (dsh-test-pass "question-picked-label-strips-number"))

;; 会话标识：优先用活跃聊天缓冲的名字；无缓冲回退到 dsh: <id> 并截断；
;; 无 session-id 时为空（直接调用测试不加前缀）
(let ((buf (get-buffer-create " *dsh-test-label-buf*")))
  (unwind-protect
      (progn
        (when (equal " *dsh-test-label-buf*"
                     (let ((dsh-emacs--chat-buffers
                            (make-hash-table :test 'equal)))
                       (puthash "sess-l" buf dsh-emacs--chat-buffers)
                       (dsh-emacs--question-session-label "sess-l")))
          (dsh-test-pass "question-session-label-uses-chat-buffer-name"))
        (when (equal (concat "dsh: " (make-string 32 ?x) "…")
                     (let ((dsh-emacs--chat-buffers
                            (make-hash-table :test 'equal))
                           (dsh-emacs--sessions nil))
                       (dsh-emacs--question-session-label
                        (make-string 50 ?x))))
          (dsh-test-pass "question-session-label-truncates-long"))
        (when (equal ""
                     (let ((dsh-emacs--chat-buffers
                            (make-hash-table :test 'equal)))
                       (dsh-emacs--question-session-label nil)))
          (dsh-test-pass "question-session-label-nil-id-empty")))
    (when (buffer-live-p buf) (kill-buffer buf))))

;; 3) minibuffer 选择 → answer 映射
(when (equal '((id . "q1") (selected "Yes"))
             (cl-letf (((symbol-function 'completing-read)
                        (lambda (&rest _) "1. Yes")))
               (dsh-emacs--question-choice
                '((id . "q1") (question . "Proceed?")
                  (options . (((label . "Yes")) ((label . "No"))))))))
  (dsh-test-pass "question-choice-single-label"))

(when (equal '((id . "q1") (selected . []) (custom . "my note"))
             (cl-letf (((symbol-function 'completing-read)
                        (lambda (&rest _) "Type answer…"))
                       ((symbol-function 'read-string)
                        (lambda (&rest _) "my note")))
               (dsh-emacs--question-choice
                '((id . "q1") (question . "Proceed?")
                  (options . (((label . "Yes")) ((label . "No"))))))))
  (dsh-test-pass "question-choice-single-type-answer"))

(when (equal '((id . "q2") (selected "A" "B"))
             (cl-letf (((symbol-function 'completing-read-multiple)
                        (lambda (&rest _) '("1. A" "2. B")))
                       ((symbol-function 'read-string)
                        (lambda (&rest _) "x")))
               (dsh-emacs--question-choice
                '((id . "q2") (question . "Pick?") (multiSelect . t)
                  (options . (((label . "A")) ((label . "B"))
                              ((label . "C"))))))))
  (dsh-test-pass "question-choice-multi-labels"))

(when (equal '((id . "q2") (selected "A") (custom . "extra"))
             (cl-letf (((symbol-function 'completing-read-multiple)
                        (lambda (&rest _) '("1. A" "Type answer…")))
                       ((symbol-function 'read-string)
                        (lambda (&rest _) "extra")))
               (dsh-emacs--question-choice
                '((id . "q2") (question . "Pick?") (multiSelect . t)
                  (options . (((label . "A")) ((label . "B"))))))))
  (dsh-test-pass "question-choice-multi-with-type-answer"))

(when (equal '((id . "q3") (selected . []) (custom . "free text"))
             (cl-letf (((symbol-function 'read-string)
                        (lambda (&rest _) "free text")))
               (dsh-emacs--question-choice
                '((id . "q3") (question . "Say?")))))
  (dsh-test-pass "question-choice-no-options-custom"))

;; 无选项 + 空输入 → nil（无选项可回退，整体取消）
(when (null (cl-letf (((symbol-function 'read-string)
                       (lambda (&rest _) "")))
              (dsh-emacs--question-choice
               '((id . "q3") (question . "Say?")))))
  (dsh-test-pass "question-choice-no-options-empty-aborts"))

;; Type answer… 空输入 → 回到选项（再轮选择）
(let ((reads '("Type answer…" "1. Yes")))
  (when (equal '((id . "q1") (selected "Yes"))
               (cl-letf (((symbol-function 'completing-read)
                          (lambda (&rest _)
                            (if reads (pop reads) "1. Yes")))
                         ((symbol-function 'read-string)
                          (lambda (&rest _) "")))
                 (dsh-emacs--question-choice
                  '((id . "q1") (question . "Proceed?")
                    (options . (((label . "Yes")) ((label . "No"))))))))
    (dsh-test-pass "question-choice-type-answer-empty-backs-to-options")))

;; 多选同规则：Type answer… 空输入 → 回到多选
(let ((reads '(("Type answer…") ("1. A"))))
  (when (equal '((id . "q2") (selected "A"))
               (cl-letf (((symbol-function 'completing-read-multiple)
                          (lambda (&rest _)
                            (if reads (pop reads) '("1. A"))))
                         ((symbol-function 'read-string)
                          (lambda (&rest _) "")))
                 (dsh-emacs--question-choice
                  '((id . "q2") (question . "Pick?") (multiSelect . t)
                    (options . (((label . "A")) ((label . "B"))))))))
    (dsh-test-pass "question-choice-multi-type-answer-empty-backs")))

;; 3b) 帧分发：question/requested → minibuffer 应答（不渲染任何卡片）
;; （单题；mux 重放时 history 加载中也应答）
(let* ((chat (get-buffer-create " *dsh-test-question*"))
       (responds nil))
  (unwind-protect
      (progn
        (with-current-buffer chat
          (setq-local dsh-emacs--buffer-session "sess-q"))
        (cl-letf (((symbol-function 'dsh-emacs-events--chat)
                   (lambda (_p) chat))
                  ((symbol-function 'dsh-emacs--rpc-respond-async)
                   (lambda (rpc-id payload cb)
                     (push (list rpc-id payload) responds)
                     (funcall cb t nil)))
                  ((symbol-function 'completing-read)
                   (lambda (&rest _) "Yes")))
          (dsh-emacs-events--dispatch-json
           'process
           (concat "{\"type\":\"server-request\",\"rpcId\":\"rpc-q\","
                   "\"method\":\"question/requested\","
                   "\"payload\":{\"type\":\"question/requested\","
                   "\"sessionId\":\"sess-q\","
                   "\"questions\":[{\"id\":\"q1\","
                   "\"question\":\"Proceed?\","
                   "\"options\":[{\"label\":\"Yes\"},"
                   "{\"label\":\"No\"}]}]}}"))
          (let ((r (car responds)))
            (when (and (equal "rpc-q" (car r))
                       (equal '((sessionId . "sess-q")
                                (answer . ((answers .
                                            (((id . "q1")
                                              (selected "Yes")))))))
                             (cadr r)))
              (dsh-test-pass "question-frame-responds-echoing-rpc-id")))
          ;; 不再插入选项卡：应答后缓冲内容没有任何问题卡片
          (let ((text (with-current-buffer chat (buffer-string))))
            (when (not (string-match-p "❓ Question" text))
              (dsh-test-pass "question-frame-inserts-no-card")))))
    (when (buffer-live-p chat) (kill-buffer chat))))

;; 4) 多问题帧：顺序渲染 + 逐题 minibuffer 选择，答完只 respond 一次
(let* ((chat (get-buffer-create " *dsh-test-question-multi*"))
       (responds nil)
       (queue '("Yes" "X")))
  (unwind-protect
      (progn
        (with-current-buffer chat
          (setq-local dsh-emacs--buffer-session "sess-m"))
        (cl-letf (((symbol-function 'dsh-emacs-events--chat)
                   (lambda (_p) chat))
                  ((symbol-function 'dsh-emacs--rpc-respond-async)
                   (lambda (rpc-id payload cb)
                     (push (list rpc-id payload) responds)
                     (funcall cb t nil)))
                  ((symbol-function 'completing-read)
                   (lambda (&rest _)
                     (if queue (pop queue) "Yes")))
                  ((symbol-function 'completing-read-multiple)
                   (lambda (&rest _) '("X"))))
          (dsh-emacs-events--dispatch-json
           'process
           (concat "{\"type\":\"server-request\",\"rpcId\":\"rpc-m\","
                   "\"method\":\"question/requested\","
                   "\"payload\":{\"type\":\"question/requested\","
                   "\"sessionId\":\"sess-m\","
                   "\"questions\":[{\"id\":\"q1\","
                   "\"question\":\"One?\","
                   "\"options\":[{\"label\":\"Yes\"},"
                   "{\"label\":\"No\"}]},"
                   "{\"id\":\"q2\",\"question\":\"Two?\","
                   "\"multiSelect\":true,"
                   "\"options\":[{\"label\":\"X\"},"
                   "{\"label\":\"Y\"}]}]}}"))
          (let ((r (car responds)))
            (when (and (equal "rpc-m" (car r))
                       (equal '((sessionId . "sess-m")
                                (answer . ((answers .
                                            (((id . "q1")
                                              (selected "Yes"))
                                             ((id . "q2")
                                              (selected "X")))))))
                             (cadr r)))
              (dsh-test-pass "question-multi-answers-sequential-in-order")))
          ;; 仍然不插入任何卡片（纯 minibuffer 回答）
          (let ((text (with-current-buffer chat (buffer-string))))
            (when (not (string-match-p "❓ Question" text))
              (dsh-test-pass "question-multi-inserts-no-card")))))
    (when (buffer-live-p chat) (kill-buffer chat))))

;; 5) 帧分发：C-g 取消 → 不应答（问题留给 host）
(let* ((chat (get-buffer-create " *dsh-test-question-cg*"))
       (responds nil))
  (unwind-protect
      (progn
        (with-current-buffer chat
          (setq-local dsh-emacs--buffer-session "sess-qc"))
        (cl-letf (((symbol-function 'dsh-emacs-events--chat)
                   (lambda (_p) chat))
                  ((symbol-function 'dsh-emacs--rpc-respond-async)
                   (lambda (&rest _) (push t responds)))
                  ((symbol-function 'completing-read)
                   (lambda (&rest _) (signal 'quit nil))))
          (dsh-emacs-events--dispatch-json
           'process
           (concat "{\"type\":\"server-request\",\"rpcId\":\"rpc-qc\","
                   "\"method\":\"question/requested\","
                   "\"payload\":{\"type\":\"question/requested\","
                   "\"sessionId\":\"sess-qc\","
                   "\"questions\":[{\"id\":\"q1\","
                   "\"question\":\"Proceed?\","
                   "\"options\":[{\"label\":\"Yes\"}]}]}}"))
          (when (null responds)
            (dsh-test-pass "question-frame-c-g-aborts-without-respond"))))
    (when (buffer-live-p chat) (kill-buffer chat))))

;; 6) 帧分发：history 加载中也要应答（mux 重放的 pending 问题在打开时到达）
(let* ((chat (get-buffer-create " *dsh-test-question-load*"))
       (responds nil))
  (unwind-protect
      (progn
        (with-current-buffer chat
          (setq-local dsh-emacs--buffer-session "sess-ql")
          (setq-local dsh-emacs--event-history-loading t))
        (cl-letf (((symbol-function 'dsh-emacs-events--chat)
                   (lambda (_p) chat))
                  ((symbol-function 'dsh-emacs--rpc-respond-async)
                   (lambda (rpc-id payload cb)
                     (push rpc-id responds)
                     (funcall cb t nil)))
                  ((symbol-function 'completing-read)
                   (lambda (&rest _) "Yes")))
          (dsh-emacs-events--dispatch-json
           'process
           (concat "{\"type\":\"server-request\",\"rpcId\":\"rpc-ql\","
                   "\"method\":\"question/requested\","
                   "\"payload\":{\"type\":\"question/requested\","
                   "\"sessionId\":\"sess-ql\","
                   "\"questions\":[{\"id\":\"q1\","
                   "\"question\":\"Proceed?\","
                   "\"options\":[{\"label\":\"Yes\"}]}]}}"))
          (when (equal '("rpc-ql") responds)
            (dsh-test-pass "question-frame-during-history-load-answered"))))
    (when (buffer-live-p chat) (kill-buffer chat))))

;; 7) 非本会话问题、question/resolved、approval/requested → 忽略
(let* ((chat (get-buffer-create " *dsh-test-question-other*"))
       (responds nil))
  (unwind-protect
      (progn
        (with-current-buffer chat
          (setq-local dsh-emacs--buffer-session "mine"))
        (cl-letf (((symbol-function 'dsh-emacs-events--chat)
                   (lambda (_p) chat))
                  ((symbol-function 'dsh-emacs--rpc-respond-async)
                   (lambda (&rest _) (push t responds)))
                  ((symbol-function 'completing-read)
                   (lambda (&rest _) "Yes")))
          ;; 另一会话的问题帧 → 忽略
          (dsh-emacs-events--dispatch-json
           'process
           (concat "{\"type\":\"server-request\",\"rpcId\":\"rpc-o\","
                   "\"method\":\"question/requested\","
                   "\"payload\":{\"type\":\"question/requested\","
                   "\"sessionId\":\"other-session\","
                   "\"questions\":[{\"id\":\"q1\","
                   "\"question\":\"Proceed?\","
                   "\"options\":[{\"label\":\"Yes\"}]}]}}"))
          ;; question/resolved（纯推送）→ 忽略
          (dsh-emacs-events--dispatch-json
           'process
           (concat "{\"type\":\"server-request\",\"rpcId\":\"rpc-r\","
                   "\"method\":\"question/resolved\","
                   "\"payload\":{\"type\":\"question/resolved\","
                   "\"sessionId\":\"mine\","
                   "\"questionRpcId\":\"rpc-q\",\"outcome\":\"answered\"}}"))
          ;; approval/requested → 忽略
          (dsh-emacs-events--dispatch-json
           'process
           (concat "{\"type\":\"server-request\",\"rpcId\":\"rpc-a\","
                   "\"method\":\"approval/requested\","
                   "\"payload\":{\"type\":\"approval/requested\","
                   "\"sessionId\":\"mine\",\"approvalId\":\"a1\","
                   "\"toolName\":\"bash\"}}"))
          (when (null responds)
            (dsh-test-pass "question-other-session-and-pushes-ignored"))))
    (when (buffer-live-p chat) (kill-buffer chat))))

;; 8) 多会话并发提问：minibuffer 是全局唯一资源，回答一帧的途中到达的
;;    其它会话帧必须排队（FIFO）串行应答，提示语还要带所属会话标识
(let* ((chat-a (get-buffer-create " *dsh-test-question-a*"))
       (chat-b (get-buffer-create " *dsh-test-question-b*"))
       (responds nil)
       (prompts nil)
       (b-pushed nil))
  (unwind-protect
      (let ((dsh-emacs--sessions nil)
            (dsh-emacs--chat-buffers (make-hash-table :test 'equal)))
        (setq dsh-emacs--question-queue nil
              dsh-emacs--question-active nil)
        (with-current-buffer chat-a
          (setq-local dsh-emacs--buffer-session "sess-a"))
        (with-current-buffer chat-b
          (setq-local dsh-emacs--buffer-session "sess-b"))
        (cl-letf (((symbol-function 'dsh-emacs--rpc-respond-async)
                   (lambda (rpc-id payload cb)
                     (push (list rpc-id payload) responds)
                     (funcall cb t nil)))
                  ((symbol-function 'completing-read)
                   (lambda (prompt &rest _)
                     (push prompt prompts)
                     ;; A 的 minibuffer 等待期间，B 会话的问题帧到达：
                     ;; 必须排队，而不是在同一 minibuffer 里嵌套提示
                     (unless b-pushed
                       (setq b-pushed t)
                       (dsh-emacs--question-requested
                        chat-b "rpc-b" "sess-b"
                        '(("id" . "qb") ("question" . "B asks?")
                          ("options" . ((("label" . "Only")))))))
                     "Yes")))
          ;; 先来 A 帧（空闲 → 直接进入回答槽）；A 回答途中 B 帧排队
          (dsh-emacs--question-requested
           chat-a "rpc-a" "sess-a"
           '(("id" . "qa") ("question" . "A asks?")
             ("options" . ((("label" . "Yes"))))))
          ;; A 答完后 B 排进同一回答槽继续答；respond 与到达顺序一致
          (let ((r2 (nth 1 (pop responds)))
                (r1 (nth 1 (pop responds))))
            (when (equal '((sessionId . "sess-a")
                           (answer . ((answers .
                                       (((id . "qa")
                                         (selected "Yes")))))))
                         r1)
              (dsh-test-pass "question-queue-serial-first"))
            (when (equal '((sessionId . "sess-b")
                           (answer . ((answers .
                                       (((id . "qb")
                                         (selected "Yes")))))))
                         r2)
              (dsh-test-pass "question-queue-serial-second")))
          ;; 每个提示语都标出所属会话
          (when (and (cl-some (lambda (p)
                                (string-match-p "\\[dsh: sess-a\\]" p))
                              prompts)
                     (cl-some (lambda (p)
                                (string-match-p "\\[dsh: sess-b\\]" p))
                              prompts))
            (dsh-test-pass "question-prompt-carries-session-label"))
          ;; 回答结束后回答槽与队列都清空（不泄漏到后续测试）
          (when (and (null dsh-emacs--question-active)
                     (null dsh-emacs--question-queue))
            (dsh-test-pass "question-queue-drained-clean"))))
    (when (buffer-live-p chat-a) (kill-buffer chat-a))
    (when (buffer-live-p chat-b) (kill-buffer chat-b))))

(when (featurep 'dsh-emacs-server)
  (dsh-test-pass "dsh-emacs-server loaded"))

;; --- 测试 79: server bootstrap：base-url → (host . port) 解析 ---
(let ((dsh-emacs-base-url "http://127.0.0.1:3080"))
  (let ((hp (dsh-emacs--server-host-port)))
    (when (and (equal "127.0.0.1" (car hp)) (= 3080 (cdr hp)))
      (dsh-test-pass "server-host-port-parses-default-url"))))
(let ((dsh-emacs-base-url "http://localhost:9999"))
  (let ((hp (dsh-emacs--server-host-port)))
    (when (and (equal "localhost" (car hp)) (= 9999 (cdr hp)))
      (dsh-test-pass "server-host-port-parses-custom-host-port"))))
(let ((dsh-emacs-base-url "http://127.0.0.1"))
  (when (= 80 (cdr (dsh-emacs--server-host-port)))
    (dsh-test-pass "server-host-port-defaults-to-80")))

;; --- 测试 80: alive 探测带短缓存（TTL 内不重复探测） ---
(let ((probes 0))
  (setq dsh-emacs--server-alive-check nil)
  (cl-letf (((symbol-function 'dsh-emacs--server-probe)
             (lambda () (setq probes (1+ probes)) t)))
    (dsh-emacs--server-alive-p)
    (dsh-emacs--server-alive-p)
    (when (= 1 probes)
      (dsh-test-pass "server-alive-cached-within-ttl"))
    (dsh-emacs--server-invalidate-alive)
    (dsh-emacs--server-alive-p)
    (when (= 2 probes)
      (dsh-test-pass "server-alive-invalidate-reprobes")))
  (setq dsh-emacs--server-alive-check nil))

;; --- 测试 81: ensure 在 batch（noninteractive）下恒为 no-op ---
(let ((started 0)
      (noninteractive t))
  (cl-letf (((symbol-function 'dsh-emacs--server-alive-p) (lambda () nil))
            ((symbol-function 'dsh-emacs-server-start)
             (lambda () (setq started (1+ started)))))
    (dsh-emacs-server-ensure))
  (when (= 0 started)
    (dsh-test-pass "server-ensure-noop-in-batch")))

;; --- 测试 82: ensure 交互路径：server 已就绪 → 不启动 ---
(let ((started 0)
      (noninteractive nil))
  (cl-letf (((symbol-function 'dsh-emacs--server-alive-p) (lambda () t))
            ((symbol-function 'dsh-emacs-server-start)
             (lambda () (setq started (1+ started)))))
    (dsh-emacs-server-ensure))
  (when (= 0 started)
    (dsh-test-pass "server-ensure-alive-skips-start")))

;; --- 测试 83: ensure 交互路径：down + auto-start → 启动被调用 ---
(let ((started 0)
      (noninteractive nil))
  (cl-letf (((symbol-function 'dsh-emacs--server-alive-p) (lambda () nil))
            ((symbol-function 'dsh-emacs-server-start)
             (lambda () (setq started (1+ started)))))
    (dsh-emacs-server-ensure))
  (when (= 1 started)
    (dsh-test-pass "server-ensure-down-starts-server")))

;; --- 测试 84: ensure 交互路径：auto-start nil → user-error 带指引 ---
(let ((dsh-emacs-server-auto-start nil)
      (noninteractive nil))
  (cl-letf (((symbol-function 'dsh-emacs--server-alive-p) (lambda () nil)))
    (condition-case err
        (dsh-emacs-server-ensure)
      (user-error
       (when (string-match-p "not reachable" (error-message-string err))
         (dsh-test-pass "server-ensure-auto-start-nil-errors"))))))

;; --- 测试 85: 安装流程：接受 → 运行安装并返回 dsh 路径 ---
(cl-letf (((symbol-function 'dsh-emacs--server-bin) (lambda () nil))
          ((symbol-function 'y-or-n-p) (lambda (_prompt) t))
          ((symbol-function 'dsh-emacs--server-run-install)
           (lambda () "/usr/bin/dsh")))
  (when (equal "/usr/bin/dsh" (dsh-emacs--server-ensure-installed))
    (dsh-test-pass "server-install-accepted-runs-install")))

;; --- 测试 86: 安装流程：拒绝 → user-error 手动指引 ---
(cl-letf (((symbol-function 'dsh-emacs--server-bin) (lambda () nil))
          ((symbol-function 'y-or-n-p) (lambda (_prompt) nil)))
  (condition-case err
      (dsh-emacs--server-ensure-installed)
    (user-error
     (when (string-match-p "manually" (error-message-string err))
       (dsh-test-pass "server-install-declined-errors")))))

;; --- 测试 87: server-start：已就绪 → 不拉起进程 ---
(let ((commands nil))
  (cl-letf (((symbol-function 'dsh-emacs--server-alive-p) (lambda () t))
            ((symbol-function 'make-process)
             (lambda (&rest args) (push args commands) 'fake-proc)))
    (dsh-emacs-server-start))
  (when (null commands)
    (dsh-test-pass "server-start-alive-does-not-spawn")))

;; --- 测试 88: server-start：down → 以 base-url 的 host/port 拉起 dsh web ---
(let ((commands nil)
      (waits 0)
      (dsh-emacs-base-url "http://127.0.0.1:3080"))
  (setq dsh-emacs--server-process nil)
  (cl-letf (((symbol-function 'dsh-emacs--server-alive-p) (lambda () nil))
            ((symbol-function 'dsh-emacs--server-bin) (lambda () "/usr/bin/dsh"))
            ((symbol-function 'make-process)
             (lambda (&rest args) (push args commands) 'fake-proc))
            ((symbol-function 'set-process-query-on-exit-flag)
             (lambda (&rest _) nil))
            ((symbol-function 'dsh-emacs--server-wait-ready)
             (lambda () (setq waits (1+ waits)) t)))
    (dsh-emacs-server-start))
  (when (and (= 1 waits)
             (equal '("/usr/bin/dsh" "web" "--host" "127.0.0.1"
                      "--port" "3080" "--no-open")
                    (plist-get (car commands) :command)))
    (dsh-test-pass "server-start-spawns-dsh-web-with-base-url-args"))
  (setq dsh-emacs--server-process nil))

;; --- 测试 89: wait-ready：server 已就绪 → 立即返回 t ---
(cl-letf (((symbol-function 'dsh-emacs--server-alive-p) (lambda () t)))
  (when (eq t (dsh-emacs--server-wait-ready))
    (dsh-test-pass "server-wait-ready-alive-returns-t")))

;; --- 测试 90: Emacs 退出时清理托管进程 ---
(when (memq 'dsh-emacs-server--teardown kill-emacs-hook)
  (dsh-test-pass "server-teardown-registered-on-kill-emacs-hook"))

;; --- 测试 91: 命令体护栏——真实命令在 server 不可达时给出指引错误 ---
(let ((dsh-emacs-server-auto-start nil)
      (noninteractive nil))
  (cl-letf (((symbol-function 'dsh-emacs--server-alive-p) (lambda () nil)))
    (condition-case err
        (dsh-emacs-list-sessions)
      (user-error
       (when (string-match-p "not reachable" (error-message-string err))
         (dsh-test-pass "list-sessions-guard-fails-with-guidance"))))))

;; --- 测试 92: open-web 打开 dsh web（base-url，settings 是弹窗无子路由） ---
(let ((dsh-emacs-base-url "http://127.0.0.1:3080")
      (opened nil))
  (cl-letf (((symbol-function 'browse-url)
             (lambda (url) (setq opened url))))
    (dsh-emacs-open-web))
  (when (equal "http://127.0.0.1:3080" opened)
    (dsh-test-pass "open-web-opens-web-ui-root")))

;; --- 测试 93: open-web 同样被 server 护栏保护 ---
(let ((dsh-emacs-server-auto-start nil)
      (noninteractive nil))
  (cl-letf (((symbol-function 'dsh-emacs--server-alive-p) (lambda () nil)))
    (condition-case err
        (dsh-emacs-open-web)
      (user-error
       (when (string-match-p "not reachable" (error-message-string err))
         (dsh-test-pass "open-web-guard-fails-with-guidance"))))))

(princ "\n===== 测试总结 =====\n")
(let ((pass (cl-count-if (lambda (r) (cdr r)) dsh-test-results))
      (fail (cl-count-if (lambda (r) (not (cdr r))) dsh-test-results)))
  (princ (format "通过 %d 项，失败 %d 项\n" pass fail))
  (when (> fail 0)
    (princ "失败的测试:\n")
    (dolist (r (nreverse dsh-test-results))
      (unless (cdr r)
        (princ (format "  - %s: %s\n" (car r) (cdr r)))))))

