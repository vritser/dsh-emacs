# 016 — Coalesce Formatting and Probe Transport Liveness

## Background

The performance audit of baseline `79bd552` found three distinct owners:
rendering scanned and restyled replies for every delta; WebSocket decoding
copied the remaining batch for every frame; and the watchdog equated three
seconds of business silence with a dead connection. Command timers also
looked up buffer-local state before selecting their owning buffer.

## Decision

Keep text insertion immediate and coalesce Markdown formatting on one 50ms
one-shot timer per active reply. Cancel/flush it at stream boundaries and
teardown. Keep raw deltas as a list for one final comparison, retaining the
painted body when the authoritative final text matches. Parse WebSocket
batches by offset and join fragments at FIN. Probe quiet connections with a
ping; reconnect only after a matching pong fails to arrive within three
seconds. Spinner callbacks explicitly receive their owner and hidden rows
skip redraws.

## Why

The renderer owns presentation frequency; changing transport delivery order
would risk command and turn ordering. A one-shot timer coalesces bursts
without adding an idle polling loop. The final snapshot still repairs missed
text. Ping/pong distinguishes an idle application from an unresponsive
socket without fetching history or resurrecting the removed polling path.

## Consequence

Formatting can trail raw text by about 50ms, subject to the Emacs event loop.
Stable reply regions avoid repeated styling and unchanged final messages
avoid delete/reinsert churn. Tests cover timer ownership/cleanup, burst
coalescing, final flushes, cursor framing and matched/unmatched pong replies.
This record accompanies the uncommitted fix against `79bd552`; no new commit
has been created for it.

## Known limitations

An unfinished long line, code fence, or extending table still needs its
unstable region scanned on a formatting pass. Coalescing reduces frequency,
not the worst-case cost of one large table or code-highlighting operation.
The watchdog now measures WebSocket health: a responsive socket with a
stalled logical follow stream still needs manual refresh/reconnect. Parsing
a single large snapshot remains synchronous. These limits are deliberately
left separate from the timer/copying fixes.
