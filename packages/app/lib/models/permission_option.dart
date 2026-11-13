/// 会话的权限预设（`permissionPresets/catalog` 里的一项）。
///
/// 宿主给的 `name` 可能就是机器名（本机就是 `read-only` / `workspace-write` /
/// `danger-full-access`），所以界面上的中文标签由客户端自己配：
/// [permissionLabel] 负责把 value 翻成产品用语，认不出来的原样显示。
class PermissionOption {
  const PermissionOption({
    required this.value,
    required this.name,
    this.description,
  });

  /// 容错解析：`value` 与 `name` 至少要有一个，否则这一项没用。
  static PermissionOption? tryParse(Object? json) {
    if (json is! Map) return null;
    final value = _text(json['value']) ?? _text(json['name']);
    if (value == null || value.isEmpty) return null;
    return PermissionOption(
      value: value,
      name: _text(json['name']) ?? value,
      description: _text(json['description']),
    );
  }

  /// 整表解析：坏条目直接跳过，不抛异常。
  static List<PermissionOption> parseList(Object? json) {
    if (json is! List) return const <PermissionOption>[];
    final out = <PermissionOption>[];
    for (final item in json) {
      final option = tryParse(item);
      if (option != null) out.add(option);
    }
    return out;
  }

  /// 机器值：写回时用的就是它（`/permission <value>`）。
  final String value;

  /// 宿主给的名字，可能与 [value] 相同。
  final String name;

  /// 一句人话说明；宿主没配就是 null。
  final String? description;

  /// 界面标签：认识的走产品用语，不认识的用宿主名字。
  String get label => permissionLabel(value);

  static String? _text(Object? value) {
    if (value is String) return value.trim().isEmpty ? null : value.trim();
    return null;
  }
}

/// value → 中文标签。三个内置预设之外，`auto`（自动审查）与 `custom`
/// （三个旋钮被单独改过、不再对应任何预设）也算认识。
String permissionLabel(String value) {
  switch (value) {
    case 'read-only':
      return '仅可查看';
    case 'workspace-write':
      return '工作区内修改';
    case 'danger-full-access':
      return '完全权限';
    case 'auto':
      return '自动审查';
    case 'custom':
      return '自定义';
  }
  return value;
}

/// 预设的一句话说明；宿主没给时用它兜底。
String permissionHint(String value) {
  switch (value) {
    case 'read-only':
      return '只能读文件和看输出，改动一律要你批准';
    case 'workspace-write':
      return '能改本工程的目录，出这个目录仍要批准';
    case 'danger-full-access':
      return '读写与外部命令都不再逐条确认，谨慎使用';
    case 'auto':
      return '每次工具调用先由模型自查一遍，不再逐条弹审批';
    case 'custom':
      return '三个权限旋钮已被单独调整，不对应任何预设';
  }
  return '宿主提供的权限预设';
}

/// `permissionPresets/catalog` 的整份回包。
class PermissionCatalog {
  const PermissionCatalog({
    required this.options,
    this.defaultOptions = const <PermissionOption>[],
    this.defaultPreset,
  });

  const PermissionCatalog.empty()
    : options = const <PermissionOption>[],
      defaultOptions = const <PermissionOption>[],
      defaultPreset = null;

  factory PermissionCatalog.fromJson(Map<String, Object?> json) {
    final options = PermissionOption.parseList(json['options']);
    return PermissionCatalog(
      options: options,
      defaultOptions: PermissionOption.parseList(json['defaultOptions']),
      defaultPreset: json['defaultPreset'] is String
          ? (json['defaultPreset'] as String)
          : null,
    );
  }

  /// 现在能选的每一项，按宿主给的贡献顺序。
  final List<PermissionOption> options;

  /// 可以作为「以后新会话默认值」的那些。
  final List<PermissionOption> defaultOptions;

  /// 不显式指定时的默认预设机器值。
  final String? defaultPreset;

  /// 空目录 = 这台主机没有权限服务。
  bool get isEmpty => options.isEmpty;
}

