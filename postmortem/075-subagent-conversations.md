# 075 — Address child conversations through their direct parent

Navigation UI superseded by [076](076-subagent-minibuffer.md). Protocol and
capability decisions remain applicable.

## Background

After `68da9c6`, dsh-emacs hid child sessions from the main list and discarded
subagent projections. The design review identified separate failure paths:
ordinary addresses fail for child history, repeated summaries were ignored,
and running/idle cannot express whether an Agent still exists.

## Decision

Use the existing control stream for durable child catalogs, identity, timing
and cumulative usage, with per-cell sequence cuts and on-demand cold reads.
Reuse session summaries for activity and three-state availability, merging live
facts without overwriting projection cells. One module owns the browser and
store; protocol owns wire decoding, tokens owns arithmetic, and the existing
chat/input/composer owners handle addressed conversations and capability gates.

Keep a native special-mode tree and xref return history. No extra chat prefix,
custom return stack, client spawn command or compulsory completion frontend.
This record describes the uncommitted implementation following `68da9c6`.

## Why

A real-server spike resolved the RPC reference's blanket rejection wording:
installed dsh 0.2.0-rc.2 accepts child projection reads while running and after
settlement; the settled read leaves Agent availability false. Both follow and
page must still carry the direct-parent address. A root id substituted for a
nested child's direct parent is not equivalent authority.

Cold-read callbacks belong to a host-owned buffer so a closed browser cannot
strand loading state. A display timer only updates visible elapsed durations;
it does not poll the server. Read-only presentation protects normal editing,
while command guards stop unsupported RPC paths independently.

The first real E2E found a missing `_request` argument on the new session-list
refresh, leaving input closed after reconnect. A failing payload assertion
preceded the fix; the complete running-Emacs E2E then passed all 32 checks,
including paging, xref return, follow-up, stop and reconnect input recovery.

## Consequence

`M-x dsh-emacs-list-subagents` and the mode-line tree icon with child counts
(`Sub` fallback) expose the hierarchy. `n/p`, `RET/o`,
`TAB`, `^`, `g`, `q` and `M-,` retain native navigation conventions. Stop and
details are named commands; child chat send/steer/stop reuse existing bindings.
One-shot input and unavailable-parent input are read-only. Token totals are
session projections including cache components, not a billing calculation or
another feed into the chat's message accumulator.

## Known limitations

One-shot children cannot be interrupted through the subagent control endpoint.
Queue mutations, attachments, session configuration, slash/skill commands and
late question answers are unavailable in child chats. No full `M-.` xref
backend is installed; xref is used for return history. Model-driven delegation
E2E requires `DSH_E2E_SUBAGENTS=1` and a working provider; synthetic summary
frames cover parent disposal/reactivation deterministically.
