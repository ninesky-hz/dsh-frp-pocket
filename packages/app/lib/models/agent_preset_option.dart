/// 会话的人格预设（`agentPresets/list` 里的一项）。
///
/// 人格预设决定这个会话装哪套工具、提示词与技能。宿主的 `name` 是预设作者写
/// 在 `preset.yml` 里的展示名（「红队模式」这种），所以界面优先用它；
/// 没写名字的老预设才退回 [agentPresetLabel] 的机器名映射。
class AgentPresetOption {
  const AgentPresetOption({
    required this.id,
    required this.isDefault,
    this.name,
    this.description,
    this.broken,
    this.order,
  });

  /// 容错解析：`id` 必须是非空字符串，否则这一项没用。
  static AgentPresetOption? tryParse(Object? json) {
    if (json is! Map) return null;
    final id = _text(json['id']);
    if (id == null) return null;
    return AgentPresetOption(
      id: id,
      isDefault: json['isDefault'] == true,
      name: _text(json['name']),
      description: _text(json['description']),
      broken: _text(json['broken']),
      order: json['order'] is num ? (json['order'] as num).toInt() : null,
    );
  }

  /// 整表解析：坏条目直接跳过，不抛异常。
  static List<AgentPresetOption> parseList(Object? json) {
    if (json is! List) return const <AgentPresetOption>[];
    final out = <AgentPresetOption>[];
    for (final item in json) {
      final option = tryParse(item);
      if (option != null) out.add(option);
    }
    out.sort((a, b) {
      final byOrder = (a.order ?? 1 << 30).compareTo(b.order ?? 1 << 30);
      return byOrder != 0 ? byOrder : a.id.compareTo(b.id);
    });
    return out;
  }

  /// 机器值：`agentPresets/select` 的 `agentPreset` 传的就是它。
  final String id;

  /// 是不是「没显式指定时用的那个」。
  final bool isDefault;

  /// 预设作者给的展示名；没配就是 null。
  final String? name;

  /// 一句话说明；没配就是 null。
  final String? description;

  /// 组合失败的原因；非 null 表示这个预设现在起不了会话。
  final String? broken;

  /// 作者给的排序权重，越小越前。
  final int? order;

  /// 界面标题。
  String get label => name ?? agentPresetLabel(id);

  /// 界面副标题：坏掉的先说坏，其次宿主说明，最后兜底。
  String get hint {
    final problem = broken;
    if (problem != null) return '暂时不可用：$problem';
    return description ?? agentPresetHint(id);
  }

  /// 现在能不能选。
  bool get usable => broken == null;

  static String? _text(Object? value) {
    if (value is String) return value.trim().isEmpty ? null : value.trim();
    return null;
  }
}

/// id → 中文标签，只在预设没写 `name` 时兜底。
String agentPresetLabel(String id) {
  switch (id) {
    case 'main-agent':
      return '主智能体';
    case 'standard':
      return '标准';
    case 'unrestricted':
      return '无限制模式';
    case 'redteam':
      return '红队模式';
    case 'cordis':
      return '创造模式';
    case 'ptc':
      return 'PTC';
    case 'minimal':
      return '极简';
  }
  return id;
}

/// 预设的一句话说明；宿主没给时用它兜底。
String agentPresetHint(String id) {
  switch (id) {
    case 'main-agent':
      return '常驻监督者：锁定目标后派生开发子代理，休眠并在收敛时验收';
    case 'standard':
      return '标准工具集：读写文件、跑命令、联网搜索';
    case 'unrestricted':
      return '操作者意图优先的骨架，工具面沿用标准集';
    case 'redteam':
      return '攻防演练模式：内置主会话加五个执行角色';
    case 'cordis':
      return '面向插件与配置的实验模式';
    case 'ptc':
      return '程序化工具调用：一次写代码跑多步';
    case 'minimal':
      return '只留最基本的对话与读写能力';
  }
  return '人格预设';
}

/// `agentPresets/list` 的整份回包。
class AgentPresetCatalog {
  const AgentPresetCatalog({required this.presets});

  const AgentPresetCatalog.empty() : presets = const <AgentPresetOption>[];

  factory AgentPresetCatalog.fromJson(Map<String, Object?> json) =>
      AgentPresetCatalog(presets: AgentPresetOption.parseList(json['presets']));

  /// 这台主机上注册的全部预设，按作者给的顺序。
  final List<AgentPresetOption> presets;

  /// 空 = 这台主机没有预设服务，界面把入口藏起来。
  bool get isEmpty => presets.isEmpty;

  /// 没显式指定时用的那个；宿主没标 default 就是 null。
  AgentPresetOption? get defaultPreset {
    for (final preset in presets) {
      if (preset.isDefault) return preset;
    }
    return null;
  }

  /// 按 id 找一项；找不到返回 null。
  AgentPresetOption? byId(String? id) {
    if (id == null) return null;
    for (final preset in presets) {
      if (preset.id == id) return preset;
    }
    return null;
  }
}
