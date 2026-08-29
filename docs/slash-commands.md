# Slash Commands

dsh exposes a **host-side command registry** — slash commands are real server
features, not client-side tricks. dsh-emacs dispatches `/name` lines typed
after the `❯ ` prompt through the same `commands.execute` RPC the web UI uses:
the host admits only registered commands (and never feeds them to the model),
then logs `command/run` + `command/done` session events, which dsh-emacs
renders as one web-style flow node in the transcript — a leading bash terminal
icon (the same dsh-web SVG as bash tool rows, `💻` in terminal Emacs) followed
by the command name, a classic `-\|/` spinner while the command is running, and
on completion a short status (`✓ done` / `✗ failed`, green on success / red on
error) in the header while the outcome text is folded into a collapsible body
below, collapsed by default (`RET` on the row expands it).

**Semantics** (mirror dsh web): a leading `/name` where `name` is lowercase
`[a-z][a-z0-9_-]*` followed by whitespace or end of line is a command line —
`/compact`, `/goal set …`, `/plan off`. Anything else (including
`/usr/local/…`, `//`, `Hello`) sends as an ordinary message. A command line
that does **not** match the server registry falls back to a plain message.

> Note: `session.send`-style editing of history is not a thing here — a command
> line never reaches the model; only the fallback (unknown) case does.

## Command catalog

The current web profile registers the following (the exact list varies by
server version; dsh-emacs reads it live from `commands.list`):

| Command | Input hint |
|---|---|
| `/compact` | — |
| `/export` | — |
| `/feedback` | `<text>` |
| `/goal` | `[<objective>\|clear\|edit <objective>\|pause\|resume]` |
| `/permission` | `<preset>` |
| `/plan` | `[off\|message]` |

## Three ways to run a command

- **Type it**: `/goal set 改进模型选择器` + `C-c C-c` — dsh-emacs parses the
  line, calls `commands.execute`, records it in the input history and **clears
  the input immediately** (web-style; no waiting on the RPC round trip). If the
  transport fails the line is restored into the input (only while it is still
  empty) so you can retry. The outcome renders when the `command/done` event
  arrives.
- **Trigger popup**: typing `/` as the first character of the input area pops
  the command list immediately (web-style). With corfu (loaded), chat buffers
  buffer-locally enable `corfu-auto` and put `/` into `corfu-auto-trigger`, so
  corfu itself fires the popup on the `/` keypress — no timers involved; other
  setups fall back to a post-command `completion-at-point` trigger (stock
  `*Completions*` list, vertico in-region). Either way the list live-filters
  as you keep typing (`/go` narrows to `/goal`…), and a message that merely
  starts with `/` (e.g. `/usr/local/...`) dismisses the list by just continuing
  to type. The whole auto-pop can be disabled with
  `dsh-emacs-slash-auto-complete` (`TAB` and `M-x dsh-emacs-command` still
  work).
- **Menu**: `M-x dsh-emacs-command` — reads the live catalog
  (`commands.list`, cached per session), shows command + description in
  `completing-read`, and prompts for the argument when the command declares an
  input hint.
- **Completion**: `TAB` in the input area completes the `/name` token over the
  cached catalog (a bare `/` lists everything). Candidates already include a
  trailing space, so `TAB` directly after `/goal` lets you type its arguments.
  `TAB` is bound to `completion-at-point` in chat buffers.

## Catalog prefetch

The catalog is **pre-fetched**: opening a session starts a short idle-time fetch
of `commands.list`, so the first `/` or `TAB` is served from cache instead of
blocking on a synchronous round trip (disable with `dsh-emacs-command-prefetch`;
tune the idle gap with `dsh-emacs-command-prefetch-delay`). If the host
registers new commands while a session stays open, run
`M-x dsh-emacs-command-catalog-refresh` to re-fetch and re-cache the catalog on
demand.

Commands that accept inline images (`goal`/`plan` declare `images: true`)
receive the empty image array from dsh-emacs; image-bearing command input is not
wired yet.