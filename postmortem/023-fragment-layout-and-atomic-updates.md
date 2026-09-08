# 023 — Fragment Layout and Atomic Updates

## Background

The complete-snapshot work in record 022, against `049f0a6`, unified fragment
state but retained independent border-width calculations, header keymap
overrides and delete-before-render updates. A narrow title could lose space
to its summary; errors during redraw could remove the original card.

## Decision

Measure the displaying window once per render and share the body-column
budget across header, body and footer. Fit the main title before the summary.
Respect embedded keymaps, local maps and buttons, supplying folding only on
passive label spans. Build the complete propertized string before editing,
then replace text inside Emacs's atomic change group for updates and folds.

## Why

The model already carries the necessary text and styling. Preserving stock
Emacs interaction properties avoids inventing a header component protocol.
One width budget removes duplicate spacing calculations and accounts for
the actual displaying window instead of the selected window. Pre-rendering
protects the old card from rendering failures; atomic replacement also
covers failures after text insertion and spacing cleanup. Exceptions still
propagate, so failures remain visible at the existing command/event boundary.

## Consequence

Titles are prioritized, custom actions survive folding and updates, and
failed replacements leave the transcript and input anchor intact. Bordered
headers use compact corner/indicator framing to share the body/footer width.
Tests cover all three styles, Chinese titles and narrow widths, custom
keymaps, and injected failures in both rendering and insertion for create,
update and fold. This is uncommitted work against `049f0a6`, following record
022; it retains that record's full-snapshot model.

## Known limitations

Long body lines are preserved rather than truncated. Existing cards reflow
on update/fold, not automatically when a window is resized; a buffer shown
in multiple windows still has one textual layout. Full-string rendering uses
temporary memory proportional to the card size. Atomic change groups cover
buffer edits, not arbitrary external effects of third-party change hooks.
