import 'package:dsh_frp_app/models/session_search.dart';
import 'package:dsh_frp_app/models/session_summary.dart';
import 'package:flutter_test/flutter_test.dart';

SessionSummary _session(String sessionId, {String title = '', String cwd = ''}) {
  return SessionSummary(sessionId: sessionId, title: title, cwd: cwd);
}

/// 三条固定样本：标题与 cwd 都能各自唯一命中，方便断言「只命中一个不算」。
List<SessionSummary> _samples() {
  return <SessionSummary>[
    _session('s1', title: 'Alpha 重构', cwd: r'D:\repo\pocket'),
    _session('s2', title: 'Beta 联调', cwd: r'D:\repo\gateway'),
    _session('s3', title: 'Gamma 发布', cwd: r'D:\repo\alpha-docs'),
  ];
}

List<String> _ids(List<SessionSummary> sessions) {
  return sessions.map((session) => session.sessionId).toList();
}

void main() {
  group('tokenizeQuery', () {
    test('按半角空白与全角空格切分、去空、转小写', () {
      expect(
        tokenizeQuery('  Alpha\u3000Beta   gamma\t'),
        <String>['alpha', 'beta', 'gamma'],
      );
    });

    test('空查询与纯空白查询都返回空表', () {
      expect(tokenizeQuery(''), isEmpty);
      expect(tokenizeQuery('   \t\n'), isEmpty);
      expect(tokenizeQuery('\u3000\u3000'), isEmpty);
    });

    test('连续分隔符不会产出空 token', () {
      expect(tokenizeQuery('a\u3000 \u3000b'), <String>['a', 'b']);
    });
  });

  group('sessionMatches', () {
    test('单 token 命中标题', () {
      expect(sessionMatches(_samples()[1], tokenizeQuery('beta')), isTrue);
    });

    test('单 token 命中 cwd', () {
      // 标题里没有 gateway，只有工作目录里有。
      expect(sessionMatches(_samples()[1], tokenizeQuery('gateway')), isTrue);
    });

    test('大小写不敏感', () {
      final session = _session('s9', title: 'DSH-FRP Pocket', cwd: r'D:\Ai-Project');
      expect(sessionMatches(session, tokenizeQuery('dsh-frp')), isTrue);
      expect(sessionMatches(session, tokenizeQuery('AI-PROJECT')), isTrue);
      // 直接传大写 token 也成立：sessionMatches 自己会折一次大小写。
      expect(sessionMatches(session, <String>['POCKET']), isTrue);
    });

    test('多 token 必须全部命中（AND）', () {
      final session = _session('s9', title: 'Alpha 重构', cwd: r'D:\repo\pocket');
      // 两个词各命中一个字段。
      expect(sessionMatches(session, tokenizeQuery('alpha pocket')), isTrue);
      // 第一个命中标题、第二个只命中别的会话 → 不算。
      expect(sessionMatches(session, tokenizeQuery('alpha gateway')), isFalse);
    });

    test('空 token 表视为命中（调用方据此走快速路径）', () {
      expect(sessionMatches(_samples().first, const <String>[]), isTrue);
    });
  });

  group('filterSessions', () {
    test('空 query 原样返回同一列表且顺序不变', () {
      final sessions = _samples();
      final filtered = filterSessions(sessions, '   ');
      expect(identical(filtered, sessions), isTrue);
      expect(_ids(filtered), <String>['s1', 's2', 's3']);
    });

    test('无命中返回空表', () {
      expect(filterSessions(_samples(), 'zzz'), isEmpty);
    });

    test('单个 token 只留下命中的会话，且保持原顺序', () {
      // 'alpha' 命中 s1 的标题与 s3 的 cwd，s2 两边都没有。
      expect(_ids(filterSessions(_samples(), 'alpha')), <String>['s1', 's3']);
    });

    test('多 token 是 AND：只命中一个不算', () {
      expect(_ids(filterSessions(_samples(), 'alpha 重构')), <String>['s1']);
      expect(_ids(filterSessions(_samples(), 'alpha gateway')), isEmpty);
    });

    test('全角空格分词与半角空格等价', () {
      expect(
        _ids(filterSessions(_samples(), 'alpha\u3000重构')),
        _ids(filterSessions(_samples(), 'alpha 重构')),
      );
      expect(_ids(filterSessions(_samples(), 'beta\u3000gateway')), <String>['s2']);
    });

    test('大小写不同的查询结果一致', () {
      expect(
        _ids(filterSessions(_samples(), 'ALPHA')),
        _ids(filterSessions(_samples(), 'alpha')),
      );
    });
  });
}
