# 065 — Background jobs: subscribe to the `job` namespace streams

## Background

Background work the model starts — a bash command left running, a subagent
delegation, a workflow — has never had a client surface in dsh-emacs.  At
0.1.6 the host published a whole-host `jobs` record on the `session/control`
baseline (and `jobs` increment frames), but the client deliberately did not
read it: commit `da61054` recorded the drop as "no background-task UI consumes
it yet".

That was survivable while the state existed.  dsh 0.1.7 deleted the
`session/control` `queues`/`jobs` records and their frames outright and moved
the roster behind a new `job` Remote namespace with two streams and a kill
call, so the same commit had to remove even the accepted-no-op branch
(`dsh-emacs-events.el`: "Background jobs have no frame here at all since dsh
0.1.7").  After that migration the client could not see background work *at
all* — not "unrendered", but unsubscribed.  postmortem/064 listed it as a
known limitation ("Background jobs still have no client surface").

## Decision

Adopt the `job` namespace: `dsh-emacs-jobs.el` owns a chat-buffer-local roster
mirror fed by a `job/list` stream, a read-only output buffer fed by a
`job/follow` stream per viewed job, and a `job/kill` stop; the mode line shows
`[Jn]` while jobs are live and `C-c C-j` opens the roster as a minibuffer menu.

The required structural change is in the event layer, not the feature:
`dsh-emacs-events--dispatch-stream` now routes a chat socket's frames by
`streamId` instead of assuming every message belongs to `session/follow`.
`dsh-emacs-events-open-stream` registers a handler on the process,
`dsh-emacs-events-close-stream` retires it (calling the handler once with nil),
and `dsh-emacs-events--close-streams` retires all of them from the socket
teardown path, so no mirror outlives its stream.

## Why

- **The roster is per-session and only on its own stream.** `job/list` takes a
  `sessionId`; unlike the queue's `inbox` projection there is no whole-host
  frame that could piggyback on the core `session/control` connection. A
  subscription is the only way to see it, so a home for it had to be chosen.
  The chat buffer's socket is that home: it is already a multiplexing carrier,
  its lifetime matches "a session the user is looking at", and the handshake
  path already re-opens per-connection streams after a reconnect.
- **The mode line is what makes it worth the wiring.** dsh web mounts its job
  control for as long as the session header lives, so a background job stays
  visible without a command. Showing `[Jn]` beside the existing `[Qn Sm]` is
  the same contract in Emacs terms, and it is the reason the stream is
  resident rather than opened only while a menu is up.
- **Rejected: a dedicated jobs buffer owning its own connection.** It would
  isolate the change from the event layer, but it duplicates socket setup,
  auth, reconnect, and watchdog logic that the chat socket already carries —
  and it would leave the mode line blind, which defeats the point.
- **Rejected: opening `job/list` only while the menu is open.** No resident
  state means no indicator; the chooser would show a snapshot that could
  already be stale when the user acts on it, and `r`-style refresh would be the
  only way to update.
- **Rejected: a local ANSI/VT emulator for output.** The host already keeps an
  `@xterm/headless` screen and every `job/follow` generation opens with a
  rendered batch of text; the client appends the chunks it is handed and does
  not re-emulate. Full-screen TUI fidelity is therefore the host's problem, not
  ours.
- **Teardown keeps the last roster, it does not blank it.** A dropped socket is
  usually followed by a reconnect whose first `rows` frame is the whole truth;
  clearing the mirror on teardown would only flash the mode line empty in
  between.
- **A kill is two-press.** This mirrors dsh web's armed stop control and keeps
  a single stray `k` from killing the model's background work. The arming press
  keeps the menu open, because the menu is the only place the two-press logic
  runs: closing it there would leave no way to press `k` again inside the arm
  window. The host records `cancelled by the user` as the reason and still
  delivers the completion notice, so the model learns the user stopped its task
  rather than inferring it.

## Consequence

- New module `dsh-emacs-jobs.el` (protocol views live in
  `dsh-emacs-protocol.el`: `dsh-protocol-job`, `dsh-protocol-job-list`,
  `dsh-protocol-job-frame`, `dsh-protocol-job-chunk`).
- New user surface: `dsh-emacs-list-jobs` (`C-c C-j`), mode-line `[Jn]` with
  `dsh-emacs-jobs-modeline-face`, `C-c C-j` menu keys `RET`/`k`/`r`, output
  buffers in `dsh-emacs-jobs-output-mode` (`q` buries), and the option
  `dsh-emacs-jobs-kill-arm-seconds` (default 3).
- `dsh-emacs-events.el` gained the public stream seam
  (`dsh-emacs-events-open-stream` / `-close-stream`); later feature streams on
  the chat socket should use it rather than inventing another property.
- `assq-delete-all` was observed leaving the entry in place when removing a
  stream registration on this Emacs, so `dsh-emacs-events-close-stream` filters
  explicitly instead — the bug is covered by
  `stream-end-retires-handler`.

## Known limitations

- The mode-line indicator counts live jobs only; settled jobs are reachable
  through `C-c C-j` but do not keep an indicator alive.
- The output buffer renders the host's chunk text as-is; a full-screen TUI
  (vim, htop) is only as faithful as the host's serialized text, and no
  client-side VT emulation is attempted.
- No per-job resume cursor: re-opening a job's output re-reads the retained
  ring from the oldest byte rather than continuing from `next`. One job's ring
  is bounded by the host, so this is a bandwidth choice, not a correctness one.
- Retained output is not persisted, and a job whose output was fully reclaimed
  shows only the host's retention notice.
