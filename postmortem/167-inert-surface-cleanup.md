# 167 — Inert surface cleanup

## Background

The audit behind [166](166-show-thinking-rename.md) left several public options
that did not match their code.  Nine of them had no reader at all:
`dsh-emacs-tool-preview-lines`, and the `-bg` palette options
`dsh-emacs-color-tool-pending-bg`, `dsh-emacs-color-tool-success-bg`,
`dsh-emacs-color-tool-error-bg`, `dsh-emacs-color-thinking-bg` plus their
`-dark` forms.  Their sibling `-border` colors were wired into faces; the `-bg`
values never were, and `tool-preview-lines` was left behind when the tool
summary became a single line.  All date from the initial commit and never
reached the docs, so a user could set them and see nothing change.

The same audit found thirteen `dsh-emacs-markdown-*-face` definitions in
`dsh-emacs-faces.el` with no reader: the converter and renderer use the
`dsh-emacs-markdown-*` faces in `dsh-emacs-markdown.el`, and
`docs/ui-styling.md` already said the `-face` variants were unused.

Two adjacent render options also used different conventions for the same kind
of cap: `dsh-emacs-max-tool-result-chars` and `dsh-emacs-tool-call-chars`.
Finally, `dsh-emacs-history-window` was defined in `dsh-emacs.el` while every
reader lived in `dsh-emacs-history.el` / `dsh-emacs-events.el`, and two render
options sat in the top-level Custom group instead of `dsh-emacs-render`.

Commits: ef08314.

## Decision

Remove the nine inert options, rename `dsh-emacs-tool-call-chars` to
`dsh-emacs-max-tool-call-chars`, move the `dsh-emacs-history-window` definition
to the history module, and put `dsh-emacs-stream-markdown-limit` and
`dsh-emacs-reply-footer-items` in the `dsh-emacs-render` Custom group.  The
session module's forward `defvar`s become bare declarations instead of
duplicated value-carrying definitions.  Delete the thirteen unused Markdown
faces, and privatize the internal `dsh-emacs-sessions-buffer` and
`dsh-emacs-server-default-base-url` symbols.

## Why

A public option is a promise that setting it changes something.  Dead options
break that promise and make the Customize surface harder to read; the project
has removed inactive transcript options before for the same reason
([122](122-remove-inactive-transcript-options.md)).  Removal is safer than
inventing a rendering use for colors that were never designed into a face.

The rename follows the `max-*` cap convention the adjacent option already used.
Only this pair is normalized: the wider option set also spells caps as
`-limit`, `-max`, `-window` and `-length`, and renaming all of them would be a
large breaking change for cosmetic gain.  New options should use `max-*`.
Moving `history-window` to the module that reads it, and the render options to
the render group, keeps ownership consistent with the rest of the package.

Declarations use bare `defvar`, as the session module's own comment intended:
a forward declaration must not carry a second default or a competing docstring.
Dead faces are the same broken promise as dead options: Customize should not
list symbols that paint nothing.  The buffer name and server fallback were
public only by spelling, not by documentation, so the private prefix matches
the package's naming contract.

## Consequence

Configurations that set a removed option or the old `tool-call-chars` name no
longer affect behavior and should be updated.  Customize lists the two moved
render options under `dsh-emacs-render`, and `history-window` remains under the
top-level group, now owned by the history module.  The thirteen Markdown faces
disappear from Customize; remove any `custom-set-faces` entries for them.
Code that referenced the internal buffer or server fallback must use the `--`
names.  Rendering and defaults are otherwise unchanged.  Docs use thinking for
the UI row and reasoning only for the wire/model layer.

## Known limitations

No aliases are provided, so old names silently do nothing (or, for the renamed
option, leave the default in effect).  Removed face customizations have no
target and may warn.  Released CHANGELOG entries and earlier postmortems keep
the old names as historical records.  The broader cap-name mix
(`max-*`, `-limit`, `-window`, `-length`) remains; only the adjacent tool pair
is normalized.
