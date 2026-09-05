# 003 — Queue and Steer: Host-Snapshot Mirror

_The `C-u C-c C-c` toggle described below is superseded by 014; it now
always selects steer._

## Background

While a turn runs, dsh delivers further input through the agent inbox:
`queue` lands in next-turn, `steer` in next-step (before the running agent's
next step).  Before `a1dba80` (2026-09-01) the client had no way to use the
inbox: `C-c C-c` while busy only interrupted, and `dsh-emacs-busy-enter-behavior`
was a placeholder with nothing to send to.

The design discussion (root `queue-design.md`) had already rejected a
persistent side panel or overlay in favor of Emacs-transient presentation —
mode line for passive state, echo area for action feedback, a
`completing-read` manager for active control ("平时无感，一键唤起").

## Decision

Mirror the host's authoritative `session/queue` mux frames — no fetch RPC, no
local drift: the host pushes the snapshot once per connection for sessions
with pending items and on every inbox splice, and `dsh-emacs-queue.el` only
mirrors that stream.  UX: `C-c C-c` while busy queues (default) or steers,
`C-u C-c C-c` flips for one send, empty input still interrupts, `C-c C-b`
interrupts explicitly; a `[Qn Sm]` mode-line indicator, transient echo-area
feedback, a clock-icon input-prompt preview following the host's delivery
order (steered items lead), and `C-c C-q` as a minibuffer manager
(`e` edit / `s` steer / `d` delete / `RET` send now / `x` clear).

## Why

- Only the host knows the true inbox state and delivery order — anything but
  mirroring drifts by definition.  The mux push removes fetch RPCs and keeps
  the client eventually consistent with one mechanism (the same replay/seq
  discipline as 004).
- Transient presentation over persistent chrome: a modal panel is the
  opposite of Emacs usage patterns (completing-read over side windows), and
  an overlay that tracks a fast-moving agent log is fragile — the queue
  design note says exactly this.
- The composition is deliberate: passive perception (mode-line), active
  push (echo area), on-demand control (minibuffer) — each layer has one job,
  matching the module map.

## Consequence

- New commands and keys: `dsh-emacs-list-queue` (`C-c C-q`), explicit
  `dsh-emacs-interrupt-turn` (`C-c C-b`), and the redefined `C-c C-c` /
  `C-u C-c C-c` semantics; new option `dsh-emacs-busy-enter-behavior`
  (`queue` default, `steer`, or `stop` for old interrupt-only behavior).
- The mode-line gained a queue segment (reusing the modeline surface from
  002); the input prompt preview shows the next message the host will send.
- Client-side steer/delete/edit RPCs apply to the mirror optimistically on
  success so the hint refreshes without waiting for the confirming frame.
- CHANGELOG 0.2.0 Added carries the full user-visible description; the wire
  names were verified against the dsh 0.1.1-rc.2 RPC table
  (`session.prompt` `mode`, `session.updateQueue`).

## Known limitations

- The mirror is authoritative *from the host's* frame stream; a session whose
  mux has not yet replayed its queue (fresh connection) shows an empty mirror
  until the first `session/queue` frame arrives — accepted, since the mux
  replay guarantees one on every connection.
