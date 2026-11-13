/// 会话在宿主侧的排队状态。
///
/// 宿主把没轮到的输入放在队列里（`session/observeState` 的 `queue`），每条带
/// 一个 `id` 与发起它的 `rpcId`。`rpcId` 就是我们发 `session/prompt` 时传的
/// `requestId`（宿主侧 `rpcId: request.requestId`），所以客户端能靠它把界面上
/// 的本地气泡和队列项对上，再用 `session/updateQueue` 真撤掉。
class DshQueuedItem {
  const DshQueuedItem({
    required this.id,
    required this.placement,
    this.rpcId,
  });

  /// 队列项 id：`session/updateQueue` 的 `itemId` 就是它。
  final String id;

  /// `queued`（排队等）/ `steering`（插队中）/ `context`（作为上下文塞进去）。
  final String placement;

  /// 发起这条输入的 `session/prompt` 的 `requestId`。
  final String? rpcId;

  bool get waiting => placement == 'queued';

  static DshQueuedItem? tryParse(Object? value) {
    if (value is! Map) return null;
    final id = value['id'];
    if (id is! String || id.isEmpty) return null;
    final placement = value['placement'];
    final rpcId = value['rpcId'];
    return DshQueuedItem(
      id: id,
      placement: placement is String ? placement : 'queued',
      rpcId: rpcId is String && rpcId.isNotEmpty ? rpcId : null,
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
