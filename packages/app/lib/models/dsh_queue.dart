import 'session_event.dart';

/// 会话在宿主侧的排队状态。
///
/// 宿主把没轮到的输入放在队列里（`session/observeState` 的 `queue`），每条带
/// 一个 `id`、发起它的 `rpcId`，以及**完整的内容**（`content`，与 durable 的
/// `user/message` 同构）。`rpcId` 就是我们发 `session/prompt` 时传的
/// `requestId`，所以客户端能靠它把界面上的本地气泡和队列项对上，再用
/// `session/updateQueue` 真撤掉。
///
/// 为什么要留 [text]：排队中的输入**不在** `session/page` 里（宿主只把它记成
/// `agent/inbox/spliced`，真正开跑后才追加 `user/message`）。所以「等待中那条」
/// 唯一的权威来源就是这里的 `content`。只靠本地副本（`_pending` + 落盘）迟早
/// 会丢——落盘是异步 apply，进程被冻结/杀掉就没了，丢了也没有任何地方能补回来。
class DshQueuedItem {
  const DshQueuedItem({
    required this.id,
    required this.placement,
    this.rpcId,
    this.text,
    this.images = const <ChatImageRef>[],
  });

  /// 队列项 id：`session/updateQueue` 的 `itemId` 就是它。
  final String id;

  /// `queued`（排队等）/ `steering`（插队中）/ `context`（作为上下文塞进去）。
  final String placement;

  /// 发起这条输入的 `session/prompt` 的 `requestId`。
  final String? rpcId;

  /// 队列项的正文（`content` 里的 text part 拼起来）。纯图消息为 null。
  final String? text;

  /// 队列项带的图（`type == 'image'` 的 part）。
  final List<ChatImageRef> images;

  bool get waiting => placement == 'queued';

  /// 行身份：合成出来的气泡用它当 key，队列项变化时列表项能原地复用。
  String get rowKey => 'queue:$id';

  /// 把队列项还原成聊天页里的一行。
  ///
  /// 没有文字也没有图就返回 null——那种项在界面上没有可说的东西。
  ChatMessage? toMessage() {
    final body = text?.trim() ?? '';
    if (body.isEmpty && images.isEmpty) return null;
    return ChatMessage(
      key: rowKey,
      localId: rowKey,
      role: ChatRole.user,
      text: body,
      delivery: waiting ? ChatDelivery.queued : ChatDelivery.none,
      images: images,
      requestId: rpcId,
    );
  }

  static DshQueuedItem? tryParse(Object? value) {
    if (value is! Map) return null;
    final id = value['id'];
    if (id is! String || id.isEmpty) return null;
    final placement = value['placement'];
    final rpcId = value['rpcId'];
    final content = value['content'];
    return DshQueuedItem(
      id: id,
      placement: placement is String ? placement : 'queued',
      rpcId: rpcId is String && rpcId.isNotEmpty ? rpcId : null,
      text: contentText(content),
      images: contentImages(content),
    );
  }

  /// `queue` 可能是 `null`（宿主没给队列，或这一轮跑完已经清空）。
  static List<DshQueuedItem> parseList(Object? value) {
    if (value is! List) return const <DshQueuedItem>[];
    final items = <DshQueuedItem>[];
    for (final entry in value) {
      final item = tryParse(entry);
      if (item != null) items.add(item);
    }
    return List<DshQueuedItem>.unmodifiable(items);
  }
}
