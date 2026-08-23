;;; dsh-emacs.el --- Main entry point for dsh-emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2025 vritser

;; Author: vritser
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))
;; URL: https://github.com/vritser/dsh-emacs
;; License: GPL-3.0-or-later
;; Keywords: ai, tools, convenience

;;; Commentary:

;; dsh-emacs 是在 Emacs 中使用 DeepSeek Harness 的界面。
;; 它通过 HTTP 与正在运行的 dsh web 服务通信，提供符合 Emacs 操作习惯的交互方式。
;;
;; 主要功能：
;; - 会话列表（卡片视图）
;; - 对话缓冲（带工具调用折叠、思考折叠）
;; - Footer 状态栏（显示 cwd、git branch、model、tokens、cost）
;; - Markdown 渲染
;;
;; 快速开始：
;;   (require 'dsh-emacs)
;;   M-x dsh-emacs                    ; 打开会话列表
;;   M-x dsh-emacs-new-session        ; 新建会话
;;
;; 对话缓冲键位：
;;   C-c C-c   发送/中断
;;   C-c C-r   刷新
;;   C-c C-l   打开会话列表
;;   C-c C-w   复制转录
;;
;; 会话列表键位：
;;   RET       打开会话
;;   c         新建会话
;;   r         重命名
;;   D         删除
;;   g         刷新
;;   q         退出

;;; Code:

(require 'json)
(require 'url)
(require 'cl-lib)

;; 加载核心 UI 框架(必须先加载)
(require 'dsh-emacs-ui)

;; 加载所有新模块
(require 'dsh-emacs-faces)
(require 'dsh-emacs-tokens)
(require 'dsh-emacs-markdown)
(require 'dsh-emacs-render)
(require 'dsh-emacs-events)
(require 'dsh-emacs-footer)
(require 'dsh-emacs-session)

;;; ---------------------------------------------------------------------------
;;;  定制选项
;;; ---------------------------------------------------------------------------

(defgroup dsh-emacs nil
  "Emacs UI for DeepSeek Harness (dsh)."
  :group 'applications
  :prefix "dsh-emacs-")

(defcustom dsh-emacs-base-url "http://127.0.0.1:3080"
  "Address of the running dsh web service."
  :type 'string
  :group 'dsh-emacs)

(defcustom dsh-emacs-poll-interval 1.0
  "Fallback polling interval (seconds).
This polling starts only when the WebSocket event stream is unavailable.  It
fetches just the newest event window per the `maxMessages' semantics (the
server returns at least ~850 raw events) and renders it incrementally, not a
full-history parse, so the main-thread cost stays small; a 1s interval
balances fidelity against overhead.
When the WebSocket works, polling does not participate at all and streaming
updates stay realtime."
  :type 'number
  :group 'dsh-emacs)

(defcustom dsh-emacs-poll-fallback t
  "Whether to fall back to polling when the WebSocket event stream is unavailable.
Enabled by default: when the event stream is disconnected or failing, replies
still appear automatically through `session.history' polling, avoiding
\"replies not shown automatically\".  Polling renders incrementally by the seq
anchor and runs only while the event stream is unavailable; it stops
automatically when the stream recovers (101 handshake).  Set to nil to disable
fallback polling entirely (once the stream drops, replies appear only via
WebSocket or manual refresh `C-c C-r')."
  :type 'boolean
  :group 'dsh-emacs)

(defcustom dsh-emacs-poll-warn-delay 5.0
  "Delay before the fallback-polling notice is shown (seconds).
When opening a session or sending a message the WebSocket may still be
handshaking (locally measured to usually recover to realtime in 1~2 seconds),
so starting polling then is a normal transition and should not show a
\"not connected\" notice.  Only when polling has lasted longer than this
duration without the event stream being established is a one-time notice
shown that fallback mode was entered; the notice clears naturally once the
connection recovers.  Set to 0 to restore the old behavior (show the notice
immediately when polling starts)."
  :type 'number
  :group 'dsh-emacs)

(defcustom dsh-emacs-history-window 30
  "Size of the history window fetched when opening a session (`maxMessages'
semantics, counted in messages).
A larger window shows more of the conversation, but the raw events returned
by the server grow proportionally (in this package each message in a session
is ~hundreds of incremental events, so parse and GC costs rise linearly:
with the default no-argument window of ~30k raw events, the main thread needs
0.7s+ to parse them).  The default of 30 messages ≈ the latest 1~2 turns,
bringing the open cost down to 0.2~0.4s; increase it (e.g. 100) when a fuller
history is needed, at the cost of a slower open."
  :type 'integer
  :group 'dsh-emacs)

(defcustom dsh-emacs-history-refetch-max-rounds 6
  "Maximum number of load-gap re-fetches when opening a session.
Each round fetches `dsh-emacs-history-window' latest messages and renders
them incrementally, until the window stops advancing or the limit is reached;
the higher the limit, the lower the chance of missing intermediate increments
while the session is still producing events rapidly at open time (e.g. a
session mid-streaming), at the cost of more small parse chunks during the
open."
  :type 'integer
  :group 'dsh-emacs)

(defcustom dsh-emacs-show-reasoning t
  "Whether to show reasoning content.  Enabled by default, matching dsh web
(the web always shows the Think line).  Set to nil for a leaner transcript."
  :type 'boolean
  :group 'dsh-emacs)

(defcustom dsh-emacs-show-tool-calls t
  "Whether to show tool calls."
  :type 'boolean
  :group 'dsh-emacs)

(defcustom dsh-emacs-default-cwd default-directory
  "Default working directory for new sessions."
  :type 'directory
  :group 'dsh-emacs)

(defcustom dsh-emacs-default-model "deepseek-v4-flash-0731"
  "Default model name."
  :type 'string
  :group 'dsh-emacs)

(defcustom dsh-emacs-pin-input-to-bottom nil
  "Whether to show the editable prompt in a fixed bottom window.

When nil (default), the prompt and the replies live in the same buffer,
agent-shell style: the `❯' input line stays at the bottom of the transcript
and messages stream in above it.  When non-nil, a separate input window is
pinned below the transcript window."
  :type 'boolean
  :group 'dsh-emacs)

(defcustom dsh-emacs-input-window-height 4
  "Height of the fixed input window, measured in text lines."
  :type 'integer
  :group 'dsh-emacs)

(defcustom dsh-emacs-attach-media-types
  '("image/png" "image/jpeg" "image/webp" "image/gif")
  "Image media types accepted for session attachments.

The host validates every upload against this set (plus byte/pixel limits
of its own), so only files resolving to one of these types are sent."
  :type '(repeat string)
  :group 'dsh-emacs)

(defcustom dsh-emacs-input-history-length 50
  "Maximum number of submitted prompts kept for `M-p' / `M-n' recall."
  :type 'integer
  :group 'dsh-emacs)

;;; ---------------------------------------------------------------------------
;;;  内部变量
;;; ---------------------------------------------------------------------------

(defvar dsh-emacs--sessions nil
  "Cache of the session list.")

(defvar dsh-emacs--chat-buffers (make-hash-table :test 'equal)
  "Registry of session id -> live chat buffer.

Chat buffers are named `dsh-<list title>' (matching the session list, with
dsh prepended), and sessions with the same title need unique names, so a
buffer cannot be looked up by title; this table provides stable reuse and
renaming by session ID.")

(defvar dsh-emacs--workspaces nil
  "Cache of the workspace list.")

(defvar dsh-emacs--archived-sessions nil
  "Set of archived session IDs (hash table).")

(defvar dsh-emacs--current-session nil
  "Current session ID.")

(defvar dsh-emacs--current-buffer nil
  "Current chat buffer.")

(defvar dsh-emacs--tool-calls (make-hash-table :test 'equal)
  "Tool-call state table.")

(defvar dsh-emacs--activity-groups (make-hash-table :test 'equal)
  "Activity-group state table.")

(defvar-local dsh-emacs--input-marker nil
  "Marker for the start of the input area (buffer-local).")

(defvar-local dsh-emacs--pending-user-messages nil
  "Text of messages the user sent but that are not yet confirmed in session.history.")

(defvar dsh-emacs--poll-timer nil
  "Polling timer.")

(defvar-local dsh-emacs--poll-inflight nil
  "Whether the current buffer already has a history request in flight.")

(defvar-local dsh-emacs--history-refetch-rounds 0
  "How many bounded re-fetches the open of this buffer has issued.
The open closes the history/stream gap by repeatedly re-fetching the newest
window until it stops advancing or the round budget is spent.")

(defvar-local dsh-emacs--poll-warned nil
  "Whether the fallback-polling warning was already shown for this buffer.")

(defvar dsh-emacs--pinned-input-window nil
  "Window displaying the fixed input buffer.")

(defvar dsh-emacs--pinned-input-buffer nil
  "Buffer displayed in `dsh-emacs--pinned-input-window'.")

(defvar-local dsh-emacs--input-chat-buffer nil
  "Chat buffer mirrored by a dedicated input buffer, if any.")

(defvar-local dsh-emacs--buffer-session nil
  "Session ID corresponding to this buffer (buffer-local).")

(defvar-local dsh-emacs--transcript-input-overlay nil
  "Overlay hiding the transcript's internal input anchor when pinned.")

(defvar dsh-emacs--input-history nil
  "Prompts submitted with `dsh-emacs-send-or-stop', newest first.
Shared across chat buffers (session transcripts are volatile, the prompt
history is not).")

(defvar dsh-emacs--input-history-pos nil
  "Index into `dsh-emacs--input-history' while browsing with M-p/M-n.
nil means not browsing (the input shows what the user typed).")

(defvar dsh-emacs--input-history-pending nil
  "Input text saved before history browsing started, restored by M-n.")

;;; ---------------------------------------------------------------------------
;;;  RPC 客户端
;;; ---------------------------------------------------------------------------

(defun dsh-emacs--rpc-id ()
  "Generate a unique RPC request id."
  (format "emacs-%d-%d" (random 999999) (truncate (float-time))))

(defun dsh-emacs--wrap-request (method params)
  "Wrap METHOD and PARAMS into the DSH RPC envelope.
Returns a JSON string."
  (let ((envelope `((type . "client-request")
                    (rpcId . ,(dsh-emacs--rpc-id))
                    (method . ,method)
                    ;; dsh expects an object even for methods without params.
                    ;; An empty Elisp list is encoded as JSON null, so use an
                    ;; empty hash table to produce JSON {} instead.
                    (payload . ,(or params (make-hash-table))))))
    (json-encode envelope)))

(defun dsh-emacs--unwrap-response (response)
  "Unwrap a DSH RPC RESPONSE, returning (ok-p . value-or-error).
RESPONSE is the parsed JSON object from the server."
  (let* ((result (cdr (assq 'result response)))
         (ok (cdr (assq 'ok result))))
    ;; `json-read' represents JSON false as :json-false, which is non-nil
    ;; in Elisp.  Test the boolean explicitly instead of using `if ok'.
    (if (and ok (not (eq ok :json-false)))
        (cons t (cdr (assq 'value result)))
      (cons nil (cdr (assq 'error result))))))

(defun dsh-emacs--decode-response-body ()
  "Decode the current HTTP response body as UTF-8 in place.
`url-retrieve' may leave an application/json response in a unibyte buffer
when the server omits a charset parameter.  Parsing that buffer directly
turns Chinese and emoji into mojibake such as `ä½\240'."
  (unless enable-multibyte-characters
    (let ((body (decode-coding-string
                 (buffer-substring (point) (point-max)) 'utf-8)))
      (delete-region (point) (point-max))
      ;; A decoded multibyte string inserted into a unibyte buffer would be
      ;; encoded back to bytes.  Switch the response buffer first.
      (set-buffer-multibyte t)
      (insert body))))

(defun dsh-emacs--rpc-request (method params)
  "Send an RPC request to the dsh web service.
METHOD is the method name and PARAMS is the parameter alist.
Returns (ok-p . value) or nil."
  (let* ((url (format "%s/api/%s" dsh-emacs-base-url method))
         (json-data (dsh-emacs--wrap-request method params))
         (url-request-method "POST")
         (url-request-extra-headers '(("Content-Type" . "application/json")))
         (url-request-data (encode-coding-string json-data 'utf-8)))
    (condition-case err
        (with-current-buffer (url-retrieve-synchronously url)
          (goto-char (point-min))
          (re-search-forward "^$")
          (delete-region (point) (point-min))
          (dsh-emacs--decode-response-body)
          (goto-char (point-min))
          (let* ((response (json-read))
                 (unwrapped (dsh-emacs--unwrap-response response)))
            (kill-buffer)
            unwrapped))
      (error
       (message "RPC error: %s" (error-message-string err))
       (cons nil nil)))))

(defun dsh-emacs--rpc-async (method params callback)
  "Asynchronous RPC request.  CALLBACK receives (ok-p value-or-error)."
  (let* ((url (format "%s/api/%s" dsh-emacs-base-url method))
         (json-data (dsh-emacs--wrap-request method params))
         (url-request-method "POST")
         (url-request-extra-headers '(("Content-Type" . "application/json")))
         (url-request-data (encode-coding-string json-data 'utf-8))
         (callback-buffer (current-buffer)))
    ;; Keep progress messages out of the minibuffer.  In particular,
    ;; `Contacting host...' otherwise remains visible when a successful
    ;; callback does not emit a follow-up message.
    (url-retrieve url
                  (lambda (status)
                    ;; JSON decode of big history windows allocates heavily;
                    ;; profiler 实测默认窗口（~3 万原始事件）解析时 Automatic GC
                    ;; 占到 open 全程的 ~46%。动态放大 GC 阈值，把 GC 风暴推迟到
                    ;; 解析完成后一次性回收 —— 解析与回调在同一个动态作用域里。
                    (let ((gc-cons-threshold (* 64 1024 1024))
                          (gc-cons-percentage 0.6))
                      (if (plist-get status :error)
                          (progn
                            (message "RPC async error: %S" status)
                            (when (buffer-live-p callback-buffer)
                              (with-current-buffer callback-buffer
                                (funcall callback nil nil))))
                        (goto-char (point-min))
                        (re-search-forward "^$")
                        (delete-region (point) (point-min))
                        (dsh-emacs--decode-response-body)
                        (goto-char (point-min))
                        (let* ((response (json-read))
                               (unwrapped (dsh-emacs--unwrap-response response)))
                          (let ((ok (car unwrapped))
                                (value (cdr unwrapped)))
                            (kill-buffer)
                            (when (buffer-live-p callback-buffer)
                              (with-current-buffer callback-buffer
                                (funcall callback ok value))))))))
                  nil t)))

;;; ---------------------------------------------------------------------------
;;;  会话管理
;;; ---------------------------------------------------------------------------

(defun dsh-emacs--sequence-list (value)
  "Convert JSON VALUE, a list or vector, to a proper list.
JSON arrays are decoded as vectors by `json-read', while the UI iteration
helpers expect lists."
  (cond
   ((vectorp value) (append value nil))
   ((listp value) value)
   (t nil)))

(defun dsh-emacs--absolute-cwd (cwd)
  "Return CWD as an absolute path, falling back to the configured default."
  (expand-file-name (or cwd dsh-emacs-default-cwd)))

;; ---------------------------------------------------------------------------
;;  会话缓冲同步：命名与列表一致 + 工作区路径（default-directory）
;; ---------------------------------------------------------------------------

(defun dsh-emacs--chat-session-item (session-id)
  "Return the cached session item for SESSION-ID, or nil."
  (catch 'found
    (dolist (item dsh-emacs--sessions)
      (when (equal session-id (dsh-emacs--alist-state item "sessionId"))
        (throw 'found item)))))

(defun dsh-emacs--chat-title (session-id)
  "Display title for SESSION-ID, identical to the session list row, or nil."
  (let ((item (dsh-emacs--chat-session-item session-id)))
    (and item (dsh-emacs-session--display-title item))))

(defun dsh-emacs--chat-cwd (session-id)
  "Workspace path of SESSION-ID (the session's `cwd' from session.list),
or nil when the session is not in the cache."
  (let ((item (dsh-emacs--chat-session-item session-id)))
    (and item (dsh-emacs--alist-state item "cwd"))))

(defun dsh-emacs--sanitize-buffer-name (title)
  "Sanitize TITLE for use as a buffer name.

Mode-line string elements are `%'-expanded by the modeline renderer, so a
literal `%' inside a buffer name would be mis-rendered (e.g. swallow the
following character); it is replaced with the visually close full-width
`％'.  Line breaks are flattened to spaces."
  (string-trim
   (replace-regexp-in-string "%" "％"
     (replace-regexp-in-string "[\n\r]" " " title))))

(defun dsh-emacs--chat-buffer-name (session-id)
  "Base buffer name for SESSION-ID.

`dsh-<list title>' when the session list has a display title for the session
(so the modeline matches the list), otherwise `dsh: <session-id>' as the
historical fallback."
  (let ((title (dsh-emacs--chat-title session-id)))
    (if (and title (not (string-empty-p title)))
        (concat "dsh-" (dsh-emacs--sanitize-buffer-name title))
      (format "dsh: %s" session-id))))

(defun dsh-emacs--chat-buffer-untrack ()
  "Remove the current chat buffer from `dsh-emacs--chat-buffers' when killed."
  (when dsh-emacs--buffer-session
    (remhash dsh-emacs--buffer-session dsh-emacs--chat-buffers)))

(defun dsh-emacs--chat-buffer-sync (session-id)
  "Bring the live chat buffer of SESSION-ID in line with the session cache:
rename it to the current list title and set its buffer-local
`default-directory' to the session workspace, so commands like
`magit-status' start in the right project directory.
A numeric suffix is appended when another buffer already holds the name."
  (let ((buf (gethash session-id dsh-emacs--chat-buffers)))
    (when (and (buffer-live-p buf)
               (equal session-id
                      (buffer-local-value 'dsh-emacs--buffer-session buf)))
      (with-current-buffer buf
        (let ((name (dsh-emacs--chat-buffer-name session-id)))
          (unless (equal (buffer-name) name)
            (rename-buffer name t)))
        (let ((cwd (dsh-emacs--chat-cwd session-id)))
          (when (and cwd (not (string-empty-p cwd)))
            (setq-local default-directory
                        (file-name-as-directory (expand-file-name cwd)))))))))

(defun dsh-emacs--chat-buffers-sync-all ()
  "Re-sync every live chat buffer after the session cache changed.
Updates the mode-line name (list title) and the workspace directory."
  (maphash (lambda (session-id _buf)
             (dsh-emacs--chat-buffer-sync session-id))
           dsh-emacs--chat-buffers))

;;;###autoload
(defun dsh-emacs-list-sessions ()
  "Fetch the session list and refresh workspaces."
  (interactive)
  (dsh-emacs--rpc-async "session.list" nil
                        (lambda (ok value)
                          (if ok
                              (progn
                                ;; JSON arrays arrive as vectors; normalize
                                ;; them before the session list renderer uses
                                ;; `dolist'.
                                (setq dsh-emacs--sessions
                                      (dsh-emacs--sequence-list
                                       (cdr (assq 'items value))))
                                ;; 标题/工作区可能已漂移（自动摘要/重命名/
                                ;; 会话移动），同步所有存活聊天缓冲的名称与
                                ;; default-directory。
                                (dsh-emacs--chat-buffers-sync-all)
                                ;; Refresh workspaces in parallel so the
                                ;; session list can group by workspace.
                                (dsh-emacs-list-workspaces))
                            (message "Failed to fetch session list: %S" value)))))

;;;###autoload
(defun dsh-emacs-new-session (&optional cwd)
  "Create a new session.  CWD is the working directory."
  (interactive)
  (let ((cwd (dsh-emacs--absolute-cwd cwd)))
    (dsh-emacs--rpc-async "session.create"
                          `((cwd . ,cwd)
                            (model . ,dsh-emacs-default-model))
                          (lambda (ok value)
                            (if ok
                                (let ((session-id (cdr (assq 'sessionId value))))
                                  (dsh-emacs-open-session session-id))
                              (message "Failed to create session: %S" value))))))

(defun dsh-emacs--ensure-input-marker ()
  "Repair the chat input marker when it was lost, without touching content.
The prompt anchor is located by its face; the marker is re-created right
after the `❯ ' prompt so input sync and transcript rendering keep working."
  (when (and (fboundp 'dsh-emacs-render--input-anchor-pos)
             (or (null dsh-emacs--input-marker)
                 (not (and (markerp dsh-emacs--input-marker)
                           (eq (marker-buffer dsh-emacs--input-marker)
                               (current-buffer))))))
    (let ((anchor (dsh-emacs-render--input-anchor-pos)))
      (when anchor
        (setq dsh-emacs--input-marker
              (save-excursion
                (goto-char anchor)
                (forward-char 2)      ; skip "❯ "
                (point-marker)))))))

(defun dsh-emacs--hide-transcript-input ()
  "Hide the internal input anchor in the transcript buffer."
  (let* ((m (and dsh-emacs--input-marker
                 (markerp dsh-emacs--input-marker)
                 dsh-emacs--input-marker))
         (anchor-line
          (cond
           ((and m (eq (marker-buffer m) (current-buffer)))
            (save-excursion
              (goto-char (marker-position m))
              (line-beginning-position)))
           (t
            (dsh-emacs--ensure-input-marker)
            (if-let* ((new-marker dsh-emacs--input-marker)
                      (m2 (and (eq (marker-buffer new-marker) (current-buffer))
                               new-marker)))
                (save-excursion
                  (goto-char (marker-position m2))
                  (line-beginning-position))
              (when (fboundp 'dsh-emacs-render--input-anchor-pos)
                (dsh-emacs-render--input-anchor-pos)))))))
    (when anchor-line
      (when (overlayp dsh-emacs--transcript-input-overlay)
        (delete-overlay dsh-emacs--transcript-input-overlay))
      (let ((overlay (make-overlay anchor-line (point-max) nil t t)))
        (overlay-put overlay 'invisible t)
        (overlay-put overlay 'priority 100)
        (setq dsh-emacs--transcript-input-overlay overlay)))))

(defun dsh-emacs--sync-pinned-input ()
  "Mirror the dedicated input buffer into its transcript anchor."
  (when (and dsh-emacs--input-chat-buffer
             (buffer-live-p dsh-emacs--input-chat-buffer)
             dsh-emacs--input-marker
             (markerp dsh-emacs--input-marker)
             (marker-buffer dsh-emacs--input-marker))
    (let ((text (dsh-emacs--get-input))
          (chat dsh-emacs--input-chat-buffer))
      (with-current-buffer chat
        (dsh-emacs--ensure-input-marker)
        (when (and dsh-emacs--input-marker
                   (markerp dsh-emacs--input-marker)
                   (eq (marker-buffer dsh-emacs--input-marker) (current-buffer)))
          (let ((inhibit-read-only t))
            (delete-region dsh-emacs--input-marker (dsh-emacs--input-end))
            (goto-char dsh-emacs--input-marker)
            (insert text)
            ;; Keep the anchor on its own line so the editable region is never
            ;; the last line of the buffer: message insertion above the prompt
            ;; must always stay above it, and `point-max' fallbacks can never
            ;; land inside the input area.
            (let ((footer-start (and dsh-emacs--footer-overlay
                                     (overlay-start dsh-emacs--footer-overlay))))
              (when (and footer-start
                         (> footer-start (point-min))
                         (not (eq (char-before footer-start) ?\n)))
                (goto-char footer-start)
                (insert "\n")))
            (dsh-emacs--hide-transcript-input)))))))

(defun dsh-emacs--lock-cursor-to-input ()
  "In inline mode, prevent the cursor from moving below the input line.\n
Moving up into the read-only transcript to read history is allowed; only when\nmoving down past the end of the input area is the cursor clamped back to the\nend of the input area (the writable region after `❯ ')."
  (when (and (not dsh-emacs-pin-input-to-bottom)
             (buffer-live-p dsh-emacs--current-buffer)
             (eq (current-buffer) dsh-emacs--current-buffer))
    (dsh-emacs--ensure-input-marker)
    (when (and dsh-emacs--input-marker
               (markerp dsh-emacs--input-marker)
               (eq (marker-buffer dsh-emacs--input-marker) (current-buffer)))
      (let* ((marker-pos (marker-position dsh-emacs--input-marker))
             (input-end (max marker-pos (dsh-emacs--input-end))))
        (when (> (point) input-end)
          (goto-char input-end))))))

(defun dsh-emacs--route-typing-to-input ()
  "When about to type or edit while point is in the read-only region, first\nmove the cursor back to the input area after `❯ '.\n
Used with `dsh-emacs--reveal-input-when-typing': typing directly in the\nread-only area would trigger `text-read-only'; this moves point into the\ninput area before the command runs, so typing no longer errors\nand the input area scrolls into view automatically."
  (when (and (not dsh-emacs-pin-input-to-bottom)
             (buffer-live-p dsh-emacs--current-buffer)
             (eq (current-buffer) dsh-emacs--current-buffer)
             (memq this-command
                   '(self-insert-command
                     delete-backward-char
                     delete-forward-char
                     backward-delete-char-untabify
                     dsh-emacs-delete-input
                     yank yank-pop))
             dsh-emacs--input-marker
             (markerp dsh-emacs--input-marker)
             (eq (marker-buffer dsh-emacs--input-marker) (current-buffer))
             (< (point) (marker-position dsh-emacs--input-marker)))
    (goto-char (marker-position dsh-emacs--input-marker))))

(defun dsh-emacs--reveal-input-when-typing ()
  "Immediately scroll the window to the input area when typing (self-insert /\nediting commands).\n
When the input line is not visible because the window was scrolled up to\nread history, starting to type scrolls the input line\nback to the bottom of the window, so the `❯ ' line being typed is visible."
  (when (and (not dsh-emacs-pin-input-to-bottom)
             (buffer-live-p dsh-emacs--current-buffer)
             (eq (current-buffer) dsh-emacs--current-buffer)
             (window-live-p (get-buffer-window (current-buffer) t))
             (memq this-command
                   '(self-insert-command
                     delete-backward-char
                     delete-forward-char
                     backward-delete-char-untabify
                     dsh-emacs-delete-input
                     yank yank-pop))
             dsh-emacs--input-marker
             (markerp dsh-emacs--input-marker)
             (eq (marker-buffer dsh-emacs--input-marker) (current-buffer))
             (>= (point) (marker-position dsh-emacs--input-marker)))
    (let ((input-pos (marker-position dsh-emacs--input-marker)))
      (unless (pos-visible-in-window-p input-pos (selected-window))
        (save-excursion
          (goto-char input-pos)
          (recenter -1))))))

(defun dsh-emacs--unpin-input-window ()
  "Remove the dedicated input window and its hidden transcript anchor."
  (when (buffer-live-p dsh-emacs--pinned-input-buffer)
    (with-current-buffer dsh-emacs--pinned-input-buffer
      (remove-hook 'post-command-hook #'dsh-emacs--sync-pinned-input t)))
  (when (window-live-p dsh-emacs--pinned-input-window)
    (delete-window dsh-emacs--pinned-input-window))
  (when (buffer-live-p dsh-emacs--pinned-input-buffer)
    (kill-buffer dsh-emacs--pinned-input-buffer))
  (when (buffer-live-p dsh-emacs--current-buffer)
    (with-current-buffer dsh-emacs--current-buffer
      (when (overlayp dsh-emacs--transcript-input-overlay)
        (delete-overlay dsh-emacs--transcript-input-overlay)
        (setq dsh-emacs--transcript-input-overlay nil))))
  (setq dsh-emacs--pinned-input-window nil
        dsh-emacs--pinned-input-buffer nil))

(defun dsh-emacs--setup-pinned-input-window ()
  "Create a fixed bottom input window for the current chat buffer."
  (when (and dsh-emacs-pin-input-to-bottom
             (buffer-live-p dsh-emacs--current-buffer))
    (dsh-emacs--unpin-input-window)
    (let ((chat dsh-emacs--current-buffer)
          (chat-window (get-buffer-window dsh-emacs--current-buffer t)))
      (when (and (window-live-p chat-window)
                 (> (window-body-height chat-window)
                    (+ (max 2 dsh-emacs-input-window-height) 3)))
        (let ((input-buffer
               (get-buffer-create
                (format "*dsh-input: %s*" dsh-emacs--current-session))))
          (with-current-buffer input-buffer
            (fundamental-mode)
            (use-local-map (symbol-value 'dsh-emacs-mode-map))
            (setq-local truncate-lines nil
                        word-wrap t
                        dsh-emacs--input-chat-buffer chat)
            ;; 复用聊天缓冲的工作区路径：从输入窗口启动 magit 等同样
            ;; 定位到会话项目目录。
            (setq-local default-directory
                        (with-current-buffer chat default-directory))
            (let ((inhibit-read-only t))
              (erase-buffer)
              (insert (propertize "❯ " 'face 'dsh-emacs-input-prompt-face))
              (put-text-property (point-min) (point) 'read-only t)
              (put-text-property (point-min) (point)
                                 'front-sticky '(read-only))
              (put-text-property (point-min) (point)
                                 'rear-nonsticky '(read-only))
              (setq dsh-emacs--input-marker (point-marker)))
            (add-hook 'post-command-hook #'dsh-emacs--sync-pinned-input nil t)
              ;; 输入窗同样不落盘：关闭/销毁时不提示保存
              (add-hook 'kill-buffer-query-functions
                        #'dsh-emacs--chat-buffer-clear-modified nil t)
              (add-hook 'after-change-functions
                        #'dsh-emacs--chat-buffer-keep-clean nil t))
          (select-window chat-window)
          (let ((input-window
                 (split-window chat-window
                               (- (max 2 dsh-emacs-input-window-height))
                               'below)))
            (set-window-buffer input-window input-buffer)
            ;; `below' should create the input window at the bottom.  Some
            ;; window managers / existing split layouts can nevertheless
            ;; return the two windows in the opposite physical order; make
            ;; the placement explicit so the prompt never appears above the
            ;; transcript.
            (let ((actual-input-window input-window))
              (when (< (nth 1 (window-edges input-window))
                       (nth 1 (window-edges chat-window)))
                (set-window-buffer input-window chat)
                (set-window-buffer chat-window input-buffer)
                (setq actual-input-window chat-window))
              (setq dsh-emacs--pinned-input-buffer input-buffer
                    dsh-emacs--pinned-input-window actual-input-window)
              (dsh-emacs--hide-transcript-input)
              (select-window actual-input-window)
              (goto-char (with-current-buffer input-buffer
                           dsh-emacs--input-marker)))))))))

;;;###autoload
(defun dsh-emacs-open-session (session-id)
  "Open session SESSION-ID."
  (interactive)
  (dsh-emacs--unpin-input-window)
  (dsh-emacs-events-disconnect dsh-emacs--current-buffer)
  (setq dsh-emacs--current-session session-id)
  (let* ((existing (gethash session-id dsh-emacs--chat-buffers))
         (buf (if (and existing (buffer-live-p existing))
                  existing
                ;; 首次打开，或缓冲已被杀掉：用 `dsh-<列表标题>' 作为名称，
                ;; 被占用时自动追加 <N> 后缀保证唯一（同标题会话并存）。
                (get-buffer-create
                 (generate-new-buffer-name
                  (dsh-emacs--chat-buffer-name session-id))))))
    (puthash session-id buf dsh-emacs--chat-buffers)
    (setq dsh-emacs--current-buffer buf)
    (with-current-buffer buf
      (setq-local dsh-emacs--buffer-session session-id)
      ;; 缓存可能已漂移（自动摘要/重命名/换工作区）：对齐列表标题，并把
      ;; 缓冲的 default-directory 指向会话工作区（magit 等按此定位项目）。
      ;; 必须在 setq-local 之后调用：sync 的守卫要求 buffer-session 匹配，
      ;; 首次打开的缓冲此前还没有这个局部变量（否则会静默跳过）。
      (dsh-emacs--chat-buffer-sync session-id)
      (dsh-emacs-mode)
      (dsh-emacs-footer-setup)
      (dsh-emacs-footer-set-model dsh-emacs-default-model)
      ;; 思考预设（agentPreset）来自会话列表缓存；缺失时补拉一次 session.list。
      (dsh-emacs--link-session-preset session-id)
      ;; Reopening must re-render: `dsh-emacs--anchor-seq' gates the seq
      ;; filter in `dsh-emacs-render-history-events', and a reused buffer
      ;; keeps the previous maximum, which would filter out the freshly
      ;; fetched history (and with it the usage/model feed) entirely.
      (setq dsh-emacs--anchor-seq 0)
      ;; Footer setup appends its anchor newline at point-max.  Return point
      ;; to the editable prompt so the cursor stays on the `❯' line.
      (goto-char dsh-emacs--input-marker)
      ;; Connect before loading history.  While the history page loads, mux
      ;; replay events for this session are dropped (see
      ;; `dsh-emacs-events--dispatch-json') and recovered by one bounded
      ;; re-fetch at the end of `dsh-emacs--load-history', so no event can
      ;; fall into a history/stream hand-off gap.
      (setq dsh-emacs--event-history-loading t)
      (dsh-emacs-events-connect dsh-emacs--current-buffer)
      (dsh-emacs--load-history session-id))
    (pop-to-buffer dsh-emacs--current-buffer)
    (dsh-emacs--setup-pinned-input-window)))

(defun dsh-emacs--completing-session-id (prompt)
  "Read a session id with completion against the cached session list.
Choices show the display title (like the list); the returned value is
always the session id."
  (let* ((entries (mapcar (lambda (s)
                            (let ((id (or (alist-get 'sessionId s) "")))
                              (cons (format "%-30s  %s"
                                            (or (dsh-emacs--chat-title id) id)
                                            id)
                                    id)))
                          dsh-emacs--sessions))
         (picked (completing-read prompt entries nil t)))
    (cdr (assoc picked entries))))

;;;###autoload
(defun dsh-emacs-fork-session (session-id)
  "Fork SESSION-ID into a new child session that inherits its history.
The child starts from the session's latest state (`session.fork' without
an explicit seq); after the RPC confirms, the list refreshes and the child
buffer opens with the same workspace path."
  (interactive (list (dsh-emacs--completing-session-id "Fork session: ")))
  (dsh-emacs--rpc-async "session.fork"
                        `((sessionId . ,session-id))
                        (lambda (ok value)
                          (if (not ok)
                              (message "Failed to fork session: %S" value)
                            (let ((child-id (cdr (assq 'sessionId value))))
                              (unless child-id
                                (user-error "session.fork returned no sessionId"))
                              (dsh-emacs-list-sessions)
                              (message "Forked %s -> %s" session-id child-id)
                              (dsh-emacs-open-session child-id))))))

(defun dsh-emacs--session-preset (session-id)
  "Return the agentPreset cached for SESSION-ID, or nil when unknown."
  (catch 'found
    (dolist (item dsh-emacs--sessions)
      (when (equal session-id (dsh-emacs--alist-state item "sessionId"))
        (throw 'found (dsh-emacs--alist-state item "agentPreset"))))))

(defun dsh-emacs--link-session-preset (session-id)
  "Fill the footer thinking preset for SESSION-ID into the mode line.
Uses the cached session list when possible; otherwise refreshes
`session.list' once and picks the preset from the response.  SAFE outside a
chat buffer (the RPC callback runs in the buffer that called this)."
  (let ((preset (dsh-emacs--session-preset session-id)))
    (if preset
        (dsh-emacs-footer-set-effort preset)
      (dsh-emacs--rpc-async "session.list" nil
                            (lambda (ok value)
                              (when ok
                                (let ((items (dsh-emacs--sequence-list
                                              (cdr (assq 'items value)))))
                                  ;; 新会话首次打开时缓存里没有该会话：顺带
                                  ;; 更新整个缓存，让缓冲名（`dsh-<标题>'）
                                  ;; 与工作区（default-directory）也一并取得。
                                  (setq dsh-emacs--sessions items)
                                  (dsh-emacs--chat-buffers-sync-all)
                                  (catch 'found
                                    (dolist (item items)
                                      (when (equal session-id
                                                   (dsh-emacs--alist-state
                                                    item "sessionId"))
                                        (dsh-emacs-footer-set-effort
                                         (dsh-emacs--alist-state
                                          item "agentPreset"))
                                        (throw 'found t)))))))))))

(defun dsh-emacs--load-history (session-id)
  "Load the session history and render it.

On the first open the mux replays globally (the current protocol has no
baseline-sync parameter; large sessions can reach 500k+ raw events).  Events
arriving while loading are dropped directly by
`dsh-emacs-events--dispatch-json' (no more queueing/sorting/flush — that used
to be the source of multi-second stalls on every open).  Once the history
page (`dsh-emacs-history-window' messages, sized to avoid parse/GC storms on
large windows) has been rendered, `dsh-emacs--refetch-history' re-fetches the
same window in a small loop, incrementally rendering by anchor until the
window stops growing, covering the load gap; `dsh-emacs--event-history-loading'
is then cleared and the event stream resumes normal delivery."
  (let ((chat-buffer dsh-emacs--current-buffer))
    (setq dsh-emacs--history-refetch-rounds 0)
    (dsh-emacs--rpc-async "session.history"
                          `((sessionId . ,session-id)
                            (maxMessages . ,dsh-emacs-history-window))
                          (lambda (ok value)
                            (if ok
                                (when (buffer-live-p chat-buffer)
                                  (with-current-buffer chat-buffer
                                    ;; Use the render module's batch function
                                    ;; which handles [{event: ...}] format.
                                    (dsh-emacs-render-history-events
                                     (dsh-emacs--sequence-list
                                      (cdr (assq 'events value)))
                                     nil)
                                    ;; 补拉：覆盖装载期间被丢弃的新事件，
                                    ;; 直到窗口稳定（见下）。
                                    (dsh-emacs--refetch-history
                                     session-id chat-buffer)))
                              (when (buffer-live-p chat-buffer)
                                (with-current-buffer chat-buffer
                                  (setq dsh-emacs--event-history-loading nil)))
                              (message "Failed to load history: %S" value))))))

(defun dsh-emacs--refetch-history (session-id chat-buffer)
  "Re-fetch one history window, covering event-stream increments dropped
during loading.
Each fetch pulls `dsh-emacs-history-window' latest messages and renders them
incrementally by anchor; as long as the window keeps advancing (a running
turn keeps producing events) polling continues, for at most
`dsh-emacs-history-refetch-max-rounds' rounds, after which
`dsh-emacs--event-history-loading' is cleared so the event stream resumes
realtime delivery (increments after that moment are covered by the async
windows/realtime stream).
The per-round cost is proportional to the window size (a ~0.2~0.4s chunk by
default), far smaller than a full parse of 30k raw events."
  (when (< dsh-emacs--history-refetch-rounds dsh-emacs-history-refetch-max-rounds)
    (cl-incf dsh-emacs--history-refetch-rounds)
    (dsh-emacs--rpc-async "session.history"
                          `((sessionId . ,session-id)
                            (maxMessages . ,dsh-emacs-history-window))
                          (lambda (ok value)
                            (when (buffer-live-p chat-buffer)
                              (with-current-buffer chat-buffer
                                (let ((advanced (and ok
                                                     (dsh-emacs-render-history-events
                                                      (dsh-emacs--sequence-list
                                                       (cdr (assq 'events value)))
                                                      t))))
                                  (if (and ok (> advanced 0))
                                      (dsh-emacs--refetch-history
                                       session-id chat-buffer)
                                    (setq dsh-emacs--event-history-loading
                                          nil)))))))))

(defun dsh-emacs-delete-session (session-id)
  "Delete session SESSION-ID."
  (interactive)
  (dsh-emacs--rpc-async "session.delete"
                        `((sessionId . ,session-id))
                        (lambda (ok value)
                          (if ok
                              (progn
                                (dsh-emacs-list-sessions)
                                (message "Session deleted"))
                            (message "Failed to delete: %S" value)))))

(defun dsh-emacs-rename-session (session-id new-title)
  "Rename session."
  (interactive)
  (dsh-emacs--rpc-async "session.update"
                        `((sessionId . ,session-id)
                          (title . ,new-title))
                        (lambda (ok value)
                          (if ok
                              (progn
                                (dsh-emacs-list-sessions)
                                (message "Session renamed"))
                            (message "Failed to rename: %S" value)))))

;;; ---------------------------------------------------------------------------
;;;  工作区管理
;;; ---------------------------------------------------------------------------

(defun dsh-emacs--normalize-archived (archived)
  "Normalize ARCHIVED (JSON array) into a hash table of session ids."
  (let ((table (make-hash-table :test 'equal)))
    (dolist (id (dsh-emacs--sequence-list archived))
      (puthash id t table))
    table))

;;;###autoload
(defun dsh-emacs-list-workspaces ()
  "Fetch the workspace list."
  (interactive)
  (dsh-emacs--rpc-async "workspace.list" nil
                        (lambda (ok value)
                          (when ok
                            (setq dsh-emacs--workspaces
                                  (dsh-emacs--sequence-list
                                   (cdr (assq 'items value))))
                            (setq dsh-emacs--archived-sessions
                                  (dsh-emacs--normalize-archived
                                   (cdr (assq 'archivedSessionIds value)))))
                          ;; Always re-render the session list so grouping
                          ;; reflects the latest workspace data (or falls back
                          ;; to the ungrouped view when the fetch failed).
                          (when (get-buffer dsh-emacs-sessions-buffer)
                            (with-current-buffer dsh-emacs-sessions-buffer
                              (dsh-emacs-session--render))))))

;;;###autoload
(defun dsh-emacs-create-workspace (path)
  "Create a workspace.  PATH is the path of an existing directory."
  (interactive "DWorkspace directory: ")
  (dsh-emacs--rpc-async "workspace.create"
                        `((path . ,(expand-file-name path)))
                        (lambda (ok value)
                          (if ok
                              (progn
                                (dsh-emacs-list-workspaces)
                                (message "Workspace created"))
                            (message "Failed to create workspace: %S" value)))))

;;;###autoload
(defun dsh-emacs-rename-workspace (workspace-id new-title)
  "Rename workspace."
  (interactive)
  (dsh-emacs--rpc-async "workspace.rename"
                        `((workspaceId . ,workspace-id)
                          (title . ,new-title))
                        (lambda (ok value)
                          (if ok
                              (progn
                                (dsh-emacs-list-workspaces)
                                (message "Workspace renamed"))
                            (message "Failed to rename: %S" value)))))

;;;###autoload
(defun dsh-emacs-delete-workspace (workspace-id)
  "Delete workspace.  The directory and session logs are not deleted."
  (interactive)
  (dsh-emacs--rpc-async "workspace.delete"
                        `((workspaceId . ,workspace-id))
                        (lambda (ok value)
                          (if ok
                              (progn
                                (dsh-emacs-list-workspaces)
                                (message "Workspace deleted"))
                            (message "Failed to delete: %S" value)))))

;;; ---------------------------------------------------------------------------
;;;  对话模式
;;; ---------------------------------------------------------------------------

(defvar dsh-emacs-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'dsh-emacs-send-or-stop)
    (define-key map (kbd "C-c C-r") #'dsh-emacs-refresh)
    (define-key map (kbd "C-c C-l") #'dsh-emacs-list-sessions-display)
    (define-key map (kbd "C-c C-w") #'dsh-emacs-copy-transcript)
    (define-key map (kbd "C-c C-f") #'dsh-emacs-footer-toggle)
    (define-key map (kbd "C-c C-k") #'dsh-emacs-copy-code-block)
    (define-key map (kbd "C-c C-a") #'dsh-emacs-attach-file)
    (define-key map (kbd "C-c C-m") #'dsh-emacs-select-model)
    (define-key map (kbd "M-p") #'dsh-emacs-input-history-back)
    (define-key map (kbd "M-n") #'dsh-emacs-input-history-forward)
    (define-key map [drag-n-drop] #'dsh-emacs--dnd-attach)
    map)
  "Keymap for chat mode.")

(defun dsh-emacs--chat-buffer-clear-modified ()
  "`kill-buffer-query-functions' hook: drop the modified flag so killing a
dsh chat buffer never prompts to save a session transcript (which is never
persisted to disk).  Returns t to allow the kill: a query function that
returns nil silently blocks `kill-buffer' (the docstring says \"if any of
them returns nil, the buffer is not killed\")."
  (set-buffer-modified-p nil)
  t)

(defun dsh-emacs--chat-buffer-keep-clean (&rest _)
  "`after-change-functions' hook: keep the transcript buffer unmodified.
The buffer is a live session view that is never saved, so every programmatic
insert (history render, streaming, input sync) must leave it unmodified:
some tab/window managers query `buffer-modified-p' before closing a buffer
and prompt \"save?\".  Clearing is cheap (a flag), not a content change."
  (set-buffer-modified-p nil))

(define-derived-mode dsh-emacs-mode fundamental-mode "DSH"
  "DeepSeek Harness chat mode.
\\{dsh-emacs-mode-map}"
  (setq buffer-read-only nil)
  (setq truncate-lines nil)
  (setq word-wrap t)
  ;; The pinned layout hides the transcript's internal input anchor while
  ;; exposing the same editable text in the dedicated bottom window.
  (setq-local buffer-invisibility-spec '(t))
  (setq-local line-spacing 0.15)
  (buffer-disable-undo)
  (setq-local comment-start "// ")
  (setq-local comment-end "")

  ;; Footer/mode-line 拼接由 `dsh-emacs-footer-setup' 完成（会话创建时调用），
  ;; 这里不再覆盖 mode-line-format，保留用户的默认 modeline。

  ;; 重置渲染状态
  (add-hook 'kill-buffer-hook #'dsh-emacs-events-disconnect nil t)
  (add-hook 'kill-buffer-hook #'dsh-emacs--chat-buffer-untrack nil t)
  ;; 聊天缓冲永不"modified"：会话转录不落盘，关闭时不应提示保存
  (add-hook 'kill-buffer-query-functions #'dsh-emacs--chat-buffer-clear-modified nil t)
  (add-hook 'after-change-functions #'dsh-emacs--chat-buffer-keep-clean nil t)
  ;; 打开会话前把光标锁定输入区（`❯ ' 之后）
  (add-hook 'post-command-hook #'dsh-emacs--lock-cursor-to-input nil t)
  ;; 输入/编辑命令前若点在只读区，先挪回输入区
  (add-hook 'pre-command-hook #'dsh-emacs--route-typing-to-input nil t)
  ;; 输入时立即滚动到输入区
  (add-hook 'post-command-hook #'dsh-emacs--reveal-input-when-typing nil t)
  (setq dsh-emacs--tool-calls (make-hash-table :test 'equal))
  (setq dsh-emacs--activity-groups (make-hash-table :test 'equal))
  (setq dsh-emacs--pending-user-messages nil
        dsh-emacs--poll-inflight nil
        dsh-emacs--event-ready nil
        dsh-emacs--event-history-loading nil)
  (dsh-emacs-events--watchdog-stop)
  (dsh-emacs-events--health-stop)
  (setq dsh-emacs--ws-last-event-time nil
        dsh-emacs--ws-last-probe-time nil
        dsh-emacs--ws-probe-inflight nil)
  (dsh-emacs-render--reset-tool-tracking)

  ;; 初始化输入区域
  (dsh-emacs--setup-input-area))

(defun dsh-emacs--setup-input-area ()
  "Set up the input area (a read-only transcript plus a writable input box).
All welcome text is marked read-only; only the region after ❯ is writable."
  (let ((inhibit-read-only t))
    ;; 清空缓冲
    (erase-buffer)
    ;; 添加简洁的聊天头部和操作提示
    (let ((welcome-start (point)))
      (insert (propertize "dsh  " 'face 'dsh-emacs-accent-face))
      (insert (propertize "DeepSeek Harness\n" 'face 'dsh-emacs-header-face))
      (insert (propertize "C-c C-c send   ·   C-c C-r refresh   ·   C-c C-l session list\n\n"
                          'face 'dsh-emacs-hint-face))
      ;; 输入提示符
      (insert (propertize "❯ " 'face 'dsh-emacs-input-prompt-face))
      ;; 把整个欢迎区域标记为 read-only（使用 text property 而非 buffer-read-only）
      (put-text-property welcome-start (point) 'read-only t)
      (put-text-property welcome-start (point) 'front-sticky '(read-only))
      ;; Do not let the read-only property leak into the input inserted at
      ;; the end of the prompt.  Text properties are sticky by default, so
      ;; inserting immediately after the prompt would otherwise signal
      ;; `text-read-only' even though the insertion point itself has no
      ;; `read-only' property.
      (put-text-property welcome-start (point) 'rear-nonsticky '(read-only)))
    ;; 标记输入开始位置（marker 会自动跟随文本插入/删除）
    (setq dsh-emacs--input-marker (point-marker))))

(defun dsh-emacs--ensure-input-area ()
  "Ensure the input area exists and point is at the right position."
  (unless (and dsh-emacs--input-marker (marker-buffer dsh-emacs--input-marker))
    (dsh-emacs--setup-input-area))
  (goto-char dsh-emacs--input-marker))

(defun dsh-emacs--busy-p ()
  "Return non-nil when this chat buffer (or its pinned input) is generating.
Consults the same buffer-local flag that drives the mode-line spinner; when
called from the fixed bottom input window, falls back to the flag of the
chat buffer it mirrors."
  (or (and (boundp 'dsh-emacs--ml-busy) dsh-emacs--ml-busy)
      (and (boundp 'dsh-emacs--input-chat-buffer)
           dsh-emacs--input-chat-buffer
           (buffer-live-p dsh-emacs--input-chat-buffer)
           (buffer-local-value 'dsh-emacs--ml-busy
                               dsh-emacs--input-chat-buffer))))

(defun dsh-emacs--interrupt-turn ()
  "Interrupt the running turn via `session.cancel'.

The server stops the agent mid-flight; the partial reply stays in the
transcript and `turn/end' arrives normally, which clears the spinner."
  (let ((session-id dsh-emacs--current-session))
    (when (null session-id)
      (user-error "No session is open"))
    (dsh-emacs--rpc-async "session.cancel"
                          `((sessionId . ,session-id))
                          (lambda (ok value)
                            (if ok
                                (progn
                                  (dsh-emacs--ml-busy-set nil)
                                  (message "⏸ Turn interrupted"))
                              (message "Failed to interrupt: %S" value))))))

(defun dsh-emacs-send-or-stop ()
  "Send the input as a message, or interrupt the running turn.

While a turn is executing (the mode-line spinner is lit) another
`C-c C-c' issues `session.cancel' instead of queueing a second message:
the agent stops, the partial reply is kept in the transcript.  When idle,
the text after the `❯ ' prompt is submitted."
  (interactive)
  (if (dsh-emacs--busy-p)
      (dsh-emacs--interrupt-turn)
    (let ((input (dsh-emacs--get-input)))
      (if (string-empty-p (string-trim input))
          (message "Please enter a message")
        (dsh-emacs--submit-prompt input)))))

(defun dsh-emacs--input-end ()
  "Return the end of editable input, before the footer separator newline."
  (let ((footer-start (and (boundp 'dsh-emacs--footer-overlay)
                           dsh-emacs--footer-overlay
                           (overlay-start dsh-emacs--footer-overlay))))
    (if (and footer-start
             (> footer-start (point-min))
             (eq (char-before footer-start) ?\n))
        (1- footer-start)
      (point-max))))

(defun dsh-emacs--get-input ()
  "Get the text in the input area, excluding the footer newline."
  (when (and dsh-emacs--input-marker (marker-buffer dsh-emacs--input-marker))
    (buffer-substring-no-properties dsh-emacs--input-marker
                                    (dsh-emacs--input-end))))

(defun dsh-emacs--clear-input ()
  "Clear the input area, keeping the footer newline."
  (when (and dsh-emacs--input-marker (marker-buffer dsh-emacs--input-marker))
    (let ((inhibit-read-only t))
      (delete-region dsh-emacs--input-marker (dsh-emacs--input-end))
      (goto-char dsh-emacs--input-marker))))

(defun dsh-emacs--valid-iana-time-zone-p (zone)
  "Return non-nil when ZONE names an installed IANA timezone."
  (and (stringp zone)
       (not (string-empty-p zone))
       (or (string= zone "UTC")
           (and (not (string-prefix-p "/" zone))
                (not (string-match-p "\\.\\." zone))
                (or (file-exists-p (expand-file-name zone "/usr/share/zoneinfo"))
                    (file-exists-p (expand-file-name zone
                                                      "/var/db/timezone/zoneinfo")))))))

(defun dsh-emacs--local-iana-time-zone ()
  "Return the IANA name linked by /etc/localtime, or nil."
  (condition-case nil
      (let ((localtime (file-truename "/etc/localtime")))
        (when (string-match "/zoneinfo/\\(.+\\)$" localtime)
          (match-string 1 localtime)))
    (error nil)))

(defun dsh-emacs--client-time-zone ()
  "Return a valid IANA timezone string for the prompt payload.
Abbreviations such as `CST' are deliberately rejected because they are
ambiguous and are not accepted by the dsh API."
  (let ((env-zone (getenv "TZ")))
    (cond
     ((dsh-emacs--valid-iana-time-zone-p env-zone) env-zone)
     ((let ((local-zone (dsh-emacs--local-iana-time-zone)))
        (when (dsh-emacs--valid-iana-time-zone-p local-zone)
          local-zone)))
     (t "UTC"))))

(defun dsh-emacs--push-input-history (text)
  "Record TEXT in the shared input history, dropping consecutive repeats."
  (when (and text (not (string-empty-p text)))
    (unless (string= text (car dsh-emacs--input-history))
      (push text dsh-emacs--input-history))
    (let ((len dsh-emacs-input-history-length))
      (when (> (length dsh-emacs--input-history) len)
        (setcdr (nthcdr (1- len) dsh-emacs--input-history) nil)))))

(defun dsh-emacs--submit-prompt (message &optional images)
  "Submit MESSAGE (a plain string) to the current session.

IMAGES, when given, is a list of wire-ready attachment alists
\((mediaType . M) (data . B64) (name . N)); they ride along as the
`images' payload of `session.prompt' so the model sees them immediately.
On acceptance the message is echoed into the transcript (when non-empty),
the running spinner lights up, and the watchdog starts."
  (let ((input-buffer (current-buffer))
        (chat-buffer dsh-emacs--current-buffer)
        (payload `((sessionId . ,dsh-emacs--current-session)
                   (mode . "queue")
                   (content . [((type . "text") (text . ,message))])
                   (clientTimeZone . ,(dsh-emacs--client-time-zone)))))
    (when images
      (setq payload (append payload (list (cons 'images images)))))
    (dsh-emacs--rpc-async "session.prompt" payload
                          (lambda (ok value)
                            (if ok
                                (progn
                                  (dsh-emacs--push-input-history message)
                                  (setq dsh-emacs--input-history-pos nil
                                        dsh-emacs--input-history-pending nil)
                                  ;; Render immediately in the transcript even
                                  ;; when the request originated in the fixed
                                  ;; bottom input buffer.
                                  (when (buffer-live-p chat-buffer)
                                    (with-current-buffer chat-buffer
                                      (unless (string-empty-p message)
                                        (setq dsh-emacs--pending-user-messages
                                              (append dsh-emacs--pending-user-messages
                                                      (list message))))
                                      ;; dsh is now executing: light up the
                                      ;; mode-line running spinner.
                                      (dsh-emacs--ml-busy-set t)
                                      ;; Confirm the stream keeps delivering
                                      ;; while this turn runs.
                                      (dsh-emacs-events--watchdog-start)
                                      (unless (string-empty-p message)
                                        (dsh-emacs--render-user-message message))
                                      (dsh-emacs-render--follow-stream)
                                      (unless dsh-emacs--event-ready
                                        (dsh-emacs--start-polling))))
                                  (when (buffer-live-p input-buffer)
                                    (with-current-buffer input-buffer
                                      (dsh-emacs--clear-input)
                                      (dsh-emacs--sync-pinned-input))))
                              (message "Failed to send: %S" value))))))

;;; ---------------------------------------------------------------------------
;;;  附件 / 模型选择 / 输入历史
;;; ---------------------------------------------------------------------------

(defun dsh-emacs--file-attachment (file)
  "Read FILE into a wire-ready image attachment alist, or nil.

The dsh host accepts base64 image uploads inline in `session.prompt'
(media type, bytes and pixel limits are enforced server-side)."
  (let* ((media (ignore-errors
                  (mailcap-file-name-to-mime-type
                   (file-name-nondirectory file))))
         (supported (and media (member media dsh-emacs-attach-media-types))))
    (when (and supported (file-readable-p file))
      (let ((bytes (with-temp-buffer
                     (set-buffer-multibyte nil)
                     (insert-file-contents-literally file)
                     (buffer-string))))
        (list (cons 'mediaType media)
              (cons 'data (base64-encode-string bytes))
              (cons 'name (file-name-nondirectory file)))))))

;;;###autoload
(defun dsh-emacs-attach-file (&optional file caption)
  "Attach an image FILE to the current session and send it as a prompt.
CAPTION (or the file name) accompanies the image as the message text.
Only the media types in `dsh-emacs-attach-media-types' are sent."
  (interactive
   (list (read-file-name "Image to attach: " default-directory)
         (read-string "Caption (optional): ")))
  (let ((attachment (dsh-emacs--file-attachment file)))
    (unless attachment
      (user-error "Unsupported or unreadable image: %s" file))
    (dsh-emacs--submit-prompt (if (string-empty-p caption)
                                  (file-name-nondirectory file)
                                caption)
                              (list attachment))))

(defun dsh-emacs--dnd-attach (event)
  "Handle a `drag-n-drop' EVENT in a chat buffer by attaching the files."
  (interactive "e")
  (let* ((files (and (listp event) (nth 1 event)))
         (paths (and files
                     (delq nil (mapcar (lambda (f) (dnd-get-local-file-name f t))
                                       (if (listp files) files (list files)))))))
    (unless paths (user-error "No files in drop event"))
    (if (not (y-or-n-p (format "Attach %d file(s) to this session? "
                               (length paths))))
        (message "Attach cancelled")
      (let ((attachments (delq nil (mapcar #'dsh-emacs--file-attachment paths))))
        (if (null attachments)
            (message "No supported image files among the dropped files")
          (dsh-emacs--submit-prompt
           (if (= 1 (length attachments))
               (file-name-nondirectory (car paths))
             (format "%d images" (length attachments)))
           attachments))))))

(defun dsh-emacs--model-candidates (value)
  "Flatten a `session.models' VALUE into per-model entries.

Each entry is (ID PROVIDER PROVIDER-NAME NAME):
  ID            — the model id, sent as `session.selectModel' model.
  PROVIDER      — the owning group's id; the live host resolves
                  `current.provider' to exactly this value (the provider
                  `session.selectModel' expects for the model).
  PROVIDER-NAME — the group's display name (may equal PROVIDER).
  NAME          — the model's display name."
  (let ((groups (dsh-emacs--sequence-list (cdr (assq 'groups value)))))
    (cl-loop for g in groups
             for provider = (cdr (assq 'id g))
             for provider-name = (or (cdr (assq 'name g)) provider)
             append (cl-loop for m in (dsh-emacs--sequence-list
                                       (cdr (assq 'models g)))
                             for id = (cdr (assq 'id m))
                             for name = (or (cdr (assq 'name m)) id)
                             collect (list id provider provider-name name)))))

;;;###autoload
(defun dsh-emacs-select-model ()
  "Choose a model for the current session from the live model catalog.
Lists the models the host can route to (`session.models'), shows each with
a provider column, reads one with `completing-read' and switches via
`session.selectModel'.  The footer model segment updates immediately."
  (interactive)
  (let ((session-id (or dsh-emacs--current-session
                        (and (boundp 'dsh-emacs--buffer-session)
                             dsh-emacs--buffer-session))))
    (unless session-id (user-error "Open or select a session first"))
    (dsh-emacs--rpc-async "session.models"
                          `((sessionId . ,session-id))
                          (lambda (ok value)
                            (if (not ok)
                                (message "Failed to list models: %S" value)
                              (dsh-emacs--select-model-prompt
                               session-id value))))))

(defun dsh-emacs--select-model-prompt (session-id value)
  "Read a model choice for SESSION-ID from a `session.models' VALUE.
Each candidate shows model id, provider display name, and model name; the
provider actually sent to `session.selectModel' is the owning group's id
(the host resolves `current.provider' to exactly that)."
  (let* ((candidates (dsh-emacs--model-candidates value))
         (current (cdr (assq 'current value)))
         (current-model (and current (cdr (assq 'model current))))
         (entries (mapcar (lambda (c)
                            (cons (format "%-28s %-18s %s"
                                          (nth 0 c) (nth 2 c) (nth 3 c))
                                  c))
                          candidates))
         (picked (completing-read
                  (format "Select model%s: "
                          (if current-model
                              (format " (current %s)" current-model)
                            ""))
                  entries nil t)))
    (when picked
      (let* ((chosen (cdr (assoc picked entries)))
             (model (nth 0 chosen))
             (provider (nth 1 chosen)))
        (dsh-emacs--rpc-async "session.selectModel"
          `((sessionId . ,session-id)
            (provider . ,provider)
            (model . ,model))
          (lambda (ok2 value2)
            (if ok2
                (progn
                  (dsh-emacs-footer-set-model model)
                  (message "Model switched to %s (%s)" (nth 3 chosen)
                           (nth 2 chosen)))
              (message "Failed to switch model: %S" value2))))))))

(defun dsh-emacs--replace-input (text)
  "Replace the input area of the current buffer with TEXT and park point."
  (when (and dsh-emacs--input-marker (marker-buffer dsh-emacs--input-marker))
    (let ((inhibit-read-only t))
      (delete-region dsh-emacs--input-marker (dsh-emacs--input-end))
      (goto-char dsh-emacs--input-marker)
      (insert text)
      (goto-char (dsh-emacs--input-end)))))

(defun dsh-emacs-input-history-back ()
  "Show the previous submitted prompt in the input area (M-p)."
  (interactive)
  (let ((len (length dsh-emacs--input-history)))
    (cond
     ((zerop len) (message "No input history"))
     ((null dsh-emacs--input-history-pos)
      (setq dsh-emacs--input-history-pending (dsh-emacs--get-input)
            dsh-emacs--input-history-pos 0)
      (dsh-emacs--replace-input (nth 0 dsh-emacs--input-history)))
     ((>= (1+ dsh-emacs--input-history-pos) len)
      (message "Beginning of history"))
     (t (setq dsh-emacs--input-history-pos (1+ dsh-emacs--input-history-pos))
        (dsh-emacs--replace-input
         (nth dsh-emacs--input-history-pos dsh-emacs--input-history))))))

(defun dsh-emacs-input-history-forward ()
  "Show the next submitted prompt, or restore the typed text (M-n)."
  (interactive)
  (cond
   ((null dsh-emacs--input-history-pos)
    (message "No newer history"))
   ((zerop dsh-emacs--input-history-pos)
    (dsh-emacs--replace-input dsh-emacs--input-history-pending)
    (setq dsh-emacs--input-history-pos nil
          dsh-emacs--input-history-pending nil))
   (t (setq dsh-emacs--input-history-pos (1- dsh-emacs--input-history-pos))
      (dsh-emacs--replace-input
       (nth dsh-emacs--input-history-pos dsh-emacs--input-history)))))

(defun dsh-emacs--render-user-message (message)
  "Render the user message."
  (let ((event `((type . "user/message")
                 (data . ((content . [((type . "text")
                                       (text . ,message))]))))))
    (dsh-emacs-render-event event)))

(defun dsh-emacs--start-polling ()
  "Start polling for session updates (the fallback channel when the
WebSocket is unavailable).
Does nothing when `dsh-emacs-poll-fallback' is nil (fallback disabled by the
user).
Polling during the connection race (right after opening a session or sending
a message the WS may still be handshaking and usually recovers within 1~2
seconds) is a normal transition and is not reported; only when polling
outlasts `dsh-emacs-poll-warn-delay' without recovery is a one-time notice
shown, avoiding a false \"not connected\" report.
The polling timer is stopped only by the 101 handshake (stream recovery) or
`dsh-emacs-events-disconnect' (switching sessions); it is never cancelled by
seeing a historical `turn/end'."
  (let ((buffer (current-buffer)))
    (when (and dsh-emacs-poll-fallback
               (not dsh-emacs--event-ready)
               (not (timerp dsh-emacs--poll-timer)))
      (let ((warn-deadline (+ (float-time) (or dsh-emacs-poll-warn-delay 0.0))))
        (let ((timer (run-with-timer 0 dsh-emacs-poll-interval
                                     (lambda ()
                                       (when (buffer-live-p buffer)
                                         (with-current-buffer buffer
                                           ;; 延迟一次性提示：轮询持续超过阈值
                                           ;; 仍无 WS 时才提示；101 处理器会取消
                                           ;; 本定时器，恢复后不再提示。
                                           (unless dsh-emacs--poll-warned
                                             (when (and (not dsh-emacs--event-ready)
                                                        (> (float-time) warn-deadline))
                                               (setq dsh-emacs--poll-warned t)
                                               (message "dsh: event stream connecting, replies shown temporarily via polling (switches back to realtime when connected)")))
                                           (dsh-emacs--poll-update)))))))
          ;; 保存 timer 以便后续清理
          (setq-local dsh-emacs--poll-timer timer))))))

(defun dsh-emacs--poll-update ()
  "Poll once for updates."
  ;; 只拉取最新的事件窗口（maxMessages 语义 = 最新 N 条消息的事件，
  ;; 服务端最少返回约 850 条原始事件，一分钟内的新内容必然在其中），
  ;; 由渲染层按 seq 锚点跳过已渲染部分。全量历史（可达数万条/数 MB JSON）
  ;; 只在会话打开时加载一次；轮询每次都解析全量是本包卡顿的主要来源。
  ;; The timer runs at a Web-like cadence, but HTTP responses can take
  ;; longer than that cadence.  Never issue overlapping history requests:
  ;; overlapping callbacks would race the seq anchor and make chunks appear
  ;; out of order.
  (unless dsh-emacs--poll-inflight
    (setq dsh-emacs--poll-inflight t)
    (dsh-emacs--rpc-async "session.history"
                          `((sessionId . ,dsh-emacs--current-session)
                            (maxMessages . 50))
                          (lambda (ok value)
                            (setq dsh-emacs--poll-inflight nil)
                            (if ok
                                (let ((events (dsh-emacs--sequence-list
                                               (cdr (assq 'events value)))))
                                  ;; Use the render module's batch function which
                                  ;; processes only newly arrived chunks.
                                  (dsh-emacs-render-history-events events t))
                              (message "Polling error: %S" value))
                            ;; Check for turn completion regardless.
                            ;; IMPORTANT: never cancel the poll timer here.
                            ;; The fetched window (maxMessages => ~850 raw
                            ;; events) can end at the *previous* turn's
                            ;; turn/end even while the current turn is still
                            ;; in flight, and while the WebSocket is wedged
                            ;; this timer is the ONLY channel that will ever
                            ;; show the reply.  Cancelling on a historical
                            ;; turn/end leaves a WS-down session render-dead.
                            ;; The 101 handler / disconnect / watchdog own
                            ;; stopping this timer instead.
                            (when (and ok value)
                              (let ((events (dsh-emacs--sequence-list
                                             (cdr (assq 'events value)))))
                                (when (dsh-emacs--turn-complete-p events)
                                  ;; Turn finished: stop the running spinner.
                                  (dsh-emacs--ml-busy-set nil))))))))

(defun dsh-emacs--turn-complete-p (events)
  "Return non-nil when EVENTS indicates that a turn is complete."
  (when events
    (let* ((last-entry (car (last (append events nil))))
           (ev (and last-entry (cdr (assq 'event last-entry)))))
      (when ev
        (let ((type (cdr (assq 'type ev))))
          (equal type "turn/end"))))))

(defun dsh-emacs-refresh ()
  "Refresh the current session."
  (interactive)
  (when dsh-emacs--current-session
    (dsh-emacs--load-history dsh-emacs--current-session)))

(defun dsh-emacs-list-sessions-display ()
  "Display the session list buffer."
  (interactive)
  (dsh-emacs-list-sessions)
  (let ((buf (get-buffer-create dsh-emacs-sessions-buffer)))
    (with-current-buffer buf
      (dsh-emacs-session-mode))
    (pop-to-buffer buf)))

(defun dsh-emacs--code-block-region-at (pos)
  "Return (START . END) of the source-block body containing POS, or nil.
The renderer tags every fenced-block body with the text property
`dsh-emacs-markdown-source-block-body'; the label above the block is not
part of the body (RET on the label already copies there)."
  (let ((prop 'dsh-emacs-markdown-source-block-body))
    (save-excursion
      (goto-char (point-min))
      (catch 'found
        (while (<= (point) (point-max))
          (let ((start (if (get-text-property (point) prop)
                           (point)
                         (next-single-property-change (point) prop nil
                                                      (point-max)))))
            (if (null start)
                (throw 'found nil)
              (let ((end (or (next-single-property-change start prop)
                             (point-max))))
                (cond
                 ((<= start pos)
                  ;; REGION starts at/before POS: inside when POS < END,
                  ;; otherwise move past it and keep scanning.
                  (if (< pos end)
                      (throw 'found (cons start end))
                    (goto-char end)))
                 (t
                  ;; First region found starts after POS: POS is not inside
                  ;; any block; no later region can contain it either.
                  (throw 'found nil)))))))))))

;;;###autoload
(defun dsh-emacs-copy-code-block ()
  "Copy the source-code block containing point to the kill ring.
Point may be anywhere inside a rendered fenced block; the block face and
`dsh-emacs-markdown-source-block-body' tag survive even after a propertized
copy into another buffer (e.g. an image viewport)."
  (interactive)
  (let* ((region (dsh-emacs--code-block-region-at (point)))
         (text (and region
                    (buffer-substring-no-properties (car region) (cdr region)))))
    (if text
        (progn (kill-new text) (message "Copied code block"))
      (user-error "Point is not inside a code block"))))

(defun dsh-emacs-copy-transcript ()
  "Copy the current transcript to the clipboard."
  (interactive)
  (let ((chat (or dsh-emacs--input-chat-buffer (current-buffer))))
    (when (buffer-live-p chat)
      (with-current-buffer chat
        (let ((transcript (buffer-substring-no-properties
                           (point-min) (point-max))))
          (kill-new transcript)
          (message "Transcript copied to clipboard"))))))

(defun dsh-emacs-footer-toggle ()
  "Toggle footer display."
  (interactive)
  (let ((chat (or dsh-emacs--input-chat-buffer (current-buffer))))
    (when (buffer-live-p chat)
      (with-current-buffer chat
        (setq dsh-emacs-footer-enabled (not dsh-emacs-footer-enabled))
        (dsh-emacs-footer-update)))))

;;; ---------------------------------------------------------------------------
;;;  主入口
;;; ---------------------------------------------------------------------------

;;;###autoload
(defun dsh-emacs ()
  "Open the dsh session list.
This is the main entry command of dsh-emacs."
  (interactive)
  (dsh-emacs-list-sessions-display))

;;;###autoload
(defun dsh-emacs-health ()
  "Check the dsh web service status."
  (interactive)
  (dsh-emacs--rpc-async "session.list" nil
                        (lambda (ok value)
                          (if ok
                              (message "dsh service is running")
                            (message "dsh service unreachable: %S" value)))))

(provide 'dsh-emacs)

;;; dsh-emacs.el ends here
