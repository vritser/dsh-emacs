# 181 — Use xref for navigation return history

## Background

At baseline `067698b`, child conversations recorded an xref departure after
receiving their first follow snapshot. File references, ordinary sessions,
local Markdown links and other selected document buffers did not share that
return path. Revisiting a live child also waited for a snapshot that would
not arrive. The inconsistency belonged to UI navigation.

## Decision

Use Emacs's xref history for explicit navigation that changes the current
buffer or point. `dsh-emacs-ui-navigate` receives the original departure
marker, performs the operation and records it after successful navigation.
Callers retain markers across asynchronous image fetches and plan decisions.
Session opening owns the live-chat entry; cold children retain the existing
follow-snapshot success gate. This is the working-tree change after `067698b`.

## Why

One return mechanism covers file references, same-file line links, session
switches, the session list, new drafts, skills, configuration, plans, images
and retained job output. Existing xref bindings and history storage remain
usable. A marker follows edits in the source buffer while the user is away.

Global advice on `find-file` or buffer selection would affect unrelated Emacs
navigation and background work. Recording at explicit package navigation
sites keeps the ownership local. Passing the departure explicitly avoids
recording an RPC callback's incidental buffer as the origin.

## Consequence

`M-,` returns to the departure position. Errors, cancellation and no-op visits
do not add entries. Existing parent/child paths no longer double-record, and
live children need no new follow frame to become returnable. The implementation
uses the public xref push API available in Emacs 28.1 and leaves keymaps alone.

## Known limitations

This is return history, not an `M-.` definitions backend. External browser
launches and passive help or preview displays keep their existing behavior.
A killed source buffer cannot be returned to. First-time child navigation is
recorded only after its follow snapshot succeeds, preserving the earlier
subagent contract. Session-list redraws already preserve row markers.
