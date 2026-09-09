# 032 — Reduce Partial-Line Styling and Preserve Burst Following

Implementation commit: `perf: bound streamed markdown rendering`.

Partially superseded by [033](033-final-face-pass-and-pixel-probes.md):
base-face application now shares the Markdown mirroring traversal.

## Background

Continuing the `f61cef6` working-tree audit after 031, profiling a growing
plain paragraph attributed about half of Markdown time to emphasis matching
despite no emphasis delimiters. Rich-text streams also accumulated another
assistant base face on each formatting pass: after twenty deltas the first
bold word carried twenty-one copies. Recreating the yank handler modified
plain text even when a second formatting pass changed no visible content.

A separate renderer regression reproduced with a 100-line stream write:
following was decided after insertion, when the prompt had already moved
beyond the ten-row slack. First chunks, text/reasoning flushes and corrected
final messages could all lose a window that had been following before them.

## Decision

Skip emphasis matching before its first delimiter, add the assistant base face
only where absent, reuse a named yank handler, and capture following windows
immediately before stream edits for pinning after those edits.

## Why

The character preceding the first delimiter retains the old whitespace/BOL
grammar while excluding a prefix that cannot contain an emphasis opener.
This avoids a second incremental parser or delaying visible inline styling.
The base face is a renderer invariant, not a layer to append on every pass.
A constant callback registration preserves plain paste without property churn.

Following is a decision about the pre-edit viewport. A short-lived window
list carries that decision across the synchronous write; saving it when a
timer is scheduled would override a subsequent user scroll. Increasing the
slack merely moves the failure threshold. No persistent follow mode, hook,
extra timer, transport scheduling change or global GC adjustment is needed.

## Consequence

In three-sample median batch measurements of 1,500 flushes, a plain paragraph
falls from 1.60s to 0.93s; repeated bold text falls from 11.20s to 3.92s, with
GC cycles falling from 207 to 34. The assistant base face stays single.
Tests first failed on redundant emphasis work, property churn, face growth
and each of the five large-write paths. One thousand generated Markdown
cases also retain identical text and faces versus the 031 formatter.

This record accompanies uncommitted changes against `f61cef6`, after the
uncommitted work in 029–031. See [the audit](../docs/streaming-performance.md)
for workloads and scope. The events module changes only its renderer function
declaration; event delivery and RPC behavior are unchanged.

## Known limitations

Partial-line scans and property walks still grow with the unfinished line;
the improvement removes redundant work rather than proving linear total cost.
Final table layout and code highlighting remain synchronous. GUI redisplay,
pixel scrolling and Emacs 27.1 performance have not been measured. Non-stream
event renderers still use their existing post-edit following paths and slack;
the pre-edit capture here belongs to live assistant/reasoning stream writes.
