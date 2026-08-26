# dsh-emacs — An Emacs client for DeepSeek Harness

An Emacs frontend for [dsh](https://github.com/deepseek-ai/deepseek-harness) (DeepSeek Harness) that talks to a running dsh web service over HTTP and offers a modern, Emacs-native interactive experience.

## English Overview

`dsh-emacs` is an Emacs client for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (dsh). It talks to a running dsh web service (`http://127.0.0.1:3080`) over plain HTTP/WebSocket and renders sessions, streaming replies, tool calls and thinking blocks with an Emacs-native UI:

- **Session list** (`*dsh-sessions*`): card-style browsing, search/filter, create / open / rename / archive sessions
- **Chat buffer**: read-only transcript with a fixed input area, streaming output and Markdown rendering
- **Collapsible tool calls & thinking blocks** (folded by default)
- **Mode-line footer**: model · reasoning effort · agent preset · context-window percentage (color-coded), all customizable via `M-x customize-group RET dsh-emacs-footer`
- **Mode-line buffer name** matches the session list title (`dsh-<title>`), and `default-directory` points at the session workspace so `magit-status`/`project-*` start in the right repo
- **Zero runtime dependencies**: core `url` / `json` / `cl-lib` only; Emacs 27.1+
- **Out-of-the-box server bootstrap**: the `dsh` CLI is auto-detected (asking to install it with `npm install -g @deepseek-ai/dsh` when missing) and the server is started on demand before any server-touching command — no manual `dsh web` needed
- **Resilient event stream**: native RFC 6455 WebSocket client with fallback polling, watchdog and anchored incremental history rendering

## Design Highlights

The design language draws on mainstream coding agents (agent-shell, pi, opencode) to achieve a clear visual hierarchy:

- **User messages**: card background, light teal tint, timestamped
- **Assistant messages**: frameless design, pure Markdown rendering, separated by dividers
- **Thinking blocks**: collapsible `<details>`-style items, folded by default, shown with dsh web's Think icon (IconThink) + "Think" + a first-sentence preview (truncated with `...` when too long)
- **Tool calls**: collapsible tool rows modeled on dsh web, with a variant icon + status color (pending=orange, success=green, error=red) and separate IN/OUT sections
- **Activity groups**: consecutive tool calls are merged automatically and show an aggregate status (e.g. "2 of 3 completed")
- **Footer status bar**: a bottom status bar showing cwd, git branch, model, tokens, context%, and cost
- **Session list**: card view showing session title, working directory, branch, and last activity time

## Features

- **Session list** (`*dsh-sessions*`): card-style browsing, search filtering, quick open/create/rename
- **Chat buffer**: read-only transcript on top with a fixed input area at the bottom, supporting streaming output and Markdown rendering
- **Interrupt**: while a turn is running, pressing `C-c C-c` again issues `session.cancel` — the agent stops mid-flight, the partial reply stays in the transcript
- **User questions**: when the agent's `ask` tool poses a question, each question is answered in the minibuffer — the option labels appear numbered (`1. label`; type the number to jump), the **Type answer…** candidate is pinned last and reads a free-text answer (an empty free-text input goes back to the options), multi-select takes comma-separated picks, and multi-question frames run one after another with a `Question N/M` prompt prefix. Prompts carry the owning session's label (`[dsh-<title>]`), and frames from different sessions are answered one at a time in arrival order — the minibuffer is a single global resource, so later arrivals queue up instead of stacking their prompts. The reply goes out via `/api/respond` (dsh 0.1.1-rc.2 `question/requested` flow)
- **Model switching**: `C-c C-m` opens the live model catalog and switches the session's model, updating the footer immediately — rows are grouped by provider with sticky headers while filtering, and models with reasoning-effort options get a second mini-prompt for the effort. Details in [Model Picker](#model-picker).
- **Image attachments**: `C-c C-a` (or drag & drop onto the chat buffer) attaches images inline as base64 in the prompt, with media-type and caption
- **Code-block copy**: `C-c C-k` (or `RET` on the `LANG ⧉` label) copies the fenced block under point to the kill ring
- **Session fork**: `f` in the session list branches a session (`session.fork`) into a child that inherits the full history, then opens it
- **Workspace filter**: `w` in the session list filters rows to one workspace; the filter survives refreshes and is shown in the header
- **Session-list auto refresh**: `dsh-emacs-session-auto-refresh-interval` re-fetches the list on a timer (`g` still refreshes manually)
- **Input history**: `M-p` / `M-n` recall previously submitted prompts in the input area
- **Footer status bar**: live token usage, cost, and context percentage (color-coded: <50% green, 50-80% yellow, >80% red)
- **Smart collapsing**: tool calls and thinking blocks are folded by default and expand on demand
- **Asynchronous polling**: session history is polled automatically after sending, and stops automatically when the WebSocket reconnects
- **Server bootstrap on demand**: before any server-touching command, the server address is probed — down, the `dsh` CLI is located (asking to install it when missing) and `dsh web --no-open` is started in the background and awaited, so the first `M-x dsh-emacs` just works
- **Zero dependencies**: uses only the built-in `url` / `json` libraries; Emacs 27+

## Model Picker

`C-c C-m` (`dsh-emacs-select-model`) reads `session.models` and calls `session.selectModel`. Rows show the model **id** only (the provider name lives inside the row key, so it stays searchable while filtering); duplicates of the same id across providers keep their provider visible in the suffix.

- **Sticky provider groups**: the table carries a `group-function` in its completion metadata. Modern vertico (and Emacs 27+ `*Completions*` buffers) draw one sticky header per provider, recomputed on every filter input, so grouping is never lost while searching — no `vertico-group.el`/group-mode needed. In completion UIs without group support, provider headers are ordinary candidates and colliding ids fall back to a per-row provider suffix.
- **Header style**: inside the picker, `vertico-group-format` is overridden buffer-locally by `dsh-emacs-model-group-format` (defaults to just the provider name — vertico's stock long separator lines are dropped; other completions keep their global format unchanged).
- **Row icons**: the table metadata declares its own `category` (`dsh-model`), which keeps row prefixes clean against `nerd-icons-completion` by default. Once that package is loaded, the picker auto-registers a default chip icon (`nf-cod-chip`) for the category — zero configuration. To use a different icon, register the category yourself and your entry wins (the auto default is skipped):
  `(add-to-list 'nerd-icons-completion-category-icons '(dsh-model . (nerd-icons-faicon "nf-fa-robot" nerd-icons-blue)))`
- **Reasoning effort**: models that declare `reasoning` options (efforts + defaultEffort) get a second mini-prompt right after the model pick. Re-picking the current model pre-selects its live `reasoningEffort`; other models pre-select their `defaultEffort`. The chosen id is sent as `session.selectModel`'s `reasoningEffort`; models without `reasoning` send no effort field at all.
- **Behaviour**: empty RET keeps the current model (no RPC), unknown input is rejected, `C-g` cancels cleanly inside the RPC filter; when vertico is active the picker locally disables extra sorting and pre-selects the first row.

## Architecture

Modular design that is easy to maintain and extend:

```
dsh-emacs/
├── dsh-emacs.el              # Main entry point, RPC client, session management, mode definition
├── dsh-emacs-protocol.el     # Typed views of dsh RPC payloads (cl-defstruct)
├── dsh-emacs-ui.el           # UI framework (rounded borders, collapsing, fragment management)
├── dsh-emacs-faces.el        # Unified face definitions and theme variables
├── dsh-emacs-tokens.el       # Token tracking and formatting
├── dsh-emacs-markdown.el     # Markdown syntax highlighting
├── dsh-emacs-render.el       # Event renderer (user/assistant/tool/thinking)
├── dsh-emacs-events.el       # Event stream: native WebSocket + fallback polling
├── dsh-emacs-footer.el       # Footer status bar
├── dsh-emacs-server.el       # Server bootstrap: probe / auto-start / install
└── dsh-emacs-session.el      # Session list card view
```

### Protocol layer (`dsh-emacs-protocol.el`)

dsh server responses arrive as decoded JSON alists (arrays as vectors). Their
common shapes are normalized into `cl-defstruct` types here, and business
code reads fields exclusively through generated accessors
(e.g. `dsh-protocol-model-selection-reasoning-effort`,
`dsh-protocol-session-cwd`): each wire field name appears only in the
matching `--from-alist` constructor, so when the server protocol changes you
sync exactly one file. Covered payloads:

- `session.list` → `dsh-protocol-session` (sessionId, title, cwd,
  agentPreset, updatedAt, blank, running, title-value, pending-interaction)
- `workspace.list` → `dsh-protocol-workspace-list` (items,
  archived-session-ids) → `dsh-protocol-workspace` (workspaceId, sessionIds,
  title, path, createdAt, updatedAt)
- `workspace.create` / `rename` / `insertSessionBefore` →
  `dsh-protocol-workspace-result` (workspace, created)
- `session.models` → `dsh-protocol-model-directory` → `provider-group` →
  `model-catalog-entry` → `reasoning` → `effort`, plus
  `dsh-protocol-model-selection` for `current`
- `session.selectModel` → `dsh-protocol-model-selection-result` (selected)
- `agentPreset.list` → `dsh-protocol-agent-preset-list` (presets,
  authorable, has-document) → `dsh-protocol-agent-preset` (id, trust,
  is-default, name, description, broken)

Conversion is one-way and lossless: `session.models` responses become a
`dsh-protocol-model-directory` before the picker reads them; the cached
session/workspace lists are stored as structs too. Helper
`dsh-protocol--struct` accepts either a wire alist or an already-converted
struct, so callers and fixtures can stay on either side of the boundary.
Event-stream payloads stay raw for now (their shapes vary per event type).

## Installation

Add all `.el` files to `load-path`:

```elisp
(add-to-list 'load-path "/path/to/dsh-emacs")
(require 'dsh-emacs)
```

Or in `use-package`:

```elisp
(use-package dsh-emacs
  :load-path "/path/to/dsh-emacs"
  :commands (dsh-emacs dsh-emacs-new-session))
```

## Prerequisites

The dsh CLI is auto-managed out of the box; a manually run server also works:

- **Auto-detection & install**: when the `dsh` executable is missing, the first server-touching command asks whether to install it (`npm install -g @deepseek-ai/dsh`, customizable via `dsh-emacs-server-install-command`); declining gives manual instructions.
- **Server auto-start** (`dsh-emacs-server-auto-start`, default `t`): the probe checks `dsh-emacs-base-url`; if nothing answers, `dsh web --host H --port P --no-open` is spawned in the background (host/port come from the base URL) and dsh-emacs waits up to `dsh-emacs-server-wait-seconds` for it to become ready. The spawned process is tracked and stopped on Emacs exit (or via `M-x dsh-emacs-server-stop`); set the option to `nil` to manage the server yourself.
- **Manual server**: a server you start yourself is just used — dsh-emacs never kills it:

```sh
dsh --profile web
```

A different address/port can be set via `dsh-emacs-base-url`:

```elisp
(setq dsh-emacs-base-url "http://127.0.0.1:8080")
```

### Provider configuration

Provider/model configuration is **owned by dsh**, not by dsh-emacs — this package is a thin client that reads the catalog via `session.models` and has no provider-editing surface. Configure providers in the dsh web UI (`M-x dsh-emacs-open-web` opens it; Settings is a modal inside the app), or directly in the dsh home files (`~/.dsh/settings.yaml`, `~/.dsh/.credentials.yaml` for API keys, `~/.dsh/profiles/<name>/cordis.yml` for profile layers). Changes appear in dsh-emacs after a refresh (`g` in the session list, `C-c C-r` in a chat buffer); the model picker (`C-c C-m`) shows exactly the providers the host announces.

## Quick Start

| Command | Description |
|---|---|
| `M-x dsh-emacs` | Open the session list |
| `M-x dsh-emacs-new-session` | Create a new session. On a workspace header / its empty New Session row the session is created inside that workspace; elsewhere as an ungrouped session. With a prefix argument (`C-u`), first choose the agent preset (thinking preset) from the live `agentPreset.list` roster |
| `M-x dsh-emacs-open-session` | Open an existing session by ID |
| `M-x dsh-emacs-fork-session` | Fork a session into a child that inherits its history |
| `M-x dsh-emacs-select-model` | Switch the current session's model (live catalog) |
| `M-x dsh-emacs-attach-file` | Attach an image to the current session and send it |
| `M-x dsh-emacs-copy-code-block` | Copy the code block under point |
| `M-x dsh-emacs-health` | Check whether the dsh service is reachable |
| `M-x dsh-emacs-server-start` | Start the dsh server as a managed background process (asks to install the dsh CLI when missing) |
| `M-x dsh-emacs-server-stop` | Stop the managed dsh server process (never touches servers you started) |
| `M-x dsh-emacs-server-restart` | Restart the managed dsh server process |
| `M-x dsh-emacs-open-web` | Open the dsh web UI in the browser (provider/model config lives in dsh; Settings is a modal there) |

## Chat Buffer Key Bindings

| Key | Command | Description |
|---|---|---|
| `C-c C-c` | `dsh-emacs-send-or-stop` | Send the text in the input area; **press again while generating to interrupt** (`session.cancel`, partial reply kept) |
| `C-c C-r` | `dsh-emacs-refresh` | Reload and render the full history |
| `C-c C-l` | `dsh-emacs-list-sessions-display` | Open the session list |
| `C-c C-w` | `dsh-emacs-copy-transcript` | Copy the transcript to the kill-ring |
| `C-c C-f` | `dsh-emacs-footer-toggle` | Toggle the footer status bar |
| `C-c C-k` | `dsh-emacs-copy-code-block` | Copy the fenced code block under point |
| `C-c C-a` | `dsh-emacs-attach-file` | Attach an image and send it as a prompt |
| `C-c C-m` | `dsh-emacs-select-model` | Choose a model for the session |
| `M-p` / `M-n` | `dsh-emacs-input-history-back/forward` | Recall previously submitted prompts |

Send rule: sends the text after the `❯ ` prompt in the input area. The input field and the reply live **in the same buffer** (agent-shell style): the `❯` input line stays at the bottom of the transcript, replies stream in above it, and the cursor always stays in the input area — chat buffers set a telega-style scroll discipline (`scroll-conservatively`/`next-screen-context-lines`/`scroll-error-top-bottom`), so the prompt line stays visible while typing and page commands land on line boundaries; scrolling away to read history does not pull the view back.

**Workspace path**: each session buffer's `default-directory` automatically points at that session's workspace (the `cwd` from `session.list`, consistent with the list/grouping), so `M-x magit-status`, `M-x dired` or `project-*` commands run directly in the corresponding project directory from the chat buffer; it stays in sync after session-list refreshes/renames.

**No save prompts**: session transcripts are never written to disk, and the chat buffer always stays in unmodified state — closing the buffer (`C-x k`, tab/window-manager close) never shows a "buffer modified, save?" prompt.

## Session List Key Bindings

| Key | Description |
|---|---|
| `RET` | Open the session at point |
| `c` | Create a new session (default preset) |
| `C` | Create a new session after choosing its agent preset |
| `r` | Rename the session |
| `D` | Archive the session (remove it from its workspace view) |
| `f` | Fork the session into a child that inherits its history |
| `w` | Filter the list to one workspace (empty answer clears) |
| `g` | Refresh the list |
| `/` | Search filter |
| `i` | Show session details (title, cwd, branch, preset, live model) |
| `q` | Quit the list |

> Note: `D` (archive) removes the session from its workspace via
> `workspace.archiveSession`; the session data itself is kept server-side.
> There is no `session.delete` RPC in current dsh server versions.

## Footer Status Bar

The footer is displayed at the bottom of the chat buffer and contains the following segments (separated by ` • `):

- **cwd**: current working directory (home path abbreviated with `~`)
- **branch**: git branch name (auto-detected)
- **model**: current model name
- **effort**: reasoning effort (the `reasoningEffort` chosen via the model picker, e.g. `max`)
- **preset**: agent preset of the session (`agentPreset`, e.g. `standard` / `code`)
- **tokens**: token usage (`↑input ↓output Rcache-read Wcache-write CHcache-hit%`)
- **ctx**: context-window usage percentage (color-coded)
- **cost**: cumulative cost (USD)

The footer can be toggled with `C-c C-f`, or controlled via the `dsh-emacs-footer-enabled` customization option.

The branch segment has a 10-second TTL cache (`dsh-emacs-footer-branch-refresh-interval`): the running spinner animation triggers a mode-line recomputation about every 80ms, and without caching each tick would fork a `git rev-parse` subprocess (~30ms+), which would freeze Emacs; the nil result for non-git directories is cached too, so it never respawns.

### Mode Line (session buffer status bar)

dsh-emacs does **not replace** your mode line; instead it makes two small additions to your existing (default or custom) `mode-line-format`: while **dsh is running** (after sending a prompt, before `turn/end` is received), a spinner animation is shown beside the DSH mode name (end-of-line area); the footer segment is appended at the far right. The modified flag, line/column position, primary/secondary modes, misc-info, and all other existing content are preserved:

```
 U:***  %b   L40  DSH [██  ]  [ deepseek-v4-flash • max • code • CH95% ]
```

- Spinner animation: filled progress bar (`[█   ]` fills to `[████]` then drains to `[   █]`, the `progress-bar-filled` style from Malabarba's spinner.el, with the track drawn as square brackets), `dsh-emacs-mode-line-busy-face` (amber), about 12.5fps, displayed at the end of the line next to the DSH mode name
- The animation is hidden when idle; when the footer segment is empty the right end is not shown either (the right side of the mode line stays as-is)
- The splicing is done with `(:eval …)` and is recomputed live on `force-mode-line-update`
- **Buffer name**: session buffers are named `dsh-<list title>` (matching the title of the row in the `*dsh-sessions*` list, with `dsh` prepended), which is what `%b` in the mode line shows; a `%` in the title is replaced with the full-width `％` (mode-line `%`-expansion would swallow characters), sessions with the same title automatically get a `<N>` suffix, and the buffer is renamed automatically with the list refresh after a title drifts or is renamed

The animation lights up when a message is sent and goes out at `turn/end` (or when polling detects that the turn ended); it is cleaned up automatically when the event stream disconnects.

## Customization Options

```elisp
(setq dsh-emacs-base-url "http://127.0.0.1:3080")  ; dsh service URL
(setq dsh-emacs-poll-interval 1.0)                 ; WebSocket fallback poll interval (fetches only the latest window ≈850 events; don't set it too small)
(setq dsh-emacs-poll-fallback t)                    ; nil = disable fallback polling entirely; refresh manually after a disconnect (C-c C-r)
(setq dsh-emacs-poll-warn-delay 5.0)                ; poll warning delay: warns only once when fallback polling has not recovered for ≥5s (avoids false "not connected" alarms)
(setq dsh-emacs-history-window 30)                  ; messages fetched when opening a session (maxMessages): larger = fuller history but slower opening (GC/parsing scale with it)
(setq dsh-emacs-history-refetch-max-rounds 6)       ; max backfill rounds during load gaps: improves coverage when events are still arriving at high rate right after opening, at the cost of more small parse chunks
(setq dsh-emacs-show-reasoning t)                  ; show reasoning content (on by default; nil = hide, unlike dsh web)
(setq dsh-emacs-show-tool-calls t)                 ; show tool calls
(setq dsh-emacs-default-cwd default-directory)     ; working directory for new sessions
(setq dsh-emacs-default-model "claude-opus-4-5")   ; default model name
(setq dsh-emacs-default-preset "standard")         ; default agent preset for new sessions (nil = host default; "standard"/"minimal"/"code"/"cordis" or a user preset id)
(setq dsh-emacs-model-group-format #(" %s " 0 4 (face vertico-group-title))) ; provider group-header format inside the model picker (nil = hide group titles)
(setq dsh-emacs-input-history-length 50)           ; prompts kept for M-p / M-n recall
(setq dsh-emacs-ui-label-separator "·")            ; separator between Think/Tool title and its right-side summary ("" = plain gap)
(setq dsh-emacs-tool-titles '(("pwsh" . "PowerShell"))) ; tool name -> display title overrides (icons stay per variant; unnamed tools get a humanized name, e.g. grep -> "Grep")
(setq dsh-emacs-attach-media-types '("image/png" "image/jpeg" "image/webp" "image/gif")) ; accepted upload types
(setq dsh-emacs-session-auto-refresh-interval nil) ; seconds between automatic session-list refreshes (nil = off)
(setq dsh-emacs-footer-enabled t)                  ; whether the footer status bar is enabled
```

## UI Styling

All faces are defined via `defface` and adapt automatically to light/dark themes:

### User/Assistant Messages
| Face | Description |
|---|---|
| `dsh-emacs-user-face` | User label "👤 You" (cyan) |
| `dsh-emacs-user-block-face` | User message card background (light teal) |
| `dsh-emacs-assistant-face` | Assistant label "🤖 Assistant" (magenta) |
| `dsh-emacs-assistant-body-face` | Assistant message body (no background) |

### Tool Calls (dsh web style)
| Face | Description |
|---|---|
| `dsh-emacs-tool-pending-face` | Tool running (orange border + light orange background) |
| `dsh-emacs-tool-success-face` | Tool succeeded (green border + light green background) |
| `dsh-emacs-tool-error-face` | Tool failed (red border + light red background) |
| `dsh-emacs-tool-stopped-face` | Tool interrupted (purple) |
| `dsh-emacs-tool-icon-face` | Tool variant icon (purple, mimicking dsh web's tool purple #a78bfa) |
| `dsh-emacs-tool-io-face` | IN / OUT section labels |
| `dsh-emacs-tool-title-face` | Tool card title |
| `dsh-emacs-tool-output-face` | Tool output text |
| `dsh-emacs-tool-running-face` | Running status indicator |

Tool rows mimic dsh web's `ToolRow`: each tool call renders as one row of **collapsible** cards, with a header of `variant icon + title + summary`; expanding reveals a dsh web-style **ioCard** (an `IN` arguments / `OUT` result pair). Icons correspond one-to-one with dsh web's `VARIANT_ICONS`:

| Variant | Icon | Corresponding dsh web icon |
|---|---|---|
| bash (bash/pwsh) | 💻 | IconApiOutline14 (terminal) |
| read (read/web_fetch/cordis_*_inspect) | 📖 | IconBrowseOutline16 (browse) |
| search (web_search/grep/glob) | 🔍 | IconSearchOutline16 (magnifier) |
| write | ✏️ | IconEditOutline16 (pencil) |
| edit | ✏️ | IconEditOutline16 (pencil) |
| code (run_code) | `</>` | IconCodeOutline16 (code brackets) |
| others (cordis_run, etc.) | ✨ | IconSparkle16 (sparkle) |

Status semantics align with dsh web's `leadingFor`/`stateStatus`:
- **Running**: keeps the variant icon with purple highlighting (no spinner animation)
- **Success** (exit 0): keeps the variant icon, appends `✓ exit 0` to the body
- **Failure** (exit≠0 / signal / isError): leading switches to the red status dot `●`, body shows `✗ exit N`
- **Interrupted** (signal): leading switches to the yellow status dot `◐`, body shows `⏸ interrupted`

The collapsed state is a **compact single line** (no ellipsis placeholders, no extra blank lines), and adjacent tool rows stack tightly; pressing `RET` on a tool row expands/collapses the IN/OUT body (the body is stored inside the block, so expanding always restores it).

Summary key precedence matches dsh web's `SUMMARY_KEYS`: bash→`description|command`, read→`path|file_path|url`, search→`query|pattern|url`, write/edit→`path|file_path`, code→`description`.

### Thinking Blocks
| Face | Description |
|---|---|
| `dsh-emacs-thinking-face` | Thinking label (dsh web IconThink icon + "Think") |
| `dsh-emacs-thinking-body-face` | Thinking block body (italic, subdued) |

The collapsed row shows a preview of the first reasoning sentence on the right (`dsh-emacs-thinking-preview-max` controls the maximum length; longer content is truncated with `...`; set to 0 to disable).

### Activity Groups
| Face | Description |
|---|---|
| `dsh-emacs-group-face` | Activity group header (e.g. "2 of 3 completed") |
| `dsh-emacs-group-count-face` | Activity group count |

### Footer Status Bar
| Face | Description |
|---|---|
| `dsh-emacs-footer-face` | The entire footer |
| `dsh-emacs-footer-separator-face` | The "•" separator |
| `dsh-emacs-footer-token-face` | Token count |
| `dsh-emacs-footer-cost-face` | Cost |
| `dsh-emacs-footer-ctx-ok-face` | Context < 50% (green) |
| `dsh-emacs-footer-ctx-warn-face` | Context 50-80% (yellow) |
| `dsh-emacs-footer-ctx-crit-face` | Context > 80% (red) |

### Session List
| Face | Description |
|---|---|
| `dsh-emacs-session-title-face` | Session title |
| `dsh-emacs-session-cwd-face` | Working directory |
| `dsh-emacs-session-branch-face` | Git branch |
| `dsh-emacs-session-model-face` | Model name |
| `dsh-emacs-session-id-face` | Session ID |
| `dsh-emacs-session-status-face` | Status indicator |

### Miscellaneous
| Face | Description |
|---|---|
| `dsh-emacs-divider-face` | Divider line |
| `dsh-emacs-timestamp-face` | Timestamp |
| `dsh-emacs-meta-face` | Meta information |
| `dsh-emacs-error-face` | Error message |
| `dsh-emacs-running-face` | Generating status |
| `dsh-emacs-input-box-face` | Input box background |
| `dsh-emacs-input-prompt-face` | Input prompt "❯" |
| `dsh-emacs-accent-face` | Accent color (badges, headings) |

### Markdown Rendering
The Markdown renderer is modeled on `agent-shell-markdown` and uses replacement-style rendering: Markdown marker characters are removed and face properties are kept on the visible text. It supports bold, italic, strikethrough, headings, inline code, code blocks, links, images, horizontal rules, blockquotes, and aligned tables.

| Face | Description |
|---|---|
| `dsh-emacs-markdown-bold` | Bold |
| `dsh-emacs-markdown-italic` | Italic |
| `dsh-emacs-markdown-strikethrough` | Strikethrough |
| `dsh-emacs-markdown-header-1` … `-6` | Heading levels 1 through 6 |
| `dsh-emacs-markdown-inline-code` | Inline code |
| `dsh-emacs-markdown-source-block` | Code block background |
| `dsh-emacs-markdown-link` | Link text |
| `dsh-emacs-markdown-blockquote` | Blockquote |
| `dsh-emacs-markdown-table-header` | Table header |
| `dsh-emacs-markdown-table-border` | Table border |
| `dsh-emacs-markdown-table-zebra` | Table zebra striping |

The legacy `dsh-emacs-markdown-*-face` faces are still kept; the new renderer uses the fine-grained faces above.

Example: customize the tool card colors

```elisp
(custom-set-faces
 '(dsh-emacs-tool-success-face
   ((((background light)) :foreground "#1a7f37" :background "#e6f7ec")
    (((background dark))  :foreground "#5dd879" :background "#172821"))))
```

## How It Works

### RPC API

`dsh-emacs.el` calls the dsh web service's RPC API (`POST /api/session.*`) directly, with no server-side changes required:

| RPC method | Purpose |
|---|---|
| `session.list` | List sessions (including running status, title, cwd) |
| `session.create` | Create a session |
| `session.history` | Read event history (incremental polling rendering) |
| `session.prompt` | Send a message (text and/or inline base64 image attachments) |
| `session.cancel` | Interrupt the running turn (partial reply is kept) |
| `session.fork` | Branch a session into a child inheriting its history |
| `session.models` | List the routable model catalog for a session |
| `session.selectModel` | Switch the session's model |
| `session.rename` | Rename a session |
| `workspace.archiveSession` | Archive a session (remove from its workspace view) |

### Event Rendering Flow

Opening a session first reads `session.history`, then connects to the `/api/events.mux` WebSocket that dsh web uses, receiving new events in real time; only when the WebSocket disconnects or misbehaves does it fall back to `session.history` polling (`dsh-emacs-poll-fallback`, enabled by default):

1. **user/message** → `dsh-emacs-render-user-message`: rendered as a card background
2. **assistant/chunk** → `dsh-emacs-render-assistant-chunk`: the text-delta is appended to the current reply and re-rendered as Markdown in place
3. **assistant/message** → `dsh-emacs-render-assistant-message`: the final snapshot is used to correct the streamed body, avoiding duplicate display
4. **tool/call** → `dsh-emacs-render-tool-call`: rendered as a rounded box (pending state)
5. **tool/result** → `dsh-emacs-render-tool-result`: updates the existing tool card (success/error state)
6. **turn/start** / **turn/end** → `dsh-emacs-render-turn-start/end`: rendered as a divider

When opening history for the first time, old `assistant/chunk` events are skipped and the completed `assistant/message` is used directly; new chunks from live WebSocket events are handled directly. The streamed body uses `agent-shell-markdown`'s watermark/frozen properties so that only the not-yet-stable tail is re-rendered.

**Event-stream reliability**: `dsh-emacs-events.el` declares a file-level `no-native-compile: t` — on this project's emacs-plus@31 build, the network-process filter of native-compiled code is not dispatched continuously (the socket is read at most once, after which data piles up in the receive queue), whereas the byte-compiled filter delivers correctly on all builds, so this module is always loaded as byte code; the filter/sentinel are likewise installed via byte-compiled closures. **Connection health check**: after connecting, a repeating timer checks every 2 seconds whether the handshake has completed; if not, the socket is treated as wedged and killed, and the sentinel reconnects and starts polling. Errors inside the check body are isolated with `condition-case` — if a timer function throws outward, Emacs silently removes the timer, leaving an unrecoverable deadlock where the process stays "open" but nothing ever kills it; this is a pitfall hit in real testing. **Polling is incremental and does not kill itself**: fallback polling fetches only the latest event window (`maxMessages` semantics, about 850 raw events) and renders incrementally anchored on the seq — it no longer parses the whole history each time (full parsing of tens of thousands of events in large sessions was the main source of stutter). **The poll timer stops only when the WS recovers (101 handshake) or disconnects; it never cancels itself just because it saw `turn/end`**: the fetched window frequently ends with the *previous* turn's `turn/end` while the current turn is still in flight; if it canceled itself in that case, replies inside the WS-disconnect window would never be rendered — a 0.4s sampling run caught exactly this bug. After sending a message, a **stream health watchdog** starts: if the event stream delivers nothing for 3 consecutive seconds mid-turn, one windowed history probe is made; if the stream turns out to be stalled, the socket is killed and the sentinel reconnects and takes over polling. **Opening a session does not swallow global replay**: the mux replays the entire global event stream to every new connection (the protocol has no baseline-sync parameter; large sessions can reach 500k+ raw events, still growing each turn). While the initial history is being loaded on first open, the replayed frames arriving on the event stream are dropped outright — not parsed frame by frame, not queued, not sorted (the old "queue → sort → flush" path was exactly why every open froze for seconds); after the history page renders, a small-window **loop backfill** (`dsh-emacs-history-refetch-max-rounds' rounds, anchored incremental rendering until the window stops advancing) covers the load gap, and then real-time resumes. **The open window is bounded**: the history page is fetched per `dsh-emacs-history-window' (default 30 messages), and the GC threshold is raised dynamically (cpu-profiler measurements showed Automatic GC consuming ~46% of the whole open duration when parsing large windows). Measured on a 560k-event session: opening dropped from ~1.8s / two ~0.9s freezes to ~0.55s / two ~0.35s small blocks, independent of session size.

Activity-group logic: 3 or more consecutive tool calls are merged automatically into one activity group showing an aggregate status.

### Chinese Encoding

The dsh service returns UTF-8 JSON. The `url` library inserts the response body as unibyte raw bytes, and `decode-coding-region` is a no-op in unibyte buffers (bytes are kept as-is), so a direct `json-read` would interpret each UTF-8 byte as a Latin-1 character, garbling Chinese text. This package therefore extracts the response body and decodes it with `decode-coding-string` as UTF-8 into a multibyte string, which is then parsed with `json-read-from-string` — Chinese titles, messages, and tool results all display correctly.

## Testing

The repository ships batch tests:

```sh
emacs -Q --batch -l test/dsh-test.el   # ~177 unit tests, no service needed: modules, protocol types, model picker, renderer, footer
emacs -Q --batch -l test/dsh-e2e.el    # E2E against a running dsh service: create session, send message, poll, render
```

## Acknowledgments

The UI design draws on the excellent practices of the following projects:

- [agent-shell](https://github.com/xenodium/agent-shell): Emacs-native coding agent UI with an excellent snippet system and folding mechanism
- [pi-coding-agent](https://github.com/badlogic/pi-mono): modern TUI design, status color system, footer status bar
- [opencode](https://github.com/anomalyco/opencode): clean visual hierarchy, the activity-group concept

## License

[GPL-3.0-or-later](LICENSE) — GNU General Public License v3 or later.