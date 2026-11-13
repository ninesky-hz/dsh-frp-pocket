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
  id: 'host-copy',
  name: '测试网关',
  url: 'https://gw.example.com',
  pin: '1234',
);

SessionHistory _history() => SessionHistory.fromJson(<String, Object?>{
  'cursor': 9,
  'hasMore': false,
  'records': <Object?>[
    for (final (seq, role, text) in <(int, String, String)>[
      (1, 'user', '这句话我想复制出来'),
      (2, 'assistant', '这段回复也想复制一部分'),
    ])
      <String, Object?>{
        'type': 'event',
        'event': <String, Object?>{
          'type': role == 'user' ? 'user/message' : 'assistant/message',
          'seq': seq,
          'data': <String, Object?>{
            'message': <String, Object?>{
              'role': role,
              'content': <Object?>[
                <String, Object?>{'type': 'text', 'text': text},
              ],
              if (role == 'user')
                'source': <String, Object?>{'kind': 'user'},
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

SessionSummary _session() => SessionSummary(
  sessionId: 'session-copy',
  title: '复制测试',
  cwd: r'D:\Ai-Project\demo',
  updatedAt: DateTime.now(),
);

void main() {
  testWidgets('聊天正文是可选中文本，长按能选一部分复制', (tester) async {
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
            session: _session(),
            remote: remote,
            snapshotTimeout: Duration.zero,
          ),
        ),
      ),
    );
    remote.frames.add(
      const DshStreamFrame(kind: DshFrameKind.snapshot, asOfSeq: 9),
    );
    await tester.pumpAndSettle();

    // 正文走 `SelectableText`（普通 `Text` 选不了字）。
    final selectables = tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .map((widget) => widget.data)
        .toList();
    expect(selectables, contains('这句话我想复制出来'));
    expect(selectables, contains('这段回复也想复制一部分'));

    // 没包 `SelectionArea`：它会和带 center 的 CustomScrollView 抢滚动容器，
    // 选字时去拿已 defunct 的 element 取位置（真机上是崩溃日志）。
    expect(find.byType(SelectionArea), findsNothing);

    // 输入框自己的文本框不在这一层，别把聊天区的选字语义扩大过去。
    expect(find.byType(TextField), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await remote.close();
  });
}
