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
  id: 'host-sticky',
  name: '测试网关',
  url: 'https://gw.example.com',
  pin: '1234',
);

SessionHistory _history() => SessionHistory.fromJson(<String, Object?>{
  'cursor': 40,
  'hasMore': false,
  'records': <Object?>[
    for (var i = 1; i <= 40; i++)
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

void main() {
  testWidgets('从底部一点点往上拖，每一下都要真的动', (tester) async {
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
              sessionId: 'session-sticky',
              title: '贴底',
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
      const DshStreamFrame(kind: DshFrameKind.snapshot, asOfSeq: 40),
    );
    await tester.pumpAndSettle();

    final scrollable =
        tester.state<ScrollableState>(find.byType(Scrollable).first);
    final bottom = scrollable.position.pixels;

    debugPrint('DBG min=${scrollable.position.minScrollExtent} max=${scrollable.position.maxScrollExtent} pixels=${scrollable.position.pixels} texts=${find.byType(SelectableText).evaluate().length}');
    final moved = <double>[];
    for (var i = 0; i < 5; i += 1) {
      await tester.drag(find.byType(CustomScrollView), const Offset(0, 40));
      await tester.pumpAndSettle();
      moved.add(scrollable.position.pixels);
    }

    expect(
      moved.last,
      lessThan(bottom - 40),
      reason: '小步向上拖也要离开底部：$moved（底部 $bottom）',
    );

    await tester.pumpWidget(const SizedBox());
    await remote.close();
  });
}
