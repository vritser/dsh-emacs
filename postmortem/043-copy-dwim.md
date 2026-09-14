# 043 — One context-aware copy key

## Background

`C-c C-w` (`dsh-emacs-copy-transcript`) copied the whole visible chat buffer
verbatim: welcome header, every `❯` user prompt, tool cards, thinking blocks,
code-panel chrome and the input line included.  `C-c C-k`
(`dsh-emacs-copy-code-block`) copied one fenced block's body.  There was no
way to lift the model's answers alone — the common case when a reply is to be
pasted somewhere else — and no single key that picks the obvious unit under
point.

Two existing facts shaped the fix.  User bodies already carry the
`dsh-emacs-user-message` text property (`dsh-emacs-imenu-create-user-index`
scans it), so "which text is whose" was an established buffer-level question;
assistant bodies had no marker.  And the transcript is trimmed in place
(`dsh-emacs-render--trim-buffer`) and can be copied out of the chat buffer, so
the copy command must read the buffer rather than a parallel log.

While wiring the context-aware command, a latent hang surfaced in the
pre-existing `dsh-emacs--code-block-region-at`: `next-single-property-change`
returns its LIMIT (not nil) when the property never occurs, so the scan
treated `point-max` as a found block and looped there forever whenever the
buffer held no code block.  `C-c C-k` at the input area — point at
`point-max` — hung Emacs.

## Decision

Tag every assistant body with a `dsh-emacs-assistant-message` property and
make `C-c C-w` a context-aware `dsh-emacs-copy-dwim`; the narrow copies stay
as unbound commands.

- `dsh-emacs-render--insert-chat-message` takes a `role` (`user` /
  `assistant`) instead of the old `user-message` boolean and tags assistant
  bodies.  Streamed replies are tagged in
  `dsh-emacs-render--protect-stream-region` (all three callers are assistant
  streams), in `dsh-emacs-render--start-assistant-stream`'s live insertion,
  in `dsh-emacs-render--flush-stream`'s timer append (the one path that
  inserts body text without going through the markdown pass), and in
  `dsh-emacs-render--finish-assistant-stream`'s final replacement.
- The property **value** is the message's event id (falling back to `t`), not
  a constant: `next-single-property-change` splits on value, and the
  transcript stacks adjacent replies flush with no separator, so a constant
  value would merge them into one run.
- `dsh-emacs--assistant-message-region-at` returns the run containing point
  (forgiving whitespace immediately after a body);
  `dsh-emacs--assistant-message-bodies` walks all runs;
  `dsh-emacs-copy-assistant-message-at-point`,
  `dsh-emacs-copy-last-assistant-message` and
  `dsh-emacs-copy-assistant-message` copy one / the newest / all.
- `dsh-emacs-copy-dwim` resolves in one order: active region, else code block
  at point, else assistant message containing point, else the transcript's
  most recent assistant message.
- `dsh-emacs--code-block-region-at` stops when the scan reaches `point-max`
  instead of treating the limit as a block, and caps the run-end lookup.

## Why

Buffer-derived extraction keeps the commands honest for free: text that was
trimmed, replaced by a compaction replay, or pasted into another buffer is
never copied, and no second store has to be reset on session reload or kept
in sync with `dsh-emacs-max-buffer-size`.  It also inherits the code-block
copy's property-travel behavior (`dsh-emacs-markdown-source-block-body`): a
propertized copy of the transcript into another buffer is still scannable.

A separate list of rendered message texts was the alternative.  It would give
clean Markdown source (no rendered code-panel labels), but it needs its own
reset path, its own trim accounting, and it diverges from what is on screen.
The property is nothing new: `dsh-emacs-user-message` was the exact
precedent, and the markdown renderer already carries unknown text properties
across its delete+insert passes (`dsh-emacs-markdown--carry-properties`).

The event id as the property value is what makes the flush stacking
reversible: without it, `dsh-emacs--assistant-message-bodies` could not tell
two adjacent replies apart.

`C-c C-w` becoming the dwim — rather than a new key or a `C-u` variant — was
chosen because copy is one verb and the key people already press should do
the obvious thing.  The narrow commands were deliberately left **unbound**:
once the dwim covers region, code block, one reply and all replies, a second
and third copy chord only spend keys on cases the one chord already reaches
(`C-c C-k` was unbound with them; `C-c C-e` was tried for the full transcript
and dropped for the same reason).  A shifted `C-c C-W` was the first try for
the transcript and is a trap: `kbd` and terminal input normalize control keys
to lower case, so `C-c C-W` is the same event as `C-c C-w` and the second
binding silently replaced the first.  Region first is the Emacs convention,
and code block before message is the smaller unit: a block inside a reply is
more specific than the reply.  The fallback is the **most recent** reply —
the answer the user just read — not the whole reply set: "copy what I am
looking at" is the dwim's job, while collecting a session's answers stays a
separate command (`dsh-emacs-copy-assistant-message`).

The hang is fixed at its layer (the block scanner), not worked around in the
dwim: `dsh-emacs-copy-code-block` reaches the same function, and a command
that can hang the editor is a bug wherever it is called from.

## Consequence

`C-c C-w` copies the region / code block / message at point / most recent
reply.  `dsh-emacs-copy-code-block`, `dsh-emacs-copy-transcript`,
`dsh-emacs-copy-last-assistant-message` and `dsh-emacs-copy-assistant-message`
remain as commands, reachable only through `M-x`; the block scanner now
reports `Point is not inside a code block` instead of hanging when point is
at `point-max` with no block.  The assistant role is explicit at the
renderer's insertion boundary, so later role-dependent features have one
place to hook.  Docs touched: CHANGELOG 0.4.0 `Breaking Changes` + `Added` +
`Fixed`, the README key table.  Twelve assertions in `test/dsh-test.el` pin
role filtering (user prompt, tool card and transcript chrome excluded), the
blank-line join, the dwim precedence (code block, message at point, region,
last reply), the standalone last-reply command matching the fallback, the
keymap (only `C-c C-w`, with `C-c C-e` / `C-c C-k` free), the
empty-transcript `user-error`, the live-stream case (first delta and timer
flush), and the `point-max` scan termination.

## Known limitations

- Copying uses the rendered assistant body, so a fenced code block comes
  through as its panel body rather than its original ``` fence (the
  `LANG ⧉` label line is part of the body).  `M-x
  dsh-emacs-copy-code-block` remains the clean single-block copy.
- `copy-dwim` inside a *user* message falls through to the most recent
  assistant message; there is no "copy this user prompt" unit yet.
- Only committed replies and in-progress streams are tagged;
  `assistant/attempt` cards (no committed message) stay out.
- The property marks the message body, not the turn: per-message footer
  actions (copy among them) remain a separate, unbuilt feature.
