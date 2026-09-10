# Architecture

Module ownership:

```
dsh-emacs/
├── dsh-emacs.el              # Main entry point, RPC client, session management, mode definition
├── dsh-emacs-protocol.el     # Typed views of dsh RPC payloads (cl-defstruct)
├── dsh-emacs-ui.el           # Fragment snapshots, borders, folding, fragment faces
├── dsh-emacs-faces.el        # Shared faces and palette defaults
├── dsh-emacs-tokens.el       # Token tracking and formatting
├── dsh-emacs-markdown.el     # Markdown syntax highlighting
├── dsh-emacs-render.el       # Event renderer (user/assistant/tool/thinking)
├── dsh-emacs-events.el       # Event stream: native WebSocket + reconnect
├── dsh-emacs-modeline.el     # Mode-line stats
├── dsh-emacs-queue.el        # Pending-input queue mirror (queue/steer)
├── dsh-emacs-server.el       # Server bootstrap: probe / auto-start / install / browser-session auth
├── dsh-emacs-command.el      # Host slash commands (commands/list + commands/execute)
├── dsh-emacs-shell.el        # Client-side `!command` shell commands (local execution)
├── dsh-emacs-reference.el    # @ reference completion, chips and navigation
├── dsh-emacs-composer.el     # Composer chrome: Goal and Next Message rows above the input
└── dsh-emacs-session.el      # Session list card view
```

## Transcript fragments (`dsh-emacs-ui.el`)

The renderer supplies a complete alist snapshot: identity, labels, body,
border style, optional whole-block/header faces, and the non-foldable flag.
`dsh-emacs-ui-update-fragment` replaces that snapshot while preserving the
user's fold state. Nil fields clear previous values; this is not a patch API.
It returns the exact `(START . END)` range, excluding surrounding spacing.
An identical snapshot skips rendering when the buffer change tick, measured
width and label separator still match the last successful update. Snapshot
strings are copied so later caller mutation cannot fool this comparison.
Otherwise it renders again; identical rendered text and properties still
return the range without buffer writes or viewport adjustment.
Changed updates preserve the common text prefix and suffix and replace only
the middle span. Native string comparisons locate the suffix without a Lisp
loop over every character or reversed copies of the body. The new state is
applied across the block, but visual properties are written only on differing
runs. Property-only updates do not replace characters. Changed updates still
render and compare the whole card.

Identity is the separate `:namespace-id` / `:block-id` pair, compared with
`equal`; do not join these strings. Lookup and deletion both take two
positional arguments: `(dsh-emacs-ui-find-block namespace-id block-id)` and
`(dsh-emacs-ui-delete-fragment namespace-id block-id)`. Thus `("a-b", "c")`
and `("a", "b-c")` identify different cards. Navigation and bulk folding
walk local property boundaries without repeated identity searches.
See [decision record 024](../postmortem/024-fragment-identity-and-local-navigation.md).

Identity lookup caches a start marker and its state object per buffer.
Successful insertion, update and folding refresh the cache; deletion releases
the entry. Each hit verifies the marker against the actual state property.
Misses and stale entries use property search, retaining the last matching
block rule for duplicate identities. Erase and undo invalidate the index;
narrowed operations bypass it so a restricted lookup cannot poison the full
buffer's ordering. Cache entries are published after atomic edits succeed.
See [decision record 026](../postmortem/026-fragment-performance-cache.md)
for lifecycle constraints and measured results.

One renderer builds the complete text and its `dsh-emacs-ui-state` property
before the buffer is edited. Updates and fold changes both use it and replace
text inside `atomic-change-group`; rendering or insertion errors propagate
while preserving the previous card. Minimal blocks need no special
body-range editing path. The stored snapshot includes labels and
faces as well as the full body; fold/unfold preserves embedded links, icon
faces and body styling. `:status` is opaque renderer metadata and does not
apply colors. Renderers choose concrete `:face` / `:header-face` values;
the UI merges those after embedded faces on every redraw. Bash terminal
cards use a header face while retaining their own body faces.

Each render measures the displaying window once and shares that body width
between the header, body and footer. Titles take priority over summaries;
bordered rows add four framing columns. Headers retain embedded keymaps,
local maps and button actions; only otherwise passive text gets the fold map.
Long body lines remain intact. Width is recomputed on update/fold, not through
a resize hook. See [decision record 023](../postmortem/023-fragment-layout-and-atomic-updates.md).

The UI does not interpret message kinds. Renderers can mark text with
`dsh-emacs-ui-space-after` to request blank lines after it; user messages
request one. Fragment lookup/navigation use the contiguous state property.
There is no group hierarchy or append/header-only mutation API. Streaming
assistant text remains owned by the renderer's existing stream path.
See [decision record 022](../postmortem/022-fragment-snapshots.md).

## Composer (`dsh-emacs-composer.el`)

The bottom of a chat buffer is a **Composer**: a persistent, non-transcript UI
region with optional read-only **Goal Row** and **Next Message** rows, in that
order, above the editable **Input Area**. The input geometry (the `❯ ` prompt,
`dsh-emacs--input-marker` /
`dsh-emacs--input-end`, cursor clamps, delete guards) is owned by
`dsh-emacs.el`; `dsh-emacs-composer.el` owns both chrome rows and the seam
that keeps streamed transcript above them. The queue module supplies the
visible next item directly from its mirror; Composer keeps no second queue.

The Goal Row shows the session's current goal as one read-only line (a leading
dartboard goal SVG icon mirroring dsh web — the `◎ ` text is a fallback when
Emacs lacks SVG support — followed by objective + phase, and trailing
dsh-web pause/resume/edit/clear **SVG** action icons, unicode glyphs when SVG
is unavailable) only when a goal exists, fed **passively** from the server
`goal` session projection (`rpc.md §9`): `session/control` projection frames
and the `session/follow` snapshot route to the session's live chat buffer. It
is composer chrome, never a `user/message` and never sent to the model.

The goal **actions** (pause/resume/edit/clear) are `goals.*` RPCs
(`rpc.md §4.10`) issued on the current goal's CAS `ref` `{id, revision}`:
`dsh-emacs-goal-pause|resume|edit|clear` commands under a `C-c C-g` prefix
keymap, and each action glyph on the row binds RET/mouse-1 to the same
command via a text-region keymap.  A pending request token guards against a
second mutation mid-flight; a successful verb optimistically re-renders the row from
the returned view only while its request token and CAS ref remain current (a
clear removes it), so an already-newer projection always wins.  Failures
surface via `message` and leave the row unchanged (see postmortem/018).

`C-c C-g ?` (`dsh-emacs-goal-describe`) opens a read-only help buffer with
the full objective, phase and blocked reason. The objective's tooltip also
exposes the full text and reason. Editing starts from the original objective,
preserving embedded line breaks; display folding is confined to the row.
While an action is pending, its progress label replaces the phase and inline
actions are hidden. Narrow windows drop actions before sacrificing objective
space, then prioritize status when even the fixed chrome cannot fit. SVGs
reserve two columns and are capped to fit the narrowest viewing frame's cells.
Goal projection and RPC response decoding both belong to the protocol module;
Composer's mutation callback compares parsed goal identities and revisions.

Next Message displays an SVG clock followed by the preview, or `Next: …` as
a text fallback, folding line breaks and truncating to the window width. Hover
for the full text and use `C-c C-q` to manage the queue. Either row may appear
independently; clearing a goal leaves pending input visible, and clearing the
queue leaves the goal.

Geometry: `dsh-emacs--composer-top-marker` and
`dsh-emacs--composer-end-marker` delimit the complete read-only chrome region,
including row newlines. The top marker has insertion type `t`, so transcript
inserts through `dsh-emacs-render--input-insert-point` leave it attached to the
rows. The end marker has insertion type `nil` and stops before the `❯ ` line.
Composer replaces only its tagged region, preserving the draft and cursor,
and releases both markers when no rows remain. A content/layout signature
avoids rewriting unchanged rows; resize reflows Next Message even without a
goal. The input prompt remains a plain `❯ ` run, with no queue-prefix scanning
or text matching needed to remove stale previews.

## Shell commands (`dsh-emacs-shell.el`)

`!<command>` inputs without attachments are **client-side** commands:
`dsh-emacs-send-or-stop` routes them before server and busy checks, and
`dsh-emacs--submit-prompt`
also intercepts them before deferred or slash-command routing. Both use
`dsh-emacs-shell-submit` / `dsh-emacs-shell-run`, which preserve multiline
commands and spawn Emacs's `shell-file-name` with `-c`
asynchronously (`make-process`) with the chat buffer's `default-directory` —
the session workspace — as working directory.  The result row is rendered by
`dsh-emacs-render-shell-start` / `dsh-emacs-render-shell-done` in
`dsh-emacs-render.el`, reusing the slash-command row machinery (bash icon,
`-\|/` spinner, pending tint, success/error restyle): a `!` row rides the
same `dsh-emacs--command-blocks` / spinner tables under its own monotonic
`shell-N` id.  Process tracking is buffer-local (`dsh-emacs--shell-procs`).
Killing the chat buffer or resetting its major mode kills the tracked shell
before its tracking is discarded. `C-c C-!`
(`dsh-emacs-shell-process-kill`) interrupts a running one, rendered as
failed.  Because the chat has no terminal, `!` commands receive EOF through
`process-send-eof` (`dsh-emacs-shell-null-stdin`). This supplies EOF to stdin
readers but does not guarantee TUI termination; vim may continue running.
Submitting a new `!` command stops the previous tracked shell, and the opt-in
`dsh-emacs-shell-timeout` kills a tracked shell that outlives its limit.
Only exit or signal termination finalizes a row; stop/continue notifications
retain process tracking, captured output, and the timeout. Terminal processes
release their output buffers and timers even if the chat buffer is already
dead. Timeout settings are validated before either submission entry mutates
input or process state: only nil or positive integer seconds are accepted.
The process uses a pipe connection; closing its input leaves the original
command unchanged for `shell-file-name -c`, including with non-POSIX shells.
The executable follows the Emacs variable, not a fresh lookup of `$SHELL`.
When a shell exits, its tracking entry is removed; background children that
outlive it are not tracked or cleaned up by later buffer teardown or timeout.
Shell rows are also absent from server history, so a full transcript reload
discards them; reopening the session does not restore their output.
`!` never touches `session/prompt` or `commands.execute` and does
not depend on the server or the session's busy state — the model keeps
running while the local command executes. With attachments, a leading `!`
is ordinary caption text; the normal prompt path retains the images.
Output is capped by `dsh-emacs-shell-max-output`;
`dsh-emacs-shell-require-confirm` optionally
gates each run behind `y-or-n-p` (see docs/shell-commands.md).

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
- `goal` session projection (§9) → `dsh-protocol-goal` (id, revision,
  objective, phase, blocked-reason, max-goal-rounds, rounds-started)

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
the Composer Next Message row, and the `C-c C-q` manager.
`dsh-emacs-queue-next-item` determines the visible next message from delivery
order and the transient gate: steering (next-step) takes priority over queued
(next-turn). Composer owns its clock icon, width fitting and buffer geometry.
Our steer/delete/edit RPCs still update the mirror optimistically on success,
so Composer and the mode-line refresh immediately. Queue-triggered repaints
are coalesced per frame burst with the existing zero-delay timer, preserving
transient suppression. The manager's minibuffer keys `e`/`s`/`d`/`RET` act on the
highlighted item; `x` deletes the whole queue. `context`
items (host-injected next-step content) are mirrored but never counted,
previewed, or listed; `steering` items count and list, and — as the
next thing the host injects — head the preview.

The echo feedback is silenced for the client's OWN empty-queue submit:
the wire accepts only `queue`/`steer` prompt modes, so every send —
idle, or queued behind a running turn with nothing else pending — is
appended to the inbox and claimed when the turn starts, two
`session/queue` frames within milliseconds.  With an empty mirror those
frames carry no ordering information, so the transient splice/claim
gets no `queued:` / `running:` echo and no Next Message preview paint
(the row would otherwise flash as the item is inserted and claimed) — `dsh-emacs-queue--mark-submit-suppress`
arms `dsh-emacs--queue-submit-suppress` when the mirror is empty at
submit time, on both the plain and the deferred path; it clears when
the mirror settles back to empty, in the submit failure branch, or by
a transport-hygiene timer (a dead transport would otherwise leave the
echo gate stuck until the next submit — the timer paces no preview).
The Next Message preview is gated by the same flag, with one
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
2. **assistant/chunk** → `dsh-emacs-render-assistant-chunk`: the first text chunk appears immediately; subsequent insertion, Markdown and viewport following coalesce on a 50ms one-shot timer. Event boundaries, finalization, stream changes and disconnect flush pending text.
3. **assistant/message** → `dsh-emacs-render-assistant-message`: the final snapshot is used to correct the streamed body, avoiding duplicate display
4. **tool/call** → `dsh-emacs-render-tool-call`: rendered as a rounded box (pending state)
5. **tool/result** → `dsh-emacs-render-tool-result`: updates the existing tool card (success/error state)
6. **turn/start** / **turn/end** → `dsh-emacs-render-turn-start/end`: rendered as a divider

The follow snapshot is the opening history tail: `chunks` packed rows are
skipped and only message-aligned `event` records seed the buffer, so old
`assistant/chunk` deltas are not replayed and the completed
`assistant/message` is used directly; new chunks from live follow events
are handled directly. The streamed body uses
a render watermark and frozen properties so that only the not-yet-stable tail is
re-rendered and styled. The assistant stream creates and retains its Markdown
scan state from the outset, so successive flushes scan only new complete
lines of unfinished blocks. Its render watermark is a non-advancing marker
owned by that state, avoiding property writes to the first character of an
otherwise stable reply. Empty ready ranges bypass Markdown passes. Force
replacement resets the watermark; finalization detaches it after the final
formatting attempt. Queued replies retain their body markers until publication
or cancellation. Non-stream Markdown conversions keep their serializable watermark
property. Raw deltas are retained as a list and joined once
for comparison with the final message; a second list references only unpainted
deltas, which are inserted together before formatting. An unchanged final
message keeps the painted body. See [decision record 029](../postmortem/029-stream-write-batching.md).
The WebSocket decoder walks each input batch by byte offset,
retains its incomplete tail once, and joins message fragments only at FIN.
Viewport bottom detection uses `vertical-motion` with each destination
window, so wrapped lines count as screen rows.
Stream insertion, timer flushes and corrected final replies capture the
following window list immediately before editing, then pin that list after
formatting. This avoids mistaking a large insertion for a manual scroll;
there is no saved follow state between callbacks. Per-event calls still skip
pending batches. The selected draft point and excluded reading windows remain
untouched. Hidden buffers skip prompt lookup for following altogether.
The selected reading window is excluded before any screen-row measurement.
Pinning uses `recenter -1` in the destination window, targeting the selected
draft point or the inactive window's input anchor. Counting backwards by
`window-text-height` overestimates capacity with extra line spacing or larger
faces; the resulting offscreen cursor made Emacs scroll back on every redraw.
The transcript's after-change hook uses `restore-buffer-modified-p` so text
and property edits do not repeatedly invalidate the mode line. The animation
advances during pending text batches without forcing a separate redraw.
Quiet visible turns still refresh the indicator on its normal timer.

After a ready chat socket delivers input, the events module suspends further
reads for 50ms with `set-process-filter` set to t. Bytes remain in the socket;
each received batch still parses and dispatches synchronously in order. A
one-shot timer restores the filter saved when reads paused. Disconnect and
connection loss cancel that process-owned timer and clear the saved filter;
a quiet socket has no polling timer. Handshakes and the host question/approval
channel bypass this pacing.
This bounds process-triggered redraws that downstream text batching cannot
prevent, adding up to about 50ms of receive latency during bursts. See
[037](../postmortem/037-streaming-display-cpu.md).
See [decision record 031](../postmortem/031-stream-frontier-and-screen-rows.md)
and [032](../postmortem/032-partial-line-styling-and-burst-follow.md), and the
[performance audit](streaming-performance.md).

Partial-line emphasis passes narrow to the first delimiter plus its preceding
character, preserving the existing whitespace/line-start grammar. Other
Markdown passes retain the full ready range. The renderer supplies its assistant
base face to Markdown's final face pass, which keeps one copy at the lowest
priority and mirrors the complete result to `font-lock-face` in one traversal.
The renderer
then applies read-only, stickiness and event identity properties together.
Repeated tail formatting cannot grow the face list. A stable named yank handler
keeps repeated formatting from rewriting an otherwise identical property.
See [033](../postmortem/033-final-face-pass-and-pixel-probes.md).

Table width measurement belongs to Markdown. On Emacs 31 it uses the public
`string-pixel-width` buffer argument and selects the destination window during
measurement to preserve frame/font context without editing chat text.
Older versions measure in a temporary buffer with the destination's font
settings: Emacs 29–30 use `buffer-text-pixel-size`, while Emacs 27–28 briefly
display the probe under a saved window configuration. Every path measures
beyond the window width without changing the chat buffer's edit counter. See
[034](../postmortem/034-full-table-pixel-widths.md).

Font measurements are shared through one dynamically bound, render-scoped
plist. Space widths, face ratios and character-height scales cannot outlive
the table render. Height probes copy the destination's face remapping and
default properties, using `buffer-text-pixel-size` where available (Emacs 29+)
or a saved window configuration on older versions. See
[035](../postmortem/035-table-render-metrics.md).

The renderer owns the idle queue for expensive assistant Markdown, including
history messages. Pending regions above `dsh-emacs-stream-markdown-limit`
(8192 by default) wait for an idle attempt; oversized partial lines first wait
for a newline or finalization. Ready-region detection still belongs to
Markdown. A callback prepares one reply in a temporary buffer under
`while-no-input`. A one-shot 100ms clock timer checks current idleness before
each attempt, avoiding immediate re-firing of an elapsed idle deadline.
It commits only a complete result whose source character
tick is unchanged, and recomputes following windows just before publication.

Queued body markers exclude adjoining messages; the owning edit restores its
explicit bounds after changes. `replace-region-contents` preserves positions
in matching text with a 10ms comparison limit, then the renderer installs the
prepared properties. The diff receives plain characters, avoiding a reproduced
Emacs 31 coding-buffer failure with protected strings. Reset, buffer death and
major-mode changes cancel jobs and release their markers. Teardown hooks
disconnect and flush pending text before releasing those markers. Errors at
this idle callback boundary are reported while leaving the raw reply visible. This uses
the main Emacs thread and standard idle/input machinery, not a worker thread
or an alternate parser. See [036](../postmortem/036-bounded-stream-markdown.md).

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
- **Stream health watchdog**: while a turn runs, three seconds without
  business events triggers a WebSocket ping. A matching pong clears the
  probe; only a probe unanswered for more than three seconds kills the
  socket. Long model/tool waits therefore do not force reconnects on a
  responsive connection. Reconnect snapshots remain anchor-gated catch-up;
  there is no history-probe RPC. This tests transport responsiveness, not
  whether the server's logical follow stream is making progress.
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

Tool cards currently render and fold independently. The renderer retains
legacy group counters and `dsh-emacs-group-consecutive-tools`, but does not
create group headers or attach child fragments. The UI has no group API;
these renderer remnants are recorded as follow-up debt in decision 022.

## Chinese encoding

The dsh service returns UTF-8 JSON. The `url` library inserts the response body
as unibyte raw bytes, and `decode-coding-region` is a no-op in unibyte buffers
(bytes are kept as-is), so a direct `json-read` would interpret each UTF-8 byte
as a Latin-1 character, garbling Chinese text. This package therefore extracts
the response body and decodes it with `decode-coding-string` as UTF-8 into a
multibyte string, which is then parsed with `json-read-from-string` — Chinese
titles, messages, and tool results all display correctly.

### Live thinking refresh

The renderer inserts the first reasoning delta immediately, then queues raw
strings in reverse order on the live thinking state. One buffer-owned 100ms
one-shot timer joins and inserts the pending burst, clears the queue and
follows the viewport once. Per-event follow calls skip a pending burst.
Non-reasoning events, step changes and stream teardown flush pending text
before continuing. This keeps transport delivery immediate while limiting
reasoning-driven buffer invalidation. See [027](../postmortem/027-thinking-refresh.md).
