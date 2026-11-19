import 'dart:typed_data';

import 'package:dsh_frp_app/services/image_cache.dart';
import 'package:dsh_frp_app/theme/app_theme.dart';
import 'package:dsh_frp_app/widgets/image_cache_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 可控的假缓存：想看什么数字就给什么，清空可以被数到次数。
class _FakeStore implements ImageCacheStore {
  _FakeStore({this.count = 0, this.bytes = 0});

  int count;
  int bytes;
  int clears = 0;
  int reads = 0;

  @override
  Future<ImageCacheStats> stats() async =>
      ImageCacheStats(count: count, bytes: bytes);

  @override
  Future<ImageCacheStats> clear() async {
    clears += 1;
    final removed = ImageCacheStats(count: count, bytes: bytes);
    count = 0;
    bytes = 0;
    return removed;
  }

  @override
  Future<Uint8List?> read(String attachmentId) async {
    reads += 1;
    return null;
  }

  @override
  Future<void> write(String attachmentId, Uint8List bytes) async {}
}

Future<void> _pump(WidgetTester tester, _FakeStore store) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: Scaffold(body: ListView(children: <Widget>[ImageCacheTile(store: store)])),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('有缓存时把占用说清楚：多少 MB、多少张', (tester) async {
    final store = _FakeStore(count: 126, bytes: 40265318);
    await _pump(tester, store);

    final text = tester.widget<Text>(find.byKey(ImageCacheTile.sizeKey)).data!;
    expect(text, contains('38.4 MB'));
    expect(text, contains('126 张'));
    expect(find.text('图片缓存'), findsOneWidget);
  });

  testWidgets('还没缓存时说明「看一次拉一次」，清除按钮不给点', (tester) async {
    final store = _FakeStore();
    await _pump(tester, store);

    final text = tester.widget<Text>(find.byKey(ImageCacheTile.sizeKey)).data!;
    expect(text, contains('还没有缓存'));
    final button = tester.widget<TextButton>(find.byKey(ImageCacheTile.clearKey));
    expect(button.onPressed, isNull, reason: '没东西可清时按下去只会让人困惑');
  });

  testWidgets('点清除先弹确认框，取消就什么都不做', (tester) async {
    final store = _FakeStore(count: 3, bytes: 2097152);
    await _pump(tester, store);

    await tester.tap(find.byKey(ImageCacheTile.clearKey));
    await tester.pumpAndSettle();
    expect(find.text('清除图片缓存？'), findsOneWidget);

    await tester.tap(find.byKey(ImageCacheTile.cancelKey));
    await tester.pumpAndSettle();

    expect(store.clears, 0);
    expect(
      tester.widget<Text>(find.byKey(ImageCacheTile.sizeKey)).data,
      contains('2 MB'),
    );
  });

  testWidgets('确认后清空、数字归零、给一句「已清除」', (tester) async {
    final store = _FakeStore(count: 3, bytes: 2097152);
    await _pump(tester, store);

    await tester.tap(find.byKey(ImageCacheTile.clearKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ImageCacheTile.confirmKey));
    await tester.pumpAndSettle();

    expect(store.clears, 1);
    expect(
      tester.widget<Text>(find.byKey(ImageCacheTile.sizeKey)).data,
      contains('还没有缓存'),
    );
    expect(find.textContaining('已清除'), findsOneWidget);
    // 清完就没有可点的了。
    final button = tester.widget<TextButton>(find.byKey(ImageCacheTile.clearKey));
    expect(button.onPressed, isNull);
  });

  testWidgets('清完内存缓存也跟着作废（世代号 +1）', (tester) async {
    final store = _FakeStore(count: 1, bytes: 1024);
    final before = imageCacheEpoch;
    await _pump(tester, store);

    await tester.tap(find.byKey(ImageCacheTile.clearKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ImageCacheTile.confirmKey));
    await tester.pumpAndSettle();

    expect(imageCacheEpoch, greaterThan(before));
  });
}
