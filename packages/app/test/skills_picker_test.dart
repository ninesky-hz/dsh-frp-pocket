import 'dart:async';
import 'dart:typed_data';

import 'package:dsh_frp_app/models/dsh_skill.dart';
import 'package:dsh_frp_app/models/host.dart';
import 'package:dsh_frp_app/models/host_event.dart';
import 'package:dsh_frp_app/models/prompt_image.dart';
import 'package:dsh_frp_app/models/session_event.dart';
import 'package:dsh_frp_app/models/session_summary.dart';
import 'package:dsh_frp_app/screens/session_chat_screen.dart';
import 'package:dsh_frp_app/services/dsh_remote.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const Host _host = Host(
  id: 'host-skill',
  name: '测试网关',
  url: 'https://gw.example.com',
  pin: '1234',
);

const SessionSummary _session = SessionSummary(
  sessionId: 'session-skill',
  title: '技能会话',
  cwd: r'D:\Ai-Project\dsh-frp-pocket',
);

/// 只关心「技能表怎么拉、补全怎么回填」的假件。
class _SkillRemote extends DshRemote {
  _SkillRemote() : super(host: _host);

  final StreamController<DshStreamFrame> frames =
      StreamController<DshStreamFrame>.broadcast();
  final StreamController<DshHostEvent> hostEvents =
      StreamController<DshHostEvent>.broadcast();
  final StreamController<DshLinkState> states =
      StreamController<DshLinkState>.broadcast();

  int listCalls = 0;
  final List<String> prompts = <String>[];

  @override
  DshLinkState get linkState => DshLinkState.online;

  @override
  Stream<DshLinkState> get linkStates => states.stream;

  @override
  void reconnectNow() {}

  @override
  Stream<DshStreamFrame> followSession(String sessionId, {int? maxMessages}) =>
      frames.stream;

  @override
  Stream<DshHostEvent> followEvents() => hostEvents.stream;

  @override
  Future<SessionHistory> page(
    String sessionId, {
    required int throughSeq,
    int? beforeSeq,
    int maxMessages = 20,
  }) async => const SessionHistory(
    cursor: 1,
    records: <SessionLogEvent>[],
    hasMore: false,
  );

  @override
  Future<List<DshSkill>> listSkills(String sessionId) async {
    listCalls += 1;
    return const <DshSkill>[
      DshSkill(name: 'unslop', description: '把随手糊的界面收拾成设计过的'),
      DshSkill(name: 'apk-reverse', description: 'APK 解包与 smali 修改'),
      DshSkill(name: 'browser-automation', whenToUse: '需要跑浏览器自动化时'),
    ];
  }

  @override
  Future<String> prompt(
    String sessionId,
    String text, {
    String? requestId,
    List<PromptImage> images = const <PromptImage>[],
  }) async {
    prompts.add(text);
    return requestId ?? 'req-${prompts.length}';
  }

  @override
  Future<void> cancel(String sessionId) async {}

  @override
  Future<Uint8List> cachedAttachment(
    String sessionId, {
    required String attachmentId,
    String? mediaType,
    int? bytes,
    int? width,
    int? height,
    String? name,
  }) async => Uint8List(0);

  Future<void> close() async {
    await states.close();
    await frames.close();
    await hostEvents.close();
  }
}

Future<_SkillRemote> _pumpChat(WidgetTester tester) async {
  final remote = _SkillRemote();
  await tester.pumpWidget(
    MaterialApp(
      home: SessionChatScreen(
        host: _host,
        session: _session,
        remote: remote,
        snapshotTimeout: Duration.zero,
      ),
    ),
  );
  remote.frames.add(
    const DshStreamFrame(kind: DshFrameKind.snapshot, asOfSeq: 1),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
  return remote;
}

Future<void> _disposeChat(WidgetTester tester, _SkillRemote remote) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
  await remote.close();
}

void main() {
  group('DshSkill 解析', () {
    test('按名字排序，坏条目跳过', () {
      final List<DshSkill> skills = DshSkill.parseList(<Object?>[
        <String, Object?>{'name': 'zeta'},
        <String, Object?>{'name': ''},
        <String, Object?>{'name': 'alpha'},
        'not-a-map',
      ]);
      expect(skills.map((DshSkill s) => s.name).toList(), <String>[
        'alpha',
        'zeta',
      ]);
    });

    test('summary 优先用 whenToUse，超长截断', () {
      const DshSkill a = DshSkill(name: 'a', description: 'long description');
      const DshSkill b = DshSkill(name: 'b', whenToUse: 'when needed');
      expect(a.summary, 'long description');
      expect(b.summary, 'when needed');
      final String long = 'x' * 200;
      expect(DshSkill(name: 'c', description: long).summary.length, 80);
    });

    test('matches 是包含匹配，startsWith 只认前缀', () {
      const DshSkill s = DshSkill(name: 'apk-reverse');
      expect(s.matches('apk'), isTrue);
      expect(s.matches('reverse'), isTrue);
      expect(s.matches('nope'), isFalse);
      expect(s.startsWith('apk'), isTrue);
      expect(s.startsWith('reverse'), isFalse);
      expect(s.matches(''), isTrue);
    });
  });

  testWidgets('打出 / 才拉技能表，且只拉一次', (tester) async {
    final remote = await _pumpChat(tester);
    expect(remote.listCalls, 0, reason: '没打 / 之前不该多发一个请求');

    await tester.enterText(find.byKey(const Key('chat-input')), '/');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(remote.listCalls, 1);

    await tester.enterText(find.byKey(const Key('chat-input')), '/a');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(remote.listCalls, 1, reason: '表只拉一次');

    await _disposeChat(tester, remote);
  });

  testWidgets('/un 只留命中的技能，点一下回填 /unslop 加空格', (tester) async {
    final remote = await _pumpChat(tester);

    await tester.enterText(find.byKey(const Key('chat-input')), '/un');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    expect(find.byKey(const Key('skill-panel')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('skill.unslop')), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('skill.apk-reverse')),
      findsNothing,
    );

    await tester.tap(find.byKey(const ValueKey<String>('skill.unslop')));
    await tester.pump();

    final TextField field = tester.widget<TextField>(
      find.byKey(const Key('chat-input')),
    );
    expect(field.controller?.text, '/unslop ');
    // 回填后已经带空格 → 不再是「正在打名字」，面板收起。
    expect(find.byKey(const Key('skill-panel')), findsNothing);

    await _disposeChat(tester, remote);
  });

  testWidgets('带空格后不再补全，消息原样带 /名字 发出去', (tester) async {
    final remote = await _pumpChat(tester);

    await tester.enterText(
      find.byKey(const Key('chat-input')),
      '/unslop 把它收拾一下',
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(
      find.byKey(const Key('skill-panel')),
      findsNothing,
      reason: '有空格 = 在写参数，不该再弹补全',
    );

    await tester.tap(find.byKey(const Key('chat-send')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    expect(remote.prompts, <String>['/unslop 把它收拾一下']);
    await _disposeChat(tester, remote);
  });
}
