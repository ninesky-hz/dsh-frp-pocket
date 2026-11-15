import 'dart:async';

import 'package:dsh_frp_app/app_scope.dart';
import 'package:dsh_frp_app/data/host_store.dart';
import 'package:dsh_frp_app/data/settings_store.dart';
import 'package:dsh_frp_app/models/app_settings.dart';
import 'package:dsh_frp_app/models/host.dart';
import 'package:dsh_frp_app/models/host_event.dart';
import 'package:dsh_frp_app/models/session_event.dart';
import 'package:dsh_frp_app/models/session_summary.dart';
import 'package:dsh_frp_app/screens/session_chat_screen.dart';
import 'package:dsh_frp_app/screens/settings_screen.dart';
import 'package:dsh_frp_app/services/dsh_remote.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const Host _host = Host(
  id: 'host-1',
  name: '测试网关',
  url: 'https://gw.example.com',
  pin: '1234',
);

/// 一条带着「思考 + 调用 read」的助手消息，用来验证那行小字怎么拼。
SessionHistory _historyWithNotes() => SessionHistory.fromJson(<String, Object?>{
  'cursor': 1,
  'hasMore': false,
  'records': <Object?>[
    <String, Object?>{
      'type': 'event',
      'event': <String, Object?>{
        'type': 'assistant/message',
        'seq': 1,
        'data': <String, Object?>{
          'message': <String, Object?>{
            'content': <Object?>[
              <String, Object?>{
                'type': 'reasoning',
                'text': '先读简报，再改代码',
              },
              <String, Object?>{
                'type': 'tool-call',
                'name': 'read',
                'arguments': '{"file_path": ".agi/BRIEF.md"}',
              },
              <String, Object?>{
                'type': 'text',
                'text': '看完了，没问题。',
              },
            ],
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
  }) async => _historyWithNotes();

  Future<void> close() => frames.close();
}

SessionSummary _session() => SessionSummary(
  sessionId: 'session-1',
  title: '会话',
  cwd: r'D:\Ai-Project\demo',
  updatedAt: DateTime.now(),
);

void main() {
  testWidgets('答完之后过程折成一行，点一下展开；切「简洁」只留统计', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final settings = SettingsStore();
    await settings.load();
    final hosts = HostStore();
    final remote = _FakeRemote();

    await tester.pumpWidget(
      AppScope(
        hosts: hosts,
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
    // 推一帧 snapshot 让页面进入正常态，再等历史落到列表里。
    remote.frames.add(const DshStreamFrame(kind: DshFrameKind.snapshot, asOfSeq: 1));
    await tester.pumpAndSettle();

    // 默认：详细模式 + 完成后收起，历史消息只剩一行摘要。
    expect(find.text('思考 · 1 次工具调用'), findsOneWidget);
    expect(find.text('思考 · 先读简报，再改代码'), findsNothing);
    expect(find.text('工具调用 · read · .agi/BRIEF.md'), findsNothing);

    // 点一下摘要，逐项展开（思考取第一行、工具带参数摘要）。
    await tester.tap(find.byKey(const ValueKey<String>('notes-fold')));
    await tester.pumpAndSettle();
    expect(find.text('思考 · 先读简报，再改代码'), findsOneWidget);
    expect(find.text('工具调用 · read · .agi/BRIEF.md'), findsOneWidget);

    // 切「简洁」：永远只留一行统计，没有箭头也没得展开。
    await settings.setChatNotesMode(ChatNotesMode.compact);
    await tester.pumpAndSettle();

    expect(find.text('思考 · 1 次工具调用'), findsOneWidget);
    expect(find.text('工具调用 · read · .agi/BRIEF.md'), findsNothing);
    expect(find.byKey(const ValueKey<String>('notes-fold')), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await remote.close();
  });

  testWidgets('关掉「完成后收起过程」，历史消息又逐项铺开', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final settings = SettingsStore();
    await settings.load();
    await settings.setFoldNotesWhenDone(false);
    final hosts = HostStore();
    final remote = _FakeRemote();

    await tester.pumpWidget(
      AppScope(
        hosts: hosts,
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
    remote.frames.add(const DshStreamFrame(kind: DshFrameKind.snapshot, asOfSeq: 1));
    await tester.pumpAndSettle();

    expect(find.text('思考 · 先读简报，再改代码'), findsOneWidget);
    expect(find.text('工具调用 · read · .agi/BRIEF.md'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('notes-fold')), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await remote.close();
  });

  testWidgets('设置页「会话」里有详细/简洁，点了立刻写进 store', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final settings = SettingsStore();
    await settings.load();
    final hosts = HostStore();

    await tester.pumpWidget(
      AppScope(
        hosts: hosts,
        settings: settings,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('工具调用显示'), findsOneWidget);
    expect(find.text('逐项列出，带工具参数摘要'), findsOneWidget);

    await tester.tap(find.text('简洁'));
    await tester.pumpAndSettle();

    expect(settings.chatNotesMode, ChatNotesMode.compact);
    expect(find.textContaining('次工具调用'), findsOneWidget);
  });

  testWidgets('设置页有「完成后收起过程」开关，点一下写进 store 并落盘', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final settings = SettingsStore();
    await settings.load();
    final hosts = HostStore();

    await tester.pumpWidget(
      AppScope(
        hosts: hosts,
        settings: settings,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(settings.foldNotesWhenDone, isTrue, reason: '默认跟网页端一样：答完就折');

    await tester.tap(find.text('完成后收起过程'));
    await tester.pumpAndSettle();

    expect(settings.foldNotesWhenDone, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('dsh_frp.chatNotesFold'), isFalse);
  });
}
