# 165 — Waterfall prompts outside the WebSocket dispatcher

## Background

`$events` waterfalls (`approval/request`, `user-questions/request`) were
answered synchronously inside the WebSocket filter: the request handlers queued
the frame and immediately called `dsh-emacs--interaction-drain`, which read the
answer in the minibuffer.

Bounded dispatch (`3dd49c8`, [postmortem/163](163-bounded-websocket-dispatch.md))
made one consumer responsible for business messages: reentrant filters only
enqueue while `dsh-emacs-event-draining` is set. The waterfall handler runs
inside that consumer, so while the prompt is open the host's `cancel` frame —
emitted when another client answers — is queued but not dispatched. The prompt
could not close until the local user answered. Approval `y-or-n-p` could also
choose a native dialog, which `abort-recursive-edit` cannot dismiss.

Commits: 3dd49c8 (bounded dispatch); fix pending.

## Decision

- When a waterfall is enqueued inside the dispatcher, start its reader from a
  zero-delay timer (`dsh-emacs--interaction-run`), returning the dispatcher to
  its loop first. Direct callers (tests, the late-answer command) still open
  the reader synchronously.
- Check the per-frame cancellation marker before opening a reader and before
  each question in a batch, so a cancel that raced the prompt opening leaves
  nothing to ask.
- Bind `use-dialog-box` nil around the approval `y-or-n-p`, keeping the
  approval reader in the minibuffer.

## Why

The dispatcher must keep consuming frames while a prompt waits for input;
otherwise a remote answer can never reach the prompt. Moving the reader to a
timer preserves that property without reentrant dispatch, which would break
the ordered batch that `3dd49c8` established. The pre-checks cover the narrow
window between the scheduled drain and the minibuffer becoming active. The
dialog binding is required because a native dialog bypasses the minibuffer that
the cancel handler aborts.

## Consequence

A `cancel` frame now closes the active question or approval prompt, including
one opened from a frame queued behind another prompt. Approval prompts are
always minibuffer prompts, even after a mouse event, matching the interaction
contract already documented. Late-answer commands keep their synchronous
reader; the shared cancellation predicate is waterfall-kind-aware, so the
`(late-answer)` slot is never mistaken for a cancelled prompt. Tests cover the
question and approval dispatcher deferral, the pre-cancel skip for both kinds,
the late-answer reader and the dialog binding; existing question/approval tests
exercise the synchronous path.

## Known limitations

The reader still blocks Emacs command input while it is open; only the event
dispatcher is kept free. A waterfall that arrives while the user is in an
unrelated minibuffer may start its prompt when the timer fires, as before.
