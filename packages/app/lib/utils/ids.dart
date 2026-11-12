import 'dart:math';

final Random _random = Random.secure();

/// 生成本机唯一主机 id（不依赖 uuid 包）。
String newHostLocalId() {
  final ts = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final rnd = _random.nextInt(0x7FFFFFFF).toRadixString(36);
  return 'h-$ts-$rnd';
}

/// 手搓 v4 形状的 UUID：rpcId 与 prompt 的 requestId 都用它。
///
/// 不引 uuid 依赖：16 字节随机 + 版本位足够，服务端只把它当幂等键。
String newRequestId() {
  final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// 离线待发队列条目的本地 id：只用于列表 key 与落盘去重，不发给服务端。
String newOutboxId() {
  final ts = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final rnd = _random.nextInt(0x7FFFFFFF).toRadixString(36);
  return 'ob-$ts-$rnd';
}
