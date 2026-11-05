;;; dsh-emacs-server.el --- HTTP/RPC transport and server lifecycle -*- lexical-binding: t; -*-

;; Copyright (C) 2025 vritser

;; Author: vritser
;; Version: 0.8.0
;; License: GPL-3.0-or-later
;; Package-Requires: ((emacs "28.1"))

;;; Commentary:

;; Out of the box: before any dsh-emacs-* command that needs the service, make
;; sure the dsh server is ready.  Flow (see `dsh-emacs-server-ensure'):
;;   1. probe whether `dsh-emacs-base-url' already responds (one cheap HTTP
;;      GET /);
;;   2. when it does not and the server is managed by this package
;;      (`dsh-emacs-server-auto-start'), locate the `dsh' CLI first — if it
;;      is missing, ask whether to install it with
;;      `npm install -g @deepseek-ai/dsh';
;;   3. launch `dsh web --host H --port P --no-open' in the background and
;;      wait until it is ready.
;;
;; Public API:
;;
;;   (dsh-emacs-server-ensure)   ;; guard: probe / install / start / wait
;;   (dsh-emacs-server-start)    ;; start managed server (skip when ready)
;;   (dsh-emacs-server-stop)     ;; stop the managed server process
;;   (dsh-emacs-server-restart)  ;; restart the managed server
;;   (dsh-emacs-edit-config)    ;; visit a user-chosen configuration file
;;   (dsh-emacs-open-web)        ;; open dsh web in a browser
;;   (dsh-emacs--server-alive-p) ;; whether the server is ready (short cache)
;;
;; Under batch (--batch, unit tests) `dsh-emacs-server-ensure' is always a
;; no-op: mocked-RPC unit tests need no real server and hit no network/process.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'url)
(require 'url-parse)
(require 'dsh-emacs-protocol)

(declare-function dsh-emacs-ui-navigate "dsh-emacs-ui"
                  (departure function &rest arguments))

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
  "Maximum seconds to wait for server readiness.
The first boot of `dsh web' loads the whole plugin tree and can take
several seconds.  This bounds the blocking wait of
`dsh-emacs-server-ensure', the asynchronous draft readiness check of
`dsh-emacs-server-ensure-async', and the startup polling performed by
`dsh-emacs-list-sessions'."
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
rather than showing a Basic username/password prompt.  A token that
successfully authenticates an external server is remembered here
automatically (saved with `customize-save-variable'), so the next session
reuses it instead of prompting again; only a stale token — one that fails
validation after a server restart — re-prompts, pre-filled for easy edit.
The token changes on
every server restart, so a manually-maintained value goes stale whenever the
server is restarted."
  :type '(choice (const :tag "None (auto-capture from managed server)" nil)
                 (string :tag "Launch token (token= value from `dsh web:' output)"))
  :group 'dsh-emacs-server)

;;; ---------------------------------------------------------------------------
;;; Internal state
;;; ---------------------------------------------------------------------------

(defvar dsh-emacs--server-generation 0
  "Connection/work generation advanced by connect, disconnect and server stop.
Readiness, HTTP, service buffers, event streams and deferred work capture it
with their endpoint.  Disconnect retires resources; stop preserves views.")

(defvar dsh-emacs--server-work-owner nil
  "Dynamically bound (GENERATION . BASE) for an HTTP completion chain.
A failure callback still settles local work after its owner expires, but
cannot start requests or readiness work on behalf of a newer attempt.")

(defvar dsh-emacs--connection-status 'initial
  "Lifecycle status; initial preserves first-use automatic connection.")
(defvar dsh-emacs--connection-endpoint nil)
(defvar dsh-emacs--connection-base nil
  "Private immutable endpoint of the explicit connection, including userinfo.")
(defvar dsh-emacs-base-url)
(defvar dsh-emacs--connection-error nil)
(defvar dsh-emacs--connection-cleanup-needed nil)
(defvar dsh-emacs--connection-session-status 'unknown)
(defvar dsh-emacs--connection-attempt nil)
(defvar dsh-emacs--connection-retiring nil)
(defvar dsh-emacs--server-requests nil
  "Pending request records with :origin, :write and :cancel fields.")
(defvar dsh-emacs--server-sync-active nil
  "Non-nil while synchronous HTTP work owns the current call stack.")
(defvar-local dsh-emacs--server-buffer-owner nil
  "Connection owner of this service buffer, retained until it is closed.")
(put 'dsh-emacs--server-buffer-owner 'permanent-local t)
(defconst dsh-emacs--connection-instance
  (md5 (format "%s:%s:%s:%s" (emacs-pid) (current-time) (random) (system-name)))
  "Identity distinguishing notification actions across Emacs instances.")

(declare-function dsh-emacs--connection-buffers "dsh-emacs" ())
(declare-function dsh-emacs--connection-preflight "dsh-emacs" (buffers))
(declare-function dsh-emacs--connection-cleanup "dsh-emacs" ())
(declare-function dsh-emacs--connection-initialize "dsh-emacs" (callback))
(defvar dsh-emacs--sessions)
(defvar dsh-emacs-events--host-ready)
(defvar dsh-emacs-events--host-process)

(define-error 'dsh-emacs-session-state-unavailable
              "Session directory is unavailable" 'user-error)

(defun dsh-emacs--connection-copy (value)
  "Copy mutable data in a public connection or protocol snapshot VALUE."
  (cond
   ((stringp value) (copy-sequence value))
   ((consp value) (cons (dsh-emacs--connection-copy (car value))
                        (dsh-emacs--connection-copy (cdr value))))
   ((recordp value)
    (let ((copy (copy-sequence value)))
      (dotimes (index (length copy))
        (aset copy index (dsh-emacs--connection-copy (aref copy index))))
      copy))
   ((vectorp value) (apply #'vector (mapcar #'dsh-emacs--connection-copy value)))
   ((hash-table-p value)
    (let ((copy (make-hash-table :test (hash-table-test value))))
      (maphash (lambda (key item)
                 (puthash (dsh-emacs--connection-copy key)
                          (dsh-emacs--connection-copy item) copy)) value)
      copy))
   ((or (null value) (symbolp value) (numberp value)) value)
   (t (error "Resource cannot appear in a connection snapshot"))))

(defun dsh-emacs-connection-state ()
  "Return an independent, credential-free connection state plist."
  (let ((endpoint dsh-emacs--connection-endpoint))
    ;; The default first-use flow predates explicit connect.  Describe its
    ;; actual socket owner, not an address the user may have since edited.
    (when (and (eq dsh-emacs--connection-status 'initial)
               (processp dsh-emacs-events--host-process))
      (when-let* ((owner (process-get dsh-emacs-events--host-process 'dsh-server-owner)))
        (let ((parsed (url-generic-parse-url (cdr owner))))
          (setf (url-user parsed) nil (url-password parsed) nil (url-target parsed) nil
                (url-filename parsed)
                (car (split-string (or (url-filename parsed) "") "[?#]")))
          (setq endpoint (url-recreate-url parsed)))))
    (dsh-emacs--connection-copy
     (list :status (if (eq dsh-emacs--connection-status 'initial)
                       (if (bound-and-true-p dsh-emacs-events--host-ready)
                           'connected 'disconnected)
                     dsh-emacs--connection-status)
           :endpoint endpoint
           :error dsh-emacs--connection-error
           :cleanup-needed dsh-emacs--connection-cleanup-needed))))

(defun dsh-emacs-session-snapshot ()
  "Return an independent local session directory without network access."
  (dsh-emacs--connection-copy
   (list :endpoint (plist-get (dsh-emacs-connection-state) :endpoint)
         :status dsh-emacs--connection-session-status
         :sessions (and (eq dsh-emacs--connection-session-status 'ready)
                        dsh-emacs--sessions)
         :error dsh-emacs--connection-error)))

(declare-function dsh-emacs-subagent--value "dsh-emacs-subagent" (id key))
(declare-function dsh-emacs-subagent--cell "dsh-emacs-subagent" (id key))
(defun dsh-emacs-session-exists-p (session-id &optional address)
  "Whether SESSION-ID exists in the ready local directory.
ADDRESS is a `dsh-protocol-subagent-address' for a child directory.
Signal `dsh-emacs-session-state-unavailable' when the directory is unknown."
  (unless (eq dsh-emacs--connection-session-status 'ready)
    (signal 'dsh-emacs-session-state-unavailable
            (list "Session directory is unavailable"
                  dsh-emacs--connection-session-status)))
  (if address
      (let* ((parent (dsh-protocol-subagent-address-parent address))
             (cell (dsh-emacs-subagent--cell parent 'subagentCatalog))
             (catalog (and cell (dsh-protocol-subagent-cell-value cell))))
        (unless (and cell (dsh-protocol-subagent-cell-present cell))
          (signal 'dsh-emacs-session-state-unavailable
                  '("Subagent directory is unknown" unknown)))
        (and (cl-find session-id catalog :test #'equal
                      :key #'dsh-protocol-subagent-entry-id) t))
    (and (cl-find session-id dsh-emacs--sessions :test #'equal
                  :key #'dsh-protocol-session-session-id) t)))

(defvar dsh-emacs--server-process nil
  "Process object of the dsh server this package started (or nil).
Only set when *this* package spawned the server, so
`dsh-emacs-server-stop' never kills a server the user runs themselves.")

(defvar dsh-emacs--server-alive-check nil
  "List (BASE ALIVE TIMESTAMP) caching the last liveness probe result.
The probe is a raw loopback round-trip (~1ms); the cache keeps repeated
commands (and command chains like list → workspace-list) from re-probing
on every single invocation.")

(defconst dsh-emacs--server-alive-ttl 2.0
  "Seconds a cached liveness result stays valid.")

(defconst dsh-emacs--server-default-base-url "http://127.0.0.1:3080"
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
;;; URL / probing
;;; ---------------------------------------------------------------------------

(defun dsh-emacs--server-base-url-raw ()
  "The configured server URL exactly as set by the user: `dsh-emacs-base-url'
(or the default).  This is the only accessor that may carry a `?token=' query
(the URL dsh web prints); use `dsh-emacs--server-base-url' for anything that
actually builds a request URL."
  (if (boundp 'dsh-emacs-base-url)
      dsh-emacs-base-url
    dsh-emacs--server-default-base-url))

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
would delete it), hence the `when buf' guard.
This probe precedes the launch-token exchange.  A 401 only means the
server is alive; it must not ask for Basic credentials."
  (let* ((url-request-noninteractive t)
         (buf (url-retrieve-synchronously
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
        ;; A raw HTTP request must reach the wire byte-for-byte: `:coding
        ;; 'binary' pins both directions so the ambient
        ;; `default-process-coding-system' cannot re-encode it.  On Windows its
        ;; ENCODING cdr is a `-dos' coding system (`locale-coding-system'
        ;; carries DOS line endings), which rewrites every `\n' written to a
        ;; process as `\r\n' and so turns the request's `\r\n' into `\r\r\n';
        ;; dsh's HTTP parser then answers 400 Bad Request, the probe only
        ;; accepts 200/401, and a live server reads as down (empty
        ;; `*dsh-sessions*', `new-session' timing out with "did not become
        ;; ready").  Same byte-exactness requirement as the WebSocket sockets
        ;; in `dsh-emacs-events.el'.
        (let ((proc (open-network-stream "dsh-server-probe" buf
                                         host port :type 'plain :coding 'binary)))
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
  (let ((generation dsh-emacs--server-generation)
        (now (float-time))
        (base (dsh-emacs--server-base-url)))
    (if (and dsh-emacs--server-alive-check
             (equal base (car dsh-emacs--server-alive-check))
             (<= (- now (nth 2 dsh-emacs--server-alive-check))
                 dsh-emacs--server-alive-ttl))
        (cadr dsh-emacs--server-alive-check)
      (let ((alive (dsh-emacs--server-probe)))
        (unless (dsh-emacs--server-startup-current-p generation base)
          (user-error "Server startup cancelled or endpoint changed during probe"))
        (setq dsh-emacs--server-alive-check (list base alive now))
        alive))))

(defun dsh-emacs--server-startup-current-p (generation base)
  "Whether a process startup still owns GENERATION and BASE.
Process start is allowed while the client is offline; it does not authorize
RPC, authentication or event work on a disconnected client."
  (and (= generation dsh-emacs--server-generation)
       (equal base (dsh-emacs--server-base-url))
       (not dsh-emacs--connection-cleanup-needed)
       (not (eq dsh-emacs--connection-status 'disconnecting))))

(defun dsh-emacs--server-current-p (generation base)
  "Whether server work captured with GENERATION and BASE is still current."
  (and (= generation dsh-emacs--server-generation)
       (memq dsh-emacs--connection-status '(initial connecting connected))
       (or (eq dsh-emacs--connection-status 'initial)
           (equal base dsh-emacs--connection-base))
       (equal base (dsh-emacs--server-base-url))))

(defun dsh-emacs--server-capture-owner ()
  "Capture the owner for new server work, rejecting an expired caller.
HTTP completion chains inherit their original owner instead of adopting
the current generation.  Delayed callers must capture before scheduling."
  (when-let* ((process (bound-and-true-p dsh-emacs-events--host-process))
              ((process-live-p process))
              (owner (process-get process 'dsh-server-owner)))
    (unless (equal (cdr owner) (dsh-emacs--server-base-url))
      (user-error "Disconnect before changing the dsh server address")))
  (when (and dsh-emacs--server-buffer-owner
             (not (dsh-emacs--server-current-p
                   (car dsh-emacs--server-buffer-owner)
                   (cdr dsh-emacs--server-buffer-owner))))
    (user-error "This dsh buffer belongs to a retired connection"))
  (let ((owner (or dsh-emacs--server-work-owner dsh-emacs--server-buffer-owner
                   (cons dsh-emacs--server-generation
                         (dsh-emacs--server-base-url)))))
    (unless (dsh-emacs--server-current-p (car owner) (cdr owner))
      (user-error "dsh request belongs to a cancelled server attempt"))
    owner))

(defun dsh-emacs--server-invalidate-alive ()
  "Drop the cached liveness result (after a start/stop/restart)."
  (setq dsh-emacs--server-alive-check nil))

(defun dsh-emacs--server-run-later (delay repeat function &rest args)
  "Schedule owned server work FUNCTION with ARGS after DELAY, with REPEAT.
Retain the originating buffer, reject expired work and register cancellation
with connection cleanup.  Return the timer for existing callers."
  (let* ((owner (dsh-emacs--server-capture-owner))
         (origin (current-buffer))
         (record (list :origin origin :write nil)) timer)
    (cl-labels
        ((cancel ()
           (when timer (cancel-timer timer))
           (setq dsh-emacs--server-requests (delq record dsh-emacs--server-requests)))
         (fire ()
           (if (not (and (memq record dsh-emacs--server-requests)
                         (buffer-live-p origin)
                         (dsh-emacs--server-current-p (car owner) (cdr owner))))
               (cancel)
             (unless repeat (cancel))
             (with-current-buffer origin
               (let ((dsh-emacs--server-work-owner owner))
                 (apply function args))))))
      (setf (plist-get record :cancel) #'cancel)
      (push record dsh-emacs--server-requests)
      (setq timer (run-at-time delay repeat #'fire)))))

(defun dsh-emacs--server-managed-p ()
  "Non-nil when the live managed process belongs to the configured endpoint."
  (and dsh-emacs--server-process
       (process-live-p dsh-emacs--server-process)
       (equal (process-get dsh-emacs--server-process 'dsh-server-base)
              (dsh-emacs--server-base-url))))

;;; ---------------------------------------------------------------------------
;;; Browser session auth (launch token → dsh-auth-* cookie)
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
  "Scan the current endpoint's managed process output for a launch token.
When found, store the token in `dsh-emacs--server-auth-captured-token',
reset any minted cookie (a fresh server means a fresh token), and return the
token.  Returns nil if the line has not appeared yet — for a just-launched
server the URL is printed once the plugin tree settles, which can follow the
first successful probe."
  (let ((buf (and (dsh-emacs--server-managed-p)
                  (process-buffer dsh-emacs--server-process))))
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
Only the default first-use flow reads managed or saved tokens.  Explicit
connections supply credentials through `dsh-emacs-connect'."
  (when (eq dsh-emacs--connection-status 'initial)
    (or (and (dsh-emacs--server-managed-p)
             (or (dsh-emacs--server-auth-capture-token)
                 dsh-emacs--server-auth-captured-token))
        (when (and dsh-emacs-server-auth-token
                   (not (string-empty-p dsh-emacs-server-auth-token)))
          dsh-emacs-server-auth-token))))

(defun dsh-emacs--server-auth-reset ()
  "Drop any minted cookie after the base URL or token changed.
Safe to call whenever the server address or identity may have changed; the
next authenticated call re-mints from the fresh token."
  (setq dsh-emacs--server-auth-cookie nil))

(defun dsh-emacs--server-auth-maybe-expire (base cookie)
  "Drop COOKIE after an HTTP 401 from its request to BASE.
BASE and COOKIE are captured at dispatch.  Clear only when both still
match, so a late failure cannot discard newer credentials.  A request
sent without a cookie cannot invalidate the cache.  The next authenticated
request can mint a fresh cookie after an external server restart."
  (when (and cookie
             (equal base (dsh-emacs--server-base-url))
             (equal cookie dsh-emacs--server-auth-cookie))
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
  (let* ((generation dsh-emacs--server-generation)
         (token (or token
                    (dsh-emacs--server-auth-token)
                    (dsh-emacs--server-auth-token-from-url
                     (dsh-emacs--server-base-url-raw))))
         (base (dsh-emacs--server-base-url)))
    (setq dsh-emacs--server-auth-cookie nil)
    (when token
      (let ((cookie (dsh-emacs--server-auth-exchange base token)))
        (unless (dsh-emacs--server-current-p generation base)
          (user-error "Server startup cancelled or endpoint changed during authentication"))
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
        ;; Lazy minting can run inside an RPC's POST bindings.
        (let ((url-request-method "GET")
              (url-request-data nil)
              (url-request-extra-headers nil)
              (url-request-noninteractive t)
              (url-max-redirections 0))
          (with-current-buffer (url-retrieve-synchronously url t t 5)
            (goto-char (point-min))
            (when (re-search-forward "^Set-Cookie: \\([_A-Za-z0-9-]+=[^;\r\n]+\\)" nil t)
              (match-string 1))))
      (dsh-emacs--server-auth-exchange-plain url))))

(defun dsh-emacs--server-auth-exchange-plain (url)
  "Send raw `GET URL' and return the `dsh-auth-*' cookie from its headers.
Reuses the socket probe's pattern (`dsh-emacs--server-probe-plain'): hand-write
the request with configured Basic credentials and read the response headers.
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
         (auth (dsh-emacs-server--basic-auth-header))
         (buf (generate-new-buffer " *dsh-auth-exchange*"))
         (cookie nil))
    (unwind-protect
        ;; Hand-written CRLF request: keep it byte-exact despite the ambient
        ;; process coding (see `dsh-emacs--server-probe-plain').
        (let ((proc (open-network-stream "dsh-auth-exchange" buf
                                         host port :type 'plain :coding 'binary)))
          (set-process-query-on-exit-flag proc nil)
          (set-process-filter
           proc (lambda (_proc string)
                  (with-current-buffer buf
                    (goto-char (point-max))
                    (insert string))))
          (process-send-string
           proc (concat (format "GET %s HTTP/1.0\r\nHost: %s:%d\r\n"
                                req-path host-header port)
                        (when auth
                          (format "%s: %s\r\n" (car auth) (cdr auth)))
                        "\r\n"))
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
            (when-let* ((headers-end (re-search-forward "\r?\n\r?\n" nil t)))
              (goto-char (point-min))
              (when (re-search-forward
                     "^Set-Cookie:[ \t]*\\(dsh-auth-[_A-Za-z0-9-]+=[^;\r\n]+\\)"
                     headers-end t)
                (setq cookie (match-string 1))))))
      (kill-buffer buf))
    cookie))

(defun dsh-emacs--server-auth-header (&optional raw)
  "Return authentication headers for an established server connection.
Include the browser-session cookie, minting it lazily when needed.
For a RAW request, also include Basic credentials from URL userinfo.
Ordinary HTTP callers leave RAW nil: the URL library supplies Basic itself.
Readiness probes and token exchanges keep their pre-authentication policy."
  (let ((basic (and raw (dsh-emacs-server--basic-auth-header)))
        (cookie (dsh-emacs--server-auth-cookie-header)))
    (delq nil (list basic (and cookie (cons "Cookie" cookie))))))

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
        ;; Hand-written CRLF request: keep it byte-exact despite the ambient
        ;; process coding (see `dsh-emacs--server-probe-plain').
        (let ((proc (open-network-stream "dsh-auth-probe" buf
                                         (dsh-emacs--server-host-name)
                                         port :type 'plain :coding 'binary)))
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

(defun dsh-emacs--server-auth-remember-token (token)
  "Persist TOKEN as the configured `dsh-emacs-server-auth-token'.
Called after an interactively-entered launch token successfully minted a cookie
for an external server, so later sessions reuse it instead of prompting again.
Sets the option and saves it with `customize-save-variable' (survives an Emacs
restart); the value is only written when it differs from the current one (no
churn).  A server dsh-emacs manages itself never reaches here (its token is
auto-captured per process and would be stale once pinned)."
  (when (and (stringp token) (not (string-empty-p token))
             (not (string= token (or dsh-emacs-server-auth-token ""))))
    (setq dsh-emacs-server-auth-token token)
    (customize-save-variable 'dsh-emacs-server-auth-token token)))

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
    (let ((generation dsh-emacs--server-generation)
          (base (dsh-emacs--server-base-url)))
      (cond
       ;; A cookie already exists: nothing to do.
       (dsh-emacs--server-auth-cookie t)
       ;; A server dsh-emacs manages itself: never prompt — the token is
       ;; auto-captured and a not-yet-minted cookie is transient.
       ((dsh-emacs--server-managed-p)
        t)
       ;; A token is resolvable (captured / configured / base-url): mint it.
       ((let ((token (or (dsh-emacs--server-auth-token)
                         (dsh-emacs--server-auth-token-from-url
                          (dsh-emacs--server-base-url-raw)))))
          (when token (dsh-emacs--server-auth-ensure token)))
        t)
       ;; Server needs no cookie (or is https, handled by config): proceed.
       ((let ((required (dsh-emacs--server-auth-required-p)))
          (unless (dsh-emacs--server-current-p generation base)
            (user-error "Server startup cancelled or endpoint changed during authentication"))
          (not required))
        t)
       ;; A failed attempt aborts this command; the next command can retry.
       (t
        (let* ((default (dsh-emacs--server-auth-token))
               (prompt (format "dsh server %s requires a launch token%s (paste the `token=' value from the `dsh web:' URL it printed): "
                               (dsh-emacs--server-base-url)
                               (if default " (last used token pre-filled)" "")))
               ;; Pre-fill the last-known token so a stale value is easy to edit
               ;; and retry; with no known token prompt plainly.
               (token (if default (read-string prompt default) (read-string prompt))))
          (unless (dsh-emacs--server-current-p generation base)
            (user-error "Server startup cancelled or endpoint changed during token input"))
          (if (string-empty-p token)
              (user-error (concat "No launch token given.  Set `dsh-emacs-server-auth-token' "
                                  "(or put `?token=' in `dsh-emacs-base-url') to authenticate "
                                  "to the external dsh server"))
            (unless (dsh-emacs--server-auth-ensure token)
              (user-error "dsh token exchange failed; the token may be stale or the URL wrong — check `C-h v dsh-emacs-server-auth-token'"))
            ;; The exchange succeeded: remember the working token so the next
            ;; session reuses it instead of re-prompting.
            (dsh-emacs--server-auth-remember-token token)))
        t)))))

;;; ---------------------------------------------------------------------------
;;;  RPC client
;;; ---------------------------------------------------------------------------

(defun dsh-emacs--rpc-id ()
  "Generate a unique RPC request id."
  (format "emacs-%d-%d" (random 999999) (truncate (float-time))))

(defun dsh-emacs--decode-response-body ()
  "Read the current HTTP JSON body after the caller has removed its headers.
Normalize a unibyte body to UTF-8 before passing it to the protocol reader.
`url-retrieve' may leave JSON unibyte when the server omits a charset;
parsing those bytes directly corrupts non-ASCII text.  Return raw decoded
JSON; the caller chooses the RPC or upload envelope interpretation."
  (unless enable-multibyte-characters
    (let ((body (decode-coding-string
                 (buffer-substring (point) (point-max)) 'utf-8)))
      (delete-region (point) (point-max))
      ;; Switch the response buffer before inserting decoded multibyte text.
      (set-buffer-multibyte t)
      (insert body)))
  (goto-char (point-min))
  (dsh-protocol-read-json))

(defvar url-http-response-status)

(defun dsh-emacs--rpc-request (method params)
  "Send an RPC request to the dsh web service.
METHOD is the `namespace/method' endpoint (e.g. \"session/list\") and
PARAMS the wire `args' content (an alist, or nil for parameter-less
methods).  Returns (ok-p . value) or nil.  An expired response is a failure;
an expired caller is rejected before authentication or sending."
  (let* ((dsh-emacs--server-sync-active t)
         (owner (dsh-emacs--server-capture-owner))
         (base (cdr owner))
         (url (format "%s/api/%s" base method))
         (json-data (dsh-protocol-rpc-request-json
                     method (dsh-emacs--rpc-id) params))
         (url-request-noninteractive t)
         (url-request-method "POST")
         (url-request-extra-headers
          (append '(("Content-Type" . "application/json"))
                  (dsh-emacs--server-auth-header)))
         (url-request-data (encode-coding-string json-data 'utf-8))
         (cookie (cdr (assoc "Cookie" url-request-extra-headers))))
    ;; Lazy authentication may have yielded to stop/restart or a URL change.
    (unless (dsh-emacs--server-current-p (car owner) base)
      (user-error "dsh request cancelled during authentication"))
    (condition-case err
        ;; Auth cookies are owned by dsh, not the global URL cookie jar.
        (let ((buf (url-retrieve-synchronously url nil t)))
          (unless (buffer-live-p buf)
            (error "No HTTP response from dsh server"))
          (let ((result
                 (unwind-protect
                     (with-current-buffer buf
                       (unless (dsh-emacs--server-current-p (car owner) base)
                         (error "dsh request cancelled while awaiting response"))
                       (when-let* ((status (bound-and-true-p url-http-response-status))
                                   ((>= status 400)))
                         (signal 'error (list 'http status)))
                       (goto-char (point-min))
                       (re-search-forward "^$")
                       (delete-region (point) (point-min))
                       (dsh-protocol-rpc-result--from-alist
                        (dsh-emacs--decode-response-body)))
                   (kill-buffer buf))))
            (unless (dsh-emacs--server-current-p (car owner) base)
              (error "dsh request cancelled while processing response"))
            result))
      (error
       ;; A 401 while we sent a cookie means the cached cookie is stale (an
       ;; out-of-band server restarted and minted a new token): drop it so the
       ;; next call re-mints / re-prompts instead of 401-looping until restart.
       (when (and (dsh-emacs--server-current-p (car owner) base)
                  (dsh-emacs--server-auth-http-401-p err))
         (dsh-emacs--server-auth-maybe-expire base cookie))
       (message "RPC error: %s%s" (error-message-string err)
                (dsh-emacs--http-error-hint err))
       (cons nil nil)))))

(defun dsh-emacs-rpc-error-text (value)
  "Readable text for a failed RPC's VALUE.
VALUE is the error object the server returned (an alist with `code',
`message' and `details'), a plain string, or nil when no response
arrived.  The server's message wins, with its code in parentheses; nil
reads no response; a code-only response reads the code; anything else
falls back to `%S'."
  (let* ((error (dsh-protocol-rpc-error--from-alist value))
         (text (dsh-protocol-rpc-error-message error))
         (code (dsh-protocol-rpc-error-code error)))
    (cond ((and text code) (format "%s (%s)" text code))
          (text text)
          ((stringp value) value)
          ((null value) "no response")
          (code (format "%s" code))
          (t (format "%S" value)))))

(defun dsh-emacs--http-error-hint (err)
  "Human-readable hint for an HTTP error ERR, or \"\".
ERR like `(error http 404)' comes from `url-retrieve' status.  404/405
mean the `/api/<namespace>/<method>' endpoint is not claimed by this dsh
server (unknown method or a non-POST RPC path; the gateway 404s
unclaimed /api/* POSTs).  401 means the server requires browser-session
authentication that was not satisfied."
  (if (and (listp err) (numberp (nth 2 err)))
      (let ((code (nth 2 err)))
        (if (equal code 401)
            (format " (HTTP 401: dsh web requires authentication; see `C-h v dsh-emacs-server-auth-token')")
          (if (>= code 400)
              (format " (HTTP %S: current dsh server may not expose this RPC)" code)
            (format " (HTTP %S)" code))))
    ""))

(defvar dsh-emacs--server-callback-active nil
  "Non-nil while a business HTTP callback is running.")

(defun dsh-emacs--http-post (url content-type body callback)
  "POST BODY to URL as CONTENT-TYPE and decode JSON for CALLBACK.
Complete in the live origin with a value or nil on failure.  Explicit
connection cleanup cancels read requests and resets their owning state;
pending writes block disconnect.  Stop alone still settles expired responses."
  (let* ((owner (dsh-emacs--server-capture-owner))
         (base (cdr owner))
         (url-request-noninteractive t)
         (url-request-method "POST")
         (url-request-extra-headers
          (append (list (cons "Content-Type" content-type))
                  (dsh-emacs--server-auth-header)))
         (url-request-data body)
         (origin (current-buffer))
         (cookie (cdr (assoc "Cookie" url-request-extra-headers)))
         (method (and (string-prefix-p (concat base "/api/") url)
                      (substring url (+ (length base) 5))))
         (record (list :origin origin :owner owner
                       :write (not (member method
                                           '("session/list" "session/page" "session/attachment"
                                             "session/projections" "session/modelCatalog"
                                             "commands/list" "skills/list" "job/list"
                                             "agentPresets/list" "fileReferences/list"
                                             "sessionReferenceResolver/candidates"
                                             "permissionPresets/catalog"
                                             "llm/listConfigurableProviders"
                                             "credentials/describe" "settings/describe")))))
         response done)
    (unless (dsh-emacs--server-current-p (car owner) base)
      (user-error "dsh request cancelled during authentication"))
    (cl-labels
        ((release ()
           (setq done t)
           (when (buffer-live-p response)
             (when-let* ((process (get-buffer-process response)))
               (delete-process process))
             (unless (kill-buffer response)
               (error "HTTP response buffer refused cleanup")))
           (setq dsh-emacs--server-requests
                 (delq record dsh-emacs--server-requests)))
         (received (status)
           (if done
               (kill-buffer (current-buffer))
             (setq response (current-buffer))
             (unwind-protect
                 (let ((gc-cons-threshold (* 64 1024 1024))
                       (gc-cons-percentage 0.6)
                       (err (plist-get status :error)) value)
                   (cond
                    ((not (dsh-emacs--server-current-p (car owner) base))
                     (message "dsh request cancelled while awaiting response"))
                    (err
                     (when (dsh-emacs--server-auth-http-401-p err)
                       (dsh-emacs--server-auth-maybe-expire base cookie))
                     (message "HTTP POST error: %S%s" status
                              (dsh-emacs--http-error-hint err)))
                    (t
                     (condition-case problem
                         (progn
                           (goto-char (point-min))
                           (re-search-forward "^$")
                           (delete-region (point) (point-min))
                           (setq value (dsh-emacs--decode-response-body)))
                       (error (message "HTTP POST response error: %s"
                                       (error-message-string problem))))))
                   ;; Buffer cleanup may itself yield through user hooks.
                   (kill-buffer response)
                   (when (and (not done) (buffer-live-p origin))
                     (with-current-buffer origin
                       (let ((dsh-emacs--server-work-owner owner)
                             (dsh-emacs--server-callback-active t))
                         (condition-case nil
                             (funcall callback
                                      (and (dsh-emacs--server-current-p
                                            (car owner) base) value))
                           (quit nil))))))
               (release)))))
      (setf (plist-get record :cancel) #'release)
      (push record dsh-emacs--server-requests)
      (condition-case err
          (setq response (url-retrieve url #'received nil t t))
        ((error quit) (release) (signal (car err) (cdr err)))))))

(defun dsh-emacs--rpc-async (method params callback)
  "Asynchronous RPC request; CALLBACK receives (ok-p value-or-error).
METHOD is the `namespace/method' endpoint, PARAMS the wire `args'
content — see `dsh-protocol-rpc-request-json'."
  (dsh-emacs--http-post
   (format "%s/api/%s" (dsh-emacs--server-base-url) method)
   "application/json"
   (encode-coding-string
    (dsh-protocol-rpc-request-json method (dsh-emacs--rpc-id) params) 'utf-8)
   (lambda (response)
     (let ((unwrapped (and response
                           (dsh-protocol-rpc-result--from-alist response))))
       (funcall callback (car unwrapped) (cdr unwrapped))))))

;;; ---------------------------------------------------------------------------
;;; CLI detection and install
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
;;; Start / stop / wait
;;; ---------------------------------------------------------------------------

(defun dsh-emacs--server-launch (bin host port)
  "Spawn the managed dsh server process: BIN web --host HOST --port PORT.
Returns the process; refuse while any managed process is still alive.
Output goes to `*dsh-server*', kept for diagnosis; a non-query process
so Emacs exit never prompts about it."
  (let ((base (dsh-emacs--server-base-url)))
    (when (process-live-p dsh-emacs--server-process)
      (user-error "A managed dsh server is still running; stop it explicitly first"))
    (with-current-buffer (get-buffer-create "*dsh-server*")
      (erase-buffer))
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
    (process-put dsh-emacs--server-process 'dsh-server-base
                 base)
    (set-process-query-on-exit-flag dsh-emacs--server-process nil)
    ;; A fresh server process carries a fresh launch token; invalidate the
    ;; captured token and any cookie minted from a previous process.
    (setq dsh-emacs--server-auth-captured-token nil)
    (dsh-emacs--server-auth-reset)
    (dsh-emacs--server-invalidate-alive)
    dsh-emacs--server-process))

(defun dsh-emacs--server-wait-ready ()
  "Wait up to `dsh-emacs-server-wait-seconds' for the server to answer.
Reports progress every second.  Returns t when a probe succeeds; fails
fast when the spawned process already exited; otherwise signals
`user-error' after the timeout, pointing at `*dsh-server*'."
  (when (and dsh-emacs--server-process
             (process-live-p dsh-emacs--server-process)
             (not (dsh-emacs--server-managed-p)))
    (user-error "The managed dsh server belongs to another endpoint"))
  (let ((generation dsh-emacs--server-generation)
        (base (dsh-emacs--server-base-url))
        (start (float-time))
        (deadline (+ (float-time) dsh-emacs-server-wait-seconds))
        (last-report -1))
    (while (and (dsh-emacs--server-startup-current-p generation base)
                (not (dsh-emacs--server-alive-p))
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
     ((not (dsh-emacs--server-startup-current-p generation base))
      (user-error "Server startup cancelled or endpoint changed"))
     ((dsh-emacs--server-alive-p)
      (message "dsh server ready at %s" (dsh-emacs--server-base-url))
      ;; Best-effort exchange of the launch token for the browser-session
      ;; cookie, so the first RPC / WebSocket after the user acts is not a 401
      ;; race against the captured token.  If the URL line has not reached
      ;; `*dsh-server*' yet (older dsh prints none), or the token is stale, the
      ;; cookie stays unset and the RPC/WS layers re-attempt lazily on demand.
      (when (dsh-emacs--server-current-p generation base)
        (dsh-emacs--server-auth-ensure))
      t)
     ((and dsh-emacs--server-process
           (not (process-live-p dsh-emacs--server-process)))
      (user-error "dsh server exited before becoming ready; see `*dsh-server*'"))
     (t
      (user-error "dsh server did not become ready within %ds; see `*dsh-server*'"
                  dsh-emacs-server-wait-seconds)))))

;;; ---------------------------------------------------------------------------
;;; Public commands
;;; ---------------------------------------------------------------------------

(defun dsh-emacs-server-start (&optional wait)
  "Start the dsh server as a managed background process.
Spawns `dsh web --host H --port P --no-open' (H/P from
`dsh-emacs-base-url').  A server already reachable is left alone.
When WAIT is non-nil (or called from Lisp), block until the server
answers; interactively launch and return immediately so the UI stays
responsive."
  (interactive (list nil))
  (when (or dsh-emacs--connection-cleanup-needed
            (eq dsh-emacs--connection-status 'disconnecting))
    (user-error "Finish connection cleanup before starting a server"))
  (if (memq dsh-emacs--connection-status '(disconnected failed))
      (progn
        ;; A fresh explicit process command must not revive an expired callback.
        (when (or dsh-emacs--server-work-owner dsh-emacs--server-buffer-owner)
          (dsh-emacs--server-capture-owner))
        (cl-incf dsh-emacs--server-generation)
        (dsh-emacs--server-invalidate-alive))
    (dsh-emacs--server-capture-owner))
  (let ((generation dsh-emacs--server-generation)
        (base (dsh-emacs--server-base-url)))
    (cond
     ((dsh-emacs--server-alive-p)
      (message "dsh server already running at %s" (dsh-emacs--server-base-url))
      ;; External server needing the browser-session cookie: prompt for the
      ;; token so the caller's first RPC is authenticated instead of popping
      ;; `url''s Basic username/password box (see
      ;; `dsh-emacs--server-auth-ensure-interactive').
      (when (dsh-emacs--server-current-p generation base)
        (dsh-emacs--server-auth-ensure-interactive))
      t)
     ((dsh-emacs--server-managed-p)
      (if wait
          (dsh-emacs--server-wait-ready)
        (message "dsh server already starting at %s" (dsh-emacs--server-base-url))
        nil))
     ((process-live-p dsh-emacs--server-process)
      (user-error "A managed dsh server belongs to another endpoint; stop it explicitly first"))
     (t
      (let* ((bin (or (dsh-emacs--server-bin)
                      (dsh-emacs--server-ensure-installed)))
             (host-port (dsh-emacs--server-host-port)))
        (unless (dsh-emacs--server-startup-current-p generation base)
          (user-error "Server startup cancelled or endpoint changed during installation"))
        (dsh-emacs--server-launch bin (car host-port) (cdr host-port))
        (if wait
            (progn
              (message "Starting dsh server: %s web --host %s --port %d --no-open"
                       bin (car host-port) (cdr host-port))
              (dsh-emacs--server-wait-ready))
          (message "Starting dsh server in background: %s web --host %s --port %d --no-open"
                   bin (car host-port) (cdr host-port))
          nil))))))

(defun dsh-emacs-server-stop ()
  "Stop the dsh server process this package started (if any).
Servers started outside dsh-emacs (e.g. `dsh web' in a terminal) are not
touched.  Cancel pending startup work even if no process has launched yet;
HTTP responses and delayed catalog prefetch from that attempt also expire.
A later explicit start or command can begin fresh work.  This does not
disconnect the client or stop an external server."
  (interactive)
  (let ((previous dsh-emacs--server-generation))
    (cl-incf dsh-emacs--server-generation)
    ;; Stop cancels in-flight work but does not retire the client's views.
    ;; Copy identities: mutating a captured cons would revive old callbacks.
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when (and dsh-emacs--server-buffer-owner
                   (= (car dsh-emacs--server-buffer-owner) previous))
          (setq dsh-emacs--server-buffer-owner
                (cons dsh-emacs--server-generation (cdr dsh-emacs--server-buffer-owner))))))
    (dolist (process (process-list))
      (when-let* ((owner (process-get process 'dsh-server-owner))
                  ((= (car owner) previous)))
        (process-put process 'dsh-server-owner
                     (cons dsh-emacs--server-generation (cdr owner))))))
  (dsh-emacs--server-invalidate-alive)
  (prog1
      (when (process-live-p dsh-emacs--server-process)
        (delete-process dsh-emacs--server-process)
        (setq dsh-emacs--server-process nil)
        (message "dsh server stopped")
        t)
    (when dsh-emacs--connection-attempt
      (dsh-emacs--connection-finish dsh-emacs--connection-attempt 'cancelled))))

(defun dsh-emacs-server-restart ()
  "Restart the managed dsh server process."
  (interactive)
  (dsh-emacs-server-stop)
  (dsh-emacs-server-start))

(defvar dsh-emacs--config-files nil
  "Configuration files chosen per server base URL in this Emacs session.
Each entry is (BASE-URL . FILE), recorded only after opening FILE.")

;;;###autoload
(defun dsh-emacs-edit-config (&optional choose-file)
  "Open a chosen dsh configuration file with `find-file'.
Ask for an existing file on first use for the current server URL.
With prefix argument CHOOSE-FILE, choose again.  Successful choices are
remembered per server URL for this Emacs session only.

Choose the file actually used by dsh; its location is not discovered.
Explicit TRAMP file names are supported.  Saving uses ordinary Emacs
file handling; dsh owns configuration loading and validation."
  (interactive "P")
  (let* ((server (dsh-emacs--server-base-url))
         (previous (alist-get server dsh-emacs--config-files nil nil #'equal))
         (file (expand-file-name
                (if (and previous (not choose-file))
                    previous
                  (read-file-name "dsh configuration file: "
                                  nil previous t)))))
    (unless (file-regular-p file)
      (user-error "Not a regular configuration file: %s" file))
    (require 'dsh-emacs-ui)
    (dsh-emacs-ui-navigate (point-marker) #'find-file file)
    (setf (alist-get server dsh-emacs--config-files nil nil #'equal) file)))

;;;###autoload
(defun dsh-emacs-open-web ()
  "Open the dsh web UI in the default browser.
Provider/model configuration lives in dsh itself — the web UI (Settings
opens as a modal there) or its configuration files, which can be visited
with `dsh-emacs-edit-config'.  The model picker reads the catalog via
`session/modelCatalog'.  This command is the browser bridge:
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

(defun dsh-emacs--server-unreachable-error ()
  "Signal a `user-error' for an unreachable dsh server.
Local and remote `dsh-emacs-base-url' values get tailored instructions:
a local address can be started here, a remote one only points at the
address or network path.  Startup is never attempted."
  (if (dsh-emacs--server-local-host-p)
      (user-error "dsh server not reachable at %s.  Start it with M-x dsh-emacs-server-start (or `dsh web --no-open'), or set `dsh-emacs-server-auto-start' to t"
                  (dsh-emacs--server-base-url))
    (user-error "dsh server at %s is not reachable.  Check `dsh-emacs-base-url' and the network path to the remote server (the CLI would only start a local server, so it is not used here)"
                (dsh-emacs--server-base-url))))

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
  ;; Ownership is enforced in batch too; only automatic network work is skipped.
  (dsh-emacs--server-capture-owner)
  (when (not noninteractive)
    (if (dsh-emacs--server-alive-p)
        (dsh-emacs--server-auth-ensure-interactive)
      (if (and (dsh-emacs--server-local-host-p)
               dsh-emacs-server-auto-start)
          (dsh-emacs-server-start t)
        (dsh-emacs--server-unreachable-error)))))

(declare-function url-retrieve "url"
                  (url callback &optional cbargs silent inhibit-cookies))
(defvar url-http-response-status)

(defun dsh-emacs-server-ensure-async (callback)
  "Ensure readiness without blocking, then call CALLBACK with nil or an error.
Run CALLBACK in the calling buffer, if it still exists.  Probe, launch-token
exchange and startup polling are asynchronous.  Initial CLI installation and
an unknown authentication token still require the usual user interaction."
  (dsh-emacs--server-capture-owner)
  (if noninteractive
      (funcall callback nil)
    (let ((generation dsh-emacs--server-generation)
          (origin (current-buffer))
          (base (dsh-emacs--server-base-url))
          (deadline (+ (float-time) dsh-emacs-server-wait-seconds))
          (token nil)
          (used-cookie nil)
          (prompted nil)
          (launched nil)
          (done nil)
          (notified nil)
          (response nil)
          (timer nil)
          (retry nil)
          (record (list :origin (current-buffer) :write nil)))
      (cl-labels
          ((finish (reason)
             (setq done t)
             (when timer (cancel-timer timer))
             (when retry (cancel-timer retry))
             (when (buffer-live-p response)
               (when-let* ((process (get-buffer-process response))) (delete-process process))
               (unless (kill-buffer response)
                 (error "Readiness response buffer refused cleanup")))
             (setq dsh-emacs--server-requests
                   (delq record dsh-emacs--server-requests))
             (when (and (not notified) (buffer-live-p origin))
               (setq notified t)
               (with-current-buffer origin
                 (remove-hook 'kill-buffer-hook #'cancel t)
                 (let ((dsh-emacs--server-work-owner (cons generation base))
                       (dsh-emacs--server-callback-active t))
                   (funcall callback reason)))))
           (cancel ()
             (setq origin nil)
             (finish "Session draft closed"))
           (request ()
             (cond
              (done nil)
              ((not (buffer-live-p origin)) (finish "Session draft closed"))
              ((not (dsh-emacs--server-current-p generation base))
               (finish "Server startup cancelled or endpoint changed"))
              (t
               (condition-case err
                   (let* ((url-request-method "GET")
                          (url-request-data nil)
                          (url-request-noninteractive t)
                          (url-max-redirections 0)
                          (url-request-extra-headers
                           (append
                            (when dsh-emacs--server-auth-cookie
                              (list (cons "Cookie" dsh-emacs--server-auth-cookie)))
                            (when-let* ((auth (dsh-emacs-server--basic-auth-header)))
                              (list auth)))))
                     ;; A replacement process can publish its token between
                     ;; polls.  Only a user-entered token overrides the source.
                     (setq token (or (and prompted token)
                                     (dsh-emacs--server-auth-token)
                                     (dsh-emacs--server-auth-token-from-url
                                      (dsh-emacs--server-base-url-raw))))
                     (setq used-cookie dsh-emacs--server-auth-cookie)
                     (setq response
                           (url-retrieve
                            (concat base "/"
                                    (when (and token
                                               (not dsh-emacs--server-auth-cookie))
                                      (concat "?token=" (url-hexify-string token))))
                            #'received nil t t)))
                 ((error quit) (finish (error-message-string err)))))))
           (received (_status)
             (let ((code (bound-and-true-p url-http-response-status))
                   (cookie (progn
                             (goto-char (point-min))
                             (when (re-search-forward
                                    "^Set-Cookie: \\(dsh-auth-[_A-Za-z0-9-]+=[^;\r\n]+\\)"
                                    nil t)
                               (match-string-no-properties 1)))))
               (kill-buffer (current-buffer))
               (setq response nil)
               (unless done
                 (condition-case err
                     (cond
                      ((not (buffer-live-p origin)) (finish "Session draft closed"))
                      ((not (dsh-emacs--server-current-p generation base))
                       (finish "Server startup cancelled or endpoint changed"))
                      ((or (= (or code 0) 200) (and cookie (eq code 303)))
                       (when cookie
                         (setq dsh-emacs--server-auth-cookie cookie)
                         (when prompted
                           (dsh-emacs--server-auth-remember-token token)))
                       (setq dsh-emacs--server-alive-check
                             (list base t (float-time)))
                       (finish nil))
                      ((eq code 401)
                       (setq dsh-emacs--server-auth-cookie nil)
                       (cond
                        ((and used-cookie token) (request))
                        (prompted (finish "Authentication failed"))
                        (t
                         (setq prompted t
                               token (with-current-buffer origin
                                       (read-string "dsh launch token: " token)))
                         (if (string-empty-p token)
                             (finish "No launch token given")
                           (request)))))
                      (code (finish (format "Server returned HTTP %s" code)))
                      ((not (and (dsh-emacs--server-local-host-p)
                                 dsh-emacs-server-auto-start))
                       (finish "dsh server is not reachable"))
                      ((and launched
                            (not (and dsh-emacs--server-process
                                      (process-live-p dsh-emacs--server-process))))
                       (finish "dsh server exited during startup; see *dsh-server*"))
                      ((and (process-live-p dsh-emacs--server-process)
                            (not (dsh-emacs--server-managed-p)))
                       (finish "A managed dsh server belongs to another endpoint; stop it explicitly first"))
                      ((>= (float-time) deadline)
                       (finish "dsh server did not become ready before timeout"))
                      (t
                       (let ((bin (unless (and dsh-emacs--server-process
                                               (process-live-p dsh-emacs--server-process))
                                    (or (dsh-emacs--server-bin)
                                        (dsh-emacs--server-ensure-installed)))))
                         ;; Installation yields to timers and user input.
                         ;; Recheck ownership before any startup side effect.
                         (cond
                          (done nil)
                          ((not (buffer-live-p origin))
                           (finish "Session draft closed"))
                          ((not (dsh-emacs--server-current-p generation base))
                           (finish "Server startup cancelled or endpoint changed"))
                          ((and (process-live-p dsh-emacs--server-process)
                                (not (dsh-emacs--server-managed-p)))
                           (finish "A managed dsh server belongs to another endpoint; stop it explicitly first"))
                          ((>= (float-time) deadline)
                           (finish "dsh server did not become ready before timeout"))
                          (t
                           (unless (and dsh-emacs--server-process
                                        (process-live-p dsh-emacs--server-process))
                             (let ((host-port (dsh-emacs--server-host-port)))
                               (dsh-emacs--server-launch bin (car host-port)
                                                         (cdr host-port)))
                             (setq launched t))
                           (setq retry (run-at-time 0.1 nil #'request)))))))
                   ((error quit) (finish (error-message-string err))))))))
        (setf (plist-get record :cancel)
              (lambda () (finish "Connection disconnected")))
        (push record dsh-emacs--server-requests)
        (add-hook 'kill-buffer-hook #'cancel nil t)
        (setq timer (run-at-time
                     dsh-emacs-server-wait-seconds nil
                     (lambda () (finish "dsh server readiness timed out"))))
        (if (and dsh-emacs--server-auth-cookie
                 (equal base (car dsh-emacs--server-alive-check))
                 (cadr dsh-emacs--server-alive-check)
                 (<= (- (float-time) (nth 2 dsh-emacs--server-alive-check))
                     dsh-emacs--server-alive-ttl))
            (finish nil)
          (request))))))

;;; ---------------------------------------------------------------------------
;;; Emacs exit cleanup
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
  (let ((generation dsh-emacs--server-generation)
        (base (dsh-emacs--server-base-url)))
    (when (and (dsh-emacs--server-current-p generation base)
               dsh-emacs-server-start-on-init
               (not noninteractive)
               (dsh-emacs--server-local-host-p)
               (not (dsh-emacs--server-alive-p))
               (not dsh-emacs--server-process))
      (dsh-emacs--server-run-later 1 nil
                                   (lambda ()
                                     (condition-case err
                                         (when (and (dsh-emacs--server-current-p generation base)
                                                    (not (dsh-emacs--server-alive-p))
                                                    (not dsh-emacs--server-process))
                                           (when-let* ((bin (or (dsh-emacs--server-bin)
                                                                (dsh-emacs--server-ensure-installed)))
                                                       ((dsh-emacs--server-current-p generation base))
                                                       (host-port (dsh-emacs--server-host-port)))
                                             (dsh-emacs--server-launch bin (car host-port) (cdr host-port))))
                                       (error (message "dsh startup failed: %s"
                                                       (error-message-string err)))))))))

(add-hook 'after-init-hook #'dsh-emacs-server--maybe-start-on-init)

(defun dsh-emacs--connection-clean ()
  "Finish local cleanup, retaining failed work for a subsequent retry."
  (setq dsh-emacs--connection-status 'disconnecting)
  (unless dsh-emacs--connection-cleanup-needed
    (cl-incf dsh-emacs--server-generation))
  (setq dsh-emacs--connection-cleanup-needed t
        dsh-emacs--connection-session-status 'unknown)
  (condition-case err
      (progn
        (when dsh-emacs--connection-attempt
          (dsh-emacs--connection-release-attempt dsh-emacs--connection-attempt))
        (while dsh-emacs--server-requests
          (let ((record (car dsh-emacs--server-requests)))
            (funcall (plist-get record :cancel))
            (setq dsh-emacs--server-requests
                  (delq record dsh-emacs--server-requests))))
        (dsh-emacs--connection-cleanup)
        (dsh-emacs--server-auth-reset)
        (dsh-emacs--server-invalidate-alive)
        (setq dsh-emacs--connection-status 'disconnected
              dsh-emacs--connection-endpoint nil
              dsh-emacs--connection-base nil
              dsh-emacs--connection-error nil
              dsh-emacs--connection-cleanup-needed nil))
    ((error quit)
     (setq dsh-emacs--connection-status 'failed
           dsh-emacs--connection-error
           '(:code cleanup-failed :message "Local connection cleanup failed; retry disconnect"))
     (signal (car err) (cdr err)))))

(defun dsh-emacs--connection-release-attempt (attempt)
  "Release ATTEMPT's timers, authentication request and origin hook."
  (setf (plist-get attempt :done) t)
  (when-let* ((timer (plist-get attempt :timer))) (cancel-timer timer))
  (when-let* ((response (plist-get attempt :response))
              ((buffer-live-p response)))
    (when-let* ((process (get-buffer-process response))) (delete-process process))
    (unless (kill-buffer response)
      (error "Authentication response buffer refused cleanup")))
  (when-let* ((origin (plist-get attempt :origin)) ((buffer-live-p origin)))
    (with-current-buffer origin
      (remove-hook 'kill-buffer-hook #'dsh-emacs--connection-origin-closed t)))
  (when (eq attempt dsh-emacs--connection-attempt)
    (setq dsh-emacs--connection-attempt nil)))

(defun dsh-emacs--connection-notify (attempt ok result)
  "Deliver ATTEMPT's already determined OK and RESULT once in its live origin."
  (when-let* ((origin (plist-get attempt :origin))
              ((buffer-live-p origin))
              (callback (plist-get attempt :callback))
              ((not (plist-get attempt :notified))))
    (setf (plist-get attempt :notified) t)
    (with-current-buffer origin
      (let ((dsh-emacs--server-callback-active t)
            (dsh-emacs--server-work-owner (plist-get attempt :owner)))
        (funcall callback ok result)))))

;;;###autoload
(defun dsh-emacs-disconnect ()
  "Disconnect locally, preserving servers and refusing to discard user input.
Return nil after complete cleanup.  Preflight errors change nothing.  Cleanup
errors leave a failed state requiring another disconnect before connecting."
  (interactive)
  (when (eq dsh-emacs--connection-status 'disconnecting)
    (user-error "Connection cleanup is already in progress"))
  (unless dsh-emacs--connection-cleanup-needed
    (let ((buffers (dsh-emacs--connection-buffers)))
      (dsh-emacs--connection-preflight buffers)
      (setq dsh-emacs--connection-retiring buffers)))
  (let ((attempt dsh-emacs--connection-attempt))
    (unwind-protect
        (dsh-emacs--connection-clean)
      ;; Cancellation must never run user code inside synchronous cleanup.
      (when attempt
        (run-at-time 0 nil #'dsh-emacs--connection-notify attempt nil
                     '(:code cancelled :message "Connection cancelled")))))
  nil)

(defun dsh-emacs--connection-finish (attempt &optional code)
  "Finish the current ATTEMPT successfully, or fail with a safe error CODE."
  (when (and (eq attempt dsh-emacs--connection-attempt)
             (not (plist-get attempt :done)))
    (setf (plist-get attempt :done) t)
    (condition-case err
        (if code
            (progn
              (setq dsh-emacs--connection-retiring (dsh-emacs--connection-buffers))
              (dsh-emacs--connection-clean))
          (dsh-emacs--connection-release-attempt attempt))
      ((error quit)
       (unless dsh-emacs--connection-cleanup-needed
         (cl-incf dsh-emacs--server-generation)
         (setq dsh-emacs--connection-retiring (dsh-emacs--connection-buffers)))
       (setq code 'cleanup-failed
             dsh-emacs--connection-cleanup-needed t)
       (message "dsh connection cleanup failed: %s" (error-message-string err))))
    (setq dsh-emacs--connection-status (if code 'failed 'connected)
          dsh-emacs--connection-session-status (if code 'unknown 'ready)
          dsh-emacs--connection-error
          (when code
            (list :code code :message
                  (pcase code
                    ('cleanup-failed "Local connection cleanup failed; retry disconnect")
                    ('authentication "Connection authentication failed")
                    ('origin-closed "Connection origin closed")
                    ('timeout "Connection initialization timed out")
                    ('cancelled "Connection cancelled")
                    (_ "Connection initialization failed")))))
    (dsh-emacs--connection-notify
     attempt (null code) (if code
                             (dsh-emacs--connection-copy dsh-emacs--connection-error)
                           (dsh-emacs-connection-state)))))

(defun dsh-emacs--connection-origin-closed ()
  "Cancel an unfinished connection whose origin is being closed."
  (when (and dsh-emacs--connection-attempt
             (eq (current-buffer) (plist-get dsh-emacs--connection-attempt :origin)))
    (let ((attempt dsh-emacs--connection-attempt))
      (setf (plist-get attempt :origin) nil)
      (dsh-emacs--connection-finish attempt 'origin-closed))))

(defun dsh-emacs--connection-check (attempt deadline)
  "Bound ATTEMPT by its origin lifetime, ownership and DEADLINE.
The origin check also covers temporary buffers that inhibit kill hooks."
  (when (eq attempt dsh-emacs--connection-attempt)
    (let ((owner (plist-get attempt :owner)))
      (cond
       ((not (buffer-live-p (plist-get attempt :origin)))
        (dsh-emacs--connection-finish attempt 'origin-closed))
       ((not (dsh-emacs--server-current-p (car owner) (cdr owner)))
        (dsh-emacs--connection-finish attempt 'cancelled))
       ((>= (float-time) deadline)
        (dsh-emacs--connection-finish attempt 'timeout))))))

;;;###autoload
(cl-defun dsh-emacs-connect (url &key (token nil supplied-p) callback)
  "Connect asynchronously to URL using only this attempt's TOKEN.
CALLBACK receives (OK RESULT) in the live calling buffer.  Success requires
authentication, core baselines and a ready session snapshot.  Explicit nil
TOKEN never falls back to saved or managed-server credentials."
  (unless (and (stringp url) (or (null callback) (functionp callback)))
    (user-error "A server URL and optional callback function are required"))
  (let* ((parsed (url-generic-parse-url url))
         (url-token (dsh-emacs--server-auth-token-from-url url))
         (auth-token (if supplied-p token url-token))
         (base (let ((dsh-emacs-base-url url)) (dsh-emacs--server-base-url))))
    (unless (and (member (url-type parsed) '("http" "https"))
                 (url-host parsed) (not (string-empty-p (url-host parsed))))
      (user-error "Use an http or https server URL"))
    (when (and supplied-p url-token (not (equal token url-token)))
      (user-error "URL token conflicts with the explicit token"))
    (unless (or (null auth-token)
                (and (stringp auth-token) (not (string-empty-p auth-token))))
      (user-error "Token must be a nonempty string or nil"))
    (when (or dsh-emacs--connection-cleanup-needed
              (memq dsh-emacs--connection-status '(connecting connected disconnecting))
              (and (eq dsh-emacs--connection-status 'initial)
                   (or (dsh-emacs--connection-buffers) dsh-emacs--server-requests
                       (bound-and-true-p dsh-emacs-events--host-ready))))
      (user-error "Disconnect the current connection before connecting"))
    ;; Validate everything above before changing configuration or state.
    (setq dsh-emacs-base-url base)
    (setq dsh-emacs--connection-base base)
    (cl-incf dsh-emacs--server-generation)
    (dsh-emacs--server-auth-reset)
    (dsh-emacs--server-invalidate-alive)
    (setf (url-user parsed) nil (url-password parsed) nil (url-target parsed) nil
          (url-filename parsed) (car (split-string (or (url-filename parsed) "") "[?#]")))
    (setq dsh-emacs--connection-endpoint (url-recreate-url parsed)
          dsh-emacs--connection-status 'connecting
          dsh-emacs--connection-session-status 'loading
          dsh-emacs--connection-error nil)
    (let* ((origin (current-buffer))
           (owner (cons dsh-emacs--server-generation base))
           (attempt (list :origin origin :callback callback :done nil :notified nil
                          :owner owner :timer nil :response nil))
           (prompted nil))
      (setq dsh-emacs--connection-attempt attempt)
      (add-hook 'kill-buffer-hook #'dsh-emacs--connection-origin-closed nil t)
      (cl-labels
          ((current-p ()
             (when (and (eq attempt dsh-emacs--connection-attempt)
                        (not (buffer-live-p origin)))
               (dsh-emacs--connection-finish attempt 'origin-closed))
             (and (eq attempt dsh-emacs--connection-attempt)
                  (not (plist-get attempt :done))
                  (dsh-emacs--server-current-p (car owner) base)))
           (request ()
             (when (current-p)
               (let ((url-request-method "GET") (url-request-data nil)
                     (url-request-extra-headers nil)
                     (url-request-noninteractive t) (url-max-redirections 0))
                 (condition-case err
                     (setf (plist-get attempt :response)
                           (url-retrieve
                            (concat base "/" (when auth-token
                                               (concat "?token=" (url-hexify-string auth-token))))
                            #'received nil t t))
                   ((error quit)
                    (if (plist-get attempt :done) (signal (car err) (cdr err))
                      (dsh-emacs--connection-finish attempt 'transport)))))))
           (received (_status)
             (let ((code (bound-and-true-p url-http-response-status))
                   (cookie (progn
                             (goto-char (point-min))
                             (when (re-search-forward
                                    "^Set-Cookie: \\(dsh-auth-[_A-Za-z0-9-]+=[^;\r\n]+\\)" nil t)
                               (match-string-no-properties 1)))))
               ;; Keep ownership until cleanup succeeds, including when a
               ;; buffer query refuses or a cleanup hook signals an error.
               (setf (plist-get attempt :response) (current-buffer))
               (if (not (condition-case nil
                            (kill-buffer (current-buffer))
                          ((error quit) nil)))
                   (dsh-emacs--connection-finish attempt 'cleanup-failed)
                 (setf (plist-get attempt :response) nil)
                 (when (current-p)
                   (cond
                    ((or (eq code 200) (and (eq code 303) cookie))
                     (setq dsh-emacs--server-auth-cookie cookie)
                     (with-current-buffer origin
                       (let ((dsh-emacs--server-work-owner owner))
                         (condition-case err
                             (dsh-emacs--connection-initialize
                              (lambda (ok)
                                (when (current-p)
                                  (dsh-emacs--connection-finish attempt (unless ok 'initialization)))))
                           ((error quit)
                            (if (plist-get attempt :done) (signal (car err) (cdr err))
                              (dsh-emacs--connection-finish attempt 'initialization)))))))
                    ((and (eq code 401) (not auth-token) (not prompted) (not noninteractive))
                     (setq prompted t)
                     (condition-case _err
                         (setq auth-token (with-current-buffer origin
                                            (read-passwd "dsh launch token: ")))
                       (quit (dsh-emacs--connection-finish attempt 'cancelled)))
                     (when (current-p)
                       (if (or (null auth-token) (string-empty-p auth-token))
                           (dsh-emacs--connection-finish attempt 'authentication)
                         (request))))
                    (t (dsh-emacs--connection-finish
                        attempt (if (eq code 401) 'authentication 'transport)))))))))
        (setf (plist-get attempt :timer)
              (run-at-time 0.1 0.1 #'dsh-emacs--connection-check attempt
                           (+ (float-time) dsh-emacs-server-wait-seconds)))
        (request)))
    nil))

(provide 'dsh-emacs-server)

;;; dsh-emacs-server.el ends here
