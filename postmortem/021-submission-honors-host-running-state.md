# 021 — Submission honors host running state

## Background

The chat stream's `turn/start` and `turn/end` events drive its mode-line busy
flag. The independent core stream also carries the host's session running
status, and can arrive first. Submission consulted only the mode-line flag, so
ordinary `C-c C-c` could mistake a running host turn for idle, use plain
submission, and optimistically render a user transcript row. Postmortem 014's
explicit `C-u C-c C-c` steer had the same dependency.

## Decision

Busy-state decisions consult both the chat-local flag and the cached host
session's running status. A nonempty `C-u C-c C-c` enters the deferred
submission path with `mode: "steer"` before either state check. Empty-input
behavior is unchanged.

## Why

The mode-line flag is a UI projection, not the sole authority for submission.
Ignoring an already-known host running state turns queued input into a new-turn
send. Likewise, a stale local projection must not rewrite an explicit steer
request into queue semantics. The deferred path correctly avoids a user
transcript card until the host claims the message.

## Consequence

Plain input follows `dsh-emacs-busy-enter-behavior` when either live source
says the host turn is running. Prefix steer has one meaning during busy-state
races and normal operation. Tests cover core-running/chat-idle disagreement,
explicit steer with local idle state, and genuinely idle unprefixed submission.

## Known limitations

The client does not add another host-status query before submitting. Doing so
would introduce a race of its own and unnecessary latency; `session/prompt`
admission remains the server's responsibility.
