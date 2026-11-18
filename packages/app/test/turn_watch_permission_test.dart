import 'package:dsh_frp_app/services/platform_bridge.dart';
import 'package:dsh_frp_app/services/turn_watch.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 接住原生桥：`notificationStatus` 按用例给不同的表，其余方法一律 true。
///
/// 为什么单独一份（不复用 `turn_alert_island_test.dart` 里的 `_mockNative`）：
/// 那边的 mock 对所有方法都回 `true`，而 `notificationStatus` 必须回 Map，
/// 权限这条路得看清楚「回了什么」才能断言。
class _Native {
  _Native({
    this.granted = false,
    this.canAsk = true,
    this.statusShapeOk = true,
  });

  final bool granted;
  final bool canAsk;

  /// 故意让 `notificationStatus` 回一个 bool，模拟桥返回形状不对。
  final bool statusShapeOk;

  final List<String> calls = <String>[];

  void install() {
    const channel = MethodChannel('com.ninesky.dsh_frp_app/native');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'notificationStatus':
          if (!statusShapeOk) return true;
          return <String, Object?>{
            'platform': 33,
            'granted': granted,
            'canAsk': canAsk,
            'appNotificationsEnabled': true,
            'channelReady': true,
            'channelImportance': 4,
          };
        default:
          return true;
      }
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  }

  int count(String method) => calls.where((m) => m == method).length;
}

void main() {
  // 权限「问过没有」是进程级的全局状态：一条用例问过，下一条就默认不再问。
  tearDown(TurnWatch.instance.release);

  testWidgets('一轮开跑就顺手把通知权限要到手', (tester) async {
    final native = _Native(granted: false, canAsk: true)..install();
    final watch = TurnWatch.instance..bridge = const PlatformBridge();

    watch.hold(title: '修 500 报错');
    await tester.pump();

    expect(native.count('startTurnWatch'), 1, reason: '先把保活服务挂上');
    expect(native.count('notificationStatus'), 1, reason: '随手查一次权限');
    expect(
      native.count('requestNotificationPermission'),
      1,
      reason: '没给且还能问，就当场问 —— 这时候人还在前台，框弹得出来',
    );
  });

  testWidgets('已经有权限就别再弹框骚扰', (tester) async {
    final native = _Native(granted: true)..install();
    final watch = TurnWatch.instance..bridge = const PlatformBridge();

    watch.hold(title: '修 500 报错');
    await tester.pump();

    expect(native.count('notificationStatus'), 1);
    expect(native.count('requestNotificationPermission'), 0);
  });

  testWidgets('系统已经不弹框了（canAsk=false）就别白问', (tester) async {
    final native = _Native(granted: false, canAsk: false)..install();
    final watch = TurnWatch.instance..bridge = const PlatformBridge();

    watch.hold(title: '修 500 报错');
    await tester.pump();

    expect(
      native.count('requestNotificationPermission'),
      0,
      reason: '永久拒绝之后只能让用户去系统设置，弹框是白弹',
    );
  });

  testWidgets('同一次运行只问一次，不会每轮都弹', (tester) async {
    final native = _Native(granted: false, canAsk: true)..install();
    final watch = TurnWatch.instance..bridge = const PlatformBridge();

    watch.hold(title: '第一轮');
    await tester.pump();
    // 这一轮答完（收掉保活服务），下一轮再 hold —— 权限不该被重新问。
    watch.finish(title: '第一轮');
    await tester.pump();
    watch.hold(title: '第二轮');
    await tester.pump();

    expect(native.count('notificationStatus'), 1, reason: '问过就记住');
    expect(native.count('requestNotificationPermission'), 1);
  });

  testWidgets('桥返回形状不对也不能把这一轮带崩', (tester) async {
    final native = _Native(statusShapeOk: false)..install();
    final watch = TurnWatch.instance..bridge = const PlatformBridge();

    expect(() => watch.hold(title: '修 500 报错'), returnsNormally);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    expect(native.count('startTurnWatch'), 1);
  });
}
