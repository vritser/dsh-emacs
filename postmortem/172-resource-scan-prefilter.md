# 172 — Skip plain runs in the inline resource scan

## Background

Every Markdown flush calls `dsh-emacs-markdown--inline-resources` to find
links and images before prose styling consumes their punctuation. The scan
walked the buffer one character at a time and asked
`dsh-emacs-markdown--in-avoid-range-p` at each position, even where no
resource could begin. In a 32 KB reply without links it was the largest
single pass in the Markdown work. Streaming amplified it: each flush rescans
the ready region, so a long paragraph without a line break paid the whole
scan again per delta (see [036](036-bounded-stream-markdown.md)).

## Decision

Skip runs that cannot start a resource. At a line start or a `[`, `!`, a
backtick or a backslash the scan keeps its per-position branches; everywhere
else it advances in one `skip-chars-forward` call.
The scan ignores `field` properties so a display field boundary cannot stop
line motion before the actual newline and leave the scan without progress.

## Why

Only those positions can begin a link, image, code span or escape, and only
line starts can begin a bare image path. Avoid-range and frozen handling
matters only where one of those branches could fire, so skipping the rest
cannot change what is rendered; it removes the per-character lookup instead.

A prototype that also prefilted the bold matcher — a literal `**`/`__`
search followed by an anchored content match — measured neutral or worse.
Splitting the engine's single scan into two searches added work per
candidate, and that pass spends its time in the per-span edit, not in
candidate selection. The idea was dropped.

## Consequence

Rendered output is unchanged. 800 randomized documents with links, images,
tables, code spans and escapes kept identical text and text properties, and
a link at end of line still moves past the newline.

Byte-compiled, 7-sample medians on one machine:

| Workload | Before | After |
|---|---:|---:|
| 49.6 KB, 500 links, one render | 42–44 ms | 37–38 ms |
| 32.7 KB, no links, one render | 23 ms | 18 ms |
| 32 KB, no links, before the Unicode bold fix | 19–20 ms | — |
| 1,500 `**bold** text` deltas, newline per delta | 82–83 ms | 80–88 ms |
| 1,500 `**bold** text` deltas, no newline | 1.30–1.41 s | 0.49–0.52 s |

The line-per-delta stream is unchanged because its scan interval is small;
the long partial line is where the repeated scan dominated. Interpreted
sources show the same shape more strongly (5.1–5.7 s to 0.86–0.97 s for the
no-newline stream).

The regression test counts avoid-range checks for a plain document: one per
line start and interesting character instead of one per buffer character. It
fails against the previous scan.

`scripts/verify.sh` passes.

Implementation: resource-scan optimization and field-boundary regression fix
in `dsh-emacs-markdown.el` and `test/dsh-test-markdown.el`, based on `1bb3d8d`.

## Known limitations

The scan still visits every line start and each `[`, `!`, backtick or
backslash, so text dense with links gains less than plain prose. The numbers
are batch render costs, not GUI redisplay times, and vary with the machine.
