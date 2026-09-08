# 024 — Fragment Identity and Local Navigation

Lookup-scan limitations superseded by 026; separate identity components and
local navigation remain in effect.

## Background

At baseline `049f0a6`, fragment identity joined namespace and block ID with
a hyphen. Distinct pairs such as `("a-b", "c")` and `("a", "b-c")` therefore
collided. The snapshot and layout work in records 022–023 retained this
limitation. Local folding and navigation also searched the buffer by identity
even though the relevant fragment was already at point.

## Decision

Keep both identity fields in the snapshot and compare them separately.
Lookup and deletion accept namespace and block ID as two positional arguments.
Local actions derive bounds from the state property's contiguous range;
bulk folding advances by those boundaries.

## Why

The model already owns both fields, so encoding a composite string creates
ambiguity without adding information. Local boundaries remove repeated
global searches without an index, cache invalidation, or another registry.
Renderers delegate command-card deletion to the existing UI owner.

## Consequence

Hyphenated identities remain independent during creation, replacement,
lookup and deletion. Adjacent cards remain reachable through navigation,
and bulk folding preserves non-foldable cards. Extensions must migrate
lookup from joined strings and deletion from keyword arguments; no shims
are retained. Regression tests exercise distinct colliding spellings and
verify local actions perform no identity lookups.
This record accompanies uncommitted changes against `049f0a6`.

## Known limitations

Lookup still scans text properties. Callers must use unique identity pairs
for independently addressable cards; `:create-new` deliberately bypasses
lookup. No automatic window-resize reflow or fragment index is introduced.
