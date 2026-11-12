import 'dart:math';

final Random _random = Random.secure();

/// 生成本机唯一主机 id（不依赖 uuid 包）。
String newHostLocalId() {
  final ts = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final rnd = _random.nextInt(0x7FFFFFFF).toRadixString(36);
  return 'h-$ts-$rnd';
}
