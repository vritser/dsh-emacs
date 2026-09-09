# 035 — Scope Table Metrics to One Render

Implementation commit: `perf: streamline table layout measurements`.

## Background

The continuation after 034, against `f61cef6`, found font caches with mismatched
lifetimes: height scales were global per character, face ratios persisted in
the destination buffer, and space widths used only nominal font width as an
invalidation key. The height probe also switched the selected window to a
temporary buffer without the destination's face remapping. Repeating a render
after changing font metrics reused stale results.

## Decision

Share space widths, height scales and face ratios in a plist owned by one
table render. Pass the destination window through every measurement path.
Measure heights without displaying the work buffer on Emacs 29+, with a saved
window configuration for the Emacs 27.1 path.

## Why

A theme/font invalidation system would need to account for remapping, scaling,
faces and multiple frames. The actual reuse is within a table, so ending the
cache lifetime there removes the invalidation problem. The destination frame
also determines whether pixel measurement is available. ASCII characters in
mixed strings need no height probe; the variation-selector correction remains.

## Consequence

Tests reproduce two renders with different height metrics, require fresh space
and face measurements for each, and verify the destination window/frame.
Real graphical Emacs 31.1.50 measurements at text-scale levels 0/2 changed from
14/14 to 14/20 pixels for `A`, 16/16 to 16/23 for `中`, and 20/20 to 20/27 for
`🙂`: the old probe ignored scaling. The normal-size results agree.

No font-change hooks or global cache are introduced. This record accompanies
uncommitted changes against `f61cef6`, following 029–034. See the
[audit](../docs/streaming-performance.md).

## Known limitations

Existing rendered tables do not automatically reflow after font/window changes;
this fixes the metrics used by subsequent renders. Hidden-buffer layout uses
the existing fallback window. Older Emacs still needs temporary display for
height measurement and temporary insertion for width measurement. Actual 27.1
runtime performance is unmeasured. Existing character-width fallbacks on pixel
errors remain inherited compensating behavior and can conceal display failures.
