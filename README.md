# dsh-emacs — an Emacs client for DeepSeek Harness

**dsh-emacs** brings [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)
(`dsh`) into Emacs: streaming replies, tool calls, thinking blocks, slash
commands, file/session references, and model selection. It uses Emacs
built-ins (Emacs 27.1+) with no third-party dependencies.

![Chat buffer with streaming replies and tool calls](assets/chat.png)

> **0.3.0** targets the **dsh 0.1.2** wire protocol (server **0.1.2-rc.1 or
> newer**).

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
| `C-c C-g` | Open the goal-action prefix |
| `C-c C-m` | Switch model / reasoning effort |
| `C-c C-a` | Attach an image |
| `C-c C-s` / `C-c M-s` | Switch session in this workspace / across all |
| `C-c C-r` | Refresh |
| `C-c C-f` | Toggle mode-line stats |
| `C-c C-!` | Stop the tracked local shell process |
| `M-p` / `M-n` | Previous / next input |
| `TAB` | Complete a slash command |

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
vertico and icomplete require `TAB`. See
[Slash commands](docs/slash-commands.md#three-ways-to-run-a-command).

The composer shows the current goal and the next pending message above `❯`.
Hover over the preview for its full text, or use `C-c C-q` to manage pending
messages. Goal shortcuts and inline controls are described in
[Goal actions](docs/customization.md#goal-actions).

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
