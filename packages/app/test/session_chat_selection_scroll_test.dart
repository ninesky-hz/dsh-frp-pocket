import 'dart:async';

import 'package:dsh_frp_app/app_scope.dart';
import 'package:dsh_frp_app/data/host_store.dart';
import 'package:dsh_frp_app/data/settings_store.dart';
import 'package:dsh_frp_app/models/host.dart';
import 'package:dsh_frp_app/models/host_event.dart';
import 'package:dsh_frp_app/models/session_event.dart';
import 'package:dsh_frp_app/models/session_summary.dart';
import 'package:dsh_frp_app/screens/session_chat_screen.dart';
import 'package:dsh_frp_app/services/dsh_remote.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const Host _host = Host(
  id: 'host-select-scroll',
  name: '测试网关',
  url: 'https://gw.example.com',
  pin: '1234',
);

/// 三条一组：一条比整屏还高的助手回复，夹着短句，用来复现「长按把列表拽走」。
SessionHistory _history() => SessionHistory.fromJson(<String, Object?>{
  'cursor': 24,
  'hasMore': false,
  'records': <Object?>[
    for (var i = 1; i <= 24; i++)
      <String, Object?>{
        'type': 'event',
        'event': <String, Object?>{
          'type': i.isEven ? 'assistant/message' : 'user/message',
          'seq': i,
          'data': <String, Object?>{
            'message': <String, Object?>{
              'role': i.isEven ? 'assistant' : 'user',
              'content': <Object?>[
                <String, Object?>{
                  'type': 'text',
                  'text': '第 $i 段：${'这一行是要复制的正文。' * (i.isEven ? 12 : 1)}',
                },
              ],
              if (i.isOdd) 'source': <String, Object?>{'kind': 'user'},
            },
          },
        },
      },
  ],
});

class _FakeRemote extends DshRemote {
  _FakeRemote() : super(host: _host);

  final StreamController<DshStreamFrame> frames =
      StreamController<DshStreamFrame>.broadcast();

  @override
  Stream<DshStreamFrame> followSession(String sessionId, {int? maxMessages}) =>
      frames.stream;

  @override
  Stream<DshHostEvent> followEvents() => const Stream<DshHostEvent>.empty();

  @override
  Future<SessionHistory> page(
    String sessionId, {
    required int throughSeq,
    int? beforeSeq,
    int maxMessages = 20,
  }) async => _history();

  @override
  Future<List<SessionSummary>> childSessions(String parentSessionId) async =>
      const <SessionSummary>[];

  Future<void> close() => frames.close();
}


/// 找一个「确实露在视口里」的正文元素，返回它上面可以按下去的点。
///
/// 滚过之后 `find.byType(SelectableText).first` 往往已经在屏幕外，
/// 直接按它会打在空气上 —— 测试就成了假绿。
Offset _visibleTextPoint(WidgetTester tester) {
  final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
  for (final element in find.byType(SelectableText).evaluate()) {
    final box = element.renderObject as RenderBox?;
    if (box == null || !box.hasSize || !box.attached) continue;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    final point = rect.center;
    if (point.dy < 80 || point.dy > screen.height - 160) continue;
    if (point.dx < 8 || point.dx > screen.width - 8) continue;
    return point;
  }
  fail('视口里没有可长按的正文');
}

void main() {
  testWidgets('长按选字，列表不许自己滚走', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final settings = SettingsStore();
    await settings.load();
    final remote = _FakeRemote();

    await tester.pumpWidget(
      AppScope(
        hosts: HostStore(),
        settings: settings,
        child: MaterialApp(
          home: SessionChatScreen(
            host: _host,
            session: SessionSummary(
              sessionId: 'session-select-scroll',
              title: '选字滚动',
              cwd: r'D:\Ai-Project\demo',
              updatedAt: DateTime.now(),
            ),
            remote: remote,
            snapshotTimeout: Duration.zero,
          ),
        ),
      ),
    );
    remote.frames.add(
      const DshStreamFrame(kind: DshFrameKind.snapshot, asOfSeq: 24),
    );
    await tester.pumpAndSettle();

    final scrollable = tester.state<ScrollableState>(find.byType(Scrollable).first);

    // 往上翻进历史，停在中间。
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 600));
    await tester.pumpAndSettle();
    final beforeSelection = scrollable.position.pixels;
    // 列表是 `CustomScrollView(center:)`，历史那一段的 offset 是负的，
    // 只要确认确实翻上去了就行。
    expect(beforeSelection, isNot(0));

    // 长按一段可见正文：以前这一下会把整条列表拽到底（`ensureVisible`
    // 满足不了「整段可见」，只能滚到末尾），用户就选不到想选的字。
    // 按在列表正中间那行字上（滚过之后 byWidget 找到的第一条可能已经出屏）。
    await tester.longPressAt(_visibleTextPoint(tester));
    await tester.pumpAndSettle();

    expect(
      scrollable.position.pixels,
      closeTo(beforeSelection, 0.5),
      reason: '选字不该改变视口位置',
    );

    await tester.pumpWidget(const SizedBox());
    await remote.close();
  });

  testWidgets('长按选字之后拖一下，列表不许跟着滑；轻点一下解冻', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final settings = SettingsStore();
    await settings.load();
    final remote = _FakeRemote();

    await tester.pumpWidget(
      AppScope(
        hosts: HostStore(),
        settings: settings,
        child: MaterialApp(
          home: SessionChatScreen(
            host: _host,
            session: SessionSummary(
              sessionId: 'session-select-scroll',
              title: '选字冻结',
              cwd: r'D:\Ai-Project\demo',
              updatedAt: DateTime.now(),
            ),
            remote: remote,
            snapshotTimeout: Duration.zero,
          ),
        ),
      ),
    );
    remote.frames.add(
      const DshStreamFrame(kind: DshFrameKind.snapshot, asOfSeq: 24),
    );
    await tester.pumpAndSettle();

    final scrollable =
        tester.state<ScrollableState>(find.byType(Scrollable).first);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 400));
    await tester.pumpAndSettle();

    // 长按一段正文 → 起了一段选区 → 列表冻住。
    await tester.longPressAt(_visibleTextPoint(tester));
    await tester.pumpAndSettle();
    expect(
      tester.widget<CustomScrollView>(find.byType(CustomScrollView)).physics,
      isA<NeverScrollableScrollPhysics>(),
      reason: '选字期间别让列表跟着手滑',
    );

    final frozen = scrollable.position.pixels;
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(
      scrollable.position.pixels,
      closeTo(frozen, 0.5),
      reason: '选字期间拖动不该改变视口',
    );

    // 轻点一下收工，滚动交回给用户。
    await tester.tapAt(const Offset(200, 120));
    await tester.pumpAndSettle();
    expect(
      tester.widget<CustomScrollView>(find.byType(CustomScrollView)).physics,
      isNull,
      reason: '轻点之后要能继续滚动',
    );

    await tester.pumpWidget(const SizedBox());
    await remote.close();
  });

  testWidgets('流式还在长的时候翻上去选字，不许被拽回底部', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final settings = SettingsStore();
    await settings.load();
    final remote = _FakeRemote();

    await tester.pumpWidget(
      AppScope(
        hosts: HostStore(),
        settings: settings,
        child: MaterialApp(
          home: SessionChatScreen(
            host: _host,
            session: SessionSummary(
              sessionId: 'session-select-scroll',
              title: '流式选字',
              cwd: r'D:\Ai-Project\demo',
              updatedAt: DateTime.now(),
            ),
            remote: remote,
            snapshotTimeout: Duration.zero,
          ),
        ),
      ),
    );
    remote.frames.add(
      const DshStreamFrame(kind: DshFrameKind.snapshot, asOfSeq: 24),
    );
    await tester.pumpAndSettle();

    final scrollable =
        tester.state<ScrollableState>(find.byType(Scrollable).first);

    // 翻上去看历史。
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 600));
    await tester.pumpAndSettle();
    final beforeStream = scrollable.position.pixels;

    // 流式继续往下长。
    remote.frames.add(
      decodeDshStreamFrame(<String, Object?>{
        'type': 'item',
        'value': <String, Object?>{
          'type': 'assistant-stream',
          'frame': <String, Object?>{
            'type': 'start',
            'attemptId': 'session-select-scroll:1',
            'revision': 1,
            'turn': 1,
            'step': 1,
            'startedAfterSeq': 24,
          },
        },
      }),
    );
    for (var i = 0; i < 6; i++) {
      remote.frames.add(
        decodeDshStreamFrame(<String, Object?>{
          'type': 'item',
          'value': <String, Object?>{
            'type': 'assistant-stream',
            'frame': <String, Object?>{
              'type': 'chunk',
              'attemptId': 'session-select-scroll:1',
              'revision': i + 2,
              'index': i,
              'chunk': <String, Object?>{
                'type': 'text-delta',
                'index': 0,
                'text': '流式第 $i 行：这段话还在写。\n',
              },
            },
          },
        }),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    // 流式里光标一直在闪，`pumpAndSettle` 永远等不到静止；给两帧就够了。
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));

    expect(
      scrollable.position.pixels,
      closeTo(beforeStream, 0.5),
      reason: '翻上去看历史时，流式增长不该把视口拽回底部',
    );

    await tester.pumpWidget(const SizedBox());
    await remote.close();
  });
}
