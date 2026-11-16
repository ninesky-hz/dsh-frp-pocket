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
  id: 'host-short',
  name: '测试网关',
  url: 'https://gw.example.com',
  pin: '1234',
);

/// 只有 [count] 条消息的会话：用来量「内容不满一屏」时的顶部对齐。
SessionHistory _history(int count) => SessionHistory.fromJson(<String, Object?>{
  'cursor': count,
  'hasMore': false,
  'records': <Object?>[
    for (var i = 1; i <= count; i++)
      <String, Object?>{
        'type': 'event',
        'event': <String, Object?>{
          'type': i.isEven ? 'assistant/message' : 'user/message',
          'seq': i,
          'data': <String, Object?>{
            'message': <String, Object?>{
              'role': i.isEven ? 'assistant' : 'user',
              'content': <Object?>[
                <String, Object?>{'type': 'text', 'text': '第 $i 段正文内容。'},
              ],
              if (i.isOdd) 'source': <String, Object?>{'kind': 'user'},
            },
          },
        },
      },
  ],
});

class _FakeRemote extends DshRemote {
  _FakeRemote(this.count) : super(host: _host);

  final int count;
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
  }) async => _history(count);

  @override
  Future<List<SessionSummary>> childSessions(String parentSessionId) async =>
      const <SessionSummary>[];

  Future<void> close() => frames.close();
}

Future<void> _open(WidgetTester tester, int count) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final settings = SettingsStore();
  await settings.load();
  final remote = _FakeRemote(count);

  await tester.pumpWidget(
    AppScope(
      hosts: HostStore(),
      settings: settings,
      child: MaterialApp(
        home: SessionChatScreen(
          host: _host,
          session: SessionSummary(
            sessionId: 'session-short',
            title: '短会话',
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
    DshStreamFrame(kind: DshFrameKind.snapshot, asOfSeq: count),
  );
  await tester.pumpAndSettle();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await remote.close();
  });
}

/// 列表里所有气泡正文的矩形（含已经滚出视口的行）。
List<Rect> _textRects(WidgetTester tester) => <Rect>[
  for (final element in find.byType(SelectableText).evaluate())
    if (element.renderObject is RenderBox)
      (element.renderObject! as RenderBox).localToGlobal(Offset.zero) &
          (element.renderObject! as RenderBox).size,
];

void main() {
  testWidgets('两条消息时，第一条能顶到列表顶边', (tester) async {
    await _open(tester, 2);

    final listRect = tester.getRect(find.byKey(const Key('chat-list')));
    final rects = _textRects(tester);
    final top = rects.map((r) => r.top).reduce((a, b) => a < b ? a : b);
    final bottom = rects.map((r) => r.bottom).reduce((a, b) => a > b ? a : b);
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    debugPrint(
      'DBG list=${listRect.top}..${listRect.bottom} '
      'texts=${rects.length} top=$top bottom=$bottom '
      'min=${position.minScrollExtent} max=${position.maxScrollExtent} '
      'pixels=${position.pixels} vp=${position.viewportDimension}',
    );

    // 8px 顶间距 + 气泡内边距，加起来不到一行字高。
    expect(
      top - listRect.top,
      lessThan(40),
      reason: '首条消息应该贴着列表顶边（列表顶 ${listRect.top}，最早一条顶 $top）',
    );
    expect(
      listRect.bottom - bottom,
      greaterThan(120),
      reason: '内容从顶部往下排，空白应该留在下面（最后一条底 $bottom，列表底 ${listRect.bottom}）',
    );
    // 尾部补了空白：位置停在最底，但内容是从上往下排的。
    expect(position.pixels, closeTo(position.maxScrollExtent, 0.5));
    expect(position.maxScrollExtent, greaterThan(0));
  });

  testWidgets('四十条消息时仍然是最新一条贴底边', (tester) async {
    await _open(tester, 40);

    final listRect = tester.getRect(find.byKey(const Key('chat-list')));
    final rects = _textRects(tester);
    final bottom = rects.map((r) => r.bottom).reduce((a, b) => a > b ? a : b);
    final top = rects.map((r) => r.top).reduce((a, b) => a < b ? a : b);
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    debugPrint(
      'DBG long list=${listRect.top}..${listRect.bottom} '
      'texts=${rects.length} top=$top bottom=$bottom '
      'min=${position.minScrollExtent} max=${position.maxScrollExtent} '
      'pixels=${position.pixels} vp=${position.viewportDimension}',
    );

    expect(
      bottom,
      greaterThan(listRect.bottom - 64),
      reason: '长会话不该被尾部空白顶上去（最新一条底 $bottom，列表底 ${listRect.bottom}）',
    );
    expect(
      top,
      lessThan(listRect.top),
      reason: '长会话内容超一屏，最早一条应该在视口上方之外（顶 $top）',
    );
  });
}
