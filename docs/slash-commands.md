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
- **Menu**: `M-x dsh-emacs-command` — reads the live catalog
  (`commands.list`, cached per session), shows command + description in
  `completing-read`, and prompts for the argument when the command declares an
  input hint.
- **Completion**: `TAB` in the input area completes the `/name` token over the
  cached catalog (a bare `/` lists everything). Candidates already include a
  trailing space, so `TAB` directly after `/goal` lets you type its arguments.
  `TAB` is bound to `completion-at-point` in chat buffers. dsh-emacs is only a
  completion *backend* — it registers `completion-at-point-functions` and never
  drives a popup itself. When `dsh-emacs-slash-auto-complete` is on (default),
  dsh-emacs instead contributes `/` to whichever front-end already has its own
  auto mode turned on, and that front-end auto-pops the command list where it
  supports auto (the active front-end is read when the chat buffer opens, so
  turn the front-end's auto on before opening a session):
    - **corfu** (`corfu-auto` enabled): `/` is added buffer-locally to
      `corfu-auto-trigger`, so corfu's engine pops immediately on `/`;
    - **company**: nothing to wire — company reaches this buffer's capf via
      `company-capf` and auto-shows on its own idle delay, once the `/go…` prefix
      reaches `company-minimum-prefix-length`;
    - **stock `*Completions*` / vertico / icomplete**: no auto channel exists, so
      `/` completes on `TAB` only.

## Catalog prefetch

The catalog is **pre-fetched**: opening a session starts a short timer-based
fetch of `commands.list`, so the first `/` or `TAB` is served from cache instead
of blocking on a synchronous round trip (disable with
`dsh-emacs-command-prefetch`; tune the delay with
`dsh-emacs-command-prefetch-delay`). If the host registers new commands while a
session stays open, run `M-x dsh-emacs-command-catalog-refresh` to re-fetch and
re-cache the catalog on demand.

Commands that accept inline images (`goal`/`plan` declare `images: true`)
receive the empty image array from dsh-emacs; image-bearing command input is not
wired yet.