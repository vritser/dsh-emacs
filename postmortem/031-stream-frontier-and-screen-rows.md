# 031 — Keep Stream Progress Outside the Transcript

Implementation commit: `perf: bound streamed markdown rendering`.

Partially superseded by [032](032-partial-line-styling-and-burst-follow.md):
large stream writes now retain following; partial-line styling does less work.
Oversized partial-line processing is further superseded by
[036](036-bounded-stream-markdown.md).

## Background

The audit starts from the working tree at `f61cef6`, including the staged
changes recorded in 029 and 030. Text writes were already batched. However,
the Markdown layer still stamped its advancing watermark on the reply's
first character. The deferred-block path also ran the entire formatter over
an empty range. Separately, renderer viewport following counted logical
lines: a 10,000-character wrapped line was mistaken for a near-bottom view.

## Decision

Keep the live render watermark in the stream's existing Markdown plist as
a marker. Retain text-property watermarks for standalone conversions that
serialize rendered strings. Skip formatting when the ready range is empty.
Use screen-row motion in the destination window for following and pinning.

## Why

A formatting cursor is parser state, not a visual property of old text.
Moving the cursor removes stable-prefix mutations without hiding legitimate
buffer changes from Emacs. Insertion type nil keeps appended text pending;
marker relocation handles earlier markup replacements. The stream owner must
initialize the new plist slot, just as it initializes the scan slots in 029.
Finalization detaches the marker; corrected final text resets it first.

Skipping an empty range removes repeated regex setup and allocation without
changing Markdown semantics. Native `vertical-motion` uses the actual window
width and display properties; logical line counts cannot describe wrapped
paragraphs. No new timer, global GC setting or transport scheduling is needed.

## Consequence

In 1,500 line flushes, first-character watermark writes fall from 1,500 to
zero. In 1,500 unfinished-fence flushes, median batch time falls from 129 ms
to 24 ms and GC cycles from five to zero. These are instrumented Emacs
31.1.50 measurements, excluding final highlighting and GUI redisplay; ordinary
line/paragraph timings are effectively unchanged. Details and scope are in
[the audit](../docs/streaming-performance.md).

Regression tests fail on the previous code for stable-prefix mutation,
empty formatting passes and wrapped-row positioning. Chunk-size parity tests
continue to verify final text and faces, including nested fences and tables.
This record accompanies uncommitted changes against `f61cef6`; it extends
029 without changing its batching policy.

## Known limitations

An unfinished long paragraph still needs repeated inline parsing. Large final
tables and code highlighting remain synchronous. Screen-row motion can itself
cost more on very long logical lines; batch results do not establish GUI frame
latency or Emacs 27.1 performance. The existing ten-row following slack is
still heuristic: a large insertion can move the prompt beyond it. This change
corrects geometry, but does not add persistent user-follow intent tracking.
