# Slash Commands

Child conversations do not execute slash commands or skill gestures. Their
text input uses `subagents/prompt`; unsupported commands fail locally. Open
`M-x dsh-emacs-list-subagents` to choose children through minibuffer completion and
`M-,` return navigation; see [subagent controls](../README.md#subagent-conversations).

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

## Plan mode

`/plan` enters Plan mode; `/plan <message>` also sends that message for the
model to work on in Plan mode. `/plan off` leaves it. The host applies a switch
immediately between turns, or at the next accepted step during a turn. The
mode-line badge distinguishes the current mode from a pending switch:
`Plan`, `Plan → on`, or `Plan → off`. See [Plan mode](modeline.md#plan-mode).

The status badge itself does not approve a plan or change permissions.

### Plan review

When the model submits a plan through `exit_plan_mode`, the host's
`plan-review` question opens the complete Markdown in a read-only document
buffer. The chat and its input remain available; no minibuffer answer is
required while reading. The document offers:

- **Approve and execute** (`C-c C-c`): approve the plan; the host leaves Plan
  mode and the agent can begin implementation.
- **Request changes** (`C-c C-k`): dismiss review and return to the original
  chat input. The agent stays in Plan mode and waits for your feedback.
- **Back to chat** (`C-c C-z`): return to the chat without answering.
- `q`: close the document window without answering. Even killing the document
  buffer leaves review pending. `M-x dsh-emacs-plan-review` in the chat opens
  the most recently received pending plan again.

With tool calls visible, every submitted plan has a titled, clickable card in
the transcript. `RET` or a click opens its document, including after review
has ended and after history reload. Opening an old plan never grants approval.
Approval buttons disappear while sending and after settlement. A failed send
shows its error and permits retry. Host cancellation, a disconnected core
stream, or a closed chat expires the review; the document remains readable.
Closing the chat hands its pending request back to the host.

Only a single-choice question with explicit supported `plan-review` intent
uses this interface. Ordinary questions and unsupported review shapes keep the
existing question reader; an unsupported review shape says so in the echo area
instead of falling back silently. `/plan off` still changes the mode directly.

## Three ways to run a command

- **Type it**: `/goal set improve the model picker` + `C-c C-c` — dsh-emacs
  parses the line, calls `commands.execute`, records it in the input history
  and **clears the input immediately** (web-style; no waiting on the RPC round
  trip). If the transport fails the line is restored into the input (only while
  it is still empty) so you can retry. The outcome renders when the
  `command/done` event arrives.
- **Menu**: `M-x dsh-emacs-command` — reads the live catalogs
  (`commands.list` and `skills.list`, cached per session), shows both in one
  `completing-read` (commands first, then skills; user-only skills marked), and
  prompts for the argument when a picked command declares an input hint. A
  picked **skill** instead inserts its `/name ` gesture at point, ready for
  arguments, because the host expands the gesture from the prompt text rather
  than executing it; with a prefix argument (`C-u`) the picked skill's
  `SKILL.md` opens instead.
- **Completion**: `TAB` in the input area completes the `/name` token over the
  cached catalog (a bare `/` lists everything). Accepting a complete name adds
  a trailing space, so `TAB` directly after `/goal` lets you type its arguments.
  Ambiguous matches keep the token editable until a full name is chosen.
  The token is the one ending at point — at the start of the message or after
  any whitespace, the boundary the host's gesture grammar uses — so
  `please /rev` + `TAB` becomes `please /review `. A token in the middle of a
  message is claimed only when a command or skill really matches it, so prose
  and paths (`see /usr/…`) keep path and word completion; a `/name` at the
  input start stays with command completion even when the catalog is empty.
  The catalog is handed to the front-end whole and matching is Emacs's: this
  source's completion category defaults to ordinary prefix matching plus the
  built-in `flex` style, registered in `completion-category-defaults` (the
  same place `@` references get their `flex`).  So a word inside a long name
  completes — `/probe` → `/dsh-emacs-skill-probe` — while an ambiguous prefix
  (`/p`) still just lists.  Your own `completion-styles` apply after those
  defaults, and setting `completion-category-overrides` for
  `dsh-emacs-command` replaces them outright.
  The same list carries the session's **skills** (see [Skills](skills.md)):
  a skill name is not in the command registry, so `commands.execute` declines
  it and the line falls back to an ordinary prompt, where the host's skill tool
  expands the `/name` gesture.
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
