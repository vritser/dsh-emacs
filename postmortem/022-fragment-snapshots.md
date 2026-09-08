# 022 — Complete Fragment Snapshots

String-qualified identity and navigation superseded by 024; the snapshot
contract remains in effect.

## Background

At baseline `049f0a6`, the UI layer had separate writers for insertion,
body replacement, append, header updates and folding. Body writers assumed
bottom borders even for minimal rows and reused integer end positions after
editing. State omitted labels; nil could mean either retain or clear.
Render callers compensated by finding and tinting the block after updates.
The Bash terminal card introduced in that commit also needs header-only
state tint while preserving embedded body faces.

## Decision

Use complete alist snapshots and one fragment insertion path for updates
and folding. Keep fold state in the UI and content/faces in the supplied
snapshot. Remove unused group, append, header-only and restyle interfaces,
unused faces, and forwarding lookup helpers. Renderers supply concrete
whole-block or header faces; color-key remains opaque status metadata.
Renderers request spacing through a text property instead of the UI
recognizing user-message identity.

## Why

A full replacement matches current production callers and removes ambiguous
field merging and stale body geometry. Sharing the actual writer ensures
folding restores the same styling as initial rendering. A new component
hierarchy or state registry would add ownership and synchronization costs
without solving a current need. No incremental body API is retained without
a production consumer; assistant streaming already has a separate path.

## Consequence

Updates can clear content, flags and faces, retain fold state, and return
an exact range. Adjacent fragments and the input anchor survive resizing.
Extension callers must migrate to the documented snapshot contract; there
are no compatibility shims. Regression tests cover all three border styles,
growth/shrink/clear, collapsed updates, repeated fold restoration of faces
and text properties, flag clearing, bulk folding and input markers.
This record accompanies uncommitted changes against `049f0a6`.

## Known limitations

Updates still rebuild an entire visible fragment and lookup scans buffer
text properties. No index or incremental rendering is added without a
measured need. The existing viewport-follow heuristic and string-qualified
IDs remain unchanged. Render-layer activity-group bookkeeping is separate
legacy debt; removing the unused UI group API does not implement grouping
or remove its public renderer option. These are follow-up concerns, not
fallbacks inside the snapshot writer.
