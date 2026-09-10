;;; dsh-emacs-shell.el --- Local `!command' shell commands -*- lexical-binding: t; -*-

;; Copyright (C) 2025 vritser

;; Author: vritser
;; Version: 0.3.0
;; License: GPL-3.0-or-later
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; 输入区以 `!' 开头、后跟命令的行会在本机执行（Pi / agent-shell 风格的
;; 客户端 shell 命令），不会发给模型：`!git status' 运行 git status，
;; `!ls' 运行 ls。本文件提供：
;;
;;   - `dsh-emacs-shell-parse'      判定一行输入是否为 `!command' 命令（纯函数）
;;   - `dsh-emacs-shell-submit'     提交路径：记历史、清输入、开始执行
;;   - `dsh-emacs-shell-run'        shell-file-name 加 -c 异步执行并渲染结果
;;   - `dsh-emacs-shell-process-kill'
;;                                  M-x / C-c C-!：中断当前 buffer 的运行中命令
;;   - `dsh-emacs-shell-mode-setup' 每个聊天 buffer 的清理钩子（buffer 被杀时
;;                                  杀掉仍被跟踪的 shell 主进程）
;;
;; 发送路径（`dsh-emacs--submit-prompt'）在 slash 命令之前拦截 `!'
;; 行：它是本地动作，不依赖会话/服务器运行状态，也从不进入
;; session/prompt 或 commands/execute。执行目录是聊天 buffer 的
;; `default-directory'（会话工作区，见 `dsh-emacs--chat-buffer-sync'），
;; 与 magit 等命令的期望一致。结果以与 slash 命令行一致的工具行渲染
;; （bash 图标 + spinner + 状态着色，见 dsh-emacs-render.el 的
;; `dsh-emacs-render-shell-start' / `dsh-emacs-render-shell-done'）。
;;
;; 语义：`!' 必须紧跟一个非空命令（`! ls' 亦可）——裸 `!'、普通文本、
;; `/name' slash 行都不是 shell 行。
;;
;; 执行边界（聊天里没有可以交互的终端）：
;;   - 默认关闭命令的输入管道（`dsh-emacs-shell-null-stdin'）：
;;     cat 等等待 stdin 的命令得到 EOF；这不保证 TUI 退出，vim 仍可能
;;     持续运行。需要交互的程序应使用真实终端。
;;   - 新 `!' 命令会终止上一条仍被跟踪的 shell 主进程。主进程退出后
;;     存活的后台子进程不受此跟踪表管理，关闭 buffer 不保证清理它们。
;;   - 可选超时 `dsh-emacs-shell-timeout' 终止超时的被跟踪主进程；默认
;;     nil，不自动终止长时间运行的命令。
;;   - 结果行只在当前本地转录中，历史重载后消失，不会发给模型。

;;; Code:

(require 'dsh-emacs-render)

;; dsh-emacs.el 持有输入区状态与历史；本模块与 command/queue 一样通过
;; 声明式调用（加载顺序由 dsh-emacs.el 保证）。
(declare-function dsh-emacs--push-input-history "dsh-emacs" (text))
(declare-function dsh-emacs--clear-input "dsh-emacs" ())
(defvar dsh-emacs--input-history-pos)
(defvar dsh-emacs--input-history-pending)

(defgroup dsh-emacs-shell nil
  "Local `!command' shell commands."
  :group 'dsh-emacs)

(defcustom dsh-emacs-shell-require-confirm nil
  "Whether a `!<command>' line asks `y-or-n-p' before running.
The command only runs when the user confirms; declining leaves the
input untouched.  nil (default) runs immediately — the user typed the
command explicitly, the same trust model as `M-!' / `shell-command'."
  :type 'boolean
  :group 'dsh-emacs-shell)

(defcustom dsh-emacs-shell-max-output 50000
  "Maximum characters of a `!' command's captured output shown in the
transcript.  Longer outputs are truncated with a trailing marker so a
runaway `make' or `cat' cannot flood the chat buffer; the full output is
still only ever local (the command already ran on this machine)."
  :type 'integer
  :group 'dsh-emacs-shell)

(defcustom dsh-emacs-shell-null-stdin t
  "Whether `!' commands receive EOF on standard input immediately.
The chat has no terminal to feed a process, so a command that reads
stdin would otherwise block forever and the row stays running — with
this on, Emacs closes the input pipe after spawning the process (bare
`cat' exits at once), independently of the shell's syntax.  Programs
that require a tty still have no terminal.  nil leaves the pipe open
for callers to send input; the chat itself provides no terminal input."
  :type 'boolean
  :group 'dsh-emacs-shell)

(defcustom dsh-emacs-shell-timeout nil
  "Positive integer seconds a tracked shell may run before being killed, or nil.
When the limit is exceeded, its row restyles as failed with a `timed out'
note.  nil (default) means no automatic timeout; stop a long-running
command with `C-c C-!' or by submitting the next command.  Background
children that outlive the shell are no longer tracked by this timeout.
Zero, negative numbers, and non-integers are rejected before execution."
  :type '(choice (const :tag "No limit" nil)
                 (integer :tag "Positive seconds"
                          :match-alternatives
                          ((lambda (value) (and (integerp value) (> value 0))))
                          60))
  :group 'dsh-emacs-shell)

(defvar-local dsh-emacs--shell-procs nil
  "Running `!' commands of this chat buffer: list of (ID . PROCESS).
ID matches the transcript row key used by `dsh-emacs-render-shell-start'.
Entries are removed by the process sentinel when the command finishes and
killed wholesale when the buffer dies (`dsh-emacs-shell-mode-setup').
This tracks shell processes, not all of their descendant processes.")

;; ---------------------------------------------------------------------------
;; 解析
;; ---------------------------------------------------------------------------

(defun dsh-emacs-shell-parse (line)
  "Return the shell command of LINE when it is a `!command' line, else nil.
Admission: LINE must start with `!' (an optional space between `!' and
the command is tolerated) followed by a non-empty command — `!git status'
runs `git status', `!ls' runs `ls'.  Everything else (plain text,
`/name' slash lines, a bare `!') returns nil, and the caller treats the
line as an ordinary message.  Preserve the full command, including
embedded newlines in scripts and here-documents."
  (when (stringp line)
    (let ((trimmed (string-trim line)))
      (when (string-prefix-p "!" trimmed)
        (let ((command (string-trim-left (substring trimmed 1))))
          (and (not (string-empty-p command)) command))))))

;; ---------------------------------------------------------------------------
;; 提交与执行
;; ---------------------------------------------------------------------------

(defun dsh-emacs-shell--check-timeout ()
  "Reject invalid timeout settings before input or process state changes."
  (unless (or (null dsh-emacs-shell-timeout)
              (and (integerp dsh-emacs-shell-timeout)
                   (> dsh-emacs-shell-timeout 0)))
    (user-error "dsh-emacs-shell-timeout must be nil or a positive integer")))

(defun dsh-emacs-shell-submit (line command)
  "Run parsed COMMAND from LINE locally without touching the model.
COMMAND is the non-nil result of `dsh-emacs-shell-parse' for LINE.
Records the line in the input history and clears the input immediately
(the same web-style feel as slash commands), then starts the async run
whose outcome row renders above the input.  A still-running previous
`!' shell process is stopped first (at most one tracked shell per
buffer; its row restyles as failed).  With
`dsh-emacs-shell-require-confirm' the user is asked first; declining
leaves the input untouched."
  (unless command
    (error "Shell command must be non-nil"))
  (dsh-emacs-shell--check-timeout)
  (if (and dsh-emacs-shell-require-confirm
           (not (y-or-n-p (format "Run shell command: %s? " command))))
      (message "Shell command cancelled")
    (dsh-emacs--push-input-history line)
    (setq dsh-emacs--input-history-pos nil
          dsh-emacs--input-history-pending nil)
    (dsh-emacs--clear-input)
    (dsh-emacs-shell--kill-previous)
    (dsh-emacs-shell-run command (current-buffer))))

(defun dsh-emacs-shell--kill-previous ()
  "Kill every `!' command still running in this chat buffer.
Called when a new `!' command is submitted; each killed row restyles as
failed via its sentinel.  Children of exited shells are not tracked."
  (dolist (rec dsh-emacs--shell-procs)
    (when (process-live-p (cdr rec))
      (kill-process (cdr rec)))))

(defun dsh-emacs-shell-run (command &optional buffer)
  "Run COMMAND using `shell-file-name' with -c, rendering into BUFFER.
The executable follows the Emacs variable, which may differ from the
current SHELL environment variable.
BUFFER defaults to the current buffer; the command runs with that
buffer's `default-directory' (the session workspace).  A pending row
with the bash icon and a running spinner is rendered immediately
(`dsh-emacs-render-shell-start'); when the process finishes the row is
restyled with the merged stdout+stderr and the exit status
(`dsh-emacs-render-shell-done').  With `dsh-emacs-shell-null-stdin' the
command's input pipe is closed immediately (EOF — see that option);
with `dsh-emacs-shell-timeout' a run longer than that many
seconds is force-killed and marked timed out.  The process is tracked
in `dsh-emacs--shell-procs', so killing the chat buffer also kills it
while it remains tracked.  Background children may outlive the shell.
Returns the process.  A spawn failure is surfaced as a red row, not a
silent no-op; `\\[dsh-emacs-shell-process-kill]' interrupts a running
command (rendered as failed)."
  (let* ((buffer (or buffer (current-buffer)))
         (id (with-current-buffer buffer
               (dsh-emacs-shell--check-timeout)
               (dsh-emacs-render-shell-start command)))
         (proc nil))
    (with-current-buffer buffer
      (condition-case err
          (progn
            (setq proc
                  (make-process
                   :name (format "dsh-shell-%s" id)
                   :buffer (generate-new-buffer (format " *dsh-shell-%s*" id))
                   :connection-type 'pipe
                   :command (list shell-file-name "-c" command)
                   :noquery t
                   :sentinel (lambda (p _event)
                               (dsh-emacs-shell--on-exit p id buffer))))
            (when dsh-emacs-shell-timeout
              (process-put proc 'dsh-emacs-shell-timeout-secs
                           dsh-emacs-shell-timeout)
              (process-put proc 'dsh-emacs-shell-timer
                           (run-at-time
                            dsh-emacs-shell-timeout nil
                            #'dsh-emacs-shell--timeout-fire
                            proc)))
            (setq dsh-emacs--shell-procs
                  (cons (cons id proc) dsh-emacs--shell-procs))
            (when (and dsh-emacs-shell-null-stdin (process-live-p proc))
              (process-send-eof proc)))
        (quit
         (dsh-emacs-shell--spawn-failed buffer id "interrupted"))
        (error
         (dsh-emacs-shell--spawn-failed buffer id (error-message-string err)))))
    proc))

(defun dsh-emacs-shell--timeout-fire (proc)
  "Force-kill PROC when it outlived its timeout.
The sentinel then restyles the row as failed with a `timed out' note."
  (when (process-live-p proc)
    (process-put proc 'dsh-emacs-shell-timeout t)
    (kill-process proc)))

(defun dsh-emacs-shell--spawn-failed (buffer id detail)
  "Render a red result row for shell row ID in BUFFER after a spawn failure.
The optimistic row stays on screen (the user saw the command), but
turns into an error row carrying DETAIL instead of a result."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (dsh-emacs-render-shell-done
       id nil nil nil (format "failed to start: %s" detail)))))

(defun dsh-emacs-shell--on-exit (proc id buffer)
  "Finish shell command PROC (tracked as ID) and render its outcome.
Runs from the process sentinel: reads the merged stdout+stderr out of
the process buffer, classifies the run by exit status (signal death and
non-zero exit are failures), truncates to
`dsh-emacs-shell-max-output' and hands everything to
`dsh-emacs-render-shell-done'.  A run killed by
`dsh-emacs-shell-timeout' carries a leading `timed out' note.  Stopped
or running processes retain their resources.  Terminal processes release
resources even when BUFFER is dead; only rendering needs a live chat."
  (when (memq (process-status proc) '(exit signal))
    (when-let* ((timer (process-get proc 'dsh-emacs-shell-timer)))
      (cancel-timer timer))
    (let* ((out-buffer (process-buffer proc))
           (output (and (buffer-live-p buffer)
                        (buffer-live-p out-buffer)
                        (with-current-buffer out-buffer (buffer-string))))
           (status (process-status proc))
           (exit (and (eq status 'exit) (process-exit-status proc)))
           (signal (and (eq status 'signal) (process-exit-status proc)))
           (ok (and (integerp exit) (= exit 0)))
           (timeout-secs (process-get proc 'dsh-emacs-shell-timeout-secs))
           (timed-out (and (process-get proc 'dsh-emacs-shell-timeout)
                           timeout-secs)))
      (when (buffer-live-p out-buffer)
        (kill-buffer out-buffer))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (setq dsh-emacs--shell-procs
                (delq (assoc id dsh-emacs--shell-procs)
                      dsh-emacs--shell-procs))
          (dsh-emacs-render-shell-done
           id ok exit signal
           (dsh-emacs-shell--truncate-output
            (if timed-out
                (concat (format "⏸ timed out after %s seconds — killed"
                                timeout-secs)
                        (and (not (string-empty-p (or output "")))
                             (concat "\n\n" output)))
              output))))))))

(defun dsh-emacs-shell--truncate-output (output)
  "Return OUTPUT capped at `dsh-emacs-shell-max-output' characters.
Trailing whitespace is trimmed; oversized output gets a trailing note.
nil output stays nil (no body)."
  (when (stringp output)
    (let ((trimmed (string-trim-right output)))
      (if (and (integerp dsh-emacs-shell-max-output)
               (> dsh-emacs-shell-max-output 0)
               (> (length trimmed) dsh-emacs-shell-max-output))
          (concat (substring trimmed 0 dsh-emacs-shell-max-output)
                  (format "\n… output truncated at %d characters"
                          dsh-emacs-shell-max-output))
        trimmed))))

;; ---------------------------------------------------------------------------
;; 中断与清理
;; ---------------------------------------------------------------------------

(defun dsh-emacs-shell-process-kill ()
  "Kill the current chat buffer's running `!' command(s).
The newest one is killed (`kill-process'); the transcript row restyles
as failed.  Reports when nothing is running."
  (interactive)
  (if (null dsh-emacs--shell-procs)
      (message "No running shell command in this buffer")
    (let* ((rec (car dsh-emacs--shell-procs))
           (proc (cdr rec)))
      (when (process-live-p proc)
        (kill-process proc))
      (message "Shell command interrupted"))))

(defun dsh-emacs-shell-mode-setup ()
  "Install per-chat-buffer `!' cleanup.
Called from `dsh-emacs-mode' when a chat buffer opens (mirroring
`dsh-emacs-command-auto-trigger-setup'): killing the buffer or resetting
its major mode also kills each tracked shell process before its
buffer-local tracking is discarded."
  (add-hook 'kill-buffer-hook #'dsh-emacs-shell--kill-buffer-procs nil t)
  (add-hook 'change-major-mode-hook #'dsh-emacs-shell--kill-buffer-procs nil t))

(defun dsh-emacs-shell--kill-buffer-procs ()
  "Kill every `!' process still tracking in this buffer."
  (dolist (rec dsh-emacs--shell-procs)
    (when (process-live-p (cdr rec))
      (delete-process (cdr rec))))
  (setq dsh-emacs--shell-procs nil))

(provide 'dsh-emacs-shell)

;;; dsh-emacs-shell.el ends here
