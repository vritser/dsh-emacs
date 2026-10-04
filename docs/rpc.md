# dsh RPC Protocol Reference (dsh 0.2.0-rc.2, master baseline)

This document is the complete reference for the public protocol of the dsh
(DeepSeek Harness) Web service, for maintaining the existing dsh-emacs
implementation and for subsequent feature development. The protocol surface is
verified against the `deepseek-harness` repository at `dsh-v0.2.0-rc.2`
(`639ed01539`). The 0.1.5 round was a **live probe** against `dsh-v0.1.5-rc.1`
(`aa8262ec09`, the surface of the 0.1.5 npm `latest`); the 0.1.6, 0.1.7 and
0.2.0 rounds were established by full tag-to-tag source / type / persistence
schema comparisons (`dsh-v0.1.5-rc.2` → `dsh-v0.1.6-alpha.1` →
`dsh-v0.1.7-rc.1` → `dsh-v0.2.0-rc.2`).
**0.1.6 was additive to every surface dsh-emacs calls; 0.1.7 and 0.2.0 are
not** — 0.1.7 removed the `session/control` queue/jobs frames and reshaped
`agentPresets/list` (§0.4; the client migration has landed, postmortem/064), and
0.2.0 drops `agentPresets/list.modeSelectionEnabled`, makes every `account/*`
operation take a client-metadata argument, and strips the request args from
`workspace/initializeDefault` (§0.5). The transport layer, envelope,
authentication, HTTP route set, Session format version (still **V4**) and the
`KNOWN_SESSION_EVENT_TYPES` set (still **59**) are unchanged across 0.2.0.

- Protocol model: **unary Remote RPC (HTTP POST) + multiplexed Remote stream (a
  single WebSocket)**. Logical messages are decoupled from the physical channel:
  Remote calls and Remote streams share the same `client-request` /
  `server-response` envelope and the same error body; session events / control
  state / host notifications each travel over their own named stream endpoint.
- Channel address: `http://127.0.0.1:3080` (the dsh web default port;
  `--host 0.0.0.0` is rejected).
- **Browser session authentication**: since 0.1.2-rc.1, every `/api` request and
  every WebSocket upgrade requires a `dsh-auth-<sha256(authority)>` signed cookie
  (see §1.3). The existing dsh-emacs implementation already supports exchanging
  the `/?token=…` URL printed by `dsh web` for that cookie and sending it.
- Field names always use the on-wire camelCase / kebab-case originals; dsh-emacs'
  `dsh-emacs-protocol.el` is responsible for funneling these names into
  `cl-defstruct` accessors.

> **Relationship to the 0.1.2-rc.1 document**: this document supersedes the old
> `docs/rpc.md`. The transport layer, envelope, authentication, stream carrier,
> and the vast majority of namespaces are the same as in 0.1.2; the differences
> are concentrated in the **session event vocabulary (V3)**, the **open stream
> frames (assistant-stream)**, the **new namespaces** (`workspaceFiles`,
> `fileUploads`, `sessionFeedback`), and the **new HTTP routes** (`/api/file`,
> `/api/present.*`, `/api/session/uploadFileBinary`). The dsh-emacs client **has
> already migrated to this protocol surface** (`/api/<namespace>/<method>` unary
> calls + `session/follow`, `session/control`, `workspace/follow`, `$events` on
> the single `/api/remote.mux`); the next section records the five rounds of
> upstream changes, 0.1.2 and 0.1.5 (both live-verified) and 0.1.6 / 0.1.7 /
> 0.2.0 (source-compared). §11 is the per-feature usage companion to the 0.2.0
> delta table in §0.5.

## 0. Migration Cross-Reference (dsh-emacs Perspective)

### 0.1 0.1.2 Protocol Surface Replacement (client already done)

| Old (0.1.1-rc.2, now deleted) | New (0.1.2-rc.1 onward) |
|---|---|
| `POST /api/session.list` … (envelope `method: "session.list"`, a dotted name) | `POST /api/<namespace>/<method>` (two slash-separated segments; the envelope `method` must equal the URL endpoint). `session.list` → `session/list` etc., see §4 |
| `POST /api/respond` (answers `approval/requested` / `question/requested` frames) | No `/api/respond`. Approvals/questions arrive as **waterfall frames** on the `$events` stream (`{type:'waterfall', event, eventId, agentId, request}`); answering goes through the unary endpoint `POST /api/$events/result`, see §3.3 |
| WebSocket `/api/events.mux` (per-session frames: `session/event`, `session/queue`, `session/jobs`, `session/projection`, approval frames…) | A single WebSocket `/api/remote.mux` multiplexes all **Remote streams**: `session/follow` (opening snapshot + event frames), `session/control` (host-wide queue/jobs/projection baseline + incremental frames), `workspace/follow`, `$events`. The old `session/queue`/`jobs`/`projection` frame semantics are folded into `session/control` |
| WebSocket `/api/events.host` (`host/session-added`, `host/remote-event` …) | `emit` frames on the `$events` stream (event names pass through verbatim; allowlist in §6.2); session add/remove/change go through `api-session/added`, `/removed`, `/status`, `/error`, `/activity` |
| No authentication (direct loopback; only privileged methods reject non-loopback) | The entire Host API + WS upgrade requires a browser session cookie; loopback needs the cookie too, see §1.3 |
| Closed error-code set such as `session-not-found`, `command-error` | Error codes became namespaced as **`namespace/kebab-code`**: `session/not-found`, `session/agent-busy`, `gateway/*`, `workspace/*`, `subagent/*`, `agent-preset/*`, `directory-picker/*`, `llm/*` … (§5) |
| Session history `session.history` (`beforeSeq`+`maxMessages`, returns `HistoryEntry`) | `session/page` (`address` + `throughSeq` cursor + message-aligned records) + the `session/follow` opening snapshot; `SessionHistoryRecord = {type:'event'}` (see §7) |
| List/subscription data: `session.list` full snapshot + mux frame deltas | `session.list` full snapshot + `api-session/*` emit frames + `session/control` projection frames |
| `session.prompt`'s command slot (never wired up) and `command-error`/`unknown-command` | Slash commands go entirely through the `commands/list` + `commands/execute` Remotes; `session.prompt` only returns `{accepted:true}` (with a new required `requestId`) |
| `host.describe` (version/cwd/home…) | No corresponding Remote; the `$events` ready frame carries `host.home` (§3.3) |

### 0.2 0.1.5 Deltas (verified live at 0.1.5-rc.1)

| 0.1.2 | 0.1.5 |
|---|---|
| Session event vocabulary V2: the system prompt exists only in `request/header` | **Session format V3**: new surface event `system/message` (the system prompt = surface node 0, see §7.2); `request/header.header` forbids a `system` field |
| `assistant/message` = `{turn, step, message, usage?, interrupted?}` | Adds `stream: AssistantStreamRecord[]` (the exact stream record of that attempt); new `assistant/attempt` (an attempt that committed no surface message) |
| `assistant/chunk` event (token-level deltas written to the log) | **Removed**. Deltas now go through in-process `assistant-stream` frames, requiring `assistantStream: true` opt-in (§3.2.1, §7.1; client already wired up) |
| `SessionWireHeader.seedLength` | `SessionWireHeader.isSeeded: boolean` |
| History page `SessionHistoryRecord = {type:'chunks', event}` (chunkrow packing) | **Packing removed**: records are only `{type:'event', event}`; the compact stream is embedded in `assistant/message.data.stream` |
| No workspace file reading service | New namespace `workspaceFiles` (7 methods, including the `changes` stream); HTTP `GET/HEAD /api/file?path=` (§4.16, §10) |
| Image attachments inline base64 | New namespace `fileUploads/upload` + `POST /api/session/uploadFileBinary` streaming upload; `PromptContentPart` adds `{type:'file', receiptId}` (§4.17) |
| No session-level feedback endpoint | New namespace `sessionFeedback/record` (shared by `/feedback` and Dislike, §4.18) |
| `commands/execute`'s `images` parameter | Parameter renamed to `submittedAttachments: CommandSubmitAttachment[]` (tagged union: image + file receipt, §4.11; client already fixed) |
| No deliverables protocol | New event `deliverables/presented` + `present` tool + `GET /api/present.host` / `POST /api/present.open` (§10) |
| `goals` namespace has no `get` | New `goals/get`; `goal/activation-changed` enters the `$events` allowlist (§6.2) |

**Live verification at the 0.1.5-rc.1 baseline**: using the browser-session signing
key in ~/.dsh, every endpoint in this document was probed one by one against the
live service at `http://127.0.0.1:3080`. Conclusion: `session/list` (`_request`),
`agentPresets/*`, `llm/*`, `session/modelCatalog`, `settings/describe`,
`skills/list`, `fileReferences/list`, `sessionReferenceResolver/candidates`,
`subagents/list`, `pluginInventory/list`, `goals/get`, `commands/list`,
`workspaceFiles/stat`, `fileUploads/upload`, `session.export`, `session/prompt`
(including `{type:'file', receiptId}`) all pass.

During testing, a parameter-name mismatch in `commands/execute` was found — the
live service answered `{"images":[]}` with `gateway/arguments-invalid`
(`missing "submittedAttachments"; unexpected "images"`), while
`{"submittedAttachments":[]}` returned `ok`. **That gap has been fixed in the
client** (`dsh-emacs-command.el` sends `submittedAttachments` and reads
`input.attachments` instead of `input.images`); re-verified against the live
service after the fix: both payloads — with an attachment and plain text —
return `{"ok":true}`, and the old `images` field is still rejected.

### 0.3 0.1.6 Deltas (verified by source comparison)

Baseline: `dsh-v0.1.5-rc.2` (`fb2c4b9e`) — 0.1.5-rc.1 → rc.2 carried **no**
protocol change (the only source edit was a comment in
`packages/feedback/message-feedback/src/types.ts`). Target:
`dsh-v0.1.6-alpha.1` (`0a15e36e7f`). Transport, envelope, browser-session
authentication, the single `/api/remote.mux` carrier, the HTTP exact-route set,
and the Session format version (**still V3**) are unchanged. Every 0.1.6 change:

| 0.1.5 | 0.1.6 |
|---|---|
| Remote method table: 82 endpoints | **93: +11, none removed or renamed.** New namespace `terminal` (9: `environment` `shells` `list` `create` `follow`(stream) `write` `resize` `rename` `close`), new namespace `permissionPresets` (`catalog`), and `workspace/unarchiveSession` |
| `agentPresets/list` value `{ presets, authorable }` | adds required `modeSelectionEnabled: boolean` (§4.6) |
| `CommandDescriptor = { name, description, input? }` | adds optional `definitionId?` — a stable plugin-owned identity independent of the command name (§4.11) |
| `SkillEntry = { name, description, whenToUse?, modelInvocable }` | adds optional `path?` — absolute `SKILL.md` path when a filesystem provider supplies one (§4.2) |
| `permissions` projection = `{ options, currentValue }` | **narrowed to `{ currentValue }`**; the selectable options moved to the new unary `permissionPresets/catalog` → `{ options }` (§4.19) |
| `$events` allowlist: 19 entries | **20** (18 emit + 2 waterfall): adds emit `permission-presets/catalog-changed` (§6.2) |
| `KNOWN_SESSION_EVENT_TYPES`: 56 | **57**: adds durable event `image/offload`; image content blocks may carry `offloaded?: true`; failure objects may carry `offloadImages?: number`; `tool/result.error` / `tool/ptc-dispatch.error` may carry `reason` (§7) |
| `contextPressure` / `contextBreakdown` projection `stateVersion` 4 | 5 — internal fold-version bump; both wire view shapes are unchanged (§9) |
| `session/fork` child seed extends to the next `turn/start` | the seed prefix is cut exactly at the boundary `turn/end`; wire shape unchanged |
| goal activation listener `agent/session-start` | `agent/created` — host-internal; the `goal` projection and `goals/*` are unchanged |

**Impact on dsh-emacs: no migration required.** At the 0.1.6 baseline the
client needed no code change, and later rounds adopted several additions as
features: `workspace/unarchiveSession` backs `dsh-emacs-unarchive-session`
(postmortem/049); `tool/result.error.reason` is shown on failed tool rows;
`permissionPresets/catalog` backs the permission-preset picker
(`dsh-emacs-set-permission`), paired with the narrowed `permissions` projection's
`currentValue` (the mode-line permission segment). The remaining new surfaces are
unused or ignored: `terminal` is never called; the widened roster / descriptor /
`SkillEntry` values are read through `assq`-style alist parsing that ignores
unknown fields; the new `$events` emit falls through the client's `_ → nil`
handler; and the new `image/offload` event is dropped by
`dsh-emacs-render-event`'s default branch (unknown optional fields on rendered
events are ignored). The sections below record 0.1.6 so the reference stays
current.

### 0.4 0.1.7 Deltas (verified by source comparison)

Baseline: `dsh-v0.1.6-alpha.1` (`0a15e36e7f`) → target: `dsh-v0.1.7-rc.1`
(`46a7f68b09`). Transport, envelope, browser-session authentication, the single
`/api/remote.mux` carrier, and the exact HTTP route set are unchanged. **This
round is not additive**: it removes wire surface dsh-emacs consumes.

| 0.1.6 | 0.1.7 |
|---|---|
| `session/control` baseline `{queues, jobs, projections}`; delta frames `queue` / `jobs` / `projection` | baseline is **`{projections}` only**; the `queue` and `jobs` frames are **deleted**. Queue state now rides the `inbox` session projection (§6.1, §9); background jobs moved to the new `job` namespace (§4.21) |
| `agentPresets/list` → `{presets, authorable, modeSelectionEnabled}`; row `{id, trust, isDefault, name?, description?, broken?}`; `agentPresets/read` document carries `trust`; `agentPresets/copy` + `agentPresets/deletePreset` exist | roster is `{presets, modeSelectionEnabled}`; row loses **`trust`** (an undeclared `order?` sort hint now rides it at runtime); the group document loses `trust`; `copy`/`deletePreset` are **deleted**; the owner package is renamed `packages/preset/agent-presets` → `packages/preset/agent-preset-registry` (§4.6) |
| `settings/canOpenAgentPresetDirectory`, `settings/openAgentPresetDirectory` | both **deleted**; `settings/describe.hasDocument` is now always `true`; the namespace view adds `autoGenerate`; the controller's `Config.nativeOpen` is gone (§4.7) |
| 21 mounted namespaces | **26**: adds `account`, `job`, `pluginManager`, `pluginRegistryProbe`, `officeToPdf` (§4.21, §4.22, §4.23) |
| `session.*` | new `session/projections` (cold, non-activating projection read) and `session/workspacePathApplications`; `SessionSummary` adds `agentAvailable`; `SessionProjectionHints` adds `kind: 'cached'\|'sequenced'`; `SessionAddress` subagent `mode` adds `'unknown'`; `session/page` and `session/follow` add `turnWindow`; `openWorkspacePath` adds `application?`; `updateQueue` now resumes a cold Agent first (§4.1) |
| `workspace.*` | `workspace/follow` baseline adds `pinnedSessionIds` and a `pinned` increment; new `workspace/pinSession` / `unpinSession` / `initializeDefault`; `archiveSession` adds `stopActivity?` and can refuse with `workspace/session-active` (§4.4) |
| `terminal.*` | new `terminal/retain` (stream); terminals are no longer confined by the Session sandbox (they run with the execution environment's own user permissions) and `environment.cwd` is the session `cwd`, not the resolved workspace root; new `terminal/unavailable`; the "close terminals before changing `sandbox/mode`" guard is gone (§4.20) |
| `permissionPresets/catalog` → `{options}` | adds `defaultOptions: PresetOption[]` and `defaultPreset: string` (§4.19) |
| `sessionReferenceResolver/candidates` item `{sessionId, label, cwd?, sameWorkspace, createdAt}` | adds `displayTitle?` (subagent-label-first presentation text); `mention` now prefers `displayTitle` over `label`; `query` also matches it (§4.13) |
| `workspaceFiles/*` | byte reads collapse to `readBytes` + `baseFile?`; `data` becomes raw bytes carried **out of band** — `null` in the JSON metadata plus a `multipart/form-data` `bytes-<n>` part (0.1.6 sent base64 inside the JSON); new `workspace-file/watch-unsupported`; `changes` becomes per-`path` and reports **current** target metadata after invalidation (§4.16) |
| mux client messages: `open` / `cancel` | adds **`item`** and **`end`** (uplink half-close) for duplex streams; new error codes `gateway/protocol`, `gateway/uplink-overflow` (§3.1) |
| `$events` allowlist 20 (18 emit + 2 waterfall) | **23** (21 emit + 2 waterfall): adds `plugin-manager/changed`, `plugin-manager/install-log`, `plugin-manager/install-state` (§6.2) |
| `KNOWN_SESSION_EVENT_TYPES` 57 | **59**: adds `developer/message` (incremental developer-role message) and `workspace/changes` (a turn produced workspace file changes) (§7) |
| Session format **V3** | **V4**; `turn/end.reason` adds `{kind:'forked'}` — the synthetic closer a fork seed writes for a turn left open at the cut (§7.1) |
| projection `stateVersion`: `subagent`/`subagentCatalog` 2, `agentTeam` 3 | 3 / 3 / 4 — fold-version only; the wire view shapes are unchanged |
| error codes | adds `gateway/protocol`, `gateway/uplink-overflow`, `session/projections-unavailable`, `session/writer-held`, `workspace/session-active`, `terminal/unavailable`, `job/not-found`, `workspace-file/watch-unsupported`; `agent-preset/read-only` is now unreachable (its only throwers were `copy`/`deletePreset`) (§5) |

**Impact on dsh-emacs: two migrations were required, and both have landed**
(postmortem/064). The 0.1.7 round was prepared as a reference first and then
implemented in the client; the two surfaces that had to move:

1. **Queue mirror source.** `dsh-emacs-queue.el` used to mirror the host inbox
   from the `session/control` `queue` frame and the baseline's `queues` record
   (§6.1 in the 0.1.6 shape). Both are gone. The mirror is now derived from the
   **`inbox` projection**, which carries exactly the same fold state the host
   used to map into `SessionQueuedItem[]`: `session/control` delivers it as an
   ordinary `projection` frame with `key: "inbox"` (and in the generation
   baseline's `projections[<sessionId>].values.inbox`), so the client derives
   its items locally — `next-turn` → `queued`, `next-step` with a user source →
   `steering`, any other `next-step` → `context`, per item
   `{id, content, source}` (§6.1, §9). A cell whose session has no live chat
   buffer is dropped rather than applied to whatever buffer is current. The
   `inbox` projection has existed unchanged since before 0.1.5 and is present in
   the 0.1.5 baseline too, so this source switch is forward-compatible rather
   than a version fork.
2. **`agentPresets/list` display names.** `dsh-emacs--preset-display-name` used
   to key the web-consistent labels (`Standard mode` …) on
   `(equal "system" trust)`, and the row no longer carries `trust`. The mapping
   now keys on the preset id alone — which is what the web's own
   `presetDisplayText` does — and `dsh-emacs-protocol.el` dropped the roster's
   removed `authorable` field (plus its already-stale `hasDocument` sibling,
   which no server version ever sent).

Everything else in the table is additive or unread by the client: the widened
`session/list` row, the `turnWindow`/`application` options, the workspace pin
set, the new namespaces (except `job`, which the client consumes — §4.21), the
`permissionPresets` catalog fields, the `displayTitle` hint and the two new
durable events all fall through the client's `assq`-style alist parsing and its
`_ → nil` frame/event defaults.

Migration checklist: open only one WS, `/api/remote.mux`; approvals/questions go
through `$events` waterfall + `$events/result`; **projections (including the
queue-bearing `inbox`) go through `session/control`**; consume the event
vocabulary per the §7 table (V4 from 0.1.7 adds two durable events, §7.1) — in
particular, no longer wait for `assistant/chunk`, but consume `assistant-stream`
frames (§3.2.1) or `assistant/message.data.stream`; `commands/execute` now sends
`submittedAttachments`. **0.1.6 adds no client-side migration step** (§0.3);
**0.1.7 requires the two migrations above** (§0.4).

### 0.5 0.2.0 Deltas (verified by source comparison)

Baseline: `dsh-v0.1.7-rc.1` (`46a7f68b09`) → target: `dsh-v0.2.0-rc.2`
(`639ed01539`, the 0.2.0 release tag). Transport, envelope, browser-session
authentication, the single `/api/remote.mux` carrier, the exact HTTP route set,
the Session format (**still V4**) and `KNOWN_SESSION_EVENT_TYPES` (**still 59**)
are unchanged. This round is **partly breaking**: three method families change
their argument/value shape, but only one of them touches dsh-emacs.

| 0.1.7 | 0.2.0 |
|---|---|
| 26 mounted namespaces | **29** in the shared client wiring table: adds `schedule` (§4.24), `userQuestions` (§4.25) and `productAnalytics` (§4.26). Only `userQuestions` is mounted by a default profile: `schedule` rides the optional, switched-off `@deepseek-ai/dsh-experimental-schedule-bundle` (and 0.2.0 deletes the 0.1.7 `schedule` projection outright — §9), and `productAnalytics` only exists under the Desktop profile |
| `account/getProfile {}`, `getBalance {}`, `startSignIn {locale, …}`, `signOut {}` | every account operation now takes a leading **`client: AccountClientMetadata`** = `{version, locale, timezoneOffsetSeconds}`; `startSignIn`'s `locale` is replaced by `client.locale`. **New**: `getUnnotifiedBonuses(client)`, `ackBonusNotified(accountId, orderId, client)`, `hasRunningAccountTasks()` and the `watchExpiry` stream (§4.22) |
| `workspace/initializeDefault {request:{directoryName, title}}` | **takes no request args**; the leaf directory is fixed (`<Documents>/deepseek-harness/default-workspace`) and its stored title is that same automatic name (the browser localizes it); the old blank/trim/separator `gateway/bad-request` validation is gone (§4.4) |
| `agentPresets/list` → `{presets, modeSelectionEnabled}` | roster is **`{presets}`**: `modeSelectionEnabled` is **deleted** (the chooser is always enabled and the saved default always applies) (§4.6) |
| `session.*` | new `session/initializeDefaultModel` (no args); `selectModel` now rejects a model absent from the live catalog (`session/model-unavailable`) and persists the deployment default in the background; `modelCatalog.routableProviders` narrows to providers with ≥1 currently available model (§4.1) |
| `workspaceFiles/list` | follows a **final** symlink/junction that resolves to a directory, listing the resolved directory; `read` keeps its no-follow gate (§4.16) |
| `terminal/shells` discovery | candidates de-duplicate by **executable name** (case-insensitive, `.exe` stripped) instead of full path (§4.20) |
| `permissionPresets` Auto bundle | the derived `auto` preset's approval policy is **`ask`** (was `never`); a still-selected `auto` also matches a `never` approval knob so a delegated child keeps a final denial (§4.19) |
| `$events` allowlist 23 (21 emit + 2 waterfall) | **27** (25 emit + 2 waterfall): adds `credentials/record-updated`, `deepseek-account/model-sign-in-required`, `deepseek-account/session-expired` and `schedule/changed` (§6.2) |
| client-visible projections 18 | **19**: adds `userQuestions` = `{active: PendingUserQuestion[], settled: SettledUserQuestion[]}` (`stateVersion` 2) (§9) |
| `schedule/change` (the `schedule` projection is deleted at 0.2.0) | named tasks: new records require `title` (≤120 chars) and the rule set adds `daily` / `weekly` / `cron` (explicit IANA zone); `every`'s minimum interval drops 5 min → 1 min. Legacy records without `title` still read (§7.3) |
| `request/header.startsSeries` | now marks "this request begins a distinct message series" **independently of `reason`**, instead of being reserved for `reason:'change'` (§7.2) |
| `ApprovalRequestEvent` | gains optional `displayReason?: {en: string, [locale]: string}` — localized presentation only, never written to the audit events (§3.3) |
| `user/message` sources | adds `user-question-reply` (`{kind, callId, outcome:'answered'}`) — the steer message that closes a continued timed question (§7.2) |
| error codes | adds `session/provider-credentials-unavailable` `{}` and `session/provider-models-unavailable` `{provider}` (§5.2) |

**Impact on dsh-emacs: one inert field drop; no mandatory migration.** The
client's RPC call set (session / workspace / commands / goals / job /
agentPresets / skills / fileReferences / permissionPresets /
sessionReferenceResolver) is otherwise untouched by 0.2.0:

1. **`agentPresets/list.modeSelectionEnabled` is gone.** `dsh-emacs-protocol.el`
   still declares and parses the slot, so the value now reads `nil`; no business
   code consumes it (`grep` finds the symbol only in the protocol struct, its
   header comment and the unit tests), so the picker is unaffected. The dead
   struct slot and its comment are a documentation/code divergence to delete
   when the protocol file is next edited.
2. **The `account/*` and `workspace/initializeDefault` arg changes do not apply
   to dsh-emacs**: the client calls neither namespace.
3. **Timed questions are adopted (§4.25).** dsh-emacs claims a timed
   question's foreground wait while its prompt is on screen, renders the
   expired-window result as `pending`, and answers a `continued` call later
   through `userQuestions/answer` (`M-x dsh-emacs-answer-question`), completing
   the original ask card from the projection (postmortem/073). The rest of the
   additivity falls through the client's `assq`-style parsing and `_ → nil`
   frame/event defaults: `schedule` and `productAnalytics`, the four new host
   emits, the `schedule` rule widening, `displayReason`, and the
   `user-question-reply` source kind.

Migration checklist for 0.2.0: nothing is required to keep the current client
working. Timed-question support is additive and dormant on a 0.1.7 server
(there is no `wait` field and no `userQuestions` cell). If the account surface
is ever adopted, every call must carry
`client = {version: <app version>, locale: <UI language>, timezoneOffsetSeconds:
<UTC offset>}` and `startSignIn` has no separate `locale`; a client that calls
`workspace/initializeDefault` must drop its `directoryName`/`title` arguments
and localize the automatic `default-workspace` title itself. Per-feature call
recipes are §11.

---

## 1. Transport Layer

| Channel | Path | Direction | Purpose |
|---|---|---|---|
| HTTP POST | `/api/<namespace>/<method>` | C→S | Unary Remote RPC (`session/list`, `session/prompt`, `goals/create` …); the body is a `client-request` envelope whose payload is exactly `{args:{…}}` |
| HTTP POST | `/api/$events/result` | C→S | Unary endpoint: answer one waterfall on the `$events` stream (approval/question), payload `{args:{clientId,eventId,outcome}}` (§3.3) |
| WebSocket | `/api/remote.mux` | C⇄S | All Remote streams multiplex over one connection: one `open` message per logical stream; the server replies `item/error/end` per stream (§3.2) |
| HTTP GET/HEAD | `/api/session.export` | S→C | Session log ZIP download (exact Fetch route, no envelope; §10) |
| HTTP GET/HEAD | `/api/file?path=<absolute>` | S→C | Read one bounded file response by absolute path (regular files only; `content-type` inferred from the extension; §10.2) |
| HTTP GET | `/api/present.host` | C→S | Deliverable desktop-capability probe: `{name, available, fileManager}` (§10) |
| HTTP POST | `/api/present.open?sessionId&seq&index` | C→S | Open/reveal a delivered file on the host desktop; args carry `action: 'open'\|'reveal'` (§10) |
| HTTP POST | `/api/session/uploadFileBinary?sessionId[&name]` | C→S | Raw byte upload (`content-type: application/octet-stream`, streaming body); replies `{ok, value:{receiptId, file}}` or `{ok:false, error}` (§4.17) |
| HTTP GET | `/`, `/assets/*` | S→C | Frontend static assets (public); the root path handles the browser session login exchange (§1.3) |

- All `/api` RPC POSTs must use `content-type: application/json`, otherwise **415**;
  a non-JSON body returns **400**. The HTTP status describes only the carrier:
  business success/failure both go out as 200 + the envelope's `result`
  (a `gateway/bad-request` envelope error is 200 too).
- Exact Fetch routes own their status codes (`/api/file` 400/403/404/413/499,
  `/api/session.export` 400/404/500, the upload route 400/405/415); unary Remote
  and `/$events/result` are always 200 + envelope (including business errors).
- Only Remote (including `$events/result`), `/api/file`, `/api/session.export`,
  `/api/present.host`, `/api/present.open`, and `/api/session/uploadFileBinary`
  are claimed; an unclaimed `/api/*` POST returns **404** (`not found`). Non-POST
  RPC paths are likewise 404 (exact routes match by their own method).
- The default request body limit is **300 MiB** (`DEFAULT_MAX_REQUEST_BODY_BYTES`,
  reserving for base64 inflation of the 200 MiB aggregate image limit + envelope
  headers); over the limit is 413.
- There is exactly one stream carrier (identical for browsers and dsh-emacs):
  WebSocket `/api/remote.mux`, JSON text messages, host-side ping/pong keepalive
  (one Ping every 2s by default; if the previous Ping got no Pong, terminate).
  The in-process Node client has an `rpc.open` logical-stream equivalent that
  does not use WebSocket (not covered in this document).
- Session content has no SSE fallback (there is no SSE carrier). The existing
  dsh-emacs implementation ships its own minimal RFC 6455 client and connects
  directly to `/api/remote.mux` (not via the browser EventSource).

### 1.1 Unary Request Routing and Claiming

The `/api` prefix route (registered by `@deepseek-ai/dsh-client-connection`) first
does trust and authentication checks, then: **exact Fetch routes** (by
pathname+method: `/api/session.export`, `/api/file`, `/api/present.host`,
`/api/present.open`, `/api/session/uploadFileBinary`) > **shared channel
interceptor** (the two-segment Remote endpoints claimed by
`@deepseek-ai/dsh-api-gateway` + `$events/result`) > 404. Endpoint segments may
only consist of `[A-Za-z0-9_$.-]+`; empty segments / `.` / `..` are rejected.

The gateway claims only endpoints with exactly two segments that exist in the
**strict descriptor registry** (generated by typert at build time) or in the SRC
activity markers; when running from source (`node --import tsx`) it degrades to
parameter-name inference (SRC fallback, no schema validation). The Remote
endpoint `namespace/method` and the envelope's `method` must agree.

### 1.2 Envelope (client-request / server-response)

The request body and response body of a unary POST are the only two of the four
message kinds that remain (0.1.2 removed `server-request`/`client-response`, see
§0/§3.3):

Request (body):
```json
{ "type": "client-request", "rpcId": "<uuid>", "method": "session/prompt",
  "payload": { "args": { "request": { "sessionId": "…", "mode": "queue", "content": […], "requestId": "…" } } } }
```
- `rpcId`: generated by the client; echoed back verbatim in the response.
- `method` == the URL endpoint (`<namespace>/<method>`); a mismatch returns a
  `gateway/bad-request` envelope error.
- `payload` must be **exactly one plain object `args`**, whose field names match
  the method parameter names exactly (except lookup parameters: the
  `agent`/`session` parameters are `agentId`/`sessionId` on the wire). Most
  methods have a single parameter named `request` → `args` holds one level of
  nesting, `{ "request": {…} }` (a few methods such as
  `directoryPicker/createDirectory` spread `path`/`name` directly). `signal:
  AbortSignal` is a cancellation signal, not an args field.

Response (body):
```json
{ "type": "server-response", "rpcId": "<echo>",
  "result": { "ok": true, "value": { … } } }
```
Failure form:
```json
{ "type": "server-response", "rpcId": "<echo>",
  "result": { "ok": false, "error": { "code": "session/not-found",
              "message": "…", "details": { "sessionId": "…" } } } }
```
- `result.value` is omitted entirely for a void business result (not `null`) —
  that is the case for void Remotes (`credentials/set`, `terminal/write`,
  `workspace/delete`, etc.).
- **Byte-carrying results are `multipart/form-data`** (0.1.7): when a result
  contains a `Uint8Array`, the host moves the octets out of the JSON into
  `ConnectionRpcAttachment` parts and writes `null` at their path. The response is
  then a form with a `metadata` part (the ordinary `server-response` JSON, plus
  `attachments: [{path, codec:'bytes', part}]`) and one `bytes-<n>` part per
  byte view. Only unary results do this — stream items are JSON. See §4.16.
- When the envelope cannot be parsed: if the body has a string `rpcId`, use it;
  otherwise use the sentinel `rpcId = "invalid-request"`, and return
  `gateway/bad-request` (message `invalid client-request message`, details carry
  `issues`).

### 1.3 Browser Session Authentication (required on every request)

- **Startup token**: each launch of `dsh web` generates a random per-process token
  and prints `dsh web: http://127.0.0.1:<port>/?token=…`. The token is not
  persisted; it changes on restart.
- **Token → cookie exchange**: `GET /?token=<token>` (only the root path `/`, GET,
  exactly one token) → `303` + `Set-Cookie`; only a subsequent `GET /` with the
  cookie serves index. Any other root-path request gets the same 401.
- **Cookie**: name `dsh-auth-<base64url(sha256(authority))>` (authority = the
  `host[:port]` from the Host header), value `v1.<body>.<sig>` (HMAC-SHA256 over
  a persistent signing secret; the payload carries authority/expiresAt, 30 days
  by default), attributes `Path=/; HttpOnly; SameSite=Strict`. Verified on every
  request: the cookie name matches that authority, the signature is valid, and it
  has not expired.
- **Trust fence (403)**: the Host header must be a loopback hostname (`localhost`,
  `[::1]`, any 127/8 address) or be in the `trustedHosts` configuration;
  `sec-fetch-site: cross-site` is rejected; if an Origin is present it must equal
  the Host (a missing Origin is allowed — that is the case for curl/emacs).
- **Authentication (401)**: the fence passed but there is no valid cookie → 401.
  This is consistent across RPC POSTs, exact GET routes, and `/api/remote.mux`
  upgrades; a rejected upgrade is answered with plain HTTP `401/403` and then the
  socket is closed.
- dsh-emacs path: for a server it launches itself, it automatically captures the
  token from `*dsh-server*` output and mints the cookie
  (`dsh-emacs-server-auth-token` for a manually started service); just add the
  cookie to every RPC's `extra-request-headers` and to the `/api/remote.mux` WS
  handshake.
- If an HTTP reverse proxy additionally needs Basic authentication, the
  `user:pass@` in the URL is also sent with the token exchange request; the
  exchange only picks the `dsh-auth-*` from the response headers and ignores the
  proxy's own cookies. RPC requests disable the URL library's global cookie jar
  so that it cannot be sent alongside the explicit auth cookie. A 401 on either a
  synchronous or an asynchronous RPC clears the rejected cookie and reports an
  authentication error; no username/password prompt is raised. The next request
  can exchange the configured token again.
- The HTTPS token exchange uses its own body-less GET and does not inherit the
  POST method or headers of the RPC that triggered it; both the first call and
  the on-demand exchange after cookie invalidation follow the same rule.

---

## 2. Remote Programming Model (typert)

A business service `extends TypertRemoteService`
(`super(ctx, '<service>', {namespace})`; without a namespace it defaults to the
service key), selecting methods with decorators:

- `@Remote('name')` / bare `@Remote` → unary endpoint `namespace/method`;
- `@Remote({ mode: 'stream' })` → stream endpoint (can only be opened via
  `/api/remote.mux`, not called unarily; conversely a unary endpoint cannot be
  opened as a stream, `gateway/signature-invalid`);
- Parameters are the wire args: ordinary JSON parameters keep their names as
  fields; `agent`/`session`/`parentSessionId` etc. are resolved by registered
  lookup/context providers (the host resolves the wire `agentId`/`sessionId` back
  to a live Agent/Session, including **automatic resume of cold sessions**); the
  trailing `signal` parameter is a cancellation signal.
- The host business package writes generated artifacts into its own `lib/`:
  `typert.host.*` (host descriptors), `typert.remote-client.*` (client wiring +
  type merging). Browser wiring only mounts the contribution packages selected by
  `@deepseek-ai/dsh-api-remotes` (the full set of namespaces listed in §4).
- Stream methods (`follow`/`control`) and unary Remote calls are two separate
  protocol surfaces and do not masquerade as each other; non-JSON carriers
  (export ZIPs etc.) go through `connection.fetch.register` exact GET/HEAD routes.

Once a request enters as an HTTP POST: decode the envelope → assert `{args}` →
resolve the endpoint descriptor → validate fields exactly (extra/missing/wrong →
`gateway/arguments-invalid` etc.) → lookup/context resolution → call the live
service method → validate the return value → wrap in `result`. Unclassified
exceptions fold into `gateway/internal`; `RemoteError` (including business codes
and `gateway/cancelled`) goes on the wire with its original code.

---

## 3. Streams

### 3.1 Messages on `/api/remote.mux`

The client opens one WS (upgrade with cookie). After that, one text message per
**logical stream**:

```json
{ "type": "open", "streamId": "<client random string>", "endpoint": "session/follow",
  "payload": { "args": { "request": { "address": { "kind": "session", "sessionId": "…" } } } } }
{ "type": "item", "streamId": "<same string>", "value": { … } }   // uplink, duplex streams only (0.1.7)
{ "type": "end",  "streamId": "<same string>" }                  // uplink half-close (0.1.7)
{ "type": "cancel", "streamId": "<same string>" }
```

The server replies per stream:
```json
{ "type": "item", "streamId": "…", "value": { … } }
{ "type": "error", "streamId": "…", "error": { "code": "…", "message": "…", "details": {} } }
{ "type": "end", "streamId": "…" }
```
- Value validation: `open` has exactly `type/streamId/endpoint/payload`; `cancel`
  and `end` have exactly `type/streamId`; `item` has exactly
  `type/streamId[/value]` with a lossless-JSON `value` when present. A duplicate
  streamId closes that connection with 1008; binary messages close with 1003 and
  text that is not JSON with 1008. An `error` frame terminates that stream (error
  body as in the §5 error model).
- **Uplink (new in 0.1.7)**: `item`/`end` carry client→host stream input for a
  duplex Remote method (one whose parameters include an incoming stream). A
  unary-shaped stream that never reads an uplink drops unread items; overflowing
  the carrier's bounded queue is `gateway/uplink-overflow`. None of the streams
  dsh-emacs opens (`session/follow`, `session/control`, `workspace/follow`,
  `$events`) takes an uplink, so the client keeps sending only `open`/`cancel`.
- The host pings every 2s; a client that misses 2 pongs in a row is terminated.
  Close codes: host 1003/1008/1011 (final frame undeliverable), client 1000
  (dispose)/4000 (proactive reconnect)/4002 (invalid frame).

**This connection is the single multiplexing carrier for all streams**: one WS
can simultaneously carry `$events` + `session/control` + `workspace/follow`
(dsh-emacs' resident trio, see the core stream in `dsh-emacs-events.el`) + one
`session/follow` per open session. Practical points (already implemented in the
client, for reference in later changes):

- `streamId` is meaningful only within **one connection**; after the connection
  drops, all logical streams must be reopened. Reopening `session/follow` gets a
  fresh `snapshot`, and the client dedupes using the `cursor`/`seq` watermark — do
  not treat a reconnect as "resumption".
- `error`/`end` terminates only **that streamId**, not the whole connection; the
  other streams keep being served.
- The host does not reconnect on the client's behalf; dsh-emacs uses its own
  watchdog + backoff reconnect (a `$events` reconnect produces a new `clientId`,
  and pending waterfalls from the old generation must be retired wholesale and no
  longer answered).

### 3.2 Logical Stream Endpoints

| endpoint | open payload | frame content (item value) |
|---|---|---|
| `session/follow` | `{args:{request:{address, maxMessages?, turnWindow?, assistantStream?}}}` | Opening snapshot frame `snapshot` (header/cursor/records/hasMore/projections[/assistantStream]), followed by gapless `event` frames and optional `assistant-stream` frames (§7.1). **The client sends `assistantStream: true`**, otherwise it receives no deltas |
| `session/control` | `{args:{}}` | Exactly one `baseline` per generation, then `projection` delta frames (§6.1). **0.1.7**: the `queue`/`jobs` frames are gone; the queue rides the `inbox` projection |
| `workspace/follow` | `{args:{}}` | One `baseline` per generation, then `upsert`/`remove`/`order`/`archived`/`pinned` (§4.4) |
| `workspaceFiles/changes` | `{args:{<scope>}}` | Workspace file change stream: `WorkspaceFileWatchFrame` (§4.16) |
| `terminal/follow` | `{args:{agentId, id, attachmentId}}` | **new in 0.1.6**: one `snapshot` screen frame, then `output` / `state` frames (§4.20) |
| `terminal/retain` | `{args:{sessionId, id}}` | **new in 0.1.7**: one `retained` acknowledgement, then an open-window lifetime for that terminal without taking screen or input control (§4.20) |
| `job/list` | `{args:{request:{sessionId}}}` | **new in 0.1.7**: whole-set job-roster frames `{type:'rows', jobs: JobView[]}` — one on open, then one per coalesced lifecycle burst (§4.21) |
| `job/follow` | `{args:{request:{sessionId?, jobId, from?}}}` | **new in 0.1.7**: `opened` anchor → coalesced `output` batches → terminal `status` (§4.21) |
| `$events` | `{args:{}}` | `ready` (clientId+host.home) → `emit`/`waterfall`/`cancel` (§3.3) |

Except for `$events`, every stream's payload matches a unary Remote: an outer
`{args}` and the parameters inside. The `session/follow` args are the single
parameter `request` (SessionFollowRequest). `assistantStream?: true` (new in
0.1.5) requests **in-process** assistant delta frames — after a Web reconnect the
Web side can keep showing streaming output without replaying persistent chunks;
if not passed, only persistent `event` frames arrive (dsh-emacs currently does
not pass it and renders from persistent events).

### 3.2.1 assistant-stream Frames (0.1.5 replaces `assistant/chunk`)

The opening snapshot may carry `assistantStream: {revision, activeAttempt?}`;
`activeAttempt` = `{attemptId, startedAfterSeq, turn, step, nextIndex, stream}`,
where `stream` is the compact chunk record accumulated at open time. The live
frames that follow:

```json
{ "type": "assistant-stream", "frame": { "type": "start", "attemptId": "…", "revision": 1,
  "startedAfterSeq": 12, "turn": 2, "step": 1 } }
{ "type": "assistant-stream", "frame": { "type": "chunk", "attemptId": "…", "revision": 2,
  "index": 0, "time": 123, "chunk": { "type": "text-delta", "index": 0, "text": "Hi" } } }
```

Key semantics: these frames **are not persistent session events** (they carry no
`seq`). The host increments `revision` for every frame; a reconnect baseline
already includes frames through its revision, so equal or older revisions
must be ignored. A new attached Agent lifecycle may reset the counter on the
same connection: a `start` with revision 1 after a higher revision replaces
the old transient attempt — the revision is the discriminator, because
`attemptId` is `<sessionId>:<counter>` and the counter restarts with each
lifecycle, so it can repeat. The frame's `index` advances densely within an
attempt; `nextIndex` identifies the next frame after the baseline. This frame
counter is separate from the content block's `chunk.index`.
The baseline's compact `text-chunks`, `reasoning-chunks`, and `chunk` records
must be expanded before rendering. Its active prefix replaces previously
displayed transient blocks; it does not append onto the disconnected stream.
**Explicit opt-in is required**: these frames appear only if the `session/follow`
request carries `assistantStream: true`; otherwise a whole turn appears at once
when `assistant/message` lands.

Field distribution (measured on 0.1.5-rc.1): **only the `start` frame and the
opening snapshot's `activeAttempt` carry `turn`/`step`**, while `chunk` frames
carry only `attemptId/revision/index/time/chunk`; a renderer that groups streaming
body text by turn/step must remember that pair itself.

How dsh-emacs consumes it (`dsh-emacs-events.el`): it repacks each `chunk` into a
`{type:"assistant/chunk", data:{turn, step, chunk}}` event and sends it down the
ordinary event path to reuse the original delta renderer. It rejects duplicate
revisions, checks revision continuity and validates `attemptId` plus the dense
frame `index` on chunks and ends. A gap or unexpected attempt cancels the old
logical follow stream and opens a new one on the same socket; queued frames
from the retired stream id are ignored. The snapshot's
`activeAttempt.stream` is replayed once at open time so that a reconnect can
continue the same live body text; `end.outcome.kind == "committed"` is closed out
by the subsequent persistent `assistant/message` (which replaces the body) or
`assistant/attempt` (taken over as an attempt card, see §7.4), while
`"abandoned"` is flushed in place.

### 3.3 `$events`: Forwarded Host Events + Approval/Question Waterfalls

The `$events` stream is fed to the gateway by the **single** event source
registered by `@deepseek-ai/dsh-api-remotes`, and is then broadcast per connection
generation. The first frame after opening:

```json
{ "type": "ready", "clientId": "<uuid>", "host": { "home": "/Users/ed" } }
```

Subsequent downstream frames:
```json
{ "type": "emit", "event": "commands/change", "args": [] }
{ "type": "waterfall", "event": "approval/request", "eventId": "<uuid>",
  "agentId": "<sessionId>", "request": { "toolName": "bash", "callId": "…", "reason": "…" } }
{ "type": "cancel", "eventId": "<this waterfall's id>" }
```
- **emit**: pure notification; `args` is the event's original argument array
  (allowlist in §6.2).
- Before opening `$events`, the host synchronously installs all allowlist
  listeners and only then registers the stream, so the `ready` frame doubles as
  proof that "delta delivery is in effect".
- **waterfall**: the host is waiting for a client to "take the order" — the client
  should consume it (render the approval/question) and post the decision/answer
  back to `POST /api/$events/result`:
  ```json
  { "type": "client-request", "rpcId": "…", "method": "$events/result",
    "payload": { "args": { "clientId": "<clientId from the ready frame>", "eventId": "<same waterfall id>",
      "outcome": { "kind": "result", "value": <decision/answer value> } } } }
  ```
  `outcome.kind` ∈ `result` (carries value) / `next` (hand to the next taker) /
  `rejected` (`{error:{name,message,code?,details?}}`). The response to
  `$events/result` is `{ok:true}` (value omitted). After the host receives a
  cancellation (a `cancel` frame or the session ending), a pending waterfall no
  longer needs an answer. dsh-emacs removes the queued item by `eventId`; if the
  corresponding question or approval is being displayed in the minibuffer, it
  closes it immediately and does not send a stale outcome.
- The `request` of an `approval/request` waterfall (after agent/signal stripping) =
  `{toolName, callId?, reason?, displayReason?}`; **0.2.0** adds
  `displayReason?: {en: string, [locale]: string}`, a presentation-only
  localization that is **never persisted** in the audit events (a client that
  renders `reason` verbatim is unaffected). The answer value = an
  `ApprovalOutcome` string:
  `"allowed-once" | "rejected" | "cancelled" | "unavailable"` (the web taker
  usually replies only allowed-once / rejected, passing the rest to `next()`).
  **There is no approvalId on the wire**: the host-generated approval id appears
  only in the persistent audit event pair `approval/asked`
  (`{id, toolName, callId?, reason?}`) → `approval/decided` (`{id, outcome}`).
- The `request` of a `user-questions/request` waterfall = `{questions:
  AskUserQuestionItem[], wait?}`; `AskUserQuestionItem = {id, question, header?,
  detail?, options?: [{label, description?}], multiSelect?, intent?:
  {kind:'plan-review', approve, callId?}}` (`approve` is the button label for
  plan-review; `callId` identifies the submitted document). Supported plan reviews
  use a document buffer and asynchronous actions; intent changes presentation,
  not the protocol. **0.2.0** adds optional `wait?: {callId, timed?: true}`: a
  timed foreground wait that can expire while the question stays answerable — an
  answerer that wants to show a countdown attaches to
  `userQuestions/attachWait` (§4.25) before starting its local timer, and a
  continued question is later answered through `userQuestions/answer` rather
  than this waterfall. Request changes rejects with `error.name = "cancelled"`,
  returning the host to waiting for feedback. The answer value =
  `{answers: [{id, selected: string[], custom?}]}` (skip = `selected: []`).
- Reconnect: `$events` is reopened per generation by the connection controller; a
  new generation has a new `clientId`, and a result from an old `clientId` becomes
  a no-op.

---

## 4. Remote Namespaces and Methods

Each section gives: the endpoint (`namespace/method`), the wire `args` fields,
the value shape, related error codes, and key semantics. Optional items are
marked with `?`.

The **complete set visible to the client is exactly the client wiring table of
`@deepseek-ai/dsh-api-remotes`** (the `$mount` list in
`packages/api/remotes/src/client/index.ts` + the `directoryPicker` sub-plugin
composed by `workspace-controller`) — a Host namespace not in that table is
unreachable even if registered:

`agentPresets` `commands` `credentials` `directoryPicker` `dynamicCordisRunner`
`fileReferences` `fileUploads` `goals` `llm` `messageFeedback`
`permissionPresets` `pluginInventory` `session` `sessionFeedback`
`sessionReferenceResolver` `settings` `skills` `subagents` `terminal`
`workspace` `workspaceFiles` (21 at 0.1.6; of these, `credentials` and `settings`
are both mounted by settings-controller, and `directoryPicker` is composed by
workspace-controller. `permissionPresets` and `terminal` are **new in 0.1.6**;
with `terminal` that namespace also claims the `terminal/follow` /
`terminal/retain` stream endpoints).

**0.1.7 adds five** → **26**: `account`, `job`, `pluginManager`,
`pluginRegistryProbe`, `officeToPdf` (§4.21–§4.23). `job` is consumed by the
client (background-job roster/output/kill, `dsh-emacs-jobs.el`, §4.21); the
other four are unused. `job` matters to any client that wants a background-task
surface, because the `session/control` `jobs` record it replaces is gone (§0.4).

**0.2.0 adds three** → **29**: `schedule` (§4.24), `userQuestions` (§4.25) and
`productAnalytics` (§4.26). Only `userQuestions` is mounted by a default
profile: `schedule` rides the optional, switched-off
`@deepseek-ai/dsh-experimental-schedule-bundle`, and `productAnalytics` is
composed only under the Desktop profile (the shared Remote assembly advertises
it, so on an ordinary Web host those endpoints are unclaimed). dsh-emacs uses
`userQuestions`; the other two are unused.

Implementation anchors (master source):
- session / skills / fileReferences → `packages/api/session-controller`
- workspace / directoryPicker → `packages/api/workspace-controller`
- workspaceFiles → `packages/api/workspace-files`
- terminal → `packages/api/terminal-controller` (**new in 0.1.6**)
- settings / credentials → `packages/api/settings-controller`
- agentPresets → `packages/preset/agent-preset-registry` (package renamed in 0.1.7
  from `packages/preset/agent-presets`)
- llm → `packages/llm/llm`
- goals → `packages/goal/goal`
- commands → `packages/interaction/commands`
- permissionPresets → `packages/interaction/permission-presets` (**new in 0.1.6**)
- messageFeedback → `packages/feedback/message-feedback`
- sessionFeedback → `packages/feedback/command-feedback`
- sessionReferenceResolver → `packages/context/session-reference`
- fileReferences (wire owner in session-controller; type/query semantics in
  `packages/context/file-reference`)
- subagents → `packages/subagent/subagent`
- fileUploads → `packages/client/file-upload`
- pluginInventory → `packages/host/plugin-inventory`
- dynamicCordisRunner → `packages/extensions/cordis-host-runner`
- account → `packages/api/account-controller` (**new in 0.1.7**)
- job → `packages/api/job-controller` (**new in 0.1.7**)
- pluginManager / pluginRegistryProbe → `packages/boot/plugin-manager` and
  `packages/client/ui-plugin-manager` (**new in 0.1.7**)
- officeToPdf → `packages/document/office-to-pdf` (**new in 0.1.7**)
- schedule → `packages/schedule/schedule` (**new in 0.2.0**)
- userQuestions → `packages/interaction/user-questions` (**new in 0.2.0**)
- productAnalytics → `packages/client/product-analytics` (**new in 0.2.0**,
  Desktop composition only)

The `name` of `@Remote('name')` is the wire method (a bare `@Remote` uses the
method name); parameter names correspond one-to-one with `args` fields, but lookup
parameters such as `agent`/`session`/`parentSessionId` are
`agentId`/`sessionId`/`parentSessionId` on the wire and are resolved back to
instances by the host resolver.

General activation policy:
`list/search/modelCatalog/canOpenWorkspacePath/workspacePathApplications/page/fork/projections`
and `attachment` are **cold reads** (no Agent resume);
`create/selectModel/rename/prompt/updateQueue` resume explicitly; `cancel`
requires a live Agent; `follow` opens a cold session and promotes activation on
demand once the snapshot is sent; a subagent address
(`address.kind:'subagent'`) never activates. Unless stated otherwise,
these methods all reject subagent sessions (`session/agent-busy`, with `reason`
suggesting the `subagents` namespace instead).

Error envelopes and stream error frames share the same error body;
`gateway/internal` is the fold-in slot for unclassified exceptions.

### 4.1 session.*

#### session/list
```
args     { _request?: { cursor?: string } }  // parameter name `_request` (reserved empty list
                                              // request object, unlike `request` in other session
                                              // methods); cursor reserved & ignored, body may be {}
value    { items: SessionSummary[] }          // updatedAt descending
```
`SessionSummary = { sessionId, updatedAt, running, blank, agentAvailable,
parentSessionId?, origin?: 'subagent', cwd?, projections?: { kind, asOfSeq,
values } }`. Only visible sessions are listed (live + persistent sessions with a
cwd); `projections.values` is a partial hint from the persistent projection cache
(keys such as title, sessionListMetadata may be here; key table in §9), and a
missing cell means unknown. `updatedAt = max(createdAt, lastPromptAt)`. Cold rows
go through a small cold probe (≤16 events / ≤1024 B) to obtain the real
blank/lastPromptAt; if the probe fails it degrades to visible-but-unknown and
never fails the whole request. **0.1.7** adds `agentAvailable` (whether the
Session currently owns a live Agent — `/api-session/added` is now re-emitted when
that flips, §6.2) and `projections.kind`: `'sequenced'` when the live registry
produced the block, so `asOfSeq` is comparable with the connection's baselines and
frames; `'cached'` when a header-only listing read the persisted cache, so
`asOfSeq` is that stored record's own watermark and **must not** be compared with
the connected Session's values.

#### session/search
```
args     { request: { query: string } }
value    { items: { sessionId, snippet }[], hasMore: boolean }
```
query must be non-empty, ≤500 UTF-16 units, and contain no NUL (otherwise
`gateway/bad-request`). It searches only the currently visible (unshadowed)
user/assistant message surface; at most 20 hits, snippet ≤240 code points;
`hasMore` hints that the client should refine the query.

#### session/create
```
args     { request: { workspaceId?, cwd?, sessionId?, agentPreset? } }
value    { sessionId, agentPreset? }
```
- At most one of `workspaceId` / `cwd` (both given → `gateway/bad-request`); if
  both are omitted, the host cwd is used. Passing `sessionId` = explicit id
  adoption (same id + same cwd is idempotent; a different cwd →
  `session/conflict`; a different preset → `agent-preset/conflict`).
- If attaching fails after workspace creation → `session/workspace-attach-failed`
  (with the published sessionId); unknown workspace → `workspace/not-found`.
- An unknown/assembly-failing `agentPreset` is rejected by the preset assembly
  layer (`agent-preset/not-found` / `agent-preset/invalid`, see §4.6); a subagent
  identity → `session/agent-busy`.

#### session.selectModel
```
args     { request: { sessionId, provider, model, reasoningEffort? } }
value    { selected: { provider, model, reasoningEffort? } }
```
After an explicit resume, `model/selection` is installed by folding
request/header. **0.2.0** validates the pair against the live catalog first: a
provider with no registered adapter, a model that is not currently advertised,
or a model-listing failure → `session/model-unavailable` (details carry
provider/model). The deployment default is now saved in the background after
the per-Session selection is installed, so the returned value no longer waits
for (or fails on) default persistence. `session/prompt` dropped its own
provider-route pre-check in the same change, so an unavailable model surfaces
from `selectModel` (or the agent's admission) rather than at prompt time.

#### session.initializeDefaultModel
```
args     {}
value    void
```
**New in 0.2.0.** Picks the first available `deepseek-account` model after login
when no provider API key is configured, and saves it as the deployment default.
It is a no-op when any configurable API-key provider has a configured
credential. When the account provider advertises no model →
`session/provider-models-unavailable` (details carry provider); when the
settings/credentials services are absent →
`session/provider-credentials-unavailable`. dsh-emacs does not call it.

#### session.modelCatalog
```
args     {}
value    ModelCatalog
```
`ModelCatalog = { default: {provider, model, reasoningEffort?}, routableProviders:
string[], groups: ModelProviderGroup[], failures: ModelCatalogFailure[] }`;
`ModelProviderGroup = { id, name, models: [{id, name, description?, reasoning?:
{efforts:[{id,name,description?}], defaultEffort?}}] }`. Failing providers are
listed separately in `failures` and do not enter groups. Session-independent
(used by the settings surface/picker). **0.2.0** narrows `routableProviders` from
"providers with a registered route, including empty catalogs" to **providers
with at least one currently available catalog model** (it is derived from the
same non-empty groups). A catalog-driven entry point may therefore restrict
selection and submission to the advertised models, even though core routing is
unchanged.

#### session.canOpenWorkspacePath / session.openWorkspacePath / session.workspacePathApplications
```
args     {}                                      → value boolean
args     { request: { path, action?: 'reveal', application? } }
                                                 → value { opened: true }
args     { request: { path } }                   → value SessionWorkspacePathApplication[]
```
The opener hands the path to the host desktop; an empty path is
`gateway/bad-request`; abort is `gateway/cancelled`; opener failure is
`gateway/internal`. **0.1.7** adds `application?` (a registered application
identifier from `workspacePathApplications`, ignored for `reveal`; omission keeps
the operating-system default) and hardens the path first: it must resolve back to
the same host path through the composed filesystem, otherwise
`gateway/bad-request` `"Path has no verified Host path"` — a bare
`openWorkspacePath` no longer passes an arbitrary string to the native opener.

`session/workspacePathApplications` (new in 0.1.7) is a cold, non-activating
query for the serving desktop's current handlers of that file:
`SessionWorkspacePathApplication = { id, name, default: boolean, icon: string |
null }` (`icon` is a PNG/SVG data URL); it returns `[]` when native opening is
unavailable. Identifiers must be revalidated against the file's current handlers
before opening, because associations can change between the query and the open.

#### session.rename
```
args     { request: { sessionId, title: string } }
value    { title: string, seq: number }
```
Host normalization (strip OSC/CSI/control/direction characters, collapse
whitespace, truncate to a UTF-8 byte budget without splitting code points); an
empty result → `session/title-invalid`. A user rename **pins** the title (appends
a `session/title` with source=user, which later automatic generation no longer
overwrites). Subagent rejected.

#### session.fork
```
args     { request: { sessionId, atSeq? } }
value    { sessionId }                            // child session id
```
Cold-reads the source log and forks an **exact inclusive event prefix**.
**0.1.7** semantics: `atSeq` is the exact inclusive source event seq the child
inherits through (it must exist; `atSeq: 0` is valid), and an omitted `atSeq`
selects the **latest completed-turn prefix** boundary. When the cut leaves a turn
(or step) open, the seed's tail is closed with synthetic `forked` results plus
step/turn endings (`turn/end` reason `{kind:'forked'}`, §7.2), followed by the
tagged `session/end-seed` `{inherited:true}` marker; closed turns are preserved
unchanged. A boundary that does not exist, or an omitted `atSeq` with no
completed turn, is `session/fork-unavailable`. The child session inherits the
cwd, the latest model target, the `parentSessionId` lineage, and the seed prefix.
The client may increment the new session's title to "(n+1)" on its own (pure
client behavior).

#### session.prompt
```
args     { request: { requestId: string, sessionId,
                      mode: 'queue' | 'steer',
                      content: PromptContentPart[], clientTimeZone? } }
value    { accepted: true }                        // receipt only, no command slot
```
- `requestId` is **required**: client-generated, persisted on the final user
  message's source (the `user-rpc` source), used for optimistic echo and for
  reconciling the queue item's `rpcId`.
- `PromptContentPart` (three kinds since 0.1.5):
  - `{type:'text', text}`;
  - `{type:'image', mediaType, data: <base64>, name?}` (mediaType limited to
    png/jpeg/webp/gif); before enqueueing, the image bytes are promoted to a
    persistent reference;
  - `{type:'file', receiptId}` — first obtain a receipt via `fileUploads/upload`
    (§4.17) or `POST /api/session/uploadFileBinary`, then put the receipt into
    content. A receipt is valid only within the **same Session/Agent scope** and
    must be submitted together with that prompt's `requestId`.
- `mode`: `queue` → append as the next turn; `steer` → insert into the current
  turn (§8).
- All-whitespace content (an empty array or whitespace-only text) →
  `gateway/bad-request` `"prompt content must include non-whitespace text or an
  attachment"` (verified on 0.1.5-rc.1).
- `clientTimeZone` must be UTC or a valid IANA name, otherwise
  `session/invalid-time-zone`.
- The current model does not support images → `session/attachment-invalid`
  (`reason:'MODEL_DOES_NOT_SUPPORT_IMAGES'`); routing unavailable →
  `session/model-unavailable`.
- **No slash command semantics**: `/name` is intercepted by the client at the
  composer layer and goes through the `commands/*` Remote (§4.11); no command
  dispatch happens here.
- A subagent session is rejected (`session/agent-busy`) → use `subagents/prompt`.

#### session.attachment
```
args     { request: { sessionId, attachmentId } }
value    { attachment: ImageAttachmentRef, data: <base64> }
```
`ImageAttachmentRef = { attachmentId, mediaType, bytes, width, height, name?,
originalDimensions? }`. Before reading, it verifies that the session log really
references this image (otherwise `session/attachment-invalid`,
`reason:'ATTACHMENT_NOT_REFERENCED'`).

#### session.updateQueue
```
args     { request: { sessionId, itemId, action: { kind:'edit', content } |
                      { kind:'remove' } | { kind:'steer' } } }
value    { accepted: true }
```
Does not resume a cold Agent **at 0.1.6**; **0.1.7 resumes a cold Agent first**
(the commands layer routes it through the session lookup like `prompt`). edit
accepts only text content (`content: TextBlock[]`; non-text →
`session/attachment-invalid`; whitespace text/empty array → `gateway/bad-request`
`"queue edit content must include non-whitespace text"`, verified);
an item no longer queued → `session/queue-item-not-found`; `steer` is available
only for a **next-turn item while the agent is running**, otherwise
`session/steer-unavailable`. See §8 for details.

#### session.cancel
```
args     { request: { sessionId } }
value    { accepted: true }
```
Requires a live Agent (none → `session/not-found`); stops the current turn and
keeps the pending queue (resumed FIFO after settling). Subagent →
`subagents/interruptByParent`.

#### session.page
```
args     { request: { address: SessionAddress, throughSeq: number,
                      beforeSeq?, maxMessages?, turnWindow? } }
value    { records: SessionHistoryRecord[], hasMore: boolean }
```
Backward pagination aligned to message boundaries (one page = a whole number of
message records, never truncated mid-message). `address = {kind:'session',
sessionId} | {kind:'subagent', parentSessionId, childSessionId, mode}`; the
subagent `mode` is `'one-shot' | 'continuable' | 'unknown'` at 0.1.7 (a
diagnostic-only identity that cannot be matched to a live catalog row reads as
`'unknown'`).
`throughSeq` = the inclusive cursor of the follow opening snapshot (-1 = latest);
an omitted `beforeSeq` = start from the page at `throughSeq`. `maxMessages` is the
page budget (50 by default). **0.1.7** adds `turnWindow = { minMessages,
minTurns }`: stop at a `turn/start` once both a minimum number of append-origin
user/assistant messages and a minimum number of crossed Turn starts are reached
(`minMessages` must not exceed `maxMessages`; the partial Turn at `beforeSeq`
counts), unless `maxMessages` or history exhaustion wins first — the same option
is accepted by `session/follow` for its opening snapshot.
`SessionHistoryRecord = {type:'event', event}`
(0.1.5 has only this kind; the old `{type:'chunks'}` packing is gone, see §7.1).
A subagent address is validated against the corresponding restrictions (identity/
lineage mismatch → `subagent/*` error codes, see §5). Reading history never
activates the Agent.

#### session.follow (stream)
```
open     { args: { request: { address: SessionAddress, maxMessages?,
                               turnWindow?, assistantStream?: true } } }
frames   first = { type:'snapshot', header: SessionWireHeader, cursor,
                 records: SessionHistoryRecord[], hasMore,
                 projections: { asOfSeq, values },
                 assistantStream?: { revision, activeAttempt? } }
         then = { type:'event', event: SessionWireEvent } (gapless)
              | { type:'assistant-stream', frame } (only when opened with assistantStream)
```
- `SessionWireHeader = { version, id, createdAt, cwd?, parentSession?, isSeeded,
  origin?: 'subagent', delegationDepth?, agentPreset? }` (0.1.5: `seedLength` has
  been replaced by `isSeeded: boolean`; **0.1.7** bumps the format `version` to
  **4**, §7.1).
- The snapshot records = a message-aligned tail of at most maxMessages entries
  (pure `event` records); `cursor` = the seq the snapshot covers up to;
  `projections` is that session's projection baseline (§9).
- Subsequent live frames are bare `event` records; a skipped `seq` →
  `gateway/internal` ("skipped seq"). An ordinary session is promoted to active in
  the background once the snapshot has been sent (reading old pages does not);
  a subagent address never activates.
- `assistant/message.data.stream` is the complete stream of that attempt; if
  in-process deltas are not wanted during live (**dsh-emacs' choice**), just wait
  for `assistant/message` to arrive.

#### session.control (stream)
```
open     { args: {} }
frames   exactly one baseline per generation, then projection deltas (see §6.1)
```
Host-wide control plane. **Replaces** the 0.1.1-rc.2 mux frames `session/queue`,
`session/jobs`, `session/projection`. At 0.1.6 it carried queues, background jobs
and projections; **at 0.1.7 it carries projections only** — the queue is now read
from the `inbox` projection cell it still publishes (§6.1, §9), and background
jobs moved to the `job` namespace (§4.21).

#### session.projections (new in 0.1.7)
```
args     { request: { sessionId } }
value    SessionProjectionBaseline | null        // { asOfSeq, values } ; null = session not found
```
A cold, non-activating read of **all** registered projection cells for one
Session — the unary counterpart of the `session/control` baseline block and of
`session/follow`'s snapshot `projections`, for a client that holds no stream.
An empty `sessionId` is `gateway/bad-request`; when the Session exists but its
projection registry is unavailable the error is
`session/projections-unavailable`; a cancelled observation is
`gateway/cancelled`. A non-existent Session is **not** an error: the value is
`null`.

### 4.2 skills.list

```
args     { request: { sessionId } }
value    { skills: SkillEntry[] }
```
`SkillEntry = { name, description, whenToUse?, modelInvocable, path? }` (name is
referenced as `/name`; `path?` is the absolute `SKILL.md` path and is **new in
0.1.6** — it appears only when the mounted skill provider supplies one, so a
client must treat it as optional). Cold read: picks the directory view from the
session cwd + the `agentPreset` projection and lists only user-invocable skills.
**Invoking a skill has no dedicated wire**: it is just an ordinary
`session.prompt`/`commands.execute`, with the body injected by the skill tool
(those without `modelInvocable` appear only on the user surface).

### 4.3 fileReferences.list

```
args     { agentId, query: string }        // agent lookup → agentId; query is the path text after @/@"
value    FileReferenceCandidate[]          // [{ path, kind: 'file'|'directory' }]
```
Produces path candidates in the agent's cwd; a directory keeps completion open.
Cancellation follows the caller's signal.

### 4.4 workspace.*

`WorkspaceView = { workspaceId, path, title, sessionIds: SessionId[], createdAt,
updatedAt }` (createdAt/updatedAt are ISO-8601 strings; sessionIds are in manual
order). **There is no workspace/list unary method** — the list state comes from
the `workspace/follow` stream baseline.

| Endpoint | args | value | Errors |
|---|---|---|---|
| `workspace/create` | `{ request: { path } }` | `{ workspace, created }` | `workspace/invalid-path` (not an existing directory / not a directory) |
| `workspace/rename` | `{ request: { workspaceId, title } }` | `{ workspace }` | empty after trim → `gateway/bad-request`; `workspace/name-conflict`; unknown → `workspace/not-found` |
| `workspace/delete` | `{ request: { workspaceId } }` | `{ deleted: true }` | removes the registration only (directory/files/session logs untouched) |
| `workspace/insertBefore` | `{ request: { workspaceId, beforeWorkspaceId? } }` | `{ workspaceIds }` (full order) | `workspace/not-found` |
| `workspace/insertSessionBefore` | `{ request: { workspaceId, sessionId, beforeSessionId? } }` | `{ workspace }` | session/anchor not in that workspace → `workspace/move-invalid`; same position is idempotent |
| `workspace/archiveSession` | `{ request: { sessionId, stopActivity? } }` | `{ archivedSessionIds }` | neither live nor persisted → `session/not-found`; **0.1.7**: the Session still has running work (its own turn, a subagent descendant, an owned background job, an active schedule) → `workspace/session-active` **unless** `stopActivity: true`, which requests those stops (not awaited) before the durable archive write |
| `workspace/unarchiveSession` | `{ request: { sessionId } }` | `{ archivedSessionIds }` | **new in 0.1.6**: drops one id from the registry-global archive set; an id that is not archived is a no-op (idempotent), so a lost race resolves cleanly |
| `workspace/pinSession` | `{ request: { sessionId } }` | `{ pinnedSessionIds }` | **new in 0.1.7**: surfaces a known unarchived Session ahead of unpinned ones; the full set comes back, most recently pinned first |
| `workspace/unpinSession` | `{ request: { sessionId } }` | `{ pinnedSessionIds }` | **new in 0.1.7**: removes one pin without touching the saved Session order; idempotent |
| `workspace/initializeDefault` | `{}` | `{ workspace } \| undefined` | **new in 0.1.7; request args removed in 0.2.0**, first-use only: initializes or reuses the default Workspace (never renames or relocates an existing default) and creates no Session or message; `undefined` when first-use initialization is ineligible. The leaf directory is now fixed to `<system Documents>/deepseek-harness/default-workspace` and the stored initial title is that same automatic segment (browser consumers localize it for display); the old client-supplied `directoryName`/`title` and their blank/trim/separator `gateway/bad-request` validation are gone |

#### workspace.follow (stream)
```
open     { args: {} }
frames   first = { type:'baseline', value: { items: WorkspaceView[],
                                              archivedSessionIds: SessionId[],
                                              pinnedSessionIds: SessionId[] } }
         then = upsert { workspace } | remove { workspaceId }
              | order { workspaceIds } | archived { archivedSessionIds }
              | pinned { pinnedSessionIds }
```
The archive set shares its source with the `workspace/archiveSession` return
value; the pin set shares its source with `pinSession`/`unpinSession`. **0.1.7**
adds the baseline's `pinnedSessionIds` (registry-global, most recently pinned
first) and the `pinned` whole-set increment, so a reconnect baseline and a live
frame carry the same field name. The reconnect baseline is the baseline frame.

### 4.5 directoryPicker.*

The choice between local/browse backends is made by the deployment (the
controller only expresses the wire verbs). When the capability a verb requires
does not match, it rejects rather than approximating:
`directory-picker/unavailable` (details carry the current capability).

| Endpoint | args | value | Errors |
|---|---|---|---|
| `directoryPicker/pick` | `{}` | `string \| null` (cancel=null) | `gateway/cancelled`; requires the native capability |
| `directoryPicker/list` | `{ path? }` (default = home) | `DirectoryListing` | `directory-picker/unreadable` etc. |
| `directoryPicker/createDirectory` | `{ path, name }` (single-segment name) | `string` (absolute path of the new directory) | invalid/missing name → `gateway/bad-request`; `directory-picker/exists`, `directory-picker/create-failed` |

`DirectoryEntry = { name, path, hidden }`; `DirectoryListing = { path, home,
crumbs: DirectoryEntry[], entries: DirectoryEntry[], truncated }` (entries in
name order, including symlinks; truncated = the backend cut off at the
complete-result limit).

### 4.6 agentPresets.*

`AgentPresetRoster = { presets: AgentPresetRow[] }` (**0.2.0 removed the
`modeSelectionEnabled` member**); `AgentPresetRow = { id, isDefault, name?,
description?, broken? }`. A non-empty `broken` = currently unable to assemble a
session. id grammar `^[a-z0-9][a-z0-9-]*$`; the roster is sorted by `order`
(ascending, absent last) then id, and a row may additionally carry the
undeclared-at-the-type-level `order?: number`, which a client may read but must
not require.

**0.1.7 removed `trust`** from both the roster row and the read document, and
**deleted `agentPresets/copy` and `agentPresets/deletePreset`**: the namespace
has no write path at all, and the roster's `authorable` flag is gone with them. A
client that used `trust === 'system'` to pick a built-in label must key the label
on the id alone (which is what the web's own `presetDisplayText` does).

`modeSelectionEnabled` was **new (required) in 0.1.6** and is **deleted in
0.2.0**: the chooser is always enabled and the saved default always applies, so
there is no longer a state in which the picker is hidden or a stale saved choice
is ignored. A client must still take "the default" from the row whose
`isDefault` is set (the host resolves it), never from the saved setting.
dsh-emacs still declares the removed slot in `dsh-emacs-protocol.el`; it parses
as `nil`, and no business code consumes it (§0.5).

| Endpoint | args | value | Notes |
|---|---|---|---|
| `agentPresets/list` | `{}` | `AgentPresetRoster` | full roster incl. activation failures |
| `agentPresets/read` | `{ agentPreset }` | `AgentPresetDocument {agentPreset, content, name?, description?}` | reads the declared child-plugin list as entry-list YAML (`!!js` conditions included); unknown → `agent-preset/not-found`. **0.1.7 dropped `trust`** and renamed the declaring package |
| `agentPresets/select` | `{ agentId, agentPreset }` | `string` (the recorded preset id) | **only available for blank sessions** (no turns: turnBoundary has not opened a turn and lastTurn=0); a conversation already started → `agent-preset/locked`; serialized per session |

A blank Session that switches composition records the durable
`agent-preset/selected` event (`{agentPreset}`, §7.3), and the `agentPreset`
projection folds it over the creation header, so reconstruction reads the
projection rather than the header alone.

### 4.7 settings.*

`SettingsNamespaceView = { ns, autoGenerate, schema: <schemastery JSON>, value,
base?, user?, applies: 'live'|'restart', secrets: SettingsSecretView[],
revision: number }` (`autoGenerate` is **new in 0.1.7**).
- All outbound values are redacted: role('secret') fields never cross the wire;
  `SettingsSecretView = { path: string[], set: boolean }`.
- `revision` is a write CAS: carrying `expectedRevision` while the namespace has
  advanced → `settings/conflict` (details carry expected/actual).
- Calling with no provider → `gateway/internal` (or the corresponding
  `settings/*` code).
- **0.1.7**: `hasDocument` is now always `true` (the provider's `prepareDocument`
  is the sole document seam), and `canOpenAgentPresetDirectory` /
  `openAgentPresetDirectory` are **deleted** — preset authoring is no longer a
  settings surface (§4.6).

| Endpoint | args | value |
|---|---|---|
| `settings/describe` | `{}` | `{ writable, hasDocument: true, namespaces: SettingsNamespaceView[] }` |
| `settings/openSettingsDocument` | `{}` | `{ opened: true }` (materializes the document and hands it to the platform text opener) |
| `settings/update` | `{ ns, patch, expectedRevision? }` | `SettingsNamespaceView` |
| `settings/replace` | `{ ns, section, expectedRevision? }` | `SettingsNamespaceView` (`{}` = reset) |
| `settings/mutate` | `{ ns, ops: SettingsPathOpView[], expectedRevision? }` | `SettingsNamespaceView` |

Write errors (write paths map uniformly): schema/storage rejection →
`settings/rejected` (details carry ns); concurrent CAS → `settings/conflict`.
`SettingsPathOpView = {op:'set', path, value} | {op:'unset', path}`; an empty path
= the section root; `mutate` resolves relative to the **section as stored** (not
the caller's last read).

### 4.8 credentials.*

Values cross the wire only in the set direction; the read side gets a valueless
view. Reference-name grammar `^[A-Za-z_][A-Za-z0-9_]*$`; invalid →
`gateway/bad-request`. The namespace is mounted by `settings-controller`'s
`CredentialsController` (registered alongside `settings`).

| Endpoint | args | value | Errors |
|---|---|---|---|
| `credentials/describe` | `{ refs: string[] }` (≤64) | `{ <ref>: { configured, source?, writable } }` | invalid name/empty → `gateway/bad-request`; no provider → `gateway/internal` |
| `credentials/set` | `{ ref, value }` (value non-empty) | void | read-only layer shadowing → `credential/rejected` |
| `credentials/unset` | `{ ref }` | void | idempotent; same as above |

Code-spelling note: the write rejection is **`credential/rejected`** (singular
credential, details carry `ref`), not `credentials/rejected`.

### 4.9 llm.*

| Endpoint | args | value | Notes |
|---|---|---|---|
| `llm/listProviders` | `{}` | `LlmProviderInfo[]` (`{id, name}`) | routes with a registered adapter |
| `llm/listConfigurableProviders` | `{}` | `LlmConfigurableProvider[]` | `{provider, displayName, settingsNs, settingsPath: string[], declared?}` |
| `llm/discoverModels` | `{ settingsNs, request: {provider?, baseURL?, api?, apiKey?} }` | `LlmDiscoveredModel[]` (`{id, name?, contextWindow?, maxTokens?}`) | draft route, not stored; apiKey is accepted but never stored/returned; failure → `llm/model-discovery-rejected` |

The settings surface's **model list** lives in `session/modelCatalog` (§4.1), not
in llm — the provider catalog only describes configurable providers.

### 4.10 goals.*

typert namespace `goals`. The read side mostly relies on the `goal` session
projection (§9); 0.1.5 adds `goals/get` as an explicit one-shot read. All verbs go
through the `agentId` lookup to a live Agent, and all except `create` carry a CAS
`ref` (a revision mismatch is rejected). `GoalRef = {id, revision}`;
`GoalView = {id, revision, objective, phase:
'active'|'paused'|'blocked'|'complete', blockedReason?: {code,message},
maxGoalRounds, roundsStarted, createdAt, updatedAt, activation:
'armed'|'disarmed'}`.

| Endpoint | args | value |
|---|---|---|
| `goals/get` | `{ agentId }` | `GoalView \| undefined` (no current goal = value omitted) |
| `goals/create` | `{ agentId, request: { objective, maxGoalRounds? } }` | `{ ref }` |
| `goals/edit` | `{ agentId, ref, request: { objective?, maxGoalRounds? } }` | `GoalView` (at least one item changed) |
| `goals/pause` | `{ agentId, ref }` | `GoalView` |
| `goals/resume` | `{ agentId, ref }` | `GoalView` |
| `goals/complete` | `{ agentId, ref }` | `GoalView` |
| `goals/clear` | `{ agentId, ref }` | `GoalRef` (tombstone; a bare ref, not wrapped as `{ref}`) |

create reports a business error when a non-complete goal already exists;
`maxGoalRounds` defaults to the deployment default (256). `activation`
(armed/disarmed) is in-process continuation eligibility and is not persisted.
> Error-shape note: the goals domain throws `GoalError` (a plain Error subclass,
> not a RemoteError, and that package does not merge RemoteErrorDetailsMap), so a
> failed goal mutation currently folds into `gateway/internal` on the wire (the
> message preserves the original text), and the client cannot use the code to
> distinguish already-exists/stale-revision etc. The client should read the
> current state from the `goal` projection (§9) and use the returned/projected
> `ref` for CAS.

### 4.11 commands.* (slash command registry — already used by dsh-emacs)

| Endpoint | args | value |
|---|---|---|
| `commands/list` | `{ agentId }` | `CommandDescriptor[]` (name ascending) |
| `commands/execute` | `{ agentId, line: string, submittedAttachments: CommandSubmitAttachment[] }` | `CommandExecution` or undefined (admission miss) |

- `CommandDescriptor = { name, description, input?: { hint, attachments?: boolean },
  definitionId? }` (the 0.1.5 field name; 0.1.2 had `input.images`).
  `definitionId?` is **new in 0.1.6**: a stable plugin-owned identity
  (`CommandDefinitionId`) that survives a rename or copy change, present only for
  definitions that opt in; a client may use it to pair a command with its own
  behavior, but must not require it.
- `line` is the complete command line (including the leading `/`);
  `submittedAttachments` is a required field (no attachments = `[]`). **Renamed in
  0.1.5**: 0.1.2 called it `images: EncodedImageAttachment[]`; now each item is
  `{type:'image', …EncodedImageAttachment}` or `{type:'file', receiptId}` (§4.17).
- `CommandExecution = { commandId, result: { kind:'success', text?, sourceEventSeq? }
  | { kind:'error', text } }`.
- Once admitted, it records `command/run` + `command/done` session events (outside
  the model surface); an admission miss is not logged. Attachments are allowed
  only when the command declares `input.attachments: true`, otherwise an `error`
  result (settling `command/done` first). Registration/deregistration emits the
  host event `commands/change` (§6.2 emit frame).
- `input.images` (the 0.1.2 field) has been superseded by `input.attachments`.

### 4.12 messageFeedback.*

Read-modify-write of a session sidecar file. All three endpoints use a **single
`request` parameter**, and their return values carry their own `{ok:…}`
discriminant (not envelope errors; envelope errors are reserved for
transport/framework problems):

| Endpoint | args (inside request) | value |
|---|---|---|
| `messageFeedback/list` | `{ sessionId }` | `{ ok: true, value: { items } }` or `{ ok: false, error: { code: 'session-not-found' } }` |
| `messageFeedback/put` | `{ sessionId, messageId, rating: 'positive'\|'negative', note?, ifVersion: Version\|null }` | `{ ok: true, value: MessageFeedbackItem }` or `{ ok: false, error: { code, … } }` |
| `messageFeedback/delete` | `{ sessionId, messageId, ifVersion }` | `{ ok: true, value: { absent: true } }` or `{ ok: false, error: … }` |

`MessageFeedbackItem = { messageId, rating, note?, version, createdAt, updatedAt }`;
business error codes: `session-not-found` / `target-not-found` (the message is not
an append-origin assistant message) / `version-conflict` (details carry current) /
note validation (`note-blank`/`note-too-large` etc.). `ifVersion` = optimistic
lock: passing `null` to put means "there must be no old item". Replaying the same
value = an idempotent no-op (the version does not change).

### 4.13 sessionReferenceResolver.candidates

```
args     { agentId, query: string }
value    SessionReferenceMentionCandidate[]
```
`SessionReferenceCandidate = { sessionId, label, displayTitle?, cwd?,
sameWorkspace, createdAt }`; each candidates entry also carries `mention` (the
`@[label](dsh-session:…)` hint text). Self is excluded, and its cwd participates
in sorting; `query` does a case-insensitive substring match against
sessionId/cwd/title/**displayTitle**. **0.1.7** adds `displayTitle?`: the
subagent-label-first presentation text, read from the same `title` + `subagent`
projection snapshot in one shot, and `mention` now prefers it over `label` — a
client that renders the mention verbatim needs no change, one that builds its own
label should prefer `displayTitle`. Sessions whose projections answer neither
still fall back to the session id.

### 4.14 subagents.* (Subagent Control)

| Endpoint | args | value | Notes |
|---|---|---|---|
| `subagents/list` | `{ parentSessionId }` | `SubagentCatalog` (`{ entries, parentAvailable }`) | entries elements: `{kind:'child', id, mode:'one-shot'\|'continuable', activity:'running'\|'inactive', hasChildren, label?}` (label optional for one-shot, required for continuable) or `{kind:'diagnostic', id, reason:'corrupt'\|'unsupported'\|'unavailable'}` |
| `subagents/prompt` | `{ request: { requestId, parentSessionId, childSessionId, mode:'continuable', content: PromptContentPart[], clientTimeZone? } }` | `{ messageId }` | delivered to the child session's FIFO inbox via the **exact live direct parent session** (delivery=queue; receipt on acceptance, independent of later execution); images are accepted and promoted first; time-zone/image validation as on the session surface |
| `subagents/interruptByParent` | `{ childSessionId, parentSessionId, mode: 'continuable' }` | `{ accepted: true }` | fire-and-return; target missing/idle/already finished = accepted |

Deep reads of `subagents/list` (history/follow/page) all go through the `address`
subagent variant of `session.*`
(`{kind:'subagent', parentSessionId, childSessionId, mode}`). Error codes
`subagent/not-found`, `subagent/unauthorized`, `subagent/parent-unavailable`,
`subagent/not-resumable`, `subagent/delivery-unavailable`,
`subagent/projections-unavailable`, `subagent/attachment-invalid`,
`subagent/invalid-time-zone` (details in §5). Note that on the read side a
subagent identity also has the projection keys `subagent` / `subagentTiming`
(§9).

### 4.15 pluginInventory.list

```
args     {}
value    PluginInventorySnapshot
```
`{ entries: [{ entryId, moduleName, meta?, enabled, fiberPhase: 'pending'|'loading'|
'active'|'failed'|'unloading'|null }], agentPresets?: [{id, name?, isDefault,
broken?, rows: [{entryId, moduleName, meta?, enabled: bool|'conditional', condition?,
fiberPhase}]}], managementAvailable? }` — Loader live state; when an agent-preset
roster exists, the composition rows of each preset are attached (the host's
actual list of running model plugins). **0.1.7** drops the group's `trust`, adds
`meta?` (local package display metadata, present whether or not the entry is
enabled) on both entry kinds, and adds `managementAvailable?` (the Host exposes
persistent current-profile management through the new `pluginManager` namespace,
§4.23). The other face of plugin dynamic loading/inspection is
`dynamicCordisRunner` (cordis-host-runner: `runHostHalf`, `stopFromPanel`,
`undefineFromPanel`, `invoke`, `inventory`, `getClientCode`, `resolveRequestRun`,
`settleUserRun`, `reportRenderFailure`, `reportClientGuardFailure` etc., used by
web panel extensions; dsh-emacs does not need it for now).

### 4.16 workspaceFiles.* (new in 0.1.5: workspace file reading)

Host side `ctx.workspaceFiles`; reads workspace files for the "browser is not on
the host machine" scenario. Design points: **the read permission of the file
methods (`read`/`readBytes`/`stat`/`changes`) inherits from the Session's
filesystem backend** (it may go outside the workspace as long as the backend
allows it), while the observation surface of `list` and directory `changes` is
locked inside the workspace root.

| Endpoint | args | value |
|---|---|---|
| `workspaceFiles/read` | `{ workspaceFileScopeId, path, range: {offset?, limit?} }` | `WorkspaceFileText` (line window; `offset` is 1-based, default 1, limit `maxLines`=5000) |
| `workspaceFiles/readBytes` | `{ workspaceFileScopeId, path, options: { range?: {offset?, length?}, baseFile? } }` | `WorkspaceFileBytes` (one byte window, or the whole file under `maxFileBytes`=32 MiB when `range` is omitted; default range limit `maxBytes`=2 MiB) |
| `workspaceFiles/stat` | `{ workspaceFileScopeId, path }` | `WorkspaceFileStat` |
| `workspaceFiles/list` | `{ workspaceFileScopeId, path }` | `WorkspaceDirectoryListing` (`path` is a workspace-relative path; **listing the root requires an explicit `""`**; a missing field → `gateway/bad-request` `"path is required"`; limit `maxEntries`=2000) |
| `workspaceFiles/changes` (stream) | `{ workspaceFileScopeId, path }` | `{kind:'ready'}` → `{kind:'change', change}` (`{absolutePath, version}` or `{absolutePath, absent:true}`) |

- **0.2.0 final-link listing**: `list` accepts a final symlink or Windows
  junction and lists through the directory it resolves to (the entry is
  `stat`ed and must resolve to a directory, otherwise it stays
  `workspace-file/not-directory`). `read` keeps its own no-follow gate on the
  final component, so a symlinked **file** is not silently followed.
- **0.1.7 collapses the byte methods**: `readAll` (whole file) and `readRelated`
  (resolve relative to a sibling) are **deleted**. `readBytes` now takes a single
  `options` object: omit `range` for the whole-file read (the old `readAll`), and
  set `baseFile` to resolve a relative `path` from that file's directory (the old
  `readRelated`). A `path` that is absolute or carries a URL scheme while
  `baseFile` is set is `gateway/bad-request`.
- **Lookup parameter note**: the method's first parameter `workspaceFileScope` is
  called `workspaceFileScopeId` on the wire, and its value is the **sessionId
  string** (the Host resolves `{sessionId, workspaceRoot}` itself from the live
  header / persistent header; cold sessions resolve too). The client never
  supplies the root itself.
- Two path vocabularies: `read`/`readBytes`/`stat`/`changes` use **absolute paths
  or paths relative to the workspace root** in the execution world; `list` uses
  **workspace-relative paths**.
- `WorkspaceFileStat = {absolutePath, version, bytes?}` — `version` is an opaque
  freshness token (do not parse it); together with `changes` it answers "is the
  copy of this file I hold stale?".
- `WorkspaceFileText = Stat + {offset, text, lines, eof}`;
  `WorkspaceFileBytes = Stat + {offset, data, eof}`;
  `WorkspaceDirectoryEntry = {name, type:'file'|'directory'|'other', size?}`;
  `WorkspaceDirectoryListing = {path, entries, truncated}`.
- **`data` is raw bytes out of process, not base64 (0.1.7)**. The value type is
  `WorkspaceFileBytes<Uint8Array>`; the host's result encoder moves every
  `Uint8Array` out of the JSON metadata into a **`ConnectionRpcAttachment`** and
  puts `null` at its path. An HTTP client therefore receives a
  `multipart/form-data` response whose `metadata` part is the ordinary
  `server-response` JSON (with `attachments: [{path, codec:'bytes', part}]`) and
  whose `bytes-<n>` parts carry the octets. Streams never carry attachments — only
  unary results do. A client that wants bytes must parse the multipart body;
  reading only the JSON metadata yields `null` for `data`. (Through 0.1.6 `data`
  was a base64 string inside the JSON.)
- **0.1.7 `changes` semantics**: the watch is now **per target** (a required
  `path`, not the whole scope) and its `change` frames report the target's
  **current** metadata after an invalidation (a fresh `version`, or `absent`), not
  an observation of some filesystem operation. A file consumer may ignore a
  version it already holds; a directory consumer must relist on every frame,
  because a child's metadata can change without the directory version changing.
  New error: `workspace-file/watch-unsupported` (the provider cannot initialize a
  watch for that target).
- Error codes: `workspace-file/not-found`, `workspace-file/outside-workspace`,
  `workspace-file/too-large`, `workspace-file/not-text`,
  `workspace-file/not-regular-file`, `workspace-file/not-directory` (each with
  `path` in details), plus `workspace-file/watch-unsupported` (0.1.7).
- **Value for dsh-emacs**: previewing files produced by a session (including
  large-file pagination, binaries, images) no longer requires a local
  same-machine path, and is not subject to `/api/file`'s "absolute path +
  locally readable" restriction. dsh-emacs does not call this namespace today, so
  the 0.1.7 byte-encoding change does not affect it; a future binary preview must
  handle the multipart form above.
- Measured (0.1.5-rc.1 live service): `workspaceFiles/stat` works directly with a
  workspace-relative path (such as `"README.md"`) and returns `absolutePath` +
  `version` + `bytes`; `list` must carry `path` (`""` = root).

### 4.17 fileUploads.upload (new in 0.1.5: attachment upload)

`packages/client/file-upload`, namespace `fileUploads`. It turns file bytes into a
one-time **receipt**, which is then submitted with a prompt / command (§4.1's
`{type:'file', receiptId}`, §4.11's `CommandSubmitAttachment`).

```
args     { agentId, request: { data: <base64>, name? } }
value    { receiptId, file: FileAttachmentRef }
```

- `agentId` is a lookup parameter: **it must be an Agent scope that has that
  Session**; a cold session is resumed by the service's own resolver.
- A receipt is valid only within the receiving Agent's scope and is bound to the
  prompt/command that submits it (a failed submission rolls back the binding).
- Large files use the HTTP streaming route to save memory:
  `POST /api/session/uploadFileBinary?sessionId=<id>[&name=<leaf>]`,
  `content-type: application/octet-stream`, with the raw bytes as the body; the
  response body is `{ok:true, value:{receiptId, file}}` or
  `{ok:false, error:{code,message,details}}` (the HTTP status is still 200).
  Missing `sessionId` → 400, mismatched content-type → 415.

### 4.18 sessionFeedback.record (new in 0.1.5: session-level feedback)

`packages/feedback/command-feedback`. The Web `/feedback` slash command and the
message Dislike popup share this one write entry point; it records a log-only
`feedback/record` event.

```
args     { request: { sessionId, text?, category? } }
value    { ok: true, value: { recorded: true } }
       | { ok: false, error: { code: 'session-not-found', sessionId } }
```

`category` ∈ `task-result` | `instruction-following` | `product-interaction` |
`service-stability` | `resource-cost` | `security-privacy-permission` | `other`;
a whitespace `text` is treated as omitted (both omitted is also allowed — "please
have a human look at this session" is itself a signal). It shares its source with
the in-session `feedback/record` event; note that the return value carries its own
`{ok:…}` discriminant, not an envelope error (the same style as
`messageFeedback/*`).

### 4.19 permissionPresets.catalog (new in 0.1.6: process-level catalog)

`packages/interaction/permission-presets`, namespace `permissionPresets`.

```
args     {}
value    { options: [{ value, name, description? }],
           defaultOptions: [{ value, name, description? }],   // new in 0.1.7
           defaultPreset: string }                            // new in 0.1.7
```

- The catalog is **process-level** (it changes as plugins contribute live
  presets, independently of any Session log), which is why 0.1.6 split it out of
  the `permissions` projection; that projection now carries only the Session's
  durable current value (§9). A permission control pairs the two: options from
  this Remote, current value from the projection.
- **0.1.7** adds `defaultOptions` (the configured presets eligible as a
  future-session default — the same `PresetOption` shape, without the derived
  `auto` entry) and `defaultPreset` (the effective default when the deployment's
  `Config.defaultPreset` is omitted). The configured default moved from a
  settings-namespace section to a volatile Host config field, so this Remote is
  now its only read path.
- **0.2.0**: the derived `auto` preset's fixed bundle now uses approval policy
  **`ask`** (it was `never`), and a still-selected `auto` also matches a `never`
  approval knob, so a delegated child that pins `never` keeps a final reviewer
  denial. The catalog's option set and value shape are unchanged.
- `option.value` is a configured preset key, or `auto` while the experimental
  Auto-review integration is live. The derived value `custom` is **not** an
  option: it appears only as the projection's `currentValue` when the effective
  sandbox/approval knobs match no available preset, and is then not a switch
  target.
- The catalog changes when the auto integration registers/unregisters, announced
  by the `$events` emit `permission-presets/catalog-changed` (payload-free — a
  consumer re-reads the complete catalog, §6.2).
- dsh-emacs **does** consume both faces: `dsh-emacs-set-permission` reads this
  Remote for the picker, and the `permissions` projection's `currentValue` drives
  the mode-line permission segment. The `permission-presets/catalog-changed`
  emit re-reads the catalog (§6.2).

### 4.20 terminal.* (new in 0.1.6: Session-owned user terminals)

`packages/api/terminal-controller`, namespace `terminal`. A Session-owned,
Host-lifetime interactive shell, entirely separate from the Agent's own terminal
tool registry. **dsh-emacs does not use this namespace** — it is recorded for
completeness.

| Endpoint | args | value |
|---|---|---|
| `terminal/environment` | `{ agentId }` | `TerminalEnvironment = { cwd, maxInputBytes, maxCols, maxRows, scrollback }` |
| `terminal/shells` | `{ agentId }` | `TerminalShell[] = [{ path, args, name }]` (the configured/system default first) |
| `terminal/list` | `{ sessionId }` | `WebTerminalInfo[]` (cold-safe: no Agent resume; `[]` when the Session owns none) |
| `terminal/create` | `{ agentId, request: { id, cols, rows, shellPath? } }` | `WebTerminalInfo` (idempotent for an open `id`; `id`/`attachmentId` match `^[\w-]{1,128}$`) |
| `terminal/retain` (stream, **new in 0.1.7**) | `{ sessionId, id }` | one `{type:'retained'}` acknowledgement, then an open-window lifetime; no screen and no input control |
| `terminal/follow` (stream) | `{ agentId, id, attachmentId }` | `snapshot` `{sequence, screen, info}` → `output` `{sequence, data}` / `state` `{info}` |
| `terminal/write` | `{ agentId, id, attachmentId, data }` | void (raw UTF-8 input, including control characters) |
| `terminal/resize` | `{ agentId, id, attachmentId, cols, rows }` | void |
| `terminal/rename` | `{ agentId, id, title }` | void (1–120 chars after trim) |
| `terminal/close` | `{ agentId, id }` | void (closes the identity to future creation; repeated closes succeed) |

- `WebTerminalInfo = { id, title, shell, cwd, cols, rows, state:
  'running'|'exited'|'failed', exitCode: number|null, error?, controllerId? }`.
- `agentId` is the ordinary Agent lookup parameter (a cold session resolves
  through the Gateway); `sessionId` on `list`/`retain` is the displayed Session
  identity and never activates. Every attachment begins with a complete bounded
  screen (`snapshot`) before ordered output.
- **0.2.0 shell discovery** de-duplicates by **executable name**
  (case-insensitive, `.exe` stripped) rather than by full path, keeping the
  earliest entry per name with the default first. A system whose PATH resolves
  the default through another directory (`/usr/bin/bash` for `/bin/bash` on
  merged-`/usr` systems) therefore lists each shell once. `TerminalShell` is
  unchanged (`{ path, args, name }`).
- **0.1.7 semantics change**: terminals are no longer confined by the Session's
  sandbox mode and no longer consult `sandboxPolicy` — they are **Session-owned
  user terminals running with the execution environment's own system-user
  permissions**, and `environment.cwd` is the session header's `cwd` (falling back
  to the sandbox workspace root) rather than the resolved sandbox workspace root.
  The 0.1.6 internal guard that made a `sandbox/mode` change fail while the
  Session owned terminals is removed with the confinement. An idle unattended
  terminal is still reclaimed after `unattendedTimeoutMs` (default 2 h) without
  window holds; `terminal/retain` is the hold that keeps a window's terminal
  alive without showing its screen.
- Error codes: `terminal/limit-reached` (`{ limit }`, from `create` when the
  per-Session quota is full), `terminal/control-unavailable`
  (`{ reason: 'read-only'|'not-running' }`, when write/resize is refused without
  invalidating the attachment) and — **new in 0.1.7** — `terminal/unavailable`
  (`{}`, when the identity is missing or has begun process cleanup, including a
  `follow`/`retain` for a closed terminal); invalid identities/limits fold into
  `gateway/*`.

### 4.21 job.* (new in 0.1.7: background-job roster and output)

`packages/api/job-controller`, namespace `job`. This is the replacement for the
`session/control` `jobs` record and `jobs` frames that 0.1.6 carried (§0.4), so it
is the **only** background-job surface at 0.1.7. dsh-emacs consumes all three
verbs (`dsh-emacs-jobs.el`, shipped in 0.6.0): a `job/list` stream per followed
chat buffer drives its roster mirror and the mode line's `[J2]` badge, `C-c C-j`
lists the roster, `RET` opens a job's `job/follow` output in a read-only buffer,
and `k` sends `job/kill` (armed by a second press).

| Endpoint | args | value |
|---|---|---|
| `job/list` (stream) | `{ request: { sessionId } }` | whole-set frames `{type:'rows', jobs: JobView[]}`: one on open, then one after each coalesced lifecycle burst |
| `job/follow` (stream) | `{ request: { sessionId?, jobId, from? } }` | `opened {job, from}` → coalesced `output {chunks, next, lossy?}` → terminal `status {job}` |
| `job/kill` | `{ request: { sessionId, jobId } }` | `{ outcome: 'requested' \| 'already-finished' }` |

- The visible set is the addressed session's own jobs plus every unowned job.
  `sessionId` is a fenced read (`kill` and `follow` reject a job that session
  cannot see); `job/follow` may omit it for an unowned job, which any caller may
  observe.
- `job/list` has no natural end — the carrier closes it. `job/follow` closes
  normally after the terminal `status`, once the retained ring is drained. Job
  output reads are non-consuming: the model-facing cursor and notice state never
  observe them.
- `from` / `next` are absolute byte offsets into the job's retained output ring;
  `lossy: true` on an `output` frame means the bytes between the requested offset
  and the delivered chunks were already evicted.
- `JobView` / `JobChunk` are the projection and chunk types from
  `@deepseek-ai/dsh-jobs/view` (`opened`/`status` carry the job projection,
  including its `output.earliest` / `output.total`).
- Error: `job/not-found` (`{ sessionId, jobId }`) from `kill` when the session's
  list no longer carries a killable row — an unknown job and another session's
  job get the same code. `kill` records `cancelled by the user` as the reason, so
  the owning agent still receives the completion notice.

### 4.22 account.* (new in 0.1.7: Platform account)

`packages/api/account-controller`, namespace `account`. Mounted only when the
deployment composes the `deepseekAccount` provider; **no credential payload ever
crosses it** (that is the separate `credentials` namespace, §4.8).

| Endpoint | args | value |
|---|---|---|
| `account/getState` | `{}` | `AccountView` |
| `account/getProfile` | `{ client }` | `AccountDetails['profile'] \| null` |
| `account/getBalance` | `{ client }` | `AccountDetails['balance'] \| null` |
| `account/getUnnotifiedBonuses` (**new in 0.2.0**) | `{ client }` | `AccountBonusBatch \| null` |
| `account/ackBonusNotified` (**new in 0.2.0**) | `{ accountId, orderId, client }` | `boolean` |
| `account/startSignIn` | `{ client, callbackOrigin, loginSource: 'web'\|'desktop' }` | `AccountView` |
| `account/cancelSignIn` | `{ attemptId }` | `AccountView` |
| `account/signOut` | `{ client }` | `AccountView` |
| `account/hasRunningAccountTasks` (**new in 0.2.0**) | `{}` | `boolean` |
| `account/watch` (stream) | `{}` | initial `AccountView` snapshot, then changes |
| `account/watchExpiry` (stream, **new in 0.2.0**) | `{}` | `'session-expired'` per credential-expiry notification; no replay of prior notifications |

- **0.2.0 `client` metadata**: every operation that reaches Platform (and every
  operation that captures request identity) takes
  `AccountClientMetadata = { version: string, locale: string,
  timezoneOffsetSeconds: number }` — the requesting UI's version, active
  language (only its primary subtag selects the Platform wire locale) and UTC
  offset. It is **required positional `args`**, not nested under `request`:
  `getProfile` → `{ args: { client: {…} } }`, `ackBonusNotified` →
  `{ args: { accountId, orderId, client } }`, `startSignIn` →
  `{ args: { client, callbackOrigin, loginSource } }`. The removed `locale`
  parameter of `startSignIn` is `client.locale`; a joined attempt keeps its
  original identity. `getState`, `cancelSignIn` and `watch` do **not** take it.
- `AccountView = { status: 'signed-out'|'credential-stored', links: { usageUrl,
  topUpUrl }, attempt: SignInAttemptView | null }`; `credential-stored` is not a
  claim that the server validated the token.
- `SignInAttemptView = { id, phase: 'initializing'|'waiting-browser'|'exchanging'|
  'committing'|'succeeded'|'cancelled'|'expired'|'failed', authorizeUrl?,
  expiresAt?, errorCode? }` with `errorCode` ∈
  `network`|`protocol`|`expired`|`storage`; `attemptId` is that attempt's `id`.
- `AccountDetails` settles `profile` and `balance` independently, each
  `{status:'ready', value}` or `{status:'failed'}`; `getProfile`/`getBalance`
  return `null` when the account grant is absent or changed. Wallet balances are
  decimal strings (`{currency: 'CNY'|'USD', balance}`);
  `balance.bonusWallets` carries bonus balances separately.
- **Bonuses (0.2.0)**: `AccountBonusBatch = { accountId, bonuses:
  AccountBonusNotification[] }` (Platform order) with
  `AccountBonusNotification = { orderId, campaign, amount, currency, grantedAt,
  expiresAt, message }` — `message` is server-localized display text and
  `amount` is the granted amount, never the remaining balance.
  `getUnnotifiedBonuses` returns `null` when the grant is absent/changed;
  `ackBonusNotified` returns `true` once Platform records the acknowledgement and
  `false` when signed out or the account changed (a different current account is
  never acknowledged).
- `hasRunningAccountTasks()` reports whether any running Agent task has its latest
  request on the account route (used to warn before sign-out).
- `watchExpiry` subscribes without replaying prior notifications and yields
  `'session-expired'` while subscribed; the same condition is also forwarded as
  the `$events` emit `deepseek-account/session-expired` (§6.2).
- `signOut` removes the local grant and revokes it through Platform in the
  background (the captured `client` supplies the retry headers), without deleting
  API keys.

### 4.23 pluginManager.* / pluginRegistryProbe.* / officeToPdf.* (new in 0.1.7)

Three more namespaces join the client wiring at 0.1.7; **dsh-emacs uses none of
them**.

- `pluginManager` (`packages/boot/plugin-manager`) — persistent current-profile
  management: `listVersionExemptions`, `setVersionExemption`, `listPlugins`,
  `listBundles`, `registries`, `inspect`, `setPluginEnabled`, `setBundleEnabled`,
  `installBundle`, `waitForInstall`, `cancelInstall`, `removeBundle`. Mutating
  verbs return a `ChangeResult`; a bundle install is awaited by
  `waitForInstall(requestId)` and aborted by `cancelInstall(requestId)`. This is
  also the producer of the three `plugin-manager/*` host events now forwarded on
  `$events` (§6.2) and the reason `pluginInventory` can report
  `managementAvailable` (§4.15).
- `pluginRegistryProbe` (`packages/client/ui-plugin-manager`) — one unary
  `pluginRegistryProbe/fastest` → `string | null` (the fastest reachable
  registry).
- `officeToPdf` (`packages/document/office-to-pdf`) — `officeToPdf/render`
  (unary, `(workspaceFileScope, path, priority)`) and `officeToPdf/generation`
  (stream) for converting Office documents to PDF.

### 4.24 schedule.* (new in 0.2.0: Session reminders)

`packages/schedule/schedule`, namespace `schedule`. Reminders already existed at
0.1.7 (the `schedule` projection and the durable `schedule/change` event), but
0.2.0 is the first round with a Remote surface for them: named tasks
(`title`, ≤120 chars, required on new records) and the added `daily` / `weekly`
/ `cron` rule kinds (`every`'s minimum interval drops from 5 minutes to 1).

The service rides the **optional** `@deepseek-ai/dsh-experimental-schedule-bundle`,
which the installation ships switched off (a default profile mounts neither this
namespace nor the `schedule` projection). All verbs are Session-bound and none
resumes an Agent.

| Endpoint | args | value |
|---|---|---|
| `schedule/list` | `{ request: { sessionId } }` | `ScheduleRecord[]` (active tasks bound to that Session, storage order; does not resume the Agent) |
| `schedule/catalog` | `{}` | `ScheduleCatalogEntry[]` (every active and inactive Host reminder with its `sessionId`/`status`, `scheduledAt` ascending then id) |
| `schedule/history` | `{ request: { sessionId, id, limit, before? } }` | `ScheduleDeliveryHistoryResult` (newest-first inbox deliveries in append order; `limit` must be 1–100) |
| `schedule/delete` | `{ request: { sessionId, id } }` | `{ id, deleted: true }` or `{ id, deleted: false, code: 'schedule_not_found' }` |
| `schedule/update` | `{ request: { sessionId, id, expected, change?, title?, prompt? } }` | `ScheduleUpdateResult` (CAS against the complete observed record; a timing edit may switch recurrence kind) |

- `ScheduleCatalogEntry = ScheduleRecord & { sessionId, status:
  'active'|'inactive', lastDelivery?: ScheduleDeliveryReceipt }`;
  `ScheduleDeliveryReceipt = { scheduledAt, deliveredAt, messageId }`.
- Timing shapes: `after {afterSeconds}`, `at {scheduledAt}`,
  `every {everySeconds, scheduledAt}`, and the 0.2.0 wall-clock kinds
  `daily`/`weekly`/`cron` (`{…, timeZone, scheduledAt}`; local `time` is
  `HH:mm:ss[.SSS]`, weekdays are ISO 1–7, cron is five fields). Legacy records
  without `title` still read.
- Non-mutating misses are **value results** (`schedule_not_found`,
  `schedule_ended`, `schedule_conflict`, `delivery_cursor_not_found`), not
  envelope errors; a model-supplied rule that cannot become a record throws
  `ScheduleInputError` (codes `invalid_prompt`, `invalid_selector`,
  `invalid_rule`, `invalid_time_zone`, `not_future`, `time_out_of_range`,
  `frequency_too_high`). That class is a plain `Error` subclass, so on the wire
  it folds into `gateway/internal` with its message preserved (the same shape as
  `GoalError`, §4.10). `schedule/history` also returns the Host's retention
  bounds (`{days, records}`) and, when older records remain, the `nextBefore`
  message cursor.
- Each mutation writes a `schedule/change` session event and emits the
  payload-free host event `schedule/changed` (§6.2). dsh-emacs calls none of it.

### 4.25 userQuestions.* (new in 0.2.0: timed question answers)

`packages/interaction/user-questions`, namespace `userQuestions`. The
`ask_user_question` tool gained a `timed` mode whose foreground wait can expire
while the question stays answerable; this namespace lets a Client answer such a
**continued** question and hold a live countdown. The blocking legacy path still
uses the `user-questions/request` waterfall + `$events/result` (§3.3) and is
unchanged; a timed call adds an optional `wait` to that same waterfall and, once
continued, is answered here instead. The end-to-end recipe is §11.1.

| Endpoint | args | value |
|---|---|---|
| `userQuestions/answer` | `{ agentId, callId, answer }` | `boolean` (whether the question was still `continued`) |
| `userQuestions/attachWait` (stream) | `{ agentId, callId }` | `{ remainingMs: number }` — one host-computed remaining duration, then no frames once the wait ends (empty when the call has no foreground wait) |

- `agentId` is the ordinary lookup parameter and must resolve to the **exact
  live root Agent**; a delegated child is rejected (`DELEGATED_CALLER`), as is a
  call whose agent is not live (`CALLER_NOT_LIVE`).
- `answer = { answers: AskUserQuestionAnswerItem[] }`, each item
  `{ id, selected: string[], custom? }`. The batch must name each question of
  the call exactly once (`BAD_ANSWER`), and a reply already queued →
  `REPLY_QUEUED`. The accepted answer is steered into the Agent as a
  `user/message` whose source is `user-question-reply` (`{kind, callId,
  outcome:'answered'}`, §7.2); that message is what closes the question in the
  `userQuestions` projection (§9). Both rejections above are `UserQuestionError`
  codes (`extends HarnessError`, **not** `RemoteError`), so on the wire the
  `code` is `gateway/internal` and only the message survives — a client cannot
  route on `DELEGATED_CALLER` / `CALLER_NOT_LIVE` / `BAD_ANSWER` / `REPLY_QUEUED`.
- dsh-emacs **does** call both verbs (postmortem/073): while a timed question
  is being read it holds `userQuestions/attachWait` so the window cannot expire
  mid-prompt, and `M-x dsh-emacs-answer-question` submits a `continued` call
  through `userQuestions/answer`. The `wait` field of the request (§3.3) is how
  it learns the call id; `userQuestions/attachWait` for a `wait` without
  `timed` (the indefinite form) yields no frames and is not called.

### 4.26 productAnalytics.* (new in 0.2.0: Desktop analytics)

`packages/client/product-analytics`, namespace `productAnalytics`. Contributed
by the shared Remote assembly, but the host service is composed only by the
**Desktop** app, so an ordinary Web host does not claim these endpoints.
dsh-emacs does not use it.

| Endpoint | args | value |
|---|---|---|
| `productAnalytics/enabled` | `{}` | `boolean` (whether this Host currently accepts Desktop analytics) |
| `productAnalytics/watchPolicy` (stream) | `{}` | `boolean` policy values initially and after live configuration edits |
| `productAnalytics/report` | `{ event: ProductEvent }` | void |

- `ProductEvent = { eventName, timestamp, attributes }`; `eventName` is a closed
  Desktop event name (`desktop_app_launch`, `send_button_click`, `model_switch`,
  `context_compression`, …) and `attributes` carries that event's selected
  fields only. No message content or credential crosses it, and submission is
  fire-and-forget (no delivery acknowledgement); a disabled instance neither
  inspects identity nor accepts events.

---

## 5. Error Model

Unified error body: `{ code, message, details }`, with `details` required (`{}`
when there is no content). `code` is a closed-set discriminant field, prefixed by
the owning namespace; each business package uses `declare module
'@deepseek-ai/dsh-typert-protocol' { interface RemoteErrorDetailsMap … }` to
declare its own codes and details shapes. Unclassified exceptions fold into
`gateway/internal`; the same mapping function serves both the HTTP/WS faces (the
unary envelope error and the stream error frame).

### 5.1 Infrastructure Codes (gateway/*)

| code | details |
|---|---|
| `gateway/bad-request` | `{ issues: [...] }` (envelope validation/field level) |
| `gateway/cancelled` | `{}` (caller signal abort, request cancelled) |
| `gateway/arguments-invalid`, `gateway/input-invalid`, `gateway/result-invalid`, `gateway/signature-invalid` | `{ endpoint, field? }` |
| `gateway/binding-invalid`, `gateway/service-unavailable`, `gateway/method-unavailable`, `gateway/definition-unavailable`, `gateway/invocation-unavailable` | `{ endpoint, field? }` |
| `gateway/ambiguous-endpoint`, `gateway/context-not-found`, `gateway/context-unavailable`, `gateway/context-failed`, `gateway/lookup-not-found`, `gateway/lookup-unavailable`, `gateway/lookup-failed`, `gateway/provider-mismatch` | `{ endpoint, field? }` |
| `gateway/protocol`, `gateway/uplink-overflow` | `{ endpoint, field? }` — both **new in 0.1.7**: a carrier/protocol-level mismatch on a duplex stream, and an uplink producer that outran the bounded client→host queue |
| `gateway/internal` | `{}` (catch-all) |

> The lookup policy (session-controller) resolves an ordinary identity as: reuse
> the live Agent → automatically resume a cold ordinary session (concurrent
> dedupe) → reject the subagent route (`session/agent-busy`). A resume/ownership
> failure throws its own business code (`session/not-found` etc.) onto the wire
> as-is.

### 5.2 Session Domain (session/*, subagent/*, part of agent-preset/*)

| code | details | Origin |
|---|---|---|
| `session/not-found` | `{ sessionId }` | every layer resolving sessionId (ordinary session missing; cancel with no live Agent) |
| `session/conflict` | `{ sessionId, requestedCwd, existingCwd? }` | create with an explicit id that exists and a different cwd |
| `agent-preset/conflict` | `{ sessionId, requestedPreset, existingPreset? }` | create with an explicit id that exists and a different preset |
| `session/projections-unavailable` | `{}` | **new in 0.1.7**: `session/projections` on a Session whose projection registry is unavailable |
| `session/writer-held` | `{ sessionId }` | **new in 0.1.7**: another writer holds the Session, so the command cannot proceed |
| `session/agent-busy` | `{ reason }` | a subagent session addressed through an ordinary path (including list/search/prompt/cancel/updateQueue/selectModel/rename); other prompt admission failure |
| `session/model-unavailable` | `{ provider, model }` | model routing unavailable. **0.2.0**: `selectModel` requires the exact provider/model pair in the available catalog (a registered route is not enough), while prompt admission keeps the saved route without that catalog gate — so submission no longer rejects here and request execution reports the missing credential/model instead. Availability never rewrites a Session selection |
| `session/provider-credentials-unavailable` | `{}` | **new in 0.2.0**: `initializeDefaultModel` cannot inspect provider credentials because settings/credentials are not mounted |
| `session/provider-models-unavailable` | `{ provider }` | **new in 0.2.0**: `initializeDefaultModel` found no available model for the account provider |
| `session/invalid-time-zone` | `{ value }` | clientTimeZone not UTC/IANA |
| `session/workspace-attach-failed` | `{ sessionId, workspaceId }` | attach failure after create/fork publication |
| `session/attachment-invalid` | `{ reason }` | model does not support images / image not referenced by the log / queue edit is non-text / attachment read failure |
| `session/queue-item-not-found` | `{ itemId }` | updateQueue item no longer queued |
| `session/steer-unavailable` | `{ itemId }` | steer not in next-turn or agent not running |
| `session/title-invalid` | `{ sessionId }` | empty after rename normalization |
| `session/fork-unavailable` | `{ sessionId }` | the exact `atSeq` does not exist in the log, or no completed turn exists when `atSeq` is omitted (**0.1.7** semantics, §4.1) |
| `subagent/not-found` | `{ parentSessionId, childSessionId }` | subagent unavailable |
| `subagent/catalog-diagnostic` | `{ parentSessionId, childSessionId, reason: 'corrupt'\|'unsupported'\|'unavailable' }` | subagent identity projection corrupt/unsupported |
| `subagent/unauthorized` | `{ childSessionId }` | address does not match parent/mode |
| `subagent/parent-unavailable` | `{ parentSessionId }` | parent is not a live ordinary session |
| `subagent/not-resumable`, `subagent/delivery-unavailable` | `{ childSessionId }` | prompt delivery rejected |
| `subagent/attachment-invalid`, `subagent/invalid-time-zone` | same as `session/*` | subagents/prompt images/time zone |

### 5.3 Other Domains

| code | details |
|---|---|
| `workspace/not-found` | `{ workspaceId }` |
| `workspace/invalid-path` | `{ path }` (create target is not an existing directory) |
| `workspace/name-conflict` | `{ name }` |
| `workspace/move-invalid` | `{ workspaceId, sessionId, beforeSessionId? }` |
| `workspace/session-active` | `{ sessionId, activity: SessionActivity[] }` (**new in 0.1.7**: `archiveSession` refused without a write because the Session still has running work — its turn, a subagent descendant, an owned background job or an active schedule; pass `stopActivity: true` to stop them first) |
| `directory-picker/unavailable` | `{ capability }` |
| `directory-picker/unreadable` | `{ path }` |
| `directory-picker/exists` | `{ path }` |
| `directory-picker/create-failed` | `{ path }` |
| `agent-preset/not-found` | `{ agentPreset, available: string[] }` |
| `agent-preset/invalid` | `{ agentPreset, reason }` |
| `agent-preset/read-only` | `{ agentPreset, reason }` (system trust / no user root). **Unreachable at 0.1.7**: its only throwers were `agentPresets/copy` and `deletePreset`, both deleted (§4.6) |
| `agent-preset/locked` | `{ sessionId, agentPreset }` (session already has turns) |
| `llm/model-discovery-rejected` | `{ settingsNs, baseURL? }` |
| `settings/rejected` | `{ ns }` (schema/storage rejection) |
| `settings/conflict` | `{ ns, expected, actual }` (CAS) |
| `credential/rejected` | `{ ref }` (write rejections such as read-only layer shadowing; note the singular credential) |
| `workspace-file/not-found` | `{ path }` |
| `workspace-file/outside-workspace` | `{ path }` (`list` goes outside the session workspace root) |
| `workspace-file/too-large` | `{ path, limit }` (requested page exceeds the configured byte limit) |
| `workspace-file/not-text` | `{ path }` (non-UTF-8 or contains NUL) |
| `workspace-file/not-regular-file` | `{ path, kind: 'directory'\|'symlink'\|'other' }` |
| `workspace-file/not-directory` | `{ path, kind: 'file'\|'symlink'\|'other' }` |
| `terminal/limit-reached` | `{ limit }` (per-Session terminal quota; new in 0.1.6) |
| `terminal/control-unavailable` | `{ reason: 'read-only'\|'not-running' }` (write/resize refused; new in 0.1.6) |
| `terminal/unavailable` | `{}` (identity missing or already cleaning up; **new in 0.1.7**, §4.20) |
| `job/not-found` | `{ sessionId, jobId }` (the session's job list no longer carries a killable row; **new in 0.1.7**, §4.21) |
| `workspace-file/watch-unsupported` | `{ path }` (the filesystem provider cannot watch that target; **new in 0.1.7**, §4.16) |

> Note that a messageFeedback/* business failure is a **`{ok:false,error}` in the
> return value** (§4.12), not an envelope error; its internal codes are the legacy
> `session-not-found`/`target-not-found`/`version-conflict`/note validation codes.

---

## 6. Control Plane and Host Events

### 6.1 session.control Frames (host-wide live control plane)

**0.1.7 shape (unchanged in 0.2.0):**
```
baseline   { type:'baseline', value: {
              projections: Record<sessionId, SessionProjectionBaseline> } }
projection { type:'projection', sessionId, key, value, seq }   // per-cell watermark; higher-seq-wins
```
- Each generation (each open/reconnect) first sends one baseline, then delta
  frames. The client treats the baseline as a snapshot (truncate by `asOfSeq`
  before seeding), then applies deltas.
- **0.1.7 deleted the baseline's `queues` and `jobs` members and the `queue` /
  `jobs` delta frames.** Both states are still observable, just elsewhere: the
  queue is the **`inbox` projection cell** delivered through the very same
  `projection` frames (and the baseline's `projections` record), and background
  jobs are the `job` namespace (§4.21).
- **Deriving queue items from `inbox`** (what the host used to do for
  `SessionQueuedItem`, now the client's job): the cell value is
  `{ 'next-turn': UserMessage[], 'next-step': UserMessage[] }` where each
  `UserMessage` is JSON-safe (`{ id, content: ContentBlock[], source: { kind,
  rpcId?, … } }`, §9). Map `next-turn` → placement `queued`; a `next-step` entry
  whose `source.kind` is `user` → `steering`; any other `next-step` entry →
  `context`. An item's text is its `text` content blocks concatenated; a
  prompt-RPC identity is `message.source.rpcId` on a user-source message. An item
  leaves the cell once it becomes a persistent user message (so the mirror
  retires exactly as before). The `inbox` projection has existed unchanged since
  before 0.1.5, so this read works against 0.1.5/0.1.6 servers too.
- **0.1.6 shape (superseded)**: the baseline carried
  `{ queues, jobs, projections }` and deltas were
  `queue {sessionId, items}` (the full agent inbox after a splice — the
  authoritative snapshot), `jobs {sessionId, jobs}` (whole list pushed on change,
  empty pushed `[]`) and `projection`. `SessionQueuedItem = { id, placement:
  'queued'|'steering'|'context', rpcId?, message: { id, content } }` and
  `SessionJob = { id, kind, label, status: 'running'|'stopping'|'completed'|
  'killed'|'failed', detail?, startedAt, finishedAt? }`; both are gone from the
  wire at 0.1.7. `Session/list`'s `agentAvailable` is the one surviving
  list-level hint about live agents (§4.1).

### 6.2 Host Events (`$events` stream emit-frame allowlist)

`@deepseek-ai/dsh-api-remotes` forwards only the following host events (event
names pass through, arguments as-is):

| event | args | Semantics |
|---|---|---|
| `agent-preset/selected` | `(sessionId, agentPreset)` | session preset change recorded |
| `approval/request` | waterfall | approval request (§3.3) |
| `api-session/added` | `(summary: SessionSummary)` | a session became visible, **or its Agent was created/disposed** (0.1.7 re-emits the current row so a consumer replaces its `running`/`agentAvailable` state) |
| `api-session/activity` | `(sessionId, updatedAt)` | a user message advances list ordering |
| `api-session/error` | `(sessionId, message)` | Agent failed outside a turn |
| `api-session/removed` | `(sessionId)` | session left the host registry |
| `api-session/status` | `(sessionId, running: boolean)` | running-state change |
| `commands/change` | `()` | command registration/deregistration |
| `credentials/record-updated` | `(ref)` | a credential record changed; **new in 0.2.0** (§4.22's account routes also consume it) |
| `credentials/reference-updated` | `(ref)` | credential reference change |
| `cordis/request-run`, `cordis/request-run-resolved`, `cordis/dynamic-package`, `cordis/dynamic-retract`, `cordis/inspect-query`, `cordis/inspect-query-resolved` | plugin host | plugin dynamic loading/panel queries |
| `deepseek-account/model-sign-in-required` | `()` | an account model request needs the user to sign in; **new in 0.2.0** |
| `deepseek-account/session-expired` | `()` | a server rejection removed the current account credential; **new in 0.2.0**, never replayed (§4.22 `watchExpiry`) |
| `llm/adapters-updated` | `()` | adapter registration change |
| `goal/activation-changed` | `(payload: GoalActivationChanged)` = `{sessionId, goal?: {id, revision, activation: 'armed'\|'disarmed'}}` (`goal` omitted after clear) | in-process goal continuation eligibility change; new in 0.1.5 |
| `permission-presets/catalog-changed` | `()` | the selectable permission catalog changed; payload-free, re-read `permissionPresets/catalog` (§4.19); new in 0.1.6 |
| `plugin-manager/changed`, `plugin-manager/install-log`, `plugin-manager/install-state` | plugin manager | current-profile bundle/plugin mutation progress; **new in 0.1.7** (§4.23) |
| `schedule/changed` | `()` | a reminder was created, updated, deleted or dispatched; **new in 0.2.0**, payload-free — re-read `schedule/catalog` (§4.24) |
| `settings/document-updated` | `(ns, revision)` | settings document change |
| `user-questions/request` | waterfall | question request (§3.3) |

Count check: `API_REMOTE_FORWARDED_EVENTS` in
`packages/api/remotes/src/remote-events.ts` has **27 entries** = 25 emit + 2
waterfall (`approval/request`, `user-questions/request`); the table above is the
complete set, and not one extra event is forwarded. (0.1.6 had 20 = 18 + 2; the
three `plugin-manager/*` emits were the 0.1.7 additions; the 0.2.0 additions are
`credentials/record-updated`, `deepseek-account/model-sign-in-required`,
`deepseek-account/session-expired` and `schedule/changed`.)

> Suggested dsh-emacs subscription strategy: `session/control` (baseline +
> `projection` deltas) provides the projections — including `inbox`, which *is*
> the queue since 0.1.7 — while `$events` emit frames provide session-level
> add/remove/change plus command/credential/settings change notifications.
> Background jobs, which 0.1.6 published on `session/control`, are the `job`
> namespace's streams at 0.1.7 (§4.21). Session **content** events come only from
> `session/follow` (§7) and never via emit.

---

## 7. Session Event Vocabulary

### 7.1 Event Envelope and Log Records

The event envelope used for persistence/transport (the wire shape
`SessionWireEvent`) is
`{ type, seq, time, data, ignorable?, sourceEventSeqs?, surfaceOp? }`.

- `seq` is monotonically contiguous (within a session); `time` is epoch
  milliseconds; `data` is a JSON value.
- `surfaceOp` (V3) appears only on the **surface event kinds**
  (`system/message`, `developer/message`, `user/message`, `assistant/message`,
  `tool/result` — `developer/message` joins the set at 0.1.7):
  `'append'` or `{op:'replace', startSeq, endSeq}` (used for compaction
  shadowing, and the event carries `sourceEventSeqs` covering the shadowed
  nodes). The `start`/`end` field names written in the 0.1.2 document are
  deprecated.
- `ignorable: true` = readers may not know the type and may skip it; omitted =
  must-know — on encountering an unknown type it must refuse to reconstruct.
  **Since 0.1.5 this is a hard constraint**: the persistent read path decides by
  `KNOWN_SESSION_EVENT_TYPES` in
  `packages/core/session/src/known-event-types.ts` (56 at 0.1.5, 57 at 0.1.6 with
  the added `image/offload`, **59 at 0.1.7** with `developer/message` and
  `workspace/changes`, and **unchanged at 59 through 0.2.0**; 0.1.6 also adds
  the companion
  `MESSAGE_PROJECTION_EVENT_TYPES = { image/offload }` — an event in that set
  requires its owning pure interpreter, or the host refuses the read); an event
  outside the set without `ignorable` makes it refuse to interpret the whole log.
- **Session format version 4 (0.1.7)**: `SESSION_FORMAT_VERSION` moved from 3 to
  4. The V4 additions are the `developer/message` event and the `forked` turn-end
  reason (§7.2); the envelope itself is unchanged, and a V3 log still reads.
- **Record packing removed (0.1.5)**: `SessionHistoryRecord` has only one kind,
  `{type:'event', event}` (`SessionEventEntry`). The 0.1.2 `{type:'chunks', event}`
  (`chunkrow/text-chunks` runs) and the persistent `assistant/chunk` event have
  both been deleted; the compact stream is embedded in
  `assistant/message.data.stream`, and live deltas go through the
  `assistant-stream` frames of §3.2.1.
- In JSONL storage (export download) the first line is still a
  `{type:'session', …}` header; history lines are bare session events whose fields
  match the wire envelope.
- **replace records do reach the client** (neither path filters them): live `event`
  frames forward every persistent event directly; the opening snapshot's `records`
  are also forwarded one by one — `isAppendSurfaceEvent` is used server-side only
  for **counting and page splitting**, not for filtering slice content. Measured
  over 399 real session logs and 1.2599 million events: 74 replace records total
  (`user/message` 61 = compaction summaries, `system/message` 5 = system prompt
  rewrites, `tool/result` 8 = tool result pruning), and there are instances falling
  inside the default 50-message window (`tail_distance=4`).
  **Renderer discipline**: `system/message` is not rendered; `user/message` source
  filtering (skip when `kind` is not `nil`/`user`) already covers compaction
  summaries (whose `source.kind` is `plugin`); `tool/result` must itself check
  `surfaceOp.op == "replace"` and skip — it **shares the `callId`** with the
  replaced record, and `data` has **no** source field to rely on. dsh-emacs does
  this via `dsh-emacs-render--replacement-p` + the dispatcher.
- **Measured evidence (a `session/follow` snapshot from the 0.1.5-rc.1 live
  service)**: header =
  `{"version":3,"id":"…","createdAt":…,"cwd":"…","isSeeded":false,
  "delegationDepth":0,"agentPreset":"standard"}`; all `records` are
  `{type:'event'}` (observed: `assistant/message`, `tool/call`, `tool/result`,
  `step/start|end`, `turn/end`, `session/end-seed`), with no `chunks` records and
  no `assistant/chunk`. A 0.1.7 host emits `"version":4` for the same shape.

### 7.2 Core Events (`packages/core/session` + agent-loop etc.)

| type | data | Notes |
|---|---|---|
| `turn/start` | `{ turn }` | opens a turn |
| `turn/end` | `{ turn, reason }` | closes a turn; reason below |
| `step/start` | `{ turn, step }` | opens a step (one model call + tool execution) |
| `step/end` | `{ turn, step }` | closes a step |
| `user/message` | `UserMessage` | user-surface message; `source.kind` distinguishes human/rpc/plugin/goal… (**0.2.0** adds `user-question-reply`, the steer message that closes a continued timed question, §4.25) |
| `developer/message` | `{ turn, step, message: DeveloperMessage, headerSeq? }` | **new in V4/0.1.7**: an incremental agent-session change (tool additions/removals) admitted at that turn/step; `headerSeq` names the earlier `request/header` defining every tool addition and is required exactly when additions are present. A surface event (carries `surfaceOp`) |
| `system/message` | `{ turn, step, message: SystemMessage }` | **new in V3**: the rendered system prompt = surface node 0; when the prompt changes, replace the nearest system node or (in-history route) append a new node |
| `assistant/message` | `{ turn, step, message, stream: AssistantStreamRecord[], usage?, interrupted?: true }` | assembled assistant message; `stream` is the exact stream record of that attempt; usage hangs off this event too |
| `assistant/attempt` | `{ turn, step, stream: AssistantStreamRecord[] }` | **new in V3**: a failed/retried/cancelled attempt that committed no surface message |
| `tool/call` | `{ turn, step, callId, name, arguments: string }` | the model's raw JSON string |
| `tool/result` | `{ turn, step, message, error?: { name, code, reason? }, meta? }` | model-surface result; `meta` is tool-owned (must be JSON-safe). `error.reason` — a raw user-facing explanation kept **outside** the model-facing `message` — is **new in 0.1.6** and optional |
| `request/header` | `{ header: EpochHeader, reason, startsSeries? }` | complete header for the next request; log-only. V3 requires the header to **not** carry a `system` field (the system prompt has moved to `system/message`). **0.2.0** redefines `startsSeries` as "this request begins a distinct message series", set independently of `reason` (it is no longer reserved for `reason:'change'`); still optional and log-only |
| `request/context` | `{ provider, model, contextWindow?, systemPromptUpdate? }` | routing metadata (recorded only on change); log-only. `systemPromptUpdate: 'in-history'` means that route treats the latest system message as the effective system prompt |
| `session/end-seed` | `{ inherited?: true }` | seed end marker (resume/fork/replay boundary); log-only |

`turn/end.reason`: `{kind:'completed'}`, `{kind:'aborted', reason}`,
`{kind:'blocked'}`, `{kind:'error', error}`, `{kind:'max-tokens'}`,
`{kind:'interrupted'}`, and — **new in 0.1.7** — `{kind:'forked'}` (the synthetic
closer a fork seed writes for a turn left open at the cut; the loop never emits
it, §4.1). The aborted `reason` (AgentCancelCause):
`{kind:'user'|'parent'|'disposed'} | {kind:'hook', reason} | {kind:'legacy'}`.
With `kind:'error'`, `error` may additionally carry `offloadImages?: number`
(0.1.6, image-offload accounting) — an optional field a renderer can ignore.

`request/header.reason`: `'initial'|'resume'|'change'|'series'`; **0.2.0**
decoupled the optional `startsSeries` marker from this reason (a coincident
series boundary may be reported on any of them).

**Image offload (0.1.6)**: an image content block inside a message may carry
`offloaded?: true` (the model sees placeholder text naming the image and its
read-only path instead of bytes), and the failure objects of `llm/retry` /
`assistant` stream chunks may carry `offloadImages?: number`. These are optional
additions on existing events; the only new event type is `image/offload`
(§7.3).

### 7.3 Plugin Extension Events (SessionEventMap merge, by producer package)

| type | data summary | Source package |
|---|---|---|
| `model/selection` | `{provider, model, reasoningEffort?}` | dsh-api-session-controller |
| `agent-preset/selected` | `{agentPreset}` | dsh-agent-preset-registry |
| `workspace/changes` | `{ turn }` — the Session recorded workspace file changes during that turn; **new in V4/0.1.7** | dsh-workspace-changes |
| `goal/change` | `{kind:'goal/change', version:1, operation: 'create'\|'edit'\|'pause'\|'resume'\|'complete'\|'block', goal, roundsStarted, createdAt, updatedAt}` or the clear tombstone `{operation:'clear', cleared, clearedAt}` | dsh-goal |
| `todo/write` | `{ todos: TodoItem[] }` (whole table last-wins); `TodoItem={content, status:'pending'\|'in_progress'\|'completed'}` | dsh-tool-todo |
| `plan/mode` | `{active: boolean}` | dsh-plan-mode |
| `permission/preset` | `{preset: string}` | dsh-permission-presets |
| `sandbox/mode` | `{mode: 'read-only'\|'workspace-write'\|'danger-full-access', source?}` | dsh-sandbox-policy |
| `approval/asked` | `{id, toolName, callId?, reason?}` (the persistent approval ask pair) | dsh-user-approval |
| `approval/decided` | `{id, outcome}` | dsh-user-approval |
| `approval/policy` | `{policy:'ask'\|'never', source?}` | dsh-user-approval |
| `schedule/change` | `{version:1, operation:'create'\|'delete'\|'dispatch', …}` — **0.2.0** widens creates to named tasks (`title`) and the `daily`/`weekly`/`cron` rule kinds, and drops `every`'s minimum interval to 1 min (§4.24) | dsh-schedule |
| `command/run` | `{commandId, name, args?, source:{kind:'user'}}` | dsh-commands |
| `command/done` | `{commandId, kind:'success'\|'error', text?, sourceEventSeq?}` | dsh-commands |
| `compaction/start` | `{compactionId, sourceCommandId?, turn: number\|null}` (`null` for standalone compaction between turns) | dsh-compaction |
| `compaction/summary` | `{compactionId, sourceCommandId?, summary, shadowedRange, shadowedSeqs, shadowedTokenCount, provider, model, maxTokens?, usage?, rawOutput?}` | dsh-compaction |
| `compaction/end` | `{compactionId, sourceCommandId?, turn: number\|null, error?: string}` | dsh-compaction |
| `compaction/prune` | `{shadowedRange, shadowedSeqs, shadowedTokenCount}` | dsh-compaction-tool-result-pruner |
| `session/title` | `{title, messageSeqs, source:{kind:'fallback'}\|{kind:'provider',provider,model?}\|{kind:'user'}}` | dsh-session-title |
| `session/title-llm-request` | `{titleProvider, messageSeqs, route, system, messages, maxTokens}` | dsh-session-title-llm |
| `feedback/record` | `{text?, category?}` (`category` ∈ `task-result`\|`instruction-following`\|`product-interaction`\|`service-stability`\|`resource-cost`\|`security-privacy-permission`\|`other`) | dsh-command-feedback |
| `feedback/message-put` | `{sessionId, item: MessageFeedbackItem}` | dsh-message-feedback |
| `feedback/message-delete` | `{sessionId, messageId}` | dsh-message-feedback |
| `subagent/descriptor` | `{version:3, mode:'one-shot'\|'continuable', provider, label?, agentProvider?, agentModel?, agentReasoningEffort?, persona?, toolFilter?}` | dsh-subagent |
| `subagent/model-selection-policy` | `{allowedModels}` | dsh-tool-subagent |
| `subagent/catalog` | `{version, childId, childCreatedAt, mode:'one-shot'\|'continuable', label?}` (the parent-session-side subagent registry, one per line; `continuable` requires label) | dsh-subagent |
| `deliverables/presented` | `{turn, callId, files: [{path, description?}]}` (delivered files registered after the `present` tool closes successfully) | dsh-tool-present |
| `hook/invoked` / `hook/result` | hook execution records | dsh-hook-protocol |
| `llm/retry` | `{retryId, turn, step, provider, mode:'normal'\|'always', policyKey, retry, maxRetries?, delayMs, failure:{message,code?,…}}`; `maxRetries` belongs to normal mode; `failure` may carry `offloadImages?` (0.1.6) | dsh-llm-retry |
| `llm/retry-started` | `{retryId, turn, step, retry}`; emitted after the scheduled wait, immediately before the retry request | dsh-llm-retry |
| `image/offload` | `{ targets: [{ seq, imageIndexes: number[] }] }` — records which image occurrences of which message nodes were offloaded; **new in 0.1.6**, and a *message-projection* event: its owning interpreter (`dsh-compaction-image-offload`) derives the `offloaded` marks on those message image blocks (also replayed into `assistant/message`/`user/message`/`system/message`/`compaction/summary`/`tool/ptc-dispatch` content) | dsh-compaction-image-offload |
| `agent/inbox/spliced` | `{target:'next-turn'\|'next-step', start, removedCount?, inserted, outcome?}` | dsh-agent |
| `tool/ptc-dispatch-start` / `tool/ptc-dispatch` | PTC (`run_code` bridge) subcall dispatch pair: `start` opens a subcall, `dispatch` closes it out with the same `subCallId`; `dispatch` may carry `error?: { name, code, reason? }` (**new in 0.1.6**) | dsh-tools |
| `tool-workflow/run-start` / `agent-start` / `agent-end` / `run-end` | workflow lifecycle | dsh-tool-workflow |
| `team/member`, `team/task`, `team/message/queued`, `team/message/delivered` | team state (experimental) | dsh-agent-team |
| `session-log-deepseek/delivery-accepted` | `{sessionId, throughSeq}` | dsh-session-log-deepseek |
| `web/deepseek-search-llm-request` | search request records | dsh-web-search-deepseek |

> There are **no** `session/telemetry` or token-meter events: usage hangs off
> `assistant/message.usage` + `compaction/*.shadowedTokenCount` and is emitted by
> projection folding (tokenUsage/contextPressure/sessionStats etc., §9).

### 7.4 dsh-emacs Rendering Consumption Guide (for migration verification)

Events flow in only from the `event` frames of `session/follow` for a **session
already followed** (opening a session = `session/follow` + consuming snapshot/
event frames). The rendering layer needs at least: `user/message`,
`assistant/message` (with `data.stream` holding the complete stream of that
attempt), `tool/call`, `tool/result`, `turn/start`, `turn/end`, `request/header`,
`request/context`, plus the extension events `command/run`, `command/done`,
`session/title`. **V3 changes**: `assistant/chunk` is no longer a persistent
event, so streaming text is either taken whole from
`assistant/message.data.stream` or consumed from the §3.2.1 `assistant-stream`
frames; `system/message` is a surface event and needs separate handling if the
system prompt is rendered (most clients just skip it). A `replace` surfaceOp on
`assistant/message`/`tool/result`/`system/message` means compaction shadowing — the
rendering layer must replace old nodes per `sourceEventSeqs` rather than append.
State such as title and goal/todo is taken from projection keys
(`title`/`goal`/`todos`/`plan`/…, §9) rather than directly from events. **At
0.1.7 the queue is the `inbox` projection cell** and background jobs are the
`job` namespace, both off `session/control` (§6.1, §4.21);
approvals/questions come from the `$events`
waterfall (§3.3), and delivered files from `deliverables/presented` (§10.3).

**The coverage dsh-emacs added (`dsh-emacs-render-event` dispatch)**: events
previously dropped silently now all have an owner — `step/start` / `step/end` are
turn-internal boundaries (one step = one model call + its tool execution) and do
not enter the transcript; they instead feed the modeline's `step N` badge
(`dsh-emacs-modeline-note-step`; off by default, enable
`dsh-emacs-modeline-show-step`, see docs/modeline.md); `assistant/attempt`
renders as a `↻ Attempt (no committed reply)` card whose body is rebuilt in order
from the packed records of `data.stream`
(`reasoning-chunks`/`tool-call-chunks`/`text-chunks`) (reasoning is subject to
`dsh-emacs-show-reasoning`); if that attempt still has a live streaming body when
it settles, the live body is taken over by the card rather than drawn twice;
`session/end-seed` renders as a single `── seed boundary` line (a fork/resume seed
carries `inherited: true` and is labeled `inherited history`; a brand-new session
does not append this event); `deliverables/presented` renders after `turn/end` as
a single `Deliverables · N files` line, collapsed by default (turnTail position;
expanded, it lists one indented line per path, click to open, with no body
background; the same path takes the latest description, and `write`/`edit` changes
are not merged in — their tool cards are already shown). `system/message` is still
not rendered.

**Execution feedback**: `llm/retry` / `llm/retry-started` and
`compaction/start` / `compaction/end` feed the mode line, with provider, wait
and failure details through `M-x dsh-emacs-describe-status`. A retry chain
reuses `retryId` across attempts, so `retry-started` must also match `retry`.
Compaction's `turn: null` is independent of the running-turn animation.
Completion boundaries clear live status; disconnect clears it, and the whole
follow snapshot rebuilds it even below the transcript dedup anchor. Automatic
compaction failures render a retained error card; `sourceCommandId` failures
use the existing command result instead. `compaction/summary` and
`compaction/prune` have no dedicated renderer.

**0.1.6 additions and the dispatcher**: `image/offload` is a durable event with
no dedicated renderer, so `dsh-emacs-render-event`'s `_ → nil` default branch
drops it, and the `offloaded` / `offloadImages` fields are optional keys on
events the client already handles — `assq`/`aget` reads of the fields the client
needs are unaffected.  `tool/result.error.reason` **is** consumed:
`dsh-emacs-render-tool-result` reads it and appends it to the failed row's
status line (`dsh-emacs-render--tool-status-text`), so a refusal shows the
user-facing explanation the host keeps outside the model-facing `message`.  If
an offloaded image is shown, the client still renders the block from its
`attachment` ref (the attachment bytes remain durable); image offload changes
what the *model* sees, not what the transcript holds.

**0.1.7 additions and the dispatcher**: the two new durable events
(`developer/message`, `workspace/changes`) likewise have no renderer and fall
through `dsh-emacs-render-event`'s `_ → nil` default; neither is part of the
conversation surface a transcript needs. `turn/end` with
`reason.kind === 'forked'` reaches the client only in a fork child's seed prefix,
where the client already renders seed history without special-casing the closer
(the turn simply shows as ended). The breaking part of 0.1.7 is **not** in the
event vocabulary: it is the `session/control` queue source (§0.4, §6.1), which
the client has since migrated to the `inbox` projection (postmortem/064).

**0.2.0 adds no durable event type** (`KNOWN_SESSION_EVENT_TYPES` stays 59), so
the transcript dispatcher needs no new event branch. The durable change is a
tool result's *meaning*: the timed `ask_user_question` pending payload is
rendered as `pending` and settled from the `userQuestions` projection cell
(adopted — §4.25, postmortem/073). The remaining additions — the
`user-question-reply` `user/message` source, `ApprovalRequestEvent.displayReason`
and the four host emits — are an unknown key in an alist the client already
reads or an unknown frame that falls through its `_ → nil` default, and the
`user-question-reply` message is deliberately hidden by the transcript source
filter. The `session/control` / `session/follow` shapes and the `inbox` queue
source are unchanged from 0.1.7, so no migration is required (§0.5).

---

## 8. queue / steer Semantics (transient inbox + control plane)

- **queue**: `session.prompt` `mode:'queue'` → `agent.followup()`, appended as the
  next turn (becoming the only message of its own turn).
- **steer**: `mode:'steer'` → `agent.steer()`, inserted into the next step of the
  current turn ("interjection"); in an idle driver steer degrades to a new turn.
- The **authoritative snapshot** is the `inbox` Session projection: the control
  baseline's `projections[<sessionId>].values.inbox` and every later
  `session/control` `projection` frame with `key === "inbox"` (through 0.1.6 it
  was the control baseline's `queues` record plus `queue` frames, now deleted —
  §6.1). `placement` is derived from which inbox list the message sits in:
  `queued` (next turn, pending send; rendered in the outgoing area), `steering`
  (next-step user input, already inserted into the current turn; a pending bubble
  at the tail of the conversation), `context` (injected next-step content such as
  an approval; invisible until claimed). Once an item becomes a persistent user
  message it retires from the projection, and therefore from the mirror.
- **`session.updateQueue`**: does `edit` (text only) / `remove` / `steer` on a
  pending item.
  - `steer` takes effect only for a next-turn item while the agent is `running`;
    otherwise `steer-unavailable`.
  - Already claimed → `queue-item-not-found` (an all-queue interjection with an
    empty draft via Cmd+Enter may hit an already-claimed item; silently skip it).
  - **0.1.7**: the verb resumes a cold Agent first instead of failing without a
    live one (§4.1).
- **Request receipt reconciliation**: `session.prompt`'s `requestId` appears on the
  queue item's `rpcId` — `message.source.rpcId` inside the `inbox` projection —
  and on the final user message source (`user-rpc`); the
  client uses that to replace the optimistic echo with the persistent message.
- Web interaction comparison: while the agent is busy, plain Enter = queue,
  `Cmd/Ctrl+Enter` = steer; an empty draft with `Cmd/Ctrl+Enter` = interject all.
  Setting: the `ui-conversation` namespace's `busyEnter: 'queue'|'steer'` (default
  `queue`).
- Subagent sessions have no queue operations (all ordinary endpoints reject; use
  `subagents/prompt`).
- Behavior tightened in 0.1.5: an empty prompt to `session/prompt` is rejected (at
  the `session-controller` layer), and an empty-content `session.updateQueue` edit
  is rejected too — the client no longer needs its own fallback filtering of empty
  strings.

---

## 9. Session Projections (session.control `projection` frames + follow snapshot `projections`)

Projection cells are registered by each plugin with the host's
`sessionProjections`; each cell folds session events into one JSON value. The
client maintains a **per-session value store keyed by key**, with the rules: a
control `projection` frame is higher-seq-wins; the `projections` block of the
follow opening snapshot (aligned by `asOfSeq`) and the control baseline's
`projections` can both serve as a reconnect/open baseline (truncate by asOfSeq
before seeding); `projections.values` on a `session.list` row is a partial cache
hint over the same key space.

Client-visible keys (18 at 0.1.6; present when mounted) and value shapes (0.1.5
adds `subagentCatalog`; 0.1.6 narrows `permissions`; 0.1.7 promotes `inbox` from
a host-internal cell to the client's queue source and mounts `schedule`;
**0.2.0 swaps cells — adds `userQuestions` and deletes the `schedule`
projection, so a 0.2.0 host exposes the same 19 keys**; the table's `subagent` /
`subagentTiming` / `subagentCatalog` all come from the subagent package):

| key | value shape |
|---|---|
| `inbox` | `{ 'next-turn': UserMessage[], 'next-step': UserMessage[] }` — the pending agent input, **the queue snapshot since 0.1.7** (§6.1, §8). Each `UserMessage` is JSON-safe (`{id, content: ContentBlock[], source: {kind, rpcId?, …}}`); `next-turn` → `queued`, user-source `next-step` → `steering`, other `next-step` → `context`. The cell existed through 0.1.5/0.1.6 as well, but those hosts also republished it as `session/control` queue frames, which 0.1.7 deleted |
| `title` | `string \| null` (latest `session/title` text, last-wins) |
| `turnOutline` | `{ turn, seq, prompt, response }[]` (one per completed turn, including a boundary preview) |
| `sessionStats` | `{ turns, steps, llmMs, toolMs, ttftMs, ttftSteps, decodeMs, decodeTokens }` |
| `goal` | `{ goal: {id, revision, objective, phase, blockedReason?, maxGoalRounds}, roundsStarted, createdAt, updatedAt } \| null` |
| `todos` | `TodoItem[] \| null` (null before the first write) |
| `plan` | `{ active: boolean, pending: boolean }` — committed mode and whether an opposite selection is pending; missing key means the capability is absent. dsh-emacs consumes this for its Plan badge |
| `permissions` | `{ currentValue: string }` (key missing = no permission service). **Changed in 0.1.6**: through 0.1.5 this value also carried `options: [{value, name, description?}]`; the selectable options are now the process-level `permissionPresets/catalog` Remote (§4.19), and `currentValue` is a configured key, live `auto`, or the derived `custom` |
| `userQuestions` | `{ active: PendingUserQuestion[], settled: SettledUserQuestion[] }` — **new in 0.2.0** (§4.25): `PendingUserQuestion = {callId, questions: AskUserQuestionItem[], state: 'open'\|'continued'}` (in ask order) and `SettledUserQuestion = {callId, answers: AskUserQuestionAnswerItem[]}` (in settlement order, empty `answers` when the late reply carried none). Only **timed** `ask_user_question` calls enter either half; the blocking legacy tool appears in neither. Missing key = the user-questions capability is not mounted. **dsh-emacs reads it**: the chat buffer keeps the latest cell, `M-x dsh-emacs-answer-question` answers `continued` calls, and a settled cell completes the original ask card (postmortem/073) |
| `tokenUsage` | `{ uncachedInputTokens, outputTokens, cacheReadTokens, cacheWriteTokens }` (cumulative totals) |
| `contextPressure` | `{ pressureTokens?, projectedTokens?, contextWindow? }` |
| `contextBreakdown` | `{ systemTokens, toolsTokens, messageTokens }` |
| `agentPreset` | `string \| null` (the preset the session actually runs) |
| `subagent` | `{mode:'one-shot', label?, seq} \| {mode:'continuable', label, seq} \| null` |
| `subagentTiming` | `{ settledMs, active?: {since, through} }` |
| `subagentCatalog` | `SubagentCatalogEntry[]` (parent-session-side subagent catalog, in `subagent/catalog` event order; does not include fork-inherited facts) |
| `schedule` | **deleted in 0.2.0** — the 0.1.7 cell was `ScheduleRecord[]` (effective reminders, mounted only with a schedule service). The 0.2.0 schedule package registers **no** Session projection, so read `schedule/list` / `schedule/catalog` and invalidate on the payload-free `schedule/changed` emit (§4.24, §11.3) |
| `sessionListMetadata` | `{ blank, lastPromptAt }` (list row hint) |
| `imageLimits` | `{ maxImageBytes, maxImagesPerMessage, maxMessageImageBytes, maxImagePixels, maxImageDimension, mediaTypes }` (key missing = no attachment service) |
| `modelSelection` | `{ lastUsed: {provider, model, reasoningEffort?} \| null, next: … \| null }` |

Plan's `pending` is a logged `/plan` selection awaiting settlement/application,
not a user-review flag. During an open turn the change applies at an accepted
pre-step; between turns it can be logged immediately. `plan/mode` records the
committed mode; its event alone does not carry the pending selection. The
client reads control increments (`seq`) and follow/control baselines
(`asOfSeq`), retaining the newest cut even when the capability is absent.
It resets these watermarks when a new core connection opens.

The projections contain **no** "this session is waiting for the user" state
(neither history nor 0.1.5 has `sessionStats.pendingInteraction`). The web keeps
it in a client-owned registry, written during the lifetime of a request by the
live `approval/request` / `user-questions/request` waterfall **taker**
(`ui-session`'s `pendingInteractions`; `ui-approval` / `ui-user-questions` each
register a domain), not in `session/list`.

Current dsh-emacs state (deliberately kept): it shows running state only from the
row's `running` flag and does **not** infer pending interactions. The reason is
not a missing aggregation function, but that for a session with **no chat buffer
open** this client hands the waterfall straight back to the host with `next`
(`dsh-emacs-events--host-dispatch`), so the client simply has no state for such
sessions. If "waiting for approval" is to be shown on the Emacs side in the
future, the source that also holds for cold sessions is the persistent event pair
`approval/asked` → `approval/decided` (§7.3), not the waterfall.

The host also has several cells that are **state-table-only and never cross the
wire** (`turnBoundary`, `titleInput`, `subagentModelSelectionPolicy`,
`sandboxMode`, `agentTeam`, `timeContext`, `tmuxContext`, `llmRetry`) — they are
used for host-side folding and do not appear in wire frames.

`stateVersion` is a host-side fold version, not a wire field: 0.1.6 raised
`contextPressure` and `contextBreakdown` from 4 to 5 (image-offload accounting in
the fold) without changing either value shape; **0.1.7** raised `subagent` and
`subagentCatalog` from 2 to 3 and `agentTeam` from 3 to 4 (again with unchanged
wire view shapes); **0.2.0** adds the `userQuestions` cell at `stateVersion` 2
and leaves every existing cell's version unchanged. A client that sees a cache
cell from an older version simply re-reads it.

> The 0.1.1-rc.2 mux projection frame (`session/projection`) was replaced in 0.1.2
> by the `projection` delta frames of `session.control`; projection sources =
> follow snapshot + control projection frames.
>
> Projections are a **capability surface**: a key being absent on the wire means
> the deployment has not mounted the corresponding plugin (for example, no
> schedule service means no `schedule`, no permission service means no
> `permissions`); do not treat it as "value unknown". On the dsh-emacs side this
> corresponds to the projection dispatch in `dsh-emacs-events.el`.

---

## 10. Other Exact HTTP Routes (no envelope)

These routes go through the same trust fence + cookie authentication as the
`/api` RPC, but **do not use an envelope**: requests/responses have their own
shapes and status codes.

### 10.1 Session Log Download

```
GET /api/session.export?sessionId=<id>[&includeDescendants=true|false]
```
- An exact GET/HEAD Fetch route; returns a ZIP attachment
  (`content-type: application/zip`,
  `content-disposition: attachment; filename="dsh-session-<id>.zip"`).
- Root artifact `session.jsonl` (header line + event lines) + subagent descendants
  `subagents/<id>/session.jsonl` + referenced images
  `media/<attachmentId>.<ext>`.
- `includeDescendants` accepts only `true`/`false`/omitted; any other value or a
  missing sessionId → 400; a missing service
  (session-query/persistence/attachments) → 500; root read failure → 500; the root
  session does not exist → 404.
- The web composer additionally has an `/export` slash command that triggers the
  same download (it accepts no path argument).
- dsh-emacs can `url-retrieve`/`curl` the download and unpack it locally (with the
  cookie).

### 10.2 Reading a File by Absolute Path (0.1.5)

```
GET  /api/file?path=<absolute path>      (HEAD same path, headers only)
```
- The path must be **absolute** and contain no NUL, otherwise 400; it is resolved
  through the execution world of `ctx.fs` (still governed by the sandbox policy).
- Success: 200 + file bytes (**whole file**), `content-type` inferred from the
  extension, with `cache-control: private, no-store`,
  `x-content-type-options: nosniff`,
  `content-security-policy: sandbox; default-src 'none'`.
- Failure: 404 not found / 403 not a regular file, or permission, or sandbox
  rejection / 413 over the byte limit / 499 caller abort / 500 other `FsError`.
- The byte limit = `ctx.attachments.imageLimits.maxImageBytes` (the attachment
  image limit, on the order of 200 MiB by default) read as a **whole file**, with
  no disk write and no pagination.
- **Version note (verified against the npm 0.1.5-rc.1 build)**: during the 0.1.5
  DEV period `Range: bytes=` (single range) and 416/`content-range` were
  supported, but that capability was removed before the rc release by
  `refactor(api): reuse attachment limits for file responses`; **the actual
  0.1.5-rc.1 build has no Range support** (neither the source nor the installed
  `lib/index.js` handles `range`). For large-file pagination use
  `workspaceFiles/readBytes` from §4.16.
- **Division of labor with `workspaceFiles`**: `/api/file` is "direct read by local
  absolute path" and suits same-machine scenarios; `workspaceFiles` is "read by
  session scope, with pagination/change subscription/cross-machine support" and is
  the client's first choice for reading workspace files (§4.16).

### 10.3 Deliverables (`present`) Related (0.1.5)

When the `present` tool closes successfully it writes a `deliverables/presented`
session event (`{turn, callId, files: [{path, description?}]}`, §7.3), which the
Web side renders as a clickable file card. The two routes behind the card:

```
GET  /api/present.host                     → {name, available, fileManager}
POST /api/present.open?sessionId&seq&index  body: {"action":"open"|"reveal"}
```
- `present.host` probes the host desktop capability (`fileManager` ∈
  `finder`/`explorer`/`directory`/`null`; it does not guess from the browser OS).
- `present.open` locates the file by **session event coordinates** (`sessionId` +
  the `seq` of that `deliverables/presented` event + the `files` array index) and
  then hands it to the host to open/reveal; it rejects when `seq`/`index` does not
  match the actual event.
- To show deliverables, dsh-emacs only needs to consume the
  `deliverables/presented` event to get the paths; whether to offer "open in
  Finder" is a pure client choice and does not require these two routes (it can use
  `session/openWorkspacePath`, §4.1).

### 10.4 Raw Byte Upload (0.1.5)

```
POST /api/session/uploadFileBinary?sessionId=<id>[&name=<leaf name>]
content-type: application/octet-stream
body: raw bytes
```
- Success is 200 + `{ok:true, value:{receiptId, file}}`; failure is also 200 +
  `{ok:false, error:{code,message,details}}` (a custom result shape outside the
  envelope).
- Status codes are used only for request validation failures: missing `sessionId`
  → 400; `content-type` not `application/octet-stream` → 415; non-POST → 405.
- The obtained `receiptId` is used for §4.1's `{type:'file', receiptId}` or §4.11's
  `CommandSubmitAttachment`; small files may also use the unary
  `fileUploads/upload` (base64).

---

## 11. 0.2.0 New Features: How to Use Them

§0.5 records *what* changed at 0.2.0; this section is its usage companion — for
every client-visible addition it gives the call order and the semantics that
decide it, plus what dsh-emacs does with it today. Wire shapes stay in §3–§9 and
are cross-referenced rather than repeated.

| Feature | Surface | dsh-emacs today |
|---|---|---|
| Timed / continued questions | `wait` on the question waterfall, `userQuestions/*`, `userQuestions` projection | **adopted** — §11.1 |
| Platform account | `account/*` (7 verbs + 2 streams) | unused; the largest genuinely new capability — §11.2 |
| Session reminders | `schedule/*` (optional bundle) | unused — §11.3 |
| Default-model bootstrap | `session/initializeDefaultModel`, changed `selectModel` / `modelCatalog` | unused — §11.4 |
| Localized approval reason | `ApprovalRequestEvent.displayReason` | unused; a one-line win — §11.5 |
| Reshaped existing surfaces | `agentPresets/list`, `workspace/initializeDefault`, `workspaceFiles/list`, `terminal/shells` | breaking but inert — §11.6 |
| Semantics-only changes | `startsSeries`, Auto policy, two error codes, four emits | no migration — §11.7 |
| Desktop analytics | `productAnalytics/*` | skip — Desktop-only, §11.8 |

### 11.1 Timed / continued questions (`userQuestions`) — adopted

**What it buys.** `ask_user_question` can now run in a `timed` mode: the host
holds a foreground wait but does **not** retire the question when it elapses.
The call becomes `continued` and stays answerable. A client that only implements
the blocking waterfall is left with a stale card whose answer path no longer
exists. The window is per call — the timed tool's model-facing `timeout`
parameter in seconds, default 120 — and `timeout: -1` selects the indefinite
form (a `wait` without `timed`). The mode itself is host opt-in
(`mode: 'timed'` on `@deepseek-ai/dsh-tool-ask-user`); the shipped Web preset
mounts the tool with no config, so a stock host keeps the legacy blocking tool
and never sends `wait`.

**Wire** (§3.3, §4.25, §9): the waterfall request gains
`wait?: {callId, timed?: true}`; the tool result after expiry is
`{pending: true, callId, message}`; the state lives in the `userQuestions`
projection cell `{active, settled}`.

**How to use it**, in order:

1. **Read `wait` off the waterfall.** No `wait` on the request — or no
   `userQuestions` key in the projections — means a host older than 0.2.0; take
   today's blocking path unchanged. That is the whole compatibility story: one
   code path, no version probe.
2. **Claim a timed wait before prompting.** For `wait.timed`, open
   `userQuestions/attachWait {agentId, callId}` and keep it open while the
   prompt is on screen — while attached, the host deadline is suspended, so a
   slow answer cannot be timed out mid-read. The stream yields one
   `{remainingMs}` and stays open until released or settled; it is not a ticker.
   A `wait` without `timed` is the indefinite form: `attachWait` yields no
   frames, so do not call it.
3. **Release the claim on every exit path.** For a submitted answer, transfer
   cleanup to the RPC callback and hold the stream until the response arrives.
   Other exits release immediately. Release reschedules the **original** host
   deadline, which may already have passed; it does not restart a saved duration.
   The stream lifetime is the claim, so a dropped socket releases it as well.
4. **Answer in time through the unchanged waterfall:** `$events/result` with
   `{answers: [{id, selected, custom?}]}` (§3.3).
5. **Treat expiry as pending, not unanswered.** The recorded tool result is
   `{pending: true, callId, message}` (the service returns `{pending, callId}`
   and the tool layer adds `message`): not an answer document, and the
   projection moves that `callId` to `state:'continued'` inside `active`.
6. **Answer later with `userQuestions/answer {agentId, callId, answer}`.**
   `agentId` must be the exact live root Agent; the service rejects a delegated
   child, a call whose agent is not live, a batch that does not name every
   question exactly once, and an already-queued reply (in-process
   `UserQuestionError` codes `DELEGATED_CALLER`, `CALLER_NOT_LIVE`, `BAD_ANSWER`,
   `REPLY_QUEUED`). Those are **not** `RemoteError`s, so on the wire they all fold
   to `gateway/internal` with the message preserved (§5). Skip is
   `selected: []`; the value is a boolean — whether the call was still
   `continued`. A successful envelope carrying `false` means the batch was not
   accepted and must not be reported as answered.
7. **Let the steer message close it.** The accepted answer enters the Agent as a
   `user/message` with `source.kind = 'user-question-reply'`; that message is
   what moves the call from `active`/`continued` to `settled` (settlement order,
   empty `answers` when the late reply carried none). A transcript normally hides
   that synthetic message.
8. **Track state from the projection, not from a local timer.** Seed the cell
   from the follow snapshot / control baseline and apply increments
   higher-seq-wins (§9); a missing key is a capability signal, not an unknown
   value.

**dsh-emacs** (postmortem/073): holds `attachWait` around the read, renders the
expired result as `❓ Ask question · pending`, answers a continued call with
`M-x dsh-emacs-answer-question` (`C-c C-p`), and completes the original card from
`settled`. Dormant against a 0.1.7 server (no `wait`, no cell).

### 11.2 Platform account (`account/*`) — unused

**What it buys.** DeepSeek-account sign-in plus profile/balance/bonus display,
and the "sign-in required" / "session expired" signals. Every operation that
reaches Platform carries the requesting UI's identity.

**Client metadata (the 0.2.0 breaking part).** `client = {version: string,
locale: string, timezoneOffsetSeconds: number}` is a required positional `args`
field on `getProfile`, `getBalance`, `getUnnotifiedBonuses`, `ackBonusNotified`,
`startSignIn` and `signOut`. `timezoneOffsetSeconds` is seconds, **positive east**
of Greenwich. `getState`, `cancelSignIn` and both streams do not
take it. `startSignIn`'s removed `locale` argument is now `client.locale`.

**How to use it** — the minimal sign-in loop:

1. `account/getState {}` → `AccountView`; the namespace is mounted only when the
   deployment composes the `deepseekAccount` provider.
2. When `status: 'signed-out'`, call `account/startSignIn {client,
   callbackOrigin, loginSource: 'web'|'desktop'}` → a view carrying `attempt`
   (`SignInAttemptView`); present `attempt.authorizeUrl` once its `phase`
   reaches `waiting-browser`, and follow `exchanging → committing → succeeded`
   on `account/watch` (stream: initial snapshot, then changes). The URL is not
   returned synchronously — the host runs the flow in the background — and
   re-calling while a phase is live is idempotent.
3. `account/cancelSignIn {attemptId}` cancels (the id is `attempt.id`);
   `AccountView.links.usageUrl` / `topUpUrl` are always present for the UI.
4. Profile and balance settle independently: `account/getProfile {client}` /
   `getBalance {client}` → `null` (grant absent or changed) or
   `{status:'ready', value}` / `{status:'failed'}`. Balances are decimal strings,
   with `balance.bonusWallets` carried separately.
5. Bonuses: `account/getUnnotifiedBonuses {client}` → `AccountBonusBatch |
   null`; show each notification's server-localized `message`, then
   `account/ackBonusNotified {accountId, orderId, client}` → `boolean` (`false`
   when signed out or the account changed).
6. Sign-out: guard with `account/hasRunningAccountTasks {}` (a running task's
   latest request is on the account route); `account/signOut {client}` drops the
   local grant and revokes it in the background, leaving API keys alone.
7. Expiry: `account/watchExpiry` (stream) yields `'session-expired'` without
   replaying earlier notifications; the same condition is forwarded as the
   `$events` emit `deepseek-account/session-expired`, and a request needing
   sign-in raises `deepseek-account/model-sign-in-required` (§6.2).

**dsh-emacs**: calls none of it today. A minimal `/login` (getState →
startSignIn → watch + watchExpiry) captures most of the value without the bonus
half.

### 11.3 Session reminders (`schedule/*`) — unused

**Mounted only with the optional bundle, and read-mostly on the Remote side.**
The namespace comes from `@deepseek-ai/dsh-experimental-schedule-bundle`, which
the installation ships switched off, so a default host has no `schedule`
endpoint and `schedule/*` is capability-gated rather than assumed. Two shape
surprises: 0.2.0 **deleted the 0.1.7 `schedule` Session projection** (no
`schedule` key exists at all — client state comes from `schedule/list` /
`schedule/catalog`, invalidated by `schedule/changed`), and there is **no Remote
`create`**: records are created by the model's `schedule_create` tool, so the
Remote surface is list / catalog / history / update / delete only.

**How to use it:**

1. Per session: `schedule/list {request: {sessionId}}` → `ScheduleRecord[]` in
   storage order; it never resumes the Agent. Host-wide: `schedule/catalog {}`
   adds `sessionId`, `status` and `lastDelivery`. Delivery history is
   newest-first and paged by message cursor:
   `schedule/history {request: {sessionId, id, limit, before?}}` (`limit` 1–100)
   with the retention bounds and a `nextBefore` cursor in the result.
2. Mutate through the CAS verb: `schedule/update {request: {sessionId, id,
   expected, change?, title?, prompt?}}`, where `expected` is the complete
   observed record. A timing edit may switch recurrence kind. New records
   require `title` (≤120 chars).
3. `schedule/delete {request: {sessionId, id}}` for removal.
4. **Misses are values, not errors**: `{deleted: false, code:
   'schedule_not_found'}` and `schedule_ended` / `schedule_conflict` /
   `delivery_cursor_not_found` arrive inside the result. Only a rule that cannot
   become a record throws (`ScheduleInputError`, whose codes fold into
   `gateway/internal` with the message preserved).
5. Re-read on the payload-free `schedule/changed` emit (§6.2), fired by every
   create/update/delete/dispatch.
6. Rules: `after` / `at` / `every`, plus 0.2.0's wall-clock `daily` / `weekly` /
   `cron` (explicit IANA `timeZone`, local `HH:mm:ss[.SSS]`, ISO weekdays 1–7,
   five-field cron); `every`'s floor dropped from 5 min to 1 min. Legacy records
   without `title` still read.

**dsh-emacs**: unused.

### 11.4 Default-model bootstrap and catalog narrowing — unused

**How to use it.** After an account sign-in that leaves no provider API key,
`session/initializeDefaultModel {}` picks the first available
`deepseek-account` model and saves it as the deployment default. It is a no-op
when any configurable API-key provider already has a credential; with no account
model it is `session/provider-models-unavailable {provider}`, and with
settings/credentials unmounted
`session/provider-credentials-unavailable {}`.

**Changed existing calls.** `session/selectModel` now validates the exact
provider/model pair against the live catalog — a registered route with an empty
catalog is no longer enough — and answers `session/model-unavailable {provider,
model}`; the deployment default is persisted in the background, so the returned
`{selected}` no longer waits for or fails on that write.
`session/modelCatalog.routableProviders` narrows to providers with ≥1 currently
available model, and `session/prompt` dropped its own route pre-check, so an
unavailable model surfaces from `selectModel` (or the agent's admission) instead
of at prompt time.

**dsh-emacs**: calls neither `initializeDefaultModel` nor `selectModel`'s
catalog gate; its model picker reads `groups`, not `routableProviders`
(`dsh-protocol-model-directory` deliberately drops the list), so the narrowing is
invisible to it.

### 11.5 Localized approval reason (`displayReason`) — unused, one-line win

`approval/request`'s `request` gains optional `displayReason?: {en: string,
[locale]: string}`. It is presentation-only and never persisted — the durable
audit pair `approval/asked`/`approval/decided` still carries `reason` — so a
client should prefer `displayReason` for the locale it is showing and keep
`reason` as the fallback for an older host or an absent locale.

**dsh-emacs**: not consumed; a single alist read in the approval card.

### 11.6 Reshaped existing surfaces — breaking but inert

- **`agentPresets/list` lost `modeSelectionEnabled`** (its value is now
  `{presets}`). The chooser is always enabled and the saved default always
  applies; take "the default" from the row whose `isDefault` is set, never from
  a saved setting.
- **`workspace/initializeDefault` takes no request args.** The leaf directory is
  fixed to `<Documents>/deepseek-harness/default-workspace` and the stored title
  is that automatic `default-workspace` segment, which a client localizes for
  display itself; the old `directoryName`/`title` args and their
  `gateway/bad-request` validation are gone.
- **`workspaceFiles/list` follows a final symlink/junction** that resolves to a
  directory, listing the resolved directory; `read` keeps its no-follow gate, so
  a symlinked directory lists while a symlinked *file* is not read through.
- **`terminal/shells` de-duplicates by executable name** (case-insensitive,
  `.exe` stripped) instead of full path, keeping the earliest entry per name
  with the default first; `TerminalShell` is unchanged.

**dsh-emacs**: only `modeSelectionEnabled` touches the client — the struct slot
still parses, now always to `nil`, and no business code reads it (a dead slot to
delete with the next protocol edit). The rest is in namespaces it never calls.

### 11.7 Semantics-only changes — no migration

- **`request/header.startsSeries`** now means "this request begins a distinct
  message series" and is set independently of `reason`, no longer reserved for
  `reason:'change'`; still optional and log-only.
- **`permissionPresets/catalog`'s derived `auto`** preset now uses approval
  policy `ask` (was `never`), and a still-selected `auto` also matches a `never`
  approval knob, so a delegated child that pins `never` keeps a final denial. The
  option set and value shape are unchanged.
- **New error codes** `session/provider-credentials-unavailable {}` and
  `session/provider-models-unavailable {provider}`, both from
  `initializeDefaultModel` (§5.2).
- **Four new `$events` emits** — `credentials/record-updated (ref)`,
  `deepseek-account/model-sign-in-required ()`,
  `deepseek-account/session-expired ()` and `schedule/changed ()` — raising the
  allowlist from 23 to 27 (§6.2). They matter only to a client that builds
  §11.2/§11.3; otherwise they fall through an unknown-frame default.

**dsh-emacs**: nothing to migrate; all four sit behind existing `assq` /
`_ → nil` parsing.

### 11.8 Desktop analytics (`productAnalytics/*`) — skip

Three endpoints (`enabled`, `watchPolicy`, `report`) contributed by the shared
Remote assembly, but the host service is composed only by the Desktop app, so an
ordinary Web host does not claim them. A Web client has nothing to integrate
(carries no message content or credential by design).
