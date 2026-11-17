import 'package:dsh_frp_app/models/host.dart';
import 'package:dsh_frp_app/models/host_dir.dart';
import 'package:dsh_frp_app/screens/host_dir_picker_screen.dart';
import 'package:dsh_frp_app/services/dsh_api.dart';
import 'package:dsh_frp_app/theme/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const Host _host = Host(
  id: 'h1',
  name: '家里',
  url: 'https://home.dsh.example.com',
  pin: 'abcd1234',
);

const String _home = r'C:\Users\Chen';
const String _projects = r'C:\Users\Chen\projects';
const String _demo = r'C:\Users\Chen\projects\demo';

/// 一张固定的宿主目录树：键是绝对路径，值是网关返回的那份 JSON。
Map<String, Map<String, Object?>> _tree() => <String, Map<String, Object?>>{
  _home: <String, Object?>{
    'ok': true,
    'path': _home,
    'parent': r'C:\Users',
    'home': _home,
    'roots': <Object?>[
      <String, Object?>{'name': 'C:', 'path': r'C:\'},
      <String, Object?>{'name': 'D:', 'path': r'D:\'},
    ],
    'entries': <Object?>[
      <String, Object?>{
        'name': 'projects',
        'path': _projects,
        'dir': true,
        'hidden': false,
      },
      <String, Object?>{
        'name': 'notes.md',
        'path': r'C:\Users\Chen\notes.md',
        'dir': false,
        'hidden': false,
      },
    ],
    'truncated': false,
  },
  _projects: <String, Object?>{
    'ok': true,
    'path': _projects,
    'parent': _home,
    'home': _home,
    'roots': const <Object?>[],
    'entries': <Object?>[
      <String, Object?>{
        'name': 'demo',
        'path': _demo,
        'dir': true,
        'hidden': false,
      },
    ],
    'truncated': false,
  },
};

class _FakeApi extends DshApi {
  _FakeApi(this.tree);

  final Map<String, Map<String, Object?>> tree;
  final List<String> requested = <String>[];
  final List<({String path, String name})> created =
      <({String path, String name})>[];

  /// 下一次 listHostDir 抛这个错误（一次性）。
  DshApiException? failNext;

  @override
  Future<HostDirListing> listHostDir(
    Host host,
    String path, {
    bool showHidden = false,
  }) async {
    requested.add(path);
    final failure = failNext;
    if (failure != null) {
      failNext = null;
      throw failure;
    }
    // 空路径 = 让宿主用家目录，和真端点的语义一致。
    final key = path.trim().isEmpty ? _home : path;
    final body = tree[key];
    if (body == null) {
      throw const DshApiException('not-found', 'no such directory', statusCode: 404);
    }
    return HostDirListing.fromJson(body);
  }

  @override
  Future<String> makeHostDir(
    Host host, {
    required String path,
    required String name,
  }) async {
    created.add((path: path, name: name));
    return '$path\\$name';
  }
}

/// 把浏览页挂在按钮后面，好接住它 pop 回来的路径。
class _Launcher extends StatefulWidget {
  const _Launcher({required this.api, this.initialPath});

  final _FakeApi api;
  final String? initialPath;

  @override
  State<_Launcher> createState() => _LauncherState();
}

class _LauncherState extends State<_Launcher> {
  String? picked;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextButton(
                key: const ValueKey<String>('open'),
                onPressed: () async {
                  final value = await Navigator.of(context).push<String>(
                    MaterialPageRoute<String>(
                      builder: (_) => HostDirPickerScreen(
                        host: _host,
                        api: widget.api,
                        initialPath: widget.initialPath,
                      ),
                    ),
                  );
                  setState(() => picked = value);
                },
                child: const Text('打开'),
              ),
              Text(
                picked ?? '',
                key: const ValueKey<String>('picked'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<_FakeApi> _open(
  WidgetTester tester, {
  String? initialPath,
  Map<String, Map<String, Object?>>? tree,
}) async {
  final api = _FakeApi(tree ?? _tree());
  await tester.pumpWidget(
    MaterialApp(home: _Launcher(api: api, initialPath: initialPath)),
  );
  await tester.tap(find.byKey(const ValueKey<String>('open')));
  await tester.pumpAndSettle();
  return api;
}

void main() {
  testWidgets('首屏落在家目录：目录可点，文件只是占位', (tester) async {
    final api = await _open(tester);

    expect(api.requested, <String>['']);
    expect(find.text(_home), findsOneWidget);
    expect(find.text('projects'), findsOneWidget);
    expect(find.text('notes.md'), findsOneWidget);

    final file = tester.widget<ListTile>(
      find.byKey(const ValueKey<String>('dir-picker.entry.notes.md')),
    );
    expect(file.enabled, isFalse);

    final dir = tester.widget<ListTile>(
      find.byKey(const ValueKey<String>('dir-picker.entry.projects')),
    );
    expect(dir.enabled, isTrue);
  });

  testWidgets('点目录进下一层，路径条跟着变', (tester) async {
    final api = await _open(tester);

    await tester.tap(
      find.byKey(const ValueKey<String>('dir-picker.entry.projects')),
    );
    await tester.pumpAndSettle();

    expect(api.requested, <String>['', _projects]);
    expect(find.text('demo'), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey<String>('dir-picker.path')))
          .data,
      _projects,
    );
  });

  testWidgets('「上一级」回父目录', (tester) async {
    final api = await _open(tester, initialPath: _projects);

    expect(api.requested, <String>[_projects]);
    await tester.tap(find.byKey(const ValueKey<String>('dir-picker.up')));
    await tester.pumpAndSettle();

    expect(api.requested.last, _home);
    expect(find.text('projects'), findsOneWidget);
  });

  testWidgets('「用这个目录」把绝对路径 pop 回去', (tester) async {
    await _open(tester, initialPath: _projects);

    await tester.tap(find.byKey(const ValueKey<String>('dir-picker.confirm')));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey<String>('picked')))
          .data,
      _projects,
    );
  });

  testWidgets('宿主说不存在时给中文提示，重试能恢复', (tester) async {
    final api = _FakeApi(_tree())
      ..failNext = const DshApiException(
        'not-found',
        'no such directory',
        statusCode: 404,
      );
    await tester.pumpWidget(MaterialApp(home: _Launcher(api: api)));
    await tester.tap(find.byKey(const ValueKey<String>('open')));
    await tester.pumpAndSettle();

    expect(find.text('这个目录不存在了'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('dir-picker.confirm')), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey<String>('dir-picker.confirm')),
          )
          .onPressed,
      isNull,
    );

    await tester.tap(find.byKey(const ValueKey<String>('dir-picker.retry')));
    await tester.pumpAndSettle();

    expect(find.text('这个目录不存在了'), findsNothing);
    expect(find.text('projects'), findsOneWidget);
  });

  testWidgets('新建子目录：名字发给宿主，然后直接进去', (tester) async {
    final api = await _open(tester, initialPath: _projects);

    await tester.tap(find.byKey(const ValueKey<String>('dir-picker.create')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('dir-picker.new-name')),
      'fresh',
    );
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();

    expect(api.created, <({String path, String name})>[
      (path: _projects, name: 'fresh'),
    ]);
    // 新目录还没进树里 → 显示 not-found，但至少请求已经打过去了。
    expect(api.requested.last, r'C:\Users\Chen\projects\fresh');
  });

  testWidgets('隐藏项开关会带 showHidden 重新请求', (tester) async {
    final api = await _open(tester);

    await tester.tap(find.byKey(const ValueKey<String>('dir-picker.hidden')));
    await tester.pumpAndSettle();

    expect(api.requested, <String>['', _home]);
    // 图标换成了「显示中」，说明开关状态翻转了。
    expect(find.byIcon(AppIcons.visible), findsOneWidget);
  });
}
