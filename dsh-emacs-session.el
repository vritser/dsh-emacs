;;; dsh-emacs-session.el --- Session list view -*- lexical-binding: t; -*-

;; Copyright (C) 2025 vritser

;; Author: vritser
;; Version: 0.1.0
;; License: GPL-3.0-or-later
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; 会话列表视图，参考 dsh web 设计：
;;   Sessions
;;   ──────────────────────────────────────────────────
;;   my-workspace  (3)
;;     ● session-title                              5m
;;     ● another-session                           2h
;;
;;   Ungrouped  (1)
;;     ● stray-session                             1d
;;
;; 每行显示：状态点 + 标题 + 相对时间。会话按工作区分组显示。
;; 标题即会话的自动摘要（`projections.values.title'，与 dsh web 一致：
;; 由首条用户消息概括生成）；空会话（blank）显示 "New Session"。
;; 详细信息通过 `i' 键显示在 minibuffer。
;;
;; 键位：
;;   RET     打开会话
;;   c       新建会话
;;   r       重命名会话
;;   D       删除会话（如果 API 支持）
;;   /       搜索过滤
;;   i       显示会话详情
;;   W       创建工作区（从目录）
;;   R       重命名当前工作区
;;   u       移除当前工作区注册
;;   g       刷新列表
;;   q       退出

;;; Code:

(require 'cl-lib)
(require 'hl-line)
(require 'dsh-emacs-ui)
(require 'dsh-emacs-faces)

;; These commands are defined in dsh-emacs.el, which loads this module to
;; install the session-list keymap.  Declare the cross-file API so native
;; compilation does not mistake the intentional load order for missing
;; functions.
(declare-function dsh-emacs-list-sessions "dsh-emacs" ())
(declare-function dsh-emacs-new-session "dsh-emacs" (&optional cwd workspace-id preset))
(declare-function dsh-emacs-new-session-choose-preset "dsh-emacs" ())
(declare-function dsh-emacs-open-session "dsh-emacs" (session-id))
(declare-function dsh-emacs-rename-session "dsh-emacs" (session-id new-title))
(declare-function dsh-emacs-archive-session "dsh-emacs" (session-id))
(declare-function dsh-emacs-fork-session "dsh-emacs" (session-id))
(declare-function dsh-emacs-server-ensure "dsh-emacs-server" ())
(declare-function dsh-emacs-create-workspace "dsh-emacs" (path))
(declare-function dsh-emacs-rename-workspace "dsh-emacs" (workspace-id new-title))
(declare-function dsh-emacs-delete-workspace "dsh-emacs" (workspace-id))
(declare-function dsh-emacs-move-workspace "dsh-emacs" (workspace-id before-workspace-id))
(declare-function dsh-emacs--rpc-async "dsh-emacs" (method params callback))
(declare-function dsh-emacs-events-host-connect "dsh-emacs-events" ())
(declare-function dsh-emacs-events-host-disconnect "dsh-emacs-events" ())

;; Defvars for cross-file caches owned by dsh-emacs.el, so native
;; compilation does not treat the reads as free-variable errors.
(defvar dsh-emacs--sessions nil
  "Cached session struct list (owned by dsh-emacs.el).")
(defvar dsh-emacs--workspaces nil
  "Cached workspace struct list (owned by dsh-emacs.el).")
(defvar dsh-emacs--archived-sessions nil
  "Archived session ids (owned by dsh-emacs.el).")
(defvar dsh-emacs--current-session nil
  "Globally active session (the last opened one); owned by dsh-emacs.el.
Interactively resolve command targets through `dsh-emacs--active-session-id'
(see the authoritative defvar in dsh-emacs.el).")

;;; ---------------------------------------------------------------------------
;;; 缓冲和模式
;;; ---------------------------------------------------------------------------

(defvar dsh-emacs-sessions-buffer "*dsh-sessions*"
  "Buffer name for the session list.")

(defvar dsh-emacs-session-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'dsh-emacs-open-session-at-point)
    (define-key map "c" #'dsh-emacs-new-session)
    (define-key map "C" #'dsh-emacs-new-session-choose-preset)
    (define-key map "r" #'dsh-emacs-rename-session-at-point)
    (define-key map "D" #'dsh-emacs-archive-session-at-point)
    (define-key map "f" #'dsh-emacs-fork-session-at-point)
    (define-key map "/" #'dsh-emacs-session-search)
    (define-key map "w" #'dsh-emacs-session-filter-workspace)
    (define-key map "i" #'dsh-emacs-session-show-info)
    (define-key map "W" #'dsh-emacs-create-workspace)
    (define-key map "R" #'dsh-emacs-rename-workspace-at-point)
    (define-key map "u" #'dsh-emacs-delete-workspace-at-point)
    (define-key map "M" #'dsh-emacs-move-workspace-at-point)
    (define-key map "g" #'dsh-emacs-list-sessions)
    (define-key map "q" #'quit-window)
    (define-key map "j" #'next-line)
    (define-key map "k" #'previous-line)
    (define-key map "n" #'next-line)
    (define-key map "p" #'previous-line)
    map)
  "Keymap for session list mode.")

(defcustom dsh-emacs-session-auto-refresh-interval nil
  "Seconds between automatic session-list refreshes, or nil to disable.
When set, the `*dsh-sessions*' buffer re-fetches the list on this cadence
while it is alive (the fetch already re-renders in place, keeping any
active workspace filter)."
  :type '(choice (const :tag "Off" nil)
                 (number :tag "Seconds"))
  :group 'dsh-emacs)

(define-derived-mode dsh-emacs-session-mode special-mode "DSH Sessions"
  "Major mode for browsing dsh sessions."
  (setq buffer-read-only t)
  (setq truncate-lines t)
  (setq cursor-type nil)
  (setq-local line-spacing 0.2)
  ;; Use the user's theme highlight for the focused row (default `hl-line'
  ;; face); do not impose a custom background.
  (hl-line-mode 1)
  (add-hook 'kill-buffer-hook #'dsh-emacs-session--auto-refresh-stop nil t)
  (dsh-emacs-session--auto-refresh-start)
  (when (fboundp 'dsh-emacs-events-host-connect)
    (dsh-emacs-events-host-connect)
    (add-hook 'kill-buffer-hook #'dsh-emacs-events-host-disconnect nil t))
  (dsh-emacs-session--render))

;;; ---------------------------------------------------------------------------
;;; 会话列表渲染
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-session--render ()
  "Render the session list, grouped by workspace."
  (let ((sessions dsh-emacs--sessions)
        (workspaces dsh-emacs--workspaces)
        (inhibit-read-only t)
        ;; 重绘后仍停在同一个会话行上：列表在事件/刷新/自动刷新之间重建时，
        ;; 光标不弹回顶部，hl-line 高亮也随之保持（否则导航中列表自己“跳走”，
        ;; 体感就是卡顿）。
        (restore-id (dsh-emacs-session-id-at-point)))
    (erase-buffer)
    
    ;; Header
    (insert (propertize "Sessions" 'face 'dsh-emacs-header-face))
    (when dsh-emacs-session--filter-ws-title
      (insert (propertize (format " | Filter: %s" dsh-emacs-session--filter-ws-title)
                          'face 'dsh-emacs-session-model-face)))
    (insert "\n")
    (insert (propertize (make-string 50 ?─) 'face 'dsh-emacs-separator-face))
    (insert "\n\n")
    
    (if (and (null sessions) (null workspaces))
        (progn
          (insert (propertize "No sessions. " 'face 'dsh-emacs-muted-face))
          (insert (propertize "Press 'c' to create one." 'face 'dsh-emacs-hint-face)))
      
      ;; Group sessions by workspace
      (dolist (group (dsh-emacs-session--group-sessions sessions workspaces))
        (dsh-emacs-session--render-group group)))
    ;; Restore the previously focused session row, if it is still listed.
    (when restore-id
      (goto-char (point-min))
      (catch 'dsh-session-restored
        (while (not (eobp))
          (when (equal restore-id (dsh-emacs-session-id-at-point))
            (throw 'dsh-session-restored t))
          (forward-line 1))))
    ;; On a fresh buffer (no previously focused row) the `insert` calls above
    ;; leave point at the end; park it on the first session row instead so the
    ;; list opens with the cursor (and hl-line) at the top, not the bottom.
    ;; A buffer with no rows simply stays at the header.
    (unless restore-id
      (goto-char (point-min))
      (catch 'dsh-first-row
        (while (not (eobp))
          (when (dsh-emacs-session-id-at-point)
            (throw 'dsh-first-row t))
          (forward-line 1))))))

(defun dsh-emacs-session--visible-p (session &optional current-session-id)
  "Non-nil when SESSION passes dsh web's visible-session rule.
Mirrors the dsh web browser tree: the session is not archived, not of
subagent origin, and not blank — unless it is the currently-open
session (CURRENT-SESSION-ID, defaulting to `dsh-emacs--current-session'),
which stays visible even while blank."
  (let* ((archived dsh-emacs--archived-sessions)
         (session-id (or (dsh-protocol-session-session-id session) ""))
         (current (or current-session-id dsh-emacs--current-session))
         (blank (dsh-protocol-session-blank session)))
    (not (or (and archived (gethash session-id archived))
             (dsh-protocol-session-origin session)
             (and blank (not (eq blank :json-false))
                  (not (equal session-id current)))))))

(defun dsh-emacs-session--group-sessions (sessions workspaces)
  "Group SESSIONS by WORKSPACES.
Returns a list of plists: (:label LABEL :workspace-id WS-ID :sessions MEMBERS),
in workspace order (WS-ID is nil for the ungrouped bucket).
When `dsh-emacs-session--filter-ws-id' is set, only that workspace's
members are returned (the ungrouped bucket is suppressed); archived
sessions are always excluded."
  ;; Build session-id → workspace-id map from each workspace's sessionIds.
  (let ((ws-by-id (make-hash-table :test 'equal))
        (ws-by-session (make-hash-table :test 'equal))
        (filter dsh-emacs-session--filter-ws-id)
        (current dsh-emacs--current-session)
        (groups nil)
        (ungrouped nil))
    (dolist (ws workspaces)
      (let ((ws-id (dsh-protocol-workspace-workspace-id ws)))
        (puthash ws-id ws ws-by-id)
        (dolist (sid (dsh-protocol-workspace-session-ids ws))
          (puthash sid ws-id ws-by-session))))
    ;; Assign each visible (non-archived) session to its workspace or the
    ;; ungrouped bucket.
    (dolist (session sessions)
      (let* ((session-id (or (dsh-protocol-session-session-id session) ""))
             (ws-id (gethash session-id ws-by-session)))
        ;; Skip archived sessions, subagent child sessions and blank
        ;; (never-messaged) rows — blank rows match dsh web's browser tree:
        ;; only the currently-open session stays visible among them.
        (when (dsh-emacs-session--visible-p session current)
          (if (and ws-id (or (null filter) (equal ws-id filter)))
              (let ((entry (assoc ws-id groups)))
                (if entry
                    (setcdr entry (cons session (cdr entry)))
                  (push (cons ws-id (list session)) groups)))
            ;; Only sessions outside any workspace land in the ungrouped
            ;; bucket, and only when the list is not filtered.
            (when (and (null ws-id) (null filter))
              (push session ungrouped))))))
    ;; Emit groups in workspace order, then ungrouped.  Empty workspaces
    ;; stay visible (their members may all be blank/archived/subagent):
    ;; without the header row there is no way to create a session in them.
    (let ((result nil))
      (dolist (ws workspaces)
        (let* ((ws-id (dsh-protocol-workspace-workspace-id ws))
               (title (or (dsh-protocol-workspace-title ws)
                          (dsh-emacs-session--workspace-basename
                           (dsh-protocol-workspace-path ws))))
               (members (dsh-emacs-session--sort-by-recency
                         (cdr (assoc ws-id groups)))))
          (when (or members (null filter) (equal ws-id filter))
            (push (list :label title :workspace-id ws-id :sessions members)
                  result))))
      (when ungrouped
        (push (list :label "Ungrouped" :workspace-id nil
                    :sessions (dsh-emacs-session--sort-by-recency ungrouped))
              result))
      (nreverse result))))

(defun dsh-emacs-session--sort-by-recency (sessions)
  "Sort SESSIONS by updatedAt descending (newest first)."
  (sort (copy-sequence sessions)
        (lambda (a b)
          (let ((ta (or (dsh-protocol-session-updated-at a) 0))
                (tb (or (dsh-protocol-session-updated-at b) 0)))
            (> (if (numberp ta) ta (string-to-number ta))
               (if (numberp tb) tb (string-to-number tb)))))))

(defun dsh-emacs-session--workspace-basename (path)
  "Return the basename of PATH, or PATH when empty."
  (if (and path (not (string-empty-p path)))
      (file-name-nondirectory (directory-file-name path))
    "Workspace"))

(defun dsh-emacs-session--render-group (group)
  "Render a GROUP plist header and its session rows."
  (let* ((label (plist-get group :label))
         (ws-id (plist-get group :workspace-id))
         (members (plist-get group :sessions))
         (count (length members)))
    ;; Group header
    (let ((start (point)))
      (insert (propertize (format "%s  (%d)" label count)
                          'face 'dsh-emacs-group-face))
      (when ws-id
        (put-text-property start (point) 'dsh-emacs-workspace-id ws-id))
      (put-text-property start (point) 'dsh-emacs-workspace-title label)
      (insert "\n"))
    ;; Session rows: every row carries the workspace context (id + title)
    ;; so `c' (new session) anywhere inside this group creates inside it.
    (if members
        (dolist (session members)
          (dsh-emacs-session--render-session session 2
                                             (and ws-id ws-id)
                                             (and ws-id label)))
      ;; Empty workspace: show a New Session row (like dsh web's blank
      ;; row) so `c' can create a session inside this workspace.
      (let ((start (point)))
        (insert (propertize "  New Session" 'face 'dsh-emacs-status-idle-face))
        (when ws-id
          (put-text-property start (point) 'dsh-emacs-workspace-id ws-id)
          (put-text-property start (point) 'dsh-emacs-workspace-title label))
        (insert "\n")))
    (insert "\n")))

;;; ---------------------------------------------------------------------------
;;; 工作区过滤 / 自动刷新 / 分支
;;; ---------------------------------------------------------------------------

(defvar-local dsh-emacs-session--filter-ws-id nil
  "Workspace id the session list is filtered to, or nil for all.")
(defvar-local dsh-emacs-session--filter-ws-title nil
  "Human title of the active workspace filter (shown in the header).")

(defvar-local dsh-emacs-session--auto-refresh-timer nil
  "Timer driving `dsh-emacs-session-auto-refresh-interval'.")

(defun dsh-emacs-session-filter-workspace ()
  "Filter the session list to one workspace (or clear the filter).
Choices are the workspace titles from the loaded workspace list; an empty
answer clears the filter.  `g' refreshes while keeping the filter."
  (interactive)
  (let* ((workspaces dsh-emacs--workspaces)
         (entries (mapcar (lambda (ws)
                            (cons (or (dsh-protocol-workspace-title ws)
                                      (dsh-emacs-session--workspace-basename
                                       (dsh-protocol-workspace-path ws)))
                                  (dsh-protocol-workspace-workspace-id ws)))
                          workspaces))
         ;; require-match is nil so an empty answer (which clears the filter)
         ;; is accepted — a literal `t' would force a valid candidate and make
         ;; it impossible to type empty to restore the full list.
         (picked (completing-read "Filter by workspace (empty to clear): "
                                  entries nil nil)))
    (if (or (string-empty-p picked)
            ;; A typed string that matches no known workspace also means
            ;; "show all" (leave the filter cleared), rather than silently
            ;; picking a nil workspace-id.
            (null (assoc picked entries)))
        (setq dsh-emacs-session--filter-ws-id nil
              dsh-emacs-session--filter-ws-title nil)
      (setq dsh-emacs-session--filter-ws-id (cdr (assoc picked entries))
            dsh-emacs-session--filter-ws-title picked))
    (dsh-emacs-session--render)))

(defun dsh-emacs-session--auto-refresh-start ()
  "Start the auto-refresh timer for this buffer, if configured."
  (when (and dsh-emacs-session-auto-refresh-interval
             (> dsh-emacs-session-auto-refresh-interval 0)
             (null dsh-emacs-session--auto-refresh-timer))
    (let ((buf (current-buffer)))
      (setq dsh-emacs-session--auto-refresh-timer
            (run-at-time dsh-emacs-session-auto-refresh-interval
                         dsh-emacs-session-auto-refresh-interval
                         (lambda ()
                           (when (buffer-live-p buf)
                             (with-current-buffer buf
                               (dsh-emacs-list-sessions)))))))))

(defun dsh-emacs-session--auto-refresh-stop ()
  "Cancel this buffer's auto-refresh timer."
  (when (timerp dsh-emacs-session--auto-refresh-timer)
    (cancel-timer dsh-emacs-session--auto-refresh-timer))
  (setq dsh-emacs-session--auto-refresh-timer nil))

(defun dsh-emacs-fork-session-at-point ()
  "Fork the session under point into a new child session."
  (interactive)
  (dsh-emacs-server-ensure)
  (let ((session-id (dsh-emacs-session-id-at-point)))
    (unless session-id (user-error "No session at point"))
    (dsh-emacs-fork-session session-id)))

(defun dsh-emacs-session--title (session)
  "Return SESSION's auto-generated title (summary text), or nil.
The API carries it at `projections.values.title' — the first-user-prompt
summary that dsh web shows in the session list.  (Not under sessionStats.)"
  (dsh-protocol-session-title-value session))

(defun dsh-emacs-session--display-title (session)
  "Display name for SESSION, matching dsh web: \"New Session\" for blank
rows, otherwise the generated summary title, else a cwd-derived name."
  (let ((blank (dsh-protocol-session-blank session))
        (inferred (dsh-emacs-session--title session)))
    (cond
     ((and blank (not (eq blank :json-false))) "New Session")
     ((and inferred (not (string-empty-p inferred))) inferred)
     (t (dsh-emacs-session--generate-name session)))))

(defun dsh-emacs-session--render-session (session &optional indent
                                                     workspace-id workspace-title)
  "Render a single SESSION row, optionally indented by INDENT spaces.
When WORKSPACE-ID is given (rendering inside a workspace group), the row
carries `dsh-emacs-workspace-id' / `dsh-emacs-workspace-title' text
properties as well, so commands like `c' (new session) started on ANY row
of that workspace create the session inside it — matching dsh web, where
the workspace context applies to the whole group."
  (let* ((session-id (or (dsh-protocol-session-session-id session) ""))
         (running (let ((value (dsh-protocol-session-running session)))
                    (and value (not (eq value :json-false)))))
         (updated-at (dsh-protocol-session-updated-at session))
         ;; Compute status from projections
         (status (dsh-emacs-session--compute-status session running))

         ;; Format fields: the display title is the auto-generated summary
         ;; (`values.title') like dsh web; blank sessions show "New Session".
         (title-str (dsh-emacs-session--display-title session))
         (time-str (dsh-emacs-session--compact-time updated-at))

         ;; Status indicator
         (status-dot (dsh-emacs-session--status-dot status))

         ;; Column at which the time begins, measured from the left margin.
         ;; indent + status dot (1 col) + separator space + 46-column title
         ;; field + 2-col gap.  `:align-to' is used instead of literal space
         ;; padding so the column holds even when a title's rendered glyph
         ;; width differs from `string-width' (proportional/CJK fonts), which
         ;; would otherwise let the time drift right/left.
         (time-column (+ (or indent 0) 1 49))
         (row (concat
               (make-string (or indent 0) ?\s)
               status-dot " "
               ;; Pad to a fixed width so over-long titles truncate and short
               ;; ones keep a readable gap; the exact column is then pinned by
               ;; the :align-to below regardless of title glyph widths.
               (propertize (dsh-emacs-session--pad-right title-str 46)
                           'face 'dsh-emacs-session-title-face)
               (propertize " " 'display `(space :align-to ,time-column))
               (propertize (or time-str "") 'face 'dsh-emacs-muted-face))))
    
    ;; Insert row with text properties for selection and (optionally) the
    ;; containing workspace
    (let ((start (point)))
      (insert row)
      (put-text-property start (point) 'dsh-emacs-session session)
      (put-text-property start (point) 'dsh-emacs-session-id session-id)
      (when workspace-id
        (put-text-property start (point) 'dsh-emacs-workspace-id workspace-id)
        (put-text-property start (point)
                           'dsh-emacs-workspace-title workspace-title))
      (insert "\n"))))

;;; ---------------------------------------------------------------------------
;;; 辅助函数
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-session--generate-name (session)
  "Generate a name for SESSION when it has no title."
  (let ((cwd (or (dsh-protocol-session-cwd session) "")))
    (if (not (string-empty-p cwd))
        (file-name-nondirectory (directory-file-name cwd))
      "Untitled")))

(defun dsh-emacs-session--compact-time (timestamp)
  "Format TIMESTAMP as compact relative time (e.g., 'now', '5m', '3h', '2d').
Accept both numeric and string timestamps in seconds or milliseconds."
  (when timestamp
    (let* ((now (float-time))
           (raw (if (numberp timestamp)
                    timestamp
                  (string-to-number timestamp)))
           ;; The API uses Unix milliseconds; accept seconds as well for
           ;; compatibility with older session data.
           (last (if (> raw 10000000000)
                     (/ raw 1000.0)
                   raw))
           (diff (- now last)))
      (cond
       ((< diff 60) "now")
       ((< diff 3600) (format "%dm" (/ diff 60)))
       ((< diff 86400) (format "%dh" (/ diff 3600)))
       ((< diff (* 30 86400)) (format "%dd" (/ diff 86400)))
       ((< diff (* 365 86400)) (format "%dmo" (/ diff (* 30 86400))))
       (t (format "%dy" (/ diff (* 365 86400))))))))

(defun dsh-emacs-session--pad-right (str width)
  "Pad STR to WIDTH display columns with trailing spaces.
WIDTH is measured in display columns (`string-width'): wide characters
(CJK, emoji) count 2, so the session list's time column stays aligned
for both ASCII and Chinese titles.  Over-wide strings are truncated to
WIDTH display columns without splitting a wide character."
  (let ((w (string-width str)))
    (if (<= w width)
        (concat str (make-string (- width w) ?\s))
      (truncate-string-to-width str width))))

(defun dsh-emacs-session--compute-status (session running)
  "Compute session status: 'running, 'approval, 'pending, or 'idle.
Uses projections data when available, falls back to running flag."
  (let* ((pending-interaction (dsh-protocol-session-pending-interaction
                                  session)))
    (cond
     ;; Pending interaction takes priority
     ((and pending-interaction
           (not (eq pending-interaction :json-false)))
      (pcase (if (stringp pending-interaction) pending-interaction
               (symbol-name pending-interaction))
        ("approval" 'approval)
        ("plan-review" 'approval)
        ("question" 'pending)
        (_ 'pending)))
     ;; Running state
     (running 'running)
     ;; Default to idle
     (t 'idle))))

(defun dsh-emacs-session--git-branch (cwd)
  "Get current git branch in CWD, or nil."
  (when (and cwd (file-directory-p cwd))
    (with-temp-buffer
      (let ((default-directory cwd))
        (when (= 0 (call-process "git" nil t nil "rev-parse" "--abbrev-ref" "HEAD"))
          (string-trim (buffer-string)))))))

(defun dsh-emacs-session--status-dot (status)
  "Return a colored dot for STATUS."
  (pcase status
    ('running  (propertize "●" 'face 'dsh-emacs-status-running-face))
    ('approval (propertize "●" 'face 'dsh-emacs-status-pending-face))
    ('pending  (propertize "●" 'face 'dsh-emacs-status-pending-face))
    (_         (propertize "●" 'face 'dsh-emacs-status-idle-face))))

;;; ---------------------------------------------------------------------------
;;; 交互命令
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-session-at-point ()
  "Get session at point, or nil."
  (get-text-property (point) 'dsh-emacs-session))

(defun dsh-emacs-session-id-at-point ()
  "Get session ID at point, or nil."
  (get-text-property (point) 'dsh-emacs-session-id))

(defun dsh-emacs-open-session-at-point ()
  "Open session at point."
  (interactive)
  (dsh-emacs-server-ensure)
  (let ((session-id (dsh-emacs-session-id-at-point)))
    (if session-id
        (progn
          (dsh-emacs-open-session session-id)
          (message "Opened session %s" session-id))
      (user-error "No session at point"))))

(defun dsh-emacs-rename-session-at-point ()
  "Rename session at point."
  (interactive)
  (dsh-emacs-server-ensure)
  (let* ((session-id (dsh-emacs-session-id-at-point))
         (session (dsh-emacs-session-at-point))
         (current-title (and session (dsh-emacs-session--title session)))
         (new-title (read-string "New title: " (or current-title ""))))
    (when session-id
      (dsh-emacs-rename-session session-id new-title))))

(defun dsh-emacs-archive-session-at-point ()
  "Archive session at point (remove it from its workspace view)."
  (interactive)
  (dsh-emacs-server-ensure)
  (let ((session-id (dsh-emacs-session-id-at-point)))
    (if session-id
        (when (yes-or-no-p (format "Archive session %s? " session-id))
          (dsh-emacs-archive-session session-id))
      (user-error "No session at point"))))

(defun dsh-emacs-workspace-id-at-point ()
  "Get workspace ID at point, or nil."
  (get-text-property (point) 'dsh-emacs-workspace-id))

(defun dsh-emacs-workspace-title-at-point ()
  "Get workspace title at point, or nil."
  (get-text-property (point) 'dsh-emacs-workspace-title))

(defun dsh-emacs-delete-workspace-at-point ()
  "Remove workspace registration at point (directory and logs are kept)."
  (interactive)
  (dsh-emacs-server-ensure)
  (let ((workspace-id (dsh-emacs-workspace-id-at-point)))
    (if workspace-id
        (when (yes-or-no-p "Remove this workspace? (Sessions become ungrouped) ")
          (dsh-emacs-delete-workspace workspace-id))
      (user-error "Not on a workspace header"))))

(defun dsh-emacs-rename-workspace-at-point ()
  "Rename workspace at point."
  (interactive)
  (dsh-emacs-server-ensure)
  (let* ((workspace-id (dsh-emacs-workspace-id-at-point))
         (current-title (dsh-emacs-workspace-title-at-point))
         (new-title (read-string "New workspace title: " (or current-title ""))))
    (when workspace-id
      (dsh-emacs-rename-workspace workspace-id new-title))))

(defun dsh-emacs-move-workspace-at-point ()
  "Move the workspace under point to another position in the list.
Prompts for the workspace to insert BEFORE (or append to the end), then
calls `workspace.insertBefore' — dsh web's drag-to-reorder persisted via
RPC rather than by mouse."
  (interactive)
  (dsh-emacs-server-ensure)
  (let ((workspace-id (dsh-emacs-workspace-id-at-point))
        (workspace-title (dsh-emacs-workspace-title-at-point)))
    (if (null workspace-id)
        (user-error "Not on a workspace header")
      (let* ((current (format "%s (%s)" workspace-title workspace-id))
             (candidates
              (append
               (cl-loop for ws in dsh-emacs--workspaces
                        for id = (dsh-protocol-workspace-workspace-id ws)
                        unless (equal id workspace-id)
                        collect (cons (format "%s (%s)"
                                              (or (dsh-protocol-workspace-title ws)
                                                  (dsh-emacs-session--workspace-basename
                                                   (dsh-protocol-workspace-path ws)))
                                              id)
                                      id))
               (list (cons ".. (move to end)" :end))))
             (choice (completing-read
                      (format "Move %s before: " (or workspace-title current))
                      candidates nil t))
             (before (cdr (assoc choice candidates))))
        (dsh-emacs-move-workspace
         workspace-id
         (and (not (eq before :end)) before))))))

(defun dsh-emacs-session-show-info ()
  "Show detailed info for session at point in minibuffer.
The base line (status, title, cwd, time, preset) shows immediately; the
live model for the session is fetched once (`session.models') and appended
when it arrives."
  (interactive)
  (dsh-emacs-server-ensure)
  (let* ((session (dsh-emacs-session-at-point))
         (session-id (dsh-emacs-session-id-at-point)))
    (if (not session)
        (user-error "No session at point")
      (let* ((cwd (or (dsh-protocol-session-cwd session) ""))
             (running (let ((value (dsh-protocol-session-running session)))
                        (and value (not (eq value :json-false)))))
             (updated-at (dsh-protocol-session-updated-at session))
             (title (dsh-emacs-session--title session))
             (preset (or (dsh-protocol-session-agent-preset session) ""))
             (status (dsh-emacs-session--compute-status session running))
             (time-str (dsh-emacs-session--compact-time updated-at))
             (cwd-short (dsh-emacs-session--shorten-cwd cwd))
             (branch (dsh-emacs-session--git-branch cwd))
             (kind (cond ((dsh-protocol-session-origin session)
                          "subagent")
                         ((dsh-protocol-session-parent-session-id session)
                          "child(fork)")
                         (t "root")))
             (info (format "%s %s | %s | %s%s | %s | [%s]"
                           (pcase status
                             ('running "⟳")
                             ((or 'approval 'pending) "⏳")
                             (_ "·"))
                           (or title "Untitled")
                           cwd-short
                           (or time-str "")
                           (if branch (format " (%s)" branch) "")
                           (if preset preset session-id)
                           kind)))
        (message "%s" info)
        ;; The session-list item carries no model field, so query the live
                ;; catalog once per `i' press (never per list row — that would be
        ;; N+1 requests).
        (dsh-emacs--rpc-async "session.models"
                              `((sessionId . ,session-id))
                              (lambda (ok value)
                                (when ok
                                  (let ((current (and (listp value)
                                                      (dsh-protocol-model-directory-current
                                                       (dsh-protocol-model-directory--from-alist
                                                        value)))))
                                    (when current
                                      (message "%s | Model: %s (%s)"
                                               info
                                               (dsh-protocol-model-selection-model current)
                                               (dsh-protocol-model-selection-provider current)))))))))))
(defun dsh-emacs-session--shorten-cwd (cwd)
  "Shorten CWD path for display."
  (let ((home (expand-file-name "~")))
    (if (string-prefix-p home cwd)
        (concat "~" (substring cwd (length home)))
      ;; Otherwise show last 2 components
      (let ((parts (split-string cwd "/")))
        (if (> (length parts) 2)
            (concat "../" (car (last parts 2)) "/" (car (last parts)))
          cwd)))))

(defun dsh-emacs-session-debug-ungrouped ()
  "Show every ungrouped session's id / kind / parent for dsh-web comparison.
Ungrouped = not claimed by any workspace and not archived.  Kinds are
`subagent' (origin=\"subagent\"), `child' (fork child: has parentSessionId
but no origin) and `root'.  Blank rows are marked B; dsh web hides blank
rows except the currently-open session."
  (interactive)
  (let ((ws-sessions (make-hash-table :test 'equal))
        (shown 0))
    (dolist (ws dsh-emacs--workspaces)
      (dolist (sid (dsh-protocol-workspace-session-ids ws))
        (puthash sid t ws-sessions)))
    (dolist (session dsh-emacs--sessions)
      (let* ((sid (or (dsh-protocol-session-session-id session) ""))
             (claimed (gethash sid ws-sessions))
             (archived (and dsh-emacs--archived-sessions
                            (gethash sid dsh-emacs--archived-sessions)))
             (blank (let ((b (dsh-protocol-session-blank session)))
                      (and b (not (eq b :json-false)))))
             (kind (cond ((dsh-protocol-session-origin session) "subagent")
                         ((dsh-protocol-session-parent-session-id session) "child")
                         (t "root"))))
        (unless (or claimed archived)
          (setq shown (1+ shown))
          (message "  %-40s %-8s %s parent=%s title=%s"
                   sid kind
                   (if blank "B" " ")
                   (or (dsh-protocol-session-parent-session-id session) "-")
                   (or (dsh-emacs-session--title session) "Untitled")))))
    (message "Ungrouped: %d session(s), dsh web keeps the non-blank ones" shown)))

(defun dsh-emacs-session-search ()
  "Search sessions by title or ID."
  (interactive)
  (let* ((query (read-string "Search: "))
         (matches (cl-remove-if-not
                   (lambda (session)
                     (let ((title (dsh-emacs-session--title session)))
                       (or (and title (string-match-p query title))
                           (string-match-p query (or (dsh-protocol-session-session-id session) "")))))
                   dsh-emacs--sessions)))
    (if matches
        (progn
          (setq dsh-emacs--sessions matches)
          (dsh-emacs-session--render))
      (message "No sessions match '%s'" query))))

(provide 'dsh-emacs-session)

;;; dsh-emacs-session.el ends here
