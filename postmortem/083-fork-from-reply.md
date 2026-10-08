# 083 — Fork through the reply at point

## Background

At `763e6a6`, session-list `f` sent `session/fork` without `atSeq`, so users
could branch only through the latest completed turn. The Web client's reply
action exposes an earlier boundary. The missing layer was the Emacs command
and rendered-message identity: the RPC already supports an inclusive event
sequence, but body properties identify display blocks rather than durable
fork boundaries. Record 043 established assistant-body properties for copy.

## Decision

Expose `dsh-emacs-fork-message-at-point` on `C-c C-y`, passing the selected
reply's durable sequence to `dsh-emacs-fork-session` as its optional second
argument. The protocol module serializes the request; the renderer stores
`dsh-emacs-message-seq` on committed assistant bodies, including every
settled text segment and pending Markdown state. Stream states reserve the
`:seq` slot at construction so filling it preserves their shared identity.

## Why

The server event sequence is authoritative. Parsing display block names or
using the buffer's latest watermark would select the wrong boundary for
streamed or older replies. A text property follows the visible body through
Markdown and history paging without adding another history cache. Partial
streams have no durable sequence and are rejected, rather than guessing a
nearby event. The existing fork operation owns child opening and the
subagent restriction. Session-list `f` retains its current meaning.

## Consequence

Users can branch from an earlier answer, including from inside its code
blocks. The original session remains intact; the child includes the selected
reply and omits later events. No confirmation is needed for creating this
separate conversation. Tests cover selection of an older reply, session
identity, zero/omitted boundaries, segmented streaming, deferred Markdown,
and rejection of non-replies and subagents. README, customization and RPC
documentation describe the two entry points.

Implementation: `feat: fork conversations from replies`, following `763e6a6`.

## Known limitations

Only committed assistant text bodies are selectable. User messages,
thinking/tool cards, and replies without visible text have no point-based
entry. There is no mouse footer action. Exact cuts require the dsh 0.1.7+
semantics in `docs/rpc.md`; the server owns synthetic closure of open turns.
