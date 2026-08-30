# dsh RPC 协议参考（dsh 0.1.1-rc.2）

本文件是 dsh（DeepSeek Harness）Web 服务对外协议的完整参考，供 dsh-emacs 的后续
功能开发使用。所有内容核对自仓库 `packages/host/apiproxy/src/api/`（契约层，
零 Node 依赖、浏览器可导入）与 `packages/typert/`（Remote 网关），版本锚定
`dsh-v0.1.1-rc.2`。

- 协议设计：**四象限消息模型** —— 逻辑消息与物理通道解耦；HTTP/WebSocket/SSE
  只是载体。
- 通道地址：`http://127.0.0.1:3080`（dsh web 默认端口）。
- 字段名一律使用线上的 camelCase 原名；dsh-emacs 的 `dsh-emacs-protocol.el`
  负责把这些名字收敛到 `cl-defstruct` 访问器。

---

## 1. 传输层

| 通道 | 路径 | 方向 | 用途 |
|---|---|---|---|
| HTTP POST | `/api/<method>` | C→S | 一元 RPC（`session.list`、`session.prompt` …） |
| HTTP POST | `/api/respond` | C→S | 回答服务端请求（审批 / 提问） |
| WebSocket | `/api/events.mux` | S→C | 全会话聚合事件流（mux 帧） |
| WebSocket | `/api/events.host` | S→C | 主机级事件流（host 帧） |
| HTTP GET | `/api/events.mux`、`/api/events.host` | S→C | 同源 SSE 回退（Node/进程内客户端） |
| HTTP GET | `/api/session.export` | S→C | 会话日志 ZIP 下载（无信封） |
| HTTP POST | `/api/<namespace>/<method>` | C→S | typert Remote（`commands/execute`、`goals/create` …），payload 为 `{args: {...}}` |

- 所有 `/api` POST 必须 `content-type: application/json`，否则 415；body 非 JSON
  返回 400。HTTP 状态只描述载体：业务成功/失败都走 200 + 信封里的 `result`。
- 请求体上限默认 300 MiB（`DEFAULT_MAX_REQUEST_BODY_BYTES`，为 200 MiB 图片
  上限的 base64 膨胀预留）。
- 浏览器端的 mux/host 流是 **WebSocket**；非浏览器（Node、测试）用 **SSE**
  （`data: <json>\n\n` 分帧，打开时先发一行注释 `: connected\n\n`）。dsh-emacs
  走 WebSocket，断线后按 mux 重连 + `session.history` 补页处理。

---

## 2. 四象限消息模型（`api/rpc.ts`）

四种消息构成判别联合（判别字段 `type`）：

### 2.1 client-request（客户端发起，POST `/api/<method>` body）

```json
{ "type": "client-request", "rpcId": "<uuid>", "method": "session.prompt", "payload": { ... } }
```

- `rpcId`：客户端自造（`crypto.randomUUID()`），响应原样回显。

### 2.2 server-response（该 POST 的响应 body）

```json
{
  "type": "server-response",
  "rpcId": "<echo>",
  "result": { "ok": true,  "value": { ... } }
}
```

失败形：

```json
{ "type": "server-response", "rpcId": "<echo>",
  "result": { "ok": false, "error": { "code": "session-not-found", "message": "...", "details": { "sessionId": "..." } } } }
```

- `result.value` 在空值业务结果时整个缺省（不是 `null`）。
- 信封无法解析时用固定哨兵 `rpcId = "invalid-request"` 回一个 `bad-request`。

### 2.3 server-request（服务端发起，mux/host 流帧）

```json
{ "type": "server-request", "rpcId": "<uuid>", "method": "session/event", "payload": { ... } }
```

- `method` == `payload.type`。
- **可回答**的帧（`approval/requested`、`question/requested`）：`rpcId` 是该交互
  的稳定逻辑 id（重连重放时原样复用），通过 POST `/api/respond` 回答。
- **纯推送**帧（`session/event` 等）：`rpcId` 只标识这一次推送。

### 2.4 client-response（回答 server-request，POST `/api/respond` body）

```json
{ "type": "client-response", "rpcId": "<echo>", "result": { "ok": true, "value": { ... } } }
```

该 POST 的响应是**载体回执**：

```json
{ "accepted": true }
{ "accepted": false, "reason": "not-pending" | "bad-response" }
```

---

## 3. 错误模型（`api/rpc.ts` 的 `RpcErrorDetailsMap`）

统一错误体：`{ code, message, details }`，`details` 必填（无内容时是 `{}`）。
`code` 是闭集判别字段。完整表：

| code | details |
|---|---|
| `bad-request` | `{ issues: [...] }` |
| `cancelled` | `{}` |
| `session-not-found` | `{ sessionId }` |
| `model-unavailable` | `{ provider, model }` |
| `session-conflict` | `{ sessionId, requestedCwd, existingCwd? }` |
| `invalid-time-zone` | `{ value }` |
| `workspace-attach-failed` | `{ sessionId, workspaceId }` |
| `workspace-not-found` | `{ workspaceId }` |
| `workspace-invalid-path` | `{ path }` |
| `workspace-name-conflict` | `{ name }` |
| `workspace-move-invalid` | `{ workspaceId, sessionId, beforeSessionId? }` |
| `directory-unreadable` | `{ path }` |
| `directory-exists` | `{ path }` |
| `directory-create-failed` | `{ path }` |
| `directory-picker-unavailable` | `{ capability }` |
| `agent-preset-read-only` | `{ agentPreset, reason }` |
| `agent-preset-locked` | `{ sessionId, agentPreset }` |
| `agent-preset-conflict` | `{ sessionId, requestedPreset, existingPreset? }` |
| `agent-preset-not-found` | `{ agentPreset, available: string[] }` |
| `agent-preset-invalid` | `{ agentPreset, reason }` |
| `agent-busy` | `{ reason }`（subagent 会话被普通路径寻址时也返回此码） |
| `attachment-error` | `{ reason }` |
| `queue-item-not-found` | `{ itemId }` |
| `steer-unavailable` | `{ itemId }` |
| `command-error` | `{}`（契约声明：已知命令的用法/状态错误；rc.2 无产生点，见 §4.1） |
| `unknown-command` | `{}`（契约声明：`/name` 未命中注册表；rc.2 无产生点，见 §4.1） |
| `settings-rejected` | `{ ns }` |
| `settings-conflict` | `{ ns, expected, actual }` |
| `credential-rejected` | `{ ref }` |
| `model-discovery-failed` | `{ settingsNs, baseURL? }` |
| `title-invalid` | `{ sessionId }` |
| `fork-unavailable` | `{ sessionId }` |
| `subagent-parent-unavailable` | `{ parentSessionId }` |
| `subagent-not-found` | `{ parentSessionId, childSessionId }` |
| `subagent-catalog-diagnostic` | `{ parentSessionId, childSessionId, reason: 'corrupt'\|'unsupported'\|'unavailable' }` |
| `subagent-not-resumable` | `{ childSessionId }` |
| `subagent-unauthorized` | `{ childSessionId }` |
| `subagent-delivery-unavailable` | `{ childSessionId }` |
| `internal` | `{}`（catch-all） |

> dsh-emacs 注意：`command-error` / `unknown-command` 是契约注释声明的错误码，但
> rc.2 的 `session.prompt` 实现不产生它们（见 §4.1）。dsh-emacs 走 `commands.execute`
> 的先试路径（admission miss = 结果 `undefined`，fallback 为普通消息），与 web 一致，
> 不需要依赖这两个码。

---

## 4. 一元 RPC 方法（`RpcMethodMap` → POST `/api/<method>`）

下方每节列出：请求 payload、响应 value、相关错误码与关键语义。可选字段以 `?` 标注。

### 4.1 session.*

#### session.list
```
payload  { cursor?: string }              // cursor 是 v1 预留位，未实现
value    { items: SessionSummary[] }      // updatedAt 降序
```
`SessionSummary`：`{ sessionId, updatedAt, running, blank, parentSessionId?,
origin?: 'subagent', cwd?, agentPreset?, projections?: SessionProjectionsBlock }`。
`projections` 直接可播入客户端投影存储（更高 seq 覆盖规则），`asOfSeq` 说明新鲜度。

#### session.search
```
payload  { query: string }                // 1..500 字符，不含 NUL
value    { items: SessionSearchItem[], hasMore: boolean }
```
`SessionSearchItem`：`{ sessionId, snippet }`（snippet ≤ 240 码点）。最多 20 条，
无游标 —— `hasMore` 提示客户端细化查询。搜索面 = 当前 user/assistant/steering 消息。

#### session.create
```
payload  { workspaceId?: WorkspaceId, cwd?: string, sessionId?: SessionId, agentPreset?: string }
value    { sessionId: SessionId, agentPreset?: string }
```
- `workspaceId` / `cwd` 至多一个；都缺省用 Host cwd。
- `sessionId` 可预分配：同 id + 同 cwd 重试幂等；不同 cwd 返回 `session-conflict`。
- workspace 创建后附加失败返回 `workspace-attach-failed`（已发布 sessionId 也带回）。
- 未知 `agentPreset` → `agent-preset-not-found`；组合无法挂载 → `agent-preset-invalid`。

#### session.history
```
payload  { sessionId, beforeSeq?: number, maxMessages?: number }
value    { events: HistoryEntry[], hasMore: boolean, projections?: SessionProjectionsBlock }
```
- 分页按 **append-origin 消息边界**对齐（一页 = 整数条消息的原始事件，绝不在消息
  中间截断）；`beforeSeq` 缺省 = 尾部页（额外带 in-flight partial 与 `projections`）。
- `HistoryEntry`：`{ event: SessionEvent, view?: ToolEventView }`。`view` 是
  分页时刻主机对 tool 事件的渲染意图，从不持久化。
- 读取历史绝不 resume/publish Agent。

#### session.models
```
payload  { sessionId }
value    SessionModels = { current: ModelSelection, routable: boolean,
                           groups: ModelProviderGroup[], failures: ModelCatalogFailure[] }
```
- `routable` 是"能否开一轮"的唯一权威（与 groups 无关：适配器停了但还在广告
  中的模型仍可用）。subagent 拒绝（`agent-busy`）。
- `ModelSelection = { provider, model, reasoningEffort? }`；
  `ModelProviderGroup = { id, name, models: ModelCatalogModel[] }`；
  `ModelCatalogModel = { id, name, description?, reasoning?: { efforts, defaultEffort? } }`。

#### session.selectModel
```
payload  { sessionId, provider, model, reasoningEffort? }
value    { selected: ModelSelection }
```
subagent 拒绝（`agent-busy`）。

#### session.rename
```
payload  { sessionId, title: string }     // 原始标题，host 规范化后决定是否接受
value    { title: string, seq: number }   // 规范化后的接受标题 + session/title 事件的 seq
```
追加 `session/title`（source = user），钉住标题、停止自动生成。空标题 →
`title-invalid`。subagent 拒绝（`agent-busy`）。

#### session.fork
```
payload  { sessionId, atSeq?: number }
value    { sessionId: SessionId }         // 子会话 id
```
`atSeq` 锚定切割：边界是 ≥ atSeq 的第一个 `turn/end`；省略或越界回退到最后一个
已完成轮。仍在进行中的轮 → `fork-unavailable`。子会话继承源 cwd、最新模型目标、
`parentSessionId` 谱系与种子前缀。

#### session.prompt
```
payload  { sessionId, mode: 'queue' | 'steer',
           content: PromptContentPart[], clientTimeZone?: string }
value    { accepted: true, command?: { kind: 'success', text?: string } }
```
- `PromptContentPart`：`{ type: 'text', text }` 或 `{ type: 'image', mediaType,
  data: <base64>, name? }`。**图片是 content 的一部分**，不是独立 payload 字段
  （mediaType 限 png/jpeg/webp/gif）。host 在入队前把图片字节提升为持久引用。
- `mode`：`queue` → 追加为下一轮；`steer` → 插入当前轮（见 §9）。
- **slash 命令**：`sessions.ts` 契约注释声明"content 恰好一个 text 块且以 `/` 开头 =
  slash 命令，host 走命令注册表（mode 无关）执行、成功返回 `command` 槽、用法/状态
  错误返回 `command-error`、未知名返回 `unknown-command"——但 rc.2 的 `session.prompt`
  实现**未接入**该逻辑（api-proxy 的 prompt 没有任何 command 分支，`command-error` /
  `unknown-command` 也无产生点）。实际 web 与 dsh-emacs 都在 composer 层拦截 `/name`
  前缀、直接走 `commands.execute`（见 §5.1），从不经过此槽。客户端实现不应依赖
  `session.prompt` 的 command 槽。
- `clientTimeZone` 必须是 UTC 或合法 IANA 名称，否则 `invalid-time-zone`；缺省合法
  （非浏览器调用方省略即可）。
- 模型不支持图片输入 → `attachment-error`（`reason: MODEL_DOES_NOT_SUPPORT_IMAGES`）。
- subagent 会话拒绝（`agent-busy`）——子会话走 `subagent.prompt`。

#### session.attachment
```
payload  { sessionId, attachmentId }
value    { attachment: ImageAttachmentRef, data: <base64> }
```
`ImageAttachmentRef = { attachmentId, mediaType, bytes, width, height, name? }`。
读取前校验该会话日志确实引用了此图片（否则 `attachment-error`）。

#### session.updateQueue
```
payload  { sessionId, itemId, action: QueueAction }
value    { accepted: true }
```
`QueueAction`：`{ kind: 'edit', content: ContentBlock[] }` | `{ kind: 'remove' }` |
`{ kind: 'steer' }`。edit 只接受 text 内容（非文本 → `attachment-error`）。
- 已不在队列 → `queue-item-not-found`。
- `steer` 只在 **next-turn 且 agent 正在运行**时可用，否则 `steer-unavailable`。
- subagent 会话拒绝（`agent-busy`）。详见 §9。

#### session.cancel
```
payload  { sessionId }
value    { accepted: true }
```
停止当前轮，保留 pending 队列（取消收敛后按 FIFO 恢复）。subagent 拒绝
（`agent-busy`）——子会话用 `subagent.interrupt`。

### 4.2 subagent.*（浏览器安全子代理域）

#### subagent.list
```
payload  { parentSessionId }
value    { entries: SubagentListEntry[], parentAvailable: boolean }
```
`SubagentListEntry`（判别 `kind`）：
- `{ kind: 'child', id, mode: 'one-shot'|'continuable', activity: 'running'|'inactive',
   hasChildren: boolean, label?: string }`（one-shot 的 label 可选，continuable 必填）
- `{ kind: 'diagnostic', id, reason: 'corrupt'|'unsupported'|'unavailable' }`

`parentAvailable` 只是提示；真正的权威检查在 prompt 时。

#### subagent.history
```
payload  { parentSessionId, childSessionId, mode: 'one-shot'|'continuable',
           beforeSeq?, maxMessages? }
value    { events: HistoryEntry[], hasMore: boolean, projections? }
```
与 `session.history` 同构，读 live 子会话内存快照或冷子会话持久日志，不激活 Agent。

#### subagent.prompt
```
payload  { parentSessionId, childSessionId, mode: 'continuable',
           content: ContentBlock[], clientTimeZone? }
value    { messageId }
```
经**精确 live 直接父会话**的 continuation owner 投递到子会话 FIFO inbox；返回被接受
消息 id，后续执行独立于此请求。

#### subagent.interrupt
```
payload  { parentSessionId, childSessionId, mode: 'continuable' }
value    { accepted: true }
```
fire-and-return：`accepted` 只承认已受理取消信号，子会话可能仍短暂显示运行中。
未认领的排队 follow-up 保留并 parked；目标不存在/空闲/已完成也返回 `accepted`。

### 4.3 host.*

#### host.describe
```
payload  {}
value    { version, cwd, provider?, model?, attachedSessions: number, home, canOpenPath: boolean }
```
`version` = 主机应用版本；`provider/model` 是未显式指定时的默认（缺省 = 无显式默认）。

#### host.pickDirectory
```
payload  {}                              // 需 native 能力
value    { path: string | null }          // 取消返回 null
```

#### host.listDirectory
```
payload  { path?: string }                // 缺省 = 主机 home；需 browse 能力
value    DirectoryListing = { path, home, crumbs: DirectoryEntry[], entries: DirectoryEntry[], truncated: boolean }
```
`DirectoryEntry = { name, path, hidden }`；`truncated` = 后端在完整结果上限处截断。
不可读/不存在 → `directory-unreadable`。请求 signal 随调用者取消。

#### host.createDirectory
```
payload  { path: string, name: string }   // 在已存在父目录下建子目录；需 browse 能力
value    { path: string }
```
已存在 → `directory-exists`；其它文件系统失败 → `directory-create-failed`。

#### host.openPath
```
payload  { path: string }
value    { opened: true }
```
用系统默认应用打开（Finder/Explorer/xdg-open）。

### 4.4 workspace.*

`WorkspaceView = { workspaceId, path, title, sessionIds: SessionId[], createdAt, updatedAt }`
（sessionIds 按手动顺序，attach 前插、insertSessionBefore 重排；活动从不重排）。

#### workspace.list
```
payload  {}
value    { items: WorkspaceView[], archivedSessionIds: SessionId[] }
```
archive 集合是重连基线（`host/archived-sessions-changed` 的同样快照）。

#### workspace.create
```
payload  { path: string }                 // 必须是已存在目录（不 mkdir）
value    { workspace: WorkspaceView, created: boolean }
```
缺失/非目录 → `workspace-invalid-path`；已被某 workspace 拥有 → 返回该
workspace 且 `created: false`。

#### workspace.rename
```
payload  { workspaceId, title: string }   // trim 后非空（schema 强制）
value    { workspace: WorkspaceView }
```
未知 id → `workspace-not-found`；与其它 workspace 同题 → `workspace-name-conflict`；
改为当前标题 = 幂等成功。

#### workspace.delete
```
payload  { workspaceId }
value    { deleted: true }
```
只删注册：目录、用户文件、会话日志全不动；这些会话变为未分组。

#### workspace.insertBefore
```
payload  { workspaceId, beforeWorkspaceId? }   // 省略 = 追加到末尾
value    { workspaceIds: WorkspaceId[] }       // 完整持久顺序
```

#### workspace.insertSessionBefore
```
payload  { workspaceId, sessionId, beforeSessionId? }
value    { workspace: WorkspaceView }
```
session 或 anchor 不属于该 workspace → `workspace-move-invalid`；移到当前位置 =
幂等成功。

#### workspace.archiveSession
```
payload  { sessionId }
value    { archivedSessionIds: SessionId[] }   // 完整更新后的集合
```
会话从所有分组面消失但保留日志与 workspace 记账槽；幂等。会话既非 live 也不在
持久化中 → `session-not-found`。

### 4.5 skill.list
```
payload  { sessionId }
value    { skills: SkillEntry[] }
```
`SkillEntry = { name, description, whenToUse?, modelInvocable }`。`modelInvocable:
false` = 仅用户可调（`disable-model-invocation`），不出现在模型目录。
**skill 的调用没有专用 wire**：就是一条普通 `session.prompt`，其前导 `/name`
token 由 `dsh-tool-skill` 在 pre-step 边界注入渲染后的正文。

### 4.6 agentPreset.*

`AgentPresetEntry = { id, trust: 'system'|'user', isDefault, name?, description?, broken? }`。
`broken` 非空 = 该 preset 当前无法组会话（保留列出以便展示/删除）。

#### agentPreset.list
```
payload  {}
value    { presets: AgentPresetEntry[], authorable: boolean, hasDocument: boolean }
```
`authorable` = 部署是否配置了可写入新 preset 的根；`hasDocument` = 能否交给本地
opener。空 roster = 部署不组 preset。

#### agentPreset.select
```
payload  { sessionId, agentPreset }
value    { agentPreset: string }
```
**仅 blank 会话可用**（无轮次已运行）；已有对话后换 preset → `agent-preset-locked`
（历史是在旧工具集下产生的）。subagent 拒绝（`agent-busy`）。

#### agentPreset.read
```
payload  { agentPreset }
value    { agentPreset, trust, content: string, name?, description? }
```
特权方法（组合文本 = 侦察面；`read/copy/openDocument/remove` 均在连接层特权
清单，见 §4.8 的说明）。

#### agentPreset.copy
```
payload  { from, agentPreset, name? }
value    { agentPreset: string }
```
唯一写路径；不跨线传组合文本或路径（host 按 id 解析）。复制保留源描述、不保留
源名字（用 `name` 或 id 回退区分）。

#### agentPreset.openDocument
```
payload  { agentPreset }
value    { opened: true } | { opened: false, path: string }
```
把本地作者 preset 的**目录**交给平台 opener；无 native opener 时回退返回目录路径
供文本展示。shipped preset 拒绝。

#### agentPreset.remove
```
payload  { agentPreset }
value    {}
```
只删本地作者 preset；shipped 拒绝。

### 4.7 goal.*

读侧全部走 `'goal'` 会话投影（`session/projection` 帧 / history 尾部 `projections`
块），**没有 goal.get、没有线上 goal view** —— 响应只回 CAS ref。除 `create` 外
每个动词要求 `{ sessionId, ref: { id, revision } }`（CAS 守卫，revision 不匹配拒绝）；
subagent 会话拒绝（`agent-busy`）。

| 方法 | payload 额外字段 | value |
|---|---|---|
| `goal.create` | `objective: string`, `maxGoalRounds?: number` | `{ ref }` |
| `goal.edit` | `ref`, `objective?`, `maxGoalRounds?`（至少一个） | `{ ref }` |
| `goal.pause` | `ref` | `{ ref }` |
| `goal.resume` | `ref` | `{ ref }` |
| `goal.complete` | `ref` | `{ ref }` |
| `goal.clear` | `ref` | `{ cleared: true }` |

> 另一条等价路径：typert Remote 命名空间 `goals/*`（web 客户端实际使用，见 §5.2）。
> 两者落在同一个 GoalService 上。

### 4.8 settings.*

`SettingsNamespaceView = { ns, schema: <schemastery JSON>, value, base?, user?,
applies: 'live'|'restart', secrets: SettingsSecretView[], revision: number }`。
- 所有出站值都经过 `redactSecrets`：`role('secret')` 字段永不跨线；
  `SettingsSecretView = { path: string[], set: boolean }` 告诉表单该槽存在/已配置。
- `revision` 是写入的 CAS：携带 `expectedRevision` 时，若命名空间已前进 →
  `settings-conflict`（details 带 expected/actual，供重读重试）。

#### settings.describe
```
payload  {}
value    { writable: boolean, hasDocument: boolean, namespaces: SettingsNamespaceView[] }
```
`writable: false`（只读 provider）时禁用一切写控件。

> **设置与凭据域全部 loopback 加固**：`settings.*`（describe/openDocument/update/
> replace/mutate）与 `credentials.*`（describe/set/unset）都在连接层的特权方法
> 清单里（`PRIVILEGED_METHODS`），同列的有 `agentPreset.read/copy/openDocument/
> remove`、`host.pickDirectory`、`host.openPath`、`llm.discoverModels`。浏览器
> 请求以空信任列表过特权围栏（DNS-rebinding / 跨站防御）；非 loopback 客户端
> （LAN）调用这些方法会被拒绝。

#### settings.openDocument
```
payload  {}                               // 无路径 —— 浏览器不能挑任意主机文件
value    { opened: true }
```
缺文档时物化并交给平台文本 opener。

#### settings.update
```
payload  { ns, patch: object, expectedRevision? }
value    SettingsNamespaceView            // 新脱敏视图
```
合并补丁到用户层（validate → persist → commit）。secret 字段**可包含**在 patch 中
（只写方向）；schema/存储拒绝 → `settings-rejected`。

#### settings.replace
```
payload  { ns, section: object, expectedRevision? }
value    SettingsNamespaceView
```
整体替换用户 section（`{}` = 重置为组合默认）。section 缺失键即删除，含 secret：
客户端需先折叠 descriptor 的 user 层再补交想保留的 secret。

#### settings.mutate
```
payload  { ns, ops: SettingsPathOpView[], expectedRevision? }
value    SettingsNamespaceView
```
按路径编辑，相对**存储中的 section** 解析（非调用者上次读取）。这是任何持有脱敏
descriptor 的客户端的删除路径。`SettingsPathOpView = { op:'set', path: string[],
value } | { op:'unset', path: string[] }`，空路径 = section 根。

### 4.9 credentials.*

读取结构化无值：`CredentialView = { configured, source?, writable }`。值只在
`credentials.set` 一个方向跨线。没有枚举方法 —— 客户端从 settings schema/value
的 `apiKeyEnv` 字段学习引用名。引用名必须匹配 `^[A-Za-z_][A-Za-z0-9_]*$`。

| 方法 | payload | value | 错误 |
|---|---|---|---|
| `credentials.describe` | `{ refs: string[] }`（≤64） | `{ credentials: Record<string, CredentialView> }` | 非法名 → `bad-request` |
| `credentials.set` | `{ ref, value }` | `{}` | 只读层遮蔽 → `credential-rejected` |
| `credentials.unset` | `{ ref }` | `{}` | 同上；幂等 |

### 4.10 llm.*

#### llm.providers
```
payload  {}
value    { providers: ConfigurableProviderView[] }
```
`ConfigurableProviderView = { provider, displayName, settingsNs, settingsPath:
string[], active, declared? }`。`declared` 缺省 = "未知"而非"未 shipped"。

#### llm.models
```
payload  {}
value    { groups: ModelProviderGroup[], failures: ModelCatalogFailure[] }
```
与 `session.models` 同构、会话无关（设置面用）。

#### llm.discoverModels
```
payload  { settingsNs, provider?, baseURL?, api?, apiKey? }
value    { models: DiscoveredModelView[] }
```
`DiscoveredModelView = { id, name?, contextWindow?, maxTokens? }`。payload 是**草稿**
非存储路由；`apiKey` 接受但永不存储/返回。什么都不写 —— 只是候选。

---

## 5. typert Remote（`/api/<namespace>/<method>`，payload `{ args: {...} }`）

Remote 是另一套 RPC 面：宿主服务方法经 `@Remote` 标记注册到 typert 注册表，
网关（`@deepseek-ai/dsh-api-gateway`）在 `/api` 前缀上拦截 `namespace/method`
端点。**请求 payload 必须恰好是一个纯对象 `args`**；响应信封同 §2.2（`result.value`
对 void 结果缺省）。`agentId` 是 lookup 参数（解析为该会话的 live Agent）。

### 5.1 commands.*（slash 命令注册表 —— dsh-emacs 已在用）

#### commands/list
```
payload  { args: { agentId: SessionId } }
value    CommandDescriptor[]             // name 升序
```
`CommandDescriptor = { name, description, input?: { hint, images?: boolean } }`。

#### commands/execute
```
payload  { args: { agentId, line: string, images: EncodedImage[] } }
value    CommandExecution | undefined    // undefined = admission miss（语法或未知名）
```
- `line` 是完整命令行（含前导 `/`）；`images` 是必需字段（无图 = `[]`）。
- `CommandExecution = { commandId, result: { kind:'success', text?, sourceEventSeq? }
  | { kind:'error', text } }`。
- 受理后日志 `command/run` + `command/done` 会话事件（不在模型面）；admission miss
  不记日志。图片仅当命令声明 `input.images: true` 时接受，否则 `error` 结果。
- 注册/注销时触发 host 事件 `commands/change`（经 `host/remote-event` 转发，
  见 §7.2）。

### 5.2 goals.*（web 客户端实际使用的 goal 面）

与 §4.7 的 `goal.*` 等价，但 payload 形状与返回形状都不同（web 的 ui-goal 走这里；
生成自 `GoalService` 的 `@Remote` 方法）：

| 端点 | payload args | value |
|---|---|---|
| `goals/create` | `{ agentId, request: { objective, maxGoalRounds? } }` | `{ ref: GoalRef }` |
| `goals/edit` | `{ agentId, ref, request: { objective?, maxGoalRounds? } }` | `GoalView` |
| `goals/pause` | `{ agentId, ref }` | `GoalView` |
| `goals/resume` | `{ agentId, ref }` | `GoalView` |
| `goals/complete` | `{ agentId, ref }` | `GoalView` |
| `goals/clear` | `{ agentId, ref }` | `GoalRef`（裸 `{ id, revision }`，非 `{ ref }`） |

- `GoalRef = { id, revision }`；`GoalView = GoalSnapshot & { roundsStarted,
  createdAt, updatedAt, activation: 'armed'\|'disarmed' }`，其中
  `GoalSnapshot = { id, revision, objective, phase, blockedReason?, maxGoalRounds }`。
- 注意与 §4.7 的 `goal.*`（RpcMethodMap 面）不同：那边所有变更统一回 `{ ref }`
  （clear 回 `{ cleared: true }`），而这边的 typert 面除 create 外都回完整
  `GoalView`。两种面都落在同一个 GoalService 上。

### 5.3 其余 Remote（web 用，扩展能力）

| 端点 | args | value 摘要 |
|---|---|---|
| `fileReferences/list` | `{ agentId, query }` | 文件引用候选（`@`/`@"` 路径提示） |
| `sessionReferenceResolver/candidates` | `{ agentId, query }` | 会话引用候选（带 `mention` 文本） |
| `messageFeedback/list` | `{ request: { sessionId } }` | `{ items: MessageFeedbackItem[] }` |
| `messageFeedback/put` | `{ request: { sessionId, messageId, rating: 'positive'\|'negative', note?, ifVersion } }` | `{ ok, value: { messageId, rating, note?, version, createdAt, updatedAt } }` 或 `{ ok: false, error: { code: 'session-not-found'\|'target-not-found'\|'version-conflict'\|… } }` |
| `messageFeedback/delete` | `{ request: { sessionId, messageId, ifVersion } }` | `{ ok, value: { absent: true } }` 或 `{ ok: false, error: { code: 'session-not-found'\|'version-conflict'\|… } }` |
| `pluginInventory/list` | `{}` | 插件清单 `{ entries: [{ entryId, moduleName, enabled, fiberPhase }] }` |
| `cordis/*`（dynamic-package 等） | 见 cordis-host-runner | 插件动态装载/检查 |

> 注意 `messageFeedback/*` 不走 `agentId` lookup，而是直接用 `{ request: { sessionId,
> … } }` 信封（与 fileReferences/sessionReferenceResolver 的 `{ agentId, query }`
> 不同）。

> 这些扩展面在 dsh-emacs 中暂未使用；有需求时按 `{args}` 信封直连即可。

---

## 6. 事件流帧

### 6.1 mux 帧（`/api/events.mux`，`events.ts` 的 `MuxFrame`）

打开时对**每个会话**发一个 `session/subscribed`（含冷会话），然后重放 pending 的
`approval/requested` / `question/requested`（rpcId 原样复用 —— 刷新恢复基线），
以及有 pending 队列/任务的 `session/queue` / `session/jobs` 快照。
`since` 参数 v1 未实现（忽略）；重连 = 重开流 + 重取 history。

| type | payload | 说明 |
|---|---|---|
| `session/event` | `{ sessionId, event: SessionEvent, view?: ToolEventView }` | 原始会话事件透传 + 可选渲染意图 |
| `session/subscribed` | `{ sessionId, lastSeq: number }` | 打开基线；`lastSeq` 可对比 history 的 `asOfSeq` |
| `approval/requested` | `{ sessionId, approvalId, toolName, callId?, reason? }` | **可回答**：POST `/api/respond` |
| `approval/resolved` | `{ sessionId, approvalId, outcome: 'allowed-once'\|'rejected'\|'cancelled'\|'unavailable' }` | 最终结局 |
| `question/requested` | `{ sessionId, questions: AskUserQuestionItem[] }`（≥1） | **可回答**：POST `/api/respond` |
| `question/resolved` | `{ sessionId, questionRpcId, outcome: 'answered'\|'cancelled' }` | |
| `session/queue` | `{ sessionId, items: QueuedInboxItem[] }` | 完整暂态 inbox 快照（见 §9） |
| `session/jobs` | `{ sessionId, jobs: JobView[] }` | 完整后台任务快照（变化即推，空集也推 `[]`） |
| `session/projection` | `{ sessionId, key, value, seq }` | 投影单元值变化；`seq` = 单元水位，客户端 higher-seq-wins |
| `stream/error` | `{ error: RpcError }` | 流中途实现失败；之后关闭 |

- `AskUserQuestionItem = { id, question, header?, detail?, options?: [{ label,
  description? }], multiSelect?, intent?: { kind:'plan-review', approve } }`。
- `JobView = { id, kind, label, status: 'running'|'stopping'|'completed'|'killed'|'failed',
  detail?, startedAt, finishedAt? }`。

### 6.2 host 帧（`/api/events.host`，`HostFrame`）

| type | payload |
|---|---|
| `host/session-added` | `{ sessionId, blank, parentSessionId?, origin?: 'subagent', cwd?, agentPreset? }` |
| `host/session-removed` | `{ sessionId }` |
| `host/session-status` | `{ sessionId, running: boolean }` |
| `host/agent-error` | `{ sessionId, message }` |
| `host/workspace-changed` | `{ workspace: WorkspaceView }` |
| `host/workspace-removed` | `{ workspaceId }` |
| `host/workspace-order-changed` | `{ workspaceIds: WorkspaceId[] }` |
| `host/archived-sessions-changed` | `{ archivedSessionIds: SessionId[] }` |
| `host/remote-event` | `{ event: string, args: JsonValue[] }`（allowlist 直通） |
| `stream/error` | `{ error: RpcError }` |

`host/remote-event` 转发 allowlist（`@deepseek-ai/dsh-api-remotes`）：
`agent-preset/selected`、`commands/change`、`credentials/reference-updated`、
`cordis/request-run`、`cordis/request-run-resolved`、`cordis/dynamic-package`、
`cordis/dynamic-retract`、`cordis/inspect-query`、`cordis/inspect-query-resolved`、
`llm/adapters-updated`、`settings/document-updated`。

> dsh-emacs 现在订阅 mux 但未处理 `session/projection`、`session/queue`、
> `session/jobs` 三帧 —— 投影帧是 model-picker/footer 之外的"新标题/新 goal"
> 即时来源，queue 帧是队列 UI（§9）的前提。

---

## 7. 会话事件词汇（`SessionEventMap`）

`SessionEvent` 信封：`{ type, seq, time, data, sourceEventSeqs?, surfaceOp?,
ignorable? }`。`seq` 单调连续；`surfaceOp` 只出现在三类 surface 事件
（`user/message`、`assistant/message`、`tool/result`），值为 `'append'` 或
`{ op:'replace', start, end }`；`ignorable: true` = 读者可不认识该 type 而跳过，
否则遇到未知 type 必须拒绝重建。

### 7.1 核心事件（`packages/core/session/src/types.ts`）

| type | data | 说明 |
|---|---|---|
| `turn/start` | `{ turn }` | 开轮 |
| `turn/end` | `{ turn, reason }` | 关轮；reason 见下 |
| `step/start` | `{ turn, step }` | 开步（一次模型调用 + 其工具执行） |
| `step/end` | `{ turn, step }` | 关步 |
| `user/message` | `UserMessage` | 用户面消息；`source` 区分 human/inject/goal/skill 等 |
| `assistant/chunk` | `{ turn, step, chunk: StreamChunk }` | 原始流块（token 级重放保真） |
| `assistant/message` | `{ turn, step, message, usage?, interrupted?: true }` | 组装好的助手消息；`interrupted` 标记取消前缀 |
| `tool/call` | `{ turn, step, callId, name, arguments: string }` | `arguments` 是模型原始 JSON 字符串（未解析） |
| `tool/result` | `{ turn, step, message, error?: { name, code }, meta? }` | 模型面结果；`meta` 由工具自持（须 JSON 安全） |
| `todo/write` | `{ todos: TodoItem[] }` | 整表快照，last-wins；log-only |
| `request/header` | `{ header: EpochHeader, reason: 'initial'\|'resume'\|'change' }` | 下一请求完整头；log-only |
| `request/context` | `{ provider, model, contextWindow? }` | 路由元数据（变化才记）；log-only |
| `session/end-seed` | `{}` | 构造种子结束标记（resume/fork/replay 边界） |

`turn/end.reason`：`{ kind:'completed' }`、`{ kind:'aborted', reason: AgentCancelCause }`、
`{ kind:'blocked' }`、`{ kind:'error', error: LlmFailure }`、`{ kind:'max-tokens' }`、
`{ kind:'interrupted' }`。`AgentCancelCause = { kind:'user'|'parent'|'disposed' } |
{ kind:'hook', reason } | { kind:'legacy' }`（`disposed` 是关闭时取消）。

`TodoItem = { content, status: 'pending'|'in_progress'|'completed' }`。

### 7.2 插件扩展事件

| type | data 摘要 | 来源包 |
|---|---|---|
| `goal/change` | 全量目标变更：`{ kind:'goal/change', version:1, operation: 'create'\|'edit'\|'pause'\|'resume'\|'complete'\|'block', goal, roundsStarted, createdAt, updatedAt }` 或 clear 墓碑 `{ operation:'clear', cleared, clearedAt }` | `dsh-goal` |
| `command/run` | `{ commandId, name, args?, source }` | `dsh-commands` |
| `command/done` | `{ commandId, kind: 'success'\|'error', text?, sourceEventSeq? }` | `dsh-commands` |
| `compaction/start` | `{ compactionId, sourceCommandId?, turn: number\|null }` | `dsh-compaction` |
| `compaction/summary` | `{ compactionId, sourceCommandId?, summary: ContentBlock[], shadowedRange, shadowedSeqs, shadowedTokenCount, provider, model, maxTokens?, usage?, rawOutput? }` | `dsh-compaction` |
| `compaction/end` | `{ compactionId, sourceCommandId?, turn, error? }` | `dsh-compaction` |
| `compaction/prune` | `{ shadowedRange, shadowedSeqs, shadowedTokenCount }` | `dsh-compaction` |
| `plan/mode` | `{ active: boolean }` | `dsh-plan-mode` |
| `feedback/record` | `{ text: string }` | `dsh-command-feedback` |
| `session/title` | `{ title, messageSeqs: number[], source: { kind:'user' } \| ... }` | `dsh-session-title` |
| `schedule/change` | 版本化 Schedule 变更 | `dsh-schedule` |
| `subagent/descriptor` | 子代理身份描述符：`{ mode: 'one-shot'\|'continuable', provider, label?, agentProvider?, agentModel?, persona?, toolFilter? }` | `dsh-subagent` |
| `team/*` | `team/member`、`team/task`、`team/message/queued`、`team/message/delivered` …（experimental） | `dsh-agent-team` |

> dsh-emacs 渲染层已消费：`user/message`、`assistant/chunk`、`assistant/message`、
> `tool/call`、`tool/result`、`turn/start`、`turn/end`、`request/header`、
> `request/context`、`command/run`、`command/done`、`session/title`（经 projections）。
> 未消费：`goal/change`、`compaction/*`、`plan/mode`、`feedback/record`、
> `session/queue`（见 §9）、`session/jobs`。

---

## 8. 投影（`session/projection` 帧 + history 尾部 `projections` 块）

投影单元由各插件注册；客户端维护一个**按 key 的每会话值存储**，规则：
higher-seq-wins；history 尾部 `projections` 块可作重连基线。键表（挂载即有）：

| key | value 形状 |
|---|---|
| `title` | `string \| null`（最新 `session/title` 文本，last-wins） |
| `goal` | `{ goal: { id, revision, objective, phase: 'active'\|'paused'\|'blocked'\|'complete', blockedReason?, maxGoalRounds }, roundsStarted, createdAt, updatedAt } \| null` |
| `todos` | `TodoItem[]` |
| `plan` | `{ active: boolean, pending: boolean }` |
| `permissions` | `{ options: [{ value, name, description? }], currentValue }`（`currentValue` 是预设表键或 `custom`；键缺 = 无权限服务） |
| `tokenUsage` | `{ totals: { uncachedInputTokens, outputTokens, cacheReadTokens, cacheWriteTokens }, last: { turn, step, buckets } \| null }` |
| `contextPressure` | `{ pressureTokens?, projectedTokens?, contextWindow? }` |
| `contextBreakdown` | `{ systemTokens, toolsTokens, messageTokens }`（envelope 图 last-wins，消息图随折叠 O(1)） |
| `sessionStats` | `{ turns, steps, llmMs, toolMs, ttftMs, ttftSteps, decodeMs, decodeTokens }` |
| `subagent` | `{ mode: 'one-shot', label?, seq } \| { mode: 'continuable', label, seq } \| null`（子代理身份投影） |
| `subagentTiming` | `{ settledMs, active?: { since, through } }` |
| `imageLimits` | `{ maxImageBytes, maxImagesPerMessage, maxMessageImageBytes, maxImagePixels, maxImageDimension, mediaTypes }`（键缺 = 无附件服务） |
| `sessionListMetadata` | `{ blank: boolean, lastPromptAt: number \| null }`（list 行 hint） |

---

## 9. queue / steer 语义（暂态 inbox）

- **queue**：`session.prompt` 的 `mode: 'queue'` → `agent.followup()`，追加为下一轮。
- **steer**：`mode: 'steer'` → `agent.steer()`，插入当前轮的下一步（"插话"）。
  空闲时 steer 退化为新一轮（AgentLoop 语义）。
- **`session/queue` 帧**是唯一权威 inbox 快照：每次入队/变更/认领/丢弃/重连后推送
  全量。`QueuedInboxItem = { id: MessageId, placement: 'queued'|'steering'|'context',
  message: { id, role, content, source } }`。
  - `queued` → 渲染在 QueueDock（待发送区）；
  - `steering` → 已插入当前轮，渲染在对话尾部（pending steering 气泡）；
  - `context` → 注入上下文（审批等），认领前不可见。
- **`session.updateQueue`**：对 `queued` 项做 `edit` / `remove` / `steer`（§4.1）。
  - `steer` 只对 `next-turn` 且 agent `running` 生效；否则 `steer-unavailable`。
  - 已被认领 → `queue-item-not-found`（幂等收敛：空草稿 Cmd+Enter 全队列插话时
    可能撞上已认领项，静默跳过）。
- Web 交互对照：agent 忙碌时普通 Enter = queue（或 busyEnter 设置），
  `Cmd/Ctrl+Enter` = steer（与 busyEnter 相反）；空草稿 `Cmd/Ctrl+Enter` = 全部插话。
  设置项：`ui-conversation` 命名空间 `busyEnter: 'queue'|'steer'`（默认 `queue`）。

> dsh-emacs 现状：`session.prompt` 固定 `mode: "queue"`，忙碌打断走 `session.cancel`。
> 要支持插话只需把 mode 改为 `"steer"`；队列 UI 需要消费 `session/queue` 帧 +
> `session.updateQueue`。注意 subagent 会话无队列操作（`agent-busy`）。

---

## 10. 会话日志下载（无信封 GET）

```
GET /api/session.export?sessionId=<id>[&includeDescendants=true|false]
```
- 返回 ZIP 附件（`content-disposition: attachment; filename="dsh-session-<id>.zip"`），
  根工件 `session.jsonl` 原样 + 每个子代理后代 `subagents/<id>/<filename>` +
  被引用图片 `media/<attachmentId>.<ext>`。
- `includeDescendants` 只接受 `true`/`false`/缺省，其它值 400。
- 缺服务（session-query/persistence/attachments）→ 500；持久化后端不暴露逐会话原始
  工件 → 501；缺根会话 → 404（都在任何字节产生之前）。
- dsh-emacs 可通过 `url-retrieve`/`curl` 下载后本地解包。
