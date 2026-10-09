# 078 — Bound session-list updates to individual rows

_Unknown-catalog TAB discovery is superseded by [087](087-confirmed-child-expansion.md)._

## Background

The uncommitted session-list work after `68da9c6` (077) used a whole-buffer
text diff to preserve xref departure markers. Small fixture tests passed,
but opening a large host's list starved input. Batching the control baseline
removed repeated repaints, yet the user still observed pauses over ten seconds.

A private snapshot of the actual 534-session cache reproduced the remaining
problem in the renderer: regrouping its multibyte rows took 245 seconds, almost
entirely inside the whole-buffer diff. Unchanged-list benchmarks had missed
the expensive case. The default arrow also treated an unknown catalog as
evidence of children, causing misleading controls and unnecessary text changes.

## Decision

Match existing rows by identity, transpose surviving rows into their new order,
and limit text diffs to individual lines. Reapply fresh row properties afterward.
Only known nonempty catalogs display a subagent disclosure arrow. Explicit TAB
on an unknown catalog retains the asynchronous discovery workflow.

## Why

Emacs transposition moves markers with their text, including across workspace
reordering. This preserves navigation without searching the entire list for a
character-level edit sequence. Header and empty-workspace rows share an id, so
the row index distinguishes headers. Temporary index markers are always released.
Per-window identity and viewport restoration remain responsible for list focus.

A diff timeout would still spend an arbitrary budget and could erase navigation
markers on fallback. Erasing/rebuilding would restore the original xref bug.
Neither addresses the mismatch between row identities and whole-buffer diffing.

## Consequence

The same cached-list regrouping takes about 0.1 seconds; folding and expanding
take about 0.01–0.02 seconds. Tests bound diff scope and assert marker identities,
workspace order, metadata refresh and disclosure visibility. The existing
control-baseline batching remains in place. This record covers the working-tree
revision following 077; no commit has been made.

## Known limitations

Unknown catalogs have no arrow until the host projection or an explicit TAB
read confirms children. Removed rows cannot retain a meaningful return target.
Transposition still moves buffer text when rows reorder; performance is measured
for the actual cache size, not promised constant for arbitrarily large lists.
