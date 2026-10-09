# 086 — Separate the reply action target from the turn's end

## Background

At `ae201a0`, reply footers used the final committed text segment as both
the Copy/Fork target and the insertion position. A Deliverables row could
follow that segment. The first uncommitted fix handled that row explicitly;
an event audit reproduced the same ordering error with tool cards, thinking,
failed attempts, automatic compaction failures and turn-end errors.

## Decision

Keep the last text reply as the action target, but place the footer after
the actual final content rendered when `turn/end` is consumed. The renderer
stores the last fragment's namespace/block identity or the message identity
in the existing turn summary and resolves its current bounds when painting.
This record accompanies the uncommitted correction against `ae201a0`.

## Why

A final text reply is not a turn boundary: the run can finish with a tool or
a diagnostic instead of another answer. Adding exceptions for each event
would repeat the original ownership mistake. Content identities already
survive fragment replacement, folding and Markdown formatting; storing them
also avoids introducing another set of mutable position markers. The existing
history insertion boundary keeps older turns independent of the live tail.

## Consequence

The footer follows the turn's complete visible content while Copy/Fork keep
their original reply semantics. No new options or commands are introduced.
Regression cases cover live rendering, history, cross-page completion and
reconnect deduplication, alongside delivery expansion and delayed Markdown.

## Known limitations

A footer still requires a visible committed text reply and a recorded turn
end. Standalone events occurring after that end remain separate transcript
content; they do not move the completed turn's footer.
