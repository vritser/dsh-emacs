# 027 — Batch Live Thinking Refresh

## Background

The working tree based on `6741dc9` appended each reasoning delta immediately.
After removing redundant SVG construction and window-start writes, the user
still measured 73% of CPU samples in redisplay and 25% in automatic GC.
The renderer continued to invalidate the displayed buffer on every delta.

## Decision

Show the first delta immediately, then coalesce reasoning writes on one
buffer-owned 100ms timer. Flush at event boundaries, step changes and stream
teardown. Skip per-event viewport following while a burst is pending.

## Why

Reducing buffer mutations addresses display invalidation at its source.
A reverse list avoids repeatedly copying the accumulated body. A one-shot
wall-clock timer makes progress while input remains busy. Transport order
and sequence consumption remain unchanged. Raising global GC thresholds
would only defer collection without removing display work.

## Consequence

Reasoning updates can trail arrival by about 100ms, subject to the event loop.
A 100-delta synchronous burst retains the first visible delta and flushes the
remaining 99 in one insertion. Tests cover exact text, one-edit flushing,
step changes, event boundaries and the disconnect flush entry point.
This record accompanies uncommitted changes against `6741dc9`.

## Known limitations

Interleaved non-reasoning events force earlier flushes. A single redisplay of
long wrapped lines can still be costly; batching limits frequency, not the
cost per display pass. GUI CPU reduction must be measured in the user's
session; batch tests cannot reproduce redisplay latency or its GC pressure.
