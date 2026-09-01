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
;; - mode-line 统计段（显示 cwd、git branch、model、tokens、ctx%、cost）
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
(require 'dsh-emacs-modeline)
(require 'dsh-emacs-server)
(require 'dsh-emacs-command)
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

(defcustom dsh-emacs-switch-max-candidates 200
  "Max candidates offered to the completion UI per keystroke by switch-session.
The completion framework (vertico/ivy/corfu) rebuilds its candidate list
on every keystroke, so an unbounded list of sessions would allocate a
fresh N-entry structure per keypress — the same pain counsel-rg avoids by
consuming its rg output in bounded increments.  This caps the offered set
to the most-recently-active entries; older sessions remain reachable as
soon as a filter is typed (and the workspace-scoped list is naturally
below this cap).  Raise it for very large session counts, lower it for
snappier keys."
  :type 'integer
  :group 'dsh-emacs)

(defcustom dsh-emacs-base-url "http://127.0.0.1:3080"
  "Address of the running dsh web service."
  :type 'string
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

(defcustom dsh-emacs-default-preset nil
  "Default agent preset (agentPreset id) for new sessions.

nil lets the host pick its own default preset (no `agentPreset' field is
sent to `session.create').  Known values are the built-in preset ids
\"standard\" (Standard mode), \"minimal\" (Minimal mode), \"code\" (PTC
mode) and \"cordis\" (Creator mode), or the id of a user preset listed
by `agentPreset.list'.  Interactively, `dsh-emacs-new-session' with a
prefix argument asks for the preset instead of using this value."
  :type '(choice (const :tag "Host default" nil) string)
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

(defcustom dsh-emacs-question-skip-key "s"
  "Key that skips the current ask question (answers it with an empty
selection, dsh web's per-question Skip) and moves to the next one.
A single letter by default (`s' = skip): the chooser is a one-shot
numbered picker, so typing letters to filter is rare.  The nested
`Type answer…' free-text minibuffer is separate and keeps normal
editing keys.  Bound only inside the question chooser's minibuffer, on a
copy of the local keymap, so nothing leaks into unrelated
`completing-read' prompts; an option-less free-text question skips on an
EMPTY input instead, so the key is only bound where there is a candidate
list.  Set to nil to disable the shortcut."
  :type '(choice (key-sequence :tag "Key sequence")
                 (const :tag "No shortcut" nil))
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

(defvar dsh-emacs--agent-presets nil
  "Cached `agentPreset.list' response (a `dsh-protocol-agent-preset-list'
struct), used by the new-session preset picker.  Refreshed lazily by
`dsh-emacs--agent-presets-refresh'; nil before the first successful
fetch falls back to the built-in preset ids.")

(defvar dsh-emacs--archived-sessions nil
  "Set of archived session IDs (hash table).")

(defvar dsh-emacs--current-session nil
  "Globally active session (the last opened one).

`dsh-emacs-open-session' sets it; it is the fallback owner for contexts
with no chat buffer (the session list, list-buffer commands, naming
yourself before a session opens).  With several session buffers open it
still points at the LAST-opened session, so interactive commands must
NOT resolve their target from this variable alone — they read
`dsh-emacs--buffer-session' (the owning chat buffer) first, via
`dsh-emacs--active-session-id'.")

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

(defvar-local dsh-emacs--history-refetch-rounds 0
  "How many bounded re-fetches the open of this buffer has issued.
The open closes the history/stream gap by repeatedly re-fetching the newest
window until it stops advancing or the round budget is spent.")

(defvar-local dsh-emacs--buffer-session nil
  "Session ID owned by this chat buffer (buffer-local).

Set by `dsh-emacs-open-session' on every chat buffer; this is the
AUTHORITATIVE owner for event routing and interactive commands while
inside that buffer: mux transcript events are attributed to a chat
buffer via `buffer-local-value of this variable, and
`dsh-emacs--active-session-id' resolves the command target from it
before falling back to the global `dsh-emacs--current-session'.
Several session buffers can be open at once; each keeps its own
binding, so switching buffers never confuses which session a
transcript or a `C-c C-c' belongs to.")
;; `dsh-emacs-mode' is a derived mode, whose generated initializer runs
;; `kill-all-local-variables' (Clearing buffer-local variables on mode
;; switch).  Mark this binding permanent so it survives the mode call and
;; `dsh-emacs--chat-buffer-sync' (invoked from live `session/title' events)
;; can still match the current buffer against its session id.
(put 'dsh-emacs--buffer-session 'permanent-local t)

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
      ;; Not an ok envelope: prefer the envelope's error, then a provider
      ;; error body that leaked through the HTTP response (no `result' key,
      ;; e.g. a model-studio quota rejection) so callers show the real
      ;; reason instead of nil.
      (cons nil (or (cdr (assq 'error result))
                    (cdr (assq 'message response))
                    (cdr (assq 'error response))
                    nil)))))

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
                        (let* ((response
                                (condition-case err
                                    (progn
                                      (dsh-emacs--decode-response-body)
                                      (goto-char (point-min))
                                      (json-read))
                                  (error
                                   ;; 体无法解析（非 JSON、断流等）：打印缘由
                                   ;; 但仍把回调派发出去（ok=nil），调用方因此
                                   ;; 总能走到自己的失败分支，而不是被静默丢弃。
                                   (message "RPC response error: %s"
                                            (error-message-string err))
                                   nil)))
                               (unwrapped (and response
                                               (dsh-emacs--unwrap-response
                                                response))))
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
Updates the mode-line name (list title), the workspace directory, and
feeds each buffer's mode-line stats the server `contextPressure' snapshot (ctx%
segment) so it matches the freshly fetched list."
  (maphash (lambda (session-id buf)
             (dsh-emacs--chat-buffer-sync session-id)
             (dsh-emacs--chat-buffer-context-sync session-id buf))
           dsh-emacs--chat-buffers))

(defun dsh-emacs--chat-buffer-context-sync (session-id buf)
  "Push SESSION-ID's server contextPressure snapshot into BUF's mode line.
Pulled from the cached session struct (protocol accessors), so the same
projection pair (pressure, window) always lands together — the ctx% stays
consistent across model switches.
The row is only trusted when it carries a COMPLETE pair: `session.list`'s
projection column is explicitly partial (missing cells and
not-yet-materialized rows are served without `contextPressure'), and a
failed model run can leave the cell without `contextWindow'.  Wiping the
mode-line from such a row would blink out a previously correct ctx% until
the live `session/projection' frame lands the real pair; an incomplete row
therefore leaves the buffer's snapshot untouched, exactly like a session
missing from the cache (first open of a brand-new session, list not
fetched — `dsh-emacs--link-session-preset' brings the list back and the
fetch there re-runs this sync and fills the snapshot in)."
  (when (buffer-live-p buf)
    (let ((item (dsh-emacs--chat-session-item session-id)))
      (when item
        (let ((pressure (dsh-protocol-session-context-pressure item))
              (window (dsh-protocol-session-context-window item)))
          (when (and (integerp pressure) (integerp window) (> window 0))
            (with-current-buffer buf
              (dsh-emacs-modeline-set-context-snapshot pressure window))))))))

(defun dsh-emacs--chat-buffer-model-sync (session-id buf)
  "Feed BUF's mode-line model/effort/provider for SESSION-ID.
The session list carries no model field, so the only authoritative source
is `session.models': its `current' is the live (provider, model,
reasoningEffort) triple.  Seeding the mode-line with
`dsh-emacs-default-model' instead used to show the wrong model for every
session not running that default (the guess stuck whenever the history
window held no `request/header' to correct it).  Until the RPC lands the
model segment keeps rendering whatever it has — `dsh-emacs-default-model'
remains the segment-level fallback, which is genuinely right for a
session just created with it."
  (dsh-emacs--rpc-async "session.models"
                        `((sessionId . ,session-id))
                        (lambda (ok value)
                          (when (and ok (buffer-live-p buf))
                            (with-current-buffer buf
                              (when (equal session-id dsh-emacs--buffer-session)
                                (let ((current (and (listp value)
                                                    (dsh-protocol-model-directory-current
                                                     (dsh-protocol-model-directory--from-alist
                                                      value)))))
                                  (when current
                                    (dsh-emacs-modeline-set-model
                                     (dsh-protocol-model-selection-model current))
                                    (dsh-emacs-modeline-set-provider
                                     (dsh-protocol-model-selection-provider current))
                                    (dsh-emacs-modeline-set-effort
                                     (dsh-protocol-model-selection-reasoning-effort
                                      current))))))))))

;;;###autoload
(defun dsh-emacs-list-sessions--fetch ()
  "Fetch the session list via RPC and populate `dsh-emacs--sessions'."
  (dsh-emacs--rpc-async "session.list" nil
                        (lambda (ok value)
                          (unwind-protect
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
                                (message "Failed to fetch session list: %S" value))
                            ;; Snapshot installed: replay any frame that arrived
                            ;; while the refresh was in flight, so the list never
                            ;; rolls back below the stream's latest state.
                            (dsh-emacs-events--host-refresh-drain)))))

(defun dsh-emacs-list-sessions--fetch-when-ready (attempts)
  "Poll until the server is alive, then fetch the session list.
ATTEMPTS counts remaining retries (0.5 s apart).  Gives up silently
after exhausting attempts so the user is not spammed with errors."
  (if (dsh-emacs--server-alive-p)
      (dsh-emacs-list-sessions--fetch)
    (if (> attempts 0)
        (run-at-time 0.5 nil #'dsh-emacs-list-sessions--fetch-when-ready
                     (1- attempts))
      (message "dsh: server did not become ready — retry with M-x dsh-emacs"))))

(defun dsh-emacs-list-sessions ()
  "Fetch the session list and refresh workspaces."
  (interactive)
  ;; Non-blocking: launch the server in the background if needed.
  ;; When the server was just started, poll until it's ready before
  ;; firing the RPC to avoid a 404 race.
  (let ((alive (dsh-emacs-server-start)))
    (dsh-emacs-events--host-refresh-begin)
    (if alive
        (dsh-emacs-list-sessions--fetch)
      ;; Server just launched — wait for it (up to ~5 s).
      (dsh-emacs-list-sessions--fetch-when-ready 10))))

;;;###autoload
(defun dsh-emacs--new-session-workspace ()
  "Resolve the workspace to create the next session in, or nil.
Precedence: the workspace under point (session list header / New Session
row), then — inside a chat buffer — the current session's workspace.
Nil means create in CWD (session lands in the Ungrouped bucket)."
  (or (dsh-emacs-workspace-id-at-point)
      (and (derived-mode-p 'dsh-emacs-mode)
           (dsh-emacs--workspace-for-session
            (dsh-emacs--active-session-id)))))

;;;###autoload
(defun dsh-emacs-new-session (&optional cwd workspace-id preset)
  "Create a new session.
CWD is the working directory; with WORKSPACE-ID the session is created
inside that workspace (`session.create' takes workspaceId rather than
cwd).  PRESET is the agentPreset id the session starts on; nil lets the
host pick its default preset.

Interactively, when point sits on a workspace header or its empty
New Session row (in the session list), the session is created in that
workspace; inside a chat buffer, it is created in the current session's
workspace; otherwise in CWD.  With a prefix argument, first choose the
agent preset from the live `agentPreset.list' roster (falling back to
the built-in presets before the first roster arrives); without one
the session uses `dsh-emacs-default-preset'."
  (interactive
   (let ((ws (dsh-emacs--new-session-workspace)))
     (list nil ws
           (if current-prefix-arg
               (dsh-emacs--read-preset dsh-emacs-default-preset)
             dsh-emacs-default-preset))))
  (dsh-emacs-server-ensure)
  (dsh-emacs--rpc-async "session.create"
                        (append (if workspace-id
                                    `((workspaceId . ,workspace-id))
                                  `((cwd . ,(dsh-emacs--absolute-cwd cwd))))
                                `((model . ,dsh-emacs-default-model))
                                (and preset `((agentPreset . ,preset))))
                        (lambda (ok value)
                          (if ok
                              (let ((session-id (cdr (assq 'sessionId value))))
                                ;; 把新会话补进缓存：sessions 列表 + workspace
                                ;; session-ids（分组归属）——否则它落到 ungrouped
                                ;; 且 `session/title' 事件找不到缓存 item，自动
                                ;; 重命名无法实时生效。创建响应携带 agentPreset
                                ;; 时一并入缓存，列表详情/页脚预设立即可见。
                                (dsh-emacs--cache-new-session
                                 session-id workspace-id
                                 (cdr (assq 'agentPreset value)))
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

;;;###autoload
(defun dsh-emacs-new-session-choose-preset ()
  "Create a new session after choosing its agent preset.
Like `dsh-emacs-new-session' (the workspace under point, or the current
chat session's workspace, decides the creation context), but always reads
the preset first — bound to `C' in the session list, next to `c' which
creates immediately with `dsh-emacs-default-preset'.  C-g during the
preset prompt cancels the creation."
  (interactive)
  (dsh-emacs-server-ensure)
  (dsh-emacs-new-session nil (dsh-emacs--new-session-workspace)
                         (dsh-emacs--read-preset dsh-emacs-default-preset)))

(defun dsh-emacs--cache-new-session (session-id &optional workspace-id preset)
  "Cache the freshly created SESSION-ID so grouping and title updates work
before the next `session.list' refresh: insert a placeholder row (blank,
\"New Session\", PRESET when given) into `dsh-emacs--sessions' and, with
WORKSPACE-ID, append SESSION-ID to that workspace's `session-ids' (the
group renderer assigns sessions to workspaces from those ids).  Repaints
the session list.

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
               (append (list (cons 'sessionId session-id)
                             (cons 'blank t)
                             (cons 'cwd cwd))
                       (and preset (list (cons 'agentPreset preset)))))
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

;; ---------------------------------------------------------------------------
;;  新建会话的 agent preset（agentPreset）选择
;; ---------------------------------------------------------------------------

(defun dsh-emacs--agent-presets-refresh ()
  "Refresh `dsh-emacs--agent-presets' from `agentPreset.list'.
Async: the response lands in the cache when it arrives; a failed RPC
leaves the previous cache (when any) untouched.  Returns nothing."
  (dsh-emacs--rpc-async "agentPreset.list" nil
                        (lambda (ok value)
                          (when ok
                            (setq dsh-emacs--agent-presets
                                  (dsh-protocol-agent-preset-list--from-alist
                                   value))))))

(defconst dsh-emacs--preset-display-name-mapping
  '(("standard" . "Standard mode")
    ("minimal" . "Minimal mode")
    ("code" . "PTC mode")
    ("cordis" . "Creator mode"))
  "Mapping (PRESET-ID . DISPLAY-NAME) of each shipped system preset.

The dsh web resolves these presets' option labels through exactly this
built-in key map (`presetDisplayText' in the web's agent-preset UI) —
`agentPreset.list' carries no `name' for them.  The picker mirrors the
mapping so the Emacs choices read the same as the web's.")

(defun dsh-emacs--preset-display-name (preset)
  "Web-consistent display name of roster row PRESET.
Mirrors the web's `presetDisplayText': a system preset among the shipped
built-ins shows its web name (\"Standard mode\" …); anything else shows
its published `name', falling back to the id.  PRESET is a
`dsh-protocol-agent-preset' struct or wire alist."
  (let* ((p (dsh-protocol--struct #'dsh-protocol-agent-preset-p
                                  #'dsh-protocol-agent-preset--from-alist
                                  preset))
         (id (dsh-protocol-agent-preset-id p)))
    (or (and (equal "system" (dsh-protocol-agent-preset-trust p))
             (cdr (assoc id dsh-emacs--preset-display-name-mapping)))
        (dsh-protocol-agent-preset-name p)
        id)))

(defun dsh-emacs--preset-choices ()
  "((DISPLAY . ID) ...) preset choices for the new-session picker.
From the cached `agentPreset.list' roster (broken entries excluded),
each DISPLAY matches what the dsh web shows for that preset — the web
name for the shipped system presets (\"Standard mode\" …), the
published `name' (or the id) for everything else.  Before the first
roster arrives, the four built-in presets are offered with their web
names."
  (let ((presets (and dsh-emacs--agent-presets
                      (dsh-protocol-agent-preset-list-presets
                       dsh-emacs--agent-presets))))
    (if presets
        (delq nil
              (mapcar
               (lambda (p)
                 (unless (dsh-protocol-agent-preset-broken p)
                   (cons (dsh-emacs--preset-display-name p)
                         (dsh-protocol-agent-preset-id p))))
               presets))
      (mapcar (lambda (pair) (cons (cdr pair) (car pair)))
              dsh-emacs--preset-display-name-mapping))))

(defun dsh-emacs--preset-default-id (&optional default)
  "Preset id the new-session picker pre-selects, or nil.
DEFAULT (the configured `dsh-emacs-default-preset') wins when it is a
valid choice; otherwise the roster's `isDefault' preset; otherwise nil
(no pre-selection)."
  (let ((choices (dsh-emacs--preset-choices)))
    (or (and default (rassoc default choices) default)
        (let ((presets (and dsh-emacs--agent-presets
                            (dsh-protocol-agent-preset-list-presets
                             dsh-emacs--agent-presets))))
          (cl-some (lambda (p)
                     (and (dsh-protocol-agent-preset-is-default p)
                          (dsh-protocol-agent-preset-id p)))
                   presets)))))

(defun dsh-emacs--read-preset (&optional default)
  "Read an agent preset id for a new session; nil keeps the host default.
Choices come from the cached `agentPreset.list' roster (the built-in
presets with their web names before the first fetch); a background
refresh is kicked off so the next pick sees fresh entries.  Pre-selects
DEFAULT (the configured `dsh-emacs-default-preset') when it is a valid
choice, else the host's `isDefault' preset — an empty RET accepts the
pre-selection; without any pre-selection picking is required (unknown
input is rejected).  C-g cancels the whole session creation."
  (dsh-emacs--agent-presets-refresh)
  (let* ((default-id (dsh-emacs--preset-default-id default))
         (choices (dsh-emacs--preset-choices))
         (default-name (and default-id
                            (car (rassoc default-id choices))))
         (picked (completing-read
                  (format "Agent preset for the new session%s: "
                          (if default-name
                              (format " (default %s)" default-name)
                            ""))
                  choices nil t nil nil default-name)))
    (cond ((and picked (not (string-empty-p picked)))
           (or (cdr (assoc picked choices)) default-id))
          (default-name default-id)
          (t nil))))

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

(defun dsh-emacs--lock-cursor-to-input ()
  "Clamp the cursor to the end of the editable input area (post-command).
Moving up into the read-only transcript to read history is allowed; only
positions BELOW the input area are clamped back to its end.  The clamp is
area-based (`dsh-emacs--input-end'), not line-based, so a multi-line input
is unaffected — the cursor may roam anywhere inside the editable region.
Runs in every dsh-emacs-mode buffer (buffer-local hook) independent of the
global `dsh-emacs--current-buffer', so it also holds in an inactive chat
buffer while another session is the last-opened one."
  (dsh-emacs--ensure-input-marker)
  (when (and dsh-emacs--input-marker
             (markerp dsh-emacs--input-marker)
             (eq (marker-buffer dsh-emacs--input-marker) (current-buffer)))
    (let* ((marker-pos (marker-position dsh-emacs--input-marker))
           (input-end (max marker-pos (dsh-emacs--input-end))))
      (when (> (point) input-end)
        (goto-char input-end)))))

(defun dsh-emacs--route-typing-to-input ()
  "When about to type or edit while point is in the read-only region, first\nmove the cursor back to the input area after `❯ '.\n
Used with `dsh-emacs--reveal-input-when-typing': typing directly in the\nread-only area would trigger `text-read-only'; this moves point into the\ninput area before the command runs, so typing no longer errors\nand the input area scrolls into view automatically."
  (when (and (memq this-command
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
  (when (and (window-live-p (get-buffer-window (current-buffer) t))
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


;;;###autoload
(defun dsh-emacs-open-session (session-id)
  "Open session SESSION-ID.
Connects a per-session mux stream for the chat buffer WITHOUT touching
other open sessions' streams: with several chats live, each buffer keeps
its own realtime stream (tearing the previous one down here used to
leave it stream-less — unable to ever switch back to
realtime)."
  (interactive)
  (dsh-emacs-server-ensure)
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
      (dsh-emacs-modeline-setup)
      ;; 默认模型只作段级兜底立即显示；权威的 (provider, model, effort)
      ;; 由 session.models 异步落地 —— 盲信默认值曾是 mode-line 显示错
      ;; 模型的根因（见 `dsh-emacs--chat-buffer-model-sync'）。
      (dsh-emacs-modeline-set-model dsh-emacs-default-model)
      (dsh-emacs--chat-buffer-model-sync session-id buf)
      ;; 打开即把服务器 contextPressure 快照喂给 mode-line 段。必须在
      ;; `dsh-emacs-mode'（define-derived-mode 内部 kill-all-local-variables）
      ;; 与 `dsh-emacs-modeline-setup' 之后：此前喂入的 buffer-local 快照会
      ;; 被 mode 切换整个清掉，ctx% 就永远不显示（首次打开的经典症状）。
      (dsh-emacs--chat-buffer-context-sync session-id buf)
      ;; 思考预设（agentPreset）来自会话列表缓存；缺失时补拉一次 session.list。
      (dsh-emacs--link-session-preset session-id)
      ;; Reopening must re-render: `dsh-emacs--anchor-seq' gates the seq
      ;; filter in `dsh-emacs-render-history-events', and a reused buffer
      ;; keeps the previous maximum, which would filter out the freshly
      ;; fetched history (and with it the usage/model feed) entirely.
      (setq dsh-emacs--anchor-seq 0)
      ;; 空闲预取 slash 命令目录（commands.list）：首次 "/" / TAB 不再同步
      ;; 往返阻塞。目录按会话缓存，打开即有 session-id 才拉得了。
      (dsh-emacs-command-catalog-prefetch session-id)
      ;; Mode-line setup appends its anchor newline at point-max.  Return point
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
    (pop-to-buffer dsh-emacs--current-buffer)))

;; ---------------------------------------------------------------------------
;;  在同一 workspace 内切换 session（chat buffer 中直接切）
;; ---------------------------------------------------------------------------

(defun dsh-emacs--workspace-sessions (workspace-id)
  "Return SESSIONS belonging to WORKSPACE-ID, excluding archived,
subagent and blank rows.  Returns a list of session structs in recency
order."
  (let ((ws-by-id
         (catch 'found
           (dolist (ws dsh-emacs--workspaces)
             (when (equal workspace-id
                            (dsh-protocol-workspace-workspace-id ws))
               (throw 'found ws))))))
    (if (null ws-by-id)
        nil
      (let ((session-ids (dsh-protocol-workspace-session-ids ws-by-id)))
        (dsh-emacs-session--sort-by-recency
         (cl-remove-if
          (lambda (s)
            (or (not (dsh-emacs-session--visible-p s))
                (not (member (dsh-protocol-session-session-id s)
                             session-ids))))
          dsh-emacs--sessions))))))

(defun dsh-emacs--workspace-label (workspace-id)
  "Human label of WORKSPACE-ID: title, else path basename, else the id."
  (or (dsh-emacs--workspace-title workspace-id)
      (dsh-emacs-session--workspace-basename
       (dsh-emacs--workspace-path workspace-id))
      workspace-id))

(defun dsh-emacs--switch-prompt (workspace-id &optional all)
  "Return the completing-read prompt for switching sessions.
WORKSPACE-ID scopes the prompt to one workspace; non-nil ALL asks
across all workspaces."
  (cond
   (all "Switch session (all workspaces): ")
   (workspace-id (format "Switch session in %s: "
                         (dsh-emacs--workspace-label workspace-id)))
   (t "Switch session: ")))

(defun dsh-emacs--workspace-title (workspace-id)
  "Return the title of the workspace with WORKSPACE-ID, or nil."
  (catch 'found
    (dolist (ws dsh-emacs--workspaces)
      (when (equal workspace-id (dsh-protocol-workspace-workspace-id ws))
        (throw 'found (dsh-protocol-workspace-title ws))))))

(defun dsh-emacs--workspace-path (workspace-id)
  "Return the path of the workspace with WORKSPACE-ID, or nil."
  (catch 'found
    (dolist (ws dsh-emacs--workspaces)
      (when (equal workspace-id (dsh-protocol-workspace-workspace-id ws))
        (throw 'found (dsh-protocol-workspace-path ws))))))

(defun dsh-emacs--workspace-for-session (session-id)
  "Return the workspace id SESSION-ID belongs to, or nil when ungrouped."
  (catch 'found
    (dolist (ws dsh-emacs--workspaces)
      (when (member session-id (dsh-protocol-workspace-session-ids ws))
        (throw 'found (dsh-protocol-workspace-workspace-id ws))))))

;; `ivy-mode' 开启时 `ivy-sort-functions-alist' 接管排序；开关我们按用户
;; 实际启用的补全框架适配（见 `dsh-emacs--completing-read-ordered'）。
;; defvar 声明只为消 byte-compile 警告并保证动态绑定；框架未加载时无副作用。
(defvar ivy-sort-functions-alist)

(defun dsh-emacs--completing-read-ordered (prompt collection &rest args)
  "`completing-read'，但保持 COLLECTION 传入顺序不被补全框架重排。
按用户实际启用的补全框架适配，不写死任何一家：
- vertico / corfu / stock minibuffer：读取 completion metadata 的
  `display-sort-function'（vertico--sort-function / corfu 均优先于各自
  的排序开关），这里把它设为 identity，框架自动放弃重排；
- ivy：不读该 metadata，按 collection/caller 从 `ivy-sort-functions-alist'
  取排序函数——动态绑定为 ((t . nil))（docstring: nil = no sorting），
  仅本次调用生效；
- 其余框架（selectrum 等）同样遵循 display-sort-function 约定。
PROMPT/COLLECTION/ARGS 语义与 `completing-read' 完全一致。"
  (let ((ordered (completion-table-with-metadata
                  collection
                  '((display-sort-function . identity)))))
    (if (bound-and-true-p ivy-mode)
        (let ((ivy-sort-functions-alist '((t))))
          (apply #'completing-read prompt ordered args))
      (apply #'completing-read prompt ordered args))))

(defun dsh-emacs--sessions-index ()
  "Hash table session-id → session struct for `dsh-emacs--sessions'.
Indexing once keeps repeated per-candidate title lookups O(1) instead of
the linear scan in `dsh-emacs--chat-session-item' (switching over
hundreds of sessions makes the scan quadratic)."
  (let ((index (make-hash-table :test 'equal
                                :size (length dsh-emacs--sessions))))
    (dolist (s dsh-emacs--sessions)
      (puthash (dsh-protocol-session-session-id s) s index))
    index))

(defun dsh-emacs--workspaces-by-session ()
  "Hash table session-id → owning workspace-id for `dsh-emacs--workspaces'."
  (let ((index (make-hash-table :test 'equal
                                :size (length dsh-emacs--sessions))))
    (dolist (ws dsh-emacs--workspaces)
      (let ((ws-id (dsh-protocol-workspace-workspace-id ws)))
        (dolist (sid (dsh-protocol-workspace-session-ids ws))
          (puthash sid ws-id index))))
    index))

(defun dsh-emacs--switch-entry-label (session &optional session-index ws-index ws-label-fn)
  "Completion label for SESSION when switching across workspaces:
display title followed by the owning workspace title, so same-titled
sessions from different workspaces stay tellable apart.  SESSION-INDEX
(session-id → struct) and WS-INDEX (session-id → workspace-id) make the
lookups O(1) over many sessions; WS-LABEL-FN maps a workspace-id to its
display label (default `dsh-emacs--workspace-label', which re-scans
`dsh-emacs--workspaces' per call — pass a memoized resolver when the
candidate list is large)."
  (let* ((id (dsh-protocol-session-session-id session))
         (item (if session-index
                   (gethash id session-index)
                 (dsh-emacs--chat-session-item id)))
         (title (or (and item (dsh-emacs-session--display-title item)) id))
         (ws-id (if ws-index
                    (gethash id ws-index)
                  (dsh-emacs--workspace-for-session id))))
    (if ws-id
        (format "%s (%s)" title
                (if ws-label-fn
                    (funcall ws-label-fn ws-id)
                  (dsh-emacs--workspace-label ws-id)))
      title)))

(defun dsh-emacs--switch-candidates (vec string limit)
  "Bound the candidate universe VEC delivers to the completion UI.
VEC holds (LABEL . ID) pairs in recency order; STRING is the current
minibuffer input; LIMIT caps the empty-input offer.  On empty input only
the first LIMIT (most recently active) labels are handed over, so
sustained navigation rebuilds a small list per keystroke instead of a
multi-hundred one — the in-memory equivalent of counsel-rg consuming its
subprocess output in bounded increments.  Once the user types a filter
the full universe is returned and the user's `completion-styles' narrow
it as usual, so older sessions stay reachable."
  (let ((out nil)
        (n 0))
    (if (not (string-empty-p string))
        (cl-loop for rec across vec collect (car rec))
      (catch 'limit
        (cl-loop for rec across vec
                 do (push (car rec) out)
                 (setq n (1+ n))
                 when (>= n limit)
                 do (throw 'limit (nreverse out)))
        (nreverse out)))))

(defun dsh-emacs--switch-table (vec limit)
  "Function completion table over VEC of (LABEL . ID) pairs.
Hands the completion framework a bounded candidate universe (see
`dsh-emacs--switch-candidates') with standard programmed-completion
semantics: trivial boundaries/metadata, and the entries the framework
filters with the user's `completion-styles'."
  (lambda (string _pred action)
    (if (or (eq (car-safe action) 'boundaries) (eq action 'metadata))
        nil
      (let ((cands (dsh-emacs--switch-candidates vec string limit)))
        (complete-with-action action cands string _pred)))))

(defun dsh-emacs--switch-id-table (vec)
  "Hash display label → session id for VEC; the most recent one wins.
Labels are not guaranteed unique across sessions (same title in one
workspace), so first-write wins to keep the recency-first pick."
  (let ((table (make-hash-table :test 'equal :size (length vec))))
    (cl-loop for rec across vec
             unless (gethash (car rec) table)
             do (puthash (car rec) (cdr rec) table))
    table))

(defun dsh-emacs--switch-title (session &optional session-index)
  "Display title for SESSION: the list-row title, else the session id.
SESSION-INDEX (session-id → struct) makes the lookup O(1) over many
sessions; it defaults to building one from `dsh-emacs--sessions'."
  (let* ((id (dsh-protocol-session-session-id session))
         (index (or session-index (dsh-emacs--sessions-index)))
         (item (gethash id index)))
    (or (and item (dsh-emacs-session--display-title item)) id)))

(defun dsh-emacs--switch-entry-labels (candidates session-index ws-index ws-label)
  "Return the (LABEL . ID) completion entries for CANDIDATES.
Labels are the bare display titles: workspace names never take part in
filtering, so typing a workspace name does not narrow the list.  A
workspace title is appended (via `dsh-emacs--switch-entry-label') only
when several candidates share one display title — the disambiguator that
keeps same-titled sessions from different workspaces selectable — and the
session id if that still collides.  Preserves CANDIDATES' (recency)
order."
  (let ((counts (make-hash-table :test 'equal))
        (seen (make-hash-table :test 'equal))
        (entries nil))
    ;; 第一遍：统计显示标题出现次数（重复标题需要 workspace 消歧）
    (dolist (s candidates)
      (let ((title (dsh-emacs--switch-title s session-index)))
        (puthash title (1+ (gethash title counts 0)) counts)))
    ;; 第二遍：构建 (label . id)，唯一标题裸显示
    (dolist (s candidates)
      (let* ((id (dsh-protocol-session-session-id s))
             (title (dsh-emacs--switch-title s session-index))
             (label (if (> (gethash title counts 0) 1)
                        (dsh-emacs--switch-entry-label
                         s session-index ws-index ws-label)
                      title)))
        (if (gethash label seen)
            (let ((final (format "%s · %s" label id)))
              (puthash final t seen)
              (setq entries (cons (cons final id) entries)))
          (progn
            (puthash label t seen)
            (setq entries (cons (cons label id) entries))))))
    (nreverse entries)))

;;;###autoload
(defun dsh-emacs-switch-workspace-session (&optional all)
  "Switch to another session in the same workspace as the current one.
Prompts for a session from the current workspace's session list; opens or
focuses its chat buffer on selection.  The current session itself is
never offered.  When all sessions are in the Ungrouped bucket (no known
workspaces), falls back to switching any cached session.

With prefix argument ALL, or via `dsh-emacs-switch-session', offer
every visible session across all workspaces (the Ungrouped bucket
included) instead; workspace names never take part in filtering — they
disambiguate only same-titled sessions.

The completion list is capped at `dsh-emacs-switch-max-candidates'
entries while the input is empty (recency-first; type to narrow the full
set), so navigating a large session list never churns a multi-hundred
candidate rebuild per keystroke — mirroring how counsel-rg consumes its
results in bounded increments."
  (interactive "P")
  (dsh-emacs-server-ensure)
  (let* ((session-id (dsh-emacs--active-session-id))
         (workspace-id (unless all (dsh-emacs--workspace-for-session session-id)))
         ;; 每次调用只建一次索引：逐候选的标题/工作区查询从线性扫描
         ;; （O(n)/O(n·m)）降为哈希 O(1)，会话多时不再卡。
         (session-index (dsh-emacs--sessions-index))
         (ws-index (dsh-emacs--workspaces-by-session))
         ;; 工作区显示名记忆化：每个 workspace 只算一次
         ;; （`dsh-emacs--workspace-label' 每次调用都线性扫 workspace 列表）。
         (ws-label-cache (make-hash-table :test 'equal))
         (ws-label (lambda (ws-id)
                     (or (gethash ws-id ws-label-cache)
                         (puthash ws-id
                                  (dsh-emacs--workspace-label ws-id)
                                  ws-label-cache))))
         (candidates
          (cl-remove-if
           (lambda (s)
             (equal (dsh-protocol-session-session-id s) session-id))
           (if workspace-id
               ;; 同 workspace 的成员已按可见规则（非归档/subagent/blank）
               ;; 过滤并按活跃时间排序。
               (dsh-emacs--workspace-sessions workspace-id)
             (dsh-emacs-session--sort-by-recency
              (cl-remove-if-not #'dsh-emacs-session--visible-p
                                dsh-emacs--sessions))))))
    (if (null candidates)
        (message (if all
                     "No other sessions"
                   "No other sessions in this workspace"))
      (let* ((entries (dsh-emacs--switch-entry-labels
                         candidates session-index ws-index ws-label))
             (vec (vconcat entries))
             (id-table (dsh-emacs--switch-id-table vec))
             (table (dsh-emacs--switch-table
                     vec dsh-emacs-switch-max-candidates))
             (picked (dsh-emacs--completing-read-ordered
                      (dsh-emacs--switch-prompt workspace-id all)
                      table nil t)))
        (when picked
          (let ((target-id (gethash picked id-table)))
            (when target-id
              (dsh-emacs-open-session target-id))))))))

;;;###autoload
(defun dsh-emacs-switch-session ()
  "Switch to another session across ALL workspaces (Ungrouped included).
The all-workspaces counterpart of `dsh-emacs-switch-workspace-session':
every visible session is offered (workspace names only disambiguate
same-titled sessions), and the current session itself is never offered."
  (interactive)
  (dsh-emacs-switch-workspace-session 'all))

(defun dsh-emacs--completing-session-id (prompt)
  "Read a session id with completion against the cached session list.
Choices show the display title (like the list); the returned value is
always the session id."
  (let* ((index (dsh-emacs--sessions-index))
         (entries (mapcar (lambda (s)
                            (let* ((id (dsh-protocol-session-session-id s))
                                   (item (gethash id index)))
                              (cons (format "%-30s  %s"
                                            (or (and item
                                                     (dsh-emacs-session--display-title item))
                                                id)
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
  (dsh-emacs-server-ensure)
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
  "Fill the mode-line agent preset for SESSION-ID.
Uses the cached session list when possible; otherwise refreshes
`session.list' once and picks the preset from the response.  SAFE outside a
chat buffer (the RPC callback runs in the buffer that called this).
The lazy fetch also covers the ctx% snapshot on first open: a session
missing from `dsh-emacs--sessions' has no `contextPressure' to feed the
mode-line either (see `dsh-emacs--chat-buffer-context-sync'), so the same
fetch — whose callback calls `dsh-emacs--chat-buffers-sync-all' — brings
preset, context snapshot, title and workspace in one round trip."
  (let ((preset (dsh-emacs--session-preset session-id))
        (have-item (dsh-emacs--chat-session-item session-id)))
    (if (and preset have-item)
        (dsh-emacs-modeline-set-preset preset)
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
                                        (dsh-emacs-modeline-set-preset
                                         (dsh-protocol-session-agent-preset
                                          item))
                                        (throw 'found t)))))))))))

(defun dsh-emacs--load-history (session-id)
  "Load the session history of SESSION-ID and render it.
The transcript renders into the CURRENT buffer at call time (callers run
this in the target chat buffer); the target is captured up front so a
later `C-c C-r' issued from a chat buffer that is not the last-opened one
still renders into ITS OWN buffer, never the global
`dsh-emacs--current-buffer' of the last session opened.

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
  (let ((chat-buffer (current-buffer)))
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
turn keeps producing events) the refetch loop continues, for at most
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
  (dsh-emacs-server-ensure)
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
  (dsh-emacs-server-ensure)
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
  (dsh-emacs-server-ensure)
  (dsh-emacs-events--host-refresh-begin)
  (dsh-emacs--rpc-async "workspace.list" nil
                        (lambda (ok value)
                          (unwind-protect
                              (progn
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
                                (when (and dsh-emacs-sessions-buffer
                                           (get-buffer dsh-emacs-sessions-buffer))
                                  (with-current-buffer dsh-emacs-sessions-buffer
                                    (dsh-emacs-session--render))))
                            (dsh-emacs-events--host-refresh-drain)))))

;;;###autoload
(defun dsh-emacs-create-workspace (path)
  "Create a workspace.  PATH is the path of an existing directory."
  (interactive "DWorkspace directory: ")
  (dsh-emacs-server-ensure)
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
  (dsh-emacs-server-ensure)
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
  (dsh-emacs-server-ensure)
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
  (dsh-emacs-server-ensure)
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
    (define-key map (kbd "C-c C-s") #'dsh-emacs-switch-workspace-session)
    (define-key map (kbd "C-c M-s") #'dsh-emacs-switch-session)
    (define-key map (kbd "C-c C-w") #'dsh-emacs-copy-transcript)
    (define-key map (kbd "C-c C-f") #'dsh-emacs-modeline-toggle)
    (define-key map (kbd "C-c C-k") #'dsh-emacs-copy-code-block)
    (define-key map (kbd "C-c C-a") #'dsh-emacs-attach-file)
    (define-key map (kbd "C-c C-m") #'dsh-emacs-select-model)
    (define-key map (kbd "M-p") #'dsh-emacs-input-history-back)
    (define-key map (kbd "M-n") #'dsh-emacs-input-history-forward)
    ;; 输入区以 "/" 开头时 TAB 补全 slash 命令名（无论弹出菜单是否开着）
    (define-key map (kbd "TAB") #'completion-at-point)
    (define-key map [drag-n-drop] #'dsh-emacs--dnd-attach)
    map)
  "Keymap for chat mode.")

(defvar corfu-auto-trigger ""
  "Corfu's auto-completion trigger characters (defined by corfu when loaded).
Chat buffers append \"/\" buffer-locally so typing a slash pops the
slash-command list via corfu's own mechanism; the stub keeps
byte-compilation clean when corfu is absent.")

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

(defun dsh-emacs-imenu-create-user-index ()
  "Build an imenu index of user messages in the current buffer.
Each entry maps a human-readable label to the message's start position.
Users can jump to any historical input via `M-x imenu' (or consult-imenu,
vertico, etc.)."
  (let ((index '()))
    (save-excursion
      (goto-char (point-min))
      (while (< (point) (point-max))
        (let ((pos (next-single-property-change (point) 'dsh-emacs-user-message nil (point-max))))
          (if (>= pos (point-max))
              (goto-char (point-max))
            (goto-char pos)
            (when (get-text-property pos 'dsh-emacs-user-message)
              (let* ((line-num (line-number-at-pos pos))
                     (line-end (line-end-position))
                     (raw (buffer-substring-no-properties pos line-end))
                     (content (if (string-prefix-p "\u276f " raw)
                                  (substring raw 2)
                                raw))
                     (preview (if (> (length content) 60)
                                  (concat (substring content 0 57) "...")
                                content))
                     (label (format "%d: %s" line-num preview)))
                (push (cons label pos) index)))
            (goto-char (1+ pos))))))
    (nreverse index)))

(define-derived-mode dsh-emacs-mode fundamental-mode "DSH"
  "DeepSeek Harness chat mode.
\\{dsh-emacs-mode-map}"
  (setq buffer-read-only nil)
  (setq truncate-lines nil)
  (setq word-wrap t)
  ;; telega-style scroll discipline: with point in the input area, vertical
  ;; scrolling keeps the `❯' line visible (recenters rather than jumping far
  ;; away), page commands land on line boundaries, and scrolling past the
  ;; top/bottom wraps to the other end instead of erroring.
  (setq-local scroll-conservatively 101)
  (setq-local next-screen-context-lines 0)
  (setq-local scroll-error-top-bottom t)
  (setq-local buffer-invisibility-spec '(t))
  (setq-local line-spacing 0.15)
  (buffer-disable-undo)
  (setq-local comment-start "// ")
  (setq-local comment-end "")
  ;; 输入区以 "/" 开头时，TAB 补全 slash 命令名（见 dsh-emacs-command.el）
  (setq-local completion-at-point-functions
              '(dsh-emacs-command-completion-at-point))

  ;; imenu: 按 user message 索引，M-x imenu 可跳转到任意历史输入
  (setq-local imenu-create-index-function #'dsh-emacs-imenu-create-user-index)

  ;; Mode-line 拼接由 `dsh-emacs-modeline-setup' 完成（会话创建时调用），
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
  ;; 输入区出现 "/name" 前缀时自动弹出 slash 命令补全（内容驱动；
  ;; corfu 用户的自动弹由 corfu-auto 接管，见下）
  (add-hook 'post-command-hook #'dsh-emacs--slash-auto-complete nil t)
  ;; corfu 用户的 slash 补全：把 "/" 加进 `corfu-auto-trigger'，输入 "/" 时
  ;; corfu 立即（无视 corfu-auto-prefix）查询 capf 并弹命令列表——官方机制、
  ;; 零自建定时器，popup 开启后继续输入由 corfu 自己过滤。corfu 未加载或
  ;; corfu-auto 未安装的环境（stock *Completions* 等）由上面的
  ;; `dsh-emacs--slash-auto-complete' 走 completion-at-point 兜底——因此这里
  ;; 必须用 `require' 返回值把关：装了 corfu 但没装 corfu-auto 时既不能把
  ;; `corfu-auto' 置为 t（否则上面的兜底被禁用、弹出彻底失效），也不能挂
  ;; 未定义的 `corfu-auto--post-command'（void-function）。
  (when (and dsh-emacs-slash-auto-complete (boundp 'corfu-mode)
             (require 'corfu-auto nil t)
             (fboundp 'corfu-auto--post-command))
    (setq-local corfu-auto t)
    ;; 保留用户自定的 trigger 字符，追加 "/"
    (setq-local corfu-auto-trigger
                (concat (if (stringp corfu-auto-trigger)
                            corfu-auto-trigger
                          "")
                        "/"))
    (add-hook 'post-command-hook #'corfu-auto--post-command 10 t))
  (setq dsh-emacs--tool-calls (make-hash-table :test 'equal))
  (setq dsh-emacs--activity-groups (make-hash-table :test 'equal))
  (setq dsh-emacs--pending-user-messages nil
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
      ;; Do not let properties leak into the input inserted at the end of the
      ;; prompt.  Text properties are sticky by default, so inserting
      ;; immediately after the prompt would otherwise inherit them:
      ;;  - `read-only': would signal `text-read-only' even though the
      ;;    insertion point itself has no `read-only' property.
      ;;  - `face` / `font-lock-face': typing runs `insert-and-inherit'
      ;;    (Emacs 31 `self-insert-command'), which copies the previous
      ;;    character's face.  Without the exclusion, manual input after
      ;;    `❯ ' inherited the prompt's accent face (blue) while pasted
      ;;    (`yank' strips faces) or completed (plain `insert') text stayed
      ;;    default coloured — the "half blue, half white" input line.
      (put-text-property welcome-start (point) 'rear-nonsticky
                         '(read-only face font-lock-face)))
    ;; 标记输入开始位置（marker 会自动跟随文本插入/删除）
    (setq dsh-emacs--input-marker (point-marker))))

(defun dsh-emacs--ensure-input-area ()
  "Ensure the input area exists and point is at the right position."
  (unless (and dsh-emacs--input-marker (marker-buffer dsh-emacs--input-marker))
    (dsh-emacs--setup-input-area))
  (goto-char dsh-emacs--input-marker))

(defun dsh-emacs--active-session-id ()
  "Return the session id the current command context belongs to.
Resolves in this order:
1. the buffer-local `dsh-emacs--buffer-session' of the current chat buffer;
2. the global `dsh-emacs--current-session' as a fallback for list-buffer \ncommands and other contexts with no session ownership.
Interactive commands (send, interrupt, refresh, model picker) must resolve
here rather than reading the global directly: with several session buffers
open, the global points at the last-opened session while the user may be
editing inside an earlier one."
  (or (and (boundp 'dsh-emacs--buffer-session)
           dsh-emacs--buffer-session)
      dsh-emacs--current-session))

(defun dsh-emacs--busy-p ()
  "Return non-nil when this chat buffer is generating.
Consults the same buffer-local flag that drives the mode-line spinner."
  (and (boundp 'dsh-emacs--ml-busy) dsh-emacs--ml-busy))

(defun dsh-emacs--interrupt-turn ()
  "Interrupt the running turn via `session.cancel'.

The server stops the agent mid-flight; the partial reply stays in the
transcript and `turn/end' arrives normally, which clears the spinner."
  (let ((session-id (dsh-emacs--active-session-id)))
    (when (null session-id)
      (user-error "No session is open"))
    (dsh-emacs--rpc-async "session.cancel"
                          `((sessionId . ,session-id))
                          (lambda (ok value)
                            (if ok
                                (progn
                                  ;; User-initiated stop: suppress the
                                  ;; finished-run notification.
                                  (setq dsh-emacs--turn-awaiting nil)
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
  (dsh-emacs-server-ensure)
  (if (dsh-emacs--busy-p)
      (dsh-emacs--interrupt-turn)
    (let ((input (dsh-emacs--get-input)))
      (if (string-empty-p (string-trim input))
          (message "Please enter a message")
        (dsh-emacs--submit-prompt input)))))

(defun dsh-emacs--input-end ()
  "Return the end of editable input, before the mode-line separator newline."
  (let ((modeline-start (and (boundp 'dsh-emacs--modeline-overlay)
                           dsh-emacs--modeline-overlay
                           (overlay-start dsh-emacs--modeline-overlay))))
    (if (and modeline-start
             (> modeline-start (point-min))
             (eq (char-before modeline-start) ?\n))
        (1- modeline-start)
      (point-max))))

(defun dsh-emacs--get-input ()
  "Get the text in the input area, excluding the mode-line newline."
  (when (and dsh-emacs--input-marker (marker-buffer dsh-emacs--input-marker))
    (buffer-substring-no-properties dsh-emacs--input-marker
                                    (dsh-emacs--input-end))))

(defun dsh-emacs--clear-input ()
  "Clear the input area, keeping the mode-line newline."
  (when (and dsh-emacs--input-marker (marker-buffer dsh-emacs--input-marker))
    (let ((inhibit-read-only t))
      (delete-region dsh-emacs--input-marker (dsh-emacs--input-end))
      (goto-char dsh-emacs--input-marker))))

(defvar-local dsh-emacs--slash-pop-token nil
  "The /NAME token that last triggered the automatic completion popup.
Content-driven de-dup: the popup is re-triggered only after the token
text changes, so every keystroke while a command prefix is in progress
refreshes the candidate list (web-style live filtering).")

(defun dsh-emacs--slash-token ()
  "Return the in-progress /NAME token in the input area, or nil.
The token is the text from the `❯ ' prompt up to point when it is
\"/\" followed by zero or more `[a-z0-9_-]' — the web-style trigger
shape — and nil otherwise (transcript, other prefixes, a completed
token with trailing space)."
  (when (and dsh-emacs--input-marker
             (marker-buffer dsh-emacs--input-marker)
             (>= (point) dsh-emacs--input-marker))
    (let ((case-fold-search nil)
          (txt (buffer-substring-no-properties
                dsh-emacs--input-marker (point))))
      (when (string-match-p "\\`/[a-z0-9_-]*\\'" txt)
        txt))))

(defun dsh-emacs--slash-auto-complete ()
  "Pop the slash-command completion list whenever a /NAME token is in progress.
`post-command-hook' entry, content-driven (no key-event dependency):
typing \"/\" at the start of the input area immediately opens the
command catalog, and each keystroke that extends the token re-triggers
it so the list live-filters (/go narrows to /goal …).  The actual
`completion-at-point' runs on a short idle delay and re-checks the
token, so stale timers from fast typing are dropped; the completion UI
(corfu popup, stock *Completions* list, vertico in-region) renders the
candidates.  Messages that merely start with \"/\" (e.g.
\"/usr/local/...\") filter the list to nothing and keep typing
uninterrupted.

No-op when corfu auto-completion has taken over for this buffer
(`corfu-auto' is buffer-locally t): corfu's own trigger handles the
popup then, so this fallback only serves non-corfu setups."
  (when (and dsh-emacs-slash-auto-complete
             (not (and (boundp 'corfu-auto) corfu-auto))
             (let ((token (dsh-emacs--slash-token)))
               (and token (not (string= token dsh-emacs--slash-pop-token)))))
    (setq dsh-emacs--slash-pop-token (dsh-emacs--slash-token))
    (let ((buf (current-buffer)))
      (run-with-idle-timer
       0.1 nil
       (lambda ()
         (when (and (buffer-live-p buf)
                    (get-buffer-window buf)
                    (with-current-buffer buf
                      (equal (dsh-emacs--slash-token)
                             dsh-emacs--slash-pop-token)))
           (with-current-buffer buf
             (completion-at-point))))))))

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
  "Submit MESSAGE to the current session.

Slash-command lines (leading \"/name\") are routed to
`commands.execute' instead of the model: the host admits only
registered commands, and an admission miss falls back to sending the
line as an ordinary message (the same semantics as dsh web).  Other
lines go through `dsh-emacs--submit-plain' unchanged.  IMAGES, when
given, is a list of wire-ready attachment alists
\((mediaType . M) (data . B64) (name . N)); they are appended to the
`content' array of `session.prompt' as `{type: \"image\"}' parts so
the model sees them immediately."
  (if (dsh-emacs-command-parse message)
      (let ((session-id (dsh-emacs--active-session-id))
            (input-buffer (current-buffer)))
        ;; 提交即清空输入区、记入输入历史——不等 RPC 往返（网页同款手感）：
        ;; 命令是否被 host 受理由 `commands.execute' 的响应决定，结果由
        ;; command/run + command/done 会话事件渲染。
        (dsh-emacs--push-input-history message)
        (setq dsh-emacs--input-history-pos nil
              dsh-emacs--input-history-pending nil)
        (when (buffer-live-p input-buffer)
          (with-current-buffer input-buffer
            (dsh-emacs--clear-input)))
        ;; 立即渲染命令行（乐观路径）——不等 RPC 往返。
        (when (buffer-live-p input-buffer)
          (with-current-buffer input-buffer
            (dsh-emacs-render-command-optimistic message)))
        (dsh-emacs-command-execute
         session-id (string-trim message) images
         (lambda (ok execution err)
           ;; 回调可能运行在 process filter 里：吞掉 C-g 的 quit。
           (condition-case nil
               (cond
                ((null ok)
                 ;; 传输失败（HTTP/解析错误）：清除乐观行，恢复原文。
                 (when (buffer-live-p input-buffer)
                   (with-current-buffer input-buffer
                     (dsh-emacs-render-command-cleanup-optimistic)
                     (when (string-empty-p
                            (or (dsh-emacs--get-input) ""))
                       (dsh-emacs--replace-input message))))
                 (message "Command failed to run: %S"
                          (or err "transport error")))
                ((null execution)
                 ;; 未命中注册表 → 清除乐观行，按普通消息发送（浏览器同款语义）；
                 ;; 历史已在提交时记录，不再重复记入。
                 (when (buffer-live-p input-buffer)
                   (with-current-buffer input-buffer
                     (dsh-emacs-render-command-cleanup-optimistic)))
                 (dsh-emacs--submit-plain message images t))
                (t nil))       ; 受理：乐观行由 command/run 事件替换
             (quit nil)))))
    (dsh-emacs--submit-plain message images)))

(defun dsh-emacs--submit-plain (message &optional images skip-history)
  "Submit MESSAGE (a plain string) to the current session.

IMAGES, when given, is a list of wire-ready attachment alists
\((mediaType . M) (data . B64) (name . N)); the canonical wire shape
is part of `content' (each becomes a `{type: \"image\"}' part) — a
top-level `images' field is stripped by the host schema and never
reaches the model.
On acceptance the message is echoed into the transcript (when non-empty),
the running spinner lights up, and the watchdog starts.  Non-nil
SKIP-HISTORY suppresses the input-history push: used by the slash-command
fallback after the line was already recorded at submit time."
  (let* ((session-id (dsh-emacs--active-session-id))
         (chat-buffer (and (boundp 'dsh-emacs--buffer-session)
                           dsh-emacs--buffer-session
                           (current-buffer)))
         (input-buffer (current-buffer))
         (content (vconcat `(((type . "text") (text . ,message)))
                           (mapcar (lambda (attachment)
                                     (cons '(type . "image") attachment))
                                   images)))
         (payload `((sessionId . ,session-id)
                    (mode . "queue")
                    (content . ,content)
                    (clientTimeZone . ,(dsh-emacs--client-time-zone)))))
    ;; Track the optimistic echo BEFORE the RPC round-trip: the mux may
    ;; deliver the canonical `user/message' at any moment — even before the
    ;; HTTP response is processed — and `dsh-emacs-render--consume-pending-user-message'
    ;; is the only dedup gate.  The entry must already exist when the event
    ;; arrives, or the echo (rendered on acceptance) and the canonical copy
    ;; would both render.
    (when (buffer-live-p chat-buffer)
      (with-current-buffer chat-buffer
        ;; Register before the RPC round-trip: a fast run can end before its
        ;; prompt callback is processed.
        (setq dsh-emacs--turn-awaiting t)
        (unless (string-empty-p message)
          (setq dsh-emacs--pending-user-messages
                (append dsh-emacs--pending-user-messages (list message))))))
    (dsh-emacs--rpc-async "session.prompt" payload
                          (lambda (ok value)
                            (if ok
                                (progn
                                  (unless skip-history
                                    (dsh-emacs--push-input-history message))
                                  (setq dsh-emacs--input-history-pos nil
                                        dsh-emacs--input-history-pending nil)
                                  ;; Render immediately in the transcript even
                                  ;; when the request originated in the fixed
                                  ;; bottom input buffer.
                                  (when (buffer-live-p chat-buffer)
                                    (with-current-buffer chat-buffer
                                      ;; dsh is now executing: light up the
                                      ;; mode-line running spinner.
                                      (dsh-emacs--ml-busy-set t)
                                      ;; Confirm the stream keeps delivering
                                      ;; while this turn runs.
                                      (dsh-emacs-events--watchdog-start)
                                      (unless (string-empty-p message)
                                        (dsh-emacs--render-user-message
                                         message images))
                                      (dsh-emacs-render--follow-stream)
                                      (unless dsh-emacs--event-ready
                                        ;; 流不在线时自愈：连进程都不存在说明
                                        ;; 该会话的 mux 已断开且无人重连（旧版
                                        ;; 打开新会话会误拆上一个会话的流——
                                        ;; 见 `dsh-emacs-open-session'）——先
                                        ;; 重连，让「switches back to realtime」
                                        ;; 的承诺成立；握手途中的进程由 connect
                                        ;; 的 health check 兜底，这里不重复建连。
                                        (when (not (process-live-p
                                                    dsh-emacs--event-process))
                                          (dsh-emacs-events-connect
                                           (current-buffer))))))
                                  (when (buffer-live-p input-buffer)
                                    (with-current-buffer input-buffer
                                      (dsh-emacs--clear-input))))
                              (message "Failed to send: %S" value)
                              ;; The server rejected the prompt, so no
                              ;; `user/message' will ever arrive to consume the
                              ;; optimistic entry; drop it, lest the same text
                              ;; sent again later swallow the real event.
                              (when (buffer-live-p chat-buffer)
                                (with-current-buffer chat-buffer
                                  (setq dsh-emacs--turn-awaiting nil)
                                  (setq dsh-emacs--pending-user-messages
                                        (delq message dsh-emacs--pending-user-messages)))))))))

;;; ---------------------------------------------------------------------------
;;;  附件 / 模型选择 / 输入历史
;;; ---------------------------------------------------------------------------

(defun dsh-emacs--file-attachment (file)
  "Read FILE into a wire-ready image attachment alist, or nil.

The dsh host accepts base64 image uploads inline in `session.prompt'
(media type, bytes and pixel limits are enforced server-side).  The
base64 is emitted without line breaks: the wire field is validated as
one continuous base64 run."
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
              (cons 'data (base64-encode-string bytes t))
              (cons 'name (file-name-nondirectory file)))))))

;;;###autoload
(defun dsh-emacs-attach-file (&optional file caption)
  "Attach an image FILE to the current session and send it as a prompt.
CAPTION (or the file name) accompanies the image as the message text.
Only the media types in `dsh-emacs-attach-media-types' are sent."
  (interactive
   (list (read-file-name "Image to attach: " default-directory)
         (read-string "Caption (optional): ")))
  (dsh-emacs-server-ensure)
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
  (dsh-emacs-server-ensure)
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
messages/the mode line) with payload = the candidate tuple
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
colliding ids are shown.  The mode-line model segment updates
immediately."
  (interactive)
  (dsh-emacs-server-ensure)
  (let ((session-id (dsh-emacs--active-session-id)))
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
                      (dsh-emacs-modeline-set-model model)
                      ;; 选中行自带所属 provider：同 id 跨 provider 时
                      ;; mode-line 的 model 段靠它消歧（tooltip 显示）。
                      (dsh-emacs-modeline-set-provider provider)
                      (dsh-emacs-modeline-set-effort effort-id)
                      ;; 模型切换后立即刷新会话列表：旧模型的
                      ;; contextPressure 快照不再可信，需拉新模型的同一投影
                      ;; 快照（mode-line ctx% 的 pressure+window 一并更新成对）。
                      ;; 直接走内部 fetch（纯 RPC），不进 server-start/事件恢复。
                      (dsh-emacs-list-sessions--fetch)
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

(defun dsh-emacs--render-user-message (message &optional images)
  "Render the optimistic echo of MESSAGE, with IMAGES if any.
IMAGES is a list of wire-ready attachment alists; they become
`{type: \"image\"}' content blocks so the renderer displays them
inline immediately — the bytes are already local, no
`session.attachment' round-trip is needed."
  (let ((event `((type . "user/message")
                 (data . ((content . ,(vconcat
                                       `(((type . "text") (text . ,message)))
                                       (mapcar (lambda (attachment)
                                                 (cons '(type . "image") attachment))
                                               images))))))))
    (dsh-emacs-render-event event)))

(defun dsh-emacs-refresh ()
  "Refresh the current chat buffer's session history.
Only meaningful inside a chat buffer: the history must render into the
buffer-local session's own buffer (`dsh-emacs--load-history' renders into
the current buffer).  Outside one it refuses with a message, instead of
injecting a transcript into an unrelated buffer (the old global
`dsh-emacs--current-buffer' target hid this by always pointing at a chat
buffer — the last-opened one, which mixed sessions)."
  (interactive)
  (dsh-emacs-server-ensure)
  (let ((session-id (dsh-emacs--active-session-id)))
    (cond
     ((and (boundp 'dsh-emacs--buffer-session) dsh-emacs--buffer-session)
      (dsh-emacs--load-history session-id))
     (session-id
      (message "Refresh works inside a chat buffer (last session: %s)"
               session-id))
     (t
      (message "No session to refresh")))))

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
  (let ((chat (current-buffer)))
    (when (buffer-live-p chat)
      (with-current-buffer chat
        (let ((transcript (buffer-substring-no-properties
                           (point-min) (point-max))))
          (kill-new transcript)
          (message "Transcript copied to clipboard"))))))

(defun dsh-emacs-modeline-toggle ()
  "Toggle the mode-line stats display."
  (interactive)
  (let ((chat (current-buffer)))
    (when (buffer-live-p chat)
      (with-current-buffer chat
        (setq dsh-emacs-modeline-enabled (not dsh-emacs-modeline-enabled))
        (dsh-emacs-modeline-update)))))

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

;; ---------------------------------------------------------------------------
;;  用户提问（question/requested）应答
;; ---------------------------------------------------------------------------
;; dsh 的 `ask' 工具（AskUserQuestion）通过 mux 流推送 answerable 的
;; `question/requested' 帧：客户端必须展示问题与选项、读取用户选择并
;; 以 client-response 回 POST /api/respond（回声 rpcId）。逐字对齐宿主
;; 的校验规则：单选用一个 label 或 custom（二选一），多用 label 集合
;; + 可选 custom，无选项问题只能给 custom，且 answers 必须覆盖整帧。
;;
;; 交互方式：逐题在 MINIBUFFER 中选择——选项作为 completion 候选（带
;; 序号，按数字键即可选择），单/多选，候选末尾附「Type answer…」（空
;; 输入回到选项）；提示语带 Question N/M 序号，全部答完一次性 respond。
;; 跳过某题只走 `dsh-emacs-question-skip-key' 快捷键 = 该题以空 selected
;; 覆盖（dsh web 的逐题 Skip），其余照答。C-g/ESC（或无选项问题的空输入）
;; 放弃整组问题：以协议
;; 保留的 cancelled 错误回执应答（ok:false + error.code=cancelled，与 dsh
;; web 的 abandon 同一信号），宿主把该 ask 撤销为 cancelled 并广播
;; `question/resolved'；ask 工具调用随之中止 —— 旧行为（完全不应答）会让
;; 宿主永久 pending、回合卡死。
;;
;; minibuffer 是全局唯一资源：多个会话同时活跃时，回答一帧的途中其它
;; mux 流仍会继续到达 question/requested。帧进入全局 FIFO 队列，同一
;; 时刻只回答一帧（否则嵌套 completing-read 会把不同会话的提示叠进
;; 同一个 minibuffer、相互覆盖）；提示语带所属会话的标识（聊天缓冲名，
;; 如 [dsh-<标题>]），让用户知道问题来自哪个会话。

(defvar dsh-emacs--question-queue nil
  "Pending `question/requested' frames awaiting the single interactive
answering slot; each entry is (CHAT RPC-ID SESSION-ID QUESTIONS).")

(defvar dsh-emacs--question-active nil
  "The `question/requested' frame currently occupying the interactive
answering slot, or nil.  The slot is shared with the approval flow
(`dsh-emacs--approval-active'): only one prompt may own the minibuffer
at a time.")

;; Declared here — before `dsh-emacs--question-drain' references them in
;; the shared-slot handoff — because the byte-compiler reads the file
;; top-down; the answering logic itself lives in the approval section.
(defvar dsh-emacs--approval-queue nil
  "Pending `approval/requested' frames awaiting the single interactive
answering slot; each entry is (CHAT RPC-ID SESSION-ID APPROVAL-ID
TOOL-NAME REASON CALL-ID).")

(defvar dsh-emacs--approval-active nil
  "The `approval/requested' frame currently occupying the interactive
answering slot, or nil.  The slot is shared with the question flow
(`dsh-emacs--question-active'): only one prompt may own the minibuffer
at a time.")

(defun dsh-emacs--question-session-label (session-id)
  "Label identifying SESSION-ID in question prompts.
Prefers the live chat buffer's name (the title-based \"dsh-<title>\"
form); falls back to `dsh-emacs--chat-buffer-name', then to the raw id.
Long labels are truncated so the minibuffer prompt stays readable; a nil
SESSION-ID (direct test calls) yields an empty label."
  (let* ((buf (and session-id
                   (boundp 'dsh-emacs--chat-buffers)
                   (hash-table-p dsh-emacs--chat-buffers)
                   (gethash session-id dsh-emacs--chat-buffers)))
         (label (cond
                 ((and buf (buffer-live-p buf)) (buffer-name buf))
                 (session-id (dsh-emacs--chat-buffer-name session-id))
                 (t ""))))
    (if (> (length label) 40)
        (concat (substring label 0 37) "…")
      label)))

(defun dsh-emacs--question-drain ()
  "Answer queued question frames one at a time, in arrival order.
Minibuffer answering is a single global slot
(`dsh-emacs--question-active', shared with the approval flow's
`dsh-emacs--approval-active' — only one of the two may prompt at a
time): each frame is answered — or aborted — before the next one is
presented, so prompts from different sessions never nest inside the
same minibuffer.  Runs from whatever filter context delivered the
current frame; queued frames are collected in their own chat buffer
regardless of which stream they arrived on."
  (while (and (null dsh-emacs--question-active)
              (null dsh-emacs--approval-active)
              dsh-emacs--question-queue)
    (let* ((frame (pop dsh-emacs--question-queue))
           (chat (nth 0 frame))
           (rpc-id (nth 1 frame))
           (session-id (nth 2 frame))
           (questions (dsh-emacs--sequence-list (nth 3 frame))))
      (setq dsh-emacs--question-active frame)
      (condition-case err
          (let ((answers
                 (when (buffer-live-p chat)
                   (with-current-buffer chat
                     (dsh-emacs--collect-question-answers
                      questions session-id)))))
            (if answers
                (dsh-emacs--rpc-respond-async
                 rpc-id
                 `((sessionId . ,session-id)
                   (answer . ((answers . ,answers))))
                 (lambda (accepted reason)
                   (if accepted
                       (message "Answered %d question(s)" (length answers))
                     (message "Question response not accepted (%s)"
                              reason))))
              ;; No choices collected (aborted via an empty no-option
              ;; input, or the chat buffer died): cancel the whole frame
              ;; with the protocol's `cancelled' receipt (dsh web's
              ;; "abandon questions") so the ask aborts host-side and the
              ;; run is never left blocked on an unanswered question.
              (dsh-emacs--question-decline rpc-id)))
        (quit (dsh-emacs--question-decline rpc-id))
        (error (message "dsh question error: %S" err)))
      (setq dsh-emacs--question-active nil)))
  ;; The question answering slot just freed up: hand queued approvals over
  ;; to their drain (which hands back when it is done, so the two never
  ;; stack prompts inside the minibuffer).
  (when (and (null dsh-emacs--question-active)
             (null dsh-emacs--approval-active)
             dsh-emacs--approval-queue)
    (dsh-emacs--approval-drain)))

(defun dsh-emacs--respond-envelope-json (rpc-id payload)
  "JSON body of the client-response answering server-request RPC-ID
with PAYLOAD (the domain answer alist).  The receipt lives on
POST /api/respond; rpcId echoes the requested frame."
  (json-encode `((type . "client-response")
                 (rpcId . ,rpc-id)
                 (result . ((ok . t) (value . ,payload))))))

(defun dsh-emacs--respond-cancel-envelope-json (rpc-id message)
  "JSON body of the client-response that CANCELS server-request RPC-ID.
The protocol's answer receipt carries an ok:false result whose error code
is reserved `cancelled' (detail-less) — the same wire signal dsh web's
\"abandon questions\" produces; the host resolves the pending question as
cancelled and broadcasts `question/resolved'(\"cancelled\")."
  (json-encode
   `((type . "client-response")
     (rpcId . ,rpc-id)
     (result . ((ok . :json-false)
                (error . ((code . "cancelled")
                          (message . ,message)
                          (details . ,(make-hash-table)))))))))

(defun dsh-emacs--respond-post (json-data callback)
  "POST the client-response envelope JSON-DATA to /api/respond.
CALLBACK receives (accepted-p . reason): accepted-p non-nil on an
accepted receipt; otherwise REASON is `not-pending' or `bad-response'
(a transport failure calls it with nil)."
  (let* ((url (format "%s/api/respond" dsh-emacs-base-url))
         (url-request-method "POST")
         (url-request-extra-headers '(("Content-Type" . "application/json")))
         (url-request-data (encode-coding-string json-data 'utf-8))
         (callback-buffer (current-buffer)))
    (url-retrieve
     url
     (lambda (status)
       (let ((gc-cons-threshold (* 64 1024 1024)))
         (if (plist-get status :error)
             (progn
               (message "RPC respond error: %S%s" status
                        (dsh-emacs--http-error-hint (plist-get status :error)))
               (when (buffer-live-p callback-buffer)
                 (with-current-buffer callback-buffer
                   (condition-case nil
                       (funcall callback nil 'transport)
                     (quit nil)))))
           (goto-char (point-min))
           (re-search-forward "^$")
           (delete-region (point) (point-min))
           (dsh-emacs--decode-response-body)
           (goto-char (point-min))
           (let* ((response (json-read))
                  (accepted (cdr (assq 'accepted response)))
                  (reason (cdr (assq 'reason response))))
             (kill-buffer)
             (when (buffer-live-p callback-buffer)
               (with-current-buffer callback-buffer
                 (condition-case nil
                     (funcall callback
                              (and accepted (not (eq accepted :json-false)))
                              reason)
                   (quit nil))))))))
     nil t)))

(defun dsh-emacs--rpc-respond-async (rpc-id payload callback)
  "Answer a server-request on POST /api/respond: client-response for
RPC-ID with domain answer PAYLOAD.  CALLBACK receives (accepted-p . reason):
accepted-p non-nil on an accepted receipt; otherwise REASON is
`not-pending' or `bad-response' (a transport failure calls it with nil)."
  (dsh-emacs--respond-post
   (dsh-emacs--respond-envelope-json rpc-id payload)
   callback))

(defun dsh-emacs--question-option-labels (question)
  "Option labels of QUESTION (a decoded alist), in roster order."
  (delq nil
        (mapcar (lambda (o) (dsh-emacs-render--aget "label" o))
                (dsh-emacs--sequence-list
                 (dsh-emacs-render--aget "options" question)))))

(defconst dsh-emacs--question-skip-label "Skip this question"
  "Internal sentinel signaling an empty-selection answer (dsh web's
per-question Skip): `dsh-emacs--question-skip-command' inserts it and
exits the minibuffer, and `dsh-emacs--question-choice' matches it to
cover that question as {id, selected: []} while the rest of the frame is
answered normally.  No longer a visible candidate — the skip key is the
only way to choose it.  Distinct from abandoning the whole group (C-g →
cancelled receipt).")

(defconst dsh-emacs--question-type-label "Type answer…"
  "Sentinel candidate switching an option question to free-text answering:
picked (or included in a multi question's selection) it reads the answer
as the `custom' field of the client-response instead of a `selected'
label.")

(defun dsh-emacs--question-candidates (labels type-option)
  "Completion candidates for one question: each LABEL prefixed with its
1-based index (\"1. label\" — press the number to pick it instantly),
then the raw TYPE-OPTION sentinel pinned at the tail.
The returned candidate keeps the number; the answer must go through
`dsh-emacs--question-picked-label' to recover the bare label."
  (append (cl-loop for l in labels for n from 1
                   collect (format "%d. %s" n l))
          (list type-option)))

(defun dsh-emacs--question-picked-label (picked)
  "The bare option label of a PICKED candidate (strip the leading
\"N. \" index); the `Type answer…' sentinel passes through unchanged."
  (if (string-match "\\`[0-9]+\\. \\(.*\\)\\'" picked)
      (match-string 1 picked)
    picked))

(defvar dsh-emacs--question-pick-labels nil
  "Option labels of the single-select question being asked right now.
A DYNAMIC binding set by `dsh-emacs--question-choice' around each
single-select chooser read.  Non-nil makes the chooser a STATIC key menu
instead of a typing-narrowed prompt: digits pick by number, `t' switches
to the `Type answer…' free-text path, and self-insertion is inert so the
candidate list never narrows.  nil (multi-select and free-text cases)
keeps plain completion behavior.")

(defun dsh-emacs--question-pick-command ()
  "Pick the option numbered by the digit key just pressed.
`1'…`9' pick options 1–9, `0' the 10th.  The chosen option is inserted as
its numbered candidate and the chooser exits — exactly the path of RET
on the candidate.  Out-of-range digits (including `0' on a question with
fewer than 10 options) only show a message.  Bound in the chooser's
keymap while `dsh-emacs--question-pick-labels' is set (see
`dsh-emacs--question-chooser-keymap')."
  (interactive)
  (let ((n (- (event-basic-type last-command-event) ?0)))
    (when (= n 0) (setq n 10))
    (let ((label (nth (1- n) dsh-emacs--question-pick-labels)))
      (if (null label)
          (minibuffer-message "No option %d" n)
        (insert (format "%d. %s" n label))
        (exit-minibuffer)))))

(defun dsh-emacs--question-type-command ()
  "Switch the current question to free-text answering.
Inserts the `Type answer…' sentinel and exits the minibuffer, so the
choice lands on the same path as RET on the candidate.  Bound to `t' in
the chooser's keymenu (see `dsh-emacs--question-chooser-keymap')."
  (interactive)
  (insert dsh-emacs--question-type-label)
  (exit-minibuffer))

(defun dsh-emacs--question-inert-command ()
  "Ignore typing in the question chooser and remind the user how to answer.
The single-select chooser is a STATIC key menu — the option list never
narrows, so printable characters are remapped here instead of
self-inserting.  Briefly show the menu keys (digits, `t', the skip key)
and leave the prompt alone; C-g still abandons the whole group."
  (interactive)
  (minibuffer-message
   (concat "Press a number to pick, t = type an answer"
           (when dsh-emacs-question-skip-key
             (format ", %s = skip"
                     (key-description
                      (if (stringp dsh-emacs-question-skip-key)
                          (kbd dsh-emacs-question-skip-key)
                        dsh-emacs-question-skip-key)))))))

(defun dsh-emacs--question-skip-command ()
  "Answer the current question with an empty selection (skip).
Inserts the `Skip this question' sentinel and exits the minibuffer, so
`dsh-emacs--question-choice' matches it to an empty `selected' — the
skip path.  Bound in the question chooser via
`dsh-emacs-question-skip-key' (default `s'); an option-less free-text
question skips on an EMPTY input instead, so the key is only bound where
there is a candidate list."
  (interactive)
  (insert dsh-emacs--question-skip-label)
  (exit-minibuffer))

(defun dsh-emacs--question-chooser-keymap ()
  "Keymap for the question chooser minibuffer: a copy of the current
local keymap (vertico's when `vertico-mode' is on — the copy keeps its
navigation and refresh alive — the minibuffer completion map otherwise)
plus `dsh-emacs-question-skip-key' (default `s') bound to
`dsh-emacs--question-skip-command'.  An option question
(`dsh-emacs--question-pick-labels' set) additionally turns the chooser
into a STATIC key menu: digits 1–9 (and `0' for the 10th option) pick
that option via `dsh-emacs--question-pick-command', `t' switches to the
`Type answer…' free-text path, and self-insertion is remapped to
`dsh-emacs--question-inert-command' so typing never narrows the list.
Mounted from the setup hook, so none of this leaks into unrelated
`completing-read' prompts; the menu keys are absent for multi-select
questions, which keep plain comma-separated typing."
  (let ((map (copy-keymap (current-local-map))))
    (when dsh-emacs-question-skip-key
      (define-key map (if (stringp dsh-emacs-question-skip-key)
                          (kbd dsh-emacs-question-skip-key)
                        dsh-emacs-question-skip-key)
        #'dsh-emacs--question-skip-command))
    (when dsh-emacs--question-pick-labels
      (cl-loop for n from 1 to (min 9 (length dsh-emacs--question-pick-labels))
               do (define-key map (kbd (number-to-string n))
                    #'dsh-emacs--question-pick-command))
      (when (>= (length dsh-emacs--question-pick-labels) 10)
        (define-key map (kbd "0") #'dsh-emacs--question-pick-command))
      (define-key map (kbd "t") #'dsh-emacs--question-type-command)
      (define-key map [remap self-insert-command]
        #'dsh-emacs--question-inert-command))
    map))

(defun dsh-emacs--question-setup-hook ()
  "Tame completion sorting in the question chooser's minibuffer: the
roster order stays put (numbered labels with the `Type answer…'
sentinel pinned last), the first option is preselected, and the
local keymap gains `dsh-emacs-question-skip-key' (default `s';
skip this question) plus, for option questions, the key menu bound in
`dsh-emacs--question-chooser-keymap' (digits pick, `t' types, typing is
inert — the list never narrows).  Returns nil explicitly — the Emacs 31
`minibuffer-with-setup-hook' would funcall the setup value."
  (when (boundp 'vertico-sort-function)
    (setq-local vertico-sort-function nil))
  (when (boundp 'vertico-sort-override-function)
    (setq-local vertico-sort-override-function nil))
  (when (boundp 'vertico-preselect)
    (setq-local vertico-preselect 'first))
  (use-local-map (dsh-emacs--question-chooser-keymap))
  nil)

(defun dsh-emacs--question-choice (question &optional index total session-id)
  "Read ONE answer to QUESTION in the minibuffer and return it as an
answer alist ((id . ID) (selected . LABELS) [custom . TEXT]).
The options are shown as numbered completion candidates (\"1. label\")
followed by the pinned `Type answer…' sentinel.
A single-select question reads as a STATIC key menu — the list never
narrows because typing is inert: press the option's digit (1–9, 0 for
the 10th) to pick it immediately, `t' to switch to the `Type answer…'
free-text path, or the `dsh-emacs-question-skip-key' binding (default
`s') to skip this question with an empty selection; RET confirms the
preselected first option.  Without a list-rendering completion UI
(vertico, icomplete, fido, ivy)
the numbered options are embedded in the prompt itself, so the same keys
work on a bare minibuffer.  A multi-select question instead uses
`completing-read-multiple' with plain comma-separated typing (the menu
keys are not bound there) and also accepts the `Type answer…' sentinel
for the `custom' answer — an EMPTY free-text input goes BACK to the
options instead (re-reads the whole choice).  The skip key answers
that one question with an empty `selected' (dsh web's per-question Skip)
and moves on to the next question of the frame; a question without
options reads free text directly, where an EMPTY input likewise skips it.
C-g still abandons the WHOLE frame (see `dsh-emacs--question-decline').
INDEX/TOTAL (when given) prefix each prompt as \"Question INDEX/TOTAL\" so a
multi-question frame stays oriented; SESSION-ID (when given) prefixes the
owning session's label (\[dsh-<title>\]), so with several sessions open the
user can tell which conversation is asking.
`selected' is always present and JSON-encodes as an array (empty for
custom-only answers — the host schema requires the field).  Labels are
compared with `equal' (fresh strings are never `eq'); C-g aborts the
whole frame."
  (let* ((id (dsh-emacs-render--aget "id" question))
         (text (or (dsh-emacs-render--aget "question" question)
                   "Question"))
         ;; Hide the session label when the user is already in the
         ;; asking buffer — it is redundant.
         (same-buffer (and (boundp 'dsh-emacs--buffer-session)
                           (equal dsh-emacs--buffer-session session-id)))
         (where (concat
                 (if (and session-id (not (string-empty-p session-id))
                          (not same-buffer))
                     (format "[%s] "
                             (dsh-emacs--question-session-label
                              session-id))
                   "")
                 (if index (format "Question %d/%d — " index total) "")))
         (multi (eq t (dsh-emacs-render--aget "multiSelect" question)))
         (labels (dsh-emacs--question-option-labels question))
         (skip-label dsh-emacs--question-skip-label)
         (free-prompt (format "%s%s (free text, empty input = back to options): "
                              where text)))
    (cond
     ((null labels)
      (let ((custom (read-string (format "%s%s (empty input = skip): "
                                         where text))))
        (if (string-empty-p custom)
            ;; Empty input SKIPS this question (dsh web's per-question
            ;; Skip — there is no option list to go back to): cover it as
            ;; {id, selected: []}; C-g still abandons the whole GROUP.
            (progn (and index total
                        (message "Question %d/%d skipped" index total))
                   `((id . ,id) (selected . [])))
          `((id . ,id) (selected . []) (custom . ,custom)))))
     (multi
      (catch 'back
        (while t
          (let* ((picked
                  (minibuffer-with-setup-hook
                      (lambda () (dsh-emacs--question-setup-hook))
                    (completing-read-multiple
                     (format "%s%s (comma-separated choices): " where text)
                     (dsh-emacs--question-candidates
                      labels dsh-emacs--question-type-label)
                     nil t)))
                 (custom-p (cl-member dsh-emacs--question-type-label picked
                                      :test #'equal))
                 (custom (and custom-p (read-string free-prompt)))
                 (selected (mapcar #'dsh-emacs--question-picked-label
                                   (cl-remove dsh-emacs--question-type-label
                                              picked :test #'equal))))
            (cond
             ((cl-member skip-label picked :test #'equal)
              ;; Skip wins over any selection/custom (web's Skip is
              ;; exclusive per question).
              (and index total
                   (message "Question %d/%d skipped" index total))
              (throw 'back `((id . ,id) (selected . []))))
             ((and custom-p (string-empty-p custom))
              (message "Empty answer — back to the options"))   ; 循环返回选项
             (t
              (throw 'back
                (append `((id . ,id) (selected . ,(or selected [])))
                        (and custom (not (string-empty-p custom))
                             `((custom . ,custom)))))))))))
     (t
      (catch 'back
        (while t
          (let* ((dsh-emacs--question-pick-labels labels)
                 ;; Without a list-rendering completion UI (vertico,
                 ;; icomplete, fido, ivy) the minibuffer never shows the
                 ;; candidates, so embed the numbered options in the
                 ;; prompt — the digit keys still pick them.
                 (stock-list
                  (unless (or (bound-and-true-p vertico-mode)
                              (bound-and-true-p icomplete-mode)
                              (bound-and-true-p fido-mode)
                              (bound-and-true-p ivy-mode))
                    (mapconcat #'identity
                               (cl-loop for l in labels for n from 1
                                        collect (format "(%d) %s" n l))
                               " ")))
                 (picked
                  (minibuffer-with-setup-hook
                      (lambda () (dsh-emacs--question-setup-hook))
                    (completing-read
                     (format "%s%s%s: " where text
                             (if stock-list (format " (%s)" stock-list) ""))
                     (dsh-emacs--question-candidates
                      labels dsh-emacs--question-type-label)
                     nil t nil nil nil))))
            (cond
             ((equal picked skip-label)
              (and index total
                   (message "Question %d/%d skipped" index total))
              (throw 'back `((id . ,id) (selected . []))))
             ((equal picked dsh-emacs--question-type-label)
              (let ((custom (read-string free-prompt)))
                (if (string-empty-p custom)
                    (message "Empty answer — back to the options")
                  (throw 'back
                         `((id . ,id) (selected . [])
                           (custom . ,custom))))))
             (t
              (throw 'back
                     `((id . ,id)
                       (selected . (,(dsh-emacs--question-picked-label
                                      picked))))))))))))))



(defun dsh-emacs--collect-question-answers (questions &optional session-id)
  "Answer QUESTIONS one at a time from the minibuffer: each question's
options are the completion candidates (`dsh-emacs--question-choice',
with its INDEX/TOTAL in the prompt), in frame order.  SESSION-ID (when
given) labels every prompt with the owning session.  Returns the answer
alists in frame order, or nil when the user aborted (C-g or an empty
custom-only answer) — the caller then skips the respond."
  (let ((total (length questions))
        (answers nil)
        (n 0))
    (catch 'abort
      (dolist (q questions)
        (setq n (1+ n))
        (let ((answer (dsh-emacs--question-choice q n total session-id)))
          (if (null answer) (throw 'abort nil)
            (push answer answers))))
      (reverse answers))))

(defun dsh-emacs--question-requested (chat rpc-id session-id questions)
  "Queue a `question/requested' frame for SESSION-ID in CHAT and answer it.
The minibuffer is one global resource: with several chat buffers open, a
mux filter can deliver the next question while the previous frame is
still being answered interactively.  Nested `completing-read' calls
would stack different sessions' prompts inside the same minibuffer, so
frames are queued (FIFO) and drained one at a time by
`dsh-emacs--question-drain'; each prompt carries the owning session's
label (see `dsh-emacs--question-session-label').  All questions of the
frame are then read one after another (options as completion candidates
plus a \"Type answer…\" free-text choice) and answered with a single
client-response echoing RPC-ID on POST /api/respond.  C-g (or an empty
no-option input) cancels the whole frame with the protocol's reserved
`cancelled' receipt — dsh web's \"abandon questions\" — so the host
withdraws the ask and the run is never left blocked; the quit is caught
here, so it cannot leak out of the process filter as \"error in process
filter: Quit\".
A frame whose RPC-ID is already pending (queued or active — the mux
replays the same request) is dropped instead of asked twice, mirroring
the approval flow."
  (unless (or (and (consp dsh-emacs--question-active)
                   (equal rpc-id (nth 1 dsh-emacs--question-active)))
              (cl-some (lambda (entry)
                         (equal rpc-id (nth 1 entry)))
                       dsh-emacs--question-queue))
    (setq dsh-emacs--question-queue
          (nconc dsh-emacs--question-queue
                 (list (list chat rpc-id session-id questions)))))
  (dsh-emacs--question-drain))

(defun dsh-emacs--question-decline (rpc-id)
  "Cancel a whole `question/requested' frame and unblock its run.
Answers the server-request with the protocol's reserved `cancelled'
receipt (ok:false + error.code=cancelled) — the same wire signal dsh web's
\"abandon questions\" produces: the host resolves the pending question as
cancelled and broadcasts `question/resolved'(\"cancelled\"), and the ask
tool call aborts, so the agent's turn is never left blocked on an
unanswered question.  The quit is contained here so it cannot leak out of
the process filter as \"error in process filter: Quit\"."
  (dsh-emacs--respond-post
   (dsh-emacs--respond-cancel-envelope-json
    rpc-id "User abandoned the questions")
   (lambda (accepted reason)
     (if accepted
         (message "Question cancelled")
       (message "Question response not accepted (%s)" reason)))))

(defun dsh-emacs--question-resolved (session-id rpc-id outcome)
  "Handle a `question/resolved' push for RPC-ID of SESSION-ID.
The OUTCOME (answered/cancelled/…) is echoed in *Messages*, and any queued
frame for the same question is dropped, so a mux replay of
requested→resolved never re-asks a finished question.  A question currently
being prompted cannot be aborted from here; its stale answer is then refused
server-side as not-pending."
  (message "dsh question %s resolved: %s" rpc-id (or outcome "…"))
  (setq dsh-emacs--question-queue
        (cl-remove-if (lambda (entry)
                        (and (equal rpc-id (nth 1 entry))
                             (equal session-id (nth 2 entry))))
                      dsh-emacs--question-queue)))

;; ---------------------------------------------------------------------------
;;  用户审批（approval/requested）应答
;; ---------------------------------------------------------------------------
;; 沙箱工具的越界请求通过 mux 流推送 answerable 的 `approval/requested'
;; 帧（server-request，rpcId 稳定）：bash/fs 等工具要访问 workspace 之外
;; 的文件时，宿主先征询用户的许可（dsh web 的 ApprovalPanel 同一协议）。
;; 客户端必须展示请求（toolName + justification reason）、读取用户的
;; approve/reject 决定，并以 client-response 回 POST /api/respond（回声
;; rpcId；payload 即 ApprovalResponsePayload：sessionId + approvalId +
;; outcome，客户端只能给 "allowed-once" | "rejected"）。宿主随后广播
;; `approval/resolved' 帧（纯推送）并继续（或被拒后放弃）被阻塞的调用。
;;
;; 交互方式：minibuffer y-or-n-p —— y/y 键 = 允许一次，n = 拒绝；C-g/ESC
;; 同样按拒绝应答（客户端不回决定，宿主就会一直阻塞在 pending 审批上；
;; 若宿主已先 resolved 则 receipt 报 not-pending，静默丢弃）。minibuffer 是
;; 全局唯一资源：审批与提问共用同一把锁（`dsh-emacs--approval-active' /
;; `dsh-emacs--question-active'，见上面的 defvar），任一活跃时新帧入队
;; 串行，两个 drain 在各自队列清空时互相接棒，绝不嵌套两个 minibuffer
;; 提示。

(defun dsh-emacs--approval-command-line (call-id)
  "One-line summary of the tool call CALL-ID from the live transcript.
Reads the buffer-local `dsh-emacs--tool-states' map, so it must run in
the chat buffer of the approving session.  For bash the rendered body is
the real command (\"$ cat /etc/hostname\"); other tools fall back to
\"Title — args\".  Returns nil when CALL-ID is unknown (e.g. the call
predates this window, or the approval replayed right after open)."
  (when (and call-id
             (boundp 'dsh-emacs--tool-states)
             (hash-table-p dsh-emacs--tool-states))
    (let* ((state (dsh-emacs-render--tool-state call-id))
           (title (and state (plist-get state :title)))
           (args (and state (plist-get state :args))))
      (cond
       ((and (stringp args) (string-match-p "\\`\\$ " args)) args)
       ((and (stringp args) (not (string-empty-p args)))
        (if (and (stringp title) (not (string-empty-p title)))
            (format "%s — %s" title args)
          args))
       ((and (stringp title) (not (string-empty-p title))) title)
       (t nil)))))

(defun dsh-emacs--approval-drain ()
  "Answer queued approval frames one at a time, in arrival order.
The approval prompt owns the same single minibuffer slot as question
answering: while `dsh-emacs--question-active' or
`dsh-emacs--approval-active' is set, queued approvals wait.  Each frame
is decided before the next one is presented — a quit (C-g/ESC) counts
as a rejection so the host never stays blocked on a pending frame.
The decision goes out as a client-response echoing the frame's RPC-ID with
the `ApprovalResponsePayload' (sessionId + approvalId + outcome).  The
prompt runs in the frame's chat buffer so the tool-call lookup
(`dsh-emacs--approval-command-line') can read the buffer-local
transcript state.  When the slot frees up, queued questions are handed
back to `dsh-emacs--question-drain'."
  (while (and (null dsh-emacs--approval-active)
              (null dsh-emacs--question-active)
              dsh-emacs--approval-queue)
    (let* ((frame (pop dsh-emacs--approval-queue))
           (chat (nth 0 frame))
           (rpc-id (nth 1 frame))
           (session-id (nth 2 frame))
           (approval-id (nth 3 frame))
           (tool-name (nth 4 frame))
           (reason (nth 5 frame))
           (call-id (nth 6 frame)))
      (setq dsh-emacs--approval-active frame)
      (condition-case err
          (let ((allow (condition-case nil
                           (if (buffer-live-p chat)
                               (with-current-buffer chat
                                 (dsh-emacs--approval-prompt
                                  session-id tool-name reason call-id))
                             (dsh-emacs--approval-prompt
                              session-id tool-name reason call-id))
                         ;; C-g/ESC 折叠为拒绝：宿主阻塞在 pending 审批上，
                         ;; 只有收到决定才能解除，留着不答只会永远卡住回合。
                         (quit (message "Approval %s quit — rejecting"
                                        approval-id)
                               nil))))
            (dsh-emacs--rpc-respond-async
             rpc-id
             `((sessionId . ,session-id)
               (approvalId . ,approval-id)
               (outcome . ,(if allow "allowed-once" "rejected")))
             (lambda (accepted rsn)
               (if accepted
                   (message "%s %s for %s"
                            (if allow "Approved" "Rejected")
                            (or tool-name "tool") session-id)
                 (message "Approval response not accepted (%s)" rsn)))))
        ;; Safety net: a quit from anywhere but the prompt still aborts the
        ;; frame without answering.
        (quit (message "Approval %s cancelled" approval-id))
        (error (message "dsh approval error: %S" err)))
      (setq dsh-emacs--approval-active nil)))
  ;; The approval answering slot just freed up: hand queued questions over
  ;; to their drain (which hands back when it is done).
  (when (and (null dsh-emacs--approval-active)
             (null dsh-emacs--question-active)
             dsh-emacs--question-queue)
    (dsh-emacs--question-drain)))

(defun dsh-emacs--approval-prompt (session-id tool-name reason call-id)
  "Read the user's decision for one approval in the minibuffer.
The prompt is multi-line, untruncated and colored: the asker's full
justification REASON in `dsh-emacs-approval-justification-face' (light
orange), then a blank line and the actual tool call (the bash command
line, see `dsh-emacs--approval-command-line' — runs in the chat buffer,
so CALL-ID must be that session's) in `dsh-emacs-approval-command-face'
(gray).  The owning session, tool and call-id are logged to *Messages*.
Without any detail the prompt falls back to \"Allow TOOL?\".  The prompt
faces survive because `minibuffer-prompt-properties' is bound WITHOUT
its `face' slot around the read — the minibuffer prompt insertion would
otherwise replace every prompt face with `minibuffer-prompt'.  Returns t
to allow once, nil to reject; C-g signals `quit' and the caller answers
the same rejection (an unanswered frame would block the host forever)."
  (let* ((where (concat
                 (if (and session-id (not (string-empty-p session-id)))
                     (format "[%s] " (dsh-emacs--question-session-label
                                      session-id))
                   "")
                 (if (and call-id (not (string-empty-p call-id)))
                     (format "call %s " call-id)
                   "")))
         (just-line (and reason (not (string-empty-p reason))
                         (propertize reason
                                     'face
                                     'dsh-emacs-approval-justification-face)))
         (cmd-line (let ((line (dsh-emacs--approval-command-line call-id)))
                     (and line (propertize line
                                           'face
                                           'dsh-emacs-approval-command-face))))
         (lines (delq nil (list just-line cmd-line)))
         (prompt (if lines
                     (mapconcat #'identity lines "\n\n")
                   (format "Allow %s?" (or tool-name "tool")))))
    (when (and where (not (string-empty-p where)))
      (message "dsh approval, %s: %s%s"
               (or tool-name "tool") where
               (if (and reason (not (string-empty-p reason)))
                   (format " — %s" reason)
                 "")))
    (let ((minibuffer-prompt-properties
           ;; Keep the prompt non-editable and point-safe, but drop the
           ;; `face' slot: `read-from-minibuffer' applies these properties
           ;; over the prompt, and `add-text-properties' replaces an
           ;; existing `face' — with it bound the justification/command
           ;; colors above would be wiped by `minibuffer-prompt'.
           (list 'read-only t
                 'point-entered #'minibuffer-avoid-prompt)))
      (y-or-n-p prompt))))

(defun dsh-emacs--approval-requested (chat rpc-id session-id approval-id
                                           tool-name reason call-id)
  "Queue an `approval/requested' frame for SESSION-ID in CHAT and answer it.
Mirrors `dsh-emacs--question-requested': the minibuffer is one global
resource, so frames are queued (FIFO) and drained one at a time by
`dsh-emacs--approval-drain', never nested inside another prompt.  A
frame whose APPROVAL-ID is already pending (mux replay of the same
request) is dropped instead of asked twice.  The decision — allow once
or reject — is sent as a single client-response echoing RPC-ID on POST
/api/respond with the `ApprovalResponsePayload'; C-g answers the
rejection too (default deny).  The quit is caught here so it cannot
leak out of the process filter as \"error in process filter: Quit\"."
  (unless (or (and dsh-emacs--approval-active
                   (equal approval-id (nth 3 dsh-emacs--approval-active)))
              (cl-some (lambda (entry)
                         (equal approval-id (nth 3 entry)))
                       dsh-emacs--approval-queue))
    (setq dsh-emacs--approval-queue
          (nconc dsh-emacs--approval-queue
                 (list (list chat rpc-id session-id approval-id
                             tool-name reason call-id)))))
  (dsh-emacs--approval-drain))

(defun dsh-emacs--approval-resolved (session-id approval-id outcome)
  "Handle an `approval/resolved' push for APPROVAL-ID of SESSION-ID.
The outcome (allowed-once/rejected/cancelled/unavailable) is echoed in
*Messages*, and any queued frame for the same approval is dropped so a
mux replay of requested→resolved never re-asks a finished approval.  An
approval currently being prompted cannot be aborted from here; its
stale answer is then refused server-side as not-pending."
  (message "dsh approval %s resolved: %s" approval-id (or outcome "…"))
  (setq dsh-emacs--approval-queue
        (cl-remove-if (lambda (entry)
                        (and (equal approval-id (nth 3 entry))
                             (equal session-id (nth 2 entry))))
                      dsh-emacs--approval-queue)))

(provide 'dsh-emacs)

;;; dsh-emacs.el ends here
