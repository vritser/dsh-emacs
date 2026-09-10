# 039 — Region-Scoped Fragment Faces

## Background

The fragment snapshot carried two face slots: a whole-block `:face` and a
header-only `:header-face` (see [022](022-fragment-snapshots.md)).  Renderers
used `:face` for the row's state face — tool
pending/success/error/stopped and the Think accent — because that is the face
the collapsed row visibly needed.  `dsh-emacs-ui--render-fragment` then
applied `:face` with `add-face-text-property` across the whole rendered
string, so expanding a card painted its body with the row's accent: Think
reasoning text rendered orange bold, and a Read/Edit/grep ioCard rendered its
`IN` arguments and `OUT` result green, red or orange.  Bash cards were correct
only because they already passed `:header-face` and gave their terminal body
its own faces.

The first fix flipped the affected call sites to `:header-face`.  That left
the invariant guarded only by comments and tests at those eight call sites:
any future fragment (in-tree or an extension) could still pass its row face
as `:face` and reproduce the bug.

## Decision

Remove the whole-block face.  `dsh-emacs-ui-make-fragment` takes
`:header-face` (header row) and `:body-face` (expanded body); the two regions
are disjoint, and `dsh-emacs-ui--render-fragment` applies each face only
inside its own span — body lines, excluding the border chrome.  State faces
are always header faces.  A renderer that wants one content style on both —
the Think row's muted reasoning text — passes that face to both slots, with
the accent embedded on the label string so it still wins.  The same split
applies inside the header: `dsh-emacs-ui--label-merge` gives the bold
`dsh-emacs-ui-label-face` to the left label (title) only, so the right label
(summary) keeps its own or the header face instead of the title's weight.

## Why

The invariant belongs to the layer that merges faces, not to its callers.
Deleting the whole-block slot makes "a row/status face tints the body"
unrepresentable instead of merely discouraged, and keeps call sites
declarative: which region gets which face.

Rejected: keep `:face` and document "header only" — one forgotten call site
reintroduces the bug, which is exactly what happened.  Rejected: map
`:status` to faces inside the UI module — it would couple the fragment layer
to renderer face names, and `:status` is documented opaque metadata.
Rejected: a shared "state row" constructor for every tool/command row — it
dedups construction but still lets any other fragment tint its body, and it
adds a helper tier that does not own the face contract.

## Consequence

`dsh-emacs-ui-make-fragment` loses `:face`; unknown keywords now raise, so
out-of-tree callers fail loudly instead of silently losing styling.
`dsh-emacs-ui-label-face` is now the title face — the header's right label no
longer inherits its bold weight.  `dsh-emacs-thinking-body-face` styles the
reasoning preview and body; ioCard `IN`/`OUT` labels use
`dsh-emacs-tool-io-face` with a `dsh-emacs-divider-face` rule, and args/output
lines stay unstyled.  Docs and `CHANGELOG.md` are updated in the same change.
Tests pin the disjoint regions across all three border styles; both whole-block
mutations were observed red.

This record accompanies uncommitted changes staged against `89fca2c`.

## Known limitations

The live streaming Think block is hand-rolled for streaming cost
([027](027-thinking-refresh.md)) rather than a fragment, so it still repeats
the two face literals and must track the fragment slots by hand.  The
contract prevents accidental bleed, not deliberate misuse: a caller can still
pass a status face as `:body-face`.
