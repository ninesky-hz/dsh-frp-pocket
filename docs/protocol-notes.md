# DSH 远程接口实测记录（2026-11-12）

公网入口：`https://pwq8t9.dsh.chenz.vip`（frp + Caddy 泛域名）→ 家里 DSH `127.0.0.1:3081`(gateway) → DSH web。

## 1. 鉴权链

```
GET  /?pin=<pin>                      → 303 + set-cookie: frp_auth=…
GET  /            (带 frp_auth)        → 200 + x-frp-pocket-handshake: transition
                                        + set-cookie: dsh-auth-<随机名>=v1.…
GET  /            (带两个 cookie)      → 200 真页面（>50KB）
```
判据（客户端用）：
- `followRedirects: false`，否则 303 上的 `set-cookie` 会丢。
- 握手完成的标志：响应头没有 `x-frp-pocket-handshake` 且 body > 5000 字节。
- 之后所有 `/api/*` 请求带 `Cookie: frp_auth=…; dsh-auth-<名>=…`。

## 2. HTTP unary 调用

```
POST https://<host>/api/<method>
Content-Type: application/json

{"type":"client-request","rpcId":"<任意唯一串>","method":"<method>","payload":{"args":{ <descriptor 参数> }}}
```

响应：
```json
{"type":"server-response","rpcId":"…","result":{"ok":true,"value":{…}}}
{"type":"server-response","rpcId":"…","result":{"ok":false,"error":{"code":"gateway/…","message":"…"}}}
```

- `payload` 里必须**恰好一个** `args` 对象字段。
- 业务失败是 HTTP 200 + `ok:false`；`code` 常见值：`gateway/arguments-invalid`（args 键名不对）、`gateway/bad-request`（参数值不合法）、`gateway/signature-invalid`（把 unary 方法当流开）、`gateway/internal`。
- args 的键名由各方法 descriptor 决定，**不一致**：`session/list` 用 `_request`，其它多为 `request`。

### 已验证的方法

| method | args | 返回 |
|---|---|---|
| `session/list` | `{"_request":{}}` | `{items:[{sessionId,updatedAt,running,agentAvailable,cwd,projections:{asOfSeq,values:{title,tokenUsage,goal,modelSelection,…}}}]}` |
| `session/page` | `{"request":{"address":{"kind":"session","sessionId":"…"},"throughSeq":N,"beforeSeq":M,"maxMessages":20}}` | `{cursor,hasMore,records:[{type:"event",event:{seq,time,type,data}}]}` |
| `session/prompt` | `{"request":{"requestId":"<uuid>","sessionId":"…","mode":"queue","content":[{"type":"text","text":"…"}]}}` | `{accepted:true}` |
| `session/cancel` | `{"request":{"sessionId":"…"}}` | `{accepted:true}` |
| `session/create` | `{"request":{"cwd":"C:\\path","agentPreset":"unrestricted"}}` | `{sessionId,agentPreset}` |
| `workspace/archiveSession` | `{"request":{"sessionId":"…","stopActivity":true}}` | `{archivedSessionIds:[…]}`（**全量**已归档列表） |

`session/page` 的 `throughSeq` 有上界：超过该会话当前 seq → `session history cut 100 exceeds 21`。所以先用 `session/follow` 的 `projections.asOfSeq` 取得游标。

## 3. WebSocket 流

```
wss://<host>/api/remote.mux
Cookie: frp_auth=…; dsh-auth-<名>=…
```

开流：
```json
{"type":"open","streamId":"f1","endpoint":"session/follow",
 "payload":{"args":{"request":{"address":{"kind":"session","sessionId":"…"},"assistantStream":true}}}}
{"type":"open","streamId":"w1","endpoint":"workspace/follow","payload":{"args":{}}}
{"type":"open","streamId":"e1","endpoint":"$events","payload":{"args":{}}}
```
关流：`{"type":"close","streamId":"f1"}`

### `session/follow` 的 value 只有三种

```jsonc
// 1) 首帧快照（无逐条消息）
{"type":"item","streamId":"f1","value":{"type":"snapshot",
  "header":{"version":4,"id":"session-…","createdAt":1794483451771,"cwd":"…","isSeeded":false,"agentPreset":"unrestricted"},
  "projections":{"asOfSeq":2,"values":{"title":null,"turnOutline":[],"sessionStats":{…},"tokenUsage":{…}}}}}

// 2) durable 事件（seq 连续递增；与 session/page 的 records[].event 同形）
{"type":"item","streamId":"f1","value":{"type":"event",
  "event":{"type":"turn/start","seq":4,"time":1794483452522,"data":{"turn":1}}}}

// 3) 助手流式增量（只用于「正在思考」指示）
{"type":"item","streamId":"f1","value":{"type":"assistant-stream",
  "frame":{"type":"start","attemptId":"session-…:1","revision":1,"turn":1,"step":1,"startedAfterSeq":15}}}
{"type":"item","streamId":"f1","value":{"type":"assistant-stream",
  "frame":{"type":"chunk","attemptId":"session-…:1","revision":2,"index":0,"time":…,
           "chunk":{"type":"block-start","index":0,"blockType":"reasoning"}}}}
```
另有 `{"type":"error","streamId":…,"error":{…}}` 与 `{"type":"closed","streamId":…,"reason":…}`。

### `assistant-stream` 的 `chunk.index` 是「块下标」，不是帧序号

真机抓包（2026-11-12 20:32，`session/follow` + `assistantStream:true`，一次带思考的回答）：

```
frame.index=50..62  chunk=reasoning-delta   chunk.index=0     ← 思考块（第 0 块）
frame.index=63      chunk=block-start       chunk.index=0     ← 思考块收尾
frame.index=64      chunk=block-end         chunk.index=0
frame.index=65      chunk=block-start       chunk.index=1     ← 正文块（第 1 块）
frame.index=66,67   chunk=text-delta        chunk.index=1
frame.index=68      chunk=block-end         chunk.index=1
frame.index=69      chunk=usage
frame.index=70      chunk=finish
frame.index=71      frame.type=end
```

两条 index 各管一件事，混淆就会把正文写进思考块：

| 字段 | 含义 | 用途 |
| --- | --- | --- |
| `frame.index` | 这条 chunk 帧的**全局序号**（严格 +1） | 帧级去重：`frame.index < nextIndex` 整帧丢弃 |
| `chunk.index` | 块在本次 attempt 里的**下标**（0=思考，1=正文，工具调用往后排） | 累积目标：把 delta 写进对应的 `DraftBlock` |

`block-start` 带 `blockType`（如 `reasoning`）；`block-end` 带 `block`（成型的 part，可优先于 delta 拼接结果用于定稿）。


### `workspace/follow` 首帧
```json
{"type":"item","streamId":"w1","value":{"type":"baseline","value":{"items":[
  {"workspaceId":"…","path":"D:\\Ai-Project\\dsh-frp-pocket","title":"dsh-frp-pocket",
   "sessionIds":["session-…"],"createdAt":"2026-11-12T05:45:05.601Z","updatedAt":"…"}]}}}
```

## 4. 一次真实往返的事件序列（关键：注入消息必须过滤）

```
seq 0  permission/preset
seq 1  sandbox/mode
seq 2  approval/policy
seq 3  agent/inbox/spliced      data.inserted[0].content[0].text = 用户原文
seq 4  turn/start
seq 5  agent/inbox/spliced      inserted: []
seq 6  step/start
seq 7  system/message
seq 8  user/message             data.source = {"kind":"user","rpcId":"…"}   ← 真用户消息
seq 9  user/message             "Current runtime context. …"                ← 注入，要过滤
seq 10 user/message             "<system-reminder>…"                        ← 注入
seq 11 user/message             "Time sampled while preparing turn 1…"      ← 注入
seq 12 user/message             "[MNEMON] …"                                ← 注入
seq 13 user/message             "MNEMON RUNTIME MEMORY SNAPSHOT…"           ← 注入
seq 14 request/header
seq 15 request/context
seq 16 session/title
seq 17 session/title-llm-request
seq 18 session/title
seq 19 assistant/message        data.message.content = [{reasoning},{text:"收到"}]
seq 20 step/end
seq 21 turn/end
```

渲染规则：
- 用户气泡：仅 `type == 'user/message'` **且** `data.source?.kind == 'user'`（带 `rpcId`）。
- 助手气泡：`type == 'assistant/message'`，取 `data.message.content` 里 `type == 'text'` 的 `text`。
- `reasoning` / `tool-call` part 折叠成一行灰字；`agent/inbox/spliced`、`system/message`、`*/*-request`、注入的 `user/message` 全部不渲染。

## 5. 排版注意
- 响应可能是 chunked，且中文按 UTF-8 编码，读取要按字节累积再解码，不要按行切。
- 一切时间字段是 epoch 毫秒（`createdAt`/`time`/`updatedAt`），唯独 `workspace/follow` 的 `createdAt/updatedAt` 是 ISO 字符串。
