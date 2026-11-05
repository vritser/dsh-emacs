# 185 — Retire event transports before releasing their resources

_Unbounded handler retry superseded by [188](188-bounded-cleanup-and-upgrade-ownership.md)._

_Lifecycle scope superseded by [187](187-single-service-lifecycle.md)._

## Background

At `7b03e89` (v0.8.0), explicit core disconnect cleared its process variable
before deleting the socket. The loss handler deliberately recovered unowned
core sockets after source reload, so the deletion sentinel could schedule a
new connection while a chat still needed the core. Cancelling a timer also
did not prevent an already-queued callback from operating on its replacement.
The failing layer is events, not rendering or the mode line.

## Decision

Mark intentionally closed sockets retired before closing their logical streams
or deleting the process. Event filters, parsers, dispatch continuations and
sentinels ignore retired sockets. Recovery timers check that their captured
timer still owns the corresponding slot. Successful cleanup releases the owner
handle; failed stream handlers and their retired handle remain available for a
subsequent disconnect call to retry.

## Why

An unowned socket is not necessarily intentionally closed: source reload still
needs to recover a legacy connection. A process-local retirement state separates
that recovery from explicit teardown without treating the server endpoint as
the transport's identity. Timer identity similarly distinguishes a cancelled
callback from the new timer occupying its former slot.

Cleanup must invalidate producers before invoking feature callbacks. The parser
can yield while replying to a Ping; when it resumes, it must not reinstall its
locally accumulated messages or slice the input that teardown already cleared.
A failed close handler must not lose the remaining cleanup work. Successful
handlers are removed individually, failing ones remain for retry, and the socket
is deleted even when a handler signals.

## Consequence

Explicit core/chat disconnection no longer initiates recovery by itself. New
explicit connection requests and genuine connection loss still recover normally.
Core disconnect clears its client id, read/dispatch timers, queued bytes/messages
and logical-stream registrations. Chat disconnection retires transport resources
before flushing already-rendered pending text. Reentrant transport retirement is
rejected while a feature callback is still closing that transport.

This is uncommitted work based on `7b03e89`, following prerequisites 182–184.
Regression tests cover real process sentinels, late filters, manually delivered
cancelled timers, parser reentry and failed-handler cleanup retries. The event
subsystem's 82 tests and the complete `scripts/verify.sh` pass. On each of two
isolated Docker services, real core/chat WebSockets remain closed beyond the
reconnect delay while a chat still needs them; an explicit reconnect creates
fresh sockets and RPC remains available. Each service uses a separate Emacs,
so this does not establish cross-service switching. CHANGELOG and architecture
document the scope. No remote CI was run for this uncommitted work.

## Known limitations

These are event-module disconnect operations, not the planned public single
service lifecycle. They do not clear all service caches, preflight user drafts,
cancel business HTTP requests or retire old chat controls and notifications.
A new deliberate command can still request a connection. The lifecycle
coordinator must enforce its own disconnected/cleaning states and connection
generation before exposing safe service switching.

Cleanup callbacks should tolerate retry after a partial failure. This change
does not turn arbitrary feature or user callbacks into transactional operations;
errors remain visible. The retained failed process handle supports retry while
its owning buffer/state exists, not persistence after Emacs exits.
