# 007 — Footer Compatibility Aliases Removed

_Supersedes the alias-retention decision in 002._

## Background

Postmortem 002 recorded the footer→mode-line rename while retaining
obsolete compatibility aliases: three variable, three function and seven
face aliases (`dsh-emacs-footer-*` → `dsh-emacs-modeline-*`), so 0.1.0-era
configs kept loading.  AGENTS.md, however, already forbids exactly this:
pre-1.0 breaking changes are renamed or removed with **no compat shims
retained** (Core principles: "Delete, don't deprecate").

## Decision

Delete all thirteen aliases: the three
`define-obsolete-variable-alias` and three
`define-obsolete-function-alias` in `dsh-emacs-modeline.el`, and the
seven `define-obsolete-face-alias` in `dsh-emacs-faces.el`.  The old
footer names cease to exist; only the modeline names remain.

## Why

- 0.2.0 has not shipped: the aliases never appeared in any released
  version — they bridge an unreleased pre-1.0 rename only.  Keeping them
  would carry a permanent dual-name surface for zero shipped-compat gain.
- AGENTS.md is explicit that pre-1.0 breaking changes carry no
  compatibility shims; 002's alias retention contradicted the repo's own
  principle.
- A hard cut is honest: `(setq dsh-emacs-footer-enabled …)` fails loudly
  at load instead of working silently through an alias that byte-compile
  and customize both deprecate.  Early exposure of the migration burden
  beats a deferred one with two live names in docs and compiler output.

## Consequence

- Customizers must rename footer options/commands/faces to the modeline
  names; saved customizations of old names stop binding (the variable is
  void at load).  The CHANGELOG 0.2.0 breaking entry now states that no
  compatibility aliases are retained, and its rationale link points here.
- `dsh-emacs-modeline.el` and `dsh-emacs-faces.el` no longer carry alias
  sections; the byte-compile alias-ordering warnings vanished with them.

## Known limitations

- `test/dsh-e2e.el` still references pre-rename footer function names
  (`dsh-emacs-footer-format`, `-set-usage`, `-enabled`, `-toggle`); it
  predates the rename (some of those names never existed even in 0.1.0)
  and sits outside the verify gate because it drives a real dsh server.
  Left as pre-existing debt — the alias removal does not make it worse in
  kind, but it is now fully disconnected from the current API.