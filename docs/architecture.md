# Architecture

`dsh-emacs` is a modular design that is easy to maintain and extend:

```
dsh-emacs/
├── dsh-emacs.el              # Main entry point, RPC client, session management, mode definition
├── dsh-emacs-protocol.el     # Typed views of dsh RPC payloads (cl-defstruct)
├── dsh-emacs-ui.el           # UI framework (rounded borders, collapsing, fragment management)
├── dsh-emacs-faces.el        # Unified face definitions and theme variables
├── dsh-emacs-tokens.el       # Token tracking and formatting
├── dsh-emacs-markdown.el     # Markdown syntax highlighting
├── dsh-emacs-render.el       # Event renderer (user/assistant/tool/thinking)
├── dsh-emacs-events.el       # Event stream: native WebSocket + reconnect
├── dsh-emacs-modeline.el       # Mode-line stats
├── dsh-emacs-queue.el        # Pending-input queue mirror (queue/steer)
├── dsh-emacs-server.el       # Server bootstrap: probe / auto-start / install
└── dsh-emacs-session.el      # Session list card view
```

## Protocol layer (`dsh-emacs-protocol.el`)

dsh server responses arrive as decoded JSON alists (arrays as vectors). Their
common shapes are normalized into `cl-defstruct` types here, and business code
reads fields exclusively through generated accessors (e.g.
`dsh-protocol-model-selection-reasoning-effort`, `dsh-protocol-session-cwd`):
each wire field name appears only in the matching `--from-alist` constructor, so
when the server protocol changes you sync exactly one file. Covered payloads:

- `session.list` → `dsh-protocol-session` (sessionId, title, cwd, agentPreset,
  updatedAt, blank, running, title-value, pending-interaction, context-pressure,
  context-window, context-projected)
- `workspace.list` → `dsh-protocol-workspace-list` (items, archived-session-ids)
  → `dsh-protocol-workspace` (workspaceId, sessionIds, title, path, createdAt,
  updatedAt)
- `workspace.create` / `rename` / `insertSessionBefore` →
  `dsh-protocol-workspace-result` (workspace, created)
- `session.models` → `dsh-protocol-model-directory` → `provider-group` →
  `model-catalog-entry` → `reasoning` → `effort`, plus
  `dsh-protocol-model-selection` for `current`
- `session.selectModel` → `dsh-protocol-model-selection-result` (selected)
- `agentPreset.list` → `dsh-protocol-agent-preset-list` (presets, authorable,
  has-document) → `dsh-protocol-agent-preset` (id, trust, is-default, name,
  description, broken)

Conversion is one-way and lossless: `session.models` responses become a
`dsh-protocol-model-directory` before the picker reads them; the cached
session/workspace lists are stored as structs too. Helper `dsh-protocol--struct`
accepts either a wire alist or an already-converted struct, so callers and
fixtures can stay on either side of the boundary. Event-stream payloads stay raw
for now (their shapes vary per event type).

## RPC API

`dsh-emacs.el` calls the dsh web service's RPC API (`POST /api/session.*`)
directly, with no server-side changes required:

| RPC method | Purpose |
|---|---|
| `session.list` | List sessions (including running status, title, cwd) |
| `session.create` | Create a session |
| `session.history` | Read event history (incremental, anchor-diffed rendering) |
| `session.prompt` | Send a message (`mode: "queue"` = next turn, `"steer"` = wake the running agent; text and/or inline base64 image attachments) |
| `session.updateQueue` | Manage pending inbox items (`edit` text / `remove` / `steer` by itemId) |
| `session.cancel` | Interrupt the running turn (partial reply is kept, inbox preserved) |
| `session.fork` | Branch a session into a child inheriting its history |
| `session.models` | List the routable model catalog for a session |
| `session.selectModel` | Switch the session's model |
| `session.rename` | Rename a session |
| `workspace.archiveSession` | Archive a session (remove from its workspace view) |

## Pending-input queue (`session/queue` frames)

Input sent while a turn runs is delivered through the agent inbox:
`queue` lands in next-turn (the next turn), `steer` in next-step (before
the running agent's next step).  The host pushes the authoritative
snapshot as `session/queue` mux frames — once per connection for sessions
with pending items, and on every inbox splice thereafter — so
`dsh-emacs-queue.el` only mirrors frames (no fetch RPC, no local drift).
The wire item shape (`id`, `placement` = `queued`/`steering`/`context`,
`message.content`) is normalized to `dsh-protocol-queue-item` in
`dsh-emacs-protocol.el`.  The mirror drives the mode-line `[Qn Sm]`
indicator, the echo-area feedback (enqueue / steer / consumption,
diffed against the previous mirror, with locally-deleted ids suppressed),
the input-prompt prefix — a small clock icon (SVG `currentColor`
mapped to the prompt face's foreground, `[next: …] ` brackets as
fallback when Emacs lacks SVG support) followed by the next message
the host will send: the preview follows the host's delivery order, so
an item steered into the running turn (`steering`, next-step, injected
at the agent's next step) leads it ahead of items queued for the next
turn (`queued`, next-turn); our own steer/delete/edit RPCs update the
mirror optimistically on
success, so the hint and mode-line refresh immediately without waiting
for the confirming frame; prefix repaints are coalesced per frame burst
(one zero-delay timer paints the settled mirror), so an item the host
splices and instantly claims never flashes the hint),
and the `C-c C-q` manager (a
minibuffer candidate list whose single keys `e`/`s`/`d`/`RET` act on the
highlighted item; `x` deletes the whole queue).  `context`
items (host-injected next-step content) are mirrored but never counted,
previewed, or listed; `steering` items count and list, and — as the
next thing the host injects — head the preview.

## Event rendering flow

Opening a session first reads `session.history`, then connects to the
`/api/events.mux` WebSocket that dsh web uses, receiving new events in real
time; the mux stream is the only automatic reply channel — when it drops,
the health-check / watchdog / reconnect machinery below restores it, and
until then replies appear only via manual refresh (`C-c C-r`):

1. **user/message** → `dsh-emacs-render-user-message`: rendered as a card background
2. **assistant/chunk** → `dsh-emacs-render-assistant-chunk`: the text-delta is appended to the current reply and re-rendered as Markdown in place
3. **assistant/message** → `dsh-emacs-render-assistant-message`: the final snapshot is used to correct the streamed body, avoiding duplicate display
4. **tool/call** → `dsh-emacs-render-tool-call`: rendered as a rounded box (pending state)
5. **tool/result** → `dsh-emacs-render-tool-result`: updates the existing tool card (success/error state)
6. **turn/start** / **turn/end** → `dsh-emacs-render-turn-start/end`: rendered as a divider

When opening history for the first time, old `assistant/chunk` events are
skipped and the completed `assistant/message` is used directly; new chunks from
live WebSocket events are handled directly. The streamed body uses
`agent-shell-markdown`'s watermark/frozen properties so that only the
not-yet-stable tail is re-rendered.

## Event-stream reliability

- **No native compile**: `dsh-emacs-events.el` declares a file-level
  `no-native-compile: t` — on the project's emacs-plus@31 build the
  network-process filter of native-compiled code is not dispatched continuously
  (the socket is read at most once, after which data piles up in the receive
  queue), whereas the byte-compiled filter delivers correctly on all builds, so
  this module is always loaded as byte code; the filter/sentinel are likewise
  installed via byte-compiled closures.
- **Connection health check**: after connecting, a repeating timer checks every
  2 seconds whether the handshake has completed; if not, the socket is treated
  as wedged and killed, and the sentinel reconnects.  Errors
  inside the check body are isolated with `condition-case` — if a timer function
  throws outward, Emacs silently removes the timer, leaving an unrecoverable
  deadlock where the process stays "open" but nothing ever kills it; this is a
  pitfall hit in real testing.
- **Incremental history rendering**: history is fetched with the
  `maxMessages` semantics (about 850 raw events for the default window) and
  rendered incrementally anchored on the seq — it never parses the whole
  history each time (full parsing of tens of thousands of events in large
  sessions was the main source of stutter).  The same anchored diff also makes
  the watchdog's periodic `session.history` probe harmless to re-render.
- **Reconnect is self-healing**: the reconnect socket pins `no-conversion` — on
  a reused events buffer the re-inferred process coding system folds the 101
  response's `\r\n\r\n` to `\n\n`, so the handshake never matched and the
  health check killed the socket in a 2s reconnect loop, leaving that session
  silently deaf while other sessions' sockets kept rendering (reproduced live
  against a real server).  A synchronous connect error (unresolvable host,
  malformed `dsh-emacs-base-url`) is contained: the reconnect is re-armed and
  another connect scheduled, instead of a timer-error leaving the chat with no
  recovery channel.
- **Stream health watchdog**: after sending a message, if the event stream
  delivers nothing for 3 consecutive seconds mid-turn, one windowed history
  probe is made; if the stream turns out to be stalled, the socket is killed and
  the sentinel reconnects.
- **Opening a session does not swallow global replay**: the mux replays the
  entire global event stream to every new connection (the protocol has no
  baseline-sync parameter; large sessions can reach 500k+ raw events, still
  growing each turn). While the initial history is being loaded on first open,
  the replayed frames arriving on the event stream are dropped outright — not
  parsed frame by frame, not queued, not sorted (the old "queue → sort → flush"
  path was exactly why every open froze for seconds); after the history page
  renders, a small-window **loop backfill** (`dsh-emacs-history-refetch-max-rounds`
  rounds, anchored incremental rendering until the window stops advancing)
  covers the load gap, and then real-time resumes.
- **The open window is bounded**: the history page is fetched per
  `dsh-emacs-history-window` (default 30 messages), and the GC threshold is
  raised dynamically (cpu-profiler measurements showed Automatic GC consuming
  ~46% of the whole open duration when parsing large windows). Measured on a
  560k-event session: opening dropped from ~1.8s / two ~0.9s freezes to ~0.55s /
  two ~0.35s small blocks, independent of session size.

## Activity groups

3 or more consecutive tool calls are merged automatically into one activity
group showing an aggregate status (e.g. "2 of 3 completed").

## Chinese encoding

The dsh service returns UTF-8 JSON. The `url` library inserts the response body
as unibyte raw bytes, and `decode-coding-region` is a no-op in unibyte buffers
(bytes are kept as-is), so a direct `json-read` would interpret each UTF-8 byte
as a Latin-1 character, garbling Chinese text. This package therefore extracts
the response body and decodes it with `decode-coding-string` as UTF-8 into a
multibyte string, which is then parsed with `json-read-from-string` — Chinese
titles, messages, and tool results all display correctly.