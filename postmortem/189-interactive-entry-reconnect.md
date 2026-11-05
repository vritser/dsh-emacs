# 189 — Reconnect on explicit interactive entry

## Background

The lifecycle introduced in `0cfdd93` deliberately kept disconnected clients
offline. The profile extension in `50d1425` could explicitly connect again,
but a single-service user invoking `M-x dsh-emacs` received an error. The
failing layer was the UI entry point: it treated a fresh user command like
background work left over from the previous connection.

## Decision

Let interactive `dsh-emacs` entry reconnect from disconnected or failed state
through `dsh-emacs-connect`, then open the session list after success. The
interactive specification supplies an explicit reconnect argument, including
when invoked by a keyboard macro. Keep the existing transport guards and
origin-buffer lifetime contract.

## Why

A user opening the client expresses fresh connection intent. A timer or an
old callback does not. Resetting lifecycle state to the initial automatic
startup mode would also revive background work and reuse default credentials;
calling the explicit connection API preserves authentication and generation
boundaries. The configured URL already identifies the last attempted target,
so another endpoint registry or credential cache would duplicate ownership.
An initial `called-interactively-p` check excluded keyboard macros during GUI
acceptance; the interactive argument records command intent directly.

## Consequence

Single-service users can disconnect and reopen with the usual command.
Authentication may prompt again. The session list opens only after a ready
snapshot, preserving the invoking project's navigation target. A failed
connection reports its error and can be retried manually; a failed switch
does not silently return to the previous service. No-argument Lisp entry, expired
owners, overlapping attempts and unfinished cleanup remain guarded.

Regression tests cover readiness, project navigation, failed-target retry and
offline guards. A separate GUI Emacs probe exercises real M-x and password
readers, list display, password cancellation and a background invocation;
HTTP responses and initial baselines are mocked in that probe.

## Known limitations

This reconnect path requires an already running service. It does not install
or launch one, replay a profile resolver, or remember launch tokens. Use the
process commands to start a stopped managed service, or the profile switcher
to refresh dynamic endpoints and credentials. Closing the invoking buffer
cancels the attempt. Reopening selects the session list, not the last chat.
