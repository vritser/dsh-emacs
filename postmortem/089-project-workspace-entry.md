# 089 — Locate the project workspace when opening dsh

Pending-navigation lifetime superseded by
[090](090-project-navigation-user-control.md).

## Background

At `bbdae5d`, `dsh-emacs` always opened the session list at the last active
session, even when invoked from a different project. Project detection and
canonical workspace matching already served new-session creation (006).
The missing behavior belonged to entry context and list navigation, not RPC.

## Decision

Capture the invoking buffer's project root in `dsh-emacs` and pass it to the
list opener. The list owns a pending project root, resolves it against the
existing workspace cache, unfolds the matching group and focuses its header.
Project matching takes precedence over the previous active session. Chat and
session-list buffers keep their existing navigation, as does `C-c C-l`.

## Why

The project root must be captured before switching to the shared list buffer.
Reuse the existing project detector and canonical path matcher rather than
introducing a second interpretation of workspace identity. Retaining the
root until a match arrives covers asynchronous startup without new RPCs or
transport changes. Focus the header so an empty workspace is equally useful:
`c` already creates a session in the workspace under point.

Opening a list is navigation, so it does not register workspaces. The
new-session auto-project option continues to govern creation only. Local
paths are compared only for a local server and a non-TRAMP caller.

## Consequence

A successful jump is consumed, so ordinary repaints preserve subsequent
navigation. Other groups retain their fold state. A workspace filter is
cleared to expose the target. Existing session fallback remains available
while no project workspace is known, and reopening the list replaces the
pending project. README, customization docs and the changelog describe the
entry behavior. This record covers the uncommitted change after `bbdae5d`.

## Known limitations

There is no workspace creation or remote path mapping. If no match exists,
the project target remains pending until it arrives or the list is reopened
or killed, following the existing asynchronous session-target model.
