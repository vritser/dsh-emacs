# 041 — The turn-tail deliverables row

## Background

A successful `present` call appends the durable Session event
`deliverables/presented` (`{turn, callId, files: [{path, description?}]}`) —
see `packages/fs/tool-present/src/index.ts`, which appends it from the tool's
successful result.  At the `3e8958d` baseline dsh-emacs let it fall into
`_ nil`, so an explicit delivery was visible only through the `present` tool
card's `Presented <path>` result text: no structured list, no descriptions,
no clickable path.

dsh web renders two related surfaces at the turn tail
(`packages/client/ui-deliverables`): **explicit deliveries** from this event,
and a **"Files changed" row** derived *client-side* from the turn's successful
`write` / `edit` / `str_replace_editor` calls
(`src/client/turn-deliverables.ts`) — there is no file-change event.
Postmortem 040 had deliberately completed only the V3 core vocabulary and
left plugin events (including this one) unrendered.

## Decision

Consume `deliverables/presented` and render one row after the turn's closing
message; do **not** add a file-change row.

- `dsh-emacs-render-deliverables` collects each event's files per turn into
  the buffer-local `dsh-emacs-render--turn-deliverables` (an alist of
  `TURN . FILES`).  `turn/end` calls `dsh-emacs-render--flush-deliverables`,
  which renders the row and clears the turn's entry, so the row lands *after*
  the closing message (dsh web's turnTail position).
- Repeated declarations of one path merge into one line, last description
  winning (web does the same for persisted declarations).
- The row is a minimal fragment titled `Deliverables · N files`,
  **collapsed by default**: a green `●` (`dsh-emacs-deliverable-dot-face`)
  marks "produced", while the title carries its own magenta
  (`dsh-emacs-deliverable-text-face`, `dsh-emacs-color-deliverable`) because
  the row already shows the dot's green and the paths' teal link face — three
  colors on one row have to stay mutually distinct.  Expanding renders one
  indented `  path — description` line per file with no body background band;
  the path is a clickable reference.
- Link presentation is owned by the reference module: the new public
  `dsh-emacs-reference-file-link` (dsh-emacs-reference.el) returns a path
  propertized with `face dsh-emacs-reference-face`, `mouse-face`, the
  RET/mouse-1 keymap and a `(file . PATH)` `dsh-emacs-reference-ref`; opening
  reuses `dsh-emacs-reference--open-ref`, which resolves relative paths
  against the session working directory.  Render keeps only the layout.
- A follow snapshot's message-aligned tail can end mid-turn, with the delivery
  event but no `turn/end`; `dsh-emacs-render-history-events` flushes any
  leftover rows at the batch end (that batch end is then the tail).
- `write`/`edit` changes are not folded into the row.

## Why

The event is the authoritative, structured record of what the model declared
as deliverables — paths plus descriptions, including nested calls — while the
tool card's text is a lossy rendering of it.  Making paths clickable is the
part dsh-emacs can add over the card.

Turn-tail placement follows the reference client and the semantics: the
deliverables summarise what the turn produced, and at their own event position
they would interrupt the closing prose (the model is still talking).  That
needs buffering, and the buffer needs the batch-end flush to stay honest on
replay; the flush is the only added mechanism, and it removes the one way a
row could be lost.

Reusing the reference module's link presentation is the ownership fix rather
than a second clickable-path mechanism: `@` file mentions already mean
"clickable path resolved against the session cwd", and `--open-ref` already
implements it.  A new face was rejected for the same reason — the reference
face already carries that meaning.

Collapsed by default follows the bash card (the other expanded-body surface
in the transcript) and keeps a turn's tail quiet: the header already carries
the count, so the file list is one fold away.  The expanded body is plain
indented lines, deliberately without the bash card's code-block panel band: a
background there made a short file list look like a second card, and the
paths already carry the clickable link face that carries the meaning.

The "Files changed" row was rejected for dsh-emacs: it is not an event, it is
a client-side fold of mutation calls, and dsh-emacs already renders every
`write`/`edit` card with its path.  Web needs the row because it folds a
turn's process; in a fully expanded transcript it would duplicate what is on
screen without adding a fact.

## Consequence

A turn that called `present` ends with one collapsed green-dotted
`Deliverables · N files` row; expanding it lists one indented line per
declared path, each opening in a buffer with RET / mouse-1 (relative paths
resolve against the session workspace), the description following on the
same line and no body background.  There is no new user option.

New surface: `dsh-emacs-reference-file-link` (public, reference module), the
`dsh-emacs-deliverable-dot-face` / `dsh-emacs-deliverable-text-face` faces and
the `dsh-emacs-color-deliverable` / `-dark` color tokens;
`dsh-emacs-render-deliverables`, `dsh-emacs-render--flush-deliverables`,
`dsh-emacs-render--deliverables-body` and the buffer-local turn map
(internal).  Docs touched: CHANGELOG 0.4.0 `Added`, `docs/rpc.md` §7.4.
Thirteen assertions in `test/dsh-test.el` pin the placement (deferred to
`turn/end`, tail order), the default fold and colors (dot vs title, title vs
link face), expansion, clickability, per-path merge, the replay flush (batch
end, no double render), description flattening and the reference helper.

This lifts postmortem 040's "plugin events remain unrendered" limitation for
`deliverables/presented` only (040 carries a status note).

## Known limitations

- Only explicit `present` deliveries produce a row; a turn that changed files
  without calling `present` shows nothing new (its tool cards remain).
- There is no "open in default application" / "Show in Finder" action like
  web's native menu: the row opens the file in an Emacs buffer.
- Deliveries recorded in a subagent's own Session render only in that
  session's chat buffer, not in the parent transcript.
- Opening requires the file to be reachable from the local filesystem; a
  path only present on a remote Host reports `Reference file not found
  locally`.
