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
├── dsh-emacs-server.el       # Server bootstrap: probe / auto-start / install / browser-session auth
└── dsh-emacs-session.el      # Session list card view
```

## Protocol layer (`dsh-emacs-protocol.el`)

dsh server responses arrive as decoded JSON alists (arrays as vectors). Their
common shapes are normalized into `cl-defstruct` types here, and business code
reads fields exclusively through generated accessors (e.g.
`dsh-protocol-model-selection-reasoning-effort`, `dsh-protocol-session-cwd`):
each wire field name appears only in the matching `--from-alist` constructor, so
when the server protocol changes you sync exactly one file. Covered payloads:

- `session/list` → `dsh-protocol-session` (sessionId, title, cwd, agentPreset,
  updatedAt, blank, running, title-value, pending-interaction, context-pressure,
  context-window, context-projected)
- `workspace/follow` baseline → `dsh-protocol-workspace-list` (items,
  archived-session-ids) → `dsh-protocol-workspace` (workspaceId, sessionIds,
  title, path, createdAt, updatedAt)
- `workspace/create` / `rename` / `delete` / `insertBefore` →
  `dsh-protocol-workspace-result` (workspace, created)
- `session/modelCatalog` → `dsh-protocol-model-directory` → `provider-group` →
  `model-catalog-entry` → `reasoning` → `effort`, plus
  `dsh-protocol-model-selection` for `current`
- `session/selectModel` → `dsh-protocol-model-selection-result` (selected)
- `agentPresets/list` → `dsh-protocol-agent-preset-list` (presets, authorable,
  has-document) → `dsh-protocol-agent-preset` (id, trust, is-default, name,
  description, broken)

Conversion is one-way and lossless: `session/modelCatalog` responses become a
`dsh-protocol-model-directory` before the picker reads them; the cached
session/workspace lists are stored as structs too. Helper `dsh-protocol--struct`
accepts either a wire alist or an already-converted struct, so callers and
fixtures can stay on either side of the boundary. Event-stream payloads stay raw
for now (their shapes vary per event type).

## RPC API

`dsh-emacs.el` calls the dsh service's one-shot unary RPC API
(`POST /api/<namespace>/<method>`, e.g. `/api/session/list`) directly, with
no server-side changes required.  Endpoint names are the two-segment
slash form of the dsh 0.1.2 wire protocol (rpc.md §4); the request body
is the `client-request` envelope with `payload = {args: {...}}`:

| RPC method | Purpose |
|---|---|
| `session/list` | List sessions (including running status, title, cwd) |
| `session/create` | Create a session |
| `session/prompt` | Send a message (`mode: "queue"` = next turn, `"steer"` = wake the running agent; text and/or inline base64 image attachments; `requestId` dedups resends) |
| `session/updateQueue` | Manage pending inbox items (`edit` text / `remove` / `steer` by itemId) |
| `session/cancel` | Interrupt the running turn (partial reply is kept, inbox preserved) |
| `session/fork` | Branch a session into a child inheriting its history |
| `session/modelCatalog` | List the routable model catalog for a session |
| `session/selectModel` | Switch the session's model |
| `session/rename` | Rename a session (its display title) |
| `session/attachment` | Fetch a stored image attachment (ref + base64 data) |
| `workspace/create` / `rename` / `delete` / `insertBefore` / `archiveSession` | Mutate a workspace or a session's workspace membership |
| `agentPresets/list` | List agent presets |
| `commands/list` / `commands/execute` | List / run slash commands |
| `$events/result` | Answer a `$events` waterfall (approval/question), args `{clientId, eventId, outcome}` |

Real-time state — the transcript, the session list, queue/steer mirrors,
projections, and the approval/question waterfalls — is NOT polled; it
arrives over `/api/remote.mux` logical streams (next section).

## Pending-input queue (`session/queue` frames on `session/control`)

Input sent while a turn runs is delivered through the agent inbox:
`queue` lands in next-turn (the next turn), `steer` in next-step (before
the running agent's next step).  The host publishes the authoritative
snapshot as `session/queue` frames on the core connection's
`session/control` logical stream — once per connection (the baseline) for
sessions with pending items, and on every inbox splice thereafter — so
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

The echo feedback is silenced for the client's OWN empty-queue submit:
the wire accepts only `queue`/`steer` prompt modes, so every send —
idle, or queued behind a running turn with nothing else pending — is
appended to the inbox and claimed when the turn starts, two
`session/queue` frames within milliseconds.  With an empty mirror those
frames carry no ordering information, so the transient splice/claim
gets no `queued:` / `running:` echo and no `[next: …]` preview paint
(the preview would otherwise flash the input line: inserted on the
splice-in frame, removed on the claim) — `dsh-emacs-queue--mark-submit-suppress`
arms `dsh-emacs--queue-submit-suppress` when the mirror is empty at
submit time, on both the plain and the deferred path; it clears when
the mirror settles back to empty, in the submit failure branch, or by
a transport-hygiene timer (a dead transport would otherwise leave the
echo gate stuck until the next submit — the timer paces no preview).
The `[next: …]` preview is gated by the same flag, with one
event-driven escape: while a turn is running (`dsh-emacs--busy-p`,
buffer-local) the preview shows regardless, because an item mirrored
then can only be claimed at the turn end and is genuinely parked —
this is what reveals a queued message immediately, with no timing
window.  Genuine queueing — items already parked — keeps its feedback,
its preview, and its mode-line count.
This is the queue-frame complement of the anchor-gated replay dedup
(rationale: postmortem/004): transcript frames are idempotent by seq,
queue frames by submit context.

## Event rendering flow

dsh web multiplexes all logical Remote streams over one long-lived
WebSocket, `/api/remote.mux`.  A chat buffer opens a `session/follow`
stream whose opening `snapshot` seeds the transcript and whose `event`
items render live; the follow stream is the only automatic reply channel
for a chat — when it drops, the health-check / watchdog / reconnect
machinery below restores it, and until then replies appear only via manual
refresh (`C-c C-r`):

1. **user/message** → `dsh-emacs-render-user-message`: rendered as a card background
2. **assistant/chunk** → `dsh-emacs-render-assistant-chunk`: the text-delta is appended to the current reply and re-rendered as Markdown in place
3. **assistant/message** → `dsh-emacs-render-assistant-message`: the final snapshot is used to correct the streamed body, avoiding duplicate display
4. **tool/call** → `dsh-emacs-render-tool-call`: rendered as a rounded box (pending state)
5. **tool/result** → `dsh-emacs-render-tool-result`: updates the existing tool card (success/error state)
6. **turn/start** / **turn/end** → `dsh-emacs-render-turn-start/end`: rendered as a divider

The follow snapshot is the opening history tail: `chunks` packed rows are
skipped and only message-aligned `event` records seed the buffer, so old
`assistant/chunk` deltas are not replayed and the completed
`assistant/message` is used directly; new chunks from live follow events
are handled directly. The streamed body uses
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
- **Snapshot-first rendering**: opening a session opens a `session/follow`
  stream whose `snapshot` seeds the transcript.  The snapshot carries a
  `cursor` plus message-aligned `records` (a bounded tail — the client requests
  up to `dsh-emacs-history-window` messages via `maxMessages`).  Rendering
  parses only the snapshot records and live `event` frames, never the whole
  session history, so opening is cheap even for very large sessions.
- **Reconnect is self-healing**: the reconnect socket pins `no-conversion` — on
  a reused events buffer the re-inferred process coding system folds the 101
  response's `\r\n\r\n` to `\n\n`, so the handshake never matched and the
  health check killed the socket in a 2s reconnect loop, leaving that session
  silently deaf while other sessions' sockets kept rendering (reproduced live
  against a real server).  A synchronous connect error (unresolvable host,
  malformed `dsh-emacs-base-url`) is contained: the reconnect is re-armed and
  another connect scheduled, instead of a timer-error leaving the chat with no
  recovery channel.  Reconnecting re-opens the `session/follow` stream, and the
  fresh snapshot reseeds whatever was missed.
- **Replayed frames never render twice**: on a mid-session reconnect the fresh
  follow snapshot re-sends the transcript tail; the dispatch path
  (`dsh-emacs-events--dispatch-event`) gates every transcript frame on
  `dsh-emacs--anchor-seq` — the newest seq this buffer rendered or consumed —
  and drops frames whose seq is not newer, the same gate
  `dsh-emacs-render-history-events` applies to re-fetch windows.  The follow
  snapshot advances the anchor to its `cursor`, so replaying the same tail
  renders nothing; events generated during the outage carry seq > anchor and
  render once as the catch-up.  Without the gate a reconnect repainted the
  whole transcript a second time (doubled user messages and assistant replies,
  interleaved layout, only fixed by reopening the session).
- **Stream health watchdog**: after sending a message, if the event stream
  delivers nothing for 3 consecutive seconds mid-turn, the socket is killed so
  the sentinel reconnects; the fresh follow snapshot then reseeds whatever was
  missed (records carry original seqs, the anchor gate renders only the new
  tail) — no history-probe RPC is needed anymore.
- **The open window is bounded**: the snapshot is requested with
  `dsh-emacs-history-window` (default 30 messages), and the GC threshold is
  raised dynamically (cpu-profiler measurements showed Automatic GC consuming
  ~46% of the whole open duration when parsing large windows). Measured on a
  560k-event session: opening dropped from ~1.8s / two ~0.9s freezes to ~0.55s /
  two ~0.35s small blocks, independent of session size.
- **Core connection (list side)**: the session list keeps a separate
  `/api/remote.mux` connection that opens `session/control` + `workspace/follow`
  + `$events`.  `session/control` delivers whole-host queue/jobs/projection
  baselines and increments; `workspace/follow` seeds and then upserts/removes/
  reorders the workspace caches; `$events` carries the session list's live
  changes (`api-session/added|removed|status|activity` emits) and the
  approval/question waterfalls.  This connection is scoped to the list buffer's
  lifecycle and is also self-healing (reconnect + re-baseline).

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