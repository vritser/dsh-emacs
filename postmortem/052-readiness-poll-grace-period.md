# 052 — Readiness poll honors the configured server grace period

## Background

Commit 80bce3e added `dsh-emacs-list-sessions--fetch-when-ready`: after
`dsh-emacs-server-start` launches `dsh web` in the background, the session
list is not fetched immediately (the RPC would race the not-yet-listening
port) but through a non-blocking `run-at-time` chain of ten 0.5 s attempts —
a fixed 5 s window.  `dsh-emacs-server-wait-seconds` (30 s) was introduced
for the blocking `dsh-emacs-server-ensure` path and never reached this poll.

A cold `dsh web` boot composes the profile and loads the whole plugin tree.
Measured on this machine in an isolated `DSH_HOME` with the same profile
(base + web app + super-injector + claude-code/codex subagent bundles):
4.31 s, 4.53 s, 4.71 s.  So the client's window held roughly half a second of
headroom; anything slower — a first boot after a plugin install, a cold page
cache, a loaded machine — lost the race.  The failing layer is the
server-lifecycle boundary, not the transport: the liveness probe answered in
12 ms against a live server, and it accepts both `200` and `401`.

The user-visible symptom: `M-x dsh-emacs` printed "Starting dsh server in
background: …" and then "dsh: server did not become ready — retry with M-x
dsh-emacs", leaving the session list empty while the server finished booting
a moment later.

## Decision

One grace period for both start paths.  `dsh-emacs-list-sessions--fetch-when-ready`
now takes an absolute `float-time` deadline computed from
`dsh-emacs-server-wait-seconds`; it retries every 0.5 s while the deadline
stands and, when it passes, reports the configured window plus whether the
process this package started has exited, pointing at `*dsh-server*` for the
output.  The wait stays non-blocking (one timer per retry, never a
`sleep-for` loop).

## Why

The option already encodes the intended grace for "a freshly started server"
and the module doc already says a first boot "can take several seconds"; the
poll was the one path that ignored both, so the fix makes the option mean the
same thing everywhere.  The deadline form (rather than a smaller attempt
count) also keeps the failure message honest: the timeout is the configured
one, and the message distinguishes a server that is merely slow from a
process that already died.

Alternatives rejected: calling the blocking `dsh-emacs-server-ensure` from
`dsh-emacs-list-sessions` would freeze the UI for the whole boot, which is
exactly what the non-blocking chain was added to avoid; a larger hardcoded
attempt count moves the same race rather than removing it; keying readiness
to the `dsh web: http://…?token=` line the process prints is exact but needs
a process-output parse for a condition the cheap HTTP probe already answers;
and failing fast when the managed process exits is wrong here — the process
this package spawned can die of `EADDRINUSE` while a foreign `dsh web` on the
same port is still booting, which is the reported situation.  The poll must
keep probing the port regardless of its own child's fate.

## Consequence

`dsh-emacs-list-sessions` polls for `dsh-emacs-server-wait-seconds` (30 s by
default) instead of 5 s; on timeout the message names the window and
`*dsh-server*`, and appends that the started process exited when it did.
`dsh-emacs-server-wait-seconds`'s docstring now states it bounds both the
blocking ensure and this non-blocking poll.  Tests 89b/89c pin the deadline
to the option and the keep-polling/report behavior; `docs/customization.md`
already described the option generically and needed no change.

## Known limitations

Readiness is still discovered by polling the port every 0.5 s, so a boot
slower than the configured grace ends in the same give-up message — now with
the window and the buffer named, and the user can retry with `M-x dsh-emacs`.
The chain has no cancellation token: overlapping `M-x dsh-emacs` invocations
each probe the same port until their own deadline, which is harmless (the
probe is stateless) but means the message can be repeated.
