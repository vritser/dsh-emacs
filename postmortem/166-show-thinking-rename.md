# 166 — Rename the thinking visibility option

## Background

`dsh-emacs-show-reasoning` controlled whether the transcript renders the Think
row.  The presentation layer already used the other term everywhere: the row is
Think, the sibling options are `dsh-emacs-thinking-style` and
`dsh-emacs-thinking-preview-max`, and the faces and render functions carry
`thinking`.  The wire vocabulary is the opposite one: the content block kind is
`"reasoning"`, and model selection uses `reasoningEffort`.

The option was also declared twice, in `dsh-emacs-render.el` (the renderer that
owns it) and `dsh-emacs.el`, with different docstrings and Custom groups.  The
entry-file copy loaded last, so it shadowed the renderer's docstring and put the
option in both `dsh-emacs` and `dsh-emacs-render`.

Commits: ba34a5e.

## Decision

Rename the public option to `dsh-emacs-show-thinking` without an alias, keep its
single `defcustom` in `dsh-emacs-render.el`, and delete the entry-file copies of
it and `dsh-emacs-show-tool-calls`.  Keep `reasoning` for the protocol and model
layer.

## Why

The option controls presentation, so it should use the presentation term.  Using
`thinking` here makes the public surface (`show-thinking`, `thinking-style`,
`thinking-preview-max`, the Think row) internally consistent and stops the
options list from mixing both terms for one concept.  `reasoning` remains
correct where the wire defines it: renaming protocol accessors or
`reasoningEffort` would diverge from the host API for no user-visible gain.

An alias was rejected: the project deletes rather than deprecates, and a
pre-1.0 breaking rename is cheap to document.  Keeping the old name was the
cheaper option, but it would preserve the exact mismatch this change exists to
remove.  Renaming the protocol vocabulary instead was rejected because the wire
spelling is not ours to choose.

## Consequence

A configuration that still sets `dsh-emacs-show-reasoning` has no effect; the
new name is `dsh-emacs-show-thinking`.  The option now lives only in the
`dsh-emacs-render` Custom group.  Docs (`docs/customization.md`,
`docs/rpc.md`) and the tests use the new name.  Protocol structs, accessors and
`reasoningEffort` are unchanged.

## Known limitations

Older postmortems (040, 164) still name the option as it existed then; records
are not rewritten.  External code that reads or binds the removed variable gets
a void-variable error rather than a compatibility alias.
