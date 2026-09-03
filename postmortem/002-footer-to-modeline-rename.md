# 002 — Footer to Mode-Line Rename

_Superseded by 007 (alias-retention decision only): the obsolete footer
aliases recorded below were removed in 0.2.0; the renames themselves
stand._

## Background

Pre-0.2.0 the status bar module was named `dsh-emacs-footer`, inspired by
pi-mono's terminal footer (see the layout comment in
`dsh-emacs-modeline.el`).  But the status segments (cwd, branch, model,
effort, preset, tokens, ctx%, cost) were already spliced into
`mode-line-format` and rendered by the real Emacs mode line; the buffer-bottom
element was only a structural newline.  The name "footer" described web/terminal
chrome, not what the module did in Emacs terms.

## Decision

Rename `dsh-emacs-footer.el` → `dsh-emacs-modeline.el` with all symbols and
test labels: group `dsh-emacs-footer` → `dsh-emacs-modeline`, options
`dsh-emacs-footer-enabled` / `-format-spec` / `-branch-refresh-interval` →
`dsh-emacs-modeline-*`, commands `dsh-emacs-footer-toggle` / `-setup` /
`-update` → `dsh-emacs-modeline-*`, and the seven footer faces (face,
separator, token, cost, ctx-ok, ctx-warn, ctx-crit) → `dsh-emacs-modeline-*`.
`a718565`, 2026-08-29.

The 0.1.0 names are **retained as obsolete aliases** marked obsolete in 0.2.0
(`define-obsolete-variable-alias` / `-function-alias` /
`define-obsolete-face-alias` in `dsh-emacs-modeline.el` and
`dsh-emacs-faces.el`), so existing configs and commands keep working with
deprecation warnings.  (The 0.2.0 CHANGELOG initially claimed no aliases were
retained — that was wrong, and the entry was corrected in the same release.)

## Why

- The name was misleading: this is Emacs's mode line — the native, permanent
  status surface of an Emacs buffer — not a buffer-local footer.  The rename
  matches the project's "Emacs-native interaction" ethos (compare the queue
  design rationale, 003) and Emacs vocabulary ("mode-line" is what the
  documentation and `customize` show users).
- Keeping the mode line as the single persistent status surface paid off
  immediately: the queue/steer indicator `[Qn Sm]` and the ctx% segment
  later hung off the same module instead of inventing parallel chrome.
- Obsolete aliases instead of hard deletion kept the breaking change honest:
  rename a thing, don't silently break `setq`s in user configs.

## Consequence

- Breaking rename for customizers: group, options, commands and faces all
  moved to `dsh-emacs-modeline-*`.  Old names still resolve as aliases but
  are deprecated; byte-compiled configs referencing them warn.
- All docs moved with the code: README, docs/customization.md,
  docs/modeline.md, and the check script reference `dsh-emacs-modeline-*`.
- The rename was pure surface: no behavior change, verified by the full test
  suite (332 test lines touched in `a718565`).

## Known limitations

- None deferred by this change; the alias layer is itself the accepted
  legacy seam and can be dropped in a future major version.