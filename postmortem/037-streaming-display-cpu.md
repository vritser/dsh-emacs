# 037 — Reduce Streaming Redraws and Stop Scroll Corrections

Implementation commit: `perf: reduce streaming redisplay work`.

## Background

The user observed roughly 30% Emacs CPU, with peaks above 40%, during replies.
The earlier Markdown optimizations did not account for the GUI event loop:
Emacs can redisplay after every process read and timer callback. In the live
Emacs 31.1.50 configuration, an empty-buffer control used 0.8% CPU when idle
and about 25% when merely receiving and discarding small process writes.

The renderer also fought Emacs's cursor visibility logic. With the chat's
line spacing, scanning back `window-text-height` rows put input below the
viewport. Without inserting any text, repeated follow/redisplay pairs moved
window start between positions 794 and 885. Multiline drafts added another
disagreement: the renderer targeted the prompt while Emacs needed the actual
editing point onscreen.

## Decision

Pace ready chat socket reads with a 50ms one-shot resume timer. The existing
filter consumes received bytes immediately, then further input accumulates
in the socket. Keep handshakes and the host's question/approval stream
immediately readable. Cancel resume timers on disconnect or connection loss.

Let pending text redraw the advancing busy indicator, retaining its regular
animation during text silence. Clear the transcript's modified flag without
requesting mode-line layout. Exclude selected history readers before geometry
queries. Use native `recenter -1` for viewport pinning, targeting the selected
draft point and the input anchor in other following windows.

## Why

Renderer-only batching cannot avoid process-triggered GUI work. Socket read
pacing preserves byte order and bounds callback frequency without another
Lisp event queue. Native recentering already handles line spacing, larger
faces and cursor visibility, avoiding a second pixel-layout implementation.

Increasing text batching from 50ms to 100ms did not consistently solve CPU
use and was reverted. A visible-anchor shortcut also did not improve the
paired GUI measurements and was removed. Global GC and Doom configuration
changes were not retained.

## Consequence

Three alternating before/after runs over local TCP/WebSocket replayed 400
mixed Chinese/English reasoning/text deltas and `turn/end`. Median CPU use
fell from 48.1% to 33.8% (about 30%); median input callbacks fell from 148 to
51. All runs delivered 401 events, ended with no pending text or busy flag,
and produced identical transcript SHA-256 hashes including the draft.
The empty-input viewport remained at 885 across repeated GUI redisplays;
the multiline draft remained at 911.

Unit regressions cover input order/fragments, timer cleanup, host bypass,
animation updates, and cursor visibility when character-row capacity
overstates the usable viewport. Real-server round-trip tests also pass.
This records uncommitted work based on `f61cef6` and the staged changes
through 036; no new commit was created.

## Known limitations

Read pacing compensates for Emacs's process-triggered redisplay behavior and
could be removed if that upstream behavior improves. It adds up to about
50ms receive latency during bursts, subject to Emacs timer scheduling.
Large individual frames and final Markdown passes remain synchronous.
The measured reduction is specific to this workload, frame and configuration;
it does not promise a fixed CPU percentage during every real model reply.
