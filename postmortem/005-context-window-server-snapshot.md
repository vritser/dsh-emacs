# 005 — Context Usage: Server Snapshot Only

## Background

The 0.1.0-era footer resolved the context-window usage per model on the
client: a per-model context-window resolution (`88834b1`) fed by manual
knobs `dsh-emacs-footer-context-window` and
`dsh-emacs-footer-context-window-alist`, shown only as configured values.
The client had no idea how the server actually accounted context, so the
percentage was a guess that drifted from dsh web's own display.

## Decision

Consume the server's `contextPressure` projection — `pressureTokens`,
`projectedTokens`, `contextWindow` — from `session/projection` frames and on
session open, and render ctx% from that snapshot alone (`3e0b9fc` →
`250f6f8`, 2026-08-29): `pressureTokens / contextWindow` from the same
snapshot's two values, with the server as the single source of truth
("数据口径与 dsh web 对齐").  Delete the manual options.

## Why

- The server owns context accounting; the client cannot reproduce it.
  `cacheRead` usage alone is usually many times the window, so a naive
  tokens/window client calculation is wrong even with correct inputs — the
  renderer comment in `dsh-emacs-modeline.el` says this explicitly.
  A per-model client-side table was maintenance and a lie; the server push
  is one wire shape, one owner.
- Snapshot-not-sum: the projection pair arrives atomically, so pressure and
  window can never disagree across a session-row update.
- The manual options were a stopgap from before the server exposed the
  projection; keeping them would create two sources of truth with no honest
  way to reconcile.

## Consequence

- Breaking: `dsh-emacs-footer-context-window` and
  `dsh-emacs-footer-context-window-alist` are gone; saved customizations are
  silently dropped on upgrade (CHANGELOG 0.2.0 breaking entry).
- The ctx% segment is seeded on session open and updated live from
  projection frames; a `session.list` row lacking context-window data no
  longer hides an already-known percentage.
- Trust guard: the projection pair is honored only while the raw pressure
  sample is positive.  A failed run reports usage 0/0; its last-wins sample
  corrupts the derived `projectedTokens` (pressure + surface movement), which
  then recovers to a small lying value on the next submit — the mode-line
  keeps the last genuine snapshot instead (`5a468a8`, `6018e65`, `b00668e`).

## Known limitations

- ctx% is only as fresh as the last projection frame; between frames the
  segment shows the last honest snapshot (deliberate — a stale honest number
  beats a fresh lying one).
- `projectedTokens` remains unused for display; it is the pressure +
  movement projection and can lie, so only the raw snapshot drives the
  segment.