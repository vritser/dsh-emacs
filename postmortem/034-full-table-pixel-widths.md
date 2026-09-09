# 034 — Full Table Pixel Widths Without Destination Edits on Emacs 31

Implementation commit: `perf: streamline table layout measurements`.

Height measurement and cache lifetime limitations are addressed by
[035](035-table-render-metrics.md).

## Background

The continuation of 033 against `f61cef6` reproduced a Markdown measurement
bug in an isolated graphical Emacs. `window-text-pixel-size` defaults to a
window-width limit: 500 `W` characters measured 560 pixels, although their
full width was 3500 pixels, or 5000 after two text-scale increments. This
understates the natural width of long cells taking the pixel measurement path.
Temporary probes also advance the destination buffer's change ticks.

## Decision

Measure the complete string. On Emacs 31, use the public `string-pixel-width`
buffer argument with the target window temporarily selected. Earlier versions
keep the contained insert/measure/delete path with an unlimited X limit.

## Why

The installed Emacs source and NEWS confirm that `string-pixel-width` arrived
in 29, but its buffer argument preserving face remappings arrived in 31.
Checking only function availability would call an unsupported signature on
29/30. A major-version guard plus an availability check keeps the 27.1 baseline
and avoids recreating Emacs's work-buffer/font-context machinery locally.
Selecting the target window lets the primitive use its frame; the standard
macro restores the original selection afterward.

## Consequence

Real GUI probes agree across the modern and corrected fallback paths for
spaces, Latin text, Chinese, emoji, bold, variable-pitch text, long strings,
and text scale levels 0/2. For 1000 short mixed-text measurements, median
elapsed time is about 5.8ms before versus 5.3ms on the modern path. The material
gain is that destination character-change ticks stay unchanged instead of
advancing by 8000 in this fixture. No redraw frame-time claim follows from
these measurements. Regression tests cover full-width query bounds, target
buffer/window context, preserved selection and unchanged modification ticks.

This record accompanies uncommitted changes against `f61cef6`, following
029–033. See the [audit](../docs/streaming-performance.md) for measurement scope.

## Known limitations

Older Emacs versions still temporarily edit the destination during pixel
measurement. Their path was exercised on Emacs 31 with the version branch
forced, not on an installed Emacs 27.1 runtime. Height-scaling probes and
their caches are separate and unchanged. GUI samples use one frame and the
default fonts; arbitrary themes, other frames and full redisplay latency were
not benchmarked. Partial-line formatting and final block layout retain the
limits recorded in 031–033.
