# 036 — Bound Immediate Markdown and Prepare Large Replies at Idle

Implementation commit: `perf: bound streamed markdown rendering`.

## Background

After 034, partial paragraphs still revisited all earlier text on every flush.
A graphical 100-row table completion took about 532ms; 1000 Elisp lines took
63ms. Both ran directly in the final event callback. The audit baseline is the
uncommitted 034 tree against `f61cef6`.

## Decision

Use `dsh-emacs-stream-markdown-limit` (8192 characters; nil disables deferral)
to bound immediate formatting. Oversized partial lines wait for a newline or
completion while text remains visible. Large ready regions, final-only replies
and history messages enter a per-buffer idle queue. Prepare one reply under
`while-no-input` after 0.1 seconds idle, and publish only a complete result.

## Why

Reusing the existing parser preserves final Markdown semantics without an
incremental inline grammar or a worker-thread protocol. Emacs's idle/input
machinery allows typing to interrupt preparation and retry later. A one-shot
100ms clock timer checks actual idle time before each attempt; rearming an
already elapsed idle deadline from its callback could otherwise spin. The renderer
owns scheduling and body bounds; Markdown owns readiness and styling. Source
character ticks reject edits made during preparation. Following is sampled at
publication, so a queued job does not retain an obsolete follow decision.

Queued markers must exclude adjoining messages. Publishing with
`replace-region-contents` preserves matching text/reading positions and limits
comparison work to 10ms; the owning job then restores its explicit bounds and
installs prepared properties. A minimal Emacs 31 reproduction showed protected
replacement strings could poison its coding work buffer, breaking a later
`decode-coding-string` and URL module load. The diff therefore receives plain
characters. Prepared display properties are applied separately. The final
face pass also keeps the inherited assistant face below table header faces.

## Consequence

Reply text is protected and navigable before styling. Input interruption keeps
the old visible region intact; corrected replies replace queued source; reset,
buffer death and major-mode changes release pending jobs. Errors surface as a
message and leave raw text visible. Regression tests cover these paths, final
text/face parity, resumed streaming, adjoining-job bounds, reading positions
and coding-buffer cleanliness. Nothing is sent or reordered at the RPC layer.
An isolated GUI command-loop check also completed two queued replies and
retained a synthetic input character in the draft, with no timer left pending.

Three-sample batch medians for 1500 flushes fall from 0.783s to 0.291s for plain
paragraphs and 2.668s to 0.987s for rich paragraphs. Large final GUI events return
after displaying raw text in roughly 3–4ms; formatting then happens at idle.
These are responsiveness gains, not universal CPU savings: the final GUI idle
attempt costs about 116ms for code and 557ms for the table, with GC included.
See the [audit](../docs/streaming-performance.md) for fixture and timing scope.
This record accompanies uncommitted changes against `f61cef6`, after 029–035.

## Known limitations

This is a size threshold, not a hard frame-time budget. Publication, property
installation, native primitives and GC still have synchronous costs; the diff
limit covers comparison only. Continuous input can delay full styling and
discard/repeat preparation work. Temporary text/properties increase memory and
can add GC cost. Whole rendered tables still do not automatically reflow on
font/window changes. Real-server e2e and an actual Emacs 27.1 runtime were not
exercised; the event transport and protocol were not changed.
