# 124 — One owner for the question and approval prompt slot

Module placement superseded by [175](175-interaction-module-owner.md);
the shared-slot and service-order decisions remain in effect.

## Background

At `3c4f069`, questions and approvals kept separate active-frame variables and
drain loops. Each loop checked both variables and called the other drain after
emptying its own queue. Late answers temporarily occupied the question
variable, and cancellation also needed a separate prompt event id. These
represented one shared minibuffer resource with overlapping state.

The existing order was FIFO within each kind, not across both kinds. A
question reader receiving A1 and then Q2 would finish Q2 before presenting A1.
[073](073-timed-question-answers.md) also requires a late reader to reserve the
slot, and a timed wait claim to survive until the answer's RPC acknowledgement.

## Decision

Keep the two queues and replace both active variables and mutually calling
drains with one owner and one iterative scheduler in `dsh-emacs.el`.
The owner stores only `(kind . event-id)`, or `(late-answer)`. Each queued
frame dynamically binds the owner and cancellation marker around its handler.
Question and approval handlers retain their distinct readers, result formats
and error handling. Remove the redundant prompt event id.

This records the third refactoring batch based on `3c4f069`,
following [123](123-decoded-stream-and-tool-results.md). It changes internal
ownership without adding a command, option or workflow.

## Why

One owner makes simultaneous question/approval ownership unrepresentable.
Dynamic scope covers reentrant stream delivery during a real minibuffer read
and restores ownership on exit without paired setters. A loop makes handoff
explicit and avoids accumulating drain calls as the queues alternate.
The small `(kind . event-id)` value is enough for deduplication and cancellation;
the complete frame stays local to the answering function.

A unified FIFO would change which prompt appears next. A new interaction
module or generic scheduler registry would add indirection to two existing
handlers without improving their ownership. Keep the current service order
and the implementation beside the question and approval flows.

## Consequence

The initiating kind drains first and switches only when its queue empties.
Late-answer cleanup starts with questions, as before. Cancellation checks kind
as well as event id: the host dispatch calls question cancellation before
approval cancellation, so an id-only match could abort the latter too early.
Reload and the E2E harness inspect the one active owner.

The prompt slot ends after synchronous reading/submission. A timed question's
claim remains a per-frame closure resource until the HTTP callback, so another
prompt may run while that claim still protects the previous answer. Plan
review continues outside the minibuffer queues.

## Known limitations

Continuous arrivals of the current kind can delay the other queue. Changing
fairness would be a separate workflow decision. Connection-generation
retirement still clears queued frames without forcibly closing an active
reader, preserving its existing behavior. Source reload does not remove old
definitions; restart for complete removal, as described in
[115](115-source-hot-reload.md).
