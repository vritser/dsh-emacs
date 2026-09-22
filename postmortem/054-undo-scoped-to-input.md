# 054 — Undo is scoped to the input area

Implementation commit: `feat: scope chat undo to input`.

## Background

`dsh-emacs-mode` has called `buffer-disable-undo` since the initial commit
(`df93cd5`), so `C-/` in a chat buffer answered "No undo information in this
buffer": the input area had no undo at all, and `M-p` recall, yanks or a
mis-typed draft could not be taken back.

The buffer is a live view, not a document: everything above the `❯ ` prompt
is written by the renderer (history pages, streamed replies, tool cards,
Composer chrome, the mode-line separator), and only what follows the prompt
is the user's.  Undo records hold absolute buffer positions, and Emacs does
not adjust them when text lands elsewhere (`simple.el`, "The positions given
in elements of the undo list are the positions as of the time that element
was recorded"), which is the failing layer here: a reply rendered above the
draft shifts it down, so a record made for the draft before that render
points at transcript text.  `primitive-undo` binds `inhibit-read-only`
internally, so the transcript's read-only text property is no protection —
undoing such a record deletes rendered message text, and the removal is then
itself recorded as a redo record.  Simply re-enabling undo would have made
the first undeliberate `C-/` corrupt the view.

## Decision

Undo/redo covers the input area only.  `dsh-emacs-mode` enables undo; every
programmatic write above the input runs with `buffer-undo-list` bound to `t`
(added to the existing `(let ((inhibit-read-only t)) …)` forms that surround
transcript text, fragments and chrome — 15 in `dsh-emacs-render.el`, and the
same in `dsh-emacs-ui.el`, `dsh-emacs-composer.el`, `dsh-emacs-modeline.el`
and the optimistic-echo/delete paths in `dsh-emacs.el`).  A write that still
shifts the input is detected positionally by `dsh-emacs--note-undo-change`
(`after-change-functions`, `dsh-emacs.el`) and acted on by
`dsh-emacs--reset-undo-history` (`pre-command-hook`), which drops the
invalidated history and re-records the input as a single unit; the setup of
the input area clears the list for the same reason.  A second, narrower rule
fixes where the cursor lands: `undo` re-inserts a restored region at the
position it was deleted from and parks point there (`primitive-undo` ends a
positive `(STRING . POS)` record with `(goto-char pos)`), so a restored draft
came back with the cursor at its beginning.  `dsh-emacs--note-undo-change`
remembers the end of input text restored at the input's tail, and
`dsh-emacs--park-point-after-undo` (`post-command-hook`) leaves point after
it. Submission also rebuilds stale history after the optimistic echo and
before clearing the input, so the clear remains undoable at the next command.
`dsh-emacs.el` owns the behavior; no new module, option or keybinding is
added — `C-/`/`C-_`/`C-x u` (`undo`), `C-g C-/` for redo, and `undo-redo`
on Emacs 28+ are stock commands.

## Why

Two mechanisms, because they answer different halves of the problem.  Keeping
programmatic writes out of the history is what stops `undo` from ever seeing
transcript text, and it also stops every streamed Markdown revision from
keeping a copy of the text it replaced (that cost is what
`buffer-disable-undo` was originally avoiding).  It is not sufficient on its
own: the records already made for the draft go stale when a *silent* write
shifts them, and a dropped record would silently undo the wrong region.  The
positional flag plus a rebuild before the next command closes that window
without touching the undo list in the middle of a change — important because
`atomic-change-group` (used by `dsh-emacs-render--run-markdown` and two
`dsh-emacs-ui.el` paths) requires that nothing edits `buffer-undo-list` while
its handle is live.  The rebuild re-records the draft as one insertion, the
same shape `undo-boundary` plus one `insert` produces, so `C-/` clears the
draft, `undo-redo` restores it, and typing after that is undoable step by
step again.

Alternatives rejected: keeping undo disabled and writing a parallel
input-only undo stack reimplements amalgamation, boundaries and redo for a
region that stock undo already handles correctly; making the transcript
writes undoable and filtering `undo` afterwards cannot work, because the
corrupting delete happens inside `primitive-undo`; shifting the recorded
positions by hand as text is inserted above the input would have to
understand every entry shape (integer, `(BEG . END)`, `(STRING . POS)`,
`(nil PROP VAL BEG . END)`, marker adjustments, `apply`) and fails silently
when one is missed; encoding the rebuilt unit as a hand-made `(apply …)`
record that deletes the draft with point pre-parked at its end (so
`record_delete` stores a negative position and redo lands after the text)
fixes only the rebuilt case, leaves a natural redo of typed text at stock
placement, and puts an entry in the history that `undo-elt-in-region` cannot
classify; and giving the input its own buffer or an indirect buffer would
break the single-buffer geometry the input marker, delete guards and cursor
clamps rely on.

## Consequence

`C-/`, `C-_` and `C-x u` undo input editing; `C-g C-/` (or `undo-redo` on
Emacs 28+) redoes it. The transcript is never undone, and fragment folding or
tool-card updates leave no undo step.  Redo leaves the cursor after the text
it restored (verified in a real GUI Emacs: the rebuilt draft comes back with
point at the input's end, not its start).  After a transcript write the first
undo clears the draft rather than removing the last few characters, and the
draft's pre-write character history is gone — the accepted tradeoff for
never touching the transcript.  `README.md` lists the keys and
`docs/architecture.md` documents the mechanism; tests 52g–52i pin the input
scope, the stale-flag rebuild, the cursor after redo and the granular typing
that follows a rebuild, and the fragment-index test now asserts that a
fragment deletion is *not* undoable.

## Known limitations

Granularity is lost retroactively: a render between two keystrokes collapses
the draft into one undo step at the next command, so during a long streamed
turn `C-/` clears the whole draft instead of the last word.  Undo/redo state
is per buffer and in-memory only — it does not survive a session reload, and
a rebuilt history deliberately forgets the earlier steps.  `undo-in-region`
with an active region over the transcript is not special-cased: it can only
ever see input records, but the region's own bounds are not consulted.
