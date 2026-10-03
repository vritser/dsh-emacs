# 072 — Read the plan before deciding

## Background

The status work following `2c22407` exposed Plan mode but reused the ordinary
question reader for review (071). A real GUI demonstration showed the cost:
the document stayed inside a collapsed generic tool call while the minibuffer
asked for approval. The protocol constructor also discarded `plan-review`
intent. The failing layers were protocol, rendering and question UI; the
existing host waterfall already carried the complete document and actions.

## Decision

Give submitted plans readable document buffers with explicit asynchronous
review actions, while keeping ordinary questions in the existing reader.
This uncommitted change follows the staged status work on `2c22407`.

## Why

A long document needs ordinary scrolling and time to read. A completion prompt
occupies the minibuffer without supplying a good place for the document.
The new `dsh-emacs-plan.el` owns that document workflow; the main entry point
only routes supported questions, the renderer owns transcript cards, and the
protocol module owns the payload fields. No frontend-private APIs, recursive
edit, timers, new RPC or second persistence store are needed.

"Request changes" dismisses the waterfall and returns to chat, matching Web.
Sending the host's "Keep planning" label would instead tell the agent to
revise immediately, before the user has written feedback. Closing a document
is separate from either decision. Pending requests live in the chat so killing
the document does not silently answer or abandon them.

The request captures its connection identity and has explicit sending and
retirement state. The host may cancel the waterfall before the HTTP reply;
its acknowledgement may still finish the user's own decision. Connection or
chat retirement invalidates even that callback. Failed submissions retain
their actions and explain the error instead of leaving an inert document.

## Consequence

Plans open automatically for reading. Buttons and `C-c C-c` / `C-c C-k`
approve or request changes; `C-c C-z` returns to chat, and `q` closes only the
window. `dsh-emacs-plan-review` reopens a pending review. Transcript cards
retain their title and document through settlement and history reload.
Ordinary questions, unsupported intent shapes and status projections keep
their existing behavior. README, slash-command, RPC, architecture and styling
docs describe the workflow; CHANGELOG links this record.

## Known limitations

Transcript cards follow `dsh-emacs-show-tool-calls`; pending documents remain
available independently. Only native `exit_plan_mode` calls produce historical
cards; a review without a recorded call id is readable during the current
client lifetime but has no independent durable document. Older unloaded plans
become available when their history is loaded. A reconnect expires local
actions; only a fresh host question can grant new ones.
