# dsh RPC 协议参考（dsh 0.1.2-rc.1，master 基线）

本文件是 dsh（DeepSeek Harness）Web 服务对外协议的完整参考，供 dsh-emacs 的后续
功能开发与迁移使用。所有内容核对自仓库 `deepseek-harness` 当前 master
（`76fda72979`，版本锚定 `dsh-v0.1.2-rc.1`，与 npm 发布的 0.1.2-rc.1 同一协议面）。

- 协议模型：**一元 Remote RPC（HTTP POST）+ 复用式 Remote 流（一条 WebSocket）**。
  逻辑消息与物理通道解耦：Remote 调用与 Remote 流共用同一种
  `client-request` / `server-response` 信封与同一套错误体；会话事件/控制态/主机
  通知各自走命名流端点。
- 通道地址：`http://127.0.0.1:3080`（dsh web 默认端口，`--host 0.0.0.0` 被拒绝）。
- **浏览器会话认证**：0.1.2-rc.1 起每个 `/api` 请求与 WebSocket 升级都要求
  `dsh-auth-<sha256(authority)>` 签名 cookie（见 §1.3）。dsh-emacs 现有实现已支持
  从 `dsh web` 打印的 `/?token=…` URL 换取并携带该 cookie。
- 字段名一律使用线上的 camelCase / kebab-case 原名；dsh-emacs 的
  `dsh-emacs-protocol.el` 负责把这些名字收敛到 `cl-defstruct` 访问器。

> **与 0.1.1-rc.2 文档的关系**：本文档取代旧版 `docs/rpc.md`。旧协议面的主体
> （一元 `POST /api/session.*` 等点号方法、`/api/respond`、`/api/events.mux` +
> `/api/events.host` 双 WebSocket、`RpcMethodMap`/`RpcErrorDetailsMap`，所在包
> `packages/host/apiproxy`）已在上游 `refactor(api)`（0.1.2-alpha/rc.1 期间）整体
> 移除。dsh-emacs **客户端当前仍发旧线**（见 §0 迁移对照），本文档描述的 master
> 协议面即其迁移目标。

---

## 0. 0.1.2 迁移对照（dsh-emacs 视角）

| 旧（0.1.1-rc.2，现已删除） | 新（0.1.2-rc.1，master） |
|---|---|
| `POST /api/session.list` …（信封内 `method: "session.list"`，点号名） | `POST /api/<namespace>/<method>`（斜杠两段，信封内 `method` 必须等于 URL 端点）。`session.list` → `session/list` 等，见 §4 |
| `POST /api/respond`（回答 `approval/requested` / `question/requested` 帧） | 无 `/api/respond`。审批/提问以 **waterfall 帧** 从 `$events` 流到达（`{type:'waterfall', event, eventId, agentId, request}`），回答走一元端点 `POST /api/$events/result`，见 §3.3 |
| WebSocket `/api/events.mux`（每会话帧：`session/event`、`session/queue`、`session/jobs`、`session/projection`、审批帧…） | 单条 WebSocket `/api/remote.mux` 复用所有 **Remote 流**：`session/follow`（打开快照 + 事件帧）、`session/control`（全 host 队列/任务/投影基线 + 增量帧）、`workspace/follow`、`$events`。原 `session/queue`/`jobs`/`projection` 帧语义并入 `session/control` |
| WebSocket `/api/events.host`（`host/session-added`、`host/remote-event` …） | `$events` 流的 `emit` 帧（事件名直通，allowlist 见 §6.2）；会话增删改走 `api-session/added|removed|status|error|activity` |
| 无认证（loopback 直连；仅特权方法拒绝非 loopback） | 整个 Host API + WS 升级要求浏览器会话 cookie；loopback 也要 cookie，见 §1.3 |
| 错误码闭集如 `session-not-found`、`command-error` | 错误码改为 **`namespace/kebab-code`** 命名空间化：`session/not-found`、`session/agent-busy`、`gateway/*`、`workspace/*`、`subagent/*`、`agent-preset/*`、`directory-picker/*`、`llm/*` …（§5） |
| 会话历史 `session.history`（`beforeSeq`+`maxMessages`，返回 `HistoryEntry`） | `session/page`（`address` + `throughSeq` 游标 + 消息对齐记录）+ `session/follow` 打开快照；`SessionHistoryRecord = {type:'event'} | {type:'chunks'}`（见 §7） |
| 列表/订阅数据：`session.list` 全量 + mux 帧增量 | `session.list` 全量 + `api-session/*` emit 帧 + `session/control` 投影帧 |
| `session.prompt` 的 command 槽（从未接线）与 `command-error`/`unknown-command` | slash 命令彻底走 `commands/list` + `commands/execute` Remote；`session.prompt` 只回 `{accepted:true}`（新增必填 `requestId`） |
| `host.describe`（version/cwd/home…） | 无对应 Remote；`$events` ready 帧带 `host.home`（§3.3） |

dsh-emacs 迁移清单（按此文档 §4–§9 逐条改 `dsh-emacs.el` / `dsh-emacs-events.el` /
`dsh-emacs-queue.el` 的端点与帧消费即可）：RPC 路径与信封 method 改 `session/list`
等斜杠端点；WS 改为 `/api/remote.mux` 的 open/流帧协议；审批/提问从 respond 改到
`$events` waterfall + `$events/result`；队列/任务/投影从 mux 帧改到 `session/control`。

---

## 1. 传输层

| 通道 | 路径 | 方向 | 用途 |
|---|---|---|---|
| HTTP POST | `/api/<namespace>/<method>` | C→S | 一元 Remote RPC（`session/list`、`session/prompt`、`goals/create` …），body 为 `client-request` 信封、payload 恰为 `{args:{…}}` |
| HTTP POST | `/api/$events/result` | C→S | 一元端点：回答 `$events` 流上的一次 waterfall（审批/提问），payload `{args:{clientId,eventId,outcome}}`（§3.3） |
| WebSocket | `/api/remote.mux` | C⇄S | 全部 Remote 流复用一条连接：每条逻辑流一条 `open` 消息，服务端按流回 `item/error/end`（§3.2） |
| HTTP GET/HEAD | `/api/session.export` | S→C | 会话日志 ZIP 下载（精确 Fetch 路由，无信封；§10） |
| HTTP GET | `/`、`/assets/*` | S→C | 前端静态资源（公开）；根路径负责浏览器会话登录交换（§1.3） |

- 所有 `/api` POST 必须 `content-type: application/json`，否则 **415**；body 非
  JSON 返回 **400**。HTTP 状态只描述载体：业务成功/失败都走 200 + 信封里的
  `result`（`gateway/bad-request` 信封错误也是 200）。
- 只有 Remote（含 `$events/result`）与精确 GET/HEAD Fetch 路由会被认领；未认领的
  `/api/*` POST 返回 **404**（`not found`）。非 POST 的 RPC 路径同样 404。
- 请求体上限默认 **300 MiB**（`DEFAULT_MAX_REQUEST_BODY_BYTES`，为 200 MiB 图片
  聚合上限的 base64 膨胀 + 信封头预留），超限 413。
- 流载体只有一种（浏览器与 dsh-emacs 同构）：WebSocket `/api/remote.mux`，
  JSON 文本消息、宿主侧 ping/pong 保活。Node 进程内客户端另有 `rpc.open` 逻辑流
  等价物，不走 WebSocket（本文档不展开）。
- 会话内容不经 SSE 回退（0.1.2 无 SSE 载体）。

### 1.1 一元请求路由与认领

`/api` 前缀路由（`@deepseek-ai/dsh-client-connection` 注册）先做信任与认证检查，
然后：**精确 GET/HEAD Fetch 路由**（按 pathname+method，目前只有
`/api/session.export`）> **共享通道拦截器**（`@deepseek-ai/dsh-api-gateway` 认领
的两段 Remote 端点 + `$events/result`）> 404。端点段只能由
`[A-Za-z0-9_$.-]+` 组成，空段 / `.` / `..` 拒绝。

网关只认领恰好两段、且存在于**严格描述符注册表**（构建期 typert 生成）或 SRC
活动标记里的端点；源码运行（`node --import tsx`）时退化为参数名推导（SRC 回退，
不做 schema 校验）。Remote 端点 `namespace/method` 与信封内 `method` 必须一致。

### 1.2 信封（client-request / server-response）

一元 POST 的 body 与响应 body 是四种消息里仅存的两种（0.1.2 去掉了
`server-request`/`client-response`，见 §0/§3.3）：

请求（body）：
```json
{ "type": "client-request", "rpcId": "<uuid>", "method": "session/prompt",
  "payload": { "args": { "request": { "sessionId": "…", "mode": "queue", "content": […], "requestId": "…" } } } }
```
- `rpcId`：客户端自造，响应原样回显。
- `method` == URL 端点（`<namespace>/<method>`）；不匹配回 `gateway/bad-request`
  信封错误。
- `payload` 必须**恰好是一个纯对象 `args`**，其字段名精确等于方法形参名（lookup
  形参除外：`agent`/`session` 形参在 wire 上是 `agentId`/`sessionId`）。多数方法只
  有一个名为 `request` 的形参 → `args` 里就是 `{ "request": {…} }` 一层嵌套（个别
  方法如 `directoryPicker/createDirectory` 直接展开 `path`/`name`）。`signal:
  AbortSignal` 是取消信号，不是 args 字段。

响应（body）：
```json
{ "type": "server-response", "rpcId": "<echo>",
  "result": { "ok": true, "value": { … } } }
```
失败形：
```json
{ "type": "server-response", "rpcId": "<echo>",
  "result": { "ok": false, "error": { "code": "session/not-found",
              "message": "…", "details": { "sessionId": "…" } } } }
```
- `result.value` 在空值业务结果时整个缺省（不是 `null`）——void Remote
  （`credentials/set`、`agentPresets/copy` 等）即如此。
- 信封无法解析时：若 body 里有字符串 `rpcId` 用它、否则用哨兵 `rpcId =
  "invalid-request"`，回 `gateway/bad-request`（message `invalid client-request
  message`，details 带 `issues`）。

### 1.3 浏览器会话认证（每个请求都要）

- **启动令牌**：`dsh web` 每次启动生成随机 per-process 令牌并打印
  `dsh web: http://127.0.0.1:<port>/?token=…`。令牌不持久，重启即变。
- **令牌 → cookie 交换**：`GET /?token=<token>`（仅根路径 `/`、GET、恰好一个
  token）→ `303` + `Set-Cookie`；凭 cookie 再 `GET /` 才发 index。任何其它根路径
  请求得到同一句 401。
- **Cookie**：名 `dsh-auth-<base64url(sha256(authority))>`（authority = Host
  头里的 `host[:port]`），值 `v1.<body>.<sig>`（HMAC-SHA256 于持久签名秘密；
  载荷含 authority/expiresAt，默认 30 天），属性 `Path=/; HttpOnly;
  SameSite=Strict`。每次请求验证：cookie 名匹配该 authority、签名有效、未过期。
- **信任栅栏（403）**：Host 头必须是 loopback 主机名（`localhost`、`[::1]`、任意
  127/8 地址）或在 `trustedHosts` 配置里；`sec-fetch-site: cross-site` 拒绝；
  若带 Origin 必须等于 Host（缺 Origin 放行——curl/emacs 即此情形）。
- **认证（401）**：栅栏通过但无有效 cookie → 401。RPC POST、精确 GET 路由、
  `/api/remote.mux` 升级三处一致；升级被拒时以纯 HTTP `401/403` 应答后关闭 socket。
- dsh-emacs 路径：自己拉起的服务自动从 `*dsh-server*` 输出捕获 token 并
  mint cookie（`dsh-emacs-server-auth-token` 供手动服务）；把 cookie 加到每个
  RPC 的 `extra-request-headers` 与 `/api/remote.mux` 的 WS 握手即可。

---

## 2. Remote 编程模型（typert）

业务服务 `extends TypertRemoteService`（`super(ctx, '<service>', {namespace})`，
无 namespace 时默认等于 service key），用装饰器选方法：

- `@Remote('name')` / 裸 `@Remote` → 一元端点 `namespace/method`；
- `@Remote({ mode: 'stream' })` → 流端点（只能经 `/api/remote.mux` open，不能一元
  调用；一元端点反过来不能当流 open，`gateway/signature-invalid`）；
- 形参即 wire args：普通 JSON 形参原名字段；`agent`/`session`/`parentSessionId`
  等由注册的 lookup/context 提供者解析（宿主把 wire 上的 `agentId`/`sessionId`
  解回 live Agent/Session，含**冷会话自动 resume**）；尾参 `signal` 是取消信号。
- 宿主业务包把生成物写进自己 `lib/`：`typert.host.*`（宿主描述符）、
  `typert.remote-client.*`（客户端装配 + 类型合并）。浏览器装配只挂
  `@deepseek-ai/dsh-api-remotes` 选中的贡献包（§4 列出的 namespace 全集）。
- 流方法（`follow`/`control`）与 Remote 一元调用是两个协议面，互不伪装；非 JSON
  载体（导出 ZIP 等）走 `connection.fetch.register` 精确 GET/HEAD 路由。

请求从 HTTP POST 进入后：解码信封 → 断言 `{args}` → 解析端点描述符 → 精确校验
字段（多/缺/错 → `gateway/arguments-invalid` 等）→ lookup/context 解析 →
调 live 服务方法 → 校验返回值 → 包装 `result`。未分类异常折叠为 `gateway/internal`；
`RemoteError`（含业务码与 `gateway/cancelled`）原码上 wire。

---

## 3. 流

### 3.1 `/api/remote.mux` 上的消息

客户端开一条 WS（带 cookie 升级）。之后每条**逻辑流**一条文本消息：

```json
{ "type": "open", "streamId": "<client随机串>", "endpoint": "session/follow",
  "payload": { "args": { "request": { "address": { "kind": "session", "sessionId": "…" } } } } }
{ "type": "cancel", "streamId": "<同一串>" }
```

服务端按流回：
```json
{ "type": "item", "streamId": "…", "value": { … } }
{ "type": "error", "streamId": "…", "error": { "code": "…", "message": "…", "details": {} } }
{ "type": "end", "streamId": "…" }
```
- 值校验：`open` 恰好 `type/streamId/endpoint/payload`；`cancel` 恰好
  `type/streamId`。重复 streamId → 该连接关 1008。二进制消息 → 1003；文本非 JSON
  → 1008。`error` 帧即终止该流（错误体同 §5 错误模型）。
- 宿主每 2s ping；客户端连丢 2 次 pong 即被 terminate。关闭码：宿主 1003/1008/
  1011（终帧无法送达），客户端 1000（dispose）/4000（主动重连）/4002（非法帧）。

### 3.2 逻辑流端点

| endpoint | open payload | 帧内容（item value） |
|---|---|---|
| `session/follow` | `{args:{request:{address,maxMessages?}}}` | 打开快照帧 `snapshot`（header/cursor/records/hasMore/projections），其后为无间隙 `event` 帧（§7） |
| `session/control` | `{args:{}}` | 每代恰好一条 `baseline`，之后 `queue`/`jobs`/`projection` 增量帧（§6.1） |
| `workspace/follow` | `{args:{}}` | 每代一条 `baseline`，之后 `upsert`/`remove`/`order`/`archived`（§4.4） |
| `$events` | `{args:{}}` | `ready`（clientId+host.home）→ `emit`/`waterfall`/`cancel`（§3.3） |

除 `$events` 外，每条流的 payload 与一元 Remote 一致：外层 `{args}`、内部按形参。
`session/follow` 的 args 是单形参 `request`（SessionFollowRequest）。

### 3.3 `$events`：转发主机事件 + 审批/提问 waterfall

`$events` 流由 `@deepseek-ai/dsh-api-remotes` 注册的**唯一**事件源喂给网关，再按
连接代（generation）广播。打开后第一帧：

```json
{ "type": "ready", "clientId": "<uuid>", "host": { "home": "/Users/ed" } }
```

之后的下行帧：
```json
{ "type": "emit", "event": "commands/change", "args": [] }
{ "type": "waterfall", "event": "approval/request", "eventId": "<uuid>",
  "agentId": "<sessionId>", "request": { "toolName": "bash", "callId": "…", "reason": "…" } }
{ "type": "cancel", "eventId": "<该次 waterfall 的 id>" }
```
- **emit**：纯通知，`args` 为事件原参数数组（allowlist 见 §6.2）。
- **waterfall**：宿主在等客户端"接单"——客户端应消费（渲染审批/提问）并把决策/
  回答投回 `POST /api/$events/result`：
  ```json
  { "type": "client-request", "rpcId": "…", "method": "$events/result",
    "payload": { "args": { "clientId": "<ready 帧的 clientId>", "eventId": "<同一 waterfall id>",
      "outcome": { "kind": "result", "value": <决策/回答值> } } } }
  ```
  `outcome.kind` ∈ `result`（携带 value）/ `next`（交给下一个接单者）/
  `rejected`（`{error:{name,message,code?,details?}}`）。`$events/result` 的应答是
  `{ok:true}`（value 缺省）。宿主收到取消（`cancel` 帧或会话结束）后，未决
  waterfall 不再需要回答。
- `approval/request` waterfall 的 `request`（agent/signal 剥除后）= `{toolName,
  callId?, reason?}`；回答 value = `ApprovalOutcome` 字符串：`"allowed-once" |
  "rejected" | "cancelled" | "unavailable"`（web 接单者通常只回 allowed-once /
  rejected，其余交 `next()`）。**wire 上没有 approvalId**：宿主自造的审批 id 只
  出现在持久审计事件对 `approval/asked`（`{id, toolName, callId?, reason?}`）→
  `approval/decided`（`{id, outcome}`）里。
- `user-questions/request` waterfall 的 `request` = `{questions:
  AskUserQuestionItem[]}`；`AskUserQuestionItem = {id, question, header?, detail?,
  options?: [{label, description?}], multiSelect?, intent?: {kind:'plan-review',
  approve}}`（`approve` 是 plan-review 的按钮标签；intent 只改呈现不改协议）。
  回答 value = `{answers: [{id, selected: string[], custom?}]}`（跳过 = `selected:
  []`）。
- 重连：`$events` 由连接控制器按代重开；新代有新 `clientId`，旧 `clientId` 的
  result 成为 no-op。

---

## 4. Remote 命名空间与方法

每节给出：端点（`namespace/method`）、wire `args` 字段、value 形状、相关错误码与
关键语义。可选项以 `?` 标注。实现锚点（master 源码）：
- session / skills / fileReferences → `packages/api/session-controller`
- workspace / directoryPicker → `packages/api/workspace-controller`
- settings / credentials → `packages/api/settings-controller`
- agentPresets → `packages/preset/agent-presets`
- llm → `packages/llm/llm`
- goals → `packages/goal/goal`
- commands → `packages/interaction/commands`
- messageFeedback → `packages/feedback/message-feedback`
- sessionReferenceResolver → `packages/context/session-reference`
- fileReferences（wire owner 在 session-controller，类型/查询语义在
  `packages/context/file-reference`）
- subagents → `packages/subagent/subagent`
- pluginInventory → `packages/host/plugin-inventory`
- dynamicCordisRunner → `packages/extensions/cordis-host-runner`

通用激活策略：`list/search/modelCatalog/canOpenWorkspacePath/page/fork` 与
`attachment` **冷读**（不 resume Agent）；`create/selectModel/rename/prompt` 显式
resume；`updateQueue/cancel` 要求 live Agent；`follow` 打开冷会话、快照发完后按需
提升激活；子代理地址（`address.kind:'subagent'`）永不激活。除另有说明，这些方法
都拒绝子代理会话（`session/agent-busy`，`reason` 提示改用 `subagents` 命名空间）。

### 4.1 session.*

#### session/list
```
args     { request?: { cursor?: string } }   // cursor 是预留位，实现忽略；请求体可为 {}
value    { items: SessionSummary[] }          // updatedAt 降序
```
`SessionSummary = { sessionId, updatedAt, running, blank, parentSessionId?,
origin?: 'subagent', cwd?, projections?: { asOfSeq, values } }`。只列可见会话
（live + 带 cwd 的持久会话）；`projections.values` 是持久投影缓存的部分提示
（title、sessionListMetadata 等键可在此，键表见 §9），缺失单元格表示未知。`updatedAt = max(createdAt,
lastPromptAt)`。冷行经小型冷探测（≤16 事件 / ≤1024 B）得到真实 blank/lastPromptAt，
探测失败降级为可见但未知，绝不失败整请求。

#### session/search
```
args     { request: { query: string } }
value    { items: { sessionId, snippet }[], hasMore: boolean }
```
query 必须非空、≤500 UTF-16 单元、不含 NUL（否则 `gateway/bad-request`）。只搜
当前可见（未遮蔽）的 user/assistant 消息面；最多 20 条、snippet ≤240 码点；
`hasMore` 提示客户端细化查询。

#### session/create
```
args     { request: { workspaceId?, cwd?, sessionId?, agentPreset? } }
value    { sessionId, agentPreset? }
```
- `workspaceId` / `cwd` 至多一个（都给了 → `gateway/bad-request`）；都缺省用宿主
  cwd。传 `sessionId` = 显式 id 收养（同 id 同 cwd 幂等；不同 cwd →
  `session/conflict`；不同 preset → `agent-preset/conflict`）。
- workspace 创建后附加失败 → `session/workspace-attach-failed`（带已发布
  sessionId）；未知 workspace → `workspace/not-found`。
- `agentPreset` 未知/无法装配由 preset 装配层拒绝（`agent-preset/not-found` /
  `agent-preset/invalid`，见 §4.6）；子代理身份 → `session/agent-busy`。

#### session.selectModel
```
args     { request: { sessionId, provider, model, reasoningEffort? } }
value    { selected: { provider, model, reasoningEffort? } }
```
显式 resume 后按 request/header 折叠安装 `model/selection`；路由解析失败 →
`session/model-unavailable`（details 带 provider/model）。

#### session.modelCatalog
```
args     {}
value    ModelCatalog
```
`ModelCatalog = { default: {provider, model, reasoningEffort?}, routableProviders:
string[], groups: ModelProviderGroup[], failures: ModelCatalogFailure[] }`；
`ModelProviderGroup = { id, name, models: [{id, name, description?, reasoning?:
{efforts:[{id,name,description?}], defaultEffort?}}] }`。失败 provider 单列
`failures`，不进 groups。会话无关（设置面/选择器用）。

#### session.canOpenWorkspacePath / session.openWorkspacePath
```
args     {}                                      → value boolean
args     { request: { path: string } }           → value { opened: true }
```
后者把路径交给宿主桌面 opener；空路径 `gateway/bad-request`；中止
`gateway/cancelled`；opener 失败 `gateway/internal`。

#### session.rename
```
args     { request: { sessionId, title: string } }
value    { title: string, seq: number }
```
host 规范化（剥 OSC/CSI/控制/方向字符、空白折叠、UTF-8 字节预算截断不拆码点）；
空结果 → `session/title-invalid`。用户改名**钉住**标题（追加 source=user 的
`session/title`，之后的自动生成不再覆盖）。subagent 拒绝。

#### session.fork
```
args     { request: { sessionId, atSeq? } }
value    { sessionId }                            // 子会话 id
```
冷读源日志。`atSeq` 锚定：边界 = ≥ atSeq 的第一个 `turn/end`；省略或越界回退到
最后一个已完成轮；该 seq 之上没有已完成轮 → `session/fork-unavailable`。子会话
继承 cwd、最新模型目标、`parentSessionId` 谱系与种子前缀（切到下一个 `turn/start`
前）。客户端可自行把新会话标题递增为 "(n+1)"（纯客户端行为）。

#### session.prompt
```
args     { request: { requestId: string, sessionId,
                      mode: 'queue' | 'steer',
                      content: PromptContentPart[], clientTimeZone? } }
value    { accepted: true }                        // 仅回执，无 command 槽
```
- `requestId` **必填**：客户端自造、持久化在最终 user 消息的 source 上
  （`user-rpc` 源），用于乐观回显与队列项 `rpcId` 对账。
- `PromptContentPart`：`{type:'text', text}` 或 `{type:'image', mediaType,
  data: <base64>, name?}`（mediaType 限 png/jpeg/webp/gif）。入队前图片字节提升为
  持久引用（不认未上传的 id）。
- `mode`：`queue` → 追加下一轮；`steer` → 插入当前轮（§8）。
- `clientTimeZone` 须为 UTC 或合法 IANA 名，否则 `session/invalid-time-zone`。
- 当前模型不支持图片 → `session/attachment-invalid`
  （`reason:'MODEL_DOES_NOT_SUPPORT_IMAGES'`）；路由不可用 → `session/model-unavailable`。
- **无 slash 命令语义**：`/name` 由客户端在 composer 层拦截，走 `commands/*`
  Remote（§4.11）；这里不做任何命令分发。
- subagent 会话拒绝（`session/agent-busy`）→ 用 `subagents/prompt`。

#### session.attachment
```
args     { request: { sessionId, attachmentId } }
value    { attachment: ImageAttachmentRef, data: <base64> }
```
`ImageAttachmentRef = { attachmentId, mediaType, bytes, width, height, name?,
originalDimensions? }`。读取前校验该会话日志确实引用了此图（否则
`session/attachment-invalid`，`reason:'ATTACHMENT_NOT_REFERENCED'`）。

#### session.updateQueue
```
args     { request: { sessionId, itemId, action: { kind:'edit', content } |
                      { kind:'remove' } | { kind:'steer' } } }
value    { accepted: true }
```
不 resume 冷 Agent。edit 只收 text 内容（非文本 → `session/attachment-invalid`）；
项已不在队 → `session/queue-item-not-found`；`steer` 只在 **next-turn 项且 agent
running** 时可用，否则 `session/steer-unavailable`。详见 §8。

#### session.cancel
```
args     { request: { sessionId } }
value    { accepted: true }
```
要求 live Agent（无 → `session/not-found`）；停当前轮、保留 pending 队列（收敛后按
FIFO 恢复）。subagent → `subagents/interruptByParent`。

#### session.page
```
args     { request: { address: SessionAddress, throughSeq: number,
                      beforeSeq?, maxMessages? } }
value    { records: SessionHistoryRecord[], hasMore: boolean }
```
向后按消息边界对齐的分页（一页 = 整数条消息的记录，绝不在消息中间截断）。
`address = {kind:'session', sessionId} | {kind:'subagent', parentSessionId,
childSessionId, mode}`。`throughSeq` = follow 打开快照的 inclusive 游标
（-1 = 最新）；`beforeSeq` 省略 = 从 `throughSeq` 那页开始。默认页预算 50 条消息。
`SessionHistoryRecord = {type:'event', event} | {type:'chunks', event}`（`chunks`
打包连续 assistant/chunk 增量，见 §7.1）。子代理地址按对应限制校验（身份/谱系不
符 → `subagent/*` 错误码，见 §5）。读取历史绝不激活 Agent。

#### session.follow（流）
```
open     { args: { request: { address: SessionAddress, maxMessages? } } }
frames   第一条 = { type:'snapshot', header: SessionWireHeader, cursor,
                    records: SessionHistoryRecord[], hasMore,
                    projections: { asOfSeq, values } }
         之后 = { type:'event', event: SessionWireEvent }（无间隙、无打包）
```
- `SessionWireHeader = { version, id, createdAt, cwd?, parentSession?, seedLength?,
  origin?: 'subagent', delegationDepth?, agentPreset? }`（v0 兼容元数据）。
- snapshot 记录 = 至多 maxMessages 条消息对齐的尾部（含 chunk 打包记录）；
  `cursor` = 快照覆盖到的 seq；`projections` 是该会话投影基线（§9）。
- 随后的 live 帧是裸 `event` 记录；`seq` 跳过 → `gateway/internal`（
  "skipped seq"）。普通会话在快照发完后会后台提升激活（读旧页不会）；子代理地址
  永不激活。

#### session.control（流）
```
open     { args: {} }
frames   每代恰好一条 baseline，之后 queue/jobs/projection 增量（见 §6.1）
```
全 host 控制面：队列、后台任务、投影。**替代**了 0.1.1-rc.2 的 mux 帧
`session/queue`、`session/jobs`、`session/projection`。

### 4.2 skills.list

```
args     { request: { sessionId } }
value    { skills: SkillEntry[] }
```
`SkillEntry = { name, description, whenToUse?, modelInvocable }`（name 以 `/name`
形式引用）。冷读：按会话 cwd + 投影 `agentPreset` 选目录视图，只列用户可调 skill。
skill 的**调用没有专用 wire**：就是一条普通 `session.prompt`/`commands.execute`，
正文由 skill 工具注入（无 `modelInvocable` 的只出现在用户面）。

### 4.3 fileReferences.list

```
args     { agentId, query: string }        // agent lookup → agentId；query 为 @/@" 后的路径文本
value    FileReferenceCandidate[]          // [{ path, kind: 'file'|'directory' }]
```
agent 的 cwd 里做路径候选；目录让补全保持打开。取消跟随调用者 signal。

### 4.4 workspace.*

`WorkspaceView = { workspaceId, path, title, sessionIds: SessionId[], createdAt,
updatedAt }`（createdAt/updatedAt 为 ISO-8601 字符串；sessionIds 按手动顺序）。
**没有 workspace/list 一元方法**——列表态来自 `workspace/follow` 流基线。

| 端点 | args | value | 错误 |
|---|---|---|---|
| `workspace/create` | `{ request: { path } }` | `{ workspace, created }` | `workspace/invalid-path`（非已有目录/非目录） |
| `workspace/rename` | `{ request: { workspaceId, title } }` | `{ workspace }` | trim 后空 → `gateway/bad-request`；`workspace/name-conflict`；未知 → `workspace/not-found` |
| `workspace/delete` | `{ request: { workspaceId } }` | `{ deleted: true }` | 只删注册（目录/文件/会话日志不动） |
| `workspace/insertBefore` | `{ request: { workspaceId, beforeWorkspaceId? } }` | `{ workspaceIds }`（完整顺序） | `workspace/not-found` |
| `workspace/insertSessionBefore` | `{ request: { workspaceId, sessionId, beforeSessionId? } }` | `{ workspace }` | session/anchor 不属于该 workspace → `workspace/move-invalid`；同位置幂等 |
| `workspace/archiveSession` | `{ request: { sessionId } }` | `{ archivedSessionIds }` | 非 live 也不在持久化 → `session/not-found` |

#### workspace.follow（流）
```
open     { args: {} }
frames   第一条 = { type:'baseline', value: { items: WorkspaceView[],
                                                archivedSessionIds: SessionId[] } }
         之后 = upsert { workspace } | remove { workspaceId }
              | order { workspaceIds } | archived { archivedSessionIds }
```
archive 集合与 `workspace/archiveSession` 返回值同源；重连基线即 baseline 帧。

### 4.5 directoryPicker.*

本地/浏览后端二选一由部署组成（controller 只表达 wire 动词）。verbs 需要的能力
不匹配时拒绝而非近似：`directory-picker/unavailable`（details 带当前 capability）。

| 端点 | args | value | 错误 |
|---|---|---|---|
| `directoryPicker/pick` | `{}` | `string | null`（取消=null） | `gateway/cancelled`；需 native 能力 |
| `directoryPicker/list` | `{ path? }`（缺省 = home） | `DirectoryListing` | `directory-picker/unreadable` 等 |
| `directoryPicker/createDirectory` | `{ path, name }`（单段名） | `string`（新目录绝对路径） | 名字非法/缺失 → `gateway/bad-request`；`directory-picker/exists`、`directory-picker/create-failed` |

`DirectoryEntry = { name, path, hidden }`；`DirectoryListing = { path, home,
crumbs: DirectoryEntry[], entries: DirectoryEntry[], truncated }`（entries 名字序、
含 symlink；truncated = 后端在完整结果上限截断）。

### 4.6 agentPresets.*

`AgentPresetRoster = { presets: AgentPresetRow[], authorable }`；
`AgentPresetRow = { id, trust: 'system'|'user', isDefault, name?, description?,
broken? }`。`broken` 非空 = 当前无法组会话。id 文法 `^[a-z0-9][a-z0-9-]*$`。

| 端点 | args | value | 说明 |
|---|---|---|---|
| `agentPresets/list` | `{}` | `AgentPresetRoster` | 全量；authorable = 有可写根 |
| `agentPresets/read` | `{ agentPreset }` | `AgentPresetDocument {agentPreset, trust, content, name?, description?}` | 读组合文本；未知 → `agent-preset/not-found` |
| `agentPresets/copy` | `{ from, id, name? }` | void | 唯一写路径，不跨线传组合文本；目标 id 被占/磁盘占用 → `agent-preset/invalid`；无用户根/系统 preset → `agent-preset/read-only` |
| `agentPresets/deletePreset` | `{ id }` | void | 只删本地作者 preset；system trust → `agent-preset/read-only` |
| `agentPresets/select` | `{ agentId, agentPreset }` | `string`（记录下的 preset id） | **仅 blank 会话可用**（无轮次：turnBoundary 未开轮且 lastTurn=0）；已开对话 → `agent-preset/locked`；逐会话串行化 |

### 4.7 settings.*

`SettingsNamespaceView = { ns, schema: <schemastery JSON>, value, base?, user?,
applies: 'live'|'restart', secrets: SettingsSecretView[], revision: number }`。
- 所有出站值都经脱敏：role('secret') 字段永不跨线；
  `SettingsSecretView = { path: string[], set: boolean }`。
- `revision` 是写入 CAS：携带 `expectedRevision` 而命名空间已前进 →
  `settings/conflict`（details 带 expected/actual）。
- 无 provider 时调用 → `gateway/internal`（或对应 `settings/*` 码）。

| 端点 | args | value |
|---|---|---|
| `settings/describe` | `{}` | `{ writable, hasDocument, namespaces: SettingsNamespaceView[] }` |
| `settings/canOpenAgentPresetDirectory` | `{}` | `boolean` |
| `settings/openSettingsDocument` | `{}` | `{ opened: true }`（物化文档并交给平台文本 opener） |
| `settings/openAgentPresetDirectory` | `{ agentPreset }` | `{ opened: true } | { opened: false, path }`（无 opener 时回退路径文本展示） |
| `settings/update` | `{ ns, patch, expectedRevision? }` | `SettingsNamespaceView` |
| `settings/replace` | `{ ns, section, expectedRevision? }` | `SettingsNamespaceView`（`{}` = 重置） |
| `settings/mutate` | `{ ns, ops: SettingsPathOpView[], expectedRevision? }` | `SettingsNamespaceView` |

写错误（写路径统一映射）：schema/存储拒绝 → `settings/rejected`（details 带 ns）；
并发 CAS → `settings/conflict`。`SettingsPathOpView = {op:'set',
path, value} | {op:'unset', path}`，空 path = section 根；`mutate` 相对**存储中的
section** 解析（非调用者上次读取）。

### 4.8 credentials.*

值只在 set 一个方向跨线；读侧给无值视图。引用名文法
`^[A-Za-z_][A-Za-z0-9_]*$`，非法 → `gateway/bad-request`。命名空间由
`settings-controller` 的 `CredentialsController` 挂载（与 `settings` 并列注册）。

| 端点 | args | value | 错误 |
|---|---|---|---|
| `credentials/describe` | `{ refs: string[] }`（≤64） | `{ <ref>: { configured, source?, writable } }` | 非法名/空 → `gateway/bad-request`；无 provider → `gateway/internal` |
| `credentials/set` | `{ ref, value }`（value 非空） | void | 只读层遮蔽 → `credential/rejected` |
| `credentials/unset` | `{ ref }` | void | 幂等；同上 |

代码拼写注意：写拒绝是 **`credential/rejected`**（单数 credential，details 带
`ref`），不是 `credentials/rejected`。

### 4.9 llm.*

| 端点 | args | value | 说明 |
|---|---|---|---|
| `llm/listProviders` | `{}` | `LlmProviderInfo[]`（`{id, name}`） | 有适配器在册的路由 |
| `llm/listConfigurableProviders` | `{}` | `LlmConfigurableProvider[]` | `{provider, displayName, settingsNs, settingsPath: string[], declared?}` |
| `llm/discoverModels` | `{ settingsNs, request: {provider?, baseURL?, api?, apiKey?} }` | `LlmDiscoveredModel[]`（`{id, name?, contextWindow?, maxTokens?}`） | 草稿非存储路由；apiKey 接受但永不存储/返回；失败 → `llm/model-discovery-rejected` |

设置面的**模型列表**在 `session/modelCatalog`（§4.1）而不是 llm——provider 目录
只描述可配置 provider。

### 4.10 goals.*

typert 命名空间 `goals`。读侧靠 `goal` 会话投影（§9）+ 无独立 goal view 端点；
动词都经 `agentId` lookup 到 live Agent，除 `create` 外都带 CAS `ref`（revision
不匹配拒绝）。
`GoalRef = {id, revision}`；`GoalView = {id, revision, objective, phase:
'active'|'paused'|'blocked'|'complete', blockedReason?: {code,message},
maxGoalRounds, roundsStarted, createdAt, updatedAt, activation:
'armed'|'disarmed'}`。

| 端点 | args | value |
|---|---|---|
| `goals/create` | `{ agentId, request: { objective, maxGoalRounds? } }` | `{ ref }` |
| `goals/edit` | `{ agentId, ref, request: { objective?, maxGoalRounds? } }` | `GoalView`（至少改一项） |
| `goals/pause` | `{ agentId, ref }` | `GoalView` |
| `goals/resume` | `{ agentId, ref }` | `GoalView` |
| `goals/complete` | `{ agentId, ref }` | `GoalView` |
| `goals/clear` | `{ agentId, ref }` | `GoalRef`（墓碑，裸 ref 非包 `{ref}`） |

create 在已有非 complete 目标时报业务错误；`maxGoalRounds` 缺省 = 部署默认
（256）。`activation`（armed/disarmed）是进程内续跑资格，不持久。
> 错误形态注意：goals 域抛的是 `GoalError`（普通 Error 子类，非 RemoteError，且该
> 包未合并 RemoteErrorDetailsMap），所以失败的 goal 变更当前在 wire 上折叠为
> `gateway/internal`（message 保留原文），客户端无法用 code 判别
> already-exists/stale-revision 等。客户端应以 `goal` 投影（§9）读当前状态并用
> 返回/投影的 `ref` 做 CAS。

### 4.11 commands.*（slash 命令注册表 —— dsh-emacs 已在用）

| 端点 | args | value |
|---|---|---|
| `commands/list` | `{ agentId }` | `CommandDescriptor[]`（name 升序） |
| `commands/execute` | `{ agentId, line: string, images: EncodedImageAttachment[] }` | `CommandExecution | undefined`（undefined = admission miss） |

- `CommandDescriptor = { name, description, input?: { hint, images?: boolean } }`。
- `line` 是完整命令行（含前导 `/`）；`images` 是必需字段（无图 = `[]`）。
- `CommandExecution = { commandId, result: { kind:'success', text?, sourceEventSeq? }
  | { kind:'error', text } }`。
- 受理后记 `command/run` + `command/done` 会话事件（模型面之外）；admission miss
  不记日志。图片仅当命令声明 `input.images: true`，否则 `error` 结果（先 settle
  `command/done`）。注册/注销时发宿主事件 `commands/change`（§6.2 emit 帧）。

### 4.12 messageFeedback.*

会话侧车文件（sidecar）读改写。三个端点都用**单形参 `request`**，且返回值自带
`{ok:…}` 判别（非信封错误；信封错误只留给 transport/框架问题）：

| 端点 | args（request 内） | value |
|---|---|---|
| `messageFeedback/list` | `{ sessionId }` | `{ ok: true, value: { items } }` 或 `{ ok: false, error: { code: 'session-not-found' } }` |
| `messageFeedback/put` | `{ sessionId, messageId, rating: 'positive'\|'negative', note?, ifVersion: Version\|null }` | `{ ok: true, value: MessageFeedbackItem }` 或 `{ ok: false, error: { code, … } }` |
| `messageFeedback/delete` | `{ sessionId, messageId, ifVersion }` | `{ ok: true, value: { absent: true } }` 或 `{ ok: false, error: … }` |

`MessageFeedbackItem = { messageId, rating, note?, version, createdAt, updatedAt }`；
业务错误码：`session-not-found` / `target-not-found`（消息不是 append-origin
assistant 消息）/ `version-conflict`（details 带 current）/ note 校验（
`note-blank`/`note-too-large` 等）。`ifVersion` = 乐观锁：put 传 `null` 表示"必须
无旧项"。同值重放 = 幂等 no-op（版本不变）。

### 4.13 sessionReferenceResolver.candidates

```
args     { agentId, query: string }
value    SessionReferenceMentionCandidate[]
```
`SessionReferenceCandidate = { sessionId, label, cwd?, sameWorkspace, createdAt }`；
candidates 端点每个还带 `mention`（`@[label](dsh-session:…)` 提示文本）。self
被排除，其 cwd 参与排序；`query` 对 sessionId/cwd/title 做大小写不敏感子串匹配。

### 4.14 subagents.*（子代理控制）

| 端点 | args | value | 说明 |
|---|---|---|---|
| `subagents/list` | `{ parentSessionId }` | `SubagentCatalog`（`{ entries, parentAvailable }`） | entries 元素：`{kind:'child', id, mode:'one-shot'\|'continuable', activity:'running'\|'inactive', hasChildren, label?}`（one-shot label 可选，continuable 必填）或 `{kind:'diagnostic', id, reason:'corrupt'\|'unsupported'\|'unavailable'}` |
| `subagents/prompt` | `{ request: { requestId, parentSessionId, childSessionId, mode:'continuable', content: PromptContentPart[], clientTimeZone? } }` | `{ messageId }` | 经**精确 live 直接父会话**投到子会话 FIFO inbox（delivery=queue，收进即回执，与后续执行无关）；图片先受理提升；时区/图片校验同 session 面 |
| `subagents/interruptByParent` | `{ childSessionId, parentSessionId, mode: 'continuable' }` | `{ accepted: true }` | fire-and-return；目标不存在/空闲/已完成 = accepted |

`subagents/list` 的深读（历史/follow/page）都走 `session.*` 的 `address` 子代理变体
（`{kind:'subagent', parentSessionId, childSessionId, mode}`）。
错误码 `subagent/not-found`、`subagent/unauthorized`、`subagent/parent-unavailable`、
`subagent/not-resumable`、`subagent/delivery-unavailable`、
`subagent/projections-unavailable`、`subagent/attachment-invalid`、
`subagent/invalid-time-zone`（details 见 §5）。注意子代理身份读侧还有投影键
`subagent` / `subagentTiming`（§9）。

### 4.15 pluginInventory.list

```
args     {}
value    PluginInventorySnapshot
```
`{ entries: [{ entryId, moduleName, enabled, fiberPhase: 'pending'|'loading'|
'active'|'failed'|'unloading'|null }], agentPresets?: [{id, trust, name?, isDefault,
broken?, rows: [{entryId, moduleName, enabled: bool|'conditional', condition?,
fiberPhase}]}] }`——Loader 实时状态；有 agent-preset roster 时附带各 preset 组合行
（宿主真正跑模型插件的清单）。插件动态装载/检查的另面在 `dynamicCordisRunner`
（cordis-host-runner：`runHostHalf`、`stopFromPanel`、`undefineFromPanel`、
`invoke`、`inventory`、`getClientCode`、`resolveRequestRun`、`settleUserRun`、
`reportRenderFailure`、`reportClientGuardFailure` 等，web 面板扩展用，dsh-emacs
暂不需要）。

---

## 5. 错误模型

统一错误体：`{ code, message, details }`，`details` 必填（无内容时是 `{}`）。
`code` 是闭集判别字段，按归属命名空间前缀；各业务包用
`declare module '@deepseek-ai/dsh-typert-protocol' { interface
RemoteErrorDetailsMap … }` 声明自己的码与 details 形状。未分类异常折叠为
`gateway/internal`；HTTP/WS 两面的同一映射函数（一元信封 error 与流 error 帧）。

### 5.1 基础设施码（gateway/*）

| code | details |
|---|---|
| `gateway/bad-request` | `{ issues: [...] }`（envelope 校验/字段级） |
| `gateway/cancelled` | `{}`（调用方 signal 中止，请求取消） |
| `gateway/arguments-invalid`、`gateway/input-invalid`、`gateway/result-invalid`、`gateway/signature-invalid` | `{ endpoint, field? }` |
| `gateway/binding-invalid`、`gateway/service-unavailable`、`gateway/method-unavailable`、`gateway/definition-unavailable`、`gateway/invocation-unavailable` | `{ endpoint, field? }` |
| `gateway/ambiguous-endpoint`、`gateway/context-not-found`、`gateway/context-unavailable`、`gateway/context-failed`、`gateway/lookup-not-found`、`gateway/lookup-unavailable`、`gateway/lookup-failed`、`gateway/provider-mismatch` | `{ endpoint, field? }` |
| `gateway/internal` | `{}`（catch-all） |

> lookup 策略（session-controller）把普通身份解析为：
> live Agent 复用 → 冷普通会话自动 resume（并发去重）→ 子代理路由拒绝
> （`session/agent-busy`）。resume/ownership 失败抛自己的业务码（`session/not-found`
> 等）原样上 wire。

### 5.2 会话域（session/*、subagent/*、agent-preset/* 部分）

| code | details | 产生点 |
|---|---|---|
| `session/not-found` | `{ sessionId }` | 一切解析 sessionId 的层（普通会话缺失；cancel 无 live Agent 时） |
| `session/conflict` | `{ sessionId, requestedCwd, existingCwd? }` | create 显式 id 已存在且 cwd 不同 |
| `agent-preset/conflict` | `{ sessionId, requestedPreset, existingPreset? }` | create 显式 id 已存在且 preset 不同 |
| `session/agent-busy` | `{ reason }` | subagent 会话被普通路径寻址（含 list/search/prompt/cancel/updateQueue/selectModel/rename）；其它 prompt 受理失败 |
| `session/model-unavailable` | `{ provider, model }` | selectModel/prompt 路由不可用 |
| `session/invalid-time-zone` | `{ value }` | clientTimeZone 非 UTC/IANA |
| `session/workspace-attach-failed` | `{ sessionId, workspaceId }` | create/fork 发布后附加失败 |
| `session/attachment-invalid` | `{ reason }` | 模型不支持图片 / 图未被日志引用 / 队列编辑非文本 / 附件读取失败 |
| `session/queue-item-not-found` | `{ itemId }` | updateQueue 项已不在队 |
| `session/steer-unavailable` | `{ itemId }` | steer 不在 next-turn 或 agent 未运行 |
| `session/title-invalid` | `{ sessionId }` | 改名规范化后为空 |
| `session/fork-unavailable` | `{ sessionId }` | 无已完成轮 / atSeq 之上无 turn/end |
| `subagent/not-found` | `{ parentSessionId, childSessionId }` | 子代理不可用 |
| `subagent/catalog-diagnostic` | `{ parentSessionId, childSessionId, reason: 'corrupt'\|'unsupported'\|'unavailable' }` | 子代理身份投影损坏/不支持 |
| `subagent/unauthorized` | `{ childSessionId }` | 地址与父/模式不符 |
| `subagent/parent-unavailable` | `{ parentSessionId }` | 父不是 live 普通会话 |
| `subagent/not-resumable`、`subagent/delivery-unavailable` | `{ childSessionId }` | prompt 投递拒绝 |
| `subagent/attachment-invalid`、`subagent/invalid-time-zone` | 同 `session/*` | subagents/prompt 图片/时区 |

### 5.3 其它域

| code | details |
|---|---|
| `workspace/not-found` | `{ workspaceId }` |
| `workspace/invalid-path` | `{ path }`（create 目标不是已有目录） |
| `workspace/name-conflict` | `{ name }` |
| `workspace/move-invalid` | `{ workspaceId, sessionId, beforeSessionId? }` |
| `directory-picker/unavailable` | `{ capability }` |
| `directory-picker/unreadable` | `{ path }` |
| `directory-picker/exists` | `{ path }` |
| `directory-picker/create-failed` | `{ path }` |
| `agent-preset/not-found` | `{ agentPreset, available: string[] }` |
| `agent-preset/invalid` | `{ agentPreset, reason }` |
| `agent-preset/read-only` | `{ agentPreset, reason }`（system trust / 无用户根） |
| `agent-preset/locked` | `{ sessionId, agentPreset }`（会话已开轮） |
| `llm/model-discovery-rejected` | `{ settingsNs, baseURL? }` |
| `settings/rejected` | `{ ns }`（schema/存储拒绝） |
| `settings/conflict` | `{ ns, expected, actual }`（CAS） |
| `credential/rejected` | `{ ref }`（只读层遮蔽等写拒绝；注意是单数 credential） |

> 注意 messageFeedback/* 的业务失败是**返回值里的 `{ok:false,error}`**（§4.12），
> 不是信封错误；其内部码是历史遗留的 `session-not-found`/`target-not-found`/
> `version-conflict`/note 校验码。

---

## 6. 控制面与主机事件

### 6.1 session.control 帧（全 host 实时控制面）

```
baseline   { type:'baseline', value: {
              queues:      Record<sessionId, SessionQueuedItem[]>,
              jobs:        Record<sessionId, SessionJob[]>,
              projections: Record<sessionId, SessionProjectionBaseline> } }
queue      { type:'queue', sessionId, items: SessionQueuedItem[] }        // agent inbox 拼接后全量
jobs       { type:'jobs',  sessionId, jobs: SessionJob[] }                 // 变化即推；空也推 []
projection { type:'projection', sessionId, key, value, seq }               // 单元水位；higher-seq-wins
```
- 每代（每次 open/重连）先发一条 baseline，其后是增量帧。客户端把 baseline 当
  快照（先按 `asOfSeq` 截断再种入），之后增量应用。
- `SessionQueuedItem = { id: MessageId, placement: 'queued'|'steering'|'context',
  rpcId?: SessionRequestId, message: { id, content: JsonValue[] } }`（见 §8）；
  baseline 里 next-turn 项 → `queued`，next-step 且 user 源 → `steering`，其它
  next-step → `context`。`rpcId` 只出现在带它的 user 源消息上。
- `SessionJob = { id, kind, label, status: 'running'|'stopping'|'completed'|
  'killed'|'failed', detail?, startedAt, finishedAt? }`（变化即推全量列表）。

### 6.2 主机事件（`$events` 流 emit 帧 allowlist）

`@deepseek-ai/dsh-api-remotes` 只转发以下宿主事件（事件名直通、参数原样）：

| event | args | 语义 |
|---|---|---|
| `agent-preset/selected` | `(sessionId, agentPreset)` | 会话换 preset 落账 |
| `approval/request` | waterfall | 审批请求（§3.3） |
| `api-session/added` | `(summary: SessionSummary)` | 新会话可见（= session/created） |
| `api-session/activity` | `(sessionId, updatedAt)` | user 消息推进 list 排序 |
| `api-session/error` | `(sessionId, message)` | Agent 在轮外失败 |
| `api-session/removed` | `(sessionId)` | 会话离开宿主注册表 |
| `api-session/status` | `(sessionId, running: boolean)` | 运行态变化 |
| `commands/change` | `()` | 命令注册/注销 |
| `credentials/reference-updated` | `(ref)` | 凭据引用变更 |
| `cordis/request-run`、`cordis/request-run-resolved`、`cordis/dynamic-package`、`cordis/dynamic-retract`、`cordis/inspect-query`、`cordis/inspect-query-resolved` | 插件宿主 | 插件动态装载/面板查询 |
| `llm/adapters-updated` | `()` | 适配器注册变化 |
| `settings/document-updated` | `(ns, revision)` | 设置文档变更 |
| `user-questions/request` | waterfall | 提问请求（§3.3） |

> dsh-emacs 订阅策略建议：`session/control`（baseline + 增量）提供队列/任务/投影
> 三件事；`$events` emit 帧提供 session 级增删改与命令/凭据/设置变化通知。
> 会话**内容**事件只来自 `session/follow`（§7），不经 emit。

---

## 7. 会话事件词汇

### 7.1 事件信封与日志记录

持久/传输用的事件信封（wire 形 `SessionWireEvent`）：
`{ type, seq, time, data, ignorable?, sourceEventSeqs?, surfaceOp? }`。

- `seq` 单调连续（session 内）；`time` epoch 毫秒；`data` 是 JSON 值。
- `surfaceOp` 只出现在三类 surface 事件（`user/message`、`assistant/message`、
  `tool/result`）：`'append'` 或 `{op:'replace', start, end}`（compaction 遮蔽用，
  且事件带 `sourceEventSeqs` 覆盖被遮蔽节点）。
- `ignorable: true` = 读者可不认识该 type 而跳过；缺省 = 必识——遇到未知 type 必须
  拒绝重建。
- **记录打包**：历史页/打开快照里的 `SessionHistoryRecord` 有两种：
  `{type:'event', event}`（单条原始事件）或 `{type:'chunks', event}`（连续
  assistant/chunk 增量行程被打包成一行；wire type 形如 `chunkrow/text-chunks` /
  `chunkrow/reasoning-chunks` / `chunkrow/tool-call-chunks`，data 携带
  turn/step/index/dt/texts/args 行程，可无损展开回原 `assistant/chunk` 事件）。
  展开是客户端的活：`chunks` 不是会话事件、不进会话事件词汇。live follow 帧不带
  打包（只 `event`）。
- JSONL 存储（导出下载）用的是**裸 tag**（`text-chunks`…，无 `chunkrow/` 前缀），
  首行是 `{type:'session', …}` 头——与 wire 的 `chunkrow/*` 命名不同，别混。

### 7.2 核心事件（`packages/core/session` + agent-loop 等）

| type | data | 说明 |
|---|---|---|
| `turn/start` | `{ turn }` | 开轮 |
| `turn/end` | `{ turn, reason }` | 关轮；reason 见下 |
| `step/start` | `{ turn, step }` | 开步（一次模型调用 + 工具执行） |
| `step/end` | `{ turn, step }` | 关步 |
| `user/message` | `UserMessage` | 用户面消息；`source.kind` 区分 human/rpc/plugin/goal… |
| `assistant/chunk` | `{ turn, step, chunk: StreamChunk }` | 原始流块（token 级保真） |
| `assistant/message` | `{ turn, step, message, usage?, interrupted?: true }` | 组装好的助手消息；usage 同挂此事件 |
| `tool/call` | `{ turn, step, callId, name, arguments: string }` | 模型原始 JSON 字符串 |
| `tool/result` | `{ turn, step, message, error?: { name, code }, meta? }` | 模型面结果；`meta` 工具自持（须 JSON 安全） |
| `request/header` | `{ header: EpochHeader, reason, startsSeries? }` | 下一请求完整头；log-only |
| `request/context` | `{ provider, model, contextWindow? }` | 路由元数据（变化才记）；log-only |
| `session/end-seed` | `{}` | 种子结束标记（resume/fork/replay 边界）；log-only |

`turn/end.reason`：`{kind:'completed'}`、`{kind:'aborted', reason}`、
`{kind:'blocked'}`、`{kind:'error', error}`、`{kind:'max-tokens'}`、
`{kind:'interrupted'}`。aborted 的 `reason`（AgentCancelCause）：
`{kind:'user'|'parent'|'disposed'} | {kind:'hook', reason} | {kind:'legacy'}`。
`request/header.reason`：`'initial'|'resume'|'change'|'series'`。

### 7.3 插件扩展事件（SessionEventMap merge，按 producer 包）

| type | data 摘要 | 来源包 |
|---|---|---|
| `model/selection` | `{provider, model, reasoningEffort?}` | dsh-api-session-controller |
| `agent-preset/selected` | `{agentPreset}` | dsh-agent-presets |
| `goal/change` | `{kind:'goal/change', version:1, operation: 'create'\|'edit'\|'pause'\|'resume'\|'complete'\|'block', goal, roundsStarted, createdAt, updatedAt}` 或 clear 墓碑 `{operation:'clear', cleared, clearedAt}` | dsh-goal |
| `todo/write` | `{ todos: TodoItem[] }`（整表 last-wins）；`TodoItem={content, status:'pending'\|'in_progress'\|'completed'}` | dsh-tool-todo |
| `plan/mode` | `{active: boolean}` | dsh-plan-mode |
| `permission/preset` | `{preset: string}` | dsh-permission-presets |
| `sandbox/mode` | `{mode: 'read-only'\|'workspace-write'\|'danger-full-access', source?}` | dsh-sandbox-policy |
| `approval/asked` | `{id, toolName, callId?, reason?}`（审批问询持久对） | dsh-user-approval |
| `approval/decided` | `{id, outcome}` | dsh-user-approval |
| `approval/policy` | `{policy:'ask'\|'never', source?}` | dsh-user-approval |
| `schedule/change` | `{version:1, operation:'create'\|'delete'\|'dispatch', …}` | dsh-schedule |
| `command/run` | `{commandId, name, args?, source:{kind:'user'}}` | dsh-commands |
| `command/done` | `{commandId, kind:'success'\|'error', text?, sourceEventSeq?}` | dsh-commands |
| `compaction/start` | `{compactionId, sourceCommandId?, turn}` | dsh-compaction |
| `compaction/summary` | `{compactionId, sourceCommandId?, summary, shadowedRange, shadowedSeqs, shadowedTokenCount, provider, model, maxTokens?, usage?, rawOutput?}` | dsh-compaction |
| `compaction/end` | `{compactionId, sourceCommandId?, turn, error?}` | dsh-compaction |
| `compaction/prune` | `{shadowedRange, shadowedSeqs, shadowedTokenCount}` | dsh-compaction-tool-result-pruner |
| `session/title` | `{title, messageSeqs, source:{kind:'fallback'}\|{kind:'provider',provider,model?}\|{kind:'user'}}` | dsh-session-title |
| `session/title-llm-request` | `{titleProvider, messageSeqs, route, system, messages, maxTokens}` | dsh-session-title-llm |
| `feedback/record` | `{text}` | dsh-command-feedback |
| `subagent/descriptor` | `{version:3, mode:'one-shot'\|'continuable', provider, label?, agentProvider?, agentModel?, agentReasoningEffort?, persona?, toolFilter?}` | dsh-subagent |
| `subagent/model-selection-policy` | `{allowedModels}` | dsh-tool-subagent |
| `hook/invoked` / `hook/result` | 钩子执行记录 | dsh-hook-protocol |
| `llm/retry` / `llm/retry-started` | 重试记录 | dsh-llm-retry |
| `agent/inbox/spliced` | `{target:'next-turn'\|'next-step', start, removedCount?, inserted, outcome?}` | dsh-agent |
| `tool/code-dispatch-start` / `tool/code-dispatch` | 并行工具派发记录 | dsh-tools |
| `tool-workflow/run-start` / `agent-start` / `agent-end` / `run-end` | workflow 生命周期 | dsh-tool-workflow |
| `team/member`、`team/task`、`team/message/queued`、`team/message/delivered` | 团队状态（experimental） | dsh-agent-team |
| `session-log-deepseek/delivery-accepted` | `{sessionId, throughSeq}` | dsh-session-log-deepseek |
| `web/deepseek-search-llm-request` | 搜索请求记录 | dsh-web-search-deepseek |

> **没有** `session/telemetry`、token-meter 事件：用量挂在
> `assistant/message.usage` + `compaction/*.shadowedTokenCount`，由投影折叠输出
> （tokenUsage/contextPressure/sessionStats 等，§9）。

### 7.4 dsh-emacs 渲染消费指引（迁移核对用）

事件只从**已 follow 的会话**的 `session/follow` `event` 帧流入（打开一个会话 =
`session/follow` + 消费快照/事件帧）。渲染层至少需要：
`user/message`、`assistant/chunk`（含从 `chunks` 打包记录展开的）、
`assistant/message`、`tool/call`、`tool/result`、`turn/start`、`turn/end`、
`request/header`、`request/context`，以及扩展的 `command/run`、`command/done`、
`session/title`。`assistant/message`/`tool/result` 的 `replace` surfaceOp 表示
compaction 遮蔽——渲染层须按 `sourceEventSeqs` 替换旧节点而不是追加。标题与目标/
todo 等状态经投影键（`title`/`goal`/`todos`/`plan`/…，§9）而非事件直接取。
队列/任务态来自 `session/control`（§6.1），审批/提问来自 `$events` waterfall
（§3.3）。

---

## 8. queue / steer 语义（暂态 inbox + 控制面）

- **queue**：`session.prompt` `mode:'queue'` → `agent.followup()`，追加为下一轮
  （成为自己那一轮的唯一消息）。
- **steer**：`mode:'steer'` → `agent.steer()`，插入当前轮的下一步（"插话"）；
  空闲驱动里 steer 退化为新一轮。
- **权威快照**在 `session.control`：baseline 的 `queues` 与 `queue` 帧。
  `placement`：`queued`（下一轮待发，渲染在待发送区）、`steering`（已插入当前轮，
  对话尾部 pending 气泡）、`context`（注入上下文如审批，认领前不可见）。项进入
  持久 user 消息后即从队列镜像退休。
- **`session.updateQueue`**：对 pending 项做 `edit`（仅 text）/ `remove` / `steer`。
  - `steer` 只对 next-turn 项且 agent `running` 生效；否则 `steer-unavailable`。
  - 已被认领 → `queue-item-not-found`（空草稿 Cmd+Enter 全队列插话可能撞上已认领
    项，静默跳过即可）。
- **请求回执对账**：`session.prompt` 的 `requestId` 会出现在 queue 项 `rpcId` 与
  最终 user 消息 source（`user-rpc`）上；客户端据此把乐观回显替换为持久消息。
- Web 交互对照：agent 忙碌时普通 Enter = queue，`Cmd/Ctrl+Enter` = steer；
  空草稿 `Cmd/Ctrl+Enter` = 全部插话。设置项 `ui-conversation` 命名空间
  `busyEnter: 'queue'|'steer'`（默认 `queue`）。
- 子代理会话无队列操作（普通端点全拒，走 `subagents/prompt`）。

---

## 9. 会话投影（session.control `projection` 帧 + follow 快照 `projections`）

投影单元由各插件向宿主 `sessionProjections` 注册；每条单元折叠会话事件成一个
JSON 值。客户端维护**按 key 的每会话值存储**，规则：control 的 `projection` 帧
higher-seq-wins；follow 打开快照的 `projections` 块（`asOfSeq` 对齐）与 control
baseline 的 `projections` 都可作重连/打开基线（先按 asOfSeq 截断再种入）；
`session.list` 行的 `projections.values` 是同一键空间的部分缓存提示。

客户端可见键（17 个，挂载即有）与值形状：

| key | value 形状 |
|---|---|
| `title` | `string \| null`（最新 `session/title` 文本，last-wins） |
| `turnOutline` | `{ turn, seq, prompt, response }[]`（每已完成轮一条，含边界预览） |
| `sessionStats` | `{ turns, steps, llmMs, toolMs, ttftMs, ttftSteps, decodeMs, decodeTokens }` |
| `goal` | `{ goal: {id, revision, objective, phase, blockedReason?, maxGoalRounds}, roundsStarted, createdAt, updatedAt } \| null` |
| `todos` | `TodoItem[] \| null`（首写前 = null） |
| `plan` | `{ active: boolean, pending: boolean }` |
| `permissions` | `{ options: [{value, name, description?}], currentValue }`（键缺 = 无权限服务） |
| `tokenUsage` | `{ uncachedInputTokens, outputTokens, cacheReadTokens, cacheWriteTokens }`（累计总量） |
| `contextPressure` | `{ pressureTokens?, projectedTokens?, contextWindow? }` |
| `contextBreakdown` | `{ systemTokens, toolsTokens, messageTokens }` |
| `agentPreset` | `string \| null`（会话实际跑的 preset） |
| `subagent` | `{mode:'one-shot', label?, seq} \| {mode:'continuable', label, seq} \| null` |
| `subagentTiming` | `{ settledMs, active?: {since, through} }` |
| `schedule` | `ScheduleRecord[]`（该会话有效提醒；有 schedule 服务才挂） |
| `sessionListMetadata` | `{ blank, lastPromptAt }`（list 行 hint） |
| `imageLimits` | `{ maxImageBytes, maxImagesPerMessage, maxMessageImageBytes, maxImagePixels, maxImageDimension, mediaTypes }`（键缺 = 无附件服务） |
| `modelSelection` | `{ lastUsed: {provider, model, reasoningEffort?} \| null, next: … \| null }` |

宿主另有若干**只进状态表不跨线**的单元（`turnBoundary`、`titleInput`、
`subagentModelSelectionPolicy`、`sandboxMode`、`agentTeam`、`timeContext`、
`tmuxContext`、`llmRetry`）——它们用于宿主侧折叠，不出现在 wire 帧里。

> 0.1.1-rc.2 的 mux 投影帧（`session/projection`）在 0.1.2 由
> `session.control` 的 `projection` 增量帧取代；dsh-emacs 迁移时把
> `session/event`-侧投影来源改为 follow 快照 + control 投影帧即可。

---

## 10. 会话日志下载（无信封 GET）

```
GET /api/session.export?sessionId=<id>[&includeDescendants=true|false]
```
- 精确 GET/HEAD Fetch 路由（经认证栅栏 + cookie，同 /api RPC）；返回 ZIP 附件
  （`content-type: application/zip`、`content-disposition: attachment;
  filename="dsh-session-<id>.zip"`）。
- 根工件 `session.jsonl`（header 行 + 事件行）+ 子代理后代
  `subagents/<id>/session.jsonl` + 被引用图片 `media/<attachmentId>.<ext>`。
- `includeDescendants` 只接受 `true`/`false`/缺省，其它值或缺失 sessionId → 400；
  缺服务（session-query/persistence/attachments）→ 500；读根失败 → 500；根会话
  不存在 → 404。
- web composer 另有 `/export` 斜杠命令触发同一下载（不接受路径参数）。
- dsh-emacs 可 `url-retrieve`/`curl` 下载后本地解包（带 cookie）。
