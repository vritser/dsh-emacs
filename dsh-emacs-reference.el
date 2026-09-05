;;; dsh-emacs-reference.el --- @ file/session references (web-style mentions) -*- lexical-binding: t; -*-

;; Copyright (C) 2025 vritser

;; Author: vritser
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; dsh web 的 `@' 指令：在输入区键入 `@' 弹出文件与会话引用菜单。本文件
;; 是 dsh-emacs 的组合器一侧 —— 与 web 客户端共用一个 wire：
;;
;;   - `fileReferences/list'              工作区文件/目录路径提示（typert
;;                                        Remote，HTTP POST /api/fileReferences/list）
;;   - `sessionReferenceResolver/candidates'
;;                                       会话引用候选（带规范 mention 文本，
;;                                       HTTP POST /api/sessionReferenceResolver/candidates）
;;
;; 两者 payload 都是 {args: {agentId, query}}，走与 `commands.list' 相同的
;; 信封。补全弹层的会话行显示短标签（`@label'，对齐 web 行），选择后经
;; completion 的 :exit-function 改写为 host 产出的规范 mention
;; `@[label](dsh-session:…)' 插入输入区；该文本经普通 `session.prompt' 送达
;; 后，服务端的 agent/pre-step 监听器负责解析 mention、冻结源会话快照并注入
;; 上下文（见 harness 的 dsh-session-reference 包）—— 快照逻辑全在 host，
;; 本文件只做组合器，与 web 的 dsh-client-ui-reference 职责一致。
;;
;; 语法与插入规则逐字对齐 web 的 grammar.ts（`dsh-emacs-reference--at-token'
;; = activeAtToken，`dsh-emacs-reference--format-file-mention' =
;; formatFileMention）：`@path' / `@"path with spaces' 令牌；含空格的路径
;; 用引号形态；目录候选带尾斜杠并继续补全；含控制字符或引号的路径不可
;; 表示、直接跳过；`@' 在其它令牌内部（如邮件地址）不是触发器。
;;
;; 缓存语义（stale-while-revalidate，对应 web 的"失效后索引继续应答"决策）：
;; 每个查询首次请求同步拉取两个 remote（与 slash 首次 TAB 的 catalog-sync
;; 同款一次往返）。补全是协作式的（与 slash 同款）：dsh-emacs 只注册 capf、
;; 把 "@" 贡献给用户已开启的 corfu-auto 触发器，从不自行驱动补全 UI。Corfu
;; 用原生 completion table 负责每次编辑/退格的过滤；`dsh-emacs-reference--
;; auto-complete'（`dsh-emacs-mode' 挂的 post-command）在 @ 令牌变化时后台
;; 取 host 数据，供目录下钻等场景经 corfu 自己的 deferred 路径刷新/重开弹层。
;; 非 Corfu（stock / vertico / icomplete）无自动通道，按 TAB 补全。输入永远
;; 不会阻塞在网络往返上。
;;
;; 提供：
;;   - `dsh-emacs-reference--at-token'      输入区 `@path' / `@"path' 令牌解析
;;   - `dsh-emacs-reference--format-file-mention'
;;                                         候选 → 提示文本（对齐 web 规则）
;;   - `dsh-emacs-reference-completion-at-point'
;;                                         `completion-at-point-functions' 入口
;;   - `dsh-emacs-reference-auto-trigger-setup'
;;                                         协作式 "@" 自动触发（corfu）
;;   - `dsh-emacs-reference--auto-complete' corfu 数据拉取 watcher（post-command）
;;   - `dsh-emacs-reference-prefetch'       打开会话时预热裸查询缓存
;;   - `dsh-emacs-reference'                M-x 菜单：completing-read 选引用

;;; Code:

(require 'cl-lib)
(require 'dsh-emacs-protocol)

(declare-function dsh-emacs--rpc-async "dsh-emacs.el" (method params callback))
(declare-function dsh-emacs--rpc-request "dsh-emacs.el" (method params))
(declare-function dsh-emacs--completing-read-ordered
                  "dsh-emacs.el" (prompt collection &rest args))
;; Corfu's native auto path is the same integration seam installed by
;; `dsh-emacs-mode'; use it for async refreshes instead of generic CAPF
;; dispatch, which treats a sole non-exact candidate differently.
(declare-function corfu-auto--complete-deferred "corfu-auto" (&optional tick))
(declare-function dsh-emacs--active-session-id "dsh-emacs.el" ())
(declare-function dsh-emacs--get-input "dsh-emacs.el" ())
(declare-function dsh-emacs-server-ensure "dsh-emacs-server.el" ())

;; dsh-emacs.el 的输入区域锚点（buffer-local），本模块只读借用
(defvar dsh-emacs--input-marker)
;; corfu 的可选变量（corfu-auto-trigger 由 corfu-auto.el 定义）。前向声明只
;; 为 byte-compile 干净；运行期用 `bound-and-true-p' / `boundp' 把关。
(defvar corfu-auto)
(defvar corfu-auto-trigger)

(defgroup dsh-emacs-reference nil
  "@ file/session references (fileReferences.list /
sessionReferenceResolver.candidates)."
  :group 'dsh-emacs)

(defcustom dsh-emacs-reference-auto-complete t
  "Whether typing \"@\" in the input area auto-pops the reference list.
dsh-emacs is a completion backend only — it never enables a completion
front-end's auto mode by itself.  When this is non-nil it contributes
\"@\" to whichever front-end already has its own auto mode turned on:
corfu (`@' added buffer-locally to `corfu-auto-trigger' when
`corfu-auto' is enabled, so corfu's engine pops on \"@\" ignoring
`corfu-auto-prefix') and company (works through `company-capf' / its own
idle delay).  Stock `*Completions*' / vertico / icomplete have no auto
channel and complete on TAB only.  When nil no trigger is contributed.
TAB and `M-x dsh-emacs-reference' always work regardless."
  :type 'boolean
  :group 'dsh-emacs-reference)

(defcustom dsh-emacs-reference-prefetch t
  "Whether opening a non-Corfu chat session pre-fetches its bare-query @
candidate lists (files under the session cwd + the session roster).

The fetch runs on a short idle timer after the chat buffer opens, so
the first \"@\" completion already reads a warm cache instead of the
synchronous first-trigger round trip.  Corfu buffers skip this pre-fetch:
corfu pops on the \"@\" trigger and drives its own first fetch through
the capf / data-fetch watcher, so the cache warms on demand there.  The
pre-fetch is a no-op when the cache is already populated."
  :type 'boolean
  :group 'dsh-emacs-reference)

(defcustom dsh-emacs-reference-prefetch-delay 0.5
  "Idle delay (seconds) before the bare-query @ pre-fetch runs.
Keeps the pre-fetch from racing the session-history load that also
starts when the chat buffer opens."
  :type 'number
  :group 'dsh-emacs-reference)

(defcustom dsh-emacs-reference-fetch-delay 0.15
  "Idle delay (seconds) before a typed @ token triggers its async fetch.
A short debounce: fast typing re-arms the timer instead of stacking
one remote round trip per keystroke (stale timers drop out because
the timer re-checks the token before firing)."
  :type 'number
  :group 'dsh-emacs-reference)

(defcustom dsh-emacs-reference-max-files nil
  "Maximum file/directory candidates kept in the popup at once, or nil.
Nil includes every candidate returned by the host (the default).  When
set, the host-ranked list is truncated to this many entries."
  :type '(choice (const :tag "All candidates" nil) natnum)
  :group 'dsh-emacs-reference)

(defcustom dsh-emacs-reference-max-sessions nil
  "Maximum session candidates kept in the popup at once, or nil.
Nil includes every candidate returned by the host (the default); when
set, the host-ranked list is truncated to this many entries."
  :type '(choice (const :tag "All candidates" nil) natnum)
  :group 'dsh-emacs-reference)

(defcustom dsh-emacs-reference-inline-icons t
  "Whether @ menu rows carry a per-type icon prefix (consult-buffer
style), when nerd-icons or all-the-icons is available and the frame
is graphical.

The icon is drawn with the icon package's own glyphs: a `.ts' file
row shows the TypeScript icon, a directory row the folder icon, an
extension-less path the generic file glyph, and a session row the
`references' glyph (nerd-icons; a link glyph with all-the-icons).
It rides the completion `:affixation-function', a display-only
column: the inserted text is still the plain mention.  The column is
always drawn by this module itself — no `:company-kind' metadata is
sent for the @ menu, so margin icon layers (nerd-icons-corfu,
kind-icon) never replace it: their file/folder `:fn' glyphs lose the
nerd-font family face and can render as garbage symbols.  On
non-graphical frames no icon glyphs are emitted at all (nerd-font
codepoints render as garbage in terminals): rows stay plain text.
Set to nil to always keep the rows text-only."
  :type 'boolean
  :group 'dsh-emacs-reference)

;; ---------------------------------------------------------------------------
;; 缓存状态（buffer-local：每个聊天缓冲一份，mode 重入时随
;; `kill-all-local-variables' 清空，重开会话由 prefetch 重新预热）
;; ---------------------------------------------------------------------------

(defvar-local dsh-emacs--reference-candidates nil
  "Combined candidate cache: list of (TEXT . PROPS).
TEXT is the formatted mention inserted on pick (`@path', `@path/',
`@\"path with spaces\"', or the canonical `@[label](dsh-session:...)').
PROPS is a plist: `:kind' (`file'/`directory'/`session'), `:path' for
files, `:label'/`:session-id'/`:cwd'/`:same-workspace' for sessions.
Files precede directories, which precede sessions; each group keeps the
host's deterministic order.")

(defvar-local dsh-emacs--reference-query nil
  "The query whose results `dsh-emacs--reference-candidates' holds.
Nil means nothing has been fetched into this buffer yet.")

(defvar-local dsh-emacs--reference-requested nil
  "The query the UI currently wants (nil = none yet).
Settle paths install a fetch only when it matches this value, and a
superseded fetch re-arms for it, so fast typing catches up to the
latest query exactly once per intermediate keystroke.")

(defvar-local dsh-emacs--reference-inflight nil
  "Non-nil while a reference fetch is running.
Prevents duplicate fetches for the same desired query; the settle
path clears it and re-arms when the requested query moved on.")

(defvar-local dsh-emacs--reference-fetch-gen 0
  "Generation counter guarding slice callbacks.
A newer fetch bumps it; callbacks from an older generation are
dropped instead of overwriting the newer slices out of order.")

(defvar-local dsh-emacs--reference-files nil
  "File slice of the in-flight fetch (nil until the remote settles).")

(defvar-local dsh-emacs--reference-sessions nil
  "Session slice of the in-flight fetch (nil until the remote settles).")

(defvar-local dsh-emacs--reference-pop-token nil
  "The @ token that last drove a background reference fetch.
De-dup for the data-fetch watcher: a changed query re-fetches, so
keystrokes while an @ reference is in progress keep the cache warm.")

;; ---------------------------------------------------------------------------
;; 语法（对齐 web 的 packages/context/file-reference/src/grammar.ts）
;; ---------------------------------------------------------------------------

(defun dsh-emacs-reference--at-token (text)
  "Return the active @ token ending TEXT, or nil.
Mirrors the web composer grammar (`activeAtToken'): a `@path' or
`@\"path' token that starts at the beginning of TEXT or after
whitespace and runs to its end.  An `@' inside another token (e.g. an
email address) is not a trigger.  Returns (PREFIX QUERY QUOTED):
PREFIX the raw token span (\"@…\" or \"@\"…\"), QUERY the path text
after the marker, QUOTED non-nil for the quoted form."
  (let ((case-fold-search nil))
    (or (and (string-match
              "\\(?:\\`\\|[ \t\r\n\f]\\)\\(@\"\\([^\"]*\\)\\)\\'" text)
             (list (match-string 1 text) (match-string 2 text) t))
        (and (string-match
              "\\(?:\\`\\|[ \t\r\n\f]\\)\\(@\\([^ \t\r\n\f]*\\)\\)\\'" text)
             (list (match-string 1 text) (match-string 2 text) nil)))))

(defun dsh-emacs-reference--format-file-mention (path kind &optional preserve-quote)
  "Format file PATH (KIND is the wire string `file'/`directory') as prompt text.
Web `formatFileMention' semantics:
- directory paths gain a trailing \"/\" so completion can descend;
- paths containing whitespace are wrapped in the quoted form; a
  quoted directory keeps its quote open (\"@\"path/) so typing can
  drill another level;
- paths with control characters or a double quote are NOT
  representable: returns nil and the candidate is skipped.
PRESERVE-QUOTE keeps the quoted form even when unnecessary (the
user's own quote stays open)."
  (let ((path (if (equal kind "directory") (concat path "/") path)))
    (unless (string-match-p "[\000-\037\177-\237\"]" path)
      (let ((quoted (or preserve-quote
                        (string-match-p "[ \t\r\n\f]" path))))
        (cond
         ((not quoted) (concat "@" path))
         ((equal kind "directory") (concat "@\"" path))
         (t (concat "@\"" path "\"")))))))

;; ---------------------------------------------------------------------------
;; 候选归一化（wire 数组 → 缓存条目）
;; ---------------------------------------------------------------------------

(defun dsh-emacs-reference--collect-files (value)
  "Normalize a `fileReferences/list' VALUE into cache entries.
Each entry is (TEXT . (:kind file|directory :path PATH)); candidates
whose path the mention grammar cannot represent are skipped.  Rows
are grouped files-first, then directories (the host ranks directories
ahead of files on equal scores; the menu shows files before
directories), each kind group keeping the host's rank order."
  (let* ((entries (delq nil
                        (mapcar
                         (lambda (wire)
                           (let* ((candidate (dsh-protocol-file-reference-candidate--from-alist
                                              wire))
                                  (path (dsh-protocol-file-reference-candidate-path
                                         candidate))
                                  (kind (dsh-protocol-file-reference-candidate-kind
                                         candidate))
                                  (text (dsh-emacs-reference--format-file-mention
                                         path kind)))
                             (and text
                                  (cons text
                                        (list :kind (intern kind) :path path)))))
                         (dsh-protocol--list value))))
         (dir-p (lambda (entry)
                  (eq (plist-get (cdr entry) :kind) 'directory))))
    (append (cl-remove-if dir-p entries)
            (cl-remove-if-not dir-p entries))))

(defun dsh-emacs-reference--collect-sessions (value)
  "Normalize a `sessionReferenceResolver/candidates' VALUE into cache entries.
Each entry is (TEXT . (:kind session :label L :session-id ID :cwd CWD
:same-workspace SW)) with TEXT the host's canonical mention — the
exact prompt text the pick inserts.  A candidate without a mention is
skipped: the client must not invent references outside the canonical
URI encoding.  Host rank order is kept."
  (delq nil
        (mapcar
         (lambda (wire)
           (let* ((candidate (dsh-protocol-session-reference-candidate--from-alist
                              wire))
                  (mention (dsh-protocol-session-reference-candidate-mention
                            candidate)))
             (and (stringp mention)
                  (cons mention
                        (list :kind 'session
                              :label (dsh-protocol-session-reference-candidate-label
                                      candidate)
                              :session-id (dsh-protocol-session-reference-candidate-session-id
                                           candidate)
                              :cwd (dsh-protocol-session-reference-candidate-cwd
                                    candidate)
                              :same-workspace (dsh-protocol-session-reference-candidate-same-workspace
                                               candidate))))))
         (dsh-protocol--list value))))

(defun dsh-emacs-reference--combine (files sessions)
  "Deterministic cache order: files, directories, then SESSIONS.
Each group keeps its host order; a non-nil configured cap truncates it."
  (append (if dsh-emacs-reference-max-files
              (cl-subseq files 0
                         (min (length files) dsh-emacs-reference-max-files))
            files)
          (if dsh-emacs-reference-max-sessions
              (cl-subseq sessions 0
                         (min (length sessions)
                              dsh-emacs-reference-max-sessions))
            sessions)))

;; ---------------------------------------------------------------------------
;; 拉取状态机
;; ---------------------------------------------------------------------------

(defun dsh-emacs-reference--fetch-query (session-id query)
  "Asynchronously fetch reference candidates for QUERY in SESSION-ID.
Runs `fileReferences/list' and `sessionReferenceResolver/candidates'
concurrently (each fails independently); when both settle the
combined list is installed into the buffer-local cache if QUERY is
still the requested one, otherwise a newer fetch is re-armed for the
latest requested query.  Returns non-nil when this call started (or
reused) a fetch."
  (cond
   ((equal query dsh-emacs--reference-query) nil)
   (dsh-emacs--reference-inflight nil)
   ((null session-id) nil)
   (t
    (setq dsh-emacs--reference-inflight t
          dsh-emacs--reference-files nil
          dsh-emacs--reference-sessions nil)
    (let ((gen (1+ dsh-emacs--reference-fetch-gen)))
      (setq dsh-emacs--reference-fetch-gen gen)
      (dsh-emacs--rpc-async
       "fileReferences/list"
       `((agentId . ,session-id) (query . ,query))
       (lambda (ok value)
         (when (= gen dsh-emacs--reference-fetch-gen)
           (setq dsh-emacs--reference-files
                 (and ok (dsh-emacs-reference--collect-files value)))
           (dsh-emacs-reference--fetch-settle session-id query))))
      (dsh-emacs--rpc-async
       "sessionReferenceResolver/candidates"
       `((agentId . ,session-id) (query . ,query))
       (lambda (ok value)
         (when (= gen dsh-emacs--reference-fetch-gen)
           (setq dsh-emacs--reference-sessions
                 (and ok (dsh-emacs-reference--collect-sessions value)))
           (dsh-emacs-reference--fetch-settle session-id query)))))
    t)))

(defun dsh-emacs-reference--fetch-settle (session-id query)
  "Finish one fetch generation for QUERY: install the cache or re-arm.
Both slices must have landed (nil counts as a settled empty/failed
slice, listp distinguishes it from an un-arrived one).  Installs only
when QUERY is still `dsh-emacs--reference-requested'; a superseded
fetch re-arms once for the newer query so typing never dead-ends."
  (when (and (listp dsh-emacs--reference-files)
             (listp dsh-emacs--reference-sessions))
    (setq dsh-emacs--reference-inflight nil)
    (if (equal query dsh-emacs--reference-requested)
        (progn
          (setq dsh-emacs--reference-query query
                dsh-emacs--reference-candidates
                (dsh-emacs-reference--combine dsh-emacs--reference-files
                                              dsh-emacs--reference-sessions))
          (dsh-emacs-reference--schedule-popup-refresh))
      (unless (equal dsh-emacs--reference-requested dsh-emacs--reference-query)
        (dsh-emacs-reference--fetch-query session-id
                                          dsh-emacs--reference-requested)))))

(defun dsh-emacs-reference--schedule-popup-refresh ()
  "Refresh the completion popup once an async fetch lands.
Runs on a zero-delay idle timer (the settle callback itself may run
inside a process filter, where driving completion UI directly is not
safe).  Re-checks that an @ token is still active and that the cache
really holds the requested query, so a superseded fetch never opens
the popup with a stale table.

Cooperative, like the slash completion: dsh-emacs never opens the
completion UI itself.  When Corfu auto-completion is active it stays
responsible for the current popup (a live popup is left alone; only a
settled *directory* query re-enters Corfu's own deferred path to open
the freshly fetched next level).  Non-Corfu setups have no auto channel
and complete on TAB, so nothing is opened here."
  (let ((buf (current-buffer)))
    (run-with-idle-timer
     0 nil
     (lambda ()
       (condition-case nil
           (when (and (buffer-live-p buf)
                      (get-buffer-window buf)
                      (with-current-buffer buf
                        (and (dsh-emacs-reference--active-token)
                             (equal dsh-emacs--reference-requested
                                    dsh-emacs--reference-query))))
             (with-current-buffer buf
               (cond
                ((and (boundp 'corfu-auto) corfu-auto
                      (bound-and-true-p completion-in-region-mode)) nil)
                ((and (boundp 'corfu-auto) corfu-auto
                      (string-suffix-p "/" dsh-emacs--reference-requested)
                      (fboundp 'corfu-auto--complete-deferred))
                 (corfu-auto--complete-deferred)))))
         (error nil))))))

(defun dsh-emacs-reference--require-cache (session-id query)
  "Make the candidate cache answer QUERY, synchronously when needed.
Returns non-nil when the cache can answer now:
- already current for QUERY;
- a cache from a previous query is present: kept answering (the
  completion UI filters it by the new input text) even while a
  background refresh for QUERY is in flight — stale-while-revalidate,
  so an in-flight fetch never shuts the popup mid-typing;
- the very first trigger (empty cache): fetched synchronously, the
  same one-time round trip the slash catalog makes on first TAB.
Returns nil only when there is nothing to show yet (no cache and a
fetch already building one — the settle path installs and refreshes
the popup instead).  On a total sync failure the cache is left empty
so the next trigger retries."
  (cond
   ((equal query dsh-emacs--reference-query) t)
   (dsh-emacs--reference-query t)
   (dsh-emacs--reference-inflight nil)
   (session-id
    (let ((files (dsh-emacs--rpc-request
                  "fileReferences/list"
                  `((agentId . ,session-id) (query . ,query))))
          (sessions (dsh-emacs--rpc-request
                     "sessionReferenceResolver/candidates"
                     `((agentId . ,session-id) (query . ,query)))))
      (if (or (car files) (car sessions))
          (progn
            (setq dsh-emacs--reference-query query
                  dsh-emacs--reference-candidates
                  (dsh-emacs-reference--combine
                   (and (car files)
                        (dsh-emacs-reference--collect-files (cdr files)))
                   (and (car sessions)
                        (dsh-emacs-reference--collect-sessions (cdr sessions)))))
            t)
        nil)))
   (t nil)))

;; ---------------------------------------------------------------------------
;; corfu 数据拉取 watcher：@ 候选按 query 动态来自 host（与 slash 的静态目录
;; 不同）。watcher 只在 @ 令牌变化时后台取数，popup 由 corfu 触发器 / 异步刷新
;; 打开；dsh-emacs 从不自行驱动补全 UI（见 `dsh-emacs-mode' 的挂接）。
;; ---------------------------------------------------------------------------

(defun dsh-emacs-reference--active-token ()
  "Return the active @ token ending at point, or nil.
Extracts the token from the editable input text (input marker to
point); nil outside a chat buffer or when no `@path' / `@\"path' token
is in progress at the cursor.  A COMPLETED host session mention
(`@[label](dsh-session:…)') is not an active token: the web keeps it
behind an atomic chip so typing after a pick never re-opens the menu,
and our M-x insert must not swallow it either.  Returns (PREFIX QUERY
QUOTED), see `dsh-emacs-reference--at-token'."
  (when (and dsh-emacs--input-marker
             (markerp dsh-emacs--input-marker)
             (eq (marker-buffer dsh-emacs--input-marker) (current-buffer))
             (>= (point) (marker-position dsh-emacs--input-marker)))
    (let ((token (dsh-emacs-reference--at-token
                  (buffer-substring-no-properties
                   (marker-position dsh-emacs--input-marker)
                   (point)))))
      (and token
           ;; 完成的规范 mention 文本（host 会把标签里的 `\` 与 `]` 转义成
           ;; `\\` / `\]`，口径见 harness 的 formatSessionReferenceMention）：
           ;; 标签区 = 任意个 (转义对 `\X` | 非 `]` 非 `\` 字符)，然后收尾
           ;; `](dsh-session:<base64url>)`。
           (not (string-match-p
                 "\\`@\\[\\(?:\\\\.\\|[^]\\\\]\\)*\\](dsh-session:[A-Za-z0-9_-]+)\\'"
                 (nth 0 token)))
           token))))

(defun dsh-emacs-reference--auto-complete ()
  "Corfu data-fetch watcher for an in-progress @ token.
`post-command-hook' entry (installed by `dsh-emacs-mode').  @ candidates
are host/query-dynamic, so while corfu-auto is active and an @ token is
in progress this issues a debounced background host fetch for the
token's query; a settled fetch re-enters corfu's native popup via
`dsh-emacs-reference--schedule-popup-refresh'.  It never opens a
completion UI itself — corfu owns the popup (opened by the \"@\"
trigger), and non-corfu buffers complete on TAB and do nothing here.
Text that merely contains an `@' inside another token (email addresses)
does not match the grammar and keeps typing uninterrupted.  A trailing
slash is an explicit directory boundary, fetched without the typing
debounce."
  (when (and dsh-emacs-reference-auto-complete
             (bound-and-true-p corfu-auto)
             (let ((token (dsh-emacs-reference--active-token)))
               (and token (not (equal token dsh-emacs--reference-pop-token)))))
    (setq dsh-emacs--reference-pop-token (dsh-emacs-reference--active-token))
    (let* ((buf (current-buffer))
           (delay (if (string-suffix-p "/"
                                       (nth 1 dsh-emacs--reference-pop-token))
                      0
                    dsh-emacs-reference-fetch-delay)))
      (run-with-idle-timer
       delay nil
       (lambda ()
         (when (buffer-live-p buf)
           (with-current-buffer buf
             (when (equal (dsh-emacs-reference--active-token)
                          dsh-emacs--reference-pop-token)
               (let* ((token dsh-emacs--reference-pop-token)
                      (query (nth 1 token))
                      (session-id (dsh-emacs--active-session-id)))
                 (setq dsh-emacs--reference-requested query)
                 (dsh-emacs-reference--require-cache session-id query)
                 (dsh-emacs-reference--fetch-query session-id query))))))))))

(defun dsh-emacs-reference-prefetch (session-id)
  "Pre-fetch the bare-query @ candidate lists of SESSION-ID lazily.
Called when a chat buffer opens: the file list and the session roster
are fetched on a short idle timer (see
`dsh-emacs-reference-prefetch-delay') so the first \"@\" completion
reads a warm cache instead of the synchronous first-trigger round
trip.  It is disabled for Corfu buffers, where corfu pops on the \"@\"
trigger and drives its own first fetch through the capf / data-fetch
watcher.  No-op unless
`dsh-emacs-reference-prefetch' is enabled, the cache is empty and the
buffer still owns SESSION-ID.  Returns nil."
  (when (and dsh-emacs-reference-prefetch
             session-id
             (null dsh-emacs--reference-query)
             (not dsh-emacs--reference-inflight)
             ;; Corfu performs its own first fetch from the "@" trigger path;
             ;; a prefetch racing that path leaves no table for the trigger to
             ;; re-open after the request settles.
             (not (and (boundp 'corfu-auto) corfu-auto)))
    (let ((buf (current-buffer)))
      (run-with-idle-timer
       dsh-emacs-reference-prefetch-delay nil
       (lambda ()
         (when (buffer-live-p buf)
           (with-current-buffer buf
             (when (and (equal (dsh-emacs--active-session-id) session-id)
                        (null dsh-emacs--reference-query)
                        (not dsh-emacs--reference-inflight))
               (setq dsh-emacs--reference-requested "")
               (dsh-emacs-reference--fetch-query session-id "")))))))))

;; ---------------------------------------------------------------------------
;; 补全 UI 侧
;; ---------------------------------------------------------------------------

(defun dsh-emacs-reference--session-rows ()
  "Alist (ROW . MENTION) for every session cache entry, in cache order.
ROW is the short completion row (`@label'; a repeated label gains a
` #n' suffix so every session stays reachable and the exit lookup
stays unambiguous); MENTION is the canonical text the pick inserts.
File/directory entries are their own row and never appear here."
  (let ((seen (make-hash-table :test 'equal)))
    (delq nil
          (mapcar
           (lambda (entry)
             (when (eq (plist-get (cdr entry) :kind) 'session)
               (let* ((props (cdr entry))
                      (label (or (plist-get props :label)
                                 (plist-get props :session-id)))
                      (base (concat "@" label))
                      (n (1+ (gethash base seen 0))))
                 (puthash base n seen)
                 (cons (if (= n 1)
                           base
                         (format "%s #%d" base n))
                       (car entry)))))
           dsh-emacs--reference-candidates))))

(defun dsh-emacs-reference--entry-for (text)
  "The cache entry (MENTION . PROPS) behind completion row TEXT.
File/directory rows are their own mention; a session row (the short
`@label' display) resolves through `dsh-emacs-reference--session-rows'
to its canonical mention first."
  (or (assoc text dsh-emacs--reference-candidates)
      (let ((mention (cdr (assoc text (dsh-emacs-reference--session-rows)))))
        (and mention (assoc mention dsh-emacs--reference-candidates)))))

(defun dsh-emacs-reference--row-icon (path kind)
  "Type icon for a completion row of KIND, or nil when none can render.
KIND is `file', `directory' or `session'.  Prefers nerd-icons (its
`icon-for-file' picks the glyph by the file's extension,
`icon-for-dir' the folder glyph, and the codicon `references' marks
session mentions — the same glyph nerd-icons-corfu used for the
`reference' kind), then all-the-icons (a link glyph for sessions).
PATH is the file/directory path, ignored for sessions.  Returns nil
on non-graphic frames — nerd-font PUA codepoints render as garbage in
terminals, so icon-free setups get plain text rows there — and nil
when no icon provider is loaded."
  (when (display-graphic-p)
    (cond
     ((and (featurep 'nerd-icons)
           (fboundp 'nerd-icons-icon-for-file)
           (fboundp 'nerd-icons-icon-for-dir))
      (if (eq kind 'session)
          (nerd-icons-codicon "nf-cod-references")
        (funcall (symbol-function (if (eq kind 'directory)
                                      'nerd-icons-icon-for-dir
                                    'nerd-icons-icon-for-file))
                 path)))
     ((and (featurep 'all-the-icons)
           (fboundp 'all-the-icons-icon-for-file)
           (fboundp 'all-the-icons-icon-for-dir))
      (if (eq kind 'session)
          (all-the-icons-faicon "link")
        (funcall (symbol-function (if (eq kind 'directory)
                                      'all-the-icons-icon-for-dir
                                    'all-the-icons-icon-for-file))
                 path)))
     (t nil))))

(defun dsh-emacs-reference--snapshot-affix (cands rows)
  "Capture (TEXT . (KIND . PATH)) for completion rows CANDS.
ROWS is the session (ROW . MENTION) alist of the current cache.  Taken
once at completion-table build time so the icon column is decided for
exactly the rows the table exposes and never reverse-looked-up against
`dsh-emacs--reference-candidates' later — a background fetch replaces
that cache while a corfu popup still shows its older snapshot, and
re-affixating those rows against the swapped cache would drop their
icons (see `dsh-emacs-reference--affixate-with').  Rows the cache does
not resolve (nothing to draw) map to nil."
  (let ((cache dsh-emacs--reference-candidates))
    (mapcar
     (lambda (text)
       (cons text
             (let ((entry (or (assoc text cache)
                              (let ((mention (cdr (assoc text rows))))
                                (and mention (assoc mention cache))))))
               (and entry
                    (cons (plist-get (cdr entry) :kind)
                          (plist-get (cdr entry) :path))))))
     cands)))

(defun dsh-emacs-reference--affixate-with (map cands)
  "Build the (CAND PREFIX SUFFIX) rows the popup renders.
PREFIX is the per-type icon (consult-buffer style, see
`dsh-emacs-reference--row-icon') resolved from MAP, the captured
(TEXT . (KIND . PATH)) snapshot `dsh-emacs-reference--snapshot-affix'
took when the table was built: a file's extension glyph, the folder
glyph for directories, the `references'/link glyph for session rows.
Prefixes are empty on non-graphic frames, when
`dsh-emacs-reference-inline-icons' is nil or when no icon provider is
loaded.  The column is drawn by this module itself: no `:company-kind'
metadata is sent, so margin icon layers (nerd-icons-corfu, kind-icon)
never replace it — their file/folder `:fn' glyphs lose the nerd-font
family face and can render as garbage symbols.  SUFFIX is always empty:
completion rows show no annotation.  The icon column is display-only:
completion inserts the plain candidate regardless."
  (mapcar
   (lambda (cand)
     (let* ((kp (cdr (assoc cand map)))
            (kind (car kp))
            (icon (and dsh-emacs-reference-inline-icons
                       kind
                       (dsh-emacs-reference--row-icon (cdr kp) kind))))
       (list cand
             (if icon (concat icon " ") "")
             "")))
   cands))

(defun dsh-emacs-reference--affixate (cands)
  "Affixate CANDS against the current cache.
`dsh-emacs-reference--affixate-with' over a live
`dsh-emacs-reference--snapshot-affix'; callers that build a completion
table (corfu/vertico/company-capf) must capture the map once instead,
so a mid-popup cache refresh cannot strip icons.  This live variant is
kept for the completion UIs that only query the cache synchronously and
for tests."
  (dsh-emacs-reference--affixate-with
   (dsh-emacs-reference--snapshot-affix
    cands (dsh-emacs-reference--session-rows))
   cands))

(defun dsh-emacs-reference--exit (cand _status rows)
  "Rewrite a picked session row CAND into its canonical mention.
The completion UI has already inserted the row text (`@label', with a
` #n' suffix for repeated labels) and ROWS is the (ROW . MENTION)
alist of the capf call that produced the popup.  The row is replaced
in place by the canonical `@[label](dsh-session:...)' mention, so the
message wire always carries the reference text — and a label
containing spaces (`@My Talk') would otherwise fail the unquoted
@-token grammar and re-open the menu.  File/directory rows are their
own mention already: no ROWS entry, nothing to do.  STATUS is ignored;
the row text is final in every completion state."
  (let* ((entry (dsh-emacs-reference--entry-for cand))
         (props (cdr entry))
         (mention (cdr (assoc cand rows))))
    ;; A picked directory already ends in "/".  Fetch that directory's
    ;; children now, then the settled callback re-enters Corfu's native path
    ;; with the active @dir/ token so drilling does not require another slash.
    (when (eq (plist-get props :kind) 'directory)
      (setq dsh-emacs--reference-requested
            (concat (plist-get props :path) "/")
            ;; A directory candidate can itself have come from this exact
            ;; query.  Picking it is still an explicit refresh boundary, so
            ;; do not let the cache-equality fast path suppress the request.
            dsh-emacs--reference-query nil)
      (dsh-emacs-reference--fetch-query
       (dsh-emacs--active-session-id)
       dsh-emacs--reference-requested))
    (when mention
      (let ((start (- (point) (length cand))))
        (when (and (>= start (point-min))
                   (string= (buffer-substring-no-properties start (point))
                            cand))
          (delete-region start (point))
          (insert mention))))))

(defun dsh-emacs-reference-completion-at-point ()
  "`completion-at-point-functions' entry for @ file/session references.
Completes the active `@path' / `@\"path' token in the editable input
area over the combined candidate cache (files, then directories, then
sessions):
a bare \"@\" names every candidate, a partial query filters it.  The
first trigger synchronously fetches both reference remotes (the same
one-time round trip the slash catalog makes); later keystrokes answer
from the cache for the previous query while the data-fetch watcher
refreshes it in the background, so typing never blocks on the
network.

Rows are the texts the popup shows and filters: file/directory rows
are the formatted mention (`@path', `@path/', `@\"path with spaces\"'),
session rows the short `@label' (web-style) instead of the long
canonical mention — picking either replaces the whole token; a picked
session row is rewritten to its canonical `@[label](dsh-session:...)'
mention by the completion `:exit-function', so the wire text stays
canonical and the popup width is not stretched by the opaque session
ids.  File/directory rows carry a per-type icon column
(`:affixation-function', consult-buffer style) when
`dsh-emacs-reference-inline-icons' finds an icon provider.  Returns
nil outside the input area or when the token is not an @ reference."
  (let* ((marker (and (boundp 'dsh-emacs--input-marker)
                      dsh-emacs--input-marker))
         (pos (point)))
    (when (and marker
               (markerp marker)
               (eq (marker-buffer marker) (current-buffer))
               (>= pos (marker-position marker)))
      (let* ((text (buffer-substring-no-properties (marker-position marker) pos))
             (token (dsh-emacs-reference--at-token text))
             (session-id (dsh-emacs--active-session-id)))
        (when (and token session-id)
          (let* ((query (nth 1 token))
                 (start (- pos (length (nth 0 token)))))
            (setq dsh-emacs--reference-requested query)
            (when (dsh-emacs-reference--require-cache session-id query)
              (let* ((rows (dsh-emacs-reference--session-rows))
                     (mention->row
                      (let ((m (make-hash-table :test 'equal)))
                        (dolist (row rows m)
                          (puthash (cdr row) (car row) m))))
                     (candidates
                      (mapcar (lambda (entry)
                                (or (gethash (car entry) mention->row)
                                    (car entry)))
                              dsh-emacs--reference-candidates)))
                (when candidates
                  ;; Corfu's in-region backend reads sorting metadata from the
                  ;; completion table, not from CAPF extra properties.  Keep
                  ;; both forms: the table metadata covers corfu, while the
                  ;; plist covers stock completion and other CAPF consumers.
                  (let ((table (completion-table-with-metadata
                                candidates
                                '((category . dsh-emacs-reference)
                                  ;; Match @ references flexibly across the whole
                                  ;; path regardless of the user's global
                                  ;; completion-styles: chat buffers map this
                                  ;; category to the built-in `flex' style (see
                                  ;; `dsh-emacs-mode'), so typing a mid-path word
                                  ;; narrows to files like @src/…/button.tsx.
                                  (display-sort-function . identity)
                                  (cycle-sort-function . identity))))
                        (props (list :affixation-function
                                     ;; Snapshot the icon data when the table
                                     ;; is built: affixating later against the
                                     ;; live cache would drop icons once a
                                     ;; background fetch replaces it while a
                                     ;; corfu popup still shows its older
                                     ;; snapshot (see
                                     ;; `dsh-emacs-reference--snapshot-affix').
                                     (let ((map (dsh-emacs-reference--snapshot-affix
                                                 candidates rows)))
                                       (lambda (cands)
                                         (dsh-emacs-reference--affixate-with
                                          map cands)))
                                     ;; Let Corfu's trigger reopen the menu at
                                     ;; a bare @ after backspace, even though
                                     ;; its normal prefix threshold is longer.
                                     :company-prefix-length t
                                     ;; Keep the host-ranked group order in
                                     ;; stock completion and in completion
                                     ;; UIs such as vertico/corfu.
                                     :display-sort-function
                                     #'identity)))
                    ;; 不提供 `:company-kind'：nerd-icons-corfu / kind-icon 的
                    ;; margin formatter 对 `:fn' 型条目（file/folder）会做
                    ;; (propertize icon 'face 映射face)，把 nerd-font 字体族从
                    ;; `face' 属性剥掉（只剩 font-lock-face，显示按 `face' 解析）
                    ;; —— PUA 字形落到默认字体 → 乱码；静态 codicon 条目（如
                    ;; slash 菜单的 command）不受影响。图标一律由本模块的
                    ;; `:affixation-function' 列自绘（字体族保留），无 kind 时
                    ;; margin formatter 整体停用、prefix 列不被覆盖。
                    (apply #'list start pos table
                           (append props
                                   (list :exit-function
                                         (lambda (cand status)
                                           (dsh-emacs-reference--exit
                                            cand status rows)))))))))))))))

;; ---------------------------------------------------------------------------
;; @ 引用渲染：transcript / 输入行把完成的 mention 显示成彩色可点击链接
;; (canonical mention 仍是 buffer/上发的原文，这里只加显示与跳转属性)。
;; ---------------------------------------------------------------------------

(defvar dsh-emacs-reference--mention-keymap
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'dsh-emacs-reference-open-at-point)
    (define-key map [return] #'dsh-emacs-reference-open-at-point)
    (define-key map [follow-link] #'dsh-emacs-reference-open-at-point)
    (define-key map [mouse-1] #'dsh-emacs-reference-open-at-point)
    (define-key map [mouse-2] #'dsh-emacs-reference-open-at-point)
    map)
  "Keymap on a rendered @ reference span: RET / mouse-1 / mouse-2 open it.
`[follow-link]' is bound so the `follow-link' text property resolves to this
command; without it a click would fall back to `mouse-yank-primary' and hit
the read-only transcript (`insert-for-yank: Text is read-only').")

(defconst dsh-emacs-reference--session-mention-re
  "@\\[\\(\\(?:\\\\.\\|[^]\\\\]\\)*\\)\\](dsh-session:\\([A-Za-z0-9_-]+\\))"
  "Regexp matching a completed session mention `@[label](dsh-session:…)'.
Group 1 is the raw label interior (possibly carrying `\\]' / `\\\\' escapes),
group 2 the opaque session id.")

(defconst dsh-emacs-reference--file-mention-re
  "\\(?:^\\|[ \t\r\n\f]\\)\\(@\"[^\"]*\"\\|@[^ \t\r\n\f@]+\\)"
  "Regexp matching a file reference `@path' or `@\"quoted path\"'.
The `@' must start the string or follow whitespace (group 1 is the token,
its left boundary is group 0) so prose like `mail@example' is not linked.")

(defun dsh-emacs-reference--unescape-label (raw)
  "Unescape a raw session-label interior RAW into its display text.
Decodes the `\\\\X' escapes the host emits (`\\\\]' → `]', `\\\\\\\\' → `\\')."
  (replace-regexp-in-string
   "\\\\\\(.\\)" "\\1" raw t t))

(defun dsh-emacs-reference--link-spans (string)
  "Reference spans (BEG END KIND VALUE) in STRING, non-overlapping, by start.
KIND is `session' or `file'; VALUE is the session id or the relative file
path (quotes/`@' stripped).  A session mention's span covers the whole
`@[label](dsh-session:…)' text (labels may contain spaces); a file span the
`@…' token.  File tokens falling inside a session mention (its `@[label'
prefix) are not matched as files."
  (let ((spans '())
        (limit (length string))
        (sm dsh-emacs-reference--session-mention-re))
    (let ((pos 0))
      (while (and (<= pos limit) (string-match sm string pos))
        (push (list (match-beginning 0) (match-end 0) 'session
                    (match-string 2 string))
              spans)
        (setq pos (match-end 0))))
    (let ((m dsh-emacs-reference--file-mention-re)
          (pos 0))
      (while (and (<= pos limit) (string-match m string pos))
        (let* ((b (match-beginning 1))
               (e (match-end 1))
               (tok (match-string 1 string))
               (containing
                (cl-some (lambda (s)
                           (and (<= (nth 0 s) b) (>= (nth 1 s) e) s))
                         spans)))
          (if containing
              (setq pos (nth 1 containing))
            (push (list b e 'file
                        (if (string-prefix-p "@\"" tok)
                            (substring tok 2 -1)
                          (substring tok 1)))
                  spans)
            (setq pos e)))))
    (sort spans (lambda (a b) (< (nth 0 a) (nth 0 b))))))

(defun dsh-emacs-reference--propertize-span (text kind value)
  "Return TEXT propertized as a clickable reference of KIND for VALUE."
  (let ((str (copy-sequence text)))
    (add-text-properties
     0 (length str)
     (list 'face 'dsh-emacs-reference-face
           'mouse-face 'highlight
           'follow-link t
           'keymap dsh-emacs-reference--mention-keymap
           'help-echo (if (eq kind 'session)
                          "RET/mouse-1: open this session"
                        "RET/mouse-1: open this file")
           'dsh-emacs-reference-ref (cons kind value))
     str)
    str))

(defun dsh-emacs-reference-fontify (string)
  "Return a copy of STRING with completed @ references made clickable.
A session mention (`@[label](dsh-session:…)') is rewritten to display just
`@label' (the opaque id never shown) carrying its id; a file reference
(`@path' / `@\"quoted path\"') keeps its text.  Both gain
`dsh-emacs-reference-face', RET/mouse bindings and a
`dsh-emacs-reference-ref' property that `dsh-emacs-reference-open-at-point'
reads.  Non-matching text and any pre-existing properties are preserved.
The returned text is for display only — callers keep the raw canonical text
in the buffer / on the wire."
  (let ((out '())
        (pos 0))
    (dolist (s (dsh-emacs-reference--link-spans string))
      (let ((beg (nth 0 s)) (end (nth 1 s))
            (kind (nth 2 s)) (value (nth 3 s)))
        (push (substring string pos beg) out)
        (push (dsh-emacs-reference--propertize-span
               (if (eq kind 'session)
                   (concat "@" (dsh-emacs-reference--session-label-at string beg))
                 (substring string beg end))
               kind value)
              out)
        (setq pos end)))
    (push (substring string pos) out)
    (apply #'concat (nreverse out))))

(defun dsh-emacs-reference--session-label-at (string beg)
  "Label display text of the session mention in STRING starting at BEG."
  (let ((m dsh-emacs-reference--session-mention-re))
    (and (string-match m string beg)
         (= (match-beginning 0) beg)
         (dsh-emacs-reference--unescape-label (match-string 1 string)))))

(defun dsh-emacs-reference--open-ref (kind value)
  "Open reference KIND (`session' / `file') with VALUE."
  (declare-function dsh-emacs-open-session "dsh-emacs.el" (session-id))
  (declare-function dsh-emacs--chat-cwd "dsh-emacs.el" (session-id))
  (pcase kind
    ('session
     (if (and value (fboundp 'dsh-emacs-open-session))
         (dsh-emacs-open-session value)
       (user-error "No session id to open")))
    ('file
     (let* ((sid (dsh-emacs--active-session-id))
            (cwd (and sid (fboundp 'dsh-emacs--chat-cwd)
                      (dsh-emacs--chat-cwd sid)))
            (abs (and cwd value (expand-file-name value cwd))))
       (if (and abs (file-exists-p abs))
           (find-file abs)
         (user-error "Reference file not found locally: %s"
                     (or value "")))))))

(defun dsh-emacs-reference-open-at-point ()
  "Open the @ reference under point: jump to its session or open its file.
The reference data rides the `dsh-emacs-reference-ref' text property set by
`dsh-emacs-reference-fontify'.  RET / mouse-1 on the span call this."
  (interactive)
  (let ((ref (get-text-property (point) 'dsh-emacs-reference-ref)))
    (if (null ref)
        (user-error "No @ reference here")
      (dsh-emacs-reference--open-ref (car ref) (cdr ref)))))

;; ---------------------------------------------------------------------------
;; M-x 入口
;; ---------------------------------------------------------------------------

(defun dsh-emacs-reference--display-pairs ()
  "Completion display pairs for the M-x menu: (DISPLAY . MENTION).
DISPLAY is the web-style row (file path / directory with slash /
session label); MENTION is the text inserted on pick."
  (mapcar
   (lambda (entry)
     (cons
      (pcase (plist-get (cdr entry) :kind)
        ('session (plist-get (cdr entry) :label))
        ('directory (concat (plist-get (cdr entry) :path) "/"))
        (_ (plist-get (cdr entry) :path)))
      (car entry)))
   dsh-emacs--reference-candidates))

(defun dsh-emacs-reference--insert-at-point (mention)
  "Insert MENTION into the editable input area at point.
An @ token ending at point is replaced; the cursor is clamped into
the input area first."
  (let ((inhibit-read-only t))
    (when (and dsh-emacs--input-marker
               (markerp dsh-emacs--input-marker)
               (eq (marker-buffer dsh-emacs--input-marker) (current-buffer)))
      (when (< (point) (marker-position dsh-emacs--input-marker))
        (goto-char (marker-position dsh-emacs--input-marker)))
      (let* ((token (dsh-emacs-reference--active-token))
             (start (if token
                        (- (point) (length (nth 0 token)))
                      (point))))
        (delete-region start (point))
        (insert mention)))))

(defun dsh-emacs-reference ()
  "Insert an @ file or session reference into the chat input, at point.
Synchronously fetches the reference candidates for the current @
token (or an empty query when none is active), offers them via
`completing-read' (files, then directories, then sessions; rows show
plain candidate text) and replaces the active token — or
inserts at point when the cursor already sits inside the input area —
with the formatted mention.  Requires a chat buffer with a session."
  (interactive)
  (dsh-emacs-server-ensure)
  (let* ((session-id (dsh-emacs--active-session-id)))
    (unless session-id (user-error "Open or select a session first"))
    (let* ((token (dsh-emacs-reference--active-token))
           (query (or (and token (nth 1 token)) "")))
      (setq dsh-emacs--reference-requested query)
      (if (dsh-emacs-reference--require-cache session-id query)
          (progn
            (condition-case nil
                (let* ((pairs (dsh-emacs-reference--display-pairs))
                       (picked (dsh-emacs--completing-read-ordered
                                "Reference: " pairs nil t)))
                  (when picked
                    (dsh-emacs-reference--insert-at-point picked)))
              (quit nil)))
        (message "Reference candidates are still loading…")))))

;; ---------------------------------------------------------------------------
;; 协作式自动触发（与 slash 同款：只贡献触发器字符，不启用前端自动模式）
;; ---------------------------------------------------------------------------

(defun dsh-emacs-reference-auto-trigger-setup ()
  "Contribute \"@\" to the auto trigger in the current chat buffer.
`dsh-emacs-mode' calls this when a chat buffer opens.  dsh-emacs never
enables a completion front-end's auto mode itself; it only adds \"@\"
buffer-locally to `corfu-auto-trigger' when the user already enabled
corfu's auto completion (`corfu-auto' non-nil), so corfu's own engine
pops the @ reference list on \"@\" (ignoring `corfu-auto-prefix').
company needs no contribution (it reaches this buffer's capf via
`company-capf'), and stock completion has no auto channel (@ completes
on TAB).  No-op unless `dsh-emacs-reference-auto-complete' is non-nil."
  (when (and dsh-emacs-reference-auto-complete
             (bound-and-true-p corfu-auto)
             (require 'corfu-auto nil t)
             (boundp 'corfu-auto-trigger)
             (not (string-match-p "@" corfu-auto-trigger)))
    (setq-local corfu-auto-trigger (concat corfu-auto-trigger "@"))))

(provide 'dsh-emacs-reference)

;;; dsh-emacs-reference.el ends here
