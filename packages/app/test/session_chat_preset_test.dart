import 'dart:async';

import 'package:dsh_frp_app/models/agent_preset_option.dart';
import 'package:dsh_frp_app/models/host.dart';
import 'package:dsh_frp_app/models/host_event.dart';
import 'package:dsh_frp_app/models/prompt_image.dart';
import 'package:dsh_frp_app/models/session_event.dart';
import 'package:dsh_frp_app/models/session_summary.dart';
import 'package:dsh_frp_app/screens/session_chat_screen.dart';
import 'package:dsh_frp_app/services/dsh_api.dart';
import 'package:dsh_frp_app/services/dsh_remote.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const Host _host = Host(
  id: 'host-preset',
  name: '测试网关',
  url: 'https://gw.example.com',
  pin: '1234',
);

SessionSummary _session({String? agentPreset}) => SessionSummary(
  sessionId: 'session-preset',
  title: '人格会话',
  cwd: r'D:\Ai-Project\dsh-frp-pocket',
  agentPreset: agentPreset,
);

/// 和本机宿主一致：三套预设，`redteam` 现在组合不起来。
const AgentPresetCatalog _catalog = AgentPresetCatalog(
  presets: <AgentPresetOption>[
    AgentPresetOption(
      id: 'main-agent',
      isDefault: true,
      name: '主智能体',
      description: '常驻监督者：锁定目标后派生开发子代理',
    ),
    AgentPresetOption(
      id: 'unrestricted',
      isDefault: false,
      name: '无限制模式',
      description: '操作者意图优先的骨架',
      order: 20,
    ),
    AgentPresetOption(
      id: 'redteam',
      isDefault: false,
      name: '红队模式',
      description: '攻防演练模式',
      order: 10,
      broken: '入口脚本缺失',
    ),
  ],
);

class _PresetRemote extends DshRemote {
  _PresetRemote({this.failSwitch = false, this.listedPreset})
    : super(host: _host);

  final bool failSwitch;

  /// 列表侧（`session/list` 的投影）里这个会话的人格值：新建会话那一刻手上
  /// 那行没有它，补拉时才拿得到。可变，用来模拟「会话晚一拍才进列表」。
  String? listedPreset;
  final List<String> selects = <String>[];
  int catalogCalls = 0;
  int presetCalls = 0;

  final StreamController<DshStreamFrame> frames =
      StreamController<DshStreamFrame>.broadcast();
  final StreamController<DshHostEvent> hostEvents =
      StreamController<DshHostEvent>.broadcast();
  final StreamController<DshLinkState> states =
      StreamController<DshLinkState>.broadcast();

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
  Future<String> prompt(
    String sessionId,
    String text, {
    String? requestId,
    List<PromptImage> images = const <PromptImage>[],
  }) async => requestId ?? 'req-1';

  @override
  Future<void> cancel(String sessionId) async {}

  @override
  Future<List<SessionSummary>> childSessions(String parentSessionId) async =>
      const <SessionSummary>[];

  @override
  Future<AgentPresetCatalog> agentPresetCatalog() async {
    catalogCalls++;
    return _catalog;
  }

  @override
  Future<String?> agentPresetOf(String sessionId) async {
    presetCalls++;
    return listedPreset;
  }

  @override
  Future<String> selectAgentPreset(String sessionId, String preset) async {
    selects.add(preset);
    if (failSwitch) {
      throw const DshApiException(
        'agent-preset/locked',
        'This session has already started',
      );
    }
    return preset;
  }

  Future<void> close() async {
    await states.close();
    await frames.close();
    await hostEvents.close();
  }
}

Future<_PresetRemote> _pumpChat(
  WidgetTester tester, {
  String? agentPreset,
  String? listedPreset,
  bool failSwitch = false,
}) async {
  final remote = _PresetRemote(
    failSwitch: failSwitch,
    listedPreset: listedPreset,
  );
  await tester.pumpWidget(
    MaterialApp(
      home: SessionChatScreen(
        host: _host,
        session: _session(agentPreset: agentPreset),
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

/// 人格入口在「更多」菜单里：先点开菜单，再点那一行。
Future<void> _openMenu(WidgetTester tester) async {
  await tester.tap(find.byTooltip('更多'));
  await tester.pumpAndSettle();
}

Future<void> _openPresetSheet(WidgetTester tester) async {
  await _openMenu(tester);
  await tester.tap(find.byKey(const ValueKey<String>('preset-entry')));
  await tester.pumpAndSettle();
}

Future<void> _disposeChat(WidgetTester tester, _PresetRemote remote) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
  await remote.close();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('会话没有人格投影：菜单里整个入口都不出现，也不发目录请求', (tester) async {
    final remote = await _pumpChat(tester);
    await _openMenu(tester);
    expect(find.byKey(const ValueKey<String>('preset-entry')), findsNothing);
    expect(find.text('人格预设'), findsNothing);
    expect(remote.catalogCalls, 0);
    // 进页补一次；问不到就保持隐藏（宿主没有预设服务）。
    expect(remote.presetCalls, greaterThanOrEqualTo(1));
    await _disposeChat(tester, remote);
  });

  testWidgets('新建会话手上那行没投影：进页后补拉一次，入口自己出现', (tester) async {
    final remote = await _pumpChat(tester, listedPreset: 'unrestricted');
    await tester.pumpAndSettle();

    expect(remote.presetCalls, 1);
    await _openMenu(tester);
    expect(find.byKey(const ValueKey<String>('preset-entry')), findsOneWidget);
    expect(find.textContaining('无限制模式'), findsOneWidget);
    // 只是点亮入口，不动宿主的人格：目录仍然等到用户点开才拉。
    expect(remote.catalogCalls, 0);
    expect(remote.selects, isEmpty);
    await _disposeChat(tester, remote);
  });

  testWidgets('新建会话晚一拍才进列表：重试一次后入口自己出现', (tester) async {
    final remote = await _pumpChat(tester);
    final attempts = remote.presetCalls;

    // 宿主这时才把会话索引好。
    remote.listedPreset = 'main-agent';
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();

    expect(remote.presetCalls, greaterThan(attempts));
    await _openMenu(tester);
    expect(find.byKey(const ValueKey<String>('preset-entry')), findsOneWidget);
    expect(find.textContaining('主智能体'), findsOneWidget);
    await _disposeChat(tester, remote);
  });

  testWidgets('点开弹窗：拉一次目录，列全部预设，当前那档打勾', (tester) async {
    final remote = await _pumpChat(tester, agentPreset: 'main-agent');
    await _openPresetSheet(tester);

    expect(remote.catalogCalls, 1);
    expect(
      find.byKey(const ValueKey<String>('preset.main-agent')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('preset.unrestricted')),
      findsOneWidget,
    );
    // 坏掉的那套也列出来，但点不动。
    final broken = find.byKey(const ValueKey<String>('preset.redteam'));
    expect(broken, findsOneWidget);
    expect(tester.widget<ListTile>(broken).enabled, isFalse);
    await _disposeChat(tester, remote);
  });

  testWidgets('选另一套：写回一次，菜单里的副标题换成新名字', (tester) async {
    final remote = await _pumpChat(tester, agentPreset: 'main-agent');
    await _openPresetSheet(tester);

    await tester.tap(find.byKey(const ValueKey<String>('preset.unrestricted')));
    await tester.pumpAndSettle();

    expect(remote.selects, <String>['unrestricted']);
    await _openMenu(tester);
    expect(find.text('无限制模式 · 操作者意图优先的骨架'), findsOneWidget);
    expect(find.textContaining('主智能体'), findsNothing);
    await _disposeChat(tester, remote);
  });

  testWidgets('写回失败：副标题退回原值并提示宿主给的原因', (tester) async {
    final remote = await _pumpChat(
      tester,
      agentPreset: 'main-agent',
      failSwitch: true,
    );
    await _openPresetSheet(tester);

    await tester.tap(find.byKey(const ValueKey<String>('preset.unrestricted')));
    await tester.pumpAndSettle();

    expect(remote.selects, <String>['unrestricted']);
    expect(
      find.textContaining('This session has already started'),
      findsOneWidget,
    );
    await _openMenu(tester);
    expect(find.textContaining('主智能体'), findsOneWidget);
    await _disposeChat(tester, remote);
  });
}
