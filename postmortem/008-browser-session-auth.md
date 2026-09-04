# 008 — Browser-Session Authentication for dsh web

_Updated to fold in the interactive launch-token ask for external servers
(formerly drafted as postmortem 010; never released separately)._

## Background

dsh web added authentication to the entire Host API: starting with
`fix(web): authenticate the browser Host API` (deepseek-harness commit
`3e24087bfa`, released in 0.1.2-rc.1), every RPC route, exact Fetch route,
and WebSocket upgrade (`/api/events.mux`, `/api/events.host`) returns `401`
unless the request carries an authority-bound, HMAC-signed cookie named
`dsh-auth-<sha256(authority)>`.  The cookie is minted exactly once by
requesting `GET /?token=<launch-token>`, where the launch token is a random,
per-process value the CLI prints at startup (`dsh web: …/?token=…`).  The
token is never persisted and changes on every server start; only the signing
secret is durable (a `client-connection/browser-session` grant in
`$DSH_HOME/.credentials.yaml`).

dsh-emacs had no support for this protocol.  Its RPC posts (`dsh-emacs.el`)
and both WebSocket handshakes (`dsh-emacs-events.el`) sent only an optional
nginx Basic `Authorization` header derived from URL userinfo; there was no
token capture, no `?token=` exchange, and no cookie header.  The transport
layer's liveness probe (`dsh-emacs-server.el`) deliberately treats `401` as
"server is alive", so dsh-emacs saw a reachable server yet every real call
came back `401` — the transport layer was alive, the protocol layer was
refused.  Fixing this could not be done by URL tweaks: dsh accepts the token
nowhere except `GET /?token=` (an `Authorization` header is expressly a
non-consumed new contract in dsh's own design note), so dsh-emacs had to
reimplement the browser's token→cookie exchange.

## Decision

`dsh-emacs-server.el` — the server-lifecycle module — now owns the exchange
and shares the result:

- A `defcustom dsh-emacs-server-auth-token` (nil default) lets a user supply
  the launch token for a server dsh-emacs did not start.
- For a server dsh-emacs starts itself, the token is captured automatically
  from the `*dsh-server*` output (`dsh-emacs--server-auth-capture-token`)
  and the cookie minted eagerly right after readiness; the resolved token is
  also honored from a `?token=` in `dsh-emacs-base-url`.
- `dsh-emacs--server-auth-cookie-header` / `dsh-emacs--server-auth-header`
  mint the cookie on demand (a raw-TCP `GET /?token=…` for plain `http`,
  `url-retrieve` with redirects disabled for `https` — the `Set-Cookie`
  lives only on the first `303`, which `url` would otherwise follow away)
  and cache the parsed cookie value.
- Because a user naturally points at an external server by pasting the URL
  dsh printed — `http://HOST:PORT/?token=…` — `dsh-emacs--server-base-url`
  normalizes that base: it strips the `?token=` query and any trailing slash
  so callers can safely append paths (`/api/…`, `/`), while
  `dsh-emacs--server-base-url-raw` preserves the full configured URL so the
  token is still extracted from the query.  All RPC/path URL construction
  goes through the normalized base.
- `dsh-emacs.el` appends the cookie to every RPC post via
  `dsh-emacs--extra-request-headers`; `dsh-emacs-events.el` sends it on both
  WebSocket handshakes; `dsh-emacs-open-web` opens the token URL so a browser
  session can also authenticate.
- A `401` RPC now reports an actionable hint pointing at the option rather
  than a generic HTTP error.
- **External servers ask for the token instead of popping a Basic box**:
  `dsh-emacs--server-auth-ensure-interactive` runs before the first
  server-touching command against an already-running (external) server that
  demands the cookie and has no resolvable token.  It asks the user ONCE per
  base URL per session for the `token=` value from the URL the server
  printed (`read-string` in the minibuffer), mints the cookie, caches it and
  proceeds.  A decline or a failed mint signals an actionable `user-error` —
  never silent success, and never a re-popped Basic username/password box.
- A stale cookie self-heals: when a request that carried our cookie comes
  back `401` (an out-of-band server restarted and minted a new per-process
  token), the cached cookie and the ask-once memory are cleared, so the next
  call re-mints from a fresh token / re-prompts — instead of every RPC
  failing until Emacs restarts.

The mint is best-effort by design: if no token is known or the server
declined the exchange, dsh-emacs sends no cookie (an older server needs none)
and any real authentication failure surfaces naturally as a `401` on the
caller's own request with the improved hint — dsh-emacs never fails the mint
synchronously in the middle of an RPC.  Self-started servers never prompt
(the token is auto-captured), a token resolvable from config or the base URL
is minted without asking, an older server that needs no cookie skips the
prompt entirely, and in batch (`noninteractive`) the interactive path is a
no-op so the mocked-RPC unit suite never blocks on a prompt.

## Why

- The auth is a transport/protocol-layer reality that every connection path
  must satisfy; embedding the exchange and the cookie in the single
  server-lifecycle module (`dsh-emacs-server.el`) keeps one owner instead of
  repeating it in the RPC and event modules, which call into it through two
  small helpers.
- Auto-capture from the managed server's output means the common
  self-hosted path is entirely hands-off: the user starts dsh-emacs, and the
  per-process token (which would otherwise churn on every restart) is handled
  internally.  Only a server dsh-emacs doesn't start needs the manual
  `dsh-emacs-server-auth-token` — and since that reading-off-the-CLI step is
  precisely where users tripped, it is made interactive for external servers.
- Best-effort minting (never a synchronous user-error) preserves forward and
  backward compatibility: against an older dsh there is no cookie to obtain
  and the request simply proceeds unauthenticated, against the new dsh a stale
  or missing token surfaces as the caller's `401`, not a hard failure injected
  mid-command.
- The interactive ask fixes a *presentation* failure, not an RPC bug: with
  no token configured, the first unauthenticated RPC came back `401` and
  Emacs' `url` library — seeing no `WWW-Authenticate` challenge — fell back
  to a Basic username/password prompt that could never succeed (the server
  wants the `dsh-auth-*` cookie, not Basic credentials).  Asking once up
  front converts "your auth is broken" into "paste the token" — the same
  information the web client asks for when it cannot self-authenticate.
- Prompting only for an external server preserves the hands-off self-hosted
  path (the headline of this record) and only adds ceremony where the user
  must act anyway.
- Rejected: treating the launch token as a long-lived credential in a
  `defcustom` that users persist.  The token is per-process and must not be
  relied on across restarts; the auto-capture path and the "restart to
  refresh" guidance keep it that way, and the signing-secret durability is
  dsh's own concern (dsh-emacs just carries the cookie it is given).
- Rejected: using Emacs' built-in `url-cookie` jar.  The raw-socket probe and
  WebSocket handshake do not go through `url-retrieve`, so a cookie held only
  in `url-cookie` would not reach them; a single explicit cookie value
  propagated to both layers is simpler and consistent.
- Rejected: prompting on every unauthenticated RPC.  A declined/unknown
  token would re-prompt continuously mid-conversation; the once-per-base-URL
  memory plus an explicit actionable `user-error` on re-entry is quieter and
  points at the durable fix (`dsh-emacs-server-auth-token`).
- Rejected: a generic HTTP-401 handler that silently clears state.  Clearing
  the cookie only helps when a *stale* cookie is the cause; an external
  server the user has never authenticated needs the ask, not just a cache
  clear.

## Consequence

- Behavior: dsh-emacs transparently authenticates against dsh web
  0.1.2-rc.1+ for self-started servers; against manually-run servers it asks
  once per session for the printed `token=` value (or uses
  `dsh-emacs-server-auth-token` / a `?token=` base URL when preconfigured).
- Public surface: new `dsh-emacs-server-auth-token` option; the `401`
  RPC-error hint changed to mention authentication; the option docstring and
  the hint text mention the interactive ask as well as the option.
- A stale cookie clears itself on the next `401` — no 401-loop until
  restart.
- Ownership: the auth exchange and cookie cache live in `dsh-emacs-server.el`
  (the `dsh-emacs--server-auth-*` family); the RPC and event modules only
  call `dsh-emacs--server-auth-header` / `dsh-emacs--server-auth-cookie-header`.
- Tests: `test/dsh-test.el` covers token capture from `*dsh-server*`, token
  extraction from a base-URL query, the token→cookie exchange (mocked
  `url-retrieve-synchronously` and raw-socket exchange), cookie caching
  without re-mint, the WebSocket handshake carrying the cookie, the `401`
  hint, the stale-cookie clear on `401`, and the interactive ask paths
  (ask-once memory, decline → actionable `user-error`, managed-server
  no-prompt, token-resolvable no-prompt, not-required no-prompt) — all
  through the existing mocked-RPC seam.

## Known limitations

- A browser cookie minted by one Emacs process is not visible to another
  Emacs process (nor does dsh-emacs read the OS/browser cookie store); each
  dsh-emacs session authenticates independently via its own exchange, which
  is the same authority model dsh gives the Web client.
- The launch token is only discoverable from the CLI's printed URL, so a
  remote/manual server asks for it interactively once per session; a future
  dsh may expose a flag or machine-readable token, letting a remote profile
  be fully automatic.  `dsh-emacs-server-auth-token` remains the durable,
  non-interactive way to supply it.
- An out-of-band server restart mints a new per-process token and invalidates
  the cookie this client cached; nothing tells the client the token changed,
  so a request carrying the now-dead cookie returns `401`.  The RPC error
  path clears the cached cookie (and the ask-once memory) on that `401` so
  the next call re-mints or re-asks rather than looping until Emacs restarts
  — the self-heal described in Decision.
- If `dsh web` ever stops printing the URL line (e.g. `--no-open` suppressing
  it), auto-capture for a self-started server falls back to the user setting
  the option; the code path that mints from `dsh-emacs-server-auth-token`
  exists for exactly that case.