# 012 — Rendered @ references as clickable links (transcript + composer chip)

_Status: Complete.  The transcript layer (Slice 1) stands; the composer chip
mechanism (Slice 2) is superseded by postmortem/013, which stores the short
label in the buffer with the canonical mention on a text property instead of a
`display` collapse._

## Background

`@` file/session references travel on the wire as canonical text: files as
`@path` / `@"quoted path"`, sessions as `@[label](dsh-session:…)` with an
opaque base64url id. The reference module (postmortem/010) built the
completion side and inserted that canonical text. But the transcript rendered
it as-is (postmortem/010's known-limitation note: "the transcript renders the
canonical mention as-is"), so a session mention exposed the opaque id payload
to the reader, and nothing was clickable. The web renders the same mention as
an atomic chip showing only the label.

Desired end state (user request): show only the session name (never the id),
style `@` fragments, and let click/RET jump to the session or open the file —
on both the read-only transcript and the editable composer input — while the
wire text stays canonical.

## Decision

Keep the canonical mention as the real buffer/wire text everywhere, and add a
**display layer** over it. Ownership stays in `dsh-emacs-reference.el` (the
mention-grammar owner); the render module calls in via a declared function.

Slice 1 (this record's commit): the **transcript**. `dsh-emacs-reference-fontify`
scans a message's text for completed references and returns a display copy:
a session mention is collapsed to `@label` (unescaped) and both file and
session spans gain `dsh-emacs-reference-face`, `mouse-face`, `follow-link`,
and a keymap binding RET/mouse-1 to `dsh-emacs-reference-open-at-point`, which
reads a `dsh-emacs-reference-ref` property. Opening: a session id → the
existing `dsh-emacs-open-session` (switches/reuses/creates that session's chat
buffer); a file path → `expand-file-name` under the session cwd and
`find-file`. Hooked at the single user-message render choke point in
`dsh-emacs-render-user-message`, before image placeholders are appended so
their keymaps survive.

Assistant bodies are NOT linkified in Slice 1 (they flow through the markdown
layer; see Known limitations).

## Why

- The id payload is display-noise and the canonical mention is unreadable in a
  transcript; hiding it behind the label is exactly the web's chip model.
- Files are host-workspace-relative paths and the dsh server runs locally, so
  a file "open" resolves `cwd + path` → `find-file` with no host RPC needed.
- Reusing `dsh-emacs-open-session` for the jump reuses the tested session
  lifecycle (create/reuse/switch) instead of a parallel switcher.
- Slicing transcript (read-only, one choke point) ahead of the composer
  (editable, needs whole-span editing semantics) keeps each change small and
  independently verified. Markdown bodies are deferred because over-linking
  prose `@word` inside free text (e.g. `@param`) is a real false-positive risk
  that needs span/context care.
- File matching requires the `@` to follow whitespace/start so emails like
  `mail@example` and the `@[label` prefix of a session mention are not
  mis-linked as files.

## Consequence

- New: `dsh-emacs-reference-face`, `dsh-emacs-reference-fontify`,
  `dsh-emacs-reference-open-at-point`, `dsh-emacs-reference--mention-keymap`.
- User messages in the transcript show collapsed, colored, clickable `@`
  references; RET/mouse opens them. Wire text unchanged.
- docs/reference.md note updated; CHANGELOG Added entry (0.3.0) links here.

## Known limitations

- Only user messages are linkified in Slice 1; assistant (markdown) bodies and
  the host-injected "recall context" snippet above a message are still raw.
  Later entry lifting this supersedes this record's note.
- File "open" resolves a local path under the session cwd; it assumes the dsh
  server shares this filesystem (true for the localhost setup). A remote host
  needs a content-fetch RPC, which does not exist in the client today.

Slice 2 (composer): a completed session mention is inserted with its canonical
text kept in the buffer and a `display` property collapsing it to `@label`.
Editing safety comes from a buffer-local pre-command guard (an edit whose
point sits on the collapsed span first hops to its end, so the canonical
mention is never split) plus delete-command advice that removes the whole
span at a boundary; because the buffer text stays canonical, sending is
unchanged. Completed file picks are atomic chips too (they display their own
`@path`), so a whole file mention is removed in one backspace; a mid-drill
directory token stays plain. Accepted limits: the guard covers the common edit
commands; killing a selection that overlaps a chip can still truncate it (an
explicit delete).
