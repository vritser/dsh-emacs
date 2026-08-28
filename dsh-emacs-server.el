;;; dsh-emacs-server.el --- dsh server bootstrap (probe / start / install) -*- lexical-binding: t; -*-

;; Copyright (C) 2025 vritser

;; Author: vritser
;; Version: 0.1.0
;; License: GPL-3.0-or-later
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; 开箱即用：调用任何需要服务的 dsh-emacs-* 命令前，保证 dsh server 就绪。
;; 流程（见 `dsh-emacs-server-ensure'）：
;;   1. 探测 `dsh-emacs-base-url' 是否已响应（一次廉价 HTTP GET /）；
;;   2. 未响应且服务器由本包托管（`dsh-emacs-server-auto-start'）时，先定位
;;      `dsh' CLI —— 缺失则询问是否用 `npm install -g @deepseek-ai/dsh'
;;      安装；
;;   3. 以 `dsh web --host H --port P --no-open' 后台拉起并等待就绪。
;;
;; 公开 API：
;;
;;   (dsh-emacs-server-ensure)   ;; 命令入口守卫：探测 / 安装 / 启动 / 等待
;;   (dsh-emacs-server-start)    ;; 启动托管 server（已就绪则跳过）
;;   (dsh-emacs-server-stop)     ;; 停止本包拉起的 server 进程
;;   (dsh-emacs-server-restart)  ;; 重启托管 server
;;   (dsh-emacs-open-web)        ;; 在浏览器打开 dsh web（provider 配置在官方 UI）
;;   (dsh-emacs--server-alive-p) ;; 服务器是否就绪（带短缓存）
;;
;; batch（--batch，单测）下 `dsh-emacs-server-ensure' 恒为 no-op：mock RPC
;; 的单元测试不需要真实服务，也不会在网络/进程上被拦截。

;;; Code:

(require 'cl-lib)
(require 'url-parse)
(require 'dsh-emacs-ui)

(defgroup dsh-emacs-server nil
  "dsh server bootstrap: probe, auto-start, and on-demand install."
  :group 'dsh-emacs
  :prefix "dsh-emacs-server-")

(defcustom dsh-emacs-server-auto-start t
  "Whether server-touching commands auto-start the dsh server.
When non-nil, `dsh-emacs-server-ensure' first probes `dsh-emacs-base-url';
if nothing answers it locates the `dsh' CLI (asking to install it when
missing — see `dsh-emacs-server-install-command') and spawns
`dsh web --no-open' in the background, waiting until the server answers.
Set to nil to manage the server yourself: commands then fail with
instructions instead of starting anything."
  :type 'boolean
  :group 'dsh-emacs-server)

(defcustom dsh-emacs-server-start-on-init nil
  "Whether to start the dsh server eagerly at Emacs startup.
When non-nil the server is launched in the background shortly after
`dsh-emacs-mode' is first activated, so by the time the user opens a
session the server is likely already running.  When nil (the default)
the server is started lazily on the first command that needs it."
  :type 'boolean
  :group 'dsh-emacs-server)

(defcustom dsh-emacs-server-wait-seconds 30
  "How long `dsh-emacs-server-ensure' waits for a freshly started server.
The first boot of `dsh web' loads the whole plugin tree and can take
several seconds; this is the grace period before \"did not become ready\".
Only applies to servers this package starts itself."
  :type 'integer
  :group 'dsh-emacs-server)

(defcustom dsh-emacs-server-install-command
  '("npm" "install" "-g" "@deepseek-ai/dsh")
  "Command (program + args) used to install the dsh CLI on demand.
Run when the `dsh' executable is missing and the user accepts the install
prompt.  Adapt the program to your package manager if npm is not how you
install dsh."
  :type '(repeat string)
  :group 'dsh-emacs-server)

;;; ---------------------------------------------------------------------------
;;; 内部状态
;;; ---------------------------------------------------------------------------

(defvar dsh-emacs--server-process nil
  "Process object of the dsh server this package started (or nil).
Only set when *this* package spawned the server, so
`dsh-emacs-server-stop' never kills a server the user runs themselves.")

(defvar dsh-emacs--server-alive-check nil
  "Cons (ALIVE . TIMESTAMP) caching the last liveness probe result.
The probe is a raw loopback round-trip (~1ms); the cache keeps repeated
commands (and command chains like list → workspace-list) from re-probing
on every single invocation.")

(defconst dsh-emacs--server-alive-ttl 2.0
  "Seconds a cached liveness result stays valid.")

(defconst dsh-emacs-server-default-base-url "http://127.0.0.1:3080"
  "Fallback server address when `dsh-emacs-base-url' is not yet loaded.
`dsh-emacs-base-url' is defined in dsh-emacs.el (the package entry), which
always loads this module first at package load; the fallback only matters
for standalone use of this module.")

;;; ---------------------------------------------------------------------------
;;; URL / 探测
;;; ---------------------------------------------------------------------------

(defun dsh-emacs--server-base-url ()
  "The server URL to probe and start: `dsh-emacs-base-url' or the default."
  (if (boundp 'dsh-emacs-base-url)
      dsh-emacs-base-url
    dsh-emacs-server-default-base-url))

(defun dsh-emacs--server-host-port ()
  "Return the (HOST . PORT) pair the base URL points at.
Used both to probe the server and to hand `dsh web' its --host/--port."
  (let ((parsed (url-generic-parse-url (dsh-emacs--server-base-url))))
    (cons (or (url-host parsed) "127.0.0.1")
          (or (url-port parsed) 80))))

(defun dsh-emacs--server-probe ()
  "Probe `dsh-emacs-base-url' directly (no cache).
A raw TCP connection — no `url-retrieve' machinery, so it works headless
and is as cheap as the loopback round-trip it is.  Sends `GET /' and
accepts output until the status line arrives or 2s elapse; returns
non-nil only for an HTTP 200.  Connection refused (nothing listening)
fails instantly with nil.  Errors are CONTAINED: an unparseable URL,
resolution failure, or a wedged socket all read as \"not alive\"."
  (ignore-errors
    (let* ((host-port (dsh-emacs--server-host-port))
           (host (car host-port))
           (port (cdr host-port))
           (buf (generate-new-buffer " *dsh-server-probe*"))
           (result nil))
      (unwind-protect
          (let ((proc (open-network-stream "dsh-server-probe" buf
                                           host port :type 'plain)))
            (set-process-query-on-exit-flag proc nil)
            (set-process-filter
             proc (lambda (_proc string)
                    (with-current-buffer buf
                      (goto-char (point-max))
                      (insert string))))
            (process-send-string
             proc (format "GET / HTTP/1.0\r\nHost: %s:%d\r\n\r\n"
                          host port))
            (let ((deadline (+ (float-time) 2.0)))
              (while (and (process-live-p proc)
                          (with-current-buffer buf
                            (not (string-match-p "\r?\n" (buffer-string))))
                          (< (float-time) deadline))
                (accept-process-output proc 0.2)))
            (when (process-live-p proc)
              (delete-process proc))
            (with-current-buffer buf
              (when (string-match "^HTTP/1\\.[01] \\([0-9]+\\)"
                                  (buffer-string))
                (setq result (equal (match-string 1 (buffer-string))
                                    "200")))))
        (kill-buffer buf))
      result)))

(defun dsh-emacs--server-alive-p ()
  "Return non-nil when the dsh server answers at the base URL.
Cached for `dsh-emacs--server-alive-ttl' seconds, so repeated guard calls
in one command chain do not re-probe."
  (let ((now (float-time)))
    (if (and dsh-emacs--server-alive-check
             (<= (- now (cdr dsh-emacs--server-alive-check))
                 dsh-emacs--server-alive-ttl))
        (car dsh-emacs--server-alive-check)
      (let ((alive (dsh-emacs--server-probe)))
        (setq dsh-emacs--server-alive-check (cons alive now))
        alive))))

(defun dsh-emacs--server-invalidate-alive ()
  "Drop the cached liveness result (after a start/stop/restart)."
  (setq dsh-emacs--server-alive-check nil))

;;; ---------------------------------------------------------------------------
;;; CLI 检测与安装
;;; ---------------------------------------------------------------------------

(defun dsh-emacs--server-bin ()
  "Path of the `dsh' executable, or nil when not installed."
  (executable-find "dsh"))

(defun dsh-emacs--server-ensure-installed ()
  "Ask to install the dsh CLI when it is missing; return its path.
Declining signals `user-error' with manual-install instructions.  Accepting
runs `dsh-emacs-server-install-command' (interruptible by C-g) and re-checks
the executable; still missing after a successful install is also an error,
pointing at the install buffer."
  (or (dsh-emacs--server-bin)
      (if (y-or-n-p (format "The dsh CLI is not installed.  Install it now (%s)? "
                            (mapconcat #'identity
                                       dsh-emacs-server-install-command " ")))
          (or (dsh-emacs--server-run-install)
              (user-error "Install finished but `dsh' still not on `exec-path'; check `*dsh-install*' for errors"))
        (user-error "dsh not installed.  Install it manually (%s) and retry"
                    (mapconcat #'identity
                               dsh-emacs-server-install-command " ")))))

(defun dsh-emacs--server-run-install ()
  "Run `dsh-emacs-server-install-command', waiting for it to finish.
The install output lands in `*dsh-install*'.  Returns the newly found
`dsh' path, or nil when the executable is still missing after completion.
Interruptible by C-g (`sleep-for' polling)."
  (let ((program (car dsh-emacs-server-install-command)))
    (unless (executable-find program)
      (user-error "`%s' not found in `exec-path'; install a Node.js toolchain or adjust `dsh-emacs-server-install-command'"
                  program))
    (message "Installing dsh: %s ..."
             (mapconcat #'identity dsh-emacs-server-install-command " "))
    (let* ((buf (get-buffer-create "*dsh-install*"))
           (proc (make-process :name "dsh-install" :buffer buf :noquery t
                               :command dsh-emacs-server-install-command)))
      (while (process-live-p proc)
        (accept-process-output proc 0)   ; drain output, never block
        (sleep-for 0.3))
      (dsh-emacs--server-bin))))

;;; ---------------------------------------------------------------------------
;;; 启动 / 停止 / 等待
;;; ---------------------------------------------------------------------------

(defun dsh-emacs--server-launch (bin host port)
  "Spawn the managed dsh server process: BIN web --host HOST --port PORT.
Returns the process (killing any previous managed one).  The server's
output goes to `*dsh-server*', kept for diagnosis; a non-query process so
Emacs exit never prompts about it."
  (with-current-buffer (get-buffer-create "*dsh-server*")
    (erase-buffer))
  (when (process-live-p dsh-emacs--server-process)
    (delete-process dsh-emacs--server-process))
  (setq dsh-emacs--server-process
        (make-process
         :name "dsh-server"
         :buffer (get-buffer-create "*dsh-server*")
         :noquery t
         :command (list bin "web" "--host" host
                        "--port" (number-to-string port)
                        "--no-open")
         :sentinel (lambda (proc _event)
                     (when (memq (process-status proc) '(exit signal))
                       (when (eq proc dsh-emacs--server-process)
                         (setq dsh-emacs--server-process nil))))))
  (set-process-query-on-exit-flag dsh-emacs--server-process nil)
  (dsh-emacs--server-invalidate-alive)
  dsh-emacs--server-process)

(defun dsh-emacs--server-wait-ready ()
  "Wait up to `dsh-emacs-server-wait-seconds' for the server to answer.
Reports progress every second.  Returns t when a probe succeeds; fails
fast when the spawned process already exited; otherwise signals
`user-error' after the timeout, pointing at `*dsh-server*'."
  (let ((start (float-time))
        (deadline (+ (float-time) dsh-emacs-server-wait-seconds))
        (last-report -1))
    (while (and (not (dsh-emacs--server-alive-p))
                (or (null dsh-emacs--server-process)
                    (process-live-p dsh-emacs--server-process))
                (< (float-time) deadline))
      (let ((waited (- (float-time) start)))
        (when (>= waited (1+ last-report))
          (setq last-report (floor waited))
          (message "Waiting for dsh server... %ds/%ds"
                   last-report dsh-emacs-server-wait-seconds)))
      (sleep-for 0.1))
    (cond
     ((dsh-emacs--server-alive-p)
      (message "dsh server ready at %s" (dsh-emacs--server-base-url))
      t)
     ((and dsh-emacs--server-process
           (not (process-live-p dsh-emacs--server-process)))
      (user-error "dsh server exited before becoming ready; see `*dsh-server*'"))
     (t
      (user-error "dsh server did not become ready within %ds; see `*dsh-server*'"
                  dsh-emacs-server-wait-seconds)))))

;;; ---------------------------------------------------------------------------
;;; 公开命令
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-server-start (&optional wait)
  "Start the dsh server as a managed background process.
Spawns `dsh web --host H --port P --no-open' (H/P from
`dsh-emacs-base-url').  A server already reachable is left alone.
When WAIT is non-nil (or called from Lisp), block until the server
answers; interactively launch and return immediately so the UI stays
responsive."
  (interactive (list nil))
  (cond
   ((dsh-emacs--server-alive-p)
    (message "dsh server already running at %s" (dsh-emacs--server-base-url))
    t)
   ((and dsh-emacs--server-process
         (process-live-p dsh-emacs--server-process))
    (if wait
        (dsh-emacs--server-wait-ready)
      (message "dsh server already starting at %s" (dsh-emacs--server-base-url))
      nil))
   (t
    (let* ((bin (or (dsh-emacs--server-bin)
                    (dsh-emacs--server-ensure-installed)))
           (host-port (dsh-emacs--server-host-port)))
      (dsh-emacs--server-launch bin (car host-port) (cdr host-port))
      (if wait
          (progn
            (message "Starting dsh server: %s web --host %s --port %d --no-open"
                     bin (car host-port) (cdr host-port))
            (dsh-emacs--server-wait-ready))
        (message "Starting dsh server in background: %s web --host %s --port %d --no-open"
                 bin (car host-port) (cdr host-port))
        nil)))))

(defun dsh-emacs-server-stop ()
  "Stop the dsh server process this package started (if any).
Servers started outside dsh-emacs (e.g. `dsh web' in a terminal) are not
touched."
  (interactive)
  (when (process-live-p dsh-emacs--server-process)
    (delete-process dsh-emacs--server-process)
    (setq dsh-emacs--server-process nil)
    (dsh-emacs--server-invalidate-alive)
    (message "dsh server stopped")
    t))

(defun dsh-emacs-server-restart ()
  "Restart the managed dsh server process."
  (interactive)
  (dsh-emacs-server-stop)
  (dsh-emacs-server-start))

;;;###autoload
(defun dsh-emacs-open-web ()
  "Open the dsh web UI in the default browser.
Provider/model configuration lives in dsh itself — the web UI (Settings
opens as a modal there) or `~/.dsh/settings.yaml' plus
`.credentials.yaml' (this package has no provider-editing surface and
reads the catalog via `session.models').  This command is the bridge:
changes made in the browser show up in dsh-emacs after a refresh (`g' in
the session list, `C-c C-r' in a chat buffer)."
  (interactive)
  (dsh-emacs-server-ensure)
  (let ((url (dsh-emacs--server-base-url)))
    (browse-url url)
    (message "Opened %s" url)))

(defun dsh-emacs-server-ensure ()
  "Ensure the dsh server is reachable before a server-touching command.
With `dsh-emacs-server-auto-start' non-nil and no server answering at
`dsh-emacs-base-url', the `dsh' CLI is located (asking to install it when
missing) and the server is launched, waiting until it answers.  With
auto-start nil this fails with startup instructions instead.  No-op in
batch (`noninteractive') runs, so the mocked-RPC unit suite needs no
service."
  (interactive)
  (when (not noninteractive)
    (unless (dsh-emacs--server-alive-p)
      (if dsh-emacs-server-auto-start
          (dsh-emacs-server-start t)
        (user-error "dsh server not reachable at %s.  Start it with M-x dsh-emacs-server-start (or `dsh web --no-open'), or set `dsh-emacs-server-auto-start' to t"
                    (dsh-emacs--server-base-url))))))

;;; ---------------------------------------------------------------------------
;;; Emacs 退出清理
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-server--teardown ()
  "Stop the managed server process when Emacs exits."
  (when (process-live-p dsh-emacs--server-process)
    (delete-process dsh-emacs--server-process)))

(add-hook 'kill-emacs-hook #'dsh-emacs-server--teardown)

(defun dsh-emacs-server--maybe-start-on-init ()
  "Fire-and-forget: launch the dsh server in the background after init.
Only runs when `dsh-emacs-server-start-on-init' is non-nil.  The server
process is spawned without waiting — the first `dsh-emacs-server-ensure'
call will block until it is ready, so the user never sees a freeze at
startup."
  (when (and dsh-emacs-server-start-on-init
             (not noninteractive)
             (not (dsh-emacs--server-alive-p))
             (not dsh-emacs--server-process))
    (run-at-time 1 nil
      (lambda ()
        (condition-case nil
            (when (and (not (dsh-emacs--server-alive-p))
                       (not dsh-emacs--server-process))
              (when-let* ((bin (or (dsh-emacs--server-bin)
                                   (dsh-emacs--server-ensure-installed)))
                          (host-port (dsh-emacs--server-host-port)))
                (dsh-emacs--server-launch bin (car host-port) (cdr host-port))))
          (error nil))))))

(add-hook 'after-init-hook #'dsh-emacs-server--maybe-start-on-init)

(provide 'dsh-emacs-server)

;;; dsh-emacs-server.el ends here