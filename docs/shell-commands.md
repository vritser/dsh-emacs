# Shell Commands (`!command`)

A line typed after the `❯ ` prompt starting with `!`, without attachments,
runs **on this machine** instead of being sent to the model — Pi /
agent-shell style client-side shell access:

```
!git status
!npm test
! ls -la              # a space after `!` is tolerated
```

Admission is exactly a `!` followed by a non-empty command.  A bare `!`,
`/name` slash lines and plain text are ordinary messages. Shell syntax
follows the selected shell; these examples use POSIX shell syntax:

```
!git log --oneline | head -5
!cat package.json | jq .version
```

With attached images, a leading `!` is ordinary caption text. The full
caption and images are sent to the model, including when queued or steered;
the caption is never executed as a local command.

Multiline input runs the full command after `!`, preserving embedded
newlines and heredocs:

```
!cat <<'EOF'
hello from a heredoc
EOF
printf 'done\n'
```

## Semantics

- **Local, immediate**: the command runs through Emacs's `shell-file-name`
  with `-c`. This variable can differ from the current `$SHELL` environment
  variable; the environment variable is not read again for each run.
  The chat buffer's `default-directory` is its working directory — the session
  workspace, so `git`, `make`, `npm` etc. start in the right project.  It is
  independent of the session's busy state (`!` runs even while a turn is
  executing instead of being queued, including with busy behavior `stop`)
  and of the dsh server. `C-c C-c` requires no server connection for `!`
  input; it never reaches `session/prompt` or `commands.execute`.
- **Rendering**: a transcript row appears instantly — the bash terminal icon
  (the same dsh-web SVG as tool rows) followed by the command and a classic
  `-\|/` spinner.  On completion the header shows the exit status
  (`✓ exit 0` green, `✗ exit N` / `✗ signal N` red) and the merged
  stdout+stderr becomes a collapsible body below, expanded by default
  (`RET` on the row folds it).  The line is recorded in the input history
  (`M-p` recalls it) and the input is cleared immediately, like slash
  commands.
- **Interrupting**: `C-c C-!` (or `M-x dsh-emacs-shell-process-kill`) kills
  the tracked shell process; its row restyles as failed (`✗ signal N`).
  Killing the chat buffer also kills the shell process while it is tracked.
  Submitting a **new** `!` command stops the previous tracked shell:
  at most one shell process is tracked per chat buffer.
  A process suspended by a signal remains tracked, with its output and
  timeout preserved, until it exits or is killed.
  Reopening the session or changing the chat's major mode also kills the
  tracked shell before resetting its tracking.
- **Local-only results**: shell rows and output are not saved in server
  session history or sent to the model. Reloading session history replaces
  the transcript with server events, so these rows disappear; reopening
  the session does not restore them. Input history (`M-p`) is separate from
  this transcript and is not a saved record of command output.

## Background processes

Cleanup and timeouts track the shell launched for the command, not every
descendant process. For example, `!sleep 60 & echo launched` can finish with
exit 0 while the background `sleep` continues. Once the shell exits, that
child is no longer tracked: closing the chat, starting another command, or
the shell timeout will not clean it up. Detached processes can also survive.
The displayed exit status describes the shell run, not the eventual result
of a background job. Manage background services and jobs separately.

## What about TUI / interactive programs?

The chat provides no interactive terminal. EOF only helps programs waiting
for stdin; it does not guarantee that a TUI will exit. Vim can remain
running even after EOF and a "not a terminal" warning.

- **stdin receives EOF immediately** (`dsh-emacs-shell-null-stdin`, on by
  default): Emacs closes the input pipe after starting the process, without
  adding shell-specific redirection syntax. A bare `cat` exits at once;
  a program that does not finish on EOF may keep running.
- **Manual stop**: `C-c C-!` kills the tracked shell. Submitting a new `!`
  command also stops it. Interactive programs should run in a terminal.
- **Optional timeout** (`dsh-emacs-shell-timeout`, nil by default): set it
  to a positive integer number of seconds and the tracked shell is killed
  if it outlives the limit;
  its row restyles as failed with a `⏸ timed out after N seconds — killed`
  note. With the default nil, there is no automatic deadline. This limit
  does not manage children that outlive the shell (see above).

## Options

`dsh-emacs-shell-require-confirm` (nil by default) — when `t` every `!`
line asks `y-or-n-p` before running; declining leaves the input untouched.
The default runs immediately: you typed the command yourself, the same trust
model as `M-!` / `shell-command`.

`dsh-emacs-shell-max-output` (50000) — the captured output is truncated to at
most this many characters with a trailing note, so a runaway `make` or `cat`
cannot flood the chat buffer.

`dsh-emacs-shell-null-stdin` (t) — Emacs closes the command's input pipe
immediately (see the TUI section). Setting it to nil leaves the pipe open
for callers to send input; the chat itself still provides no terminal input.

`dsh-emacs-shell-timeout` (nil) — positive integer seconds a tracked shell
may run before it is killed and marked `⏸ timed out`; nil means no limit.
Zero, negative numbers, and non-integers are rejected before a command
starts, the draft is cleared, or the previous shell is stopped.
Use `C-c C-!` or submit the next command to stop a still-tracked run.

## Why not a slash command?

dsh slash commands (`/name`) are **host-side**: the server registers them and
renders their `command/run` + `command/done` events.  `!` is the
**client-side** complement — it deliberately bypasses the server for commands
that are purely local (inspect the working tree, run tests, format code),
giving the same muscle memory as Pi / agent-shell while the model turn keeps
running.  There is no catalog: every `!` line is run as written.
