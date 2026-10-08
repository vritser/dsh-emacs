# 081 — The session list's first paint: batch the drain, and do not paint before the rows

## Background

Opening the session list on a large host (`~540` sessions across 25
workspaces) showed a slow first paint, reported as groups appearing at once
while the rows under them needed another ~500 ms.  Two independent
client-side mechanisms produced it; neither was the data being slow.

**1. The refresh drain repainted once per replayed frame.**
While a `session/list` / workspace refresh is in flight, live frames are
recorded (`dsh-emacs-events--host-frame-record`) and replayed on top of the
snapshot when the last span ends (`dsh-emacs-events--host-refresh-drain`) so
a request-time snapshot cannot roll the caches back below what the stream
delivered (postmortem/059 keeps the list cache current; the drain is what
keeps a *refresh* honest).  Each replayed frame was applied with the repaint
flag cleared, and a `session/control` baseline records one `:apply-title`
frame per session.  The baseline regularly lands inside a refresh span, so
the first open replayed hundreds of frames back to back, each rebuilding the
whole list (`dsh-emacs-session--update-rows`).  Measured: 544 renders after
the snapshot was cached, ~12–18 ms each, rows visible at t≈9.9 s.
`dsh-emacs-events--host-control-baseline` already batched its own applies
this way, so the drain was the one path that had missed the contract.

**2. Workspace frames painted an empty grouped list before the rows.**
`dsh-emacs-events--host-repaint` guarded on `(listp dsh-emacs--sessions)`.
Nil is a list, so a `workspace/follow` baseline arriving before the first
`session/list` response repainted the list from an empty session cache:
every group header with a `(0)` count plus one "New Session" row each.  The
real rows then replaced that ~100 ms later (the fetch round trip).  That is
the reported symptom exactly — groups "instantly", rows half a second after
— and on a slower server the false grouping sits on screen for the whole
round trip.

## Decision

Both paint paths now respect the same rule: only paint a list you can paint
completely.

- `dsh-emacs-events--host-refresh-drain` replays with repainting deferred and
  repaints once at the end; the replay itself moved into
  `dsh-emacs-events--host-replay-frame` (same `pcase` vocabulary) so the drain
  reads as "batch, then paint".  The flag is cleared — restoring the caller's
  own value, since a control baseline may already be deferring — just before
  the trailing repaint.
- `dsh-emacs-events--host-repaint` gates on `(consp dsh-emacs--sessions)`, so
  workspace frames landing on a cold cache leave the window in its empty state
  until the fetch paints groups and rows together.

## Why

Mechanism 1: the repaint is the unit of work that costs ~15 ms; the mutations
are microseconds.  Deferring is the batching the control baseline and the
socket read path already use, so no new mechanism enters the tree.
Alternatives rejected: deduplicating recorded frames hides the cost only for
unchanged titles and puts equality logic in the events layer, which does not
own projections; coalescing on a timer (`run-at-time 0`) would move the paint
outside the refresh span and reopen the rollback window the drain exists to
close.

Mechanism 2: the alternative was to paint sessions first (ungrouped) and
regroup when `workspace/follow` lands.  Rejected — it trades a correct-but-late
list for two visibly different orders and makes the row identity churn, for a
capability the UI does not need.  `nil` stays the single non-list value of the
cache: the fetch callback already relies on `nil` meaning "nothing read yet",
and at least eight readers (`dsh-emacs--sessions-index`,
`dsh-emacs--chat-session-item`, `dsh-emacs--session-preset`,
`dsh-emacs--completing-session-id`, the renderer, …) iterate the cache
directly.  A third "read but empty" sentinel was prototyped and reverted
precisely because it would have taught every one of them a new state for a
case (`session/list` returning zero rows on a host with 540 stored sessions)
that `dsh-emacs-list-sessions-display` and the fetch's own drain already paint
correctly.

## Consequence

Synthetic 540-session host, groups and rows measured separately:

| | first rows visible | groups/rows gap | renders after cache |
|---|---|---|---|
| both mechanisms present | 9.893 s | 0.094 s | 544 |
| both fixed | 0.153 s | 0.000 s | 6 |
| both fixed, 400 ms server | 0.678 s | 0.000 s | 6 |

The remaining time is the `session/list` round trip itself; with the gate the
list shows nothing rather than wrong content while it waits, so no later
repaint is needed to correct the screen.

Replayed frames still apply in arrival order and the final repaint still
happens: `refresh-replays-workspace-frames`,
`refresh-replays-session-status-title`, `nested-refresh-holds-frames`,
`nested-refresh-replays-at-outer-end` and `refresh-drain-always-restores-depth`
keep their meaning, and `refresh-drain-renders-once` is the new regression
test (200 recorded frames → exactly one render; 200 before the fix).
`host-workspace-changed-repaints` now caches a session row before the frame,
because a stream frame on an unread list intentionally no longer paints.

No user-visible surface changed; `docs/*.md` needed no update.

## Known limitations

- The numbers come from a synthetic host served locally; the real
  `session/list` cost is server-side and unmeasured here (a second `dsh web`
  cannot compose its profile inside the harness sandbox, and the live server
  needs a browser-session token).  The regressions covered by unit tests are
  independent of that number.
- On a cold cache the window stays on the empty state for the length of the
  fetch rather than showing provisional content.  A host whose
  `session/list` takes seconds therefore shows "No sessions. Press 'c' to
  create one." for that whole time; a loading affordance would need a fetch
  lifecycle this client does not model yet.
- Recording is still per frame: a baseline that repeats an unchanged title
  records and replays it.  That is now cheap (one batched repaint), but the
  recordings are not deduplicated.