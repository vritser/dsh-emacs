# 033 — Combine Final Face Work and Contain Pixel Probes

Implementation commits:

- `perf: streamline table layout measurements`
- `perf: bound streamed markdown rendering`

Pixel-probe decision partially superseded by
[034](034-full-table-pixel-widths.md) on Emacs 31.

## Background

After 032, the `f61cef6` working-tree audit measured 1.317s of 2.024s inside
the Markdown formatter in face mirroring for 1,500 rich-text deltas. The
renderer then walked the same face runs again to add its base face. Besides
cost, this order made completed code blocks' `face` and `font-lock-face`
disagree: only the former included the assistant base face.

The table pixel-width boundary temporarily inserted text into the destination
buffer. Those edits entered undo history, and a measurement error skipped
deletion entirely. Its manual modified-flag restoration also requested a
mode-line refresh for each probe.

## Decision

Pass an optional base-face symbol into the formatter's existing final face
pass, and apply transcript metadata together afterward. Disable undo recording
around pixel probes, delete their exact span in `unwind-protect`, and restore
the modified flag without an explicit mode-line update.

## Why

The renderer still chooses the business face; Markdown only composes an opaque
face value. Appending it immediately before mirroring gives both properties
the same complete value and removes a second face traversal. The default nil
base face preserves standalone conversion behavior. Grouping read-only,
stickiness and event tags also replaces repeated native property walks.

Pixel probing needs the destination window's font context. Moving it to a
different buffer/window would require preserving remapping, metrics and window
state, so this change keeps that boundary and makes its temporary edits safe
for undo and errors. Exceptions still propagate. No font cache, scheduling
policy or global display setting is added.

## Consequence

Compared with 032 in a fresh three-sample median measurement, 1,500 rich-text
flushes fall from 4.210s to 2.720s; GC cycles fall from 32 to 19. Code-block
face consistency and successful/failing pixel probes have failing-before,
passing-after regressions. Probe tests preserve text properties, point,
markers, read-only state, undo history and both modified-flag states.

One thousand completed Elisp lines take about 14ms in batch; a 100-row,
four-column wrapping table takes about 103ms. These are fixture measurements,
not GUI guarantees. See [the audit](../docs/streaming-performance.md) for scope.
This record accompanies uncommitted changes against `f61cef6`, after 029–032.

## Known limitations

Partial-line scans and remaining property walks still revisit growing text.
Code highlighting and table layout remain synchronous. Pixel probes still
advance buffer change ticks and can invalidate display state even though their
text and undo effects are cleaned up. GUI pixel measurement was simulated at
its primitive boundary in unit tests; actual frame latency, font remapping
and Emacs 27.1 performance remain unmeasured.
