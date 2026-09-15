# 045 — Read and file-mutation tool cards

## Background

At the `233bdfb` baseline only bash/pwsh had a bespoke expanded body (the
terminal card, `dsh-emacs-render--bash-card-body`); every other variant fell
through to the generic ioCard (`dsh-emacs-render--tool-body-io`), whose `IN`
is the call's pretty-printed argument JSON and whose `OUT` is the result text
verbatim.  Two variants read badly: a `write`'s `IN` dumped the file's entire
new content into the transcript (an `edit`'s showed `old_string` /
`new_string` as escaped JSON), and a `read`'s `OUT` repeated the result
envelope (`<path>` / `<type>file</type>` / `<content>` tags) along with the
tool's own `(Showing lines N-M of T …)` footer.

The wire already carried structured alternatives: `tool/result.data.meta` holds
`{path, offset, lines:[{number,text}], totalLines, lang}` for a file read and
`{diffs:[{path, oldText, newText}]}` for a `write`/`edit`, distinct from the
flattened `message.content[].content[].text` the renderer was reading.  dsh web
consumes exactly those fields — `readCardModel` / `diffCardModel` feeding its
`ReadBlock` / `DiffBlock` primitives.

## Decision

Mirror dsh web's read and diff card models in `dsh-emacs-render.el`, keep the
ioCard as the fallback for everything they decline, and draw every expanded
card on the plain transcript background — no card surface band.

- `dsh-emacs-render--read-card-body` renders the `read` tool name only: the
  file's lines with their numbers right-aligned in a muted gutter, plus a
  `Showing N of M lines` footer when the window is partial.  It requires the
  settled `data.meta` **and** a matching `<type>file</type>` envelope.
- `dsh-emacs-render--diff-card-body` renders `write` and `edit`: a bold path
  row per file, `⋯` between hunks of one file, `- text` / `+ text` lines, and
  the `└ +N -M · K file(s)` footer.  While the call runs it draws the diff
  the arguments intend (`--diff-args`); once settled the applied `meta.diffs`
  win (`--diff-hunks`).
- Both validators reject a malformed payload as a whole (increasing line
  numbers from `offset` through `totalLines`; every hunk's
  path/oldText/newText), so a bad field falls back instead of printing a
  half-read file.  The wire accessors `--aget` and `--wire-list` are total
  over malformed shapes, and the read envelope is checked as an anchored
  prefix regexp plus a separate closing-tag test because one `\(?:.\|\n\)*`
  regexp spanning the body overflows Emacs' regexp matcher above ~129 KB.
- `dsh-emacs-render-tool-call` stores `:name` and `:args-raw` in the tool state
  so the result path can rebuild a card; the raw args were previously
  discarded once the display body text had been derived.

## Why

The metadata was already on the wire, so this needs no event, protocol or
server change — only the renderer reading a field it had ignored.  Reusing the
ioCard's `IN` would have meant inventing a second presentation of facts the
metadata states directly, and mirroring web's models keeps dsh-emacs' stated
design language ("tool rows reuse dsh web's `ToolRow` / `ioCard` semantics")
honest for the two variants where the generic card is worst.

Web's validity rules were kept rather than loosened — a directory or image
read must not render as a numbered file, and the diff card needs usable
arguments — and so was its edit/write asymmetry: an `edit` whose result
records no diff matched nothing, so it must not show a diff it did not apply,
while a `write`'s argument *is* the whole file and keeps its intended diff
either way.

Three web behaviours were deliberately dropped:

- **No second-level collapse.**  Web shows 8 head and 8 tail lines with an
  inner expand control once past 16; dsh-emacs already folds the whole card
  with RET, and an inner toggle would need a live re-render of a fragment body.
- **No path banner in the read card.**  The row header already carries the path
  that web repeats in the banner.
- **No surface band on any expanded card.**  Web paints its card bodies on a
  code surface; here each card's own faces carry the structure, so the band
  would only mean padding every row to the box width.  Measured over a 20-line
  bash card, dropping the band cut the transcript from 1814 characters to 542.
  The deliverables row (postmortem 041) made the same call for the same reason.

## Consequence

A `read` row expands into a numbered file card with a window footer instead of
the envelope, and a `write`/`edit` row into a diff card instead of the argument
JSON; an `edit` previews while running.  A call the models decline
(directory/image read, `web_fetch`, `cordis_*_inspect`, `str_replace_editor`)
keeps the generic card unchanged, and so does any call that did not settle as
a success — a failure, an `interrupted` abort, a nonzero exit, or a signal.
That gate needs a real exit status: dsh's shell renderer carries it in the
result text (`[exit code: N]` / `[killed by signal: X]`), so the result path
parses that trailing marker (web `parseExitStatus`) and reads the Host's
`error.code` — the block-level `exitCode`/`signal` fields are not on the wire.
Without `meta`, reads and edits use the generic card; a successful write keeps
its argument-derived whole-file diff.

Public surface: the `dsh-emacs-tool-meta-face`, `-diff-path-face`,
`-diff-add-face` and `-diff-del-face` faces.  `dsh-emacs-tool-bash-panel-face`
is removed, along with the row-padding helper it fed — expanded cards draw on
the transcript background (breaking; 0.4.0 `Breaking Changes` + `Changed`).
Docs touched: CHANGELOG 0.4.0 `Breaking Changes` + `Added` + `Changed` +
`Fixed`, `docs/ui-styling.md`.  Assertions in `test/dsh-test.el`
cover both cards, their faces and fallbacks, an unpadded row shape, a 147 KB
read, five rejected envelope shapes, a malformed-payload matrix, failed and
interrupted calls, the shell exit/signal markers parsed from the result text,
and lines before the declared read offset.

## Known limitations

- Cards are built eagerly when the result arrives, although they start
  collapsed, so a payload pays for a body the user may never open.  Per event
  (median of 21 trials, result path only, HEAD vs this change): a 20-line bash
  card 0.14 ms against 0.28 ms, a 40-line read window 0.43 ms against 0.18 ms,
  a 400-line read window 3.6 ms against 0.56 ms, and a synthetic 2000-line
  `write` 4.4 ms collapsed / 10.8 ms expanded against ~1 ms for the old
  ioCard.  Cost tracks payload lines, and real payloads are small — across 356
  hunks and 343 reads in one recorded session the median hunk was 20 lines and
  the median read window 40 — so ordinary calls stay sub-millisecond.
  Deferring the body build to the first expand is the obvious fix and would
  also help the bash card, but it needs the fragment API to accept a deferred
  body.
- The diff card is not an alignment: it prints the whole old block then the
  whole new block, like web's `DiffBlock`.  No LCS line pairing.
- Every line of a read window is printed; there is no inner "N more lines"
  collapse (see `Why`).
- The read card is keyed on the `read` tool name, so `web_fetch` and
  `cordis_*_inspect` — same icon variant — keep the ioCard, as does
  `str_replace_editor`, which the client does not map at all.
- A Host that stops sending `data.meta` reverts read and edit cards to the
  ioCard.  Successful writes keep their argument-derived whole-file diff.
- Web hides a card for Code Dispatch children; this client has no parent/child
  call model, so a nested `read`/`edit` also renders a card.
- There is no copy button on either card (web has one on both).
