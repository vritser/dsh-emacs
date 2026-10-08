# 085 — Keep seed boundaries out of the transcript

## Background

Record [040](040-core-event-rendering.md) chose to show restored history
boundaries as muted rows. At the `5fb6674` baseline, each `session/end-seed`
still renders a `── seed boundary` divider, optionally labelled inherited
history. Repeated inheritance can leave several internal markers in a chat.

## Decision

Consume `session/end-seed` directly in the renderer dispatcher, returning
its sequence to advance the anchor, and remove the divider renderer.
This decision is recorded in the commit `fix: hide seed boundaries`.

## Why

The event describes history construction and requires no action from the
reader. Its presence in the protocol does not require visible transcript
content. Removing the row reduces noise without changing history or fork
semantics; a visibility option would add configuration for no current need.

## Consequence

Refreshed and newly rendered conversations contain no seed divider.
The event still advances sequence tracking. Tests cover inherited and plain
seed markers, requiring unchanged buffer text and the expected anchor.
The changelog and RPC rendering documentation describe the new behavior.

## Known limitations

Already rendered buffers need a refresh after loading the updated code.
The transcript no longer identifies the exact restored-history boundary.
