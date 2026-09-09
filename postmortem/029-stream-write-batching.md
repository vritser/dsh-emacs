# 029 — Batch Reply Writes and Retain the Markdown Frontier

Implementation commit: `perf: bound streamed markdown rendering`.

Large-reply finalization is partially superseded by
[036](036-bounded-stream-markdown.md).

## Background

At `f61cef6`, Markdown refreshes were coalesced but each assistant text delta
still edited the transcript and ran viewport following. In a 5,000-delta
batch this generated 5,206 after-change notifications and 5,051 anchor lookups.
The renderer also initialized its Markdown plist through a `setf` expression
whose result it passed directly to the parser. On the tested Emacs 31 build,
adding the absent property returned a new outer plist; the caller's stream
retained no `:markdown` slot. The scan frontier was therefore recreated at
each flush, defeating the incremental scanning intended by record 028.

## Decision

Keep the first chunk immediate, then use the existing 50ms timer for text
insertion, Markdown and following together. Flush at event boundaries and
existing teardown paths. Initialize the nested Markdown state when creating
the assistant stream and pass that stored object directly to the parser.

## Why

Fewer buffer mutations reduce display invalidation at its source. Pending
deltas reference the same strings retained for final-message reconciliation;
only the pending batch is joined at refresh. No additional timer, global GC
tuning or transport scheduling is needed. Explicit state ownership avoids
depending on the return value of a generalized-variable assignment or adding
another accessor/fallback layer.

## Consequence

Subsequent text can appear about 50ms after arrival, subject to the event loop.
Tests cover a write-free burst, one insertion from a timer running in another
buffer, read-only/event properties, Unicode and draft preservation, reasoning
batching across dispatch, corrected final text, and scan-state reuse/release.
Loading the pre-change renderer makes four regression assertions fail.
This record accompanies uncommitted changes against `f61cef6`.

Synthetic batch measurements on macOS, Emacs 31.1.50, interpreted package
code: median of three runs, with a GC before each sample and GC time included.
The burst sends 5,000 `word text\n` deltas, calls following after each delta,
flushes every 100 deltas and finalizes. The fence workload starts with
` ```text\n` (without the leading space) and adds 1,000 `a line of code\n`
deltas, flushing each one; timing excludes final code highlighting.

| Workload / count | Before | After |
|---|---:|---:|
| Text burst | 187 ms | 45 ms |
| Burst after-change notifications | 5,206 | 257 |
| Burst anchor lookups | 5,051 | 52 |
| Growing unfinished fence | 411 ms | 80 ms |
| Fence characters presented to frontier scanning | 7,515,508 | 15,008 |

## Known limitations

These batch measurements exclude GUI redisplay and do not establish latency
on Emacs 27.1. Long wrapped lines can still make redisplay expensive, and a
still-growing partial line is rescanned until its newline arrives. Final
highlighting of a large completed block remains synchronous. Interleaved
non-text events can force refreshes sooner than 50ms. The change reduces work
without introducing another renderer or altering event consumption order.
