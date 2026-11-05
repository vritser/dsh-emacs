# 187 — Explicit single-service lifecycle and public profile integration

_Interactive reopening policy superseded by [189](189-interactive-entry-reconnect.md)._

## Background

The v0.8.0 baseline (`7b03e89`) supported one implicitly selected endpoint.
Work in 182–186 addressed concrete startup, transport and retirement failures,
but changing the URL still left service buffers, catalogs, readers and actions
owned by the old service. The failing boundary was lifecycle coordination:
an external switcher could not reliably clean up through public APIs.

## Decision

Make the core own explicit connect/disconnect and read-only state APIs, and
ship the project resolver/selector as an optional independent package source.
Implementation commits, based on `7b03e89`:
`feat: add explicit service connection lifecycle` and
`feat: add optional project service switcher`.
See the 0.9.0 Unreleased entries in
[CHANGELOG](../CHANGELOG.md) and [API guide](../docs/server-switching.md).

The server module owns connection generation, authentication, attempt lifetime
and registered asynchronous reads. The entry module coordinates preflight,
owner cleanup and cold baselines. Existing feature modules clear their own
state. Buffers, HTTP and event processes share one ownership predicate.

## Why

A URL, cookie or session id can recur after A → B → A. A generation plus an
Emacs instance identity for external notification actions prevents stale work
from becoming current again. Module-specific request identities still protect
ordinary overlapping operations within one connection.

Preflight refuses content or unacknowledged writes before mutating anything.
Cancelling an HTTP write cannot prove the server did not accept it. Active
readers can resume after a timer fires, so they also block synchronous cleanup.
Closing old service buffers avoids pretending a read-only chat has no active
commands. Failed cleanup retains resources for retry instead of exposing a
partially cleaned client as ready for another service.

Read cancellation suppresses business callbacks while owner cleanup clears
all corresponding state; explicit server stop retains the older failure
settlement contract. Connect cancellation notifies after disconnect returns,
so user callbacks cannot reenter half-finished cleanup. A persistent extension
buffer gives asynchronous work a meaningful lifetime without a permanent core
origin buffer or callbacks running in unrelated buffers.

The extension has no Docker assumptions: each resolver can start a container,
resolve ports and obtain fresh credentials. Public snapshots suffice for root
session selection. Adding a generic multi-service registry, retained copies of
all service state or a draft migration framework would solve a different task.

## Consequence

Users can disconnect safely, connect to an existing service, or select a
project profile. Connect success includes authentication, core baselines and
the session directory. Old actions expire; drafts and writes block switching;
managed processes survive disconnect. The first-use default startup workflow
still works. After explicit disconnect, service work requires explicit connect.

Coverage includes retry after refused buffer cleanup, deferred cancellation,
origin closure, snapshot deep copies, unknown child catalogs, HTTP/event/timer
ownership and both notification action formats. The manual dual-service
harness exercises the same Emacs on A → B → A against Docker dsh 0.2.1-rc.2,
without model requests. Real GUI readers cover token entry, blocked disconnect,
profile selection and session selection.

## Known limitations

One connection is active at a time. Unsent drafts must be handled before a
switch; optional draft export/restoration (P3) is intentionally deferred.
Old buffer folding, point and undo are not restored. Last profile session ids
are memory-only. Paths and shell commands remain local to Emacs. No automatic
rollback follows a failed new connection. Resolver errors are intentionally
reported without their potentially credential-bearing details.

The optional package declares core 0.9.0 and must not be independently published
before that core release. No remote repository or publication is part of this
implementation. Live model-turn continuity, desktop OS notification delivery
and child-frame focus perception are not claimed by these acceptance probes.
