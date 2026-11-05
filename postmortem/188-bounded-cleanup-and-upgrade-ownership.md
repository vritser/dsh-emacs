# 188 — Bounded feature cleanup and explicit ownership upgrades

## Background

The lifecycle work based on `7b03e89` (v0.8.0), recorded in 185 and 187,
retained failed stream handlers for retry. A deterministic handler failure
aborted every later retry, skipped other handlers and could permanently block
both chat recovery and whole-client disconnect. The events layer also invoked
those handlers before scheduling lost-socket recovery.

The same ownership upgrade required `dsh-server-owner` on sockets, but sockets
opened by 0.8.0 did not record their endpoint. Tests using the new owned-process
fixture did not represent that migration. These fixes are uncommitted changes
on that baseline, not a new release or commit.

## Decision

Invoke stream-close callbacks independently, retain only first-time failures,
and report/quarantine a handler after its second failed invocation. Schedule
lost-socket recovery and stop health timers before feature teardown; retain the
old handle while its bounded cleanup retry remains pending.

Require disconnect/reload/reconnect (or restarting Emacs) for live pre-0.9
sockets. Reload completion detects truly ownerless chat and core sockets and
reports this requirement. Routine reload of owned sockets keeps working.

## Why

A feature's local cleanup error must be visible without permanently preventing
transport recovery. One retry accommodates a transient failure; a deterministic
failure cannot be fixed by infinite retries. Quarantined handlers remain on the
retired process for diagnostics while it is reachable and are never dispatched
again. This exception is limited to feature callbacks, not arbitrary buffer or
resource cleanup failures.

Adopting old sockets using the current configured URL would falsely assign
ownership if the URL changed while they were open. The old protocol and process
state do not provide enough evidence to reconstruct the full endpoint, including
its path and authentication context. An explicit reconnect is safer and simpler
than speculative migration or a compatibility layer.

## Consequence

Healthy stream handlers still execute when another throws. A second disconnect
can complete after a persistent feature failure, and the scheduled reconnect
can open a fresh socket. Callback errors are reported; they are not silently
swallowed. Tests cover permanent failures, later handlers, timer cleanup,
actual reconnect entry, whole-client retry and genuinely ownerless legacy
sockets. The changes are listed under 0.9.0 in [CHANGELOG](../CHANGELOG.md).

## Known limitations

A quarantined feature may retain stale local presentation until its owner is
reset or reopened; quarantining does not claim its cleanup succeeded. A reload
started by an older loader can discover missing ownership only after new source
has loaded; it reports the required reconnect instead of claiming migration
completed. Upgrading live 0.8.0 sockets cannot preserve those socket instances.
