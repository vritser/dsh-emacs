# 183 — Cancel startup across stop at the same endpoint

_Lifecycle scope superseded by [187](187-single-service-lifecycle.md)._

_Startup-only scope superseded by [186](186-server-work-ownership.md)._

## Background

At `7b03e89` (v0.8.0), the server layer guarded asynchronous readiness by URL.
Stopping a process did not invalidate an outstanding probe, installation
continuation or init timer. Those continuations could launch a process after
stop or install a late authentication result. The endpoint ownership fix in
182 does not distinguish two startup attempts at the same address.

## Decision

Give startup work a generation owned by `dsh-emacs-server.el`. Explicit stop
advances it even when no managed process exists. Capture it with the endpoint
before yielding, then check both before accepting probe/authentication results,
sending the next readiness request, launching after installation or continuing
list/init polling. Keep each asynchronous attempt's own completion flag and
origin buffer checks.

## Why

Stop expresses cancellation before a process is available to kill. Process
liveness and endpoint equality cannot represent that decision. A startup
generation solves that existing problem without treating server stop as a
full client disconnect or changing which process the command owns. New
attempts capture the new generation, so cancellation is not a permanent ban
on auto-start. Checks apply to synchronous reentry too: network waits and
minibuffers can run timers while the original command remains on the stack.

## Consequence

Old startup work cannot undo stop or replace authentication from a newer
attempt. A token typed after stop is not exchanged or saved. Session-list
polling and eager init timers do not continue cancelled startup work. External
processes remain untouched. Startup failures in the init timer are reported
instead of silently swallowed.

This uncommitted change builds on `7b03e89` and the uncommitted endpoint
ownership fix. Regression tests use the public stop/start/list/readiness paths
and check response order, installation and prompt reentry, same-address retry,
callback origin/count and cleanup. CHANGELOG, customization and architecture
describe the cancellation scope.

The complete verification gate passed. A real GUI minibuffer probe confirmed
that stop during token input prevents exchange and persistence. Real HTTP tests
against both isolated Docker services confirmed old readiness cancellation,
new readiness success and authenticated session listing at the same endpoint.
Those tests use a separate Emacs per service, not a live service switch.

## Known limitations

This generation owns startup and authentication only. It is not the planned
connection lifecycle: business RPC callbacks, WebSocket events, notification
actions and old chat state are not retired by server stop. Editing the URL is
still not safe live switching, including A → B → A without explicit stop.

Invalidation takes effect immediately at startup guards, but stop does not
force-close an active reader or synchronously tear down every readiness
request. Async attempts release resources on their next response/poll or the
existing readiness timeout; a stalled attempt can therefore report timeout.
The planned public disconnect needs its separate preflight, synchronous cleanup
and cancellation-notification ordering rather than inheriting this behavior.
