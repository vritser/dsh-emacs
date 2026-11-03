# 170 — Keep event health and frontend knowledge with their owners

> Superseded by [173](173-native-menu-selection.md), which removes the private
> Vertico read.

## Background

On the `108ea2b` baseline, chat and core dispatch wrapped JSON parsing in an
inner silent catch despite having an outer diagnostic boundary. Queue and job
menus separately read Vertico internals. Prompt acceptance also inspected the
event socket's private readiness state to decide whether to reconnect.

Implementation: `refactor: keep event and completion state with their owners`.
The submit transaction and menu-selection policies remain intact.

## Decision

Malformed JSON reaches the existing outer chat/core error handler. Valid JSON
that does not describe a relevant frame remains silent. Put optional Vertico
highlight lookup in the existing UI module; queue and job modules retain their
typed-label, prefix and default-item policies. Let the event module start the
accepted turn's watchdog and recover a missing follow connection, leaving a
live handshake alone. The submit callback owns request acceptance and rollback.

## Why

Transport corruption and unrelated frames need distinguishable diagnostics.
An inner catch erased that distinction, while adding another reporting layer
would duplicate the boundary already present. Sharing the actual frontend
seam prevents its private-field assumptions drifting across menus without
introducing a generic menu framework. Connection health belongs with the
process and handshake state; callers should request that guarantee rather
than reproduce its conditions.

## Consequence

Bad JSON now produces a layer-specific message. Typed and highlighted menu
selections keep their existing meaning. Prompt echoes, history, busy-state
races and restoration of newer drafts retain their existing contracts.

## Known limitations

The optional Vertico seam still reads its private index/candidate variables;
that dependency is isolated in one function. The installed Vertico and stock
completion paths passed a real terminal Emacs probe, including highlighted
and typed selections through both menu consumers. GUI verification remains
open: LaunchServices could not launch the installed application, and its
direct GUI invocation exited before loading the probe. Other frontends keep
the existing typed-label fallback. Decode diagnostics do not attempt to
repair or replay a corrupt frame.
