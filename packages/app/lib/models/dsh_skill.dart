/// 一个可以在对话里用 `/名字` 触发的技能。
///
/// 技能本身**不是客户端能力**：宿主会扫描每条用户消息里的 `/名字`（要求前后是
/// 空白或行首行尾），命中就注入 `<skill_content>`。所以 App 只要把文字原样发出去
/// 就行——这里存在的意义是给输入框做补全，省得用户背 95 个名字。
class DshSkill {
  const DshSkill({required this.name, this.description, this.whenToUse});

  factory DshSkill.fromJson(Map<String, Object?> json) => DshSkill(
    name: (json['name'] as String?) ?? '',
    description: json['description'] as String?,
    whenToUse: json['whenToUse'] as String?,
  );

  /// kebab-case，等于 `/` 后面的那段。
  final String name;

  /// 宿主编写的用途说明，可能很长（中文技能常常一整段）。
  final String? description;

  final String? whenToUse;

  /// 补全面板里的一行说明：优先 whenToUse（更短、更像「什么时候用」）。
  String get summary {
    final String? text = whenToUse ?? description;
    if (text == null || text.trim().isEmpty) return '';
    final String flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length <= 80 ? flat : '${flat.substring(0, 77)}...';
  }

  /// 输入框里的匹配：`/un` 匹配 `unslop`，也匹配中间含 un 的（`doc-on-doc` 之类
  /// 的搜法符合直觉），但前缀匹配排在前面。
  bool matches(String query) {
    if (query.isEmpty) return true;
    final String lower = query.toLowerCase();
    return name.toLowerCase().contains(lower);
  }

  bool startsWith(String query) =>
      query.isNotEmpty && name.toLowerCase().startsWith(query.toLowerCase());

  /// 解析 `skills/list` 的返回值。坏数据静默跳过，不因为一条脏数据丢掉整张表。
  static List<DshSkill> parseList(Object? value) {
    if (value is! List<Object?>) return const <DshSkill>[];
    final List<DshSkill> out = <DshSkill>[];
    for (final Object? item in value) {
      if (item is! Map<Object?, Object?>) continue;
      final DshSkill skill = DshSkill.fromJson(<String, Object?>{
        for (final MapEntry<Object?, Object?> e in item.entries)
          if (e.key is String) e.key! as String: e.value,
      });
      if (skill.name.isEmpty) continue;
      out.add(skill);
    }
    out.sort((DshSkill a, DshSkill b) => a.name.compareTo(b.name));
    return out;
  }
}
