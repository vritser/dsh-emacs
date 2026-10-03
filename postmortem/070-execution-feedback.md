# 070 — Execution waits have an explicit status

## Background

At baseline `6c27b43`, the mode line showed a running animation and an optional
step badge (record 040), but discarded retry and compaction lifecycle events.
A provider backoff looked like unexplained inactivity. Standalone `/compact`
could run between turns, where the running animation gave no feedback at all.
The gap belonged to protocol decoding and status consumption, not transport:
the existing follow stream already delivered these facts.

## Decision

Show retry and compaction in the existing mode-line status, with details via
hover, click or `M-x dsh-emacs-describe-status`. The protocol module decodes
execution facts; modeline owns their buffer-local state. Render routes the
facts and retains automatic compaction failures. Events clears stale state on
disconnect and rebuilds it from the entire follow snapshot before rendering
history. This record accompanies the uncommitted change against `6c27b43`.

## Why

- Retry wait and request execution are different user-visible phases. The
  server reuses a retry id across attempts, so an old started event must not
  start a newer wait; matching includes the attempt, turn and step.
- Compaction has its own id and can have `turn: null`. Tying it to the turn's
  busy flag would hide legitimate standalone work. Retry and compaction remain
  independent so one cannot erase the other's feedback.
- The transcript anchor answers what has already rendered, not what is still
  running. Rebuilding from the full retained window recovers earlier starts;
  doing so before history rendering can yield avoids overwriting newer live
  events. Loading an older history page must never rewind this state.
- The server supplies a scheduled delay, not a remaining-time guarantee.
  Displaying that delay in details avoids a misleading local countdown and
  another timer. The existing status segment needs no generic status service
  or new module.
- Successful transitions are transient. Automatic compaction failures need
  retained evidence; manual command failures already have a result card, so
  the command remains responsible for their user-facing explanation.

## Consequence

`Retry n/m`, `Retrying n/m` and `Compacting` explain previously silent waits.
Policies with no fixed limit show only the attempt number. The keyboard
details command also works when the mode line is crowded. Completion and
cancellation settle matching state; disconnect clears it immediately.
README, modeline, architecture, RPC and adoption documentation describe the
new consumption. Todo rendering and Plan mode are outside this change.

## Known limitations

Follow snapshots are bounded, and no authoritative retry/compaction projection
is exposed. If the retained window lacks an operation's start, the client
cannot reconstruct it and shows no status; absence is not proof of completion.
The details buffer is a snapshot, not a live view. Manual compaction failures
use the command's explanation, which may summarize the lower-level error.
Compaction summaries and pruning events still have no dedicated renderer.
