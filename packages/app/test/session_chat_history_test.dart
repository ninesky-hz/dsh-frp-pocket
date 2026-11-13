import 'dart:async';

import 'package:dsh_frp_app/models/host.dart';
import 'package:dsh_frp_app/models/host_event.dart';
import 'package:dsh_frp_app/models/session_event.dart';
import 'package:dsh_frp_app/models/session_summary.dart';
import 'package:dsh_frp_app/screens/session_chat_screen.dart';
import 'package:dsh_frp_app/services/dsh_api.dart';
import 'package:dsh_frp_app/services/dsh_remote.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const Host _host = Host(
  id: 'h1',
  name: '家里的机器',
  url: 'http://127.0.0.1:8080',
);

const SessionSummary _session = SessionSummary(
  sessionId: 'session-1',
  title: '会话一',
  cwd: r'D:\Ai-Project\dsh-frp-pocket',
);

/// 按调用顺序吐页：第 1 次是首屏，之后每次是 `beforeSeq` 翻上来的更早一页。
class _PagingRemote extends DshRemote {
  _PagingRemote({required List<SessionHistory> pages})
    : _pages = List<SessionHistory>.of(pages),
      super(host: _host);

  final List<SessionHistory> _pages;
  final StreamController<DshStreamFrame> frames =
      StreamController<DshStreamFrame>.broadcast();

  /// 每次 `page()` 收到的 `beforeSeq`（首屏那一次是 null）。
  final List<int?> beforeSeqs = <int?>[];
  final List<int> throughSeqs = <int>[];

  /// 置 true 后所有「翻更早」的请求都失败（首屏不受影响）。
  bool failOlder = false;

  /// 非空时翻页请求挂在这儿，用来验证并发保护。
  Completer<void>? gate;

  int _cursor = 0;

  int get pageCalls => beforeSeqs.length;

  @override
  Stream<DshStreamFrame> followSession(String sessionId, {int? maxMessages}) {
    return frames.stream;
  }

  @override
  Stream<DshHostEvent> followEvents() => const Stream<DshHostEvent>.empty();

  /// 分页用例与链路状态无关；钉在 online 保持既有断言语义（否则初始 offline
  /// 会禁用发送按钮 / 换掉输入框 hint）。
  @override
  DshLinkState get linkState => DshLinkState.online;

  @override
  Future<SessionHistory> page(
    String sessionId, {
    required int throughSeq,
    int? beforeSeq,
    int maxMessages = 20,
  }) async {
    beforeSeqs.add(beforeSeq);
    throughSeqs.add(throughSeq);
    if (beforeSeq != null && failOlder) {
      throw const DshApiException('boom', '服务端闹脾气了');
    }
    final pending = gate;
    if (pending != null) await pending.future;
    final index = _cursor;
    if (_cursor < _pages.length - 1) _cursor += 1;
    return _pages[index];
  }
}

String _textOf(int seq) => '第 $seq 条消息，先占够一行的长度好看清顺序';

SessionLogEvent _userEvent(int seq) {
  return SessionLogEvent(
    type: 'user/message',
    seq: seq,
    data: <String, Object?>{
      'message': <String, Object?>{
        'source': <String, Object?>{'kind': 'user'},
        'content': <Object?>[
          <String, Object?>{'type': 'text', 'text': _textOf(seq)},
        ],
      },
    },
  );
}

SessionHistory _page(List<int> seqs, {bool hasMore = true}) {
  return SessionHistory(
    cursor: seqs.isEmpty ? null : seqs.last,
    records: <SessionLogEvent>[for (final seq in seqs) _userEvent(seq)],
    hasMore: hasMore,
  );
}

Future<void> _pumpChat(WidgetTester tester, _PagingRemote remote) async {
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
  await tester.pump();
  remote.frames.add(
    DshStreamFrame(kind: DshFrameKind.snapshot, asOfSeq: 3422),
  );
  await tester.pump();
  await tester.pump();
  // 首屏加载完会自动滚到底（180ms 的动画），等它结束再动手。
  await tester.pump(const Duration(milliseconds: 260));
}

ScrollPosition _position(WidgetTester tester) {
  // `.first`：气泡正文是 `SelectableText`，它内部也带一个 `Scrollable`
  // （`EditableText` 自己的滚动容器），深度优先里外层 `CustomScrollView`
  // 的 `Scrollable` 排在前面。
  return tester
      .state<ScrollableState>(
        find
            .descendant(
              of: find.byKey(const Key('chat-list')),
              matching: find.byType(Scrollable),
            )
            .first,
      )
      .position;
}

/// 往上翻到顶（中心结构里历史段挂在负方向，minScrollExtent 才是视觉上的最上方）。
Future<void> _scrollToTop(WidgetTester tester) async {
  final position = _position(tester);
  position.jumpTo(position.minScrollExtent);
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

Future<void> _disposeChat(WidgetTester tester, _PagingRemote remote) async {
  await tester.pumpWidget(const SizedBox());
  await remote.frames.close();
}

void main() {
  testWidgets('上滑翻页：更早一页按 seq 合到头部，重复 seq 只留一条', (tester) async {
    final remote = _PagingRemote(
      pages: <SessionHistory>[
        _page(<int>[for (var seq = 100; seq <= 119; seq += 1) seq]),
        // 故意把 100 号重复塞进来：服务端分页边界重叠是常态。
        // 更早的一页很短，而且故意把 100 号重复塞进来：服务端分页边界重叠是常态。
        _page(<int>[80, 81, 82, 100], hasMore: false),
      ],
    );
    await _pumpChat(tester, remote);

    expect(remote.pageCalls, 1, reason: '首屏只拉一页');
    expect(remote.beforeSeqs.single, isNull);
    expect(remote.throughSeqs.single, 3422, reason: '首屏用快照的 asOfSeq');
    expect(find.text(_textOf(119)), findsOneWidget);

    await _scrollToTop(tester);

    expect(remote.pageCalls, 2, reason: '翻到顶触发第二页');
    expect(
      remote.beforeSeqs[1],
      100,
      reason: 'beforeSeq 必须是列表里最老那条的 seq',
    );

    // 合并后新的一页排在列表头部，翻到顶就能看到（reverse: true 里 dy 越小越靠上）。
    await _scrollToTop(tester);
    final first = tester.getTopLeft(find.text(_textOf(80))).dy;
    final second = tester.getTopLeft(find.text(_textOf(81))).dy;
    final third = tester.getTopLeft(find.text(_textOf(82))).dy;
    final newest = tester.getTopLeft(find.text(_textOf(100))).dy;
    expect(first, lessThan(second), reason: '80 该排在最上面');
    expect(second, lessThan(third));
    expect(third, lessThan(newest), reason: '100 在更早的一页之后');

    // 重复的 100 号没有变成两条：同文案只该出现一次。
    expect(
      find.text(_textOf(100)),
      findsOneWidget,
      reason: '两页重叠的 seq 必须被去重',
    );

    // hasMore == false 之后一次请求都不发，顶部也不再有 loading。
    expect(remote.pageCalls, 2);
    expect(find.byKey(const Key('chat-older-loading')), findsNothing);
    expect(find.byKey(const Key('chat-older-retry')), findsNothing);

    await _disposeChat(tester, remote);
  });

  testWidgets('翻页失败：保留原列表，顶部给一行可点的重试', (tester) async {
    final remote = _PagingRemote(
      pages: <SessionHistory>[
        _page(<int>[for (var seq = 100; seq <= 119; seq += 1) seq]),
        _page(<int>[for (var seq = 80; seq <= 99; seq += 1) seq], hasMore: false),
      ],
    );
    await _pumpChat(tester, remote);
    expect(find.text(_textOf(119)), findsOneWidget);

    remote.failOlder = true;
    await _scrollToTop(tester);

    expect(find.byKey(const Key('chat-older-retry')), findsOneWidget);
    expect(find.text('加载更早的消息失败，点这里重试'), findsOneWidget);
    // 原列表一条都没动：翻到顶时最上面那条还是首屏里最老的 100 号。
    expect(find.text(_textOf(100)), findsOneWidget);
    expect(remote.pageCalls, 2);

    // 点重试：这次成功了，更早的消息进来，错误行消失。
    remote.failOlder = false;
    final retry = tester.widget<TextButton>(
      find.byKey(const Key('chat-older-retry')),
    );
    retry.onPressed!();
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byKey(const Key('chat-older-retry')), findsNothing);
    expect(remote.pageCalls, 3);
    await _scrollToTop(tester);
    expect(find.text(_textOf(80)), findsOneWidget);

    await _disposeChat(tester, remote);
  });

  testWidgets('翻页进行中重复触顶不会重复请求', (tester) async {
    final remote = _PagingRemote(
      pages: <SessionHistory>[
        _page(<int>[for (var seq = 100; seq <= 119; seq += 1) seq]),
        _page(<int>[for (var seq = 80; seq <= 99; seq += 1) seq], hasMore: false),
      ],
    );
    await _pumpChat(tester, remote);
    expect(remote.pageCalls, 1);

    remote.gate = Completer<void>();
    final position = _position(tester);
    position.jumpTo(position.minScrollExtent);
    await tester.pump();
    // 第一次还在飞的时候再抖两下顶。
    position.jumpTo(position.minScrollExtent + 420);
    await tester.pump();
    position.jumpTo(position.minScrollExtent);
    await tester.pump();
    await tester.pump();

    expect(remote.pageCalls, 2, reason: '加载中不该再发一次');

    remote.gate!.complete();
    remote.gate = null;
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // 只有一页在飞，落地后更早的消息进来；再抖顶也不会多要一页（hasMore 由这页决定）。
    await _scrollToTop(tester);
    expect(find.text(_textOf(80)), findsOneWidget);
    expect(remote.pageCalls, 2);

    await _disposeChat(tester, remote);
  });

  // ---------------------------------------------------------------- 中心结构

  /// 视口里第一行「完整可见」的消息（中心结构下不一定是 seq 最小的那条）。
  String visibleText(WidgetTester tester, int from, int to) {
    final viewport = tester.getRect(find.byKey(const Key('chat-list')));
    for (var seq = from; seq <= to; seq += 1) {
      final finder = find.text(_textOf(seq));
      if (finder.evaluate().isEmpty) continue;
      final rect = tester.getRect(finder);
      if (rect.top >= viewport.top && rect.bottom <= viewport.bottom) {
        return _textOf(seq);
      }
    }
    fail('视口里没有一行完整可见的消息');
  }

  testWidgets('消息列表用 center + 双 sliver，不再是 reverse ListView', (tester) async {
    final remote = _PagingRemote(
      pages: <SessionHistory>[
        _page(<int>[100, 101, 102], hasMore: false),
      ],
    );
    await _pumpChat(tester, remote);

    final list = tester.widget<CustomScrollView>(
      find.byKey(const Key('chat-list')),
    );
    expect(list.center, isNotNull, reason: 'center 键是历史段挂负方向的前提');
    expect(list.anchor, 1.0, reason: '零偏移放在视口底边，最新一条才贴底');
    expect(
      list.slivers.whereType<SliverList>().length,
      2,
      reason: '历史段 + 当前段两条 sliver',
    );
    expect(
      tester
          .widgetList<ListView>(find.byType(ListView))
          .where((ListView view) => view.reverse),
      isEmpty,
      reason: '不允许再有 reverse 列表承载消息',
    );

    await _disposeChat(tester, remote);
  });

  testWidgets('加载更早历史后视口不跳', (tester) async {
    final remote = _PagingRemote(
      pages: <SessionHistory>[
        _page(<int>[for (var seq = 100; seq <= 119; seq += 1) seq]),
        _page(<int>[for (var seq = 80; seq <= 99; seq += 1) seq], hasMore: false),
      ],
    );
    await _pumpChat(tester, remote);
    expect(remote.pageCalls, 1);

    final position = _position(tester);
    // 挂住翻页请求，好在「插入之前」量一次。
    remote.gate = Completer<void>();
    position.jumpTo(position.minScrollExtent + 120);
    await tester.pump();
    await tester.pump();

    final watched = visibleText(tester, 100, 119);
    final beforeTop = tester.getRect(find.text(watched)).top;
    final beforePixels = position.pixels;
    final beforeMin = position.minScrollExtent;

    remote.gate!.complete();
    remote.gate = null;
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(remote.pageCalls, 2, reason: '翻到顶附近应该再要一页');
    expect(
      position.minScrollExtent,
      lessThan(beforeMin - 100),
      reason: '更早的一页确实插进了历史段',
    );
    expect(
      position.pixels,
      closeTo(beforePixels, 0.51),
      reason: '插入历史不该改滚动像素',
    );
    expect(
      tester.getRect(find.text(watched)).top,
      closeTo(beforeTop, 0.51),
      reason: '正在读的那一行不该动',
    );

    await _disposeChat(tester, remote);
  });

  testWidgets('贴底时新消息自动贴底', (tester) async {
    final remote = _PagingRemote(
      pages: <SessionHistory>[
        _page(<int>[for (var seq = 100; seq <= 109; seq += 1) seq], hasMore: false),
      ],
    );
    await _pumpChat(tester, remote);

    final position = _position(tester);
    final viewport = tester.getRect(find.byKey(const Key('chat-list')));
    expect(position.extentAfter, lessThanOrEqualTo(32), reason: '首屏应该已经贴底');

    remote.frames.add(
      DshStreamFrame(kind: DshFrameKind.event, event: _userEvent(110)),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));
    await tester.pump();

    expect(find.text(_textOf(110)), findsOneWidget);
    expect(
      position.extentAfter,
      lessThanOrEqualTo(32),
      reason: '停在底部时新消息应该把视口一起带下去',
    );
    expect(
      tester.getRect(find.text(_textOf(110))).bottom,
      closeTo(viewport.bottom, 40),
      reason: '最新一条贴着视口底边',
    );

    await _disposeChat(tester, remote);
  });
}
