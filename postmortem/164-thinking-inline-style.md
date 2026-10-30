# 164 — Inline Think rows

## Background

Live reasoning rendered as a raw body under the ✶ Think header. When the first
answer text block started, `dsh-emacs-render--close-live-thinking-block` folded
that body into a collapsible fragment at the boundary, and the authoritative
assistant message reconciled reasoning in one of two ways: unchanged blocks
were left alone, while corrected reasoning ran
`dsh-emacs-render--drop-committed-thinking` and re-rendered **all** reasoning as
one merged row before the answer.

The first shape differs from dsh web. A dsh web assistant message is a block
list, and each reasoning block is an independent inline disclosure at its own
position: collapsed to one row (Think icon, title, summary, chevron), previewing
the first line of the latest completed paragraph while it runs and the first
line once settled, expandable in place. The corrected-merge path also moved
reasoning that had been read inline to the top of the answer, so the transcript
could reorder itself after the turn settled.

Commits: pending (no commit requested).

## Decision

Add `dsh-emacs-thinking-style` with two values, default `expand`:

- `expand` keeps the existing streamed body and fold.
- `inline` renders one collapsed minimal fragment from the first reasoning
  delta. Its body is a deferred closure, so a collapsed row never lays out the
  growing text; each 100 ms flush updates the same row in place. The preview is
  the first line of the latest completed paragraph
  (`dsh-emacs-render--thinking-live-preview`), matching dsh web's advancing
  summary, and settles to the existing first-sentence preview when the block
  closes. A row without a preview shows the label alone; no start clock is
  rendered. Every row starts collapsed; the reader opens it with the normal
  fragment fold gesture, and that fold state survives later updates.

The final assistant message reconciles inline rows with
`dsh-emacs-render--reconcile-inline-thinking`: one streamed row per final
non-empty reasoning block is updated in place, preserving both position and
fold state. A correction that adds or removes a reasoning block falls back to
the old single folded row, which still lands before the answer. Teardown
deletes a live inline row through the fragment API instead of the raw
`start`/`end` markers used by the expanded body.

## Why

The option exists because the two shapes trade visibility against compactness.
Some readers watch the reasoning evolve; others want the web's one-line
disclosure so the answer text owns the screen. Making one the only behavior
would remove a reading mode rather than add one, and dsh web's shape is the
reference for the compact mode.

Inline mode reuses the fragment renderer instead of adding a second inline
renderer inside assistant Markdown. That keeps Markdown regions, block
identities, fold state, tests and teardown in one place, and avoids inserting
reasoning text into the assistant stream's Markdown scan. The deferred body
keeps a collapsed live row cheap: only the header and preview are laid out
while the body grows. In-place reconciliation is what makes the row genuinely
inline; keeping the merge would leave corrected turns reordered above the
answer, which is the behavior this option is meant to avoid.

Rendering the body as Markdown (as dsh web does when expanded) was deferred:
fragment bodies are plain text and re-parsing every reasoning flush would put
the Markdown scanner behind the 100 ms reasoning batch. A separate
`dsh-emacs-thinking-inline` boolean was rejected because it would create two
independent switches for one presentation choice; the style value carries the
live shape. The old `dsh-emacs-thinking-expand-by-default` switch is removed
for the same reason: it only described the settled fold of `expand`, leaving
`inline` with a dead option. Think rows now always start collapsed and keep the
reader's fold state.

## Consequence

Users can set `(setq dsh-emacs-thinking-style 'inline)` and get a collapsed,
web-like Think row that previews the latest completed paragraph and stays put
when the answer arrives. `M-x customize-group RET dsh-emacs-render` exposes the
option next to `dsh-emacs-show-reasoning`. The default rendering is unchanged;
users who set the removed `dsh-emacs-thinking-expand-by-default` must open a
row once to read its body.
`docs/customization.md` and `docs/architecture.md` describe the two shapes, and
`CHANGELOG.md` links here. New tests cover the collapsed live row and its
previews, in-place correction across two blocks, and discard of a live inline
row; the existing stream tests continue to cover `expand`.

## Known limitations

- A correction that adds or removes a whole reasoning block still falls back to
  one folded row before the answer; only count-preserving corrections stay
  inline.
- Reasoning that never streams (it appears only in the authoritative message)
  is still rendered as one folded row before the answer, because no row
  position exists to update.
- The expanded body is plain text with the thinking body face, not Markdown
  with secondary typography as in dsh web.
- An expanded inline row is re-rendered on every 100 ms reasoning flush; a long
  open body costs more than the collapsed row.
