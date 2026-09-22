# 056 — One transcript region per protocol block

Implementation commit: `fix: isolate streamed thinking blocks`.

Status: Complete.

## Background

The live renderer keyed its streams by turn/step (`dsh-emacs-render--stream-key`)
and kept at most one live assistant body and one live Thinking body per step.
A step, however, is a sequence of protocol blocks (`block-start` /
`block-end` with `blockType` text or reasoning), and the renderer inferred block
boundaries only from the turn/step key.

That broke whenever a step interleaved text and reasoning.  A reasoning block
inserted mid-stream landed at the text stream's tail, inside its `:start`/`:end`
span and behind its Markdown watermark, with two consequences:

- the next text flush ran the Markdown passes over the reasoning text, so a
  table or fence inside the thinking was rewritten as a rendered card — line
  breaks inserted into the Think body while the model was still thinking;
- the live Thinking body's `:end` marker advanced past the text that followed
  it, so its span covered the answer.  `--replace-live-thinking-text` then
  deleted the Think body *and* the answer at `assistant/message`, and the
  repair path made it worse: the whole span was replaced by the concatenated
  authoritative text.

The failing layer is render (`dsh-emacs-render.el`): the stream/block model, not
the Markdown formatter (postmortem/055) and not the event layer.

## Decision

Each protocol block owns its own transcript region.  One live assistant body
and one live Thinking body exist at a time, and starting one kind closes the
other before the new block is inserted:

- `--close-live-text-block` flushes the live text body, renders its tail
  (closing an unfinished fence or table), records it on the step
  (`--step-record`, `:text` + `:text-regions`) and detaches the stream;
- `--close-live-thinking-block` folds the raw Think body into its fragment
  (`--replace-live-thinking-text` with the text it streamed) and records it
  (`:reasoning`).

`dsh-emacs--streamed-step` is the per-step record of what has already been put
on screen.  `assistant/message` reconciles against it: text and reasoning that
already rendered are left alone, only the part that is still missing is
appended or repaired, and a genuinely divergent authoritative body drops the
finished text bodies (`--drop-committed-text`) before it replaces the live
segment.  The record is cleared with the buffer reset and after the message.
Committed content uses the same newline separators as the authoritative
message. Closed text blocks keep their stream states until reconciliation,
so queued Markdown work owns the same bounded regions and can be cancelled
when a correction drops them. Block transitions never wait synchronously
for pending keyboard input to disappear. Raw Think headers, bodies and
separators are read-only from the first chunk.

Boundaries are driven by the deltas (`text-delta` vs `reasoning-delta`), so a
missing `block-start` cannot merge two blocks.

## Why

The alternative — keep one body per step and shield the reasoning text with
`dsh-emacs-markdown-frozen` / avoid-ranges — leaves the deeper defect: the live
Thinking body still spans the answer, so finalization and repair still delete
it, and a second reasoning block still appends to the first (inserting lines
above text already shown).  Shielding would also require teaching
`--source-block-ranges` and `--style-source-blocks` to honor frozen ranges,
which is a workaround for a region that should never have been shared.

Building each block as a fragment from the start (stream the Think body as a
UI fragment) would re-render the whole fragment per delta, the churn this
series of fixes exists to remove.

Accepted tradeoff: a step can now show several `Think` fragments instead of one
merged body, and the step record adds buffer-local state that must be cleared
with the streams.  A divergent authoritative body still rewrites the live
segment (and drops the finished text bodies) — repair is the point of that
path, and it is rare.

## Consequence

A step with text–reasoning–text reads in arrival order, a reasoning block folds
as soon as the answer starts instead of at the end of the step, and the final
message neither rewrites the Think body nor deletes it.  `assistant/chunk`
dispatch, `--start-assistant-stream`, `--start-thinking-stream`,
`--finish-assistant-stream` and `assistant/message` carry the boundaries;
`--stream-render-region`'s Markdown machinery is unchanged.

Docs: `CHANGELOG.md` (Fixed) and the stream paragraph in
`docs/architecture.md`.  Tests: `thinking-body-keeps-raw-markdown`,
`thinking-blocks-stack-in-arrival-order`,
`thinking-interleaved-final-keeps-every-block`,
`thinking-final-does-not-repaint-committed-text` and
`thinking-two-blocks-survive-a-divergent-repair` pin the block model.

## Known limitations

Non-live rendering (history, loaded pages) still renders all reasoning first
and the joined text after it, so it does not reproduce the live interleaving
order.
