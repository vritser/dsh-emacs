# 071 — Plan mode is a persistent, sequenced status

The ordinary-question review decision is superseded by 072; the status
projection decisions remain in force.

## Background

The `6c27b43` baseline already ran `/plan` through the slash-command path and
rendered Todo tool rows, but had no consumer for the `plan` projection. Record
070 added transient retry/compaction feedback and left Plan mode separate.
The installed dsh 0.1.7-rc.1 (`46a7f68b09`) defines Plan as collaboration
state: `active` is committed, `pending` means an opposite selection is not yet
applied. Todo progress and permission restrictions are independent.

## Decision

Display `Plan`, `Plan → on`, or `Plan → off` in the existing mode-line status,
with the current and pending states in the status-details command. Protocol
constructors decode the projection and its sequence; events routes control
increments and follow/control baselines; modeline owns the persistent mirror.
This record accompanies the Plan change against `2c22407`, the commit that
landed record 070's execution feedback.

## Why

- A submitted command does not prove the new mode is active. During an open
  turn the host waits for an accepted step; a failed command or cancelled
  selection can remove the pending change. Reading the projection preserves
  that distinction without duplicating the host's event fold.
- Plan survives turn completion. Clearing it with the spinner would hide an
  active mode precisely when the user prepares the next message. A transient
  disconnect retains the last known state; a new core connection discards the
  prior generation's cuts before rebuilding them.
- Control updates and follow snapshots arrive independently. Applying Plan
  before history can yield handles interleaving during rendering; comparing
  `seq` with `asOfSeq` also handles a whole old snapshot arriving late. An
  absent capability keeps its watermark so a late increment cannot restore it.
- Existing slash commands already enter/leave Plan mode, and the existing
  question path handles plan review. A new toggle command, approval flow or
  Todo UI would duplicate working surfaces.

## Consequence

Users can see whether Plan is active or merely requested, including between
turns. Inactive state has no badge; absent capability stays unknown rather than
claiming the mode is off. Hover, click and `M-x dsh-emacs-describe-status`
provide details. Old history does not alter the current status. No new RPC,
polling loop, timer, keybinding or face was added.

Unit tests cover booleans, pending transitions, session isolation, history,
interleaved updates, stale snapshots, absent capability and new-generation
sequence reset. E2E starts through the normal `dsh-emacs` entry point so the
core projection stream is live, then exercises `/plan`, turn completion,
rebaseline and `/plan off`; opening a chat alone only starts its follow stream.

## Known limitations

Live projection updates require the existing core connection owned by the
session-list buffer. A disconnected badge is the last confirmed state until
the connection/snapshot refreshes it. Pending describes the host's published
selection, not every internal intent: plan-review approval may only become
visible when the host records the next committed mode. The details buffer is
a snapshot taken when opened.
