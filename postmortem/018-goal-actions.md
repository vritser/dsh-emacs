# 018 — Goal actions: pause / resume / edit / clear

## Background

The Goal Row (`dsh-emacs-composer.el`, postmortem/017) was display-only: it
rendered the session's goal from the `goal` projection and hid on `complete`,
but a user who wanted to pause, resume, edit, or clear the goal had to leave
Emacs and reach the host's `/goal` slash command or dsh web.  The server
exposes a dedicated `goals.*` RPC family (`rpc.md §4.10`) whose non-create
verbs are CAS: each takes a `ref = {id, revision}` and rejects on a revision
mismatch.

## Decision

Add the web GoalBar's mutation verbs as first-class chat-buffer commands in
`dsh-emacs-composer.el`, plus inline mouse affordances on the Goal Row:

- `dsh-emacs-goal-pause` / `-resume` / `-edit` / `-clear`, bound under a
  `C-c C-g` prefix keymap (`p` pause, `r` resume, `e` edit, `d` clear).
- One CAS-aware mutator, `dsh-emacs-composer--goal-mutate`, shared by all four:
  it resolves the session id (the chat buffer's `dsh-emacs--buffer-session`,
  which is the `agentId`), reads the **live** `{id, revision}` from the current
  `dsh-protocol-goal`, and issues `goals/<verb>`.  A buffer-local pending flag
  blocks a second mutation while one is in flight so rapid keys can't
  double-CAS the same revision.
- Each command optimistically re-renders the row from the verb's returned
  `GoalView` (`goals/clear` returns a bare tombstone ref → the row is removed)
  only while that request still owns the pending slot and its CAS ref remains
  current.  If the projection advances first, the newer projected state wins.
- `edit` collects the new objective via a minibuffer `read-string` pre-filled
  with the current objective (consistent with the session-rename flow).
- Failures surface via `message` and leave the row unchanged — `GoalError`
  folds into `gateway/internal` with no code to branch on, so failure is
  detected by `ok=nil` + the returned message.

Mouse affordance: the Goal Row appends small clickable cells showing the
**dsh-web action SVG icons** (pause/resume · edit · clear, gated by phase;
unicode glyph fallback when Emacs lacks SVG support), each carrying a
text-region `keymap` (RET + mouse-1 → the command), `mouse-face`, and
`help-echo` — the same idiom dsh-emacs already uses for inline-image regions.
A short objective is ellipsis-truncated to leave room for the cells, so the
row stays on one line.

## Why

A goal is a live, mutable session target; leaving it read-only while its verbs
exist on the host forced users out of the chat flow.  Colocating the verbs in
the composer module (which owns the Goal Row and its live ref) keeps the CAS
source of truth and the UI in one place.  Mirroring dsh web's verb set keeps
dsh-emacs and the browser consistent; keyboard-first bindings plus click cells
serve both Emacs and mouse workflows.  The optimistic apply matches how web
renders the GoalBar (mutation verbs are async; the projection delivers
authority), while the CAS guard + ref read make double-fire safe.

Rejected alternatives:
- **Inline form on the row for edit** — a heavier read-only-buffer editing
  surface; the minibuffer prompt already matches session rename.
- **Adding `goals/create`/`complete`** — create belongs to the `/goal` slash
  command (web parity) and complete is an agent lifecycle outcome, not a
  typical strip action.

## Consequence

Users can pause/resume/edit/clear the current goal from inside the chat buffer
(`C-c C-g p|r|e|d`) or by clicking the glyphs on the Goal Row.  New faces:
`dsh-emacs-composer-goal-action-face`.  Tests cover wire payloads (agentId/ref,
edit `request.objective`, clear), phase gating, the pending guard, error
keeps-the-row, stale-response ordering, and the mouse keymap properties.

## Known limitations

Projection-driven refresh is still the authority: an optimistic apply shows the
verb's returned view immediately when the request ref is still current, while a
projection that already advanced the ref is retained.  If the host's `goal`
projection push is delayed or absent the row converges only on the next
projection/snapshot.  The dsh-emacs event layer should re-verify that a
`goals.*` mutation re-emits the `goal` projection on the open chat (the
`goal/change` session event is the host-side signal); if a gap is found,
subscribe `goal/change` and re-read the projection.
