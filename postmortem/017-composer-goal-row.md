# 017 — Composer Goal Row (chat-buffer chrome above the input)

_The single-row geometry is superseded by 020; Composer now owns two optional rows._

## Background

The chat buffer's bottom region was a single implicit concept: a read-only
`❯ ` prompt plus the editable run after `dsh-emacs--input-marker`, all built by
`dsh-emacs--setup-input-area`.  There was **no** chrome row between the last
transcript block and the input, and **no** code read the server `goal` session
projection (`rpc.md §9`) — goals were reachable only through the generic
host-side `/goal` slash command, which proxies to `commands/execute` and never
carries local persistent state.  A user wanting a persistent view of the
session's active goal while chatting had none.

## Decision

Introduce a **Composer** abstraction as a new owning module,
`dsh-emacs-composer.el`, whose Phase-1 surface is a read-only **Goal Row**
pinned directly above the editable input.  The Goal Row is composer chrome,
**not** transcript content:

- it is **never** emitted as a `user/message` and **never** sent to the model;
- it is fed **passively** from the server `goal` projection — `session/control`
  `goal` frames (`dsh-emacs-events--host-apply-projection`) and the
  `session/follow` snapshot (`dsh-emacs-events--apply-snapshot-projections`)
  both route to the session's live chat buffer via
  `dsh-emacs-events--apply-goal-projection` → `dsh-emacs-composer-set-goal`;
- no `goals.*` RPC is issued in this phase (full `/goal` protocol integration
  is explicitly out of scope);
- the projection is parsed into `dsh-protocol-goal`
  (`dsh-emacs-protocol.el`), Phase 1 rendering objective + phase.

The editable Input Area geometry (`dsh-emacs--input-marker`,
`dsh-emacs--input-end`, cursor clamps, the `kill-region`/`delete-forward-char`
guards) stays in `dsh-emacs.el` — that code is already cohesive and heavily
tested, and relocating it would be a pure move with no net value.

**Geometry seam.**  Transcript inserts all funnel through
`dsh-emacs-render--input-insert-point`, today the start of the `❯ ` line.
When a Goal Row is shown it occupies its own read-only line above the input and
composer owns a buffer-local `dsh-emacs--composer-top-marker` at that row's
start; the render seam inserts above it.  The marker is `insertion-type t`, so
content streamed above the row slides the marker down with it, keeping the
chrome pinned against the input.  When the projection is nil the row is
removed and the marker cleared, restoring the original insert boundary.

## Why

A persistent goal affordance must survive the realtime stream: if the row were
ordinary transcript text, the next message insert (which targets the `❯ ` line)
would land *between* the row and the input and push the chrome away.  Anchoring
the insert boundary to the composer-top marker is the one-seam fix that keeps
Goal Row + input contiguous while the transcript grows.

Rejected alternatives:
- **Relocate all input-area geometry into composer.el** — pure move of ~15
  well-tested functions across render/queue/reference/command/modeline seams;
  breaks the "refactors must produce net value" rule.  Only the genuinely new
  chrome layer gets its own module.
- **Render the goal into the mode line or a separate frame/child-frame** —
  wrong layer for a per-session, buffer-local, read-only status that belongs
  with the transcript context; also prohibited by Phase-1 scope (no child
  frames).
- **Drive the goal via the `/goal` slash command / `goals.*` RPC** — creates a
  user-message path and fights the Phase-1 constraint that the goal must never
  be sent to the model.

## Consequence

Users with an active session goal see a `◎ objective · phase` read-only line
above the input, appearing/disappearing and updating as the goal projection
changes, surviving `C-c C-r` in-buffer redraws and rebuilt on session reopen.
Developers get a clear ownership boundary: `dsh-emacs-composer.el` owns the
Goal Row and the transcript-above-chrome seam; render.el changes only
`input-insert-point`.  New faces: `dsh-emacs-composer-goal-face`,
`dsh-emacs-composer-goal-body-face`.  New struct `dsh-protocol-goal`.
Docs touched: `architecture.md` (module list + Composer section),
`ui-styling.md`, `README.md`, `CHANGELOG.md`.

## Known limitations

Phase 1 only: the Goal Row is a **display-only** chrome fed by the projection.
There is no client `/goal` editor, no pause/resume/clear/complete actions, and
no goal state persisted anywhere but the live buffer view — the host remains
the source of truth.  A later phase that adds goal *actions* should start from
the `goal` projection/`ref` (CAS) already parsed into `dsh-protocol-goal`.
