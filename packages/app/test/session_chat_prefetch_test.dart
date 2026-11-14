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
  id: 'host-prefetch',
  name: '测试网关',
  url: 'https://gw.example.com',
  pin: '1234',
);

SessionHistory _page(int lowest, int before) =>
    SessionHistory.fromJson(<String, Object?>{
      'cursor': lowest,
      'hasMore': lowest > 1,
      'records': <Object?>[
        for (var i = lowest; i < before; i++)
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

class _PageRemote extends DshRemote {
  _PageRemote() : super(host: _host);

  final StreamController<DshStreamFrame> frames =
      StreamController<DshStreamFrame>.broadcast();
  final List<int?> calls = <int?>[];

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
  }) async {
    calls.add(beforeSeq);
    final before = beforeSeq ?? 100;
    final lowest = before - maxMessages < 1 ? 1 : before - maxMessages;
    return _page(lowest, before);
  }

  @override
  Future<List<SessionSummary>> childSessions(String parentSessionId) async =>
      const <SessionSummary>[];

  Future<void> close() => frames.close();
}

void main() {
  testWidgets('进会话就先预取更早的页，用户往上翻时内容已经在路上', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final settings = SettingsStore();
    await settings.load();
    final remote = _PageRemote();

    await tester.pumpWidget(
      AppScope(
        hosts: HostStore(),
        settings: settings,
        child: MaterialApp(
          home: SessionChatScreen(
            host: _host,
            session: SessionSummary(
              sessionId: 'session-prefetch',
              title: '预取',
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
      const DshStreamFrame(kind: DshFrameKind.snapshot, asOfSeq: 100),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();

    expect(remote.calls.length, greaterThanOrEqualTo(2), reason: '首屏之后要自动预取');
    expect(remote.calls.first, isNull, reason: '首屏不带 beforeSeq');
    expect(remote.calls[1], 70, reason: '预取从首屏最老那条往前接');

    // 预取有上限：再等一会儿也不该无限往回翻旧账。
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(
      remote.calls.length,
      lessThanOrEqualTo(1 + SessionChatScreen.prefetchPages),
      reason: '预取页数要有上限，实际 ${remote.calls}',
    );

    await tester.pumpWidget(const SizedBox());
    await remote.close();
  });
}
