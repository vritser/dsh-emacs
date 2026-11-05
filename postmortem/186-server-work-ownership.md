# 186 — Keep HTTP and prefetch work with its server attempt

_Lifecycle scope superseded by [187](187-single-service-lifecycle.md)._

## Background

At `7b03e89` (v0.8.0), a delayed successful RPC could update state after stop.
The uncommitted fixes in 182–185 protect cookie replacement, startup and event
teardown, but startup's generation did not reach business HTTP. Command/skill
prefetch retained only a session id, so the timer could send from an unrelated
buffer to whichever endpoint was configured when it fired. The failing layers
are transport and deferred catalog work.

## Decision

Extend the server-owned generation and its single ownership predicate to HTTP
and delayed command/skill prefetch. Stop invalidates their captured generation
even at the same endpoint with the same cookie. Preserve the existing startup
guards and each business operation's separate request identity.

## Why

Checking only a URL or cookie cannot distinguish work from before and after
stop. Checking only before sending also misses lazy authentication, synchronous
network waits and response-buffer cleanup hooks that can yield before the
result reaches its consumer.

Dropping callbacks would leave submissions, uploads and cache reads pending.
An expired response instead completes as failure in its live origin, with its
owner bound through that immediate completion chain. New request and readiness
entries reject the expired owner before authentication or network side effects,
including in batch mode. A delayed timer cannot inherit that dynamic scope;
prefetch therefore explicitly captures both the owner and the originating
buffer before scheduling, then validates them before registering a fetch.

## Consequence

Old HTTP success and 401 responses cannot install successful results or expire
newer auth. Local failure settlement remains available, and a new command can
make a fresh same-endpoint request after the cancelled callback returns.
Prefetch no longer runs in an arbitrary timer buffer or after its origin closes.
No new command, option, retry policy or service-switching interface is added.

This uncommitted change is based on `7b03e89` and prerequisites 182–185.
Regression tests fail before their respective fixes and cover synchronous RPC,
asynchronous RPC/uploads, same-cookie cancellation, completion-chain rejection,
authentication/cleanup reentry and prefetch origin lifetime. CHANGELOG,
customization and architecture record the scope.

The complete `scripts/verify.sh` gate passes. Real HTTP against both isolated
Docker services passes with controlled delivery order: old async and sync
results fail after stop, auth remains intact, response buffers are released,
and fresh same-endpoint requests succeed. The first subsystem run could not
bind a local test socket inside the sandbox; the full gate rerun with that
permission passes. No remote CI or public cross-service switch was tested.

## Known limitations

This is still not the public connection lifecycle. Stop preserves external
services and does not retire chats, event sockets, notifications or all deferred
work. Changing the URL and changing it back without invalidating the generation
is not safe switching. A future lifecycle coordinator must invalidate this
same generation and bind persistent buffer/task ownership before exposing
connect/disconnect; immediate callback scope is not a replacement for that.

HTTP sockets are not synchronously cancelled by stop. Their normal responses
release the response buffers and settle failures; a hung request can remain
pending. Server-accepted writes are not rolled back. Callback failure branches
still need their operation identities, and full service teardown must ensure
old local settlement cannot alter a replacement connection's caches or counters.
Dynamic callback ownership conservatively rejects nested work until that
callback returns if stop occurs while it is awaiting user input.
