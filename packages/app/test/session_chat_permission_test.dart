import 'dart:async';

import 'package:dsh_frp_app/models/host.dart';
import 'package:dsh_frp_app/models/host_event.dart';
import 'package:dsh_frp_app/models/permission_option.dart';
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
  id: 'host-perm',
  name: '测试网关',
  url: 'https://gw.example.com',
  pin: '1234',
);

SessionSummary _session({String? permission}) => SessionSummary(
  sessionId: 'session-perm',
  title: '权限会话',
  cwd: r'D:\Ai-Project\dsh-frp-pocket',
  permission: permission,
);

/// 目录固定三档（和本机宿主一致：`name` 就是机器名）。
const PermissionCatalog _catalog = PermissionCatalog(
  options: <PermissionOption>[
    PermissionOption(value: 'read-only', name: 'read-only'),
    PermissionOption(value: 'workspace-write', name: 'workspace-write'),
    PermissionOption(value: 'danger-full-access', name: 'danger-full-access'),
  ],
  defaultPreset: 'danger-full-access',
);

class _PermRemote extends DshRemote {
  _PermRemote({this.failSwitch = false, this.listedPermission})
    : super(host: _host);

  final bool failSwitch;

  /// 列表侧（`session/list` 的投影）里这个会话的权限值：新建会话那一刻手上
  /// 那行没有它，补拉时才拿得到。可变，用来模拟「会话晚一拍才进列表」。
  String? listedPermission;
  final List<String> switches = <String>[];
  int catalogCalls = 0;
  int permissionCalls = 0;

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
  }) async =>
      const SessionHistory(
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
  Future<PermissionCatalog> permissionCatalog() async {
    catalogCalls++;
    return _catalog;
  }

  @override
  Future<String?> permissionOf(String sessionId) async {
    permissionCalls++;
    return listedPermission;
  }

  @override
  Future<String> setPermission(String sessionId, String value) async {
    switches.add(value);
    if (failSwitch) {
      throw const DshApiException('permission_failed', '宿主拒绝了这次权限切换');
    }
    return 'preset $value';
  }

  Future<void> close() async {
    await states.close();
    await frames.close();
    await hostEvents.close();
  }
}

Future<_PermRemote> _pumpChat(
  WidgetTester tester, {
  String? permission,
  String? listedPermission,
  bool failSwitch = false,
}) async {
  final remote = _PermRemote(
    failSwitch: failSwitch,
    listedPermission: listedPermission,
  );
  await tester.pumpWidget(
    MaterialApp(
      home: SessionChatScreen(
        host: _host,
        session: _session(permission: permission),
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

Future<void> _disposeChat(WidgetTester tester, _PermRemote remote) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
  await remote.close();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('会话没有权限投影：整个入口都不出现，也不发目录请求', (tester) async {
    final remote = await _pumpChat(tester);
    expect(find.byKey(const ValueKey<String>('permission-chip')), findsNothing);
    expect(remote.catalogCalls, 0);
    // 进页补一次、快照到齐再补一次（后者容忍进页那次链路还没通）；问不到就保持隐藏。
    expect(remote.permissionCalls, greaterThanOrEqualTo(1));
    await _disposeChat(tester, remote);
  });

  testWidgets('新建会话手上那行没投影：进页后补拉一次，入口自己出现', (tester) async {
    final remote = await _pumpChat(
      tester,
      listedPermission: 'workspace-write',
    );
    await tester.pumpAndSettle();

    expect(remote.permissionCalls, 1);
    expect(find.byKey(const ValueKey<String>('permission-chip')), findsOneWidget);
    expect(find.text('工作区内修改'), findsOneWidget);
    // 只是点亮入口，不动宿主的权限：目录仍然等到用户点开才拉。
    expect(remote.catalogCalls, 0);
    expect(remote.switches, isEmpty);
    await _disposeChat(tester, remote);
  });

  testWidgets('新建会话晚一拍才进列表：重试一次后入口自己出现', (tester) async {
    final remote = await _pumpChat(tester);
    expect(find.byKey(const ValueKey<String>('permission-chip')), findsNothing);
    final attempts = remote.permissionCalls;

    // 宿主这时才把会话索引好。
    remote.listedPermission = 'read-only';
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();

    expect(remote.permissionCalls, greaterThan(attempts));
    expect(find.byKey(const ValueKey<String>('permission-chip')), findsOneWidget);
    expect(find.text('仅可查看'), findsOneWidget);
    await _disposeChat(tester, remote);
  });

  testWidgets('有投影时显示中文标签', (tester) async {
    final remote = await _pumpChat(tester, permission: 'danger-full-access');
    expect(find.byKey(const ValueKey<String>('permission-chip')), findsOneWidget);
    expect(find.text('完全权限'), findsOneWidget);
    // 进入会话本身不该为权限多打一次 RPC。
    expect(remote.catalogCalls, 0);
    expect(remote.permissionCalls, 0);
    await _disposeChat(tester, remote);
  });

  testWidgets('点开弹窗选另一档：写回一次并把标签换掉', (tester) async {
    final remote = await _pumpChat(tester, permission: 'danger-full-access');

    await tester.tap(find.byKey(const ValueKey<String>('permission-chip')));
    await tester.pumpAndSettle();
    expect(remote.catalogCalls, 1);
    // 三档都在，当前那档在列表里可见。
    expect(
      find.byKey(const ValueKey<String>('permission.workspace-write')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('permission.workspace-write')),
    );
    await tester.pumpAndSettle();

    expect(remote.switches, <String>['workspace-write']);
    expect(find.text('工作区内修改'), findsOneWidget);
    expect(find.text('完全权限'), findsNothing);
    await _disposeChat(tester, remote);
  });

  testWidgets('写回失败：胶囊退回原值并提示', (tester) async {
    final remote = await _pumpChat(
      tester,
      permission: 'read-only',
      failSwitch: true,
    );

    await tester.tap(find.byKey(const ValueKey<String>('permission-chip')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('permission.danger-full-access')),
    );
    await tester.pumpAndSettle();

    expect(remote.switches, <String>['danger-full-access']);
    expect(find.text('仅可查看'), findsOneWidget);
    expect(find.textContaining('宿主拒绝了这次权限切换'), findsOneWidget);
    await _disposeChat(tester, remote);
  });
}
