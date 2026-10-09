# 084 — Actions and statistics below the final reply

_Footer placement is superseded by [086](086-reply-footer-turn-tail.md)._

## Background

`5fb6674` exposed exact reply branching through `C-c C-y`, but its
discoverability depended on knowing the command. The requested footer also
needs per-turn tokens and time, whereas the mode line accumulates session
usage and its step clock measures live observation time. Reusing either
would present the wrong statistics for historical replies.

## Decision

Render one configurable minimal row below the last committed text reply of
each completed turn. `dsh-emacs-reply-footer-items` defaults to `(copy fork
usage duration)`; nil disables it. Stock text buttons copy the selected
reply's original Markdown or call the existing fork command with its seq.
The protocol module decodes facts; the renderer owns summaries and placement.

## Why

One row per turn gives the requested turn statistics a single visible home
without adding a toolbar after every intermediate model step. A summary keyed
by turn, with usage keyed by event seq, merges partial historical pages and
reconnects without a second transcript cache. Missing starts or usage remain
explicit lower bounds; missing times remain unknown. Server timestamps give
historical turns their actual elapsed interval, including tool and user waits.
Synthetic fork closers are not elapsed-time endpoints.

Buttons retain source text and event identity instead of scanning backwards
from the click. Thus copying preserves Markdown even when rendering divides
a reply into several text/thinking segments. The footer is a separate
fragment, never assistant text. Settled pending-Markdown end markers reject
later insertions so deferred formatting cannot absorb the row. Older-history
batches finish collecting facts before placing rows against their last reply.

## Consequence

Items can be reordered or removed independently; existing chats need a
refresh to apply configuration changes. Subagent footers hide Fork. Full
reload clears summaries; trimming discards completed summaries whose reply
text is gone. Tests cover actions, item order/off, cache-inclusive totals,
incomplete history, page merging, reconnect dedup, deferred Markdown, live
settlement, and synthetic timestamps. GUI acceptance exercises real RET and
TAB navigation; the transport E2E suite uses the configured local server.

This change follows `5fb6674` and is recorded in the commit
`feat: add configurable reply footers`.

## Known limitations

Only completed turns with a visible committed text reply have a footer.
Reported assistant usage excludes separate compaction and delegated-child
usage; unavailable attempt usage prevents claiming an exact total. Copy's
source Markdown intentionally differs from the existing body-copy command's
rendered text. The summary does not request extra history in the background.
