import 'package:dsh_frp_app/models/agent_preset_option.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('解析：缺 id 的条目跳过，order 小的排前面', () {
    final presets = AgentPresetOption.parseList(<Object?>[
      <String, Object?>{'id': 'b', 'isDefault': false, 'order': 20},
      <String, Object?>{'name': '没有 id'},
      <String, Object?>{'id': 'a', 'isDefault': true, 'order': 10},
      'not a map',
      <String, Object?>{'id': 'c'},
    ]);

    expect(presets.map((preset) => preset.id), <String>['a', 'b', 'c']);
    expect(presets.first.isDefault, isTrue);
    expect(presets[1].order, 20);
  });

  test('标签与说明：宿主给名字就用它，没给才用机器名映射', () {
    const named = AgentPresetOption(
      id: 'unrestricted',
      isDefault: false,
      name: '无限制模式（自配）',
      description: '操作者意图优先',
    );
    expect(named.label, '无限制模式（自配）');
    expect(named.hint, '操作者意图优先');

    const bare = AgentPresetOption(id: 'unrestricted', isDefault: false);
    expect(bare.label, '无限制模式');
    expect(bare.hint, isNotEmpty);
    expect(bare.usable, isTrue);

    const unknown = AgentPresetOption(id: 'custom-thing', isDefault: false);
    expect(unknown.label, 'custom-thing');
  });

  test('坏掉的预设：usable 为假，说明里带上宿主给的原因', () {
    const broken = AgentPresetOption(
      id: 'redteam',
      isDefault: false,
      broken: '入口脚本缺失',
    );
    expect(broken.usable, isFalse);
    expect(broken.hint, contains('入口脚本缺失'));
  });

  test('目录：认 default 与按 id 查找，空回包算没有预设服务', () {
    const catalog = AgentPresetCatalog(
      presets: <AgentPresetOption>[
        AgentPresetOption(id: 'main-agent', isDefault: true),
        AgentPresetOption(id: 'unrestricted', isDefault: false),
      ],
    );
    expect(catalog.isEmpty, isFalse);
    expect(catalog.defaultPreset?.id, 'main-agent');
    expect(catalog.byId('unrestricted')?.id, 'unrestricted');
    expect(catalog.byId('nope'), isNull);
    expect(catalog.byId(null), isNull);

    expect(const AgentPresetCatalog.empty().isEmpty, isTrue);
    expect(const AgentPresetCatalog.empty().defaultPreset, isNull);
  });

  test('fromJson：只认 presets 字段，其它字段忽略', () {
    final catalog = AgentPresetCatalog.fromJson(<String, Object?>{
      'presets': <Object?>[
        <String, Object?>{
          'id': 'main-agent',
          'isDefault': true,
          'name': '主智能体',
          'description': '常驻监督者',
        },
      ],
      'unexpected': 1,
    });
    expect(catalog.presets.single.label, '主智能体');
    expect(catalog.presets.single.isDefault, isTrue);
    expect(
      AgentPresetCatalog.fromJson(const <String, Object?>{}).isEmpty,
      isTrue,
    );
  });
}
