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

;; 协议层：dsh 响应字段的 typed 访问（见 dsh-emacs-protocol.el）
(require 'dsh-emacs-protocol)

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

(defcustom dsh-emacs-model-group-format
  #(" %s " 0 4 (face vertico-group-title))
  "Format string for provider group titles in the model selector.
`%s' is replaced with the provider name.
Inside the model selector's minibuffer this overrides vertico's global
`vertico-group-format' (buffer-locally, other completions are untouched):
vertico's stock format draws a long strike-through separator line across
the whole group header (\"----...\"), which is noisy; the default here
paints just the provider name.  Set to nil to hide group titles entirely
inside the picker."
  :type '(choice (const :tag "No group titles" nil) string)
  :group 'dsh-emacs)

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
;; `dsh-emacs-mode' is a derived mode, whose generated initializer runs
;; `kill-all-local-variables' (Clearing buffer-local variables on mode
;; switch).  Mark this binding permanent so it survives the mode call and
;; `dsh-emacs--chat-buffer-sync' (invoked from live `session/title' events)
;; can still match the current buffer against its session id.
(put 'dsh-emacs--buffer-session 'permanent-local t)

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

(defun dsh-emacs--http-error-hint (err)
  "Human-readable hint for an HTTP error ERR, or \"\".
ERR like `(error http 404)' comes from `url-retrieve' status.  404/405
mean the method is not exposed by this dsh server version (e.g.
`session.delete' is absent from the 0.1.1-rc.1 RPC table)."
  (if (and (listp err) (numberp (nth 2 err)))
      (let ((code (nth 2 err)))
        (if (>= code 400)
            (format " (HTTP %S: current dsh server may not expose this RPC)" code)
          (format " (HTTP %S)" code)))
    ""))

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
                          (let ((err (plist-get status :error)))
                            (message "RPC async error: %S%s" status
                                     (dsh-emacs--http-error-hint err))
                            (when (buffer-live-p callback-buffer)
                              (with-current-buffer callback-buffer
                                ;; 回调若在 filter 里交互（completing-read 等）
                                ;; 并按 C-g，吞掉 quit 而非报 process filter 错误
                                (condition-case nil
                                    (funcall callback nil nil)
                                  (quit nil)))))
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
                                (condition-case nil
                                    (funcall callback ok value)
                                  (quit nil)))))))))
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
      (when (equal session-id (dsh-protocol-session-session-id item))
        (throw 'found item)))))

(defun dsh-emacs--chat-title (session-id)
  "Display title for SESSION-ID, identical to the session list row, or nil."
  (let ((item (dsh-emacs--chat-session-item session-id)))
    (and item (dsh-emacs-session--display-title item))))

(defun dsh-emacs--chat-cwd (session-id)
  "Directory of SESSION-ID: the session's `cwd' from session.list.
Falls back to the path of the workspace that accounts for the session
(a freshly created workspace session may not be in the session cache yet
but is already in `dsh-emacs--workspaces').  Returns nil when the session
is not known at all."
  (or (let ((item (dsh-emacs--chat-session-item session-id)))
        (and item (dsh-protocol-session-cwd item)))
      (catch 'found
        (dolist (ws dsh-emacs--workspaces)
          (when (member session-id
                        (dsh-protocol-workspace-session-ids ws))
            (throw 'found (dsh-protocol-workspace-path ws)))))))

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
                                ;; `dolist', and wrap each item in a
                                ;; `dsh-protocol-session' struct so field
                                ;; access is centralized (protoco.el).
                                (setq dsh-emacs--sessions
                                      (mapcar
                                       #'dsh-protocol-session--from-alist
                                       (dsh-emacs--sequence-list
                                        (cdr (assq 'items value)))))
                                ;; 标题/工作区可能已漂移（自动摘要/重命名/
                                ;; 会话移动），同步所有存活聊天缓冲的名称与
                                ;; default-directory。
                                (dsh-emacs--chat-buffers-sync-all)
                                ;; Refresh workspaces in parallel so the
                                ;; session list can group by workspace.
                                (dsh-emacs-list-workspaces))
                            (message "Failed to fetch session list: %S" value)))))

;;;###autoload
(defun dsh-emacs-new-session (&optional cwd workspace-id)
  "Create a new session.
CWD is the working directory; with WORKSPACE-ID the session is created
inside that workspace (`session.create' takes workspaceId rather than
cwd).  Interactively, when point sits on a workspace header or its empty
New Session row (in the session list), the session is created in that
workspace; otherwise in CWD."
  (interactive
   (let ((ws (dsh-emacs-workspace-id-at-point)))
     (list nil ws)))
  (dsh-emacs--rpc-async "session.create"
                        (if workspace-id
                            `((workspaceId . ,workspace-id)
                              (model . ,dsh-emacs-default-model))
                          `((cwd . ,(dsh-emacs--absolute-cwd cwd))
                            (model . ,dsh-emacs-default-model)))
                        (lambda (ok value)
                          (if ok
                              (let ((session-id (cdr (assq 'sessionId value))))
                                ;; 把新会话补进缓存：sessions 列表 + workspace
                                ;; session-ids（分组归属）——否则它落到 ungrouped
                                ;; 且 `session/title' 事件找不到缓存 item，自动
                                ;; 重命名无法实时生效。
                                (dsh-emacs--cache-new-session
                                 session-id workspace-id)
                                (dsh-emacs-open-session session-id)
                                ;; 新建的 workspace 会话尚未进入 session.list
                                ;; 缓存（事件流不携带该信息），`--chat-buffer-sync'
                                ;; 因此取不到 cwd；立即用 workspace 的 path 对齐
                                ;; default-directory，magit-status 等按此定位项目。
                                ;; 重新打开时缓存已刷新，走 `--chat-cwd' 分支。
                                (when workspace-id
                                  (let ((ws (cl-find-if
                                             (lambda (w)
                                               (equal workspace-id
                                                      (dsh-protocol-workspace-workspace-id w)))
                                             dsh-emacs--workspaces)))
                                    (when ws
                                      (let ((dir (dsh-protocol-workspace-path ws)))
                                        (when (and dir (not (string-empty-p dir))
                                                   (buffer-live-p
                                                    dsh-emacs--current-buffer))
                                          (with-current-buffer dsh-emacs--current-buffer
                                            (setq-local default-directory
                                                        (file-name-as-directory
                                                         (expand-file-name dir))))))))))
                            (message "Failed to create session: %S" value)))))

(defun dsh-emacs--cache-new-session (session-id &optional workspace-id)
  "Cache the freshly created SESSION-ID so grouping and title updates work\n before the next `session.list' refresh: insert a placeholder row (blank,\n \"New Session\") into `dsh-emacs--sessions' and, with WORKSPACE-ID, append\n SESSION-ID to that workspace's `session-ids' (the group renderer assigns\n sessions to workspaces from those ids).  Repaints the session list.

The workspace attachment is deliberately INDEPENDENT of the session-row
insert: the host stream (`host/session-added') may deliver the new session
before the `session.create' RPC callback runs, so guarding both actions
behind the same not-yet-cached check would skip the attach and leave the
session in the Ungrouped bucket until a later `workspace-changed' frame
arrives."
  (let ((ws (and workspace-id
                 (cl-find-if (lambda (w)
                               (equal workspace-id
                                      (dsh-protocol-workspace-workspace-id w)))
                             dsh-emacs--workspaces))))
    (unless (dsh-emacs--chat-session-item session-id)
      (let ((cwd (if ws (dsh-protocol-workspace-path ws)
                   (dsh-emacs--absolute-cwd nil))))
        (push (dsh-protocol-session--from-alist
               (list (cons 'sessionId session-id)
                     (cons 'blank t)
                     (cons 'cwd cwd)))
              dsh-emacs--sessions)))
    ;; Attach even when the session row already arrived via the host stream:
    ;; membership comes solely from the workspace `session-ids', so the row
    ;; must be accounted there or it renders in Ungrouped.  Idempotent by
    ;; membership.
    (when (and ws
               (not (member session-id
                            (dsh-protocol-workspace-session-ids ws))))
      (setf (dsh-protocol-workspace-session-ids ws)
            (cons session-id
                  (dsh-protocol-workspace-session-ids ws))))
    (when (and (listp dsh-emacs--sessions)
               dsh-emacs-sessions-buffer
               (get-buffer dsh-emacs-sessions-buffer))
      (with-current-buffer (get-buffer dsh-emacs-sessions-buffer)
        (dsh-emacs-session--render))))
  session-id)

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
                            (let ((id (dsh-protocol-session-session-id s)))
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
      (when (equal session-id (dsh-protocol-session-session-id item))
        (throw 'found (dsh-protocol-session-agent-preset item))))))

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
                                (let ((items (mapcar
                                              #'dsh-protocol-session--from-alist
                                              (dsh-emacs--sequence-list
                                               (cdr (assq 'items value))))))
                                  ;; 新会话首次打开时缓存里没有该会话：顺带
                                  ;; 更新整个缓存，让缓冲名（`dsh-<标题>'）
                                  ;; 与工作区（default-directory）也一并取得。
                                  (setq dsh-emacs--sessions items)
                                  (dsh-emacs--chat-buffers-sync-all)
                                  (catch 'found
                                    (dolist (item items)
                                      (when (equal session-id
                                                   (dsh-protocol-session-session-id
                                                    item))
                                        (dsh-emacs-footer-set-effort
                                         (dsh-protocol-session-agent-preset
                                          item))
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

(defun dsh-emacs-archive-session (session-id)
  "Archive SESSION-ID: remove it from its workspace view.
`workspace.archiveSession' (the only session-removal RPC this dsh version
exposes; there is no `session.delete').  Refreshes the archived set and
the session list on success."
  (interactive (list (dsh-emacs--completing-session-id "Archive session: ")))
  (dsh-emacs--rpc-async "workspace.archiveSession"
                        `((sessionId . ,session-id))
                        (lambda (ok value)
                          (if ok
                              (progn
                                (setq dsh-emacs--archived-sessions
                                      (dsh-emacs--normalize-archived
                                       (dsh-protocol-archived-set-archived-session-ids
                                        (dsh-protocol-archived-set--from-alist value))))
                                (dsh-emacs-list-sessions)
                                (message "Session archived"))
                            (message "Failed to archive: %S" value)))))

(defun dsh-emacs-rename-session (session-id new-title)
  "Rename session."
  (interactive
   (let* ((sid (dsh-emacs--completing-session-id "Rename session: "))
          (item (dsh-emacs--chat-session-item sid)))
     (list sid
           (read-string "New title: "
                        (or (and item (dsh-emacs-session--title item)) "")))))
  (dsh-emacs--rpc-async "session.rename"
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
                            (let ((wl (dsh-protocol-workspace-list--from-alist value)))
                              (setq dsh-emacs--workspaces
                                    (dsh-protocol-workspace-list-items wl))
                              (setq dsh-emacs--archived-sessions
                                    (dsh-emacs--normalize-archived
                                     (dsh-protocol-workspace-list-archived-session-ids wl)))))
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
  (interactive
   (list (read-string "Workspace id: ")
         (read-string "New workspace title: ")))
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
  (interactive
   (let ((id (read-string "Delete workspace id: ")))
     (if (yes-or-no-p (format "Delete workspace %s? " id))
         (list id)
       (keyboard-quit))))
  (dsh-emacs--rpc-async "workspace.delete"
                        `((workspaceId . ,workspace-id))
                        (lambda (ok value)
                          (if ok
                              (progn
                                (dsh-emacs-list-workspaces)
                                (message "Workspace deleted"))
                            (message "Failed to delete: %S" value)))))

;;;###autoload
(defun dsh-emacs-move-workspace (workspace-id before-workspace-id)
  "Move WORKSPACE-ID before BEFORE-WORKSPACE-ID in the workspace order.
With nil BEFORE-WORKSPACE-ID the workspace moves to the end.
Mirrors dsh web's drag ordering (`workspace.insertBefore'): the response
carries the authoritative workspaceIds, which reorder the local cache so
the session list regroups immediately (the host stream also repaints)."
  (interactive
   (list (read-string "Move workspace id: ")
         (let ((s (read-string "Insert before workspace id (blank for end): " nil nil t)))
           (and (not (string-empty-p s)) s))))
  (dsh-emacs--rpc-async "workspace.insertBefore"
                        (if before-workspace-id
                            `((workspaceId . ,workspace-id)
                              (beforeWorkspaceId . ,before-workspace-id))
                          `((workspaceId . ,workspace-id)))
                        (lambda (ok value)
                          (if ok
                              (progn
                                (let* ((ids (dsh-emacs--sequence-list
                                             (cdr (assq 'workspaceIds value))))
                                       (ids-by-local
                                        (delq nil
                                              (mapcar
                                               (lambda (ws)
                                                 (let ((id (dsh-protocol-workspace-workspace-id ws)))
                                                   (and id (cons id ws))))
                                               dsh-emacs--workspaces))))
                                  (when ids
                                    (setq dsh-emacs--workspaces
                                          (append
                                           (delq nil (mapcar (lambda (id)
                                                               (cdr (assoc id ids-by-local)))
                                                             ids))
                                           (delq nil (mapcar
                                                      (lambda (pair)
                                                        (unless (member (car pair) ids)
                                                          (cdr pair)))
                                                      ids-by-local))))
                                    ;; Refresh workspaces in parallel so
                                    ;; membership/order stays authoritative.
                                    (dsh-emacs-list-workspaces)))
                                (message "Workspace reordered"))
                            (message "Failed to reorder: %S" value)))))

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
  "Flatten a `session.models' VALUE into per-model entries, sorted.

The list is sorted by provider display name then model id
(case-insensitive), so the model picker shows a stable, predictable
order regardless of the host's own group/model ordering.

Each entry is (ID PROVIDER PROVIDER-NAME NAME REASONING):
  ID            — the model id, sent as `session.selectModel' model.
  PROVIDER      — the owning group's id; the live host resolves
                  `current.provider' to exactly this value (the provider
                  `session.selectModel' expects for the model).
  PROVIDER-NAME — the group's display name (may equal PROVIDER).
  NAME          — the model's display name (may equal ID).
  REASONING     — the model's reasoning metadata
                  (a `dsh-protocol-reasoning' struct), or nil when the
                  model offers no reasoning-effort options.

VALUE is the raw `session.models' response alist — it is normalized to
a `dsh-protocol-model-directory' struct first, so all field access lives
in dsh-emacs-protocol.el."
  (let* ((dir (dsh-protocol-model-directory--from-alist value))
         (groups (dsh-protocol-model-directory-groups dir)))
    (sort (cl-loop for g in groups
                   for provider = (dsh-protocol-provider-group-id g)
                   for provider-name = (or (dsh-protocol-provider-group-name g)
                                           provider)
                   append (cl-loop for m in (dsh-protocol-provider-group-models g)
                                   for id = (dsh-protocol-model-catalog-entry-id m)
                                   for name = (or (dsh-protocol-model-catalog-entry-name m)
                                                  id)
                                   for reasoning = (dsh-protocol-model-catalog-entry-reasoning m)
                                   collect (list id provider provider-name
                                                name reasoning)))
          (lambda (a b)
            (let ((pa (downcase (nth 2 a)))
                  (pb (downcase (nth 2 b)))
                  (ia (downcase (nth 0 a)))
                  (ib (downcase (nth 0 b))))
              (or (string-lessp pa pb)
                  (and (string= pa pb) (string-lessp ia ib))))))))

(defun dsh-emacs--model-effort-choices (reasoning)
  "Effort options of REASONING (a `dsh-protocol-reasoning' struct, or a
wire alist) as ((NAME . ID) ...), keeping the host's directory order for
display; entries without a display name fall back to their id.  Returns
nil when REASONING has no efforts."
  (setq reasoning (dsh-protocol--struct
                   #'dsh-protocol-reasoning-p
                   #'dsh-protocol-reasoning--from-alist
                   reasoning))
  (mapcar (lambda (e)
            (let ((id (dsh-protocol-effort-id e))
                  (name (or (dsh-protocol-effort-name e)
                            (dsh-protocol-effort-id e))))
              (cons name id)))
          (dsh-protocol-reasoning-efforts reasoning)))

(defun dsh-emacs--model-effort-default-id (reasoning &optional current-id)
  "The effort id to pre-select for a model with REASONING options.
CURRENT-ID wins when it is a valid option (the session already runs that
model at that effort); otherwise the model's `defaultEffort' when it is a
known option; otherwise the first effort in the directory."
  (setq reasoning (dsh-protocol--struct
                   #'dsh-protocol-reasoning-p
                   #'dsh-protocol-reasoning--from-alist
                   reasoning))
  (let* ((choices (dsh-emacs--model-effort-choices reasoning))
         (ids (mapcar #'cdr choices))
         (default (dsh-protocol-reasoning-default-effort reasoning)))
    (cond ((and current-id (member current-id ids)) current-id)
          ((member default ids) default)
          (ids (car ids))
          (t nil))))

(defun dsh-emacs--model-pick-effort (model choices default-id)
  "Read a reasoning-effort choice for MODEL from CHOICES ((NAME . ID) ...).
Returns the chosen effort id.  The choice whose id equals DEFAULT-ID is
passed as completing-read's DEF: vertico pre-selects it and an empty RET
takes it — re-picking the current model keeps its live effort, other
models default to their host-supplied default.  Signals quit on C-g, so
the caller can cancel the whole selection."
  (let* ((default-name (car (rassoc default-id choices)))
         (name (completing-read
                (if default-name
                    (format "Reasoning effort for %s (default %s): "
                            model default-name)
                  (format "Reasoning effort for %s: " model))
                choices nil t nil nil default-name)))
    (or (cdr (assoc name choices)) default-id)))

(defun dsh-emacs--model-row-entry (c dup)
  "One (KEY . C) completing-read entry for model tuple C.
KEY = \"id [provider|Provider Name]\" — the id first, so prefix
completion (default `completion-styles' match by prefix) hits when the
user types a model id; provider id and display name are embedded for
exact `assoc' and for searching by provider name — with a `display'
property rendering \"  id\" (or, when DUP non-nil — the same id is
offered by several providers — and no group headers are available,
\"  id (Provider Name)\" so duplicate-id rows stay distinguishable
after the group headers are dropped)."
  (let* ((id (nth 0 c))
         (provider (nth 1 c))
         (provider-name (nth 2 c))
         (shown (if dup
                    (format "  %s (%s)" id provider-name)
                  (format "  %s" id)))
         (key (propertize (format "%s [%s|%s]" id provider provider-name)
                          'display shown)))
    (cons key c)))

(defun dsh-emacs--model-key-parts (key)
  "Parse row KEY built by `dsh-emacs--model-row-entry' as
\"id [provider|Provider Name]\", returning (ID PROVIDER PROVIDER-NAME)
or nil when KEY is not a model row."
  (when (string-match "\\`\\([^ ]+\\) \\[\\([^]|]*\\)|\\([^]]*\\)\\]\\'" key)
    (list (match-string 1 key)
          (match-string 2 key)
          (match-string 3 key))))

(defun dsh-emacs--model-key-provider (key)
  "Provider id embedded in row KEY, or nil."
  (nth 1 (dsh-emacs--model-key-parts key)))

(defun dsh-emacs--model-entries (candidates)
  "Entries for completion UIs WITHOUT grouping support: provider shown
once as a bare header row, its models following, indented, each
showing the model id (the payload keeps the display NAME for
messages/footer) with payload = the candidate tuple
(ID PROVIDER PROVIDER-NAME NAME REASONING), where REASONING is the
host's `reasoning' alist (efforts + defaultEffort) or nil.  Rows are
(DISPLAY . PAYLOAD) conses, so a picked header is rejected by the
caller instead of being treated as a model.

The row KEY embeds the owning provider (\"id [provider|Provider
Name]\", id first so prefix filtering still matches) and a `display'
property renders the row: bare \"  id\" for unique ids, and
\"  m2 (Qwen)\" when an id collides across providers — because this
path's group headers are ordinary candidates and vanish from the
displayed list the moment the user types a query."
  (let ((entries '())
        (last-provider nil)
        (id-count (make-hash-table :test #'equal)))
    (dolist (c candidates)
      (let ((id (nth 0 c)))
        (puthash id (1+ (gethash id id-count 0)) id-count)))
    (dolist (c candidates (nreverse entries))
      (let* ((provider-name (nth 2 c))
             (dup (> (gethash (nth 0 c) id-count 0) 1)))
        (unless (equal provider-name last-provider)
          (push (cons provider-name (cons :header provider-name)) entries)
          (setq last-provider provider-name))
        (push (dsh-emacs--model-row-entry c dup) entries)))))

(defun dsh-emacs--model-grouped-collection (candidates)
  "Completion table with sticky group headers, returns (TABLE . ROWS).
For completion UIs that honour the `group-function' completion
metadata — modern vertico draws sticky group headers from it,
recomputing them on every filter input, and the Emacs 27+ *Completions*
buffer renders them too: rows are flat (no header-row candidates),
each KEY \"id [provider|Provider Name]\" rendered as bare \"  id\"
via the `display' property (id first so prefix completion still
matches while typing; provider name sits in the key, so substring
styles also find it), and the table metadata carries a
`group-function' mapping every key back to its provider display name.
The UI then paints one sticky group header per provider that stays
visible while any of its rows still matches the query — grouping is
NOT lost while searching."
  (let* ((rows (mapcar (lambda (c) (dsh-emacs--model-row-entry c nil))
                       candidates))
         (group-fn
          ;; 自包含：直接从键里解析 provider 显示名，不捕获任何变量。
          ;; 标题必须是无属性串（match-string 会保留候选键上的 display 属性）。
          ;; transform 分支把 id 区间的匹配高亮 face 迁到显示串对应位置：
          ;; 键 = "m2 [g2|Qwen]"（display 隐藏段），输入 "m2" 时 orderless/
          ;; basic 给键首 [0,2) 打 completion-match-face —— 整键摊给
          ;; vertico--display-string 会变成整行背景，全部剥掉又丢失高亮；
          ;; 正确做法是带 face 子串嵌入 "  " + id 的可见文本
          (lambda (cand transform)
            (if transform
                (let* ((c (copy-sequence cand))
                       (id (car (dsh-emacs--model-key-parts cand))))
                  (if (and id (> (length id) 0))
                      (let ((sub (substring c 0 (length id))))
                        ;; 子串剥掉 display/invisible（隐藏段的属性），保留 face。
                        (remove-text-properties
                         0 (length sub) '(display nil invisible nil) sub)
                        sub)
                    c))
              (let ((parts (dsh-emacs--model-key-parts cand)))
                (and parts (substring-no-properties (nth 2 parts)))))))
         (table (completion-table-with-metadata
                 rows
                 ;; Emacs 31 的 completion-table-with-metadata 要求元数据
                 ;; 不带前缀 (metadata ...)，直接给 plist，它自己包一层。
                 ;; (category . dsh-model)：nerd-icons-completion 会给
                 ;; 每个候选行首插图标 —— 它的图标表里 nil 类别映射为
                 ;; nf-cod-arrow_small_right（行首的 "->" 箭头），而
                 ;; 不在表里的类别返回空串；显式声明一个自用类别即可
                 ;; 让行首无图标（同时 marginalia 因类别不在其 annotator
                 ;; 表中也不会注入后缀注解）。
                 ;; 恒等 affixation-function 再兜底：第三方包想往行尾加
                 ;; annotation/affixation 后缀也会被顶掉
                 (list (cons 'category 'dsh-model)
                       (cons 'group-function group-fn)
                       (cons 'affixation-function
                             (lambda (cands)
                               (mapcar (lambda (c) (list c "" "")) cands)))))))
    (cons table rows)))

;; 模型选择器行首图标（可选集成，不新增依赖）：
;; 选择器 metadata 声明 category=dsh-model；当 nerd-icons-completion 加载后，
;; 给这个类别注册一枚默认芯片图标（nf-cod-chip）——行首就显示，无需
;; 用户配置。想换图标时在自己的配置里先 add-to-list 同类别条目即可覆盖
;; （assq 已存在则默认注册跳过）。未安装 nerd-icons-completion 时无任何影响。
(with-eval-after-load 'nerd-icons-completion
  (when (and (boundp 'nerd-icons-completion-category-icons)
             (not (assq 'dsh-model nerd-icons-completion-category-icons)))
    (add-to-list 'nerd-icons-completion-category-icons
                 '(dsh-model . (nerd-icons-codicon "nf-cod-chip" nerd-icons-blue)))))

(defun dsh-emacs--model-select-setup-hook (grouped)
  "Buffer-local tweaks for the model picker's minibuffer.
GROUPED says whether vertico's native group-function rendering is
active (see the detection in `dsh-emacs--select-model-prompt').
Sorting and preselect are tamed locally so the provider order and the
cursor position stay put; when GROUPED, `vertico-group-format' is
overridden buffer-locally by `dsh-emacs-model-group-format' (killing
the stock long separator lines inside the picker only)."
  (when (boundp 'vertico-sort-function)
    (setq-local vertico-sort-function nil))
  (when (boundp 'vertico-sort-override-function)
    (setq-local vertico-sort-override-function nil))
  (when (boundp 'vertico-preselect)
    (setq-local vertico-preselect 'first))
  (when (and grouped (boundp 'vertico-group-format))
    (setq-local vertico-group-format dsh-emacs-model-group-format))
  ;; 显式返回 nil：Emacs 31 的 minibuffer-with-setup-hook 会把 SETUP
  ;; 表达式的求值结果 funcall 掉，绝不能让它流回别的值（比如上面的
  ;; setq-local 值 —— 那会变成 "Invalid function: ..."）
  nil)

;;;###autoload
(defun dsh-emacs-select-model ()
  "Choose a model for the current session from the live model catalog.
Lists the models the host can route to (`session.models'), shows each
under its provider as its id, reads one with `completing-read'
and switches via `session.selectModel'.  Each row's key carries its
provider (hidden from display), and the provider display name is part
of the key too, so provider names stay searchable while filtering.
Modern vertico draws sticky provider group headers from the table's
`group-function' metadata (an Emacs 27+ *Completions* buffer does the
same), kept while any row of the group matches the query; without a
group-aware UI, header rows plus a per-row provider suffix on
colliding ids are shown.  The footer model segment updates
immediately."
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
Each candidate is a provider header or an indented model row showing
the model id; the provider
actually sent to `session.selectModel' is the owning group's id (the host
resolves `current.provider' to exactly that).  Row keys carry the
provider hidden behind a `display' property, so `assoc' always resolves
to the row the user picked, even when the same id is offered by
several providers.

Two display paths: with `vertico-group-mode' active (Emacs 27+
`*Completions*' buffers group too), candidates are flat rows and a
`group-function' metadata keeps one sticky header per provider while
the user filters — grouping survives searching.  In completion UIs
without grouping support, provider headers are ordinary candidates
(dropped by filtering) and colliding ids fall back to a visible
provider suffix on their rows.

When the chosen model declares reasoning-effort options (`reasoning'),
a second reader asks for the effort: re-picking the current model
pre-selects its live `reasoningEffort', other models pre-select their
`defaultEffort', and the id is sent as `session.selectModel'
`reasoningEffort'.  Models without reasoning options send no effort
field at all.

No completing-read default is passed on purpose: vertico moves the default
row to the top of the candidate list, which would pull the current model
out of its provider group.  Instead an empty RET keeps the current model
(no RPC at all) and unknown input is rejected against the entry table.
A vertico preselect nudge (vertico-nudge.el) is available but not wired;
without it the highlight starts on the first row and the user navigates
manually.

Runs inside the async RPC callback (a process filter), so C-g during
`completing-read' is caught here; otherwise the `quit' would leak out of
the filter as \"error in process filter: Quit\"."
  (condition-case nil
      (let* ((dir (dsh-protocol-model-directory--from-alist value))
             (current (dsh-protocol-model-directory-current dir))
             (current-model (and current
                                 (dsh-protocol-model-selection-model current)))
             (candidates (dsh-emacs--model-candidates value))
             ;; 现代 vertico（≥2.0）原生支持 group-function 元数据：每次
             ;; 输入都重算分组并重绘粘性组头（无需 vertico-group.el/group-mode）
             ;; → 走元数据分组路径；否则用候选头行 + 重复行后缀兜底
             ;; （头行会被过滤滤掉）。旧 vertico + vertico-group 也用同协议。
             (grouped (and (bound-and-true-p vertico-mode)
                           (or (boundp 'vertico--groups)
                               (boundp 'vertico-group--groups))))
             (grouped-pair (and grouped
                                (dsh-emacs--model-grouped-collection
                                 candidates)))
             ;; provider 头行 + 缩进的模型行（头行 payload 是 (:header . NAME)）
             (entries (if grouped (cdr grouped-pair)
                        (dsh-emacs--model-entries candidates)))
             (collection (if grouped (car grouped-pair) entries))
             (picked (minibuffer-with-setup-hook
                         ;; 模型选择器内局部关闭 vertico 的排序（防止候选被重排），
                         ;; 兜底预选设为首行（vertico preselect 只支持 prompt/first）。
                         ;; 必须是求值成函数对象的表达式：Emacs 31 的宏会
                         ;; (funcall (eval SETUP))，直接传函数调用会把它
                         ;; 的返回值当函数调用（见 dsh-emacs--model-select-setup-hook）
                         (lambda () (dsh-emacs--model-select-setup-hook grouped))
                         ;; 不传 DEF：vertico 会把默认项搬到列表最前，当前模型就会
                         ;; 脱离自己的分组、永远占首行。空 RET 由下方 "" 分支处理
                         ;; （保持当前模型），乱输入由 assoc 校验兜底。
                         (completing-read
                          (format "Select model%s: "
                                  (if current-model
                                      (format " (current %s)" current-model)
                                    ""))
                          collection nil nil nil nil nil)))
             (empty (not (and picked (stringp picked)
                              (not (string-empty-p picked))))))
        (cond
         (empty
          (message (if current-model
                       (format "Kept current model %s" current-model)
                     "Kept the current model")))
         ((not (assoc picked entries))
          (message "Unknown model: %s" picked))
         ;; 选中 provider 头行（不是模型）→ 提示后不切换
         ((eq :header (car (cdr (assoc picked entries))))
          (message "That is a provider header — pick a model below it"))
         (t
          (let* ((chosen (cdr (assoc picked entries)))
                 (model (nth 0 chosen))
                 (provider (nth 1 chosen))
                 (reasoning (nth 4 chosen))
                 ;; 第二层：目标模型声明了 reasoning 选项才问 effort。
                 ;; 重选当前模型 → 保持其现行 reasoningEffort；其他模型
                 ;; → 目录 defaultEffort（无则第一个）。RET/vertico 预选
                 ;; 即默认，C-g 冒泡到外层统一“取消”。
                 (effort-id (and reasoning
                                 (dsh-emacs--model-pick-effort
                                  model
                                  (dsh-emacs--model-effort-choices reasoning)
                                  (dsh-emacs--model-effort-default-id
                                   reasoning
                                   (and (equal model current-model)
                                        (dsh-protocol-model-selection-reasoning-effort
                                         current)))))))
            (dsh-emacs--rpc-async "session.selectModel"
              `((sessionId . ,session-id)
                (provider . ,provider)
                (model . ,model)
                ,@(and effort-id `((reasoningEffort . ,effort-id))))
              (lambda (ok2 value2)
                (if ok2
                    (progn
                      (dsh-emacs-footer-set-model model)
                      (message "Model switched to %s (%s)%s"
                               (nth 3 chosen) (nth 2 chosen)
                               (if effort-id
                                   (format ", effort %s" effort-id)
                                 "")))
                  (message "Failed to switch model: %S" value2))))))))
    (quit (message "Model selection cancelled"))))

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
