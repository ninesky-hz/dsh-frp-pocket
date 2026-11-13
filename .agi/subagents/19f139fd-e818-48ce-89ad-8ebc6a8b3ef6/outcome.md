<!-- worker: 19f139fd-e818-48ce-89ad-8ebc6a8b3ef6 -->
<!-- report: ready -->

# 会话内发送与显示图片 —— 完成

## 结论

`flutter analyze` → **No issues found!**；`flutter test --concurrency=1` → **274 条全绿**（其中新增图片相关 21 条）。`image_picker` 在 `pubspec.yaml` 里声明为 `^1.1.2`，`pubspec.lock` 实际解析 **1.2.4**。

## 改动文件（带行号）

### 新增 `packages/app/lib/models/prompt_image.dart`
- `9` `class PromptImage { … }`：`mediaType` / `base64Data` / `name`，const 构造。
- `17` `factory PromptImage.fromBytes(Uint8List bytes, {required String mediaType, String? name})`：内部 `base64Encode`。
- `33` `static PromptImage? fromJson(Object? value)`：离线队列读回时容错，坏数据返回 `null` 而不是抛（SharedPreferences 里的旧数据不该让聊天页白屏）。
- `54` `static const Set<String> supportedMediaTypes = {'image/png','image/jpeg','image/webp','image/gif'}`。
- `65` `static String? mediaTypeForPath(String path)`：小写化 + 截掉 `?query`，认 `.png/.jpg/.jpeg/.webp/.gif`，其余 `null`。
- `81` `Map<String, Object?> toJson()` → `{'type':'image','mediaType':…,'data':…, if (name != null) 'name': …}`（用 null-aware element，name 为 null 时整键不出现，避免给服务端发 `name: null`）。

### `packages/app/lib/services/dsh_remote.dart`
- `4-5` 新增 `import 'dart:typed_data';`、`import '../models/prompt_image.dart';`。
- `302-311` 图片缓存：`_imageCache`（`Map<String, Uint8List>`）、`_imagePending`（同一 id 并发只发一次 RPC）、`static const int kImageCacheLimit = 40`。
- `398` `Future<String> prompt(String sessionId, String text, {String? requestId, List<PromptImage> images = const <PromptImage>[]})`：只有「文本空且图片空」才抛 `DshApiException('bad_request','消息内容不能为空')`；content = `[if (body.isNotEmpty) {'type':'text','text':body}, ...images.map((e) => e.toJson())]`。
- `428` `Future<Uint8List> attachment(String sessionId, {required String attachmentId, String? mediaType, int? bytes, int? width, int? height, String? name})`：先发完整 descriptor `{'sessionId','attachment':{…}}`；`458` 捕获 `DshApiException` 且 `_looksLikeAttachmentShapeMismatch` 时打一行 `debugPrint` 后退化成 `{'sessionId','attachmentId':…}` 重试一次；`475` `base64Decode(_stripBase64Prefix(data))`，`data` 缺失抛 `bad_response`。
- `479` `cachedAttachment(…)`：命中缓存直接返回 → 命中 inflight 复用 future → 否则建 future，侧枝 `then` 里落缓存，`onError` 只清 inflight（错误仍由 await 它的调用方拿到，避免 unhandled）。
- `516` `_rememberImage`：超 40 条就 `remove(_imageCache.keys.first)`，靠 Map 插入顺序淘汰最旧。
- `527` `_looksLikeAttachmentShapeMismatch`（code 含 `arguments`/`input-invalid`/`bad_request`）、`536` `_stripBase64Prefix`（剥 `data:image/…;base64,`）。
- `826-827` `dispose()` 里清空 `_imageCache` / `_imagePending`。

### `packages/app/lib/models/session_event.dart`
- `109` `class ChatImageRef`：`attachmentId/mediaType/name/bytes/width/height`；`fromJson` 既吃 `{type:'image', attachment:{…}}` 也吃裸 attachment 描述，缺 `attachmentId` 返回 `null`。
- `144` `static const String localPrefix = 'local:'`，`154` `bool get isLocal`——本地乐观气泡靠这个前缀换成 `Image.memory`。
- `191` `ChatMessage.images`（默认 `const []`），`212` `copyWith` 新增 `List<ChatImageRef>? images`。
- `237` `chatMessageOf` 的 `user/message`：先收 `contentImages(message['content'])`，`(text == null || text.trim().isEmpty) && images.isEmpty` 才返回 `null`；文本为空但有图时 `text: ''` 照样出气泡。
- `275` `assistant/message` 同样收图，收尾条件加 `&& images.isEmpty`。
- `363` 顶层 `List<ChatImageRef> contentImages(Object? content)`：非 List 返回 `const []`，只挑 `type == 'image'`，`List.unmodifiable`。
- `isRealUserMessage` 兜底改为：文本为空时看有没有图（否则纯图的历史消息会被注入过滤误杀）。

### `packages/app/lib/models/outbox.dart`（整文件重写）
- `30`/`65` `OutboxEntry.images`（`List<PromptImage>`，默认 `const []`）；`37`/`44` `create(…, List<PromptImage> images = const [])` 做 unmodifiable。
- `92` `toJson()` 增加 `'images'`（元素就是 `PromptImage.toJson()` 的形状）；`104-112` `tryParse` 读回时逐项 `PromptImage.fromJson`，并且**不再要求 text 非空**——只要「文本空且图空」才丢，纯图队列条目才存得下来。

### `packages/app/lib/screens/session_chat_screen.dart`
- `7` 新增 `import 'package:image_picker/image_picker.dart';`（另加 `dart:convert`、`../models/prompt_image.dart`）。
- `38`/`57` 新增可注入 seam `final Future<PromptImage?> Function()? pickImage`。**为什么**：`ImagePicker.platform` 是只读 getter，`image_picker` 又不导出 `ImagePickerPlatform`，widget 测试里换平台实现只能直依赖 `image_picker_platform_interface`（会被 `depend_on_referenced_packages` 判 error）。加一个构造参数既保持生产路径不变，也让测试不用碰真实相册。
- `119` `_maxAttachments = 5`、`_maxOutboxImageChars = 3 * 1024 * 1024`；`132` `_attachedBytes`、`137` `_localImages`（`local:<localId>:<i>` → 字节）、`143` `_imageFutures`（按 attachmentId 记住 future，避免每帧重发 RPC）、`147` `_outboxThumbs`。
- `702` `_send()`：`images` 先快照，`text.isEmpty && images.isEmpty` 才 return；清输入框和 `_attached`；断线走 `_enqueueOutbox(text, images)`，在线走 `_sendText(text, images: images)`。
- `723` `_pickImage()`：满 5 张 `_toast('一次最多 5 张')` 并忽略；`728` 走 `widget.pickImage ?? _pickFromGallery`；不支持的类型 `_toast('只支持 png / jpeg / webp / gif')`；成功后 `_attached` + `_attachedBytes` 一起入列。
- `753` `_pickFromGallery()`：`ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 2048, maxHeight: 2048, imageQuality: 88)` → `readAsBytes()` → `PromptImage.fromBytes(… mediaType: PromptImage.mediaTypeForPath(picked.path) ?? 'image/png', name: picked.name)`。
- `769` `_removeAttachment(int index)`；`778` `_promptImagesOf(ChatMessage)`（重试时从 `_localImages` 还原字节，缺字节就跳过）。
- `796` `_sendText(String text, {List<PromptImage> images = const []})`：为每张图造 `ChatImageRef(attachmentId: 'local:$localId:$i')` 写进 `_localImages`，本地气泡立刻能显示；`830` `prompt(…, images: images)`。
- `856` `_retry` 带上原图重发；`904` `_enqueueOutbox(String text, List<PromptImage> images)`：图片 base64 超 3MB 就丢弃图片并 `_toast('图片太大，联网后再发')`，文本照存；`933` `_flushOutbox()` 调 `prompt(…, requestId: entry.requestId, images: entry.images)`（`947`）。
- `1328` `_imageBytes`（local 走 `_localImages`，远程走 `_remote.cachedAttachment(…)` 并 `putIfAbsent` 记住 future）、`1350` `_localBytesOf`、`1354` `_thumbsFor(OutboxEntry)`（条目 id → 缩略图字节，超过 4 条清理已不在队列里的键）。
- `1671`/`1678` `_buildRow` 把 `thumbs` 传给 `_OutboxBubble`、`imageBytes`/`localBytesOf` 传给 `_MessageBubble`。
- `1970` `canSend = !_sending && (_input.text.trim().isNotEmpty || _attached.isNotEmpty)`；`1984` 输入框上方插预览行；`1989` `IconButton(key: ValueKey('chat-attach'), icon: Icons.image_outlined, tooltip: '发送图片')`。
- `2047` `_buildAttachedRow`：68 高横向 `ListView.separated`，每项 56×56 `ClipRRect(8)` + 右上角 `IconButton(key: ValueKey('attach-remove.$index'), Icons.close)`。
- `2107` `_MessageBubble` 加 `imageBytes`/`localBytesOf`，`2158` 文本上方先渲染 `message.images`；`2211` `_buildImages()`（`Column(crossAxisAlignment: stretch)`）。
- `2238` `class _ChatImage extends StatelessWidget`：有本地字节直接 `Image.memory(width: double.infinity, fit: BoxFit.cover, gaplessPlayback: true)`；否则 `FutureBuilder<Uint8List>` —— 等待中 96 高灰块、失败 `Icons.broken_image_outlined` + 「图片加载失败」、成功按最大高度 260 圆角 10 铺满。**build 里没有任何同步 IO**。
- `2327` `_OutboxBubble` 加 `thumbs`，结构改为 `Column[Wrap(56×56 缩略图), Row[文本, 状态]]`——离线队列里的图片在气泡里也能看见。

### `packages/app/pubspec.yaml`
- `17` `image_picker: ^1.1.2`（放在 `http` 与 `mobile_scanner` 之间，未动其它依赖）。`flutter pub get` 通过，lock 落在 **1.2.4**。

### 既有测试的调用点（只补签名，断言意图未改）
- `packages/app/test/session_chat_outbox_test.dart`：`prompt` override 加 `List<PromptImage> images = const <PromptImage>[]`，prompts 记录类型扩成 `({String text, String? requestId, int images})`。
- `packages/app/test/session_chat_link_bar_test.dart:81` 同上。
- `packages/app/test/session_chat_screen_test.dart:135` 同上。

### 新增测试
- `packages/app/test/prompt_image_test.dart`（9 条）：toJson 有无 name、fromBytes base64 往返、fromJson 容错、`mediaTypeForPath` 四扩展名 + 大小写 + query + 未知、`supportedMediaTypes`。
- `packages/app/test/session_event_image_test.dart`（8 条）：纯图 `user/message` 非 null 且 `images.length == 1`、文本+图都保留、无图无文本仍 null、无 `source` 的纯图不被注入过滤误杀、`assistant/message` 的图不丢、`ChatImageRef.fromJson` 两种形状 / 缺 id / `isLocal`。
- `packages/app/test/session_chat_image_test.dart`（4 条 widget）：e1 `chat-attach` 存在；e2 注入图后 `attach-remove.0` 出现、点掉消失；e3 纯图可发且 `prompts.single` 是 `(text: '', images: 1)`；e4 历史 `sha256:c414` 触发 `cachedAttachment`。

## 验证原文

`flutter analyze`：

```
Analyzing app...
No issues found! (ran in 8.1s)
```

新增三个测试文件：

```
00:02 +21: All tests passed!
```

全量（`flutter test --concurrency=1`）：

```
01:04 +274: All tests passed!
```

新增数：274 - 253（改前基线）= **21** 条图片相关测试（≥6 要求）。

## 取舍说明（给复核用）

1. **发送路径**：`content` 里 text part 用 `if (body.isNotEmpty)` 守卫，所以纯图消息只有 image part；`requestId` 仍然在 `prompt` 里生成（离线重发沿用入队时的那个）。
2. **历史取字节**：渲染时逐张走 `cachedAttachment`，同一 id 只发一次 RPC（inflight 去重 + 40 条 LRU-ish 上限），失败不会无限重试（`_imageFutures` 缓的是已失败的 future，气泡显示「图片加载失败」直到页面重建）。
3. **本地乐观图**：本地气泡用 `attachmentId: 'local:<localId>:<i>'` 占位，字节留在 State 的 `_localImages`；历史回拉拿到真 `sha256:` 图后是新 key，两套并存不会互相覆盖，页面重建时本地图自然消失。
4. **离线队列体积**：单条 base64 合计超 3MB 就只排文本 + 提示「图片太大，联网后再发」，避免把 SharedPreferences 撑爆；条目不阻断文本投递。
5. **纯图队列条目**：`OutboxEntry.tryParse` 现在允许 `text` 为空（只要 images 非空），否则重启后纯图消息会被静默丢弃。
