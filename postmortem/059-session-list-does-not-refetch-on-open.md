# 059 — The session list is event-sourced, so opening it does not fetch

## Background

`dsh-emacs-list-sessions-display` (the entry point behind `M-x dsh-emacs`
and the chat buffer's `C-c C-l`) called `dsh-emacs-list-sessions` on every
open, which POSTs `session/list` and then re-baselines workspaces.  The
re-baseline is not a second request but a stream rebuild: it cancels the
live `workspace/follow` logical stream and opens a fresh one
(`dsh-emacs-events--core-workspace-rebaseline').

Worse, the session-list mode itself connected the core stream on every
open: `dsh-emacs-session-mode` calls `dsh-emacs-events-host-connect`, and
that function began with `dsh-emacs-events-host-disconnect`, so re-opening
the list tore down the socket — the `session/control`, `workspace/follow`
and `$events` streams — and handshook again.

None of that was needed: the list is maintained live by the core `$events`
stream (`session/added`, `session/removed`, `session/title`,
`session/archived`, projection frames), and creating a session already
writes its row into the cache locally (`dsh-emacs--cache-new-session`, with
a comment that the event stream does not carry it).  So a warm list was
already current, and every open paid for a round trip and a handshake to
confirm it.

## Decision

Opening the list reuses the cache: `dsh-emacs-list-sessions-display` calls
`dsh-emacs-list-sessions` only when no session is cached yet.  `dsh-emacs-events-host-connect` becomes idempotent —
a live `dsh-emacs--host-process` short-circuits it — so re-entering the mode
keeps the existing streams instead of rebuilding them.  `g` (and `M-x
dsh-emacs-list-sessions`) remain the explicit refresh, unchanged.

Re-opening also does not re-run the major mode: the display command calls
`dsh-emacs-session-mode` only when the buffer is not already in it, and
otherwise just asks for the stream (`dsh-emacs-events-host-connect`, a no-op
while it is live).

## Why

The alternative was a freshness threshold ("fetch if the cache is older than
N seconds").  It was rejected because it invents a staleness bound for data
that is already pushed: the event stream is the source of truth, so a timer
would only decide when to distrust it, and the list would still fetch at
arbitrary moments.  The cold-cache condition is not a heuristic — with no
rows there is nothing to render, so there is nothing to reuse.

Making `host-connect` idempotent rather than guarding the caller was chosen
because every reader of that function wants the same thing ("be connected"),
and the two callers that *do* need a fresh connect (the lost-connection
reconnect timer, and `dsh-emacs-list-workspaces` when no core process
exists) already clear `dsh-emacs--host-process` first, so they still connect.

Skipping the mode on re-open is what makes that guard reachable at all.
`define-derived-mode` begins with `kill-all-local-variables`, so re-running
it does not "refresh" the buffer — it resets it: the fold overrides (`TAB`),
the workspace filter and the buffer-local `dsh-emacs--host-process` all
become nil.  The user-visible symptom was that groups folded with `TAB` came
back expanded on the next open; the invisible one was that the guard saw no
process, reconnected the stream, and orphaned the previous one on every
open.  This is the same trap that had already forced the auto-jump target to
be armed after the mode.

## Consequence

- `C-c C-l` on a warm list is local: no `session/list` POST, no
  `workspace/follow` re-baseline, no socket teardown/handshake.
- The auto-jump ("open the list on the current session") still works from
  the cache, and a brand-new session is present because session creation
  cached it.
- Tests: `warm-open-costs-no-rpc`, `warm-open-renders-and-jumps`,
  `cold-open-fetches`, `host-connect-is-idempotent`,
  `reopen-keeps-folded-group`, `reopen-keeps-folded-session-hidden`.
- Docs: `docs/customization.md` states that opening reuses the live list and
  `g` refreshes.

## Known limitations

- If the host stream is down (server restarted, network dropped), the cache
  can be stale until the reconnect's baseline and the next `session/list`
  arrive; the mode reconnects on open only when the buffer's process is not
  live, and a cold cache always fetches.
- A half-dead socket (the server restarted but the local process object is
  still `process-live-p') is not detected by the connect guard: the previous
  behavior reconnected on every open, which incidentally papered over it.
  Recovery then depends on the stream's own sentinel or on `g'.
- A session deleted on the host is removed from the cache by the stream's
  removal frame; if that frame is missed while disconnected, the row can
  linger until the next explicit refresh (`g`).
