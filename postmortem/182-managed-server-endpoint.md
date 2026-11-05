# 182 — Bind a managed server process to its endpoint

## Background

At `7b03e89` (v0.8.0), the server layer had one managed process handle but
no endpoint ownership. After changing the configured URL, its captured token
could override the external endpoint's token, its live process could suppress
authentication or make startup wait for the wrong service, and its cached
liveness result could satisfy another endpoint's probe. The low-level launch
path also deleted a previous live process before starting its replacement.

## Decision

Store the launch endpoint on the managed process and require that ownership
before using its token or treating it as the current endpoint's startup.
Keep one process handle; refuse a second launch while it is alive, before
changing the output buffer or invoking installation. Recheck after installation,
which can yield to other work. Key the liveness cache by endpoint too.

## Why

The process survives independently of the configured connection. Putting its
endpoint on the process makes the lifetime explicit without adding a profile
registry or duplicating authentication contexts. Reading the owned process's
buffer also works if the user renamed that buffer, and excludes unrelated
text left in a buffer named `*dsh-server*`.

Explicit stop is the user's decision to terminate that process. Selecting a
reachable external endpoint gives no reason to kill it, while silently
replacing it could interrupt other clients. The same ownership rule applies
to synchronous startup, asynchronous draft readiness and list startup.

## Consequence

Reachable external services leave the managed process alive. A second managed
launch reports that the user must stop the first process explicitly; stop
still targets the registered process even after the configured URL changes.
Authentication for another endpoint is no longer skipped because that process
is alive. Tokens from a stopped process are no longer a fallback source.

This is the uncommitted server-ownership implementation based on `7b03e89`,
following the independent late-401 fix. Regression tests exercise actual
process properties, output buffers, public start/stop/list entry points,
authentication, endpoint-specific probes and installation-time reentry.

## Known limitations

Endpoint comparison cannot distinguish A → B → A generations or an external
restart at the same address. Shared authentication cookies, service caches,
HTTP continuations, timers and old chat actions still need the planned single
connection lifecycle. This change does not make editing `dsh-emacs-base-url`
a safe live switching workflow and does not expose connect/disconnect APIs.

Processes created by older loaded code have no recorded endpoint. Restart
Emacs when upgrading to establish that ownership; no guessed ownership or
compatibility migration is added for existing process objects.
