;;; dsh-emacs-server.el --- dsh server bootstrap (probe / start / install) -*- lexical-binding: t; -*-

;; Copyright (C) 2025 vritser

;; Author: vritser
;; Version: 0.2.0
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

(declare-function url-retrieve-synchronously "url"
                  (url &optional silent inhibit-cookies timeout))

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

(defcustom dsh-emacs-server-auth-token nil
  "dsh web process launch token, when the server needs authentication.

Recent dsh web servers (0.1.2-rc.1 and later) authenticate every Host API
call and WebSocket stream with a per-process \"launch token\": they print
`dsh web: http://HOST:PORT/?token=TOKEN' at startup, and a request to
`/?token=TOKEN' mints a signed browser cookie that all later calls must
carry.  dsh-emacs performs that exchange itself.

This should normally stay nil: for a server dsh-emacs starts itself the
token is captured automatically from the `*dsh-server*' output.  Set it to
the TOKEN (the `token=' value from the printed URL) only when pointing at a
server dsh-emacs did not start, so its own token is not available to
parse.  When nil and dsh-emacs points at an already-running external server
that requires the cookie, it asks you for the token interactively
rather than showing a Basic username/password prompt.  The token changes on
every server restart, so a manually-maintained value goes stale whenever the
server is restarted."
  :type '(choice (const :tag "None (auto-capture from managed server)" nil)
                 (string :tag "Launch token (token= value from `dsh web:' output)"))
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

(defvar dsh-emacs--server-auth-cookie nil
  "Minted browser-session cookie value (\"name=value\") for the current base URL.
Set by `dsh-emacs--server-auth-ensure'; nil means no cookie has been minted
(no launch token known, or an older server that needs none).  Cleared when
the base URL or the launch token changes, so a stale cookie is never sent.")

(defvar dsh-emacs--server-auth-captured-token nil
  "Launch token parsed from the `*dsh-server*' output, or nil.
Used when `dsh-emacs-server-auth-token' is nil and this package started the
server.  Reset whenever a fresh server is spawned.")

;;; ---------------------------------------------------------------------------
;;; URL / 探测
;;; ---------------------------------------------------------------------------

(defun dsh-emacs--server-base-url-raw ()
  "The configured server URL exactly as set by the user: `dsh-emacs-base-url'
(or the default).  This is the only accessor that may carry a `?token=' query
(the URL dsh web prints); use `dsh-emacs--server-base-url' for anything that
actually builds a request URL."
  (if (boundp 'dsh-emacs-base-url)
      dsh-emacs-base-url
    dsh-emacs-server-default-base-url))

(defun dsh-emacs--server-base-url ()
  "The server URL to probe and start: `dsh-emacs-base-url' or the default.
A leading `?token=…' query — the form dsh web prints at startup — and any
trailing slash before it are stripped, so callers can safely concatenate
paths onto the result (`/api/…', `/').  The token itself is read separately
via `dsh-emacs--server-auth-token-from-url'."
  (let* ((raw (dsh-emacs--server-base-url-raw))
         (at (and (stringp raw) (string-match-p "\\?" raw)))
         (base (if at (substring raw 0 at) raw)))
    (if (and (> (length base) 0) (string-match-p "/$" base))
        (substring base 0 -1)
      base)))

(defun dsh-emacs--server-host-port ()
  "Return the (HOST . PORT) pair the base URL points at.
Used both to probe the server and to hand `dsh web' its --host/--port.
HOST keeps any IPv6 brackets from the URL (\"[::1]\"), which is what an
HTTP Host header needs."
  (let ((parsed (url-generic-parse-url (dsh-emacs--server-base-url))))
    (cons (or (url-host parsed) "127.0.0.1")
          (or (url-port parsed) 80))))

(defun dsh-emacs--server-host-name ()
  "Return the base URL's host without IPv6 brackets (\"::1\" for \"[::1]\").
For sockets (`open-network-stream') and host comparisons: the bracket form
is valid only inside URLs / Host headers, not as an address to resolve."
  (let ((host (car (dsh-emacs--server-host-port))))
    (if (and (> (length host) 2)
             (eq (aref host 0) ?\[)
             (eq (aref host (1- (length host))) ?\]))
        (substring host 1 -1)
      host)))

(defun dsh-emacs-server--basic-auth-header ()
  "Return (\"Authorization\" . \"Basic ...\") when the base URL carries
userinfo (http://user:pass@host...), or nil.  Shared by the raw-TCP probe,
the WebSocket handshake, and any hand-built request.  The `url' library
(RPC path) derives the same header from the URL itself, so this exists
only for the non-url code paths."
  (let* ((parsed (url-generic-parse-url (dsh-emacs--server-base-url)))
         (user (url-user parsed))
         (pass (url-password parsed)))
    (when (and user (not (string-empty-p user)))
      (cons "Authorization"
            (concat "Basic "
                    (base64-encode-string
                     (encode-coding-string (concat user ":" (or pass "")) 'utf-8)
                     t))))))

(defun dsh-emacs--server-probe ()
  "Probe `dsh-emacs-base-url' directly (no cache).
Two paths: plain HTTP uses a raw TCP connection (cheap, headless-friendly,
sets a Basic Authorization header when the URL carries userinfo); HTTPS
goes through the `url' library, which is the only way to speak TLS here.
Returns non-nil for HTTP 200 or 401 — 401 means the server IS there, it
just demands authentication, so it counts as alive.  Connection refused
(nothing listening) fails instantly with nil.  Errors are CONTAINED: an
unparseable URL, resolution failure, or a wedged socket all read as
\"not alive\"."
  (ignore-errors
    (if (equal (url-type (url-generic-parse-url (dsh-emacs--server-base-url)))
               "https")
        (dsh-emacs--server-probe-https)
      (dsh-emacs--server-probe-plain))))

(defun dsh-emacs--server-probe-https ()
  "Probe an `https' base URL via `url-retrieve' (TLS path).
Bounded to a 5s wait: a peer that accepts TCP but never completes the
TLS handshake (firewall/proxy wedge) must not hang the probe.  A nil
return — timeout or `url-retrieve' refusing — reads as \"not alive\"
and must not touch the caller's current buffer (`kill-buffer' on nil
would delete it), hence the `when buf' guard."
  (let ((buf (url-retrieve-synchronously
              (concat (dsh-emacs--server-base-url) "/") t nil 5)))
    (when buf
      (unwind-protect
          (with-current-buffer buf
            (goto-char (point-min))
            (when (re-search-forward "^HTTP/[0-9.]+ \\([0-9]+\\)" nil t)
              (let ((code (match-string 1)))
                (or (equal code "200") (equal code "401")))))
        (kill-buffer buf)))))

(defun dsh-emacs--server-probe-plain ()
  "Probe a plain-http base URL with a raw TCP `GET /' (no URL machinery)."
  (let* ((host-port (dsh-emacs--server-host-port))
         (host (dsh-emacs--server-host-name))
         ;; Host header needs the bracket form for IPv6 ("[::1]:3080"),
         ;; the socket address must not have them ("::1").
         (host-header (car host-port))
         (port (cdr host-port))
         (auth (dsh-emacs-server--basic-auth-header))
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
           proc (concat (format "GET / HTTP/1.0\r\nHost: %s:%d\r\n"
                                host-header port)
                        (if auth
                            (format "%s: %s\r\n" (car auth) (cdr auth))
                          "")
                        "\r\n"))
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
              (let ((code (match-string 1 (buffer-string))))
                (setq result (or (equal code "200")
                                 (equal code "401")))))))
      (kill-buffer buf))
    result))

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
;;; 浏览器会话认证（launch token → dsh-auth-* cookie）
;;; ---------------------------------------------------------------------------
;;
;; Recent dsh web (0.1.2-rc.1+) authenticates the whole Host API: RPC, exact
;; Fetch routes, and every WebSocket upgrade return 401 unless the request
;; carries an authority-bound, HMAC-signed cookie named `dsh-auth-<hash>'.
;; The cookie is minted once by requesting `/?token=<launch-token>' (the CLI
;; prints the token inside the URL `dsh web: .../?token=...').  This module
;; owns that exchange and hands the resulting cookie to the RPC layer
;; (`dsh-emacs--rpc-request' / `dsh-emacs--rpc-async') and the event streams
;; (`dsh-emacs-events.el') via `dsh-emacs--server-auth-cookie-header'.

(defun dsh-emacs--server-auth-capture-token ()
  "Scan the managed `*dsh-server*' buffer for a `dsh web: ...?token=' line.
When found, store the token in `dsh-emacs--server-auth-captured-token',
reset any minted cookie (a fresh server means a fresh token), and return the
token.  Returns nil if the line has not appeared yet — for a just-launched
server the URL is printed once the plugin tree settles, which can follow the
first successful probe."
  (let ((buf (get-buffer "*dsh-server*")))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (goto-char (point-min))
        (when (re-search-forward "\\(?:\\?\\|&\\)token=\\([A-Za-z0-9_-]+\\)" nil t)
          (let ((token (match-string 1)))
            (unless (equal token dsh-emacs--server-auth-captured-token)
              (setq dsh-emacs--server-auth-captured-token token)
              (dsh-emacs--server-auth-reset))
            token))))))

(defun dsh-emacs--server-auth-token ()
  "Return the current launch token, or nil when none is known.
Resolution order: a token just parsed from the managed `*dsh-server*' output
(the capture is exact for the live process and therefore never goes stale),
a previously captured token retained in the buffer variable, then the
user-facing `dsh-emacs-server-auth-token'."
  (or (dsh-emacs--server-auth-capture-token)
      dsh-emacs--server-auth-captured-token
      (when (and dsh-emacs-server-auth-token
                 (not (string-empty-p dsh-emacs-server-auth-token)))
        dsh-emacs-server-auth-token)))

(defun dsh-emacs--server-auth-reset ()
  "Drop any minted cookie after the base URL or token changed.
Safe to call whenever the server address or identity may have changed; the
next authenticated call re-mints from the fresh token."
  (setq dsh-emacs--server-auth-cookie nil))

(defun dsh-emacs--server-auth-maybe-expire ()
  "Drop a stale cookie after an HTTP 401.
An out-of-band (user-managed) `dsh web' mints a NEW per-process token on
every restart, which invalidates the cookie this client cached from the
previous process — but nothing tells the client the token changed, so it
keeps sending the dead cookie and every RPC 401s until Emacs restarts.
Call this when a request that carried our cookie came back HTTP 401: clear
the cookie (so the next authenticated call re-mints from a fresh capture
or configured token, or the next interactive command prompts again).
Re-minting from a still-stale
configured token simply 401s again, which is the correct, non-silent
outcome (the hint points the user at the config)."
  (when dsh-emacs--server-auth-cookie
    (setq dsh-emacs--server-auth-cookie nil)))

(defun dsh-emacs--server-auth-http-401-p (err)
  "Non-nil when ERR is the `url' HTTP 401 error (`(error http 401)')."
  (and (listp err) (numberp (nth 2 err)) (equal (nth 2 err) 401)))

(defun dsh-emacs--server-auth-token-from-url (url)
  "Return the `token' query value in URL, or nil.
Lets a user point `dsh-emacs-base-url' at the exact URL dsh printed
(`http://.../?token=...') without a separate `dsh-emacs-server-auth-token'."
  (ignore-errors
    (let* ((parsed (url-generic-parse-url url))
           (query (cdr (url-path-and-query parsed)))
           (value (and query
                       (cdr (assoc "token" (url-parse-query-string query))))))
      (cond
       ((stringp value) value)
       ((and (consp value) (stringp (car value))) (car value))
       (t nil)))))

(defun dsh-emacs--server-auth-cookie-header ()
  "Return (\"Cookie\" . \"dsh-auth-*=*\") for the current base URL, or nil.
Mints the cookie on demand from the launch token, caching the result in
`dsh-emacs--server-auth-cookie'.  Nil when no token is known or the server
declined the exchange: the caller then sends no cookie (an older server
needs none).  Callers must ensure the server is alive before first use so a
token captured at launch is already available."
  (let ((cookie (if dsh-emacs--server-auth-cookie
                    dsh-emacs--server-auth-cookie
                  (let ((token (or (dsh-emacs--server-auth-token)
                                   (dsh-emacs--server-auth-token-from-url
                                    (dsh-emacs--server-base-url-raw)))))
                    (when token
                      (dsh-emacs--server-auth-ensure token)))
                  dsh-emacs--server-auth-cookie)))
    (dsh-emacs--server-auth-cookie-as-unibyte cookie)))

(defun dsh-emacs--server-auth-cookie-as-unibyte (cookie)
  "Return COOKIE as a unibyte byte string, or nil.
The cookie is captured with `match-string' from a network response buffer,
so even pure-ASCII content arrives flagged multibyte.  Emacs' `url' rejects a
request whose concatenated header+body is multibyte (Bug#23750: it errors
\"Multibyte text in HTTP request\" when `string-bytes' != `length'), and a
multibyte-flagged header concatenated with the unibyte-encoded request body
trips exactly that check.  Normalize to a true unibyte byte string (the cookie
is a `dsh-auth-<name>=v1.<body>.<sig>' ASCII token), so the RPC header and the
WS handshake both stay single-byte regardless of the body's non-ASCII payload."
  (when cookie
    (if (multibyte-string-p cookie)
        (encode-coding-string cookie 'utf-8)
      cookie)))

(defun dsh-emacs--server-auth-ensure (&optional token)
  "Mint the browser-session cookie for the current base URL.
Scans the managed `*dsh-server*' buffer for the `token=' launch value when
TOKEN is nil.  Exchanges `/<base>/?token=TOKEN' with the server and, when it
mints a `dsh-auth-*' cookie, stores it in `dsh-emacs--server-auth-cookie' and
returns it.  Returns nil otherwise — an older server that needs no cookie,
or no token known.  Best-effort by design: a real authentication failure
surfaces on the caller's own request as HTTP 401, which dsh-emacs reports
with actionable instructions rather than failing the mint synchronously."
  (let* ((token (or token
                    (dsh-emacs--server-auth-token)
                    (dsh-emacs--server-auth-token-from-url
                     (dsh-emacs--server-base-url-raw))))
         (base (dsh-emacs--server-base-url)))
    (setq dsh-emacs--server-auth-cookie nil)
    (when token
      (let ((cookie (dsh-emacs--server-auth-exchange base token)))
        (when cookie
          (setq dsh-emacs--server-auth-cookie cookie)
          cookie)))))

(defun dsh-emacs--server-auth-exchange (base token)
  "Exchange TOKEN for the `dsh-auth-*' cookie against BASE.
BASE is the clean server origin (no query).  dsh's successful exchange is an
HTTP 303 carrying the `Set-Cookie' header; the cookie MUST be read off that
first 303.  `url-retrieve' would follow the 303 to `/' and return that
follow-on response (a 401 when unauthenticated), dropping the header — hence
a plain-http BASE is exchanged over a raw TCP socket (no redirect handling,
see `dsh-emacs--server-auth-exchange-plain'), and an https BASE through the
`url' library with redirects disabled (`url-max-redirections' bound to 0).
Returns the cookie string, else nil."
  (let ((url (concat base "/?token=" token)))
    (if (equal (url-type (url-generic-parse-url base)) "https")
        ;; HTTPS: TLS requires the url library; disable 303 redirect-follow so
        ;; the response buffer is dsh's 303 (where the Set-Cookie lives).
        (let ((url-max-redirections 0))
          (with-current-buffer (url-retrieve-synchronously url t t 5)
            (goto-char (point-min))
            (when (re-search-forward "^Set-Cookie: \\([_A-Za-z0-9-]+=[^;\r\n]+\\)" nil t)
              (match-string 1))))
      (dsh-emacs--server-auth-exchange-plain url))))

(defun dsh-emacs--server-auth-exchange-plain (url)
  "Send raw `GET URL' to the base host and return its `Set-Cookie' value.
Reuses the socket probe's pattern (`dsh-emacs--server-probe-plain'): hand-write
the request, read the first response headers, and take the `Set-Cookie' line.
Deliberately does NOT follow location redirects — dsh's token exchange answers
with a 303 whose header is the only place the minted cookie appears."
  (let* ((parsed (url-generic-parse-url url))
         (pq (url-path-and-query parsed))
         (req-path (concat (or (car pq) "/")
                           (and (cdr pq) (concat "?" (cdr pq)))))
         (host-port (dsh-emacs--server-host-port))
         (host (dsh-emacs--server-host-name))
         (host-header (car host-port))
         (port (cdr host-port))
         (buf (generate-new-buffer " *dsh-auth-exchange*"))
         (cookie nil))
    (unwind-protect
        (let ((proc (open-network-stream "dsh-auth-exchange" buf
                                         host port :type 'plain)))
          (set-process-query-on-exit-flag proc nil)
          (set-process-filter
           proc (lambda (_proc string)
                  (with-current-buffer buf
                    (goto-char (point-max))
                    (insert string))))
          (process-send-string
           proc (format "GET %s HTTP/1.0\r\nHost: %s:%d\r\n\r\n"
                        req-path host-header port))
          (let ((deadline (+ (float-time) 3.0)))
            (while (and (process-live-p proc)
                        (with-current-buffer buf
                          (not (string-match-p "\r?\n\r?\n" (buffer-string))))
                        (< (float-time) deadline))
              (accept-process-output proc 0.1)))
          (when (process-live-p proc)
            (delete-process proc))
          (with-current-buffer buf
            (goto-char (point-min))
            (when (re-search-forward "^Set-Cookie: \\([_A-Za-z0-9-]+=[^;\r\n]+\\)" nil t)
              (setq cookie (match-string 1)))))
      (kill-buffer buf))
    cookie))

(defun dsh-emacs--server-auth-header ()
  "Return an alist of headers the RPC/WS layers must send, or nil.
Currently just the browser-session cookie (merging the nginx Basic header is
left to the consumers that already build it).  Kept as a function so the
layers share the single mint/cache path."
  (let ((cookie (dsh-emacs--server-auth-cookie-header)))
    (when cookie
      (list (cons "Cookie" cookie)))))

(defun dsh-emacs--server-auth-required-p ()
  "Return non-nil when the live server demands the browser-session cookie.
A bare `GET /' that answers HTTP 401 means the server is a dsh 0.1.2-rc.1+
Host that requires the cookie; a 200 means an older server that needs none.
Plain-http is checked over a raw socket (the same one the probe uses) so this
never triggers `url''s Basic prompt itself.  HTTPS returns nil: probing over
TLS would itself go through `url-retrieve' and pop the very prompt we are
trying to avoid, so an https target's token is expected from configuration."
  (ignore-errors
    (and (not (equal (url-type (url-generic-parse-url
                                (dsh-emacs--server-base-url)))
                     "https"))
         (dsh-emacs--server-auth-required-plain))))

(defun dsh-emacs--server-auth-required-plain ()
  "Return non-nil when a raw `GET /' to the plain-http base answers 401.
Mirrors `dsh-emacs--server-probe-plain' but reports only the auth-required
signal (status 401), reading the response over a hand-written TCP request so
no `url' machinery (and no username/password prompt) is involved."
  (let* ((host-port (dsh-emacs--server-host-port))
         (host-header (car host-port))
         (port (cdr host-port))
         (auth (dsh-emacs-server--basic-auth-header))
         (buf (generate-new-buffer " *dsh-auth-probe*"))
         (result nil))
    (unwind-protect
        (let ((proc (open-network-stream "dsh-auth-probe" buf
                                         (dsh-emacs--server-host-name)
                                         port :type 'plain)))
          (set-process-query-on-exit-flag proc nil)
          (set-process-filter
           proc (lambda (_proc string)
                  (with-current-buffer buf
                    (goto-char (point-max))
                    (insert string))))
          (process-send-string
           proc (concat (format "GET / HTTP/1.0\r\nHost: %s:%d\r\n"
                                host-header port)
                        (if auth
                            (format "%s: %s\r\n" (car auth) (cdr auth))
                          "")
                        "\r\n"))
          (let ((deadline (+ (float-time) 2.0)))
            (while (and (process-live-p proc)
                        (with-current-buffer buf
                          (not (string-match-p "\r?\n\r?\n" (buffer-string))))
                        (< (float-time) deadline))
              (accept-process-output proc 0.2)))
          (when (process-live-p proc)
            (delete-process proc))
          (with-current-buffer buf
            (when (string-match "^HTTP/1\\.[01] \\([0-9]+\\)"
                                (buffer-string))
              (setq result (equal (match-string 1 (buffer-string)) "401")))))
      (kill-buffer buf))
    result))

(defun dsh-emacs--server-auth-ensure-interactive ()
  "Ensure an auth cookie is ready before talking to a live external server.
For a server dsh-emacs manages itself, the launch token is auto-captured from
the server's output (see `dsh-emacs--server-auth-token'), so this is a silent
no-op: a cookie that is not yet minted just means the `token=' line has not
reached `*dsh-server*' yet, and the RPC/WS layers re-mint lazily on demand.
For an already-running (external) server that demands the browser-session
cookie but whose token is not configured, ask the user for the launch token
on each command until authentication succeeds, then cache the cookie.
This avoids letting
the first unauthenticated RPC come back 401 and pop `url''s Basic
username/password box.

Interactive only (no-op in batch, so the mocked-RPC suite never prompts).
When the user declines or the mint fails, signals `user-error' with actionable
instructions rather than proceeding to an unauthenticated request.
Empty input, a failed exchange, or quitting leaves the next command free
to prompt again."
  (when (not noninteractive)
    (cond
     ;; A cookie already exists: nothing to do.
     (dsh-emacs--server-auth-cookie t)
     ;; A server dsh-emacs manages itself: never prompt — the token is
     ;; auto-captured and a not-yet-minted cookie is transient.
     ((and dsh-emacs--server-process (process-live-p dsh-emacs--server-process))
      t)
     ;; A token is resolvable (captured / configured / base-url): mint it.
     ((let ((token (or (dsh-emacs--server-auth-token)
                       (dsh-emacs--server-auth-token-from-url
                        (dsh-emacs--server-base-url-raw)))))
        (when token (dsh-emacs--server-auth-ensure token)))
      t)
     ;; Server needs no cookie (or is https, handled by config): proceed.
     ((not (dsh-emacs--server-auth-required-p)) t)
     ;; A failed attempt aborts this command; the next command can retry.
     (t
      (let ((token (read-string
                    (format "dsh server %s requires a launch token (paste the `token=' value from the `dsh web:' URL it printed): "
                            (dsh-emacs--server-base-url)))))
        (if (string-empty-p token)
            (user-error (concat "No launch token given.  Set `dsh-emacs-server-auth-token' "
                                "(or put `?token=' in `dsh-emacs-base-url') to authenticate "
                                "to the external dsh server"))
          (unless (dsh-emacs--server-auth-ensure token)
            (user-error "dsh token exchange failed; the token may be stale or the URL wrong — check `C-h v dsh-emacs-server-auth-token'"))))
      t))))

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
  ;; A fresh server process carries a fresh launch token; invalidate the
  ;; captured token and any cookie minted from a previous process.
  (setq dsh-emacs--server-auth-captured-token nil)
  (dsh-emacs--server-auth-reset)
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
      ;; Best-effort exchange of the launch token for the browser-session
      ;; cookie, so the first RPC / WebSocket after the user acts is not a 401
      ;; race against the captured token.  If the URL line has not reached
      ;; `*dsh-server*' yet (older dsh prints none), or the token is stale, the
      ;; cookie stays unset and the RPC/WS layers re-attempt lazily on demand.
      (dsh-emacs--server-auth-ensure)
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
    ;; External server needing the browser-session cookie: prompt for the
    ;; token so the caller's first RPC is authenticated instead of popping
    ;; `url''s Basic username/password box (see
    ;; `dsh-emacs--server-auth-ensure-interactive').
    (dsh-emacs--server-auth-ensure-interactive)
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
reads the catalog via `session/modelCatalog').  This command is the bridge:
changes made in the browser show up in dsh-emacs after a refresh (`g' in
the session list, `C-c C-r' in a chat buffer).

When the server needs the browser-session launch token, the opened URL
carries `?token=...' so the browser can complete the first-time exchange
(an older server is opened at its clean base URL)."
  (interactive)
  (dsh-emacs-server-ensure)
  (let* ((base (dsh-emacs--server-base-url))
         (token (or (dsh-emacs--server-auth-capture-token)
                    (dsh-emacs--server-auth-token)
                    (dsh-emacs--server-auth-token-from-url
                     (dsh-emacs--server-base-url-raw)))))
    (browse-url (if token (format "%s/?token=%s" base token) base))
    (message "Opened %s" base)))

(defun dsh-emacs--server-local-host-p ()
  "Return t when `dsh-emacs-base-url' points at the local machine.
A probe failure against a REMOTE base-url must not trigger the local
spawn/install path: there is no local `dsh' CLI to install and no local
server to start — the remote server problem is one of reachability, not
of missing tooling.  Only loopback hosts (127.0.0.1, localhost, ::1) are
\"local\"."
  (let ((host (dsh-emacs--server-host-name)))
    (member (downcase host)
            '("127.0.0.1" "localhost" "::1" "0.0.0.0"))))

(defun dsh-emacs-server-ensure ()
  "Ensure the dsh server is reachable before a server-touching command.
With `dsh-emacs-server-auto-start' non-nil and no server answering at a
LOCAL `dsh-emacs-base-url', the `dsh' CLI is located (asking to install
it when missing) and the server is launched, waiting until it answers.
With auto-start nil this fails with startup instructions instead.

Against a REMOTE base-url (non-loopback host, e.g. a dsh server deployed
on another machine) this never spawns or installs: the CLI would only
start a LOCAL server, which is not what a remote deployment wants.
A probe failure there signals the address/network problem and lets the
user fix `dsh-emacs-base-url', while a successful probe proceeds as
usual.  No-op in batch (`noninteractive') runs, so the mocked-RPC unit
suite needs no service.

When a server is already reachable, also make sure an auth cookie is ready
before the caller fires its first RPC: an external server that requires the
browser-session cookie gets a token prompt here rather than letting
the unauthenticated request pop `url''s Basic username/password box."
  (interactive)
  (when (not noninteractive)
    (if (dsh-emacs--server-alive-p)
        (dsh-emacs--server-auth-ensure-interactive)
      (if (dsh-emacs--server-local-host-p)
          (if dsh-emacs-server-auto-start
              (dsh-emacs-server-start t)
            (user-error "dsh server not reachable at %s.  Start it with M-x dsh-emacs-server-start (or `dsh web --no-open'), or set `dsh-emacs-server-auto-start' to t"
                        (dsh-emacs--server-base-url)))
        (user-error "dsh server at %s is not reachable.  Check `dsh-emacs-base-url' and the network path to the remote server (the CLI would only start a local server, so it is not used here)"
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
Only runs when `dsh-emacs-server-start-on-init' is non-nil AND the base
URL points at the local machine — a remote deployment is never spawned
from here (the CLI would start a local server; the remote one is managed
where it runs).  The server process is spawned without waiting — the
first `dsh-emacs-server-ensure' call will block until it is ready, so the
user never sees a freeze at startup."
  (when (and dsh-emacs-server-start-on-init
             (not noninteractive)
             (dsh-emacs--server-local-host-p)
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
