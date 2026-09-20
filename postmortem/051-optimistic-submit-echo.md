# 051 — Optimistic submit echo

## Background

`C-c C-c` cleared the input instantly but showed the message late.  The idle
path (`dsh-emacs--submit-plain`) rendered the transcript echo only inside the
`session/prompt` HTTP callback, so the message appeared one `url-retrieve`
round trip after the keystroke; the busy path
(`dsh-emacs--submit-deferred`) rendered nothing and let the host's
`session/queue` splice frame drive the Next Message row, adding the same
round trip.  Measured here: ~1 ms of synchronous Elisp even in a 5k-line
transcript, but ~26 ms for a warm RPC — the gap users described as a sticky
send.  The failing layer is the submit/UI feedback boundary, not the
renderer or the transport.

## Decision

Local feedback is optimistic on both submit paths.  The idle path renders the
transcript echo at submit time through
`dsh-emacs--render-user-message-optimistic`, which wraps the extracted
`dsh-emacs-render--insert-user-block` and records the inserted region in the
buffer-local `dsh-emacs--pending-user-echoes`; a rejected prompt deletes that
region and restores the draft, while the host's canonical `user/message` is
consumed by the existing pending-message dedup, which also retires the
rollback record (`dsh-emacs--forget-user-message-echo`) and leaves the echo
in place.
The busy path records the just-submitted text as a local
`dsh-emacs-queue--optimistic-submit` item and repaints, so
`dsh-emacs-queue-next-item` falls back to it until the host's own
`session/queue` frame (or the submit-failure branch) retires it.

## Why

Send feedback is the one interaction where a round trip is directly visible:
the input has already emptied, so any latency reads as the client having
dropped the message.  Rendering at submit also makes the echo independent of
connection scheduling, which is the same reason the slash-command row and the
steer/delete/edit queue actions are already optimistic.

Alternatives considered: keeping the callback render (the reported symptom);
rendering the deferred message as a transcript card immediately (rejected —
the message is not part of the conversation until the host claims it, the
constraint recorded in postmortem/021 and the Next Message region design);
and connection keep-alive to shrink the round trip (rejected as a transport
project with a smaller, less durable payoff than instant local feedback).

## Consequence

`dsh-emacs-render-user-message` now delegates insertion to
`dsh-emacs-render--insert-user-block` and still returns the event seq;
`dsh-emacs--render-user-message` is replaced by the optimistic renderer plus
`dsh-emacs--discard-user-message-echo`.  New buffer-local state:
`dsh-emacs--pending-user-echoes` (chat) and
`dsh-emacs-queue--optimistic-submit` (queue).  `docs/architecture.md`
describes the optimistic preview and echo; tests cover the pre-RPC echo, its
rollback on failure, its survival on success, and the queue preview's
appearance/retirement.

Verifying against a live server surfaced a second, independent bug behind the
same symptom: the protocol layer kept the wire's JSON `false` as the truthy
`:json-false`, so `dsh-emacs--busy-p` read every idle session as running and
routed idle sends to the deferred path (the blue Next preview).  That is
fixed where the value crosses into the struct
(`dsh-protocol--boolean`), not here.

## Known limitations

A queued message still shows only in the Next Message row, never as a
transcript card, until the host claims it — unchanged deliberately.  When
items are already parked, the optimistic queued item sits behind the
displayed first item and so is not itself visible until they drain.  Duplicate
submissions of the same text are matched to their echoes in submission order
by text; a queued item deleted from the queue manager before its host frame
lands relies on that frame (or the hygiene timer) to retire the preview.
