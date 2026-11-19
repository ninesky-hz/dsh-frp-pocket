import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 图片磁盘缓存总量上限：200 MB。
///
/// 一张历史图片常在一两百 KB 到几 MB 之间（宿主存的是 webp/png 原件），
/// 200 MB 够翻好几个长会话；再大就该怀疑是不是该清一次了。
const int kImageDiskBudgetBytes = 200 * 1024 * 1024;

/// 图片磁盘缓存文件数上限：500 张。
///
/// 只压体积不压张数时，一堆小图会把目录撑成几千个文件，扫描一次就是几百
/// 毫秒——上限让统计与淘汰始终是线性小成本。
const int kImageDiskMaxFiles = 500;

/// 单张超过这个大小就不进磁盘缓存（占预算的四分之一）。
///
/// 宁可每次都从宿主拉，也不让一张大图把整个池子挤空。
const int kImageDiskEntryLimitBytes = kImageDiskBudgetBytes ~/ 4;

/// 全局世代号：清空磁盘缓存时 +1。
///
/// 内存里还留着同一批图片字节的地方（[DshRemote] 的 40 张缓存、会话页的
/// Future 表）各自比较这个数字，发现自己落后就丢掉手上那份——否则用户点了
/// 「清除」之后，屏幕上那些图还在，他会以为没清掉。
int imageCacheEpoch = 0;

/// 通知所有内存缓存丢掉自己那份。
void bumpImageCacheEpoch() => imageCacheEpoch++;

/// 磁盘缓存占用。
@immutable
class ImageCacheStats {
  const ImageCacheStats({required this.count, required this.bytes});

  const ImageCacheStats.empty() : count = 0, bytes = 0;

  /// 缓存文件数。
  final int count;

  /// 缓存总字节数。
  final int bytes;

  bool get isEmpty => count == 0;

  @override
  bool operator ==(Object other) =>
      other is ImageCacheStats && other.count == count && other.bytes == bytes;

  @override
  int get hashCode => Object.hash(count, bytes);

  @override
  String toString() => 'ImageCacheStats($count 张, $bytes 字节)';
}

/// 图片缓存的可替换外壳。
///
/// 调用方只关心两件事：能拿到字节就返回，拿不到返回 null。写、统计、清空都在
/// 实现里自己兜底——缓存坏掉不该让聊天页崩，最多退化成每次都从宿主拉。
abstract class ImageCacheStore {
  Future<Uint8List?> read(String attachmentId);

  Future<void> write(String attachmentId, Uint8List bytes);

  Future<ImageCacheStats> stats();

  /// 清空并返回清掉了多少。
  Future<ImageCacheStats> clear();
}

/// 什么都不做的实现：测试里默认用它，避免碰真实文件系统。
class NoopImageCache implements ImageCacheStore {
  const NoopImageCache();

  @override
  Future<Uint8List?> read(String attachmentId) async => null;

  @override
  Future<void> write(String attachmentId, Uint8List bytes) async {}

  @override
  Future<ImageCacheStats> stats() async => const ImageCacheStats.empty();

  @override
  Future<ImageCacheStats> clear() async => const ImageCacheStats.empty();
}

/// 一条缓存记录：多大、最后一次用是什么时候。
@immutable
class _Entry {
  const _Entry({required this.size, required this.usedMs});

  final int size;
  final int usedMs;

  Map<String, Object?> toJson() =>
      <String, Object?>{'size': size, 'used': usedMs};

  static _Entry? tryParse(Object? value) {
    if (value is! Map) return null;
    final size = value['size'];
    final used = value['used'];
    if (size is! int || used is! int) return null;
    return _Entry(size: size, usedMs: used);
  }
}

/// 落在 `getTemporaryDirectory()/attachments` 的图片缓存。
///
/// 用临时目录而不是文档目录：这块数据随时能从宿主重新拉回来，系统在空间紧张
/// 时替我们清掉正是想要的效果；文档目录只有用户点「清除」才会变小。
///
/// 目录布局：一层平面文件（文件名是 attachmentId 净化后的结果，`sha256:` 里的
/// 冒号在文件名里不合法）外加一份 `index.json` 记录「多大、什么时候用过」。
///
/// **为什么不靠文件修改时间做 LRU**：Windows 上 Dart 读到的 mtime 只有秒级精度，
/// 同一秒内写的几张图时间戳完全一样，排序结果随机——测试里立刻就能翻车，真机
/// 上「刚看过的图被删」也是同一类问题。所以 LRU 挨次自己记账。
class DiskImageCache implements ImageCacheStore {
  DiskImageCache({
    Future<Directory> Function()? root,
    this.budgetBytes = kImageDiskBudgetBytes,
    this.maxFiles = kImageDiskMaxFiles,
    this.entryLimitBytes = kImageDiskEntryLimitBytes,
  }) : _root = root ?? _defaultRoot;

  /// 进程内单例：聊天页每帧都可能来要图，不该每次 new 一个。
  static final DiskImageCache instance = DiskImageCache();

  /// 缓存目录来源（测试注入临时目录用）。
  final Future<Directory> Function() _root;

  final int budgetBytes;
  final int maxFiles;
  final int entryLimitBytes;

  /// 所有涉盘操作串成一条队：并发写 + 并发淘汰会算出两份互相打架的账。
  Future<void> _queue = Future<void>.value();

  /// 目录不可用时（例如测试环境没有插件）只打一次日志。
  bool _rootFailed = false;

  /// 记账表：id → 大小与最后使用时间。第一次用到时才从 `index.json` 载入。
  Map<String, _Entry>? _index;

  static const String _indexName = 'index.json';

  static Future<Directory> _defaultRoot() async {
    final base = await getTemporaryDirectory();
    return Directory('${base.path}/attachments');
  }

  /// 文件名：`sha256:ab/cd` → `sha256_ab_cd.img`。
  ///
  /// 反向不需要：读的时候用同一个函数，id 一样文件名就一样。
  static String fileNameFor(String attachmentId) {
    final safe = attachmentId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return '$safe.img';
  }

  Future<Directory?> _dir() async {
    if (_rootFailed) return null;
    try {
      final dir = await _root();
      if (!await dir.exists()) await dir.create(recursive: true);
      return dir;
    } on Object catch (error) {
      _rootFailed = true;
      debugPrint('DiskImageCache: 缓存目录不可用（$error），图片改为每次从宿主拉');
      return null;
    }
  }

  Future<T> _serial<T>(Future<T> Function() action, T fallback) {
    final result = _queue.then((_) => action()).catchError((Object error) {
      debugPrint('DiskImageCache: $error');
      return fallback;
    });
    _queue = result.then((_) {}).catchError((Object _) {});
    return result;
  }

  /// 读 `index.json`；没有就扫一遍目录，用 mtime 兜底填一次。
  Future<Map<String, _Entry>> _loadIndex(Directory dir) async {
    final existing = _index;
    if (existing != null) return existing;

    final loaded = <String, _Entry>{};

    // 上一次写到一半留下的 .tmp：每次载入账本时顺手清掉，别让它占着地方。
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is File && entity.path.endsWith('.tmp')) {
        try {
          await entity.delete();
        } on Object catch (_) {}
      }
    }

    final indexFile = File('${dir.path}/$_indexName');
    if (await indexFile.exists()) {
      try {
        final raw = jsonDecode(await indexFile.readAsString());
        if (raw is Map) {
          raw.forEach((Object? id, Object? value) {
            final entry = _Entry.tryParse(value);
            if (id is String && entry != null) loaded[id] = entry;
          });
        }
      } on Object catch (error) {
        debugPrint('DiskImageCache: index.json 读不动（$error），重建一次');
        loaded.clear();
      }
    }
    if (loaded.isEmpty) {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        if (entity.path.endsWith('.tmp') || entity.path.endsWith(_indexName)) {
          continue;
        }
        final name = entity.uri.pathSegments.last;
        final id = name.endsWith('.img')
            ? name.substring(0, name.length - 4)
            : name;
        try {
          final stat = await entity.stat();
          loaded[id] = _Entry(
            size: stat.size,
            usedMs: stat.modified.millisecondsSinceEpoch,
          );
        } on Object catch (_) {}
      }
    }
    return _index = loaded;
  }

  Future<void> _saveIndex(Directory dir) async {
    final index = _index;
    if (index == null) return;
    final payload = <String, Object?>{
      for (final entry in index.entries) entry.key: entry.value.toJson(),
    };
    final temp = File('${dir.path}/$_indexName.tmp');
    await temp.writeAsString(jsonEncode(payload), flush: true);
    await temp.rename('${dir.path}/$_indexName');
  }

  @override
  Future<Uint8List?> read(String attachmentId) {
    return _serial<Uint8List?>(() async {
      final dir = await _dir();
      if (dir == null) return null;
      final index = await _loadIndex(dir);
      final entry = index[attachmentId];
      final file = File('${dir.path}/${fileNameFor(attachmentId)}');
      if (entry == null || !await file.exists()) {
        if (entry != null) {
          index.remove(attachmentId);
          await _saveIndex(dir);
        }
        return null;
      }
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) {
        await file.delete();
        index.remove(attachmentId);
        await _saveIndex(dir);
        return null;
      }
      // 命中就记一笔「刚用过」：淘汰从这个时间升序来。
      index[attachmentId] = _Entry(
        size: bytes.length,
        usedMs: DateTime.now().millisecondsSinceEpoch,
      );
      await _saveIndex(dir);
      return bytes;
    }, null);
  }

  @override
  Future<void> write(String attachmentId, Uint8List bytes) {
    return _serial<void>(() async {
      if (bytes.isEmpty || bytes.length > entryLimitBytes) return;
      final dir = await _dir();
      if (dir == null) return;
      final index = await _loadIndex(dir);
      final target = File('${dir.path}/${fileNameFor(attachmentId)}');
      final temp = File('${target.path}.tmp');
      await temp.writeAsBytes(bytes, flush: true);
      await temp.rename(target.path);
      index[attachmentId] = _Entry(
        size: bytes.length,
        usedMs: DateTime.now().millisecondsSinceEpoch,
      );
      await _evict(dir, index);
      await _saveIndex(dir);
    }, null);
  }

  /// 超预算就按「最后使用时间」从旧到新删，直到两个上限都满足。
  Future<void> _evict(Directory dir, Map<String, _Entry> index) async {
    var total = index.values.fold<int>(0, (sum, entry) => sum + entry.size);
    var count = index.length;
    if (total <= budgetBytes && count <= maxFiles) return;

    final ordered = index.entries.toList()
      ..sort((a, b) => a.value.usedMs.compareTo(b.value.usedMs));
    for (final item in ordered) {
      if (total <= budgetBytes && count <= maxFiles) break;
      final file = File('${dir.path}/${fileNameFor(item.key)}');
      try {
        if (await file.exists()) await file.delete();
        total -= item.value.size;
        count -= 1;
        index.remove(item.key);
      } on Object catch (_) {}
    }
  }

  @override
  Future<ImageCacheStats> stats() {
    return _serial<ImageCacheStats>(() async {
      final dir = await _dir();
      if (dir == null) return const ImageCacheStats.empty();
      final index = await _loadIndex(dir);
      var count = 0;
      var bytes = 0;
      // 以磁盘为准统计体积（index 里的大小可能因为外部清理而过时）。
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (name.endsWith('.tmp') || name == _indexName) continue;
        try {
          bytes += await entity.length();
          count += 1;
        } on Object catch (_) {}
      }
      if (count != index.length) {
        // 有人在外面删过文件：把账本对齐，顺手落一次盘。
        index.removeWhere(
          (id, _) => !File('${dir.path}/${fileNameFor(id)}').existsSync(),
        );
        await _saveIndex(dir);
      }
      return ImageCacheStats(count: count, bytes: bytes);
    }, const ImageCacheStats.empty());
  }

  @override
  Future<ImageCacheStats> clear() {
    return _serial<ImageCacheStats>(() async {
      final dir = await _dir();
      if (dir == null) return const ImageCacheStats.empty();
      var count = 0;
      var bytes = 0;
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (name == _indexName) continue;
        try {
          if (!name.endsWith('.tmp')) bytes += await entity.length();
          await entity.delete();
          if (!name.endsWith('.tmp')) count += 1;
        } on Object catch (_) {}
      }
      _index?.clear();
      await _saveIndex(dir);
      return ImageCacheStats(count: count, bytes: bytes);
    }, const ImageCacheStats.empty());
  }
}

/// 人类可读的占用：`0 KB` / `812 KB` / `38.4 MB` / `1 GB`。
String formatCacheSize(int bytes) {
  if (bytes < 1024) return '0 KB';
  const units = <String>['KB', 'MB', 'GB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  final isWhole = (value - value.roundToDouble()).abs() < 0.05;
  final text = unit == 0 || value >= 100 || isWhole
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(1);
  return '$text ${units[unit]}';
}
