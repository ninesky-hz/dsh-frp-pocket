import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_frp_app/services/image_cache.dart';
import 'package:flutter_test/flutter_test.dart';

/// 建一份指向临时目录的缓存，顺便把目录交回去做断言。
Future<(DiskImageCache, Directory)> _cache({
  int budgetBytes = kImageDiskBudgetBytes,
  int maxFiles = kImageDiskMaxFiles,
  int entryLimitBytes = kImageDiskEntryLimitBytes,
}) async {
  final dir = await Directory.systemTemp.createTemp('image-cache-test');
  final cache = DiskImageCache(
    root: () async => dir,
    budgetBytes: budgetBytes,
    maxFiles: maxFiles,
    entryLimitBytes: entryLimitBytes,
  );
  return (cache, dir);
}

Uint8List _bytes(int length, int fill) =>
    Uint8List.fromList(List<int>.filled(length, fill));

void main() {
  test('写进去再读出来是同一份字节', () async {
    final (cache, dir) = await _cache();
    final data = _bytes(2048, 7);

    await cache.write('sha256:abcd', data);
    final read = await cache.read('sha256:abcd');

    expect(read, isNotNull);
    expect(read, equals(data));
    // 文件名里不能留冒号（Android 上不合法），但同一个 id 每次都要落到同一个文件。
    expect(File('${dir.path}/${DiskImageCache.fileNameFor('sha256:abcd')}').existsSync(), isTrue);
    await dir.delete(recursive: true);
  });

  test('stats 报出张数与总字节', () async {
    final (cache, dir) = await _cache();
    await cache.write('a', _bytes(1000, 1));
    await cache.write('b', _bytes(2000, 2));

    final stats = await cache.stats();
    expect(stats.count, 2);
    expect(stats.bytes, 3000);

    await dir.delete(recursive: true);
  });

  test('clear 之后读不到东西，占用归零', () async {
    final (cache, dir) = await _cache();
    await cache.write('a', _bytes(1000, 1));
    await cache.write('b', _bytes(2000, 2));

    final removed = await cache.clear();
    expect(removed.count, 2);
    expect(removed.bytes, 3000);
    expect(await cache.read('a'), isNull);
    expect(await cache.stats(), const ImageCacheStats.empty());

    await dir.delete(recursive: true);
  });

  test('超过张数上限时删最久没用的那张', () async {
    final (cache, dir) = await _cache(maxFiles: 3);
    for (final id in <String>['a', 'b', 'c']) {
      await cache.write(id, _bytes(100, 1));
      // 写文件的时间戳精度有限，隔开一点才能分出先后。
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    // 摸一下 a：它变成「最近用过」的那张。
    expect(await cache.read('a'), isNotNull);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    await cache.write('d', _bytes(100, 1));
    final stats = await cache.stats();

    expect(stats.count, 3);
    expect(await cache.read('a'), isNotNull, reason: '刚摸过的 a 不该被删');
    expect(await cache.read('b'), isNull, reason: '最旧的 b 应该先走');
    expect(await cache.read('d'), isNotNull);

    await dir.delete(recursive: true);
  });

  test('超过总预算时按大小往下删，直到装得下', () async {
    final (cache, dir) = await _cache(budgetBytes: 3000);
    await cache.write('a', _bytes(1500, 1));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await cache.write('b', _bytes(1500, 2));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await cache.write('c', _bytes(1500, 3));

    final stats = await cache.stats();
    expect(stats.bytes, lessThanOrEqualTo(3000));
    expect(stats.count, 2);
    expect(await cache.read('a'), isNull);

    await dir.delete(recursive: true);
  });

  test('空字节不落盘', () async {
    final (cache, dir) = await _cache();
    await cache.write('a', Uint8List(0));
    expect(await cache.stats(), const ImageCacheStats.empty());
    expect(await cache.read('a'), isNull);
    await dir.delete(recursive: true);
  });

  test('单张超过条目上限的不进缓存（省得一张图把池子挤空）', () async {
    final (cache, dir) = await _cache(budgetBytes: 4000, entryLimitBytes: 1000);
    await cache.write('big', _bytes(2000, 1));
    await cache.write('small', _bytes(500, 2));

    expect(await cache.read('big'), isNull);
    expect(await cache.read('small'), isNotNull);
    await dir.delete(recursive: true);
  });

  test('目录不可用时降级成「每次都拉」而不是抛错', () async {
    final cache = DiskImageCache(
      root: () async => throw const FileSystemException('没这个目录'),
    );
    await cache.write('a', _bytes(10, 1));
    expect(await cache.read('a'), isNull);
    expect(await cache.stats(), const ImageCacheStats.empty());
    expect(await cache.clear(), const ImageCacheStats.empty());
  });

  test('半途留下的 .tmp 会被清掉、也不计入占用', () async {
    final (cache, dir) = await _cache();
    final temp = File('${dir.path}/leftover.img.tmp');
    await temp.writeAsBytes(_bytes(500, 9));

    await cache.write('a', _bytes(100, 1));
    expect(temp.existsSync(), isFalse);
    expect((await cache.stats()).count, 1);
    await dir.delete(recursive: true);
  });

  test('formatCacheSize 四舍五入到合适单位', () {
    expect(formatCacheSize(0), '0 KB');
    expect(formatCacheSize(900), '0 KB');
    expect(formatCacheSize(1024), '1 KB');
    expect(formatCacheSize(812 * 1024), '812 KB');
    expect(formatCacheSize((38.4 * 1024 * 1024).round()), '38.4 MB');
    expect(formatCacheSize(1024 * 1024 * 1024), '1 GB');
  });

  test('NoopImageCache 什么都不留（测试默认用它）', () async {
    const cache = NoopImageCache();
    await cache.write('a', _bytes(10, 1));
    expect(await cache.read('a'), isNull);
    expect(await cache.stats(), const ImageCacheStats.empty());
  });
}
