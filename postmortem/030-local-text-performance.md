# 030 — Reduce Repeated Draft and Table Work

Implementation commit: `perf: avoid copying drafts for reference detection`.

## Background

After the uncommitted stream work in 029, against `f61cef6`, two local paths
still repeated expensive work. Reference detection copied the full draft and
ran two forward regex searches on each check; the typing watcher called it
twice when a token changed. A 100-row table's profile showed 43,015 character
width calls: fit checks measured the full cell, then wrapping measured each
accepted character twice and revisited words at line breaks.

## Decision

Parse references directly between the input start and cursor. The last quote
determines whether the quoted grammar can match; otherwise scan backward to
the last whitespace boundary. Copy only the token and query. Measure table
character widths into a temporary vector and reuse them through wrapping.

## Why

Both optimizations remove repeated work without introducing persistent state.
The quoted reference grammar has precedence and may span whitespace or newlines;
looking only at the last word would change it. Buffer bounds exclude transcript
text and text after the cursor. Table widths depend on character and face,
so a per-call vector preserves the existing measurement rules without another
cache invalidation policy. The now-unused total-width wrapper is deleted.

## Consequence

Reference grammar, completion behavior and table layout remain the same.
Regression assertions enforce bounded draft copying and one width measurement
per character. Tests cover quoted paths, input/cursor bounds, Chinese, emoji,
combining marks, tabs, narrow columns and preserved text properties. A separate
temporary comparison of 3,000 generated token cases and 3,000 wrapping cases
matched the old implementations, as did a complete styled table.
This record accompanies uncommitted changes against `f61cef6` and record 029.

Median of three macOS Emacs 31.1.50 batch samples, interpreted package code,
GC included and forced before each sample:

| Workload | Before | After |
|---|---:|---:|
| 1,000 token checks after a 100,000-character draft | 299 ms | 66 ms |
| GC cycles during each token sample | 10 | 0 |
| Ten renders of a 100-row, four-column wrapping table | 706 ms | 546 ms |

The token input is 100,000 `a` characters followed by ` @some/path`. Each
table data row has cells `Long cell with several words to wrap`,
`**Important value** and ordinary text`, `Another long entry with wrapping`,
and `More words to fit in a column`, below a four-column header and separator.

## Known limitations

Finding the last quote can still scan the draft; the change removes full-draft
allocation and repeated forward regex work, not all scanning. Width vectors
use memory proportional to the cell's character count. Existing font-width
caches and GUI pixel measurement remain unchanged; batch timings do not measure
GUI redisplay. Completed code-block highlighting and table layout still run
synchronously. First-time reference discovery can also wait for the server;
this change is confined to local token detection, with no RPC changes.
