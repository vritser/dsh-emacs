# 057 — Unchanged context in file diffs

## Background

At `d0626c7`, the renderer followed decision [045](045-read-and-diff-tool-cards.md):
an edit card printed every old line in red and every new line in green.
Changing one word in a seven-line argument therefore painted fourteen rows
and reported `+7 -7`. This belongs to the renderer: the arguments and applied
metadata already supply both texts, but the card never compared them.

The reported screenshot also contained literal `+` characters accidentally
written into `CHANGELOG.md`. Those are source text, not duplicate UI markers;
the document was repaired without teaching the renderer to strip source signs.
This record accompanies the uncommitted diff-display change against `d0626c7`.

## Decision

Align each hunk's lines in `dsh-emacs-render.el`. Matching lines appear once
as neutral context; only deletion and insertion rows carry the existing
red/green faces and contribute to totals. Pending and settled cards share
this path. Keep the path rows, hunk gaps and plain transcript background.

Remove the common prefix and suffix before computing a longest common
subsequence for the middle. Limit its table to 262144 cells. Above that
limit, preserve the matched edges and explicitly label the middle as an
unaligned replacement; its totals count the displayed old/new rows.

## Why

Line alignment exposes the actual edit while preserving the surrounding
text needed to read it. Trimming edges makes a small edit in a large block
cheap; the table handles unchanged lines between separate edits too.
Existing faces suffice, and a local Elisp comparison keeps the Emacs 27.1
baseline without external executables, temporary files or subprocesses.
The bounded table avoids unbounded quadratic work in the event renderer.

## Consequence

`one / two` becoming `ONE / two / three` shows `two` once and reports
`+2 -1`, rather than `+3 -2`. Tests first reproduced the old totals, then
covered pending and settled cards, neutral context, insertions, deletions,
repeated lines, blank lines, literal signs, Unicode and the large-middle
limit. README, UI styling docs and CHANGELOG describe the new display.
No commands, options or faces were added.

## Known limitations

The explicitly marked large-middle replacement is bounded-work design debt:
common lines inside that middle can still appear in both halves and count
in both totals. A more scalable alignment could remove that limit later.
All supplied context remains visible, and highlighting is per line, not per
word. Existing rendered cards keep their snapshots until rebuilt; loading
the new renderer alone does not rewrite already displayed history.

The cap bounds the work but does not make it free: the largest accepted
middle (511×511 lines, the full 262144-cell table) measured about 105 ms in
a batch run. That cost is the table walk itself, not the cell comparison —
mapping lines to integer ids and flattening the table to a single vector each
changed the time by under 10% — so the cap is the only real lever. It sits at
262144 so a large middle with scattered edits still aligns; lowering it would
trade that display for a shorter worst-case pause.
