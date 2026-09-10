# 038 — Client-side shell commands

## Background

At repository baseline `ce1ef7c`, prompt submission only sent model input or
host slash commands. The local `!command` feature lets users inspect a
workspace or run a build from the chat while a model turn continues. This
record describes the final design of that still-uncommitted feature; the
baseline commit does not implement it.

## Decision

Inputs starting with `!` and carrying no attachments run locally through
Emacs's `shell-file-name` with `-c`, in the chat's `default-directory`.
The interactive entry routes them before server and busy-state checks;
programmatic submission applies the same admission rule. An image caption
starting with `!` remains model input, preserving both text and attachments.
Multiline commands retain their embedded newlines.

`dsh-emacs-shell.el` owns execution, confirmation, and process cleanup;
`dsh-emacs-render.el` reuses command-row fragments and spinners. Each chat
tracks the launched shell until termination. A new command, explicit stop,
buffer closure, or major mode reset stops the tracked shell. Stop/continue
notifications retain its resources; exit/signal notifications release its
output buffer and timeout even if the chat is already dead.

EOF is supplied by closing the input pipe. The optional timeout accepts nil
or positive integer seconds; invalid settings fail before clearing the draft
or stopping an existing run. Confirmation can be enabled, and declining it
preserves input, history, and the current run.

## Why

Local execution needs neither a host command catalog nor a model round-trip.
A separate execution owner keeps process lifecycle out of the RPC client,
while shared fragments avoid inventing another transcript card type.
Attachments stay on the model path because captions describe their images;
interpreting that text as code would discard the user's attachment intent.

The executable follows Emacs configuration, which can differ from the current
`SHELL` environment. Pipe EOF keeps the command unchanged across shell
syntaxes. It is not a terminal or a timeout: vim may remain running after EOF.

The process table is not a descendant supervisor. A probe using
`sleep 30 & printf '%s' "$!"` returned shell exit 0 while its child survived
chat closure; the probe then killed its own child. Managing background or
detached descendants requires a separate lifecycle design and remains deferred.
The documentation therefore limits cleanup and timeout guarantees to the
tracked shell rather than promising that no orphan can survive.

## Consequence

Users get immediate local shell access with a pending row, exit status,
collapsible output, optional confirmation, output display cap, stdin EOF,
and optional timeout. Shell output is not sent to the model or saved in
server history: a history reload discards local rows, and reopening the
session does not restore them. Input recall is separate from output storage.

Unit coverage exercises submission with attachments, busy/offline routing,
confirmation, direct cancellation, mode reset and buffer teardown, late
exit cleanup, multiline execution, shell-independent EOF, and timeout
validation. User-facing details live in `docs/shell-commands.md`; the feature
has one entry under Added in CHANGELOG 0.3.0 Unreleased.

## Known limitations

- With the default timeout of nil, a TUI or other command may run until
  explicitly stopped. Interactive programs need a terminal.
- Background or detached children may survive their shell and fall outside
  subsequent tracking, cleanup, and timeout operations.
- Output appears only on completion and is capped for display only; the
  hidden process buffer can grow before completion.
- Local result rows are transient and disappear on history reload.
