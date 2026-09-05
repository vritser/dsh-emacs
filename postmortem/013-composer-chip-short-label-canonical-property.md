# 013 — Composer chips store the short label; canonical mention rides a text property

_Status: Complete._

## Background

`feat: render completed @ references as composer chips` (7040243, postmortem/012
Slice 2) made a picked session reference an atomic composer chip by keeping the
canonical `@[label](dsh-session:…)` text in the buffer and hiding it behind a
`display` property that collapsed it to `@label`. Files were treated the same
way, except a file chip kept its own `@path` (already the wire text, so no
collapse). Editing safety came from a buffer-local guard that treated the whole
canonical span as one unit.

The `display`-collapse model couples two things that do not move together: the
buffer holds the long canonical text while the user sees a short label. Every
editing guard that keeps the canonical unbreakable had to reason about the
canonical-length span, and the visible geometry (where the cursor sits, how a
backspace deletes) is driven by buffer positions whose length differs from what
is drawn. This works but leaves the representation far from what the user edits
and is easy to trip over as more edit paths are added.

## Decision

A picked session reference keeps the **short `@label` text** in the buffer — the
same text the user actually sees and edits — and stores the canonical
`@[label](dsh-session:…)` mention in the **`dsh-emacs-reference-canonical`
text property** on that span. Two new private functions in
`dsh-emacs-reference.el` own this:

- `dsh-emacs-reference--session-chip (start end canonical)` — marks the short
  span as an atomic chip (link face / RET-mouse keymap, `dsh-emacs-reference-ref`
  session id, `dsh-emacs-reference-chip`, `rear-nonsticky`) and records the
  canonical mention as a property; no `display`.
- `dsh-emacs-reference--expanded-text (start end)` — rebuilds the wire form of
  a buffer region, replacing each canonical-property span with its mention and
  copying everything else (plain text and file chips, whose `@path` is already
  the wire form) verbatim.

`dsh-emacs-reference--make-chip` / `dsh-emacs-reference--chipify` (the
`display`-folding path) are removed. The completion `:exit-function`
(`dsh-emacs-reference--exit`) and `M-x` insert
(`dsh-emacs-reference--insert-at-point`) no longer delete + insert the long
mention; they keep the short label already in the buffer and mark it with
`dsh-emacs-reference--session-chip`.

Expansion happens at the single read point: `dsh-emacs--get-input` in
`dsh-emacs.el` (send, busy steer/queue, input-history capture) calls the
declared `dsh-emacs-reference--expanded-text`, so the text that reaches RPC and
history is always canonical. A file chip / plain run has no canonical property,
so expansion is the identity there.

The atomic-editing guard (whole-span delete at a boundary, cursor hop past the
interior on an edit) is unchanged but now operates on the short label, whose
length is what the user sees.

## Why

- Buffer text equals visible text. The edit guard's geometry — the span a
  backspace removes, where an edit hop lands, whether typed-after text inherits
  the chip style — now works on exactly what the user sees, with no `display`
  length mismatch to reason about.
- One owner for wire form. `--expanded-text` at `dsh-emacs--get-input` is the
  single place a short label becomes canonical, so no code path can accidentally
  send or history-record the short label; conversely a recalled/pasted canonical
  mention (no property) is passed through unchanged, so it can never be
  double-expanded.
- Files stay trivially correct: a file chip is its own wire text, carries no
  canonical property, and expansion passes it through — the refactor needs no
  special file case.
- Rejected: keeping the long canonical in the buffer and only changing the
  visible layer further (the status quo of 012 Slice 2) was abandoned because
  it is the representation being refactored away. Rejected: storing only the
  label and re-deriving canonical from grammar at send time — fragile, since
  label escaping / id recovery must round-trip exactly; storing the canonical as
  a property keeps the exact host mention authoritative.

## Consequence

- Internal representation change; the visible chip behavior is unchanged
  (short `@label`, atomic editing, RET/mouse opens the session, file chips keep
  `@path`).
- `dsh-emacs.el` `dsh-emacs--get-input` now expands session chips; the RPC and
  input-history capture therefore still see canonical text.
- Removed `dsh-emacs-reference--make-chip` / `dsh-emacs-reference--chipify`;
  added `dsh-emacs-reference--session-chip` / `dsh-emacs-reference--expanded-text`.
- Docs: docs/reference.md composer-chip paragraphs and the CHANGELOG 0.3.0
  Added bullet updated. This refactor supersedes the composer (Slice 2)
  `display`-collapse approach of postmortem/012; the transcript link layer
  (012 Slice 1) is untouched.

## Known limitations

- As before (inherited from 012), killing a selection that overlaps a chip can
  still truncate it — an explicit delete that the guard does not cover.
- A canonical mention that appears in the input without going through a pick —
  history recall or a raw paste — stays plain long text (it is excluded from the
  `@` menu by the completed-mention check in `dsh-emacs-reference--active-token`)
  rather than being re-wrapped as a short chip. History recall behaved the same
  way before this refactor.
