# 162 — Static command-row status

## Background

Slash-command and local `!` rows animated their running state with a
timer-driven `-\|/` spinner in `dsh-emacs-render.el`. Every started command
allocated a repeating `run-at-time` timer and a buffer-local
`dsh-emacs--command-spinners` entry; each tick rebuilt the row fragment, but
only after locating the block and checking whether any visible window showed
it. Two extra paths existed around that timer: `dsh-emacs-events-disconnect`
cancelled every spinner so a detached conversation never kept animating, and
`dsh-emacs--command-spinner-revive` restarted the spinners for still-pending
rows after a reconnect, including a per-row status read to skip settled rows.

The timer also leaked its concerns into other layers. The spinner table had to
be buffer-local because optimistic rows use the same `pending-<name>` id in
several chats, history pages had to suppress spinner start/stop explicitly,
and the tick path was covered by its own tests in the command, modeline,
events, stream and history suites. The running state itself was already
carried by the leading icon/dot and the pending header tint, and the session
list shows running sessions with a colored dot and no animation, so the
spinner was a second, costlier way to say the same thing.

Commits: pending (no commit requested for this change).

## Decision

Mark a running command row with the leading icon/dot and the pending header
tint only. Remove the four frame constants, the tick interval, the
buffer-local spinner table, `dsh-emacs--command-spinner-start` / `-tick` /
`-stop` / `-clear-all` / `-revive`, the disconnect teardown call, the
reconnect call and the history-page guards that existed only to keep the
timer out of background pages. `dsh-emacs-render--command-label-left` owns the
pending/success/error label text so the optimistic, live, done and local
shell paths share one presentation seam.

## Why

A 10fps timer per running command redrew transcript text to change one
character, and the redraw cost grew with the number of concurrent commands
and visible chats. The state was already legible without it: the pending tint
and leading glyph are the same color language the session list uses for
running work, and they cost nothing to render. Removing the timer deletes the
reconnect revive path, the disconnect clear-all path and the cross-buffer
state that existed only to keep revival safe; there is no longer a detached
animation to cancel, so those lifecycle hooks have nothing to own.

Keeping the spinner only for visible rows was rejected: it preserves the
timer, the visibility scan and the reconnect restart for a single character,
and it makes running behavior depend on which window happens to show the
chat. Driving the row from the optional mode-line animation backend was
rejected too: the backend is optional, so command rows would animate for some
users and not others, and it would put transcript layout on a clock again.
The activity animation that remains is the mode line's shared running
indicator, which already answers "is this agent working" at a glance.

## Consequence

Users see command rows settle from the pending tint to the success/error
color without a spinner. Slash commands and local `!` commands keep identical
rows, history pages and reconnects need no special animation handling, and a
detached conversation has no per-row timer left to cancel. Rendering,
events and shell docs were updated (`docs/architecture.md`,
`docs/slash-commands.md`, `docs/shell-commands.md`), and `CHANGELOG.md` links
here. The spinner tests in the command, modeline, events, stream and history
suites were removed with the machinery; the remaining tests assert the
pending tint, the bash leading glyph, optimistic-row isolation and history
settlement.

## Known limitations

- There is no per-row motion cue, so a long-running command looks exactly like
  a just-started one; the mode line's running indicator is the progress signal.
- The spinner frames and interval constants are gone with the timer; a future
  per-row animation would need a new, different design rather than a revival
  of this one.
