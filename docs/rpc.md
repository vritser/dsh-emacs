# dsh RPC 协议参考（dsh 0.1.5-rc.1，master 基线）

本文件是 dsh（DeepSeek Harness）Web 服务对外协议的完整参考，供 dsh-emacs 的现有
实现维护与后续功能开发使用。所有内容核对自仓库 `deepseek-harness` 当前 master
（`aa8262ec09`，版本锚定 `dsh-v0.1.5-rc.1`，与 npm `latest` 发布的 0.1.5-rc.1
同一协议面）。

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

> **与 0.1.2-rc.1 文档的关系**：本文档取代旧版 `docs/rpc.md`。传输层、信封、认证、
> 流载体、绝大多数命名空间与 0.1.2 相同；差异集中在**会话事件词汇（V3）**、
> **打开的流帧（assistant-stream）**、**新命名空间**（`workspaceFiles`、
> `fileUploads`、`sessionFeedback`）与**新 HTTP 路由**（`/api/file`、
> `/api/present.*`、`/api/session/uploadFileBinary`）。dsh-emacs 客户端**已迁移到
> 本协议面**（`/api/<namespace>/<method>` 一元调用 + 单条 `/api/remote.mux` 上的
> `session/follow`、`session/control`、`workspace/follow`、`$events`）；下节记录
> 0.1.2 与 0.1.5 两轮上游变更，均已完成核对。

## 0. 迁移对照（dsh-emacs 视角）

### 0.1 0.1.2 协议面替换（客户端已完成）

| 旧（0.1.1-rc.2，现已删除） | 新（0.1.2-rc.1 起） |
|---|---|
| `POST /api/session.list` …（信封内 `method: "session.list"`，点号名） | `POST /api/<namespace>/<method>`（斜杠两段，信封内 `method` 必须等于 URL 端点）。`session.list` → `session/list` 等，见 §4 |
| `POST /api/respond`（回答 `approval/requested` / `question/requested` 帧） | 无 `/api/respond`。审批/提问以 **waterfall 帧** 从 `$events` 流到达（`{type:'waterfall', event, eventId, agentId, request}`），回答走一元端点 `POST /api/$events/result`，见 §3.3 |
| WebSocket `/api/events.mux`（每会话帧：`session/event`、`session/queue`、`session/jobs`、`session/projection`、审批帧…） | 单条 WebSocket `/api/remote.mux` 复用所有 **Remote 流**：`session/follow`（打开快照 + 事件帧）、`session/control`（全 host 队列/任务/投影基线 + 增量帧）、`workspace/follow`、`$events`。原 `session/queue`/`jobs`/`projection` 帧语义并入 `session/control` |
| WebSocket `/api/events.host`（`host/session-added`、`host/remote-event` …） | `$events` 流的 `emit` 帧（事件名直通，allowlist 见 §6.2）；会话增删改走 `api-session/added`、`/removed`、`/status`、`/error`、`/activity` |
| 无认证（loopback 直连；仅特权方法拒绝非 loopback） | 整个 Host API + WS 升级要求浏览器会话 cookie；loopback 也要 cookie，见 §1.3 |
| 错误码闭集如 `session-not-found`、`command-error` | 错误码改为 **`namespace/kebab-code`** 命名空间化：`session/not-found`、`session/agent-busy`、`gateway/*`、`workspace/*`、`subagent/*`、`agent-preset/*`、`directory-picker/*`、`llm/*` …（§5） |
| 会话历史 `session.history`（`beforeSeq`+`maxMessages`，返回 `HistoryEntry`） | `session/page`（`address` + `throughSeq` 游标 + 消息对齐记录）+ `session/follow` 打开快照；`SessionHistoryRecord = {type:'event'}`（见 §7） |
| 列表/订阅数据：`session.list` 全量 + mux 帧增量 | `session.list` 全量 + `api-session/*` emit 帧 + `session/control` 投影帧 |
| `session.prompt` 的 command 槽（从未接线）与 `command-error`/`unknown-command` | slash 命令彻底走 `commands/list` + `commands/execute` Remote；`session.prompt` 只回 `{accepted:true}`（新增必填 `requestId`） |
| `host.describe`（version/cwd/home…） | 无对应 Remote；`$events` ready 帧带 `host.home`（§3.3） |

### 0.2 0.1.5 增量（本轮核对重点）

| 0.1.2 | 0.1.5（本版） |
|---|---|
| 会话事件词汇 V2：system prompt 只存在于 `request/header` | **会话格式 V3**：新增 surface 事件 `system/message`（系统提示 = surface node 0，见 §7.2）；`request/header.header` 禁止 `system` 字段 |
| `assistant/message` = `{turn, step, message, usage?, interrupted?}` | 增加 `stream: AssistantStreamRecord[]`（该次尝试的精确流记录）；新增 `assistant/attempt`（未提交 surface 消息的尝试） |
| `assistant/chunk` 事件（token 级增量写日志） | **已移除**。增量改走进程内 `assistant-stream` 帧，需 `assistantStream: true` opt-in（§3.2.1、§7.1；客户端已接入） |
| `SessionWireHeader.seedLength` | `SessionWireHeader.isSeeded: boolean` |
| 历史页 `SessionHistoryRecord = {type:'chunks', event}`（chunkrow 打包） | **已取消打包**：记录只有 `{type:'event', event}`；compact 流内嵌在 `assistant/message.data.stream` |
| 无 workspace 文件读取服务 | 新命名空间 `workspaceFiles`（7 方法，含 `changes` 流）；HTTP `GET/HEAD /api/file?path=`（§4.16、§10） |
| 图片附件内联 base64 | 新命名空间 `fileUploads/upload` + `POST /api/session/uploadFileBinary` 流式上传；`PromptContentPart` 增加 `{type:'file', receiptId}`（§4.17） |
| 无会话级反馈端点 | 新命名空间 `sessionFeedback/record`（`/feedback` 与 Dislike 共用，§4.18） |
| `commands/execute` 的 `images` 参数 | 参数改名 `submittedAttachments: CommandSubmitAttachment[]`（tagged union：image + file receipt，§4.11；客户端已修） |
| 无交付物协议 | 新事件 `deliverables/presented` + `present` 工具 + `GET /api/present.host` / `POST /api/present.open`（§10） |
| `goals` 命名空间无 `get` | 新增 `goals/get`；`goal/activation-changed` 进 `$events` allowlist（§6.2） |

**本轮（0.1.5-rc.1）实测核对**：用 ~/.dsh 的 browser-session 签名密钥对
`http://127.0.0.1:3080` 的活服务逐条探测过本文档的端点。结论：
`session/list`（`_request`）、`agentPresets/*`、`llm/*`、`session/modelCatalog`、
`settings/describe`、`skills/list`、`fileReferences/list`、
`sessionReferenceResolver/candidates`、`subagents/list`、`pluginInventory/list`、
`goals/get`、`commands/list`、`workspaceFiles/stat`、`fileUploads/upload`、
`session.export`、`session/prompt`（含 `{type:'file', receiptId}`）全部通过。

实测中曾发现 `commands/execute` 的参数名不匹配——活服务对 `{"images":[]}` 回
`gateway/arguments-invalid`（`missing "submittedAttachments"; unexpected
"images"`），改传 `{"submittedAttachments":[]}` 即 `ok`。**该缺口已在客户端修复**
（`dsh-emacs-command.el` 发 `submittedAttachments`，并把 `input.images` 改读
`input.attachments`），修复后用活服务复验：带附件与纯文本两种载荷都是
`{"ok":true}`，旧 `images` 字段仍被拒。

迁移清单：WS 只开一条 `/api/remote.mux`；审批/提问走 `$events` waterfall +
`$events/result`；队列/任务/投影走 `session/control`；事件词汇按 §7 的 V3 表消费
（尤其：不要再等 `assistant/chunk`，改为消费 `assistant-stream` 帧（§3.2.1）或
`assistant/message.data.stream`）；`commands/execute` 改发 `submittedAttachments`。
---

## 1. 传输层

| 通道 | 路径 | 方向 | 用途 |
|---|---|---|---|
| HTTP POST | `/api/<namespace>/<method>` | C→S | 一元 Remote RPC（`session/list`、`session/prompt`、`goals/create` …），body 为 `client-request` 信封、payload 恰为 `{args:{…}}` |
| HTTP POST | `/api/$events/result` | C→S | 一元端点：回答 `$events` 流上的一次 waterfall（审批/提问），payload `{args:{clientId,eventId,outcome}}`（§3.3） |
| WebSocket | `/api/remote.mux` | C⇄S | 全部 Remote 流复用一条连接：每条逻辑流一条 `open` 消息，服务端按流回 `item/error/end`（§3.2） |
| HTTP GET/HEAD | `/api/session.export` | S→C | 会话日志 ZIP 下载（精确 Fetch 路由，无信封；§10） |
| HTTP GET/HEAD | `/api/file?path=<absolute>` | S→C | 按绝对路径读取一个有界文件响应（仅正则文件；`content-type` 按扩展名推断；§10.2） |
| HTTP GET | `/api/present.host` | C→S | 交付物桌面能力探测：`{name, available, fileManager}`（§10） |
| HTTP POST | `/api/present.open?sessionId&seq&index` | C→S | 在宿主桌面上打开/定位一个已交付文件；args 里带 `action: 'open'\|'reveal'`（§10） |
| HTTP POST | `/api/session/uploadFileBinary?sessionId[&name]` | C→S | 原始字节上传（`content-type: application/octet-stream`，body 为流）；回 `{ok, value:{receiptId, file}}` 或 `{ok:false, error}`（§4.17） |
| HTTP GET | `/`、`/assets/*` | S→C | 前端静态资源（公开）；根路径负责浏览器会话登录交换（§1.3） |

- 所有 `/api` RPC POST 必须 `content-type: application/json`，否则 **415**；body 非
  JSON 返回 **400**。HTTP 状态只描述载体：业务成功/失败都走 200 + 信封里的
  `result`（`gateway/bad-request` 信封错误也是 200）。
- 精确 Fetch 路由自持状态码（`/api/file` 400/403/404/413/499、`/api/session.export`
  400/404/500、上传路由 400/405/415）；一元 Remote 与 `/$events/result` 一律
  200 + 信封（含业务错误）。
- 只有 Remote（含 `$events/result`）、`/api/file`、`/api/session.export`、
  `/api/present.host`、`/api/present.open`、`/api/session/uploadFileBinary` 会被
  认领；未认领的 `/api/*` POST 返回 **404**（`not found`）。非 POST 的 RPC 路径
  同样 404（精确路由按各自 method 匹配）。
- 请求体上限默认 **300 MiB**（`DEFAULT_MAX_REQUEST_BODY_BYTES`，为 200 MiB 图片
  聚合上限的 base64 膨胀 + 信封头预留），超限 413。
- 流载体只有一种（浏览器与 dsh-emacs 同构）：WebSocket `/api/remote.mux`，
  JSON 文本消息、宿主侧 ping/pong 保活（默认 2s 一个 Ping，上一 Ping 未得 Pong
  则 terminate）。Node 进程内客户端另有 `rpc.open` 逻辑流等价物，不走 WebSocket
  （本文档不展开）。
- 会话内容不经 SSE 回退（无 SSE 载体）。dsh-emacs 现有实现自带一个最小 RFC 6455
  客户端，直接连 `/api/remote.mux`（不经浏览器 EventSource）。

### 1.1 一元请求路由与认领

`/api` 前缀路由（`@deepseek-ai/dsh-client-connection` 注册）先做信任与认证检查，
然后：**精确 Fetch 路由**（按 pathname+method：`/api/session.export`、
`/api/file`、`/api/present.host`、`/api/present.open`、`/api/session/uploadFileBinary`）
> **共享通道拦截器**（`@deepseek-ai/dsh-api-gateway` 认领
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
- HTTP 反向代理若另需 Basic 认证，URL 中的 `user:pass@` 也会随 token
  交换请求发送；交换只选取响应头中的 `dsh-auth-*`，忽略代理自己的 cookie。
  RPC 请求禁用 URL 库的全局 cookie jar，以免它与显式认证 cookie 混发。
  同步和异步 RPC 的 401 都清除被拒绝的 cookie、报告认证错误；不会弹出
  用户名／密码框。下次请求可用配置的 token 重新交换。

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

**这条连接是所有流的唯一多路复用载体**：一条 WS 上可以同时开
`$events` + `session/control` + `workspace/follow`（dsh-emacs 的常驻三件套，
见 `dsh-emacs-events.el` 的 core stream）+ 每个打开的会话一条 `session/follow`。
实践要点（客户端已实现，供后续改动参照）：

- `streamId` 只在**一条连接**内有意义；连接断开后必须重开全部逻辑流。重开
  `session/follow` 会重新拿到 `snapshot`，客户端用 `cursor`/`seq` 水位去重——不要
  把重连当"续传"。
- `error`/`end` 只终止**该 streamId**，不是整条连接；其余流继续服务。
- 宿主不会替客户端重连；dsh-emacs 自己用 watchdog + 退避重连（`$events` 重连会
  产生新 `clientId`，旧代未决 waterfall 必须整体退役且不再应答）。

### 3.2 逻辑流端点

| endpoint | open payload | 帧内容（item value） |
|---|---|---|
| `session/follow` | `{args:{request:{address, maxMessages?, assistantStream?}}}` | 打开快照帧 `snapshot`（header/cursor/records/hasMore/projections[/assistantStream]），其后为无间隙 `event` 帧与可选的 `assistant-stream` 帧（§7.1）。**客户端发 `assistantStream: true`**，否则收不到增量 |
| `session/control` | `{args:{}}` | 每代恰好一条 `baseline`，之后 `queue`/`jobs`/`projection` 增量帧（§6.1） |
| `workspace/follow` | `{args:{}}` | 每代一条 `baseline`，之后 `upsert`/`remove`/`order`/`archived`（§4.4） |
| `workspaceFiles/changes` | `{args:{<scope>}}` | 工作区文件变更流：`WorkspaceFileWatchFrame`（§4.16） |
| `$events` | `{args:{}}` | `ready`（clientId+host.home）→ `emit`/`waterfall`/`cancel`（§3.3） |

除 `$events` 外，每条流的 payload 与一元 Remote 一致：外层 `{args}`、内部按形参。
`session/follow` 的 args 是单形参 `request`（SessionFollowRequest）。
`assistantStream?: true`（0.1.5 新增）请求**进程内**的助手增量帧——Web 端重连后
不需要重放持久 chunk 就能继续显示流式输出；不传则只收持久 `event` 帧
（dsh-emacs 目前不传，靠持久事件渲染即可）。

### 3.2.1 assistant-stream 帧（0.1.5 取代 `assistant/chunk`）

打开快照可带 `assistantStream: {revision, activeAttempt?}`；`activeAttempt` =
`{attemptId, startedAfterSeq, turn, step, nextIndex, stream}`，其中 `stream` 是
打开时已积累的紧凑 chunk 记录。之后的 live 帧：

```json
{ "type": "assistant-stream", "frame": { "type": "start", "attemptId": "…", "revision": 1,
  "startedAfterSeq": 12, "turn": 2, "step": 1 } }
{ "type": "assistant-stream", "frame": { "type": "chunk", "attemptId": "…", "revision": 1, … } }
```

关键语义：这些帧**不是持久会话事件**（不带 `seq`），`revision` 每次 opening 递增，
`nextIndex` 必须密集无缺口；重启/重连后旧 revision 的帧作废。**必须显式 opt-in**：
`session/follow` 的 request 里带 `assistantStream: true` 才会有这些帧，否则一整个
回合只会在 `assistant/message` 落地时一次性出现。

字段分布（实测 0.1.5-rc.1）：**只有 `start` 帧和打开快照的 `activeAttempt`
带 `turn`/`step`**，`chunk` 帧只有 `attemptId/revision/index/time/chunk`；渲染器
若按 turn/step 给流式正文分组，必须自己记住这对值。

dsh-emacs 的消费方式（`dsh-emacs-events.el`）：把 `chunk` 重新包成一条
`{type:"assistant/chunk", data:{turn, step, chunk}}` 事件、走普通事件路径复用原
增量渲染器；按 `revision` 单调过滤旧代帧；快照里的 `activeAttempt.stream` 在打开
时重放一次，使断线重连能续上同一段实时正文；`end.outcome.kind == "committed"`
由后续持久 `assistant/message`（替换正文）或 `assistant/attempt`（接管为 attempt
卡，见 §7.4）收口，`"abandoned"` 则就地 flush。

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
- 打开 `$events` 前宿主会同步挂好全部 allowlist 监听器再注册流，因此 `ready` 帧
  同时是"增量投递已生效"的证明。
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
  waterfall 不再需要回答。dsh-emacs 按 `eventId` 删除排队项；若对应的提问或
  审批正在 minibuffer 显示，则立即关闭它，且不发送 stale outcome。
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
关键语义。可选项以 `?` 标注。

客户端能看到的**全集就是 `@deepseek-ai/dsh-api-remotes` 的 client 装配表**
（`packages/api/remotes/src/client/index.ts` 的 `$mount` 列表 + `workspace-controller`
组成的 `directoryPicker` 子插件）——不属于这张表的 Host 命名空间即使注册了也不可达：

`agentPresets` `commands` `credentials` `directoryPicker` `dynamicCordisRunner`
`fileReferences` `fileUploads` `goals` `llm` `messageFeedback` `pluginInventory`
`session` `sessionFeedback` `sessionReferenceResolver` `settings` `skills`
`subagents` `workspace` `workspaceFiles`（19 个；其中 `credentials` 与 `settings`
共挂 settings-controller，`directoryPicker` 由 workspace-controller 组合）。

实现锚点（master 源码）：
- session / skills / fileReferences → `packages/api/session-controller`
- workspace / directoryPicker → `packages/api/workspace-controller`
- workspaceFiles → `packages/api/workspace-files`
- settings / credentials → `packages/api/settings-controller`
- agentPresets → `packages/preset/agent-presets`
- llm → `packages/llm/llm`
- goals → `packages/goal/goal`
- commands → `packages/interaction/commands`
- messageFeedback → `packages/feedback/message-feedback`
- sessionFeedback → `packages/feedback/command-feedback`
- sessionReferenceResolver → `packages/context/session-reference`
- fileReferences（wire owner 在 session-controller，类型/查询语义在
  `packages/context/file-reference`）
- subagents → `packages/subagent/subagent`
- fileUploads → `packages/client/file-upload`
- pluginInventory → `packages/host/plugin-inventory`
- dynamicCordisRunner → `packages/extensions/cordis-host-runner`

`@Remote('name')` 的 `name` 就是 wire method（裸 `@Remote` 用方法名）；形参名与
`args` 字段一一对应，但 `agent`/`session`/`parentSessionId` 这类 lookup 形参在
wire 上是 `agentId`/`sessionId`/`parentSessionId`，由宿主 resolver 解回实例。

通用激活策略：`list/search/modelCatalog/canOpenWorkspacePath/page/fork` 与
`attachment` **冷读**（不 resume Agent）；`create/selectModel/rename/prompt` 显式
resume；`updateQueue/cancel` 要求 live Agent；`follow` 打开冷会话、快照发完后按需
提升激活；子代理地址（`address.kind:'subagent'`）永不激活。除另有说明，这些方法
都拒绝子代理会话（`session/agent-busy`，`reason` 提示改用 `subagents` 命名空间）。

错误信封与流错误帧共用同一错误体；`gateway/internal` 是未分类异常的折叠位。

### 4.1 session.*

#### session/list
```
args     { _request?: { cursor?: string } }  // 参数名 `_request`（保留空列表请求对象，
                                              // 与其它 session 方法的 `request` 不同）；
                                              // cursor 预留位，实现忽略，请求体可发 {}
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
- `PromptContentPart`（0.1.5 起三种）：
  - `{type:'text', text}`；
  - `{type:'image', mediaType, data: <base64>, name?}`（mediaType 限
    png/jpeg/webp/gif）；入队前图片字节提升为持久引用；
  - `{type:'file', receiptId}`——先经 `fileUploads/upload`（§4.17）或
    `POST /api/session/uploadFileBinary` 拿到 receipt，再把 receipt 放进 content。
    receipt 只在**同一 Session/Agent 作用域**有效，且必须与该次 prompt 的
    `requestId` 一同提交。
- `mode`：`queue` → 追加下一轮；`steer` → 插入当前轮（§8）。
- 内容全空白（空数组或纯空白 text）→ `gateway/bad-request`
  `"prompt content must include non-whitespace text or an attachment"`（已实测
  0.1.5-rc.1）。
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
不 resume 冷 Agent。edit 只收 text 内容（非文本 → `session/attachment-invalid`；
空白 text/空数组 → `gateway/bad-request` `"queue edit content must include
non-whitespace text"`，已实测）；
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
（-1 = 最新）；`beforeSeq` 省略 = 从 `throughSeq` 那页开始。`maxMessages` 是页预算
（默认 50 条）。`SessionHistoryRecord = {type:'event', event}`（0.1.5 只有这一种；
原 `{type:'chunks'}` 打包已取消，见 §7.1）。子代理地址按对应限制校验（身份/谱系不
符 → `subagent/*` 错误码，见 §5）。读取历史绝不激活 Agent。

#### session.follow（流）
```
open     { args: { request: { address: SessionAddress, maxMessages?,
                               assistantStream?: true } } }
frames   第一条 = { type:'snapshot', header: SessionWireHeader, cursor,
                    records: SessionHistoryRecord[], hasMore,
                    projections: { asOfSeq, values },
                    assistantStream?: { revision, activeAttempt? } }
         之后 = { type:'event', event: SessionWireEvent }（无间隙）
              | { type:'assistant-stream', frame }（仅 assistantStream 打开时）
```
- `SessionWireHeader = { version, id, createdAt, cwd?, parentSession?, isSeeded,
  origin?: 'subagent', delegationDepth?, agentPreset? }`（0.1.5：`seedLength` 已由
  `isSeeded: boolean` 取代）。
- snapshot 记录 = 至多 maxMessages 条消息对齐的尾部（纯 `event` 记录）；
  `cursor` = 快照覆盖到的 seq；`projections` 是该会话投影基线（§9）。
- 随后的 live 帧是裸 `event` 记录；`seq` 跳过 → `gateway/internal`（
  "skipped seq"）。普通会话在快照发完后会后台提升激活（读旧页不会）；子代理地址
  永不激活。
- `assistant/message.data.stream` 是该次尝试的完整流；live 期间若不要进程内增量
  （**dsh-emacs 的选择**），等 `assistant/message` 到达即可。

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

typert 命名空间 `goals`。读侧主要靠 `goal` 会话投影（§9）；0.1.5 新增
`goals/get` 作为显式单次读。动词都经 `agentId` lookup 到 live Agent，除 `create`
外都带 CAS `ref`（revision 不匹配拒绝）。
`GoalRef = {id, revision}`；`GoalView = {id, revision, objective, phase:
'active'|'paused'|'blocked'|'complete', blockedReason?: {code,message},
maxGoalRounds, roundsStarted, createdAt, updatedAt, activation:
'armed'|'disarmed'}`。

| 端点 | args | value |
|---|---|---|
| `goals/get` | `{ agentId }` | `GoalView \| undefined`（无当前目标 = value 缺省） |
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
| `commands/execute` | `{ agentId, line: string, submittedAttachments: CommandSubmitAttachment[] }` | `CommandExecution` 或 undefined（admission miss） |

- `CommandDescriptor = { name, description, input?: { hint, attachments?: boolean } }`
  （0.1.5 字段名：0.1.2 是 `input.images`）。
- `line` 是完整命令行（含前导 `/`）；`submittedAttachments` 是必需字段（无附件 =
  `[]`）。**0.1.5 改名**：0.1.2 叫 `images: EncodedImageAttachment[]`，现在每项是
  `{type:'image', …EncodedImageAttachment}` 或 `{type:'file', receiptId}`（§4.17）。
- `CommandExecution = { commandId, result: { kind:'success', text?, sourceEventSeq? }
  | { kind:'error', text } }`。
- 受理后记 `command/run` + `command/done` 会话事件（模型面之外）；admission miss
  不记日志。附件仅当命令声明 `input.attachments: true`，否则 `error` 结果（先
  settle `command/done`）。注册/注销时发宿主事件 `commands/change`（§6.2 emit 帧）。
- `input.images`（0.1.2 的字段）已由 `input.attachments` 取代。

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

### 4.16 workspaceFiles.*（0.1.5 新增：工作区文件读取）

Host 侧 `ctx.workspaceFiles`；为"浏览器不在宿主机器上"的场景把工作区文件读出来。
设计要点：**文件方法（`read`/`readBytes`/`readAll`/`readRelated`/`stat`/`changes`）
的读权限继承 Session 的文件系统后端**（可以越出 workspace，只要后端允许），而
`list` 与 `changes` 的观察面锁在工作区根内。

| 端点 | args | value |
|---|---|---|
| `workspaceFiles/read` | `{ workspaceFileScopeId, path, range: {offset?, limit?} }` | `WorkspaceFileText`（行窗口，`offset` 1-based，默认 1/上限 `maxLines`=5000） |
| `workspaceFiles/readBytes` | `{ workspaceFileScopeId, path, range: {offset?, length?} }` | `WorkspaceFileBytes`（字节窗口，`data` base64，默认上限 `maxBytes`=2 MiB） |
| `workspaceFiles/readAll` | `{ workspaceFileScopeId, path }` | `WorkspaceFileBytes`（整文件，上限 `maxFileBytes`=32 MiB） |
| `workspaceFiles/readRelated` | `{ workspaceFileScopeId, path, relativePath }` | `WorkspaceFileBytes`（相对 `path` 解析；`relativePath` 必须相对，否则 `gateway/bad-request`） |
| `workspaceFiles/stat` | `{ workspaceFileScopeId, path }` | `WorkspaceFileStat` |
| `workspaceFiles/list` | `{ workspaceFileScopeId, path }` | `WorkspaceDirectoryListing`（`path` 为工作区相对路径；**列根目录要显式传 `""`**，缺字段 → `gateway/bad-request` `"path is required"`；上限 `maxEntries`=2000） |
| `workspaceFiles/changes`（流） | `{ workspaceFileScopeId }` | `{kind:'ready'}` → `{kind:'change', change}`（`{absolutePath, version}` 或 `{absolutePath, absent:true}`） |

- **lookup 形参注意**：方法第一个形参 `workspaceFileScope` 在 wire 上叫
  `workspaceFileScopeId`，值就是 **sessionId 字符串**（Host 自己按 live header /
  持久 header 解析出 `{sessionId, workspaceRoot}`，冷会话也能解析）。客户端从不
  亲自给 root。
- 路径两套词汇：`read`/`readBytes`/`stat`/`changes` 用**执行世界的绝对路径**；
  `list` 用**工作区相对路径**。
- `WorkspaceFileStat = {absolutePath, version, bytes?}`——`version` 是不透明新鲜度
  令牌（不要解析），配合 `changes` 判断"这个文件我手上这版是不是旧的"。
- `WorkspaceFileText = Stat + {offset, text, lines, eof}`；
  `WorkspaceFileBytes = Stat + {offset, data, eof}`；
  `WorkspaceDirectoryEntry = {name, type:'file'|'directory'|'other', size?}`；
  `WorkspaceDirectoryListing = {path, entries, truncated}`。
- 错误码：`workspace-file/not-found`、`workspace-file/outside-workspace`、
  `workspace-file/too-large`、`workspace-file/not-text`、`workspace-file/not-regular-file`、
  `workspace-file/not-directory`（每个 details 带 `path`）。
- **对 dsh-emacs 的价值**：预览会话产出的文件（含大文件分页、二进制、图片）不再需要
  本地同机路径，也不受 `/api/file` 的"绝对路径 + 本机可读"限制。
- 实测（0.1.5-rc.1 活服务）：`workspaceFiles/stat` 对工作区相对路径
  （如 `"README.md"`）直接可用，返回 `absolutePath` + `version` + `bytes`；
  `list` 必须带 `path`（`""` = 根）。

### 4.17 fileUploads.upload（0.1.5 新增：附件上载）

`packages/client/file-upload`，命名空间 `fileUploads`。把文件字节变成一次性
**receipt**，再随 prompt / 命令提交（§4.1 的 `{type:'file', receiptId}`、§4.11 的
`CommandSubmitAttachment`）。

```
args     { agentId, request: { data: <base64>, name? } }
value    { receiptId, file: FileAttachmentRef }
```

- `agentId` 是 lookup 形参：**必须是有该 Session 的 Agent 作用域**；冷会话由服务
  自己的 resolver resume。
- receipt 只在接收 Agent 的作用域内有效，且与提交它的那次 prompt/命令绑定（提交
  失败会回滚绑定）。
- 大文件走 HTTP 流式路由更省内存：`POST /api/session/uploadFileBinary?sessionId=<id>[&name=<leaf>]`，
  `content-type: application/octet-stream`，body 就是原始字节；返回体是
  `{ok:true, value:{receiptId, file}}` 或 `{ok:false, error:{code,message,details}}`
  （HTTP 状态仍是 200）。缺 `sessionId` → 400，content-type 不符 → 415。

### 4.18 sessionFeedback.record（0.1.5 新增：会话级反馈）

`packages/feedback/command-feedback`。Web 的 `/feedback` 斜杠命令与消息
Dislike 弹窗共用这一个写入口；落一条 log-only 的 `feedback/record` 事件。

```
args     { request: { sessionId, text?, category? } }
value    { ok: true, value: { recorded: true } }
       | { ok: false, error: { code: 'session-not-found', sessionId } }
```

`category` ∈ `task-result` | `instruction-following` | `product-interaction` |
`service-stability` | `resource-cost` | `security-privacy-permission` | `other`；
`text` 空白按缺省处理（两者都缺也允许——"请求人工看一下这个会话"本身就是信号）。
与会话内 `feedback/record` 事件同源；注意返回值自带 `{ok:…}` 判别，不是信封错误
（同 `messageFeedback/*` 的风格）。

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
| `workspace-file/not-found` | `{ path }` |
| `workspace-file/outside-workspace` | `{ path }`（`list` 越出会话工作区根） |
| `workspace-file/too-large` | `{ path, limit }`（请求页超过配置字节上限） |
| `workspace-file/not-text` | `{ path }`（非 UTF-8 或含 NUL） |
| `workspace-file/not-regular-file` | `{ path, kind: 'directory'\|'symlink'\|'other' }` |
| `workspace-file/not-directory` | `{ path, kind: 'file'\|'symlink'\|'other' }` |

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
| `goal/activation-changed` | `(payload: GoalActivationChanged)` = `{sessionId, goal?: {id, revision, activation: 'armed'\|'disarmed'}}`（clear 后 `goal` 缺省） | 进程内目标续跑资格变化；0.1.5 新增 |
| `settings/document-updated` | `(ns, revision)` | 设置文档变更 |
| `user-questions/request` | waterfall | 提问请求（§3.3） |

数量核对：`packages/api/remotes/src/remote-events.ts` 的
`API_REMOTE_FORWARDED_EVENTS` 共 **19 项** = 17 个 emit + 2 个 waterfall
（`approval/request`、`user-questions/request`）；上表即其全集，多一条都不转发。

> dsh-emacs 订阅策略建议：`session/control`（baseline + 增量）提供队列/任务/投影
> 三件事；`$events` emit 帧提供 session 级增删改与命令/凭据/设置变化通知。
> 会话**内容**事件只来自 `session/follow`（§7），不经 emit。

---

## 7. 会话事件词汇

### 7.1 事件信封与日志记录

持久/传输用的事件信封（wire 形 `SessionWireEvent`）：
`{ type, seq, time, data, ignorable?, sourceEventSeqs?, surfaceOp? }`。

- `seq` 单调连续（session 内）；`time` epoch 毫秒；`data` 是 JSON 值。
- `surfaceOp`（V3）只出现在**四类** surface 事件（`system/message`、
  `user/message`、`assistant/message`、`tool/result`）：`'append'` 或
  `{op:'replace', startSeq, endSeq}`（compaction 遮蔽用，且事件带
  `sourceEventSeqs` 覆盖被遮蔽节点）。0.1.2 文档写的 `start`/`end` 字段名已废弃。
- `ignorable: true` = 读者可不认识该 type 而跳过；缺省 = 必识——遇到未知 type 必须
  拒绝重建。**0.1.5 起这条是硬约束**：持久读路径按
  `packages/core/session/src/known-event-types.ts` 的 `KNOWN_SESSION_EVENT_TYPES`
  （本版 56 个）判定，集合外且无 `ignorable` 的事件直接拒绝解释整个日志。
- **记录打包已取消（0.1.5）**：`SessionHistoryRecord` 只有
  `{type:'event', event}` 一种（`SessionEventEntry`）。0.1.2 的
  `{type:'chunks', event}`（`chunkrow/text-chunks` 等行程）以及 `assistant/chunk`
  持久事件都已删除；compact 流内嵌在 `assistant/message.data.stream`，
  live 增量走 §3.2.1 的 `assistant-stream` 帧。
- JSONL 存储（导出下载）首行仍是 `{type:'session', …}` 头；历史行是裸会话事件，
  与 wire 信封字段一致。
- **replace 记录会到达客户端**（两条路都不过滤）：live `event` 帧直接转发每条持久
  事件；打开快照的 `records` 也逐条转发——`isAppendSurfaceEvent` 服务端只用于
  **计数与切页**，不用于过滤切片内容。实测 399 个真实会话日志、125.99 万条事件：
  replace 共 74 条（`user/message` 61 = compaction 摘要、`system/message` 5 =
  系统提示改写、`tool/result` 8 = 工具结果剪枝），且存在落在默认 50 条消息窗口
  内部（`tail_distance=4`）的实例。
  **渲染侧纪律**：`system/message` 不渲染；`user/message` 的 source 过滤
  （`kind` 非 `nil`/`user` 即跳过）已覆盖 compaction 摘要（其 `source.kind` 是
  `plugin`）；`tool/result` 必须自己判 `surfaceOp.op == "replace"` 并跳过——它与被
  替换记录**共享 `callId`**，且 `data` 里**没有**任何来源字段可依。dsh-emacs 由
  `dsh-emacs-render--replacement-p` + dispatcher 完成。
- **实测证据（0.1.5-rc.1 活服务的 `session/follow` 快照）**：header =
  `{"version":3,"id":"…","createdAt":…,"cwd":"…","isSeeded":false,
  "delegationDepth":0,"agentPreset":"standard"}`；`records` 全部是
  `{type:'event'}`（实测见 `assistant/message`、`tool/call`、`tool/result`、
  `step/start|end`、`turn/end`、`session/end-seed`），没有 `chunks` 记录、
  没有 `assistant/chunk`。

### 7.2 核心事件（`packages/core/session` + agent-loop 等）

| type | data | 说明 |
|---|---|---|
| `turn/start` | `{ turn }` | 开轮 |
| `turn/end` | `{ turn, reason }` | 关轮；reason 见下 |
| `step/start` | `{ turn, step }` | 开步（一次模型调用 + 工具执行） |
| `step/end` | `{ turn, step }` | 关步 |
| `user/message` | `UserMessage` | 用户面消息；`source.kind` 区分 human/rpc/plugin/goal… |
| `system/message` | `{ turn, step, message: SystemMessage }` | **V3 新增**：渲染后的系统提示 = surface node 0；prompt 变化时替换最近 system 节点或（in-history 路由）追加新节点 |
| `assistant/message` | `{ turn, step, message, stream: AssistantStreamRecord[], usage?, interrupted?: true }` | 组装好的助手消息；`stream` 是该次尝试的精确流记录；usage 同挂此事件 |
| `assistant/attempt` | `{ turn, step, stream: AssistantStreamRecord[] }` | **V3 新增**：未提交 surface 消息的失败/重试/取消尝试 |
| `tool/call` | `{ turn, step, callId, name, arguments: string }` | 模型原始 JSON 字符串 |
| `tool/result` | `{ turn, step, message, error?: { name, code }, meta? }` | 模型面结果；`meta` 工具自持（须 JSON 安全） |
| `request/header` | `{ header: EpochHeader, reason, startsSeries? }` | 下一请求完整头；log-only。V3 要求 header **不得**带 `system` 字段（系统提示已移到 `system/message`） |
| `request/context` | `{ provider, model, contextWindow?, systemPromptUpdate? }` | 路由元数据（变化才记）；log-only。`systemPromptUpdate: 'in-history'` 表示该路由把最新 system 消息当有效系统提示 |
| `session/end-seed` | `{ inherited?: true }` | 种子结束标记（resume/fork/replay 边界）；log-only |

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
| `feedback/record` | `{text?, category?}`（`category` ∈ `task-result`\|`instruction-following`\|`product-interaction`\|`service-stability`\|`resource-cost`\|`security-privacy-permission`\|`other`） | dsh-command-feedback |
| `feedback/message-put` | `{sessionId, item: MessageFeedbackItem}` | dsh-message-feedback |
| `feedback/message-delete` | `{sessionId, messageId}` | dsh-message-feedback |
| `subagent/descriptor` | `{version:3, mode:'one-shot'\|'continuable', provider, label?, agentProvider?, agentModel?, agentReasoningEffort?, persona?, toolFilter?}` | dsh-subagent |
| `subagent/model-selection-policy` | `{allowedModels}` | dsh-tool-subagent |
| `subagent/catalog` | `{version, childId, childCreatedAt, mode:'one-shot'\|'continuable', label?}`（父会话侧的子代理登记，一行一条；`continuable` 的 label 必填） | dsh-subagent |
| `deliverables/presented` | `{turn, callId, files: [{path, description?}]}`（`present` 工具成功收口后登记的交付文件） | dsh-tool-present |
| `hook/invoked` / `hook/result` | 钩子执行记录 | dsh-hook-protocol |
| `llm/retry` / `llm/retry-started` | 重试记录 | dsh-llm-retry |
| `agent/inbox/spliced` | `{target:'next-turn'\|'next-step', start, removedCount?, inserted, outcome?}` | dsh-agent |
| `tool/ptc-dispatch-start` / `tool/ptc-dispatch` | PTC（`run_code` 桥）子调用派发对：`start` 开一条子调用，`dispatch` 以同一 `subCallId` 收口 | dsh-tools |
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
`user/message`、`assistant/message`（`data.stream` 内含该次尝试的完整流）、
`tool/call`、`tool/result`、`turn/start`、`turn/end`、`request/header`、
`request/context`，以及扩展的 `command/run`、`command/done`、`session/title`。
**V3 变化**：`assistant/chunk` 不再是持久事件，流式文本要么从
`assistant/message.data.stream` 整体取，要么消费 §3.2.1 的 `assistant-stream`
帧；`system/message` 是 surface 事件，若渲染系统提示需单独处理（多数客户端直接
跳过）。`assistant/message`/`tool/result`/`system/message` 的 `replace` surfaceOp
表示 compaction 遮蔽——渲染层须按 `sourceEventSeqs` 替换旧节点而不是追加。
标题与目标/todo 等状态经投影键（`title`/`goal`/`todos`/`plan`/…，§9）而非事件
直接取。队列/任务态来自 `session/control`（§6.1），审批/提问来自 `$events`
waterfall（§3.3），交付文件来自 `deliverables/presented`（§10.3）。

**dsh-emacs 的补齐范围（`dsh-emacs-render-event` 分派）**：以前静默丢弃的事件
现在都有归属——`step/start` / `step/end` 是 turn 内部边界（一步 = 一次模型调用 +
其工具执行），不进 transcript，改为喂 modeline 的 `step N` 徽标
（`dsh-emacs-modeline-note-step`；默认关闭，开 `dsh-emacs-modeline-show-step`，
见 docs/modeline.md）；`assistant/attempt`
渲染成 `↻ Attempt (no committed reply)` 卡，body 由 `data.stream` 的打包记录
（`reasoning-chunks`/`tool-call-chunks`/`text-chunks`）按序重建（reasoning 受
`dsh-emacs-show-reasoning` 约束），若该尝试结算时还有 live 流式 body，live body
被该卡接管而不是重复绘制；`session/end-seed` 渲染成一行 `── seed boundary`
（fork/resume 的种子带 `inherited: true`，标 `inherited history`；全新会话不追加
该事件）。`system/message` 仍不渲染。

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
- 0.1.5 行为收紧：`session/prompt` 的空 prompt 被拒（`session-controller` 层），
  空内容的 `session.updateQueue` edit 也被拒——客户端不必再自己兜底过滤空串。

---

## 9. 会话投影（session.control `projection` 帧 + follow 快照 `projections`）

投影单元由各插件向宿主 `sessionProjections` 注册；每条单元折叠会话事件成一个
JSON 值。客户端维护**按 key 的每会话值存储**，规则：control 的 `projection` 帧
higher-seq-wins；follow 打开快照的 `projections` 块（`asOfSeq` 对齐）与 control
baseline 的 `projections` 都可作重连/打开基线（先按 asOfSeq 截断再种入）；
`session.list` 行的 `projections.values` 是同一键空间的部分缓存提示。

客户端可见键（18 个，挂载即有）与值形状（0.1.5 新增 `subagentCatalog`；下表的
`subagent` / `subagentTiming` / `subagentCatalog` 都来自 subagent 包）：

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
| `subagentCatalog` | `SubagentCatalogEntry[]`（父会话侧的子代理目录，按 `subagent/catalog` 事件顺序，不含 fork 继承事实） |
| `schedule` | `ScheduleRecord[]`（该会话有效提醒；有 schedule 服务才挂） |
| `sessionListMetadata` | `{ blank, lastPromptAt }`（list 行 hint） |
| `imageLimits` | `{ maxImageBytes, maxImagesPerMessage, maxMessageImageBytes, maxImagePixels, maxImageDimension, mediaTypes }`（键缺 = 无附件服务） |
| `modelSelection` | `{ lastUsed: {provider, model, reasoningEffort?} \| null, next: … \| null }` |

投影里**没有**"该会话正在等用户"的状态（历史与 0.1.5 都没有
`sessionStats.pendingInteraction`）。web 把它放在客户端自有的登记表里，由活着的
`approval/request` / `user-questions/request` waterfall **接单者**在请求存续期间
写入（`ui-session` 的 `pendingInteractions`，`ui-approval` / `ui-user-questions`
各注册一个 domain），不在 `session/list` 里。

dsh-emacs 现状（刻意保持）：只按行的 `running` 标志显示运行态，**不做**待交互
推导。原因不是没写聚合函数，而是本客户端对**没有打开聊天缓冲**的会话，会把
waterfall 直接以 `next` 交还宿主（`dsh-emacs-events--host-dispatch`），因此客户端
手里根本没有那类会话的状态。若将来要在 Emacs 侧显示"等审批"，对冷会话也成立的
来源是持久事件对 `approval/asked` → `approval/decided`（§7.3），而不是 waterfall。

宿主另有若干**只进状态表不跨线**的单元（`turnBoundary`、`titleInput`、
`subagentModelSelectionPolicy`、`sandboxMode`、`agentTeam`、`timeContext`、
`tmuxContext`、`llmRetry`）——它们用于宿主侧折叠，不出现在 wire 帧里。

> 0.1.1-rc.2 的 mux 投影帧（`session/projection`）在 0.1.2 由
> `session.control` 的 `projection` 增量帧取代；投影来源 = follow 快照 +
> control 投影帧。
>
> 投影是**能力面**：键在 wire 上缺省表示该部署没挂对应插件（例如没有 schedule
> 服务就没有 `schedule`、没有权限服务就没有 `permissions`），不要把它当"值未知"。
> dsh-emacs 侧对应 `dsh-emacs-events.el` 的投影分派。

---

## 10. 其它精确 HTTP 路由（无信封）

这些路由都走与 `/api` RPC 相同的信任栅栏 + cookie 认证，但**不用信封**：请求/响应
是它们自己的形状与状态码。

### 10.1 会话日志下载

```
GET /api/session.export?sessionId=<id>[&includeDescendants=true|false]
```
- 精确 GET/HEAD Fetch 路由；返回 ZIP 附件（`content-type: application/zip`、
  `content-disposition: attachment; filename="dsh-session-<id>.zip"`）。
- 根工件 `session.jsonl`（header 行 + 事件行）+ 子代理后代
  `subagents/<id>/session.jsonl` + 被引用图片 `media/<attachmentId>.<ext>`。
- `includeDescendants` 只接受 `true`/`false`/缺省，其它值或缺失 sessionId → 400；
  缺服务（session-query/persistence/attachments）→ 500；读根失败 → 500；根会话
  不存在 → 404。
- web composer 另有 `/export` 斜杠命令触发同一下载（不接受路径参数）。
- dsh-emacs 可 `url-retrieve`/`curl` 下载后本地解包（带 cookie）。

### 10.2 按绝对路径读文件（0.1.5）

```
GET  /api/file?path=<absolute path>      (HEAD 同路径，只回头)
```
- 路径必须是**绝对路径**且不含 NUL，否则 400；经 `ctx.fs` 的执行世界解析（仍受
  沙箱策略管辖）。
- 成功：200 + 文件字节（**整文件**），`content-type` 按扩展名推断，附
  `cache-control: private, no-store`、`x-content-type-options: nosniff`、
  `content-security-policy: sandbox; default-src 'none'`。
- 失败：404 not found / 403 非普通文件或权限或沙箱拒绝 / 413 超过字节上限 / 499
  调用方中止 / 500 其它 `FsError`。
- 字节上限 = `ctx.attachments.imageLimits.maxImageBytes`（附件图片上限，默认
  200 MiB 量级）**整文件**读取，不落盘、不分页。
- **版本注意（已核对 npm 0.1.5-rc.1 构建）**：0.1.5 的 DEV 期曾支持
  `Range: bytes=`（单段）与 416/`content-range`，但该能力在 rc 发布前被
  `refactor(api): reuse attachment limits for file responses` 移除；**0.1.5-rc.1 的
  实际构建没有 Range 支持**（源码与已装 `lib/index.js` 均无 `range` 处理）。要大文件
  分页请用 §4.16 的 `workspaceFiles/readBytes`。
- **与 `workspaceFiles` 的分工**：`/api/file` 是"本机绝对路径直读"，适合同机场景；
  `workspaceFiles` 是"按会话作用域读、支持分页/变更订阅/跨机"，是客户端读过工作区
  文件的首选（§4.16）。

### 10.3 交付物（`present`）相关（0.1.5）

`present` 工具成功收口时会写 `deliverables/presented` 会话事件
（`{turn, callId, files: [{path, description?}]}`，§7.3），Web 端把它渲染成可点击
的文件卡片。卡片背后的两个路由：

```
GET  /api/present.host                     → {name, available, fileManager}
POST /api/present.open?sessionId&seq&index  body: {"action":"open"|"reveal"}
```
- `present.host` 探测宿主桌面能力（`fileManager` ∈ `finder`/`explorer`/
  `directory`/`null`；不按浏览器 OS 猜）。
- `present.open` 用**会话事件坐标**（`sessionId` + 该 `deliverables/presented`
  事件的 `seq` + `files` 数组下标）定位文件，再交给宿主打开/定位；`seq`/`index`
  与实际事件不符时拒绝。
- dsh-emacs 想显示交付物时，只需消费 `deliverables/presented` 事件拿路径；是否
  提供"在 Finder 里打开"是纯客户端选择，不需要这两个路由（可用 `session/openWorkspacePath`，§4.1）。

### 10.4 原始字节上传（0.1.5）

```
POST /api/session/uploadFileBinary?sessionId=<id>[&name=<leaf name>]
content-type: application/octet-stream
body: 原始字节
```
- 成功 200 + `{ok:true, value:{receiptId, file}}`；失败也是 200 +
  `{ok:false, error:{code,message,details}}`（信封外的自定义结果形状）。
- 请求校验失败才用状态码：缺 `sessionId` → 400；`content-type` 不是
  `application/octet-stream` → 415；非 POST → 405。
- 拿到的 `receiptId` 用于 §4.1 的 `{type:'file', receiptId}` 或 §4.11 的
  `CommandSubmitAttachment`；小文件也可以用一元 `fileUploads/upload`（base64）。
