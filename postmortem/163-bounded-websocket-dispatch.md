# 163 — Bounded WebSocket dispatch

## Background

Neomacs live sampling put most evaluator samples inside the WebSocket filter,
with synchronous recenter/layout accounting for more than half the samples.
An isolated GUI replay of 600 tool events in one 132 KB input chunk held the
filter for 3.13 seconds and delayed a 100 ms timer by 3.21 seconds. Individual
recenter calls stayed below 9 ms: the unbounded batch, rather than one slow
layout, owned the observed multi-second pause.

Commits: pending (no commit requested).

## Decision

Decode complete frames separately from business-message dispatch. Respond to
Ping/Pong controls while parsing; enqueue text messages and Close in wire
order. Dispatch for at most 10 ms per batch, then use a 1 ms one-shot timer to
continue. New input retains an already-pending continuation deadline.
Reentrant callbacks may parse and enqueue but cannot become a second business
consumer. Teardown cancels the continuation and releases queued messages.

## Why

Bounding Rust socket reads alone cannot bound the many business events carried
in one read. Yielding only between reads also leaves heartbeats behind a slow
rendering batch. The transport owner can separate WebSocket controls from
ordered business messages without inserting scheduling hacks into rendering
or mode-line code. Close stays after preceding business messages.

## Consequence

The same isolated Neomacs replay reduced the initial filter to 16 ms, consumed
all 600 events in order, and recorded no timer gap above 300 ms. Total replay
time increased from 3.24 to 5.61 seconds because Emacs could service timers and
redisplay between batches. Tests cover batching and yielding, control
responses answered while a continuation is pending, reentrant input, partial
frame tails, Close ordered after accepted messages, and disconnect cancelling
a pending continuation.

A loopback TCP/WebSocket replay used a one-second heartbeat deadline while
sending the same 600 events. The previous consumer timed out with no Pong
received before the deadline. The bounded consumer delivered all events,
answered 45 Pings, and kept the maximum observed Pong delay below 168 ms.
The project verification gate, including the optional Motion Line suite, passed.

## Known limitations

A single message remains atomic; a particularly expensive snapshot or Lisp
callback can still exceed the budget. Decoding one input chunk is synchronous.
The queue is lossless, so a producer permanently faster than its consumer can
still build a backlog. A peer-initiated Close is dispatched after the accepted
business messages ahead of it, so the socket is closed only once that backlog
has drained (the old synchronous consumer took the same total time before
`delete-process`, but it did not serve timers in between). The gateway closes
connections after missed heartbeats; this change removes one source of delayed
replies, but live sampling alone did not prove the cause of each reported
EPIPE.
