# 004 — Mux Replay Is Catch-Up: Anchor-Gated Live Dispatch

## Background

The dsh mux replays the whole global event stream to every new connection,
including mid-session reconnects.  History and watchdog re-fetches already
gated on `dsh-emacs--anchor-seq` (anchored, incremental, snapshot-first
rendering), but the live dispatch path did not: a reconnect after a socket
drop re-rendered every already-rendered frame, so the user message and the
agent reply each appeared twice with the layout interleaved and garbled until
the session was reopened (`72dbca0`, 2026-09-02).  Related replay-family
defects were fixed around the same time: ask frames re-asked after replay
(`6c06617`), and the reconnect handshake itself could silently kill a
session's stream on a reused events buffer (`1c5a247`).

## Decision

Gate live session/event dispatch on the same `dsh-emacs--anchor-seq` the
history and watchdog paths already use: replayed frames whose seq is already
within the anchor are dropped; events generated during the outage carry
seq > anchor and render exactly once as the catch-up.  The one mechanism —
the anchor — is the idempotency key for every path that reads the global
stream.

## Why

- The mux is the authoritative catch-up mechanism: replay is not a stream of
  *new* events, it is the server's way of saying "here is everything since
  the connection began".  The client must treat replay as history backfill,
  not live events; double-render was a correctness bug (duplicate rows,
  interleaved layout), not a cosmetic one.
- Reusing the existing anchor instead of inventing per-frame dedup state
  keeps one notion of "already rendered" across history, watchdog re-fetch,
  and live dispatch — the third place to forget the anchor was exactly where
  the bug lived.
- This is also what made the polling removal (001) safe: reconnect is the
  recovery path, and it is only safe because replay is idempotent under the
  anchor gate.

## Consequence

- `72dbca0` fixed the doubled transcript; the CHANGELOG 0.2.0 entry
  "A stream reconnect no longer doubles the transcript" describes the
  user-visible behavior.
- The same discipline extended to questions: a `question/requested` whose
  rpcId is already pending is dropped and `question/resolved` retires
  queued copies, so a user is never asked the same thing twice after replay.
- While opening history is still loading, the mux replay is dropped outright
  (bounded re-fetch covers the gap) — "replay old deltas" cost must not
  re-impose itself on the snapshot-first page render.

## Known limitations

- The anchor is a per-session sequence, not a global one: frames without a
  reliable per-session seq still needed their own dedup (the rpcId-based ask
  dedup above).  Any future global-topology frame (workspace changes, queue
  snapshots) must carry or derive its own idempotency key.