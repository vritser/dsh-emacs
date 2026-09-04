;;; dsh-emacs-command.el --- Slash commands via commands/list / commands/execute -*- lexical-binding: t; -*-

;; Copyright (C) 2025 vritser

;; Author: vritser
;; Version: 0.2.0
;; License: GPL-3.0-or-later
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; dsh 的 slash command 是 host 侧注册表（`commands/list' /
;; `commands/execute'，typert Remote，HTTP 路径为 /api/commands/list、
;; /api/commands/execute，payload 是 {args: {...}}）。本文件提供：
;;
;;   - `dsh-emacs-command-parse'      按与 dsh 注册表相同的语法判定一行
;;                                     输入是否为 slash 命令（纯函数）
;;   - `dsh-emacs-command-execute'     向 `commands/execute' 提交一行命令
;;   - `dsh-emacs-command-catalog'     按会话缓存的命令目录（读取）
;;   - `dsh-emacs-command-catalog-fetch' / `dsh-emacs-command-catalog-sync'
;;                                     异步 / 同步拉取并缓存目录
;;   - `dsh-emacs-command'             M-x 命令菜单：completing-read 选
;;                                     命令（带 description），有 input
;;                                     hint 时再读参数
;;   - `dsh-emacs-command-completion-at-point'
;;                                     `completion-at-point-functions' 入口：
;;                                     输入区以 "/" 开头时补全 "/name "
;;
;; 发送路径（`dsh-emacs--submit-prompt'）把形如 "/name" 的行交给
;; `commands/execute'，未命中注册表（admission miss）时按普通消息发回 —
;; 与 dsh web 的行为一致。执行结果由 `command/run' + `command/done'
;; 会话事件渲染（见 dsh-emacs-render.el 的 `dsh-emacs-render-command'）。

;;; Code:

(require 'cl-lib)
(require 'dsh-emacs-protocol)

(declare-function dsh-emacs--rpc-async "dsh-emacs.el" (method params callback))
(declare-function dsh-emacs--rpc-request "dsh-emacs.el" (method params))
(declare-function dsh-emacs--active-session-id "dsh-emacs.el" ())
(declare-function dsh-emacs-server-ensure "dsh-emacs-server.el" ())

(defgroup dsh-emacs-command nil
  "Slash commands (commands/list / commands/execute)."
  :group 'dsh-emacs)

(defcustom dsh-emacs-slash-auto-complete t
  "Whether typing \"/\" in the input area automatically opens the
slash-command completion list (web-style trigger).

For corfu users this is wired through corfu's own auto-completion
(`corfu-auto' + \"/\" in `corfu-auto-trigger', buffer-local to chat
buffers); for other setups dsh-emacs falls back to a post-command
`completion-at-point' trigger.  TAB always completes, and
`M-x dsh-emacs-command' always works, regardless of this option."
  :type 'boolean
  :group 'dsh-emacs-command)

(defcustom dsh-emacs-command-prefetch t
  "Whether opening a session pre-fetches its `commands/list' catalog.
The fetch runs on a short idle timer after the chat buffer opens, so
the catalog is already cached by the time the first \"/\" or TAB is
typed — no synchronous round trip on the first completion.  The
prefetch is a no-op when the catalog is already cached."
  :type 'boolean
  :group 'dsh-emacs-command)

(defcustom dsh-emacs-command-prefetch-delay 0.5
  "Idle delay (seconds) before the `commands/list' pre-fetch runs.
Keeps the prefetch from racing the session-history load that also
starts when the chat buffer opens."
  :type 'number
  :group 'dsh-emacs-command)

(defvar dsh-emacs--command-catalogs nil
  "Alist of (SESSION-ID . ITEMS) caching `commands/list' catalogs.
ITEMS is a list of `dsh-protocol-command' structs, name-sorted by the
host.  Reset per session reload; entries stay until the session closes.")

(defvar dsh-emacs--command-fetch-inflight nil
  "List of SESSION-IDs whose `commands/list' fetch is still in flight.
Guards the completion warm-up so repeated TAB presses do not stack
requests; drained by the fetch callback.")

;; ---------------------------------------------------------------------------
;; 解析与执行
;; ---------------------------------------------------------------------------

(defun dsh-emacs-command-parse (line)
  "Parse LINE as a slash-command line.

Returns (NAME . REST) when LINE starts with \"/NAME\" where NAME is
`[a-z][a-z0-9_-]*' immediately followed by whitespace or end of
line — the same admission syntax as the dsh command registry — and nil
otherwise.  REST is the raw tail after the name (leading whitespace
kept, nil when the line is exactly \"/NAME\")."
  (when (stringp line)
    (let ((case-fold-search nil)
          (trimmed (string-trim line)))
      (when (string-match "\\`/\\([a-z][a-z0-9_-]*\\)" trimmed)
        (let ((end (match-end 0)))
          (when (or (= end (length trimmed))
                    (string-match-p "[ \t\r\n]"
                                    (substring trimmed end (1+ end))))
            (cons (match-string 1 trimmed)
                  (substring trimmed end))))))))

(defun dsh-emacs-command-execute (session-id line &optional images on-done)
  "Execute slash-command LINE (e.g. \"/compact\") in SESSION-ID.

Line goes to `commands/execute' — the host admits only registered
commands.  IMAGES, when given, is a list of wire-ready image alists
\((mediaType . M) (data . B64) (name . N)); text-only commands pass an
empty array (the wire field is required).

ON-DONE is called as (funcall ON-DONE OK EXECUTION ERR) once the RPC
settles: EXECUTION is a `dsh-protocol-command-execution' for an
admitted command, nil on admission miss (unknown/malformed), OK is
nil on transport failure (`dsh-emacs--rpc-async' already reported it),
and ERR is the raw RPC error value on failure (nil otherwise).  Runs
asynchronously; returns nil."
  (dsh-emacs--rpc-async
   "commands/execute"
   `((agentId . ,session-id)
     (line . ,line)
     (images . ,(or images [])))
   (lambda (ok value)
     (let ((execution (and ok value
                           (dsh-protocol-command-execution--from-alist
                            value))))
       (when (functionp on-done)
         ;; 回调可能运行在 process filter 里：吞掉 C-g 的 quit。
         (condition-case nil
             (funcall on-done ok execution (and (null ok) value))
           (quit nil)))))))

;; ---------------------------------------------------------------------------
;; 命令目录（commands/list）
;; ---------------------------------------------------------------------------

(defun dsh-emacs-command-catalog (&optional session-id)
  "Return the cached command catalog (list of `dsh-protocol-command') for
SESSION-ID (default: the active session), or nil when not yet fetched."
  (cdr (assoc (or session-id (dsh-emacs--active-session-id))
              dsh-emacs--command-catalogs)))

(defun dsh-emacs-command--cache-catalog (session-id items)
  "Store ITEMS as the cached catalog of SESSION-ID."
  (setq dsh-emacs--command-catalogs
        (cons (cons session-id items)
              (assoc-delete-all session-id dsh-emacs--command-catalogs))))

(defun dsh-emacs-command-catalog-invalidate (session-id)
  "Drop the cached catalog (and any in-flight fetch flag) of SESSION-ID.
A later `dsh-emacs-command-catalog' / completion trigger re-fetches from
the server.  Used by the manual refresh command and by pre-fetch after a
server restart."
  (setq dsh-emacs--command-catalogs
        (assoc-delete-all session-id dsh-emacs--command-catalogs)
        dsh-emacs--command-fetch-inflight
        (delete session-id dsh-emacs--command-fetch-inflight)))

(defun dsh-emacs-command-catalog-fetch (session-id &optional callback)
  "Fetch the `commands/list' catalog of SESSION-ID asynchronously.
Caches the result; CALLBACK (optional) receives the item list (nil on
failure — the error is already reported).  A fetch already in flight
for SESSION-ID is not duplicated."
  (unless (member session-id dsh-emacs--command-fetch-inflight)
    (setq dsh-emacs--command-fetch-inflight
          (cons session-id dsh-emacs--command-fetch-inflight))
    (dsh-emacs--rpc-async
     "commands/list"
     `((agentId . ,session-id))
     (lambda (ok value)
       (setq dsh-emacs--command-fetch-inflight
             (delete session-id dsh-emacs--command-fetch-inflight))
       (let ((items (and ok
                         (mapcar #'dsh-protocol-command--from-alist
                                 (dsh-protocol--list value)))))
         (when items
           (dsh-emacs-command--cache-catalog session-id items))
         (when (functionp callback)
           (condition-case nil
               (funcall callback items)
             (quit nil))))))))

(defun dsh-emacs-command-catalog-sync (session-id)
  "Fetch and cache the `commands/list' catalog of SESSION-ID synchronously.
Returns the item list, or nil on failure (a message is emitted)."
  (or (dsh-emacs-command-catalog session-id)
      (let* ((res (dsh-emacs--rpc-request
                   "commands/list"
                   `((agentId . ,session-id))))
             (items (and (car res)
                         (mapcar #'dsh-protocol-command--from-alist
                                 (dsh-protocol--list (cdr res))))))
        (if items
            (progn
              (dsh-emacs-command--cache-catalog session-id items)
              items)
          (message "Failed to list commands: %S" (cdr res))
          nil))))

(defun dsh-emacs-command-catalog-prefetch (session-id)
  "Pre-fetch the `commands/list' catalog of SESSION-ID lazily.
Called when a chat buffer opens: the catalog is fetched on a short
idle timer (see `dsh-emacs-command-prefetch-delay') so the first
\"/\" completion does not block on the network.  No-op unless
`dsh-emacs-command-prefetch' is enabled, the catalog is not yet
cached and no fetch is already in flight.  Returns the timer, or nil."
  (when (and dsh-emacs-command-prefetch
             session-id
             (not (dsh-emacs-command-catalog session-id)))
    (unless (member session-id dsh-emacs--command-fetch-inflight)
      (run-with-idle-timer
       dsh-emacs-command-prefetch-delay nil
       (lambda (sid)
         (dsh-emacs-command-catalog-fetch sid))
       session-id))))

(defun dsh-emacs-command-catalog-refresh (&optional session-id)
  "Re-fetch and re-cache the `commands/list' catalog, then report.
Refreshes SESSION-ID (default: the active session), which is useful
after the host has registered new commands while a session stays
open.  Runs asynchronously; the result is shown via message."
  (interactive)
  (let ((sid (or session-id (dsh-emacs--active-session-id))))
    (unless sid (user-error "Open or select a session first"))
    (dsh-emacs-command-catalog-invalidate sid)
    (dsh-emacs-command-catalog-fetch
     sid
     (lambda (items)
       (message (if items
                    "Slash commands refreshed: %d available"
                  "Slash command refresh failed (see *Messages*)")
                (if items (length items) 0))))))

;; ---------------------------------------------------------------------------
;; 交互入口
;; ---------------------------------------------------------------------------

(defun dsh-emacs-command--input-hint (command)
  "Return the argument hint of COMMAND (nil when it takes no input)."
  (let ((input (dsh-protocol-command-input command)))
    (and input (dsh-protocol-command-input-hint input))))

(defun dsh-emacs-command ()
  "Pick a slash command from the live catalog and run it.

Reads the `commands/list' catalog of the current session, offers the
commands (name + description) via `completing-read', prompts for the
argument text when the command declares an input hint, then submits
the line to `commands/execute'.  Requires a running server."
  (interactive)
  (dsh-emacs-server-ensure)
  (let ((session-id (dsh-emacs--active-session-id)))
    (unless session-id (user-error "Open or select a session first"))
    (let* ((items (dsh-emacs-command-catalog-sync session-id)))
      (if (null items)
          (message "No command catalog available")
        (condition-case nil
            (let* ((candidates
                    (mapcar
                     (lambda (command)
                       (let* ((name (format "/%s"
                                            (dsh-protocol-command-name command)))
                              (desc (dsh-protocol-command-description command))
                              (hint (dsh-emacs-command--input-hint command)))
                         (cons (propertize
                                name 'display
                                (if hint
                                    (format "%s — %s (%s)" name desc hint)
                                  (format "%s — %s" name desc)))
                               command)))
                     items))
                   (picked (completing-read "Slash command: " candidates nil t))
                   (command (cdr (assoc picked candidates))))
              (when command
                (let* ((name (format "/%s"
                                     (dsh-protocol-command-name command)))
                       (hint (dsh-emacs-command--input-hint command))
                       (args (and hint
                                  (read-string (format "Args (%s): " hint)))))
                  (dsh-emacs-command-execute
                   session-id
                   (if (and args (not (string-empty-p args)))
                       (format "%s %s" name args)
                     name)
                   nil
                   (lambda (ok execution _err)
                     (cond
                      ((null ok) nil) ; rpc-async 已打印传输错误
                      ((null execution)
                       (message "Unknown or malformed command: %s" name))
                      ((equal (dsh-protocol-command-execution-kind execution)
                              "error")
                       (message "Command failed: %s"
                                (or (dsh-protocol-command-execution-text
                                     execution)
                                    name)))))))))
          (quit nil))))))

(defun dsh-emacs-command-completion-at-point ()
  "`completion-at-point-functions' entry for slash commands.

Completes the \"/name\" token in the editable input area (text after
the `❯ ' prompt) over the command catalog: a bare \"/\" names the whole
command list, a partial name (typing \"/go\") filters it.  When the
catalog is not cached yet it is fetched synchronously, so the very
first trigger (typing \"/\" or TAB) already shows the full list.
Returns nil outside the input area or when the token is not a bare
command prefix.

Candidates are plain \"/name \" strings: the description rides the
frontend-standard `:annotation-function' metadata (dimmed right-hand
column) and `:company-kind' (a function of the candidate returning the
kind — icon column for nerd-icons-corfu / kind-icon users), so the
popup lays out exactly like other modes instead of wide `display'-text
rows that overflow the popup width."
  (let* ((pos (point))
         (marker (and (boundp 'dsh-emacs--input-marker)
                      dsh-emacs--input-marker)))
    (when (and marker (>= pos marker))
      (let ((case-fold-search nil)
            (line-text (buffer-substring marker pos)))
        (when (string-match-p "\\`/\\([a-z0-9_-]*\\)\\'" line-text)
          (let* ((session-id (dsh-emacs--active-session-id))
                 (items (or (dsh-emacs-command-catalog session-id)
                            (and session-id
                                 (dsh-emacs-command-catalog-sync
                                  session-id)))))
            (when items
              (let* ((pairs (mapcar
                             (lambda (command)
                               (cons (format "/%s "
                                             (dsh-protocol-command-name command))
                                     (dsh-protocol-command-description
                                      command)))
                             items))
                     (describe (lambda (cand)
                                 (cdr (assoc cand pairs))))
                     ;; nerd-icons-corfu / kind-icon read `:company-kind' as a
                     ;; *function* of the candidate returning the kind symbol
                     ;; (`(funcall kindfunc cand)' in
                     ;; `nerd-icons-corfu-formatter'), not a bare kind
                     (kind (lambda (_cand) 'command))
                     (candidates (mapcar #'car pairs)))
                (when candidates
                  (list marker pos candidates
                        :annotation-function describe
                        :company-kind kind))))))))))

(provide 'dsh-emacs-command)

;;; dsh-emacs-command.el ends here
