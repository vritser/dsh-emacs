# 028 — Deferred Streaming Markdown Render

## Background

The renderer based on `6741dc9` reformatted the live assistant body on every
coalesced flush. `--set-watermark` backs the safe frontier off to the start of
the oldest open fence and to a table that might still extend, so a growing
block was re-parsed from its start on each chunk: `--source-block-ranges` and
the other passes rescanned the whole unfinished block, and an extending table
was re-rendered (row folding) per flush. Detection cost grew with the block,
not with the new text.

## Decision

Give the live stream an explicit render frontier.
`dsh-emacs-markdown--stream-end` advances a stream-owned scan marker over
newly completed lines and returns the position where rendering may stop: the
start of an unfinished fence or table, the start of a partial fence/table
line, otherwise `point-max`. `dsh-emacs-markdown-replace-markup` narrows to
that frontier, so an unfinished block stays raw until it ends; its `FINAL`
argument releases the scan markers and renders the tail.
`dsh-emacs-render--flush-stream` grew a FINAL argument, and every stream
teardown (turn end, disconnect, reset, stream switch) flushes with it.

## Why

Stopping at the block start makes per-chunk cost proportional to the new text
instead of the accumulated block, without a diff, an incremental renderer, or
a second parse of already rendered text. Deferring the whole block — rather
than rendering a partial one — is what makes a single narrow possible: a
partial fence has no body boundary to render, and a partial table would be
folded in again by the next row. Rejected: an incremental table folder (more
state, the same repeated face work per row) and advancing the frontier past an
open block by freezing rendered lines (a later chunk could then never complete
a construct split across the boundary).

## Consequence

While rows are still arriving a table shows its raw `| … |` text and renders
in one pass at the next non-table line or the final message. A fence shows raw
until its closing fence arrives — unchanged from before, since an unterminated
fence was never rendered. Text before the pending block keeps its previous
render. Tests cover the deferred table (no reflow while streaming, one render
at finalization), incremental fence scanning, text-and-face parity of chunked
versus one-shot rendering across chunk sizes, and the four finalization
boundaries. This record accompanies uncommitted changes against `6741dc9`.

## Known limitations

The frontier is line-granular: the last, still-growing line is re-rendered on
every flush until a newline arrives, so a construct split across chunks is
styled only once its closing marker lands. A block that never ends (a provider
that stops mid-table or mid-fence) stays raw until the stream is torn down.
