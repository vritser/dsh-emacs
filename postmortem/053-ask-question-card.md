# 053 — The `ask_user_question` card

## Background

dsh's `ask_user_question` tool carries its questions in the call arguments
(`{questions: [{id, question, header, options, multi_select}]}`) and returns
the human's answers as compact JSON (`{answers: [{id, selected, custom}]}`).
The waterfall that presents them is answered in the minibuffer (postmortem
042), so the transcript row is the only durable record of what was offered
and what was answered.

That row was the generic ioCard: `IN` dumped the whole `questions` argument
JSON — every prompt, option and description as one flattened line — and `OUT`
dumped the answer JSON, so a two-question batch read as two unparsable
documents and the header named neither the questions nor their outcome.  dsh
web gives the call its own tool view (`AskQuestionRow`, keyed
`ask_user_question`) and renders the answered set as a question/answer card
(`AskQuestionCard`); dsh-emacs had no such card.

## Decision

Add a name-keyed ask card in `dsh-emacs-render.el`, driven by the shared
protocol structs:

- `dsh-protocol-question--from-alist` now decodes the tool's own
  `multi_select` spelling as well as the ask request's `multiSelect`, so both
  wire shapes become one struct and no wire field name leaks into the
  renderer.  Its `options` array goes through `dsh-protocol--objects`, which
  drops a non-object element at the boundary: the constructor unpacks fields
  with `assq`, and model-authored arguments reach the renderer unvalidated, so
  a bare string in `options` used to signal out of the event stream and lose
  the row entirely.  The same guard covers the request path.
- `dsh-emacs-render--ask-questions` / `--ask-answers` decode the call's
  arguments and the settled result; `--ask-summary` gives the collapsed row
  its outcome (`waiting`, `A/B answered`, `cancelled`, `interrupted`, with
  web's own denominator: the answer document's length); and `--ask-body`
  renders the questionnaire — one block per question, its `header` chip and
  text, then that question's options with the reader's own numbering, the
  chosen ones checked in the accent face, descriptions in the muted meta
  face, and a closing free-text answer or `Not answered`.
- The ask call renders through the ordinary tool-card path (same namespace,
  block id and state tracking), so its result updates the row in place.
- The row gets its own `question` variant with dsh web's
  `IconQuestionOutline14`, and the title `Ask question` in
  `dsh-emacs-tool-titles`.  The card is gated by that variant, like the bash
  and write/edit cards.
- The two user-driven outcomes are corrected in the result path: an
  `ASK_CANCELLED` question set settles and an `ASK_ABORTED` one interrupts,
  matching web's `AskQuestionRow`, instead of failing red; the expanded body
  then carries web's own explanation sentence (`ask.cancelledDetail` /
  `ask.interruptedDetail`) rather than the generic "interrupted" status line.
- A call whose arguments name no usable question keeps the generic ioCard.

The card folds like every other tool row: the outcome summary is the
collapsed line, the questionnaire is the expanded body.

## Why

Web's *composer* shows the questionnaire and its *transcript* card shows only
question/answer pairs, because the composer is gone once the question is
answered.  In Emacs the transcript is the only place the offered options ever
appear, so the card keeps them: the record then answers "what was I asked,
what were my choices, which did I take" in one place, and the numbering
matches the candidates the minibuffer reader presented.  Descriptions stay
because they are what a reader needs to re-read a decision, and the accent
`✓` plus the muted descriptions make the choice legible without a second
face.

The collapsed line can only carry one thing, so it carries the outcome in
web's wording: a question set is a *decision*, and `2/3 answered` /
`interrupted` is what a reader scanning the transcript needs from it.

The two error codes are the user's own decision, not a tool failure — a
`C-g` abandon or a web-side dismissal must not paint the row red, and the row
would otherwise contradict its own "interrupted" summary.  For the same
reason the expanded card states that sentence in web's words instead of the
generic "interrupted" line: the collapsed row already carries the outcome, so
the body owes the reader the *why*.

Rejected: web's answer-only transcript card, which drops the options,
descriptions and numbering this client has nowhere else to show.  Rejected:
expanding the card by default — the transcript's fold discipline is uniform
(`dsh-emacs-tool-expand-by-default`), and an always-open questionnaire would
inflate every session that asked one.  Rejected: a dedicated face for the
chosen option; the accent label plus the check glyph already carry it, and
new faces are a user-visible contract.  Rejected: a per-card expand option,
and re-parsing the wire field names in the renderer.

## Consequence

An ask call collapses to `❓ Ask question · waiting`, then
`· 2/2 answered` (or `· cancelled` / `· interrupted`), and expands to the
questionnaire with its choices marked.  A malformed element inside either wire
array is dropped rather than signalled, so it costs at most that element; a
question the card cannot describe (no text, malformed JSON, another failure)
keeps the generic ioCard and its status line.  No new faces; the only new
user-visible defaults are the `Ask question` title and the `question` icon.

Docs touched: CHANGELOG 0.5.0 `Added`, `docs/ui-styling.md` (the tool-card
list, the variant/icon table and the summary paragraph).  Assertions in
`test/dsh-test.el` cover the pending questionnaire, the answered marks and
free-text row, `Not answered`, the aborted-as-interrupted and
cancelled-as-success mappings, the malformed question and option elements,
the ioCard fallback, and the tool-argument spelling of the multi-select flag.

## Known limitations

- No "Inspect call" action like web's live row; the body is the whole
  disclosure.
- The card does not restate a question's multi-select flag.  The marked
  answers show it once settled, and while the call runs the minibuffer
  reader carries its own hint.
- Option numbering assumes fewer than 100 options (`%2d.` gutter); the
  reader's own candidate list has the same practical bound.
- Both counts in `A/B answered` come from the answer document, so a result
  that carries no answer entry at all (an absent or empty `answers` array)
  is not summarized as a question set: the row keeps its result preview.
  The tool maps one answer entry per question, so a real call always carries
  one.
