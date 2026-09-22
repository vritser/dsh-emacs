# 055 — Append-only streamed rendering

Implementation commit: `fix: render streamed code blocks incrementally`.

Status: partially implemented — fences are append-only; extending tables still
re-render their rows (see Known limitations).

## Background

A live reply is rendered incrementally: text deltas are inserted into the
transcript, then the Markdown formatter rewrites the *unstable* tail — the
last, still-incomplete line plus any unfinished fenced block or extending
table.  `docs/streaming-performance.md` documents that split, and
`dsh-emacs-markdown--set-watermark` keeps the frontier at the start of an open
fence or an extendable table so their closing fence / next row can still be
matched.

The visible consequence, reported as "the content can be modified during
output — for example, by inserting line breaks": a code fence streamed as raw
source and was replaced by its card only when the closing fence arrived, which
inserted the card's blank padding lines *above* body text already on screen
and shifted everything below it; an extending table re-padded and re-boxed
every earlier row on each new row and inserted the `├───┼───┤` separator line
only when the table settled.  Settled text (anything behind the watermark) was
already never touched — the churn was entirely in the displayed-but-unstable
region.

## Decision

Rendering a streamed block is append-only: block chrome is written when the
block *opens*, content is appended as it arrives, and a flush never rewrites
text the user has already seen.

For a fence this means: when the opening fence line completes, the formatter
deletes that line and writes the card header (top panel line, label, middle
panel lines) immediately — before any body line exists — and remembers the
open block in the Markdown stream state (`:open-block`, with the language,
fence width, body-start marker and `line-prefix`).  The body then streams raw
inside the card; each flush styles only the lines that arrived since the last
call (`dsh-emacs-markdown--apply-source-block-body` — properties only, never
text) and `--set-watermark` keeps the frontier at the body start without any
range scan.  When the scanner sees the closing fence, `--close-source-block`
consumes that fence line, appends the bottom panel line and layers the
language's face properties.  A message that ends inside an open block
finalizes it the same way, without a closing line.

The open block spans more than the live path.  A flush past
`dsh-emacs-stream-markdown-limit` is rendered into a temp buffer and diffed
into the transcript; that render opens the card there, and `--run-markdown`
then hands the block (language, fence width, prefix, body-start marker rebased
to the transcript) to the live Markdown state so the next flush keeps
streaming the same card instead of re-reading the body as Markdown.  The
hand-off is one-way: an open block is never deferred again, because its flush
only styles the characters that just arrived and the idle queue has nothing to
buy.  `--reset-markdown-state` drops the block together with the scan markers
it was opened against, which is what lets a repaired final body re-render from
scratch. The scanner flags `:closed` when it consumes the closing fence and
stops there. After closing the card, formatting resumes in the remaining
tail of the same flush, so following prose or another code block is rendered
without re-reading the finished card. Reply separators remain read-only
through streaming and deferred formatting, just like the body.

## Why

The alternative — hold the whole block raw until it completes and render the
card then — is what produced the reported churn: the card's padding lines are
new text, so writing them at the *end* inserts line breaks into content the
user is already reading.  Writing them at the *start* is free: nothing below
the opening fence exists yet, so the chrome can only append.

The open block has to live in the stream state rather than in the text: the
one thing the old design leaned on — the raw opening fence staying in the
buffer to be re-matched on every scan — is exactly what eager rendering
consumes.  Keeping the block's identity in the state also makes a flush inside
it cheaper than before (no range scan at all; measured 9 characters scanned
for an 80-row streamed block, against one full scan per flush previously).

Rejected alternatives: keeping the raw text visible and only deferring *some*
chrome still inserts line breaks above shown text; hiding the unfinished block
until it settles keeps the transcript stable but loses live output; rendering
the body into a display overlay instead of buffer text preserves liveness but
reworks the stream/finalize path (markers, follow-stream, final-message
repair) for a display-level gain.  Where a construct genuinely cannot be
appended (a later table row widening a column would re-pad earlier rows), the
table keeps its current behaviour until the same treatment is applied to it.

## Consequence

A streamed code block now shows its card as soon as the fence line completes;
the body fills in below it, is highlighted when the block closes, and no line
break is inserted above its already displayed body. Partial lines still
settle when their newline arrives, and extending tables retain the limitation
below. Tests updated: the
open-fence performance tests now assert zero scans per body flush and the card
being present at the opening line, and new tests pin the append-only body
(`stream-open-fence-body-appends-without-rewriting`,
`stream-close-appends-below-the-body`), the deferred hand-over
(`stream-deferred-open-fence-hands-over-the-block`,
`stream-deferred-open-fence-keeps-the-body-raw`), a repaired final body
(`stream-forced-final-repair-formats-the-body`) and a closing fence followed
by the next opener in one flush (`stream-closer-closes-before-the-next-opener`,
`stream-closer-and-next-opener-in-one-flush`).  The Markdown parity tests still hold:
a streamed conversion ends byte- and face-identical to a one-shot one.
`CHANGELOG.md`, `docs/streaming-performance.md` and `docs/architecture.md`
describe the behaviour.

## Known limitations

Extending **tables** still follow the old pattern: rows stay raw until the
table settles and are then boxed together, so a table's separator line and
re-padded cells are still inserted into already-displayed rows.  The same
policy applies — box the header from its separator row with widths fixed
there, then append each following row — but it needs a per-row render path
(`--render-table-data-row` with stored widths) and its own stream state, which
is not implemented yet.

A fence that opens and closes within a single flush still takes the one-shot
path (open then immediately close), which is fine because none of it was
displayed before.  An open block's body is not re-formatted if a later chunk
would have changed its Markdown meaning — by design: it is code, and the
message's final `assistant/message` rendering repairs a body whose text
differs from what streamed.
