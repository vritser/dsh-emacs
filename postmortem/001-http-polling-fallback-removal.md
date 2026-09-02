# 001 — HTTP Polling Fallback Removal

## Background

From the initial snapshot (`df93cd5`, 2026-08-23) the client shipped a
"resilient event stream": a native RFC 6455 WebSocket mux as the primary
channel, plus an HTTP polling fallback — when the stream wedged, a per-buffer
timer fetched the latest history window (~850 events) at 1 Hz until the
stream recovered.  Polling was woven through the hot paths: re-armed through
the reconnect handshake window (`1c5a247`) and skipped while opening history
loaded (`f4bec3c`).

The fallback was the named source of global UI stutter: any wedged stream
drove 1 Hz history fetches across affected buffers while the same events were
already queued on the mux for the reconnect, so the client rendered the same
stream twice through two different paths.

## Decision

Remove the fallback entirely (`fe23b2a`, 2026-09-01, breaking): drop
`dsh-emacs-poll-fallback`, `dsh-emacs-poll-interval`, `dsh-emacs-poll-warn-delay`
and the per-buffer poll timers.  The WebSocket mux is the only automatic
delivery channel.  Recovery from an outage is the watchdog/health-check
reconnect restores the stream, or the user's manual `C-c C-r`; opening a
session still bootstraps and backfills through `session.history`.

## Why

- Polling fetched from the same mux-topic history the live stream already
  rendered, so it was never a neutral fallback — it was a second renderer of
  one stream, inviting replay and double-render races (the family later
  solved by anchor-gating; see 004).
- 1 Hz global fetches were the named stutter source; per-buffer timers added
  state (armed/skipped/ami warning) that had to be correct in every
  reconnect and handshake path.
- The guarantee polling actually bought was weak: replies during an outage
  did not appear until the server could answer history anyway — i.e. until
  the stream was effectively back.  The mux's replay (catch-up on reconnect)
  plus manual refresh covered real recovery.

## Consequence

- `dsh-emacs-poll-*` defcustoms are gone; saved customizations of them are
  silently dropped on upgrade (breaking entry in CHANGELOG 0.2.0).
- During a stream outage, replies appear only once the stream recovers or via
  `C-c C-r` — an accepted, documented limitation.
- The reconnect path became the single ownership point for recovery, which
  is what made the subsequent replay/dedup hardening (004, and the
  question-replay dedup) coherent.

## Known limitations

- The client itself cannot sense a *silently failing* stream except through
  the watchdog/health-check and the user's manual refresh; no in-band
  delivery is attempted while disconnected.