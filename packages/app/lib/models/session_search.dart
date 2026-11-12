/// 会话搜索的**本地**这一路：纯函数，不碰 RPC、不碰 widget。
///
/// dsh-Go 的搜索是两路合并：本地过滤（标题 + 工作目录）和宿主
/// `session/search`（FTS5 全文）。这里先只做本地那一路——它零延迟、断网也能用，
/// 而且过滤只是渲染前的一道筛，不需要为每个按键发一次 RPC。
///
/// TODO(host-search): 宿主 session/search（FTS5）以后接：结果按 sessionId 与
/// 本地结果去重合并，宿主明确不支持时按返回 code 永久降级（记住「该宿主不支持」
/// 后再也不发这次 RPC）。
library;

import 'session_summary.dart';

/// 分词分隔符：所有空白 + 全角空格（U+3000）。
///
/// `\s` 在 Dart 的 RegExp（ECMAScript 语义）里不覆盖全角空格，中文输入法下
/// 用户很容易打出 `a　b` 这种词间全角空格，所以必须显式列进分隔集合。
final RegExp _separators = RegExp(r'[\s\u3000]+');

/// 把一条查询切成小写 token：按空白（含全角空格）切分，去掉空片段，统一小写。
///
/// 空查询、纯空白查询都返回空表——调用方据此走「不过滤」的快速路径。
List<String> tokenizeQuery(String query) {
  final tokens = <String>[];
  for (final part in query.split(_separators)) {
    if (part.isEmpty) continue;
    tokens.add(part.toLowerCase());
  }
  return tokens;
}

/// 会话是否命中**全部** token（AND：顺序无关，每个词都要出现）。
///
/// 每个 token 在 `标题 + 工作目录` 里做大小写不敏感的子串匹配，不要求词边界：
/// 用户搜 `frp` 应该命中 `dsh-frp-pocket`，这比按词切更符合「路径搜索」的直觉。
///
/// token 允许来自任意来源，这里再小写一次（tokenizeQuery 已经小写过，重复无害），
/// 这样单独调用它也不会因为大小写不同而漏。
bool sessionMatches(SessionSummary session, List<String> tokens) {
  if (tokens.isEmpty) return true;
  // 用换行连接：token 不会跨标题与路径两段拼接处误命中。
  final haystack = '${session.title}\n${session.cwd}'.toLowerCase();
  for (final token in tokens) {
    if (!haystack.contains(token.toLowerCase())) return false;
  }
  return true;
}

/// 用一条查询过滤列表：tokens 为空时**原样返回**（同一个列表实例，顺序不变）。
///
/// 不做排序、不改 `SessionSummary`，因此调用方可以安全地在渲染前现算：
/// 列表本身的顺序仍然由工作区状态决定，过滤只减少成员。
List<SessionSummary> filterSessions(
  List<SessionSummary> sessions,
  String query,
) {
  final tokens = tokenizeQuery(query);
  if (tokens.isEmpty) return sessions;
  return <SessionSummary>[
    for (final session in sessions)
      if (sessionMatches(session, tokens)) session,
  ];
}
