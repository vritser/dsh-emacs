# dsh-emacs — an Emacs client for DeepSeek Harness

**dsh-emacs** brings [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)
(`dsh`) into Emacs: streaming replies, tool calls, thinking blocks, slash
commands, file/session references, and model selection. It uses Emacs
built-ins (Emacs 27.1+) with no third-party dependencies.

![Chat buffer with streaming replies and tool calls](assets/chat.png)

> **0.5.x** targets the **dsh 0.1.7** wire protocol (servers **0.1.5 or newer**:
> the queue surfaces read the `inbox` session projection, which 0.1.5, 0.1.6 and
> 0.1.7 all publish).

## Quick start

You need **Emacs 27.1+** and a provider/model configured in dsh to send
messages. dsh-emacs can install and start the dsh server for you; provider
credentials and model configuration remain in dsh. For an existing local or
remote server, set its address as described in [Server setup](#server-setup)
before connecting.

1. Clone the repository:

   ```sh
   git clone https://github.com/vritser/dsh-emacs.git ~/dsh-emacs
   ```

2. Add this to your Emacs configuration and evaluate it, or restart Emacs:

   ```emacs-lisp
   (add-to-list 'load-path (expand-file-name "~/dsh-emacs"))
   (require 'dsh-emacs)
   ```

3. Run `M-x dsh-emacs` to open the session list. If no local server is
   running, dsh-emacs starts one, offering to install the CLI if it is missing.
   On a fresh dsh setup, use `M-x dsh-emacs-open-web` to configure your
   provider and model before sending a message.
4. Press `c` in the session list to create a session. Use `C-c C-m` in the
   chat buffer to choose a model if needed.
5. Type after the `❯` prompt and press `C-c C-c` to send your first message.

For an optional `use-package` setup, see
[Example configuration](docs/customization.md#example-configuration).

## Using it

### Session list

`M-x dsh-emacs` opens your sessions, grouped by workspace. Press `c` to
create a session or `RET` to open one. See
[Session and workspace controls](docs/customization.md#session-and-workspace-controls)
for list management and navigation.

![Session list grouped by workspace](assets/sessions.png)

### Inside a chat buffer

| Key | What it does |
|---|---|
| `C-c C-c` | Send input or interrupt; see below |
| `C-c C-b` | Interrupt the running turn |
| `C-c C-q` | Manage the pending queue |
| `C-c C-j` | Manage background jobs (view output / stop) |
| `C-c C-g` | Open the goal-action prefix |
| `C-c C-m` | Switch model / reasoning effort |
| `C-c C-a` | Attach an image file and send it now |
| `C-c C-v` | Paste the clipboard image into the next message |
| `C-c C-d` | Discard staged images |
| `s-v` | Paste a clipboard image, else yank text |
| `C-c C-s` / `C-c M-s` | Switch session in this workspace / across all |
| `C-c C-r` | Refresh |
| `C-c C-o` | Load older messages above the current transcript |
| `C-c C-w` | Copy (region → code block → message at point → last reply) |
| `C-c C-f` | Toggle mode-line stats |
| `C-c C-!` | Stop the tracked local shell process |
| `M-p` / `M-n` | Previous / next input |
| `C-/` / `C-_` / `C-x u` | Undo input editing; redo with `C-g C-/`, or `undo-redo` on Emacs 28+ (the transcript is never undone) |
| `TAB` | Complete a slash command or skill |

**Sending during a running turn:** by default, `C-c C-c` queues a non-empty
message for the next turn. `C-u C-c C-c` steers the running turn instead;
`C-c C-c` with empty input interrupts it. Configure this with
`dsh-emacs-busy-enter-behavior`. The `C-c C-q` queue menu acts on the
highlighted item; `x` deletes all pending items.

Type **`@`** to choose file, directory or session references: `@src/` drills
into a directory and `@session-title` mentions another session. See
[@ references](docs/reference.md).

Type **`/`**, then press **`TAB`** to complete a slash command. Automatic
popups depend on your completion front-end and its settings: corfu/company
can provide them with auto completion enabled; stock completion,
vertico and icomplete require `TAB`. The same list carries the session's
skills (host instruction bundles), with user-only ones marked. The token
completes wherever the host accepts a gesture — at the start of the message
or after a space — so `please /rev` + `TAB` becomes `please /review `; a
name no command or skill matches is left to path/word completion. See
[Slash commands](docs/slash-commands.md#three-ways-to-run-a-command) and
[Skills](docs/skills.md).

**`TAB`** completes a **local file path** once the token carries a separator:
`docs/rp`, `./src/`, `~/…` and `/abs/…` complete through the stock file-name
completer against the chat buffer's working directory — the session workspace
— with the same directory drill-down as `find-file`, the path suffix after
the cursor preserved, and the active completion styles (abbreviated
directories work with `partial-completion`). A `/name` at the start of the
input is reserved for slash commands even when their catalog is empty; in the
middle of a message a `/name` only goes to command completion when a command
or skill actually matches it, so `see /usr` still completes as a path.
Completion reads the machine Emacs runs on, like `!` shell lines — with a dsh
server on another host, use an `@` reference instead. A path with spaces is
not handled in plain text (the token ends at the space); quote it as an `@`
reference.

**`TAB`** also completes an ordinary word from what is already in the buffer:
the draft above point and, within `dsh-emacs-word-completion-limit`
characters, the transcript above it — so a term from an earlier message or
tool result completes instead of being retyped. Words are runs of letters,
digits, `_` and `-`, so identifier-like terms such as `dsh-emacs-mode`
complete whole. Candidates appear nearest-first, and completion inside a
word includes the existing suffix. Slash commands and `@` references keep
their own completion even when their catalogs are empty.

The composer shows the current goal and the next pending message above `❯`.
Hover over the preview for its full text, or use `C-c C-q` to manage pending
messages. Goal shortcuts and inline controls are described in
[Goal actions](docs/customization.md#goal-actions).

Expanded file-edit cards show unchanged lines once as context, with red/green
rows and totals for the changes. See
[Tool cards](docs/ui-styling.md#tool-calls-dsh-web-style) for the display
rules, including the limit for very large replacements.

### Answering questions

Agent `ask` prompts are answered in one minibuffer read. The question text is
the prompt, the options are the completion candidates (each one carries its
description as an annotation), and the question detail shows in the echo area.

- Single choice: pick a candidate, `RET` accepts it. Empty input skips the
  question.
- Multiple choice: type the options comma-separated — `2,3` or `alpha,beta` —
  and `RET` submits them (`completing-read-multiple`, Emacs' standard
  comma-separated input path). An unambiguous prefix works too (`alph`), and
  an ambiguous one is left as your answer text rather than guessed.
- Anything that names no option is taken as your answer text, like at any
  Emacs completion prompt — there is no separate "type an answer" step, and
  a partly-matched answer is never silently trimmed.
- `C-c C-s` skips the question (empty input does the same); `C-g` abandons
  the whole group.

Nothing is toggled in place and the reader never reopens: one read per
question, so the menu cannot flicker or reorder.

```elisp
(setq dsh-emacs-question-help-display 'echo-area) ; default; nil hides the detail
```
Try `M-x dsh-emacs-question-preview` locally, without contacting a server.
See [Question prompts](docs/customization.md#ask-question-prompts) for details.

### Workspaces

Workspaces group sessions by project/directory.

New sessions use the current workspace when created from a workspace header,
its empty New Session row, or an existing chat. Without that context, a
**local server** can use the Emacs project of the current buffer's directory,
creating its workspace on first use. This detection is controlled by
`dsh-emacs-new-session-auto-project` and does not run for remote servers.
Otherwise the new session uses the current buffer's directory.

### Local shell commands

Enter `!git status` and press `C-c C-c` to run a command locally in the
session's workspace directory. Output appears in the transcript, including
while a model turn is running. `C-c C-!` stops the tracked shell process.

Shell output is not sent to the model or saved in server history; refreshing
the transcript removes it. With attachments, a leading `!` is caption text
sent to the model. See [Shell commands](docs/shell-commands.md) for multiline
scripts, shell selection and process handling.

### Skills

dsh skills are host-side instruction bundles (`SKILL.md` plus resources) for a
session's working directory and preset. dsh-emacs lists them in the `/`
completion (user-only ones marked) and in `M-x dsh-emacs-command`, the same
menu that runs slash commands: picking a skill inserts `/name ` at the cursor,
or with `C-u`, opens the picked skill's `SKILL.md`. The host expands a `/name`
gesture found in your prompt, so a skill is invoked like ordinary text
(`/review check the parser`). See [Skills](docs/skills.md).

### Images

`C-c C-v` pastes the system clipboard's image into the next message: it joins
a staged-attachments row above the input, you type a caption (or leave the
input empty to use the image name), and `C-c C-c` sends text and image
together. `C-c C-d` discards the staged images; the trailing `✕` on the row
does the same. `s-v` does the same as `C-c C-v` whenever the clipboard holds
an image, and falls back to ordinary text yank otherwise; `C-y` always stays a
plain text yank, so a clipboard carrying both an image and text can still paste
the text. Where the pasteboard exposes TIFF rather than PNG (macOS), the image
is converted with the system `sips` tool before upload, provided PNG is in
`dsh-emacs-attach-media-types`. A rejected send restores its caption and images
only while both the input and staged images are empty. Emacs 29+ users can
also run `M-x yank-media`. `C-c C-a` remains the one-shot form: it picks an
image file and sends it immediately. Only the media types in
`dsh-emacs-attach-media-types` are accepted.

### Models & presets

Configure providers, models and agent presets in dsh, through
`M-x dsh-emacs-open-web` or dsh's own configuration files. Use `C-c C-m` to
select a session's model and reasoning effort.

`dsh-emacs-default-preset` selects the preset for new sessions; nil uses the
host default. `dsh-emacs-default-model` is a display fallback for the mode
line and does not select the model used by a session. See
[Model picker](docs/model-picker.md) for details.

## Server setup

By default dsh-emacs manages a local server. To use one you run yourself, set
`dsh-emacs-base-url` to its address. Remote addresses, including HTTPS and
URLs with `user:pass@` Basic auth, never trigger a local server start. Set
`dsh-emacs-server-auto-start` to nil to disable automatic startup locally.

For a server dsh-emacs starts, launch-token authentication is automatic.
For a server you started yourself, provide the launch token from the URL it
prints (`dsh web: …/?token=…`). You can set `dsh-emacs-server-auth-token` to
the token, or paste the whole URL into `dsh-emacs-base-url`.
If a reverse proxy also requires Basic authentication, include its separate
credentials as `http://user:pass@host:port`; the dsh launch token is still
required. RPC authentication failures report HTTP 401 instead of asking for
a username and password, and clear the rejected cookie before the next attempt.

When prompted for an external server's token, a successful answer is saved
for reuse. After a server restart, the previous token may be stale and need
replacing. See [Server options](docs/customization.md#server-options).

## Streaming and appearance

Replies and thinking appear as they arrive. Large Markdown regions finish
styling while Emacs is idle; see
[Markdown responsiveness](docs/customization.md#markdown-responsiveness)
for tuning options.

Use `M-x customize-face` or `custom-set-faces` to change the appearance.
[UI styling](docs/ui-styling.md) lists the active faces and explains rendering;
the [streaming performance audit](docs/streaming-performance.md) records
measurements and remaining limits.

## Documentation

- [Customization](docs/customization.md) — configuration examples and options
- [@ references](docs/reference.md) — file, directory and session mentions
- [Slash commands](docs/slash-commands.md) — catalog, completion and execution
- [Skills](docs/skills.md) — host skill catalog and `/name` gestures
- [Shell commands](docs/shell-commands.md) — local `!command` execution
- [Model picker](docs/model-picker.md) — models, providers and reasoning effort
- [Mode line](docs/modeline.md) — status, context usage and pending queue
- [UI styling](docs/ui-styling.md) — faces and Markdown rendering
- [Development & testing](AGENTS.md) — workflow and verification
- [Architecture](docs/architecture.md) — module ownership and event flow
- [RPC protocol](docs/rpc.md) — methods, events and projections
- [Fragment extension API](docs/architecture.md#transcript-fragments-dsh-emacs-uiel) — snapshots and card styling
- [Changelog](CHANGELOG.md)

## Contributing

Development workflow and commit conventions are in [AGENTS.md](AGENTS.md).
Keep pull requests focused on one topic; for non-trivial work, open an issue
first to align the scope. Run `scripts/verify.sh` before pushing. It checks
syntax, checker self-tests, byte compilation, the full unit suite, silent
loading, diff whitespace, and generated-file cleanup.

## Acknowledgments

The UI mirrors [dsh web](https://github.com/deepseek-ai/deepseek-harness),
including its tool icons, session list and context meter. Markdown rendering
and folding build on [agent-shell](https://github.com/xenodium/agent-shell);
mode-line stats and compact token formatting follow
[pi-mono](https://github.com/badlogic/pi-mono).

## License

[GPL-3.0-or-later](LICENSE) — GNU General Public License v3 or later.
