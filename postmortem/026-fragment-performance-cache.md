# 026 — Fragment Performance Cache

## Background

After `6741dc9` and the uncommitted middle-span work in 025, fragment lookup
still scanned from the buffer end, no-op updates still rendered large bodies,
and the suffix walk compared every character in Lisp. Whole-block property
replacement also rewrote unchanged body styling when only a title changed.

## Decision

Cache identity lookup with a buffer-local start marker and state reference.
Validate each hit against text properties, refresh after successful edits,
release deleted entries, invalidate on erase/undo and bypass while narrowed.
Use the last successful buffer change tick, width, separator and copied
snapshot to skip identical renders. Find the common suffix with bounded
native substring comparisons and update only differing visual-property runs.

## Why

Measurements now justify a small cache; text properties remain the source
of truth. A start marker avoids adjacent-block end-marker insertion rules.
Publishing after an atomic edit prevents failed writes from caching a state
that never became visible. Undo can restore a later duplicate identity while
an earlier marker remains valid, so marker validation alone is insufficient.
The buffer change tick conservatively invalidates render reuse after external
edits. Copying caller-owned strings is required for snapshot comparison.

## Consequence

Tests cover no repeated scan/render, mutable input strings, unchanged body
styling, property-write rollback, delete/recreate/fold, external edits,
duplicate ordering, undo, narrowing, buffer isolation and separator changes.
The public snapshot API and Emacs 27.1 baseline are unchanged. This record
accompanies uncommitted work against `6741dc9` and records 024–025.

Batch measurements on macOS, Emacs 31.1.50, median of three runs with GC
included (GC forced before each sample), comparing the working tree at the
start of this audit with the completed changes:

| Workload | Before | After |
|---|---:|---:|
| 500 lookups of oldest card in 1000-card buffer | 510 ms | 0.79 ms |
| 50 identical updates, expanded 5000-line body | 170 ms | 0.37 ms |
| 50 title changes, expanded 5000-line body | 1612 ms | 311 ms |
| 50 title changes, collapsed 5000-line body | 1.03 ms | 2.31 ms |

The collapsed-title workload adds about 0.026 ms per update from cache and
snapshot bookkeeping. A 500-chunk plain assistant stream with a flush after
each chunk remained in the same range (71 ms before, 63 ms after); it already
uses an independent incremental path. These are synthetic batch timings,
not GUI latency promises or measurements on Emacs 27.1.

## Known limitations

Cold/stale and narrowed lookups still scan. Changed cards still render their
full text, and the state property is refreshed across the block; visual
properties are patched selectively. The cache does not introduce another
render tree, incremental Markdown parser or resize hook. Extension writers
should use the fragment API; removing identity text properties removes that
text from fragment ownership. The independently documented unfinished
Markdown fence/table costs are outside this fragment optimization.
