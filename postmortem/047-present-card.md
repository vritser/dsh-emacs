# 047 — The `present` card

## Background

dsh's `present` tool declares existing files as final deliverables.  Its
result text is `Presented <path>` lines, and a successful call appends the
durable `deliverables/presented` event (`packages/fs/tool-present`), which
dsh-emacs already consumes for the turn-tail Deliverables row (postmortem
041).

dsh web gives the *call* its own tool view: `PresentRow` is registered under
`tool.call.toolview` with key `present`, and it collapses to the call's paths
comma-joined (`fileNames(args)`) under the title "Present files", expanding to
the result text.  dsh-emacs had no `present` view: the call fell through to
the generic ioCard, whose `IN` dumped the whole `files` argument JSON — every
path *and* description — beside the same `Presented …` text, and whose
header carried no summary at all.

## Decision

Add a name-keyed `present` card in `dsh-emacs-render.el`:

- `dsh-emacs-render--present-paths` joins the call's `files[].path` values;
  `dsh-emacs-render--tool-summary` consults it for `present` ahead of the
  key-based lookup, so the row header names the declared files.
- `dsh-emacs-render--present-card-body` renders the result text through the
  shared `dsh-emacs-render--body-rows` (renamed from `--job-rows`, now that
  job and present cards both indent result lines).
- `dsh-emacs-tool-titles` gains `Present files`.

The turn-tail Deliverables row is unchanged.

## Why

This is the shape dsh web already ships, and the tool cards here follow web's
keyed toolviews.  The header is the right home for the paths: the row is one
line until folded, and `dsh-emacs-ui--top-border` already ellipsizes an
over-long summary, so a many-file call cannot break the transcript width.

Per-call and aggregate answer different questions — which call declared which
files and whether *it* succeeded, versus what the turn delivered after merging
every declaration.  Web shows both, so both stay.

Rejected: suppressing the `present` row because the tail row exists.  That
loses the per-call state (a failed `present` would vanish), and the tail row
merges declarations, so it cannot name the call that made them.  Rejected:
folding descriptions into the summary — the tail row already carries them,
and the header has to stay one line.  Rejected: a second indent helper for the
body; `--body-rows` already does exactly this for the job cards.

## Consequence

A `present` call renders as `Present files · <path>, <path>`; expanding lists
the result text (`Presented <path>` per line, or the Host's failure message)
as indented rows.  A failed call keeps the Host's message and the path
summary, with the row's error state.  No new faces or user options; the
argument JSON is never shown.

Docs touched: CHANGELOG 0.4.0 `Added`, `docs/ui-styling.md` (card list and the
summary-key precedence paragraph, which also now records the tool-name-first
lookup).  Assertions in `test/dsh-test.el` cover the joined-path summary, the
call card, the failure card, and the absence of the args JSON.

## Known limitations

- No "Inspect call" action like web's `PresentRow` button; the body is the
  whole disclosure.
- A turn's declared paths appear twice — on the call row's header and on the
  turn-tail Deliverables row.  That is web's shape too, but the header line is
  ellipsized when the call declared many files.
- Only the `present` tool name is keyed; another tool that declares `files`
  keeps the generic ioCard.
