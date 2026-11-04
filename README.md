# dsh-emacs — an Emacs client for DeepSeek Harness

[![CI](https://github.com/vritser/dsh-emacs/actions/workflows/ci.yml/badge.svg)](https://github.com/vritser/dsh-emacs/actions/workflows/ci.yml)
[![dsh](https://img.shields.io/badge/dsh-0.2.1--rc.2-blue)](https://github.com/deepseek-ai/deepseek-harness/releases/tag/dsh-v0.2.1-rc.2)

Use [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (`dsh`)
from Emacs: streaming replies, tool calls, workspace sessions, subagent chats,
file attachments, and model selection. Requires **Emacs 28.1+**, with no
mandatory third-party Emacs packages.

https://github.com/user-attachments/assets/9ee9fc66-1997-49b7-a921-5753690edafa

dsh-emacs **0.7.0** is compatible with **dsh 0.2.1-rc.2**, the
[latest upstream release](https://github.com/deepseek-ai/deepseek-harness/releases/tag/dsh-v0.2.1-rc.2)
as of **2026-10-18** (npm `next`; npm `latest` still points to 0.2.0-rc.2).
The client includes compatibility fixes for the **dsh 0.2.1 protocol**:
server-assigned session IDs, migration-required projection reads, and external
subagent navigation guards. The [protocol reference](docs/rpc.md) is
source-audited through **dsh 0.2.1-rc.2**. Live validation on 2026-10-23
passed 31 E2E checks against that version (optional model-driven subagent and
running-status scenarios were not enabled); external-child guards have unit
coverage. Existing browser-cookie authentication is retained.

## Quick start

1. Clone the repository:

   ```sh
   git clone https://github.com/vritser/dsh-emacs.git ~/dsh-emacs
   ```

2. Add this to your Emacs configuration and evaluate it, or restart Emacs:

   ```emacs-lisp
   (add-to-list 'load-path (expand-file-name "~/dsh-emacs"))
   (require 'dsh-emacs)
   ```

3. Run `M-x dsh-emacs`. It opens the session list and starts a local server
   if needed, offering to install the dsh CLI when it is missing.
4. Configure a provider with `M-x dsh-emacs-add-provider`, or use
   `M-x dsh-emacs-open-web` for account sign-in and other provider families.
   Credentials and model settings stay on the dsh server.
5. Press `c` to create a session, use `C-c C-m` to choose a model, then type
   after `❯` and press `C-c C-c` to send.

For an existing server, configure [its address and authentication](#server-setup)
before connecting. A `use-package` example is in
[Customization](docs/customization.md#example-configuration).

## Using it

`M-x dsh-emacs` opens the session list with **Recents** first: the 15 most
recently updated visible sessions with workspace labels, followed by their
usual workspace groups.
Set `dsh-emacs-session-recents-limit` to change the count (zero hides Recents).
Set `dsh-emacs-session-recents-show-workspace` to nil to hide workspace labels.
Press `RET` to open a session, `c` to create one, and `TAB` to fold a group
or expand available subagents.
From a local project, the command locates its existing workspace; from a chat,
it locates that session. New sessions open an editable draft while connecting.
Opening an existing session in a fresh chat buffer completes only the latest
human round (a turn with a user-authored message), fetching extra pages for a
long round without moving your draft cursor. `C-c C-o` cancels an in-progress
history load; once finished, it loads 3 earlier user+assistant rounds by
default (`dsh-emacs-history-rounds`). Switching back to a live chat
preserves it.

The PTC mode preset ID is now `ptc`. If your configuration sets
`dsh-emacs-default-preset` to `"code"`, change it to `"ptc"`.

Idle session dots, the `New Session` placeholder and muted text (timestamps,
reply footers, deliverable descriptions, subagent error notices) use the
theme's `shadow` face (grey by default); running session dots are orange.

### Essential keys

| Key | Action in a chat buffer |
|---|---|
| `C-c C-c` | Send; while busy, queue input or interrupt if input and attachments are empty |
| `C-u C-c C-c` | Steer the running turn (default configuration) |
| `C-c C-b` | Interrupt the running turn |
| `C-c C-q` / `C-c C-j` | [Manage pending messages / background jobs](docs/customization.md#queue-and-job-menus) |
| `C-c C-m` / `C-c C-e` | Select a model / change reasoning effort |
| `C-c C-a` | Stage a file; repeat to add more |
| `C-c C-v` / `C-c C-d` | Paste a clipboard image / discard staged attachments |
| `C-c C-o` | Load 3 earlier user+assistant rounds; prefix chooses the count; press again to cancel |
| `C-c >` | Return to the draft and follow new output |
| `C-c C-w` / `C-c C-y` | Copy content / fork through the assistant reply at point |
| `C-c C-l` | Locate this session in the list ([jump preference](docs/customization.md#renaming-and-grouping)) |
| `C-c C-s` / `C-c M-s` | Switch sessions in this workspace / across all workspaces |
| `C-c C-r` | Refresh the chat |
| `M-p` / `M-n` | Recall previous / next input |
| `TAB` | Complete commands, skills, references, local paths, or words |

User messages stay left aligned with a teal left rail and light inner
spacing, with one blank line before and after each question. Answers
remain frameless; completion summaries leave a small gap above the answer without changing its font.
Ordinary Emacs undo applies only to the input, leaving the transcript intact.
Copying a user-message line yields its authored text; pasting does not carry
the conversation rail or spacing into the destination.
`M-x imenu` navigates the conversation's questions. Click a folded tool or
thinking header, or press `RET` on it, to expand it. Once a turn ends,
continuous thinking and tool cards between replies fold into activity summaries
such as **Read files and ran commands**. Replies stay outside these groups.
Successful turns without mid-turn input additionally fold their whole process
under **Completed…**, leaving any final answer visible. **Failed** and **Stopped**
are non-foldable status rows, as are completion rows for turns with mid-turn input;
their internal activities still fold independently. Running turns stay open.
Earlier history extends disclosures without resetting manual expansion.
Set `dsh-emacs-fold-work-details` to `nil` and reopen the chat for a flat transcript.
See [Web folding rules and remaining differences](docs/web-folding.md).
Visible chat windows follow new output independently while their cursors and
views stay near the draft, preserving each editing position. Windows reading
older messages stay put; `C-c >` returns that window to the draft and following.
Typing from the read-only transcript jumps to the composer; extend
`dsh-emacs-composer-typing-commands` for a mode-specific editing command
(see [Customization](docs/customization.md#typing-from-the-transcript)).

The 0.7.0 release removes `dsh-emacs-group-consecutive-tools` and
`dsh-emacs-assistant-divider`; both are deleted, so remove any remaining
entries from personal configuration. Tool cards still fold independently and
assistant message spacing is unchanged. See
[Customization](docs/customization.md).

The unused Lisp helpers `dsh-emacs-modeline-set-cwd`,
`dsh-emacs-modeline-set-branch`, `dsh-emacs-modeline-teardown` and
`dsh-emacs-usage-p` are also removed in 0.7.0 without aliases. Remove calls
from personal Lisp code; cwd and branch follow the chat's `default-directory`
and cached Git detection. See [Mode-line](docs/modeline.md).

### References, commands, and attachments

- **`@` references** select server-side files, directories, or sessions.
  Discovery runs in the background; Corfu refreshes as results arrive, while
  other frontends may need another `TAB`. See [@ references](docs/reference.md).
- **`/` commands and skills** complete with `TAB`, including after a space
  inside a message. Use `/plan` for plan mode and `/plan off` to leave it.
  Submitted plans open in a review buffer. See
  [Slash commands](docs/slash-commands.md) and [Skills](docs/skills.md).
- **Attachments** are staged with `C-c C-a`, clipboard paste, or drag-and-drop.
  `C-c C-c` sends them with your input; a blank input uses their file names.
  See [Attachment staging](docs/customization.md#attachment-staging).
- **`!git status`** runs locally in the session's workspace. Its output is
  neither sent to the model nor saved in server history. Plain path completion
  also uses the machine running Emacs; use `@` for remote server files.
  See [Shell commands](docs/shell-commands.md).

Unfinished output stays in a compact transcript card, explicitly labelled
**Retry** (scheduled or started), **Failed reply**, **Cancelled reply**, or
**Retry cancelled** using the server's follow-up events. Recovery without an
explicit retry event shows **Retried** once another response arrives in the
same turn and step. Partial output remains
expandable; hover the title for failure details. The mode line keeps running
activity and elapsed time without a separate retry label. If outcome events
are unavailable, the card says **Incomplete reply**. Retry, cancellation, model
errors and compaction failures share a status-dot icon: orange for retry, red
for failure, grey for cancelled/unknown. Model error reasons remain visible
below the title.

### Goals, subagents, and questions

The composer shows the next pending message, then the active goal. `C-c C-g`
opens [goal actions](docs/customization.md#goal-actions); `C-c C-q` manages the
queue.
The default busy-send behavior is configurable with
`dsh-emacs-busy-enter-behavior`.

`M-,` returns to the originating position after opening files, sessions,
plans, images or job output. `M-x dsh-emacs-list-subagents` opens child
conversations. Continuable children accept follow-up input, while
one-shot children are read-only. See [Subagents](docs/subagents.md).

Agent questions use your normal minibuffer completion. Pick an option or type
an answer; multiple-choice answers accept comma-separated options such as
`2,3`. Empty input skips a question. `C-c C-p` answers an expired timed question.
See [Question prompts](docs/customization.md#ask-question-prompts).

### Appearance

The mode line shows model, usage, and activity. Install
[Motion Line](https://github.com/vritser/motion-line) separately for an animated
whale and elapsed clock; without it, activity captions remain static.
Native mode lines always keep the plain `DSH` major-mode label; the separate
whale-tail animation, caption and clock appear only during activity.
Doom keeps its static whale logo and existing layout.
Completed replies show Copy, Fork and tokens together on the left, in order.
Elapsed time appears in the compact Completed disclosure above the answer; add `duration` to
`dsh-emacs-reply-footer-items` to also show it in the footer.

Transcript event rows follow `dsh-emacs-render-style`: `full` (the
default) draws dsh-web's SVG icons where Emacs can, while `simple` leads every
event row with one compact dot (state-colored where the row carries state) and
mutes the rest of the row.

See [Mode line](docs/modeline.md),
[Reply footer](docs/customization.md#reply-footer), and
[UI styling](docs/ui-styling.md) for configuration.

## Server setup

By default, dsh-emacs manages a local server. For a server you run yourself:

```emacs-lisp
(setq dsh-emacs-base-url "http://127.0.0.1:3080"
      dsh-emacs-server-auto-start nil)
```

Remote addresses, including HTTPS, never trigger a local server start.
Authentication is automatic for servers started by dsh-emacs. For an external
server, paste its printed launch URL (`http://host:port/?token=…`) into
`dsh-emacs-base-url`, set `dsh-emacs-server-auth-token`, or supply the token when
prompted. Successful prompted tokens are saved; a server restart may require
a new one. Reverse-proxy Basic auth is separate from the dsh launch token.

See [Server options](docs/customization.md#server-options) for configuration,
[Adding providers](docs/customization.md#adding-providers) for model setup,
and [Editing dsh configuration](docs/customization.md#editing-dsh-configuration)
for local or TRAMP configuration files.

## Documentation

- [Customization](docs/customization.md) — options, history, workspaces, approvals
- [@ references](docs/reference.md) · [Slash commands](docs/slash-commands.md) · [Skills](docs/skills.md)
- [Shell commands](docs/shell-commands.md) · [Model picker](docs/model-picker.md) · [Subagents](docs/subagents.md)
- [Mode line](docs/modeline.md) · [UI styling](docs/ui-styling.md)
- [Changelog](CHANGELOG.md) — release notes and breaking changes
- [Architecture](docs/architecture.md) · [RPC protocol](docs/rpc.md)

## Contributing

Follow [AGENTS.md](AGENTS.md), keep changes focused, and run
`scripts/verify.sh` before pushing. It checks syntax, byte compilation, unit
tests, clean loading, and repository hygiene. CI runs the same gate on Emacs
28.1 and a current stable release. Optional
[GUI tests](docs/architecture.md#gui-display-regression-tests) and
[real-server tests](docs/architecture.md#real-server-e2e-testing) cover display
and transport behavior.

After editing source, `M-x dsh-emacs-reload` reloads it while preserving chats
and drafts. Removed definitions and changed struct layouts require a restart;
see [Source reload](docs/customization.md#reloading-local-source).

## Acknowledgments

The UI mirrors [dsh web](https://github.com/deepseek-ai/deepseek-harness).
Markdown rendering and folding build on
[agent-shell](https://github.com/xenodium/agent-shell); mode-line stats and
compact token formatting follow [pi-mono](https://github.com/badlogic/pi-mono).

## License

[GPL-3.0-or-later](LICENSE) — GNU General Public License v3 or later.
