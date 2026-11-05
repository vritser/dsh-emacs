# Switching services

The 0.9.0 development version supports one active service per Emacs instance.
Use the lifecycle API to switch; changing
`dsh-emacs-base-url` underneath open chats is not a switch.

## Disconnect and connect

`M-x dsh-emacs-disconnect` closes the current service's chats and lists,
cancels pending reads and timers, releases event streams, and clears service
caches and authentication. It leaves both external services and a managed
server process running. Use `dsh-emacs-server-stop` separately to stop the
process Emacs started. `dsh-emacs-server-start` and `dsh-emacs-server-restart`
also work while disconnected; they start the process without connecting or
authenticating the client. Connect explicitly afterward.

Disconnect refuses while there is unsent text, a recalled draft, staged
attachments, session creation, a pending submission/upload or other server
write, a running local shell command, an active minibuffer/question/approval,
or a response currently being processed. Finish or explicitly discard that
work and retry. No force-discard command is provided. A running server turn
alone does not prevent disconnect; it continues on the server.

Old chat buffers are closed, not retained as interactive snapshots. Reopening
a session reloads its history. Per-session input history is cleared; explicitly
enabled cross-session history remains. Folding, cursor position, undo and
cross-service drafts are not restored. Old desktop notification actions expire. Actions capture an endpoint fingerprint
as well as the Emacs instance and connection generation, so editing the address
alone also invalidates them; notification commands contain no URL credentials.

For Lisp integrations, call from a buffer that remains alive until completion:

```emacs-lisp
(dsh-emacs-disconnect)
(with-current-buffer (get-buffer-create " *my-dsh-connection*")
  (dsh-emacs-connect
   "http://127.0.0.1:38080"
   :token (read-passwd "Launch token: ")
   :callback (lambda (ok result)
               (if ok (dsh-emacs)
                 (message "%s" (plist-get result :message))))))
```

`dsh-emacs-connect` returns nil after starting an asynchronous attempt; this
is not a success result. Success requires authentication, the core control and
workspace baselines, and an initial session directory. Opening a chat may
still load its own history. The attempt is bounded by
`dsh-emacs-server-wait-seconds`. This API connects to an existing service and
does not install or start one.

An explicit `:token` (including nil) never falls back to saved credentials or
another managed process's output. Without the keyword, a URL `?token=...`
is accepted. Conflicting URL and keyword tokens or an empty token are rejected
before state changes. In GUI Emacs a missing token can prompt once; batch mode
reports authentication failure. A rejected explicit token is not retried with
another source. Public state strips URL userinfo, query and fragment.

The callback receives `(OK RESULT)` exactly once while its origin remains
alive, after the state is updated. RESULT is a connection snapshot on success
or `(:code CATEGORY :message SAFE-TEXT)` on failure. Categories are
`authentication`, `transport`, `initialization`, `timeout`, `cancelled`,
`origin-closed` and `cleanup-failed`. Closing the origin cancels an unfinished
attempt without running the callback in another buffer. A disconnect's
cancellation callback is deferred until after synchronous cleanup returns;
it cannot change a subsequent connection's state.

Invalid arguments or overlapping attempts signal `user-error` synchronously.
Successful disconnect returns nil, including repeated calls. If cleanup itself
fails, state becomes `failed` with `:cleanup-needed t`; call disconnect again
before connecting. The retry retains unfinished resources and the same retired
generation. Stream-close handlers run independently, so a failing feature does
not skip other cleanup. A handler gets one retry; a second failure is reported
and quarantined rather than blocking cleanup forever. Buffer/resource cleanup
failures still require a successful retry. Cleanup errors are surfaced rather
than silently ignored.

## Read APIs

These APIs do not issue network requests and return independent copies:

| API | Result |
|---|---|
| `dsh-emacs-connection-state` | Plist with `:status`, redacted `:endpoint`, `:error`, `:cleanup-needed` |
| `dsh-emacs-session-snapshot` | Plist with `:endpoint`, `:status`, decoded `:sessions`, `:error` |
| `dsh-emacs-session-exists-p ID &optional ADDRESS` | t/nil for a ready directory; otherwise signals `dsh-emacs-session-state-unavailable` |
| `dsh-emacs-current-session` | Current session id (including a child), or nil for a draft or absent selection |

Connection status is `disconnected`, `connecting`, `connected`, `disconnecting`
or `failed`. Directory status is `unknown`, `loading`, `ready`, `stale` or
`failed`; only `ready` with an empty list means there are no sessions. A core
stream loss marks the directory stale until baselines and a new list arrive.
For child existence queries, ADDRESS is a `dsh-protocol-subagent-address` as
used by the public subagent entry points. An unobserved child catalog signals
unavailable; a known empty catalog returns nil. Existence is a local snapshot,
not a lock against server-side deletion.

## Verification

The unit gate includes lifecycle, owned HTTP/events/timers, cleanup retry,
notification actions and snapshot copies. Real GUI acceptance
uses the stock token reader and records minibuffer state; it does
not claim to measure child-frame focus or visual perception.

For a repeatable real-server A → B → A acceptance run, provide two disposable
dsh 0.2.1-rc.2 services and export `DSH_URL_A`, `DSH_TOKEN_A`, `DSH_URL_B`,
`DSH_TOKEN_B`, then run:

```sh
emacs -Q --batch -L . -l test/dsh-switch-e2e.el
```

The script creates empty sessions, checks authentication, baselines, chat
streams, draft refusal and retirement in the same Emacs instance. It does not
send model prompts or stop servers. On 2026-11-04 this passed against two
Docker services on separate ports with separate data volumes. Model-driven
turn continuity and desktop OS delivery are not part of that acceptance run.
