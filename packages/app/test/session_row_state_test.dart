import 'package:dsh_frp_app/models/session_row_state.dart';
import 'package:dsh_frp_app/models/session_summary.dart';
import 'package:flutter_test/flutter_test.dart';

/// 固定的 `updatedAt`：所有断言都用绝对毫秒，不依赖跑测试的时刻。
final DateTime _updated = DateTime.fromMillisecondsSinceEpoch(1700000000000);
const int _updatedMs = 1700000000000;

SessionSummary _session({bool running = false, DateTime? updatedAt}) {
  return SessionSummary(
    sessionId: 'session-1',
    title: '会话',
    cwd: '/srv/app',
    running: running,
    updatedAt: updatedAt,
  );
}

void main() {
  test('枚举顺序就是优先级：pending > running > unread > none', () {
    expect(SessionRowState.values, <SessionRowState>[
      SessionRowState.pending,
      SessionRowState.running,
      SessionRowState.unread,
      SessionRowState.none,
    ]);
  });

  test('pending 压 running 和 unread', () {
    expect(
      sessionRowStateOf(
        session: _session(running: true, updatedAt: _updated),
        seenAt: null,
        hasPending: true,
      ),
      SessionRowState.pending,
    );
    expect(
      sessionRowStateOf(
        session: _session(updatedAt: _updated),
        seenAt: _updatedMs - 1,
        hasPending: true,
      ),
      SessionRowState.pending,
    );
  });

  test('running 压 unread：运行中的会话即使从未看过也不是未读', () {
    expect(
      sessionRowStateOf(
        session: _session(running: true, updatedAt: _updated),
        seenAt: null,
        hasPending: false,
      ),
      SessionRowState.running,
    );
    expect(
      sessionRowStateOf(
        session: _session(running: true, updatedAt: _updated),
        seenAt: 0,
        hasPending: false,
      ),
      SessionRowState.running,
    );
  });

  test('从未看过（seenAt == null）也算未读：新会话第一次出现要有提示', () {
    expect(
      sessionRowStateOf(
        session: _session(updatedAt: _updated),
        seenAt: null,
        hasPending: false,
      ),
      SessionRowState.unread,
    );
  });

  test('看过但水位早于 updatedAt → unread', () {
    expect(
      sessionRowStateOf(
        session: _session(updatedAt: _updated),
        seenAt: _updatedMs - 1,
        hasPending: false,
      ),
      SessionRowState.unread,
    );
  });

  test('seenAt == updatedAt → none（看过就是看过，不重复提醒）', () {
    expect(
      sessionRowStateOf(
        session: _session(updatedAt: _updated),
        seenAt: _updatedMs,
        hasPending: false,
      ),
      SessionRowState.none,
    );
  });

  test('seenAt 晚于 updatedAt → none', () {
    expect(
      sessionRowStateOf(
        session: _session(updatedAt: _updated),
        seenAt: _updatedMs + 5000,
        hasPending: false,
      ),
      SessionRowState.none,
    );
  });

  test('没有 updatedAt 的占位行 → none，不冒未读点', () {
    expect(
      sessionRowStateOf(
        session: _session(),
        seenAt: null,
        hasPending: false,
      ),
      SessionRowState.none,
    );
  });

  test('updatedAt 前进（停留聊天页期间有新消息）后重新变未读', () {
    final later = DateTime.fromMillisecondsSinceEpoch(_updatedMs + 60000);
    expect(
      sessionRowStateOf(
        session: _session(updatedAt: _updated),
        seenAt: _updatedMs,
        hasPending: false,
      ),
      SessionRowState.none,
    );
    expect(
      sessionRowStateOf(
        session: _session(updatedAt: later),
        seenAt: _updatedMs,
        hasPending: false,
      ),
      SessionRowState.unread,
    );
  });
}
