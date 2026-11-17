import 'session_event.dart' show asBool, asText;

/// 宿主目录浏览的一层结果（`/frp-pocket/api/fs/list`）。
///
/// 这是**我们自己的网关端点**，不是 DSH 的原生 RPC：DSH 的 `directoryPicker`
/// 单 capability 组合之后只剩 native（PC 系统框），`list` 永远不可用；把组合
/// 改成 browse 又会让 PC 端的新建目录变成内置浏览器。所以手机端这条走网关。
///
/// 字段全部容错：插件升级后少字段不能让界面崩掉。
class HostDirListing {
  const HostDirListing({
    required this.path,
    this.parent,
    this.home,
    this.roots = const <HostDirRoot>[],
    this.entries = const <HostDirEntry>[],
    this.truncated = false,
  });

  factory HostDirListing.fromJson(Map<String, Object?> json) {
    final entries = <HostDirEntry>[];
    final rawEntries = json['entries'];
    if (rawEntries is List) {
      for (final item in rawEntries) {
        if (item is Map) {
          final entry = HostDirEntry.fromJson(item.cast<String, Object?>());
          if (entry.name.isNotEmpty) entries.add(entry);
        }
      }
    }
    final roots = <HostDirRoot>[];
    final rawRoots = json['roots'];
    if (rawRoots is List) {
      for (final item in rawRoots) {
        if (item is Map) {
          final root = HostDirRoot.fromJson(item.cast<String, Object?>());
          if (root.path.isNotEmpty) roots.add(root);
        }
      }
    }
    return HostDirListing(
      path: asText(json['path']) ?? '',
      parent: asText(json['parent']),
      home: asText(json['home']),
      roots: roots,
      entries: entries,
      truncated: asBool(json['truncated']),
    );
  }

  /// 当前目录的宿主绝对路径（规范化后）。
  final String path;

  /// 上一层目录；已经在盘符根时为空。
  final String? parent;

  /// 宿主的用户目录，首次打开浏览页的落点。
  final String? home;

  /// 存在的盘符根，根目录时可当快捷入口。
  final List<HostDirRoot> roots;

  /// 这一层的子项：目录在前、文件在后（文件只用来帮助辨认位置，不可选）。
  final List<HostDirEntry> entries;

  /// 是否被条目上限截断。
  final bool truncated;
}

/// 一个盘符根（Windows 上是 `D:\`）。
class HostDirRoot {
  const HostDirRoot({required this.name, required this.path});

  factory HostDirRoot.fromJson(Map<String, Object?> json) => HostDirRoot(
    name: asText(json['name']) ?? asText(json['path']) ?? '',
    path: asText(json['path']) ?? '',
  );

  final String name;
  final String path;
}

/// 一层里的一个子项。
class HostDirEntry {
  const HostDirEntry({
    required this.name,
    required this.path,
    required this.dir,
    this.hidden = false,
  });

  factory HostDirEntry.fromJson(Map<String, Object?> json) => HostDirEntry(
    name: asText(json['name']) ?? '',
    path: asText(json['path']) ?? '',
    dir: asBool(json['dir']),
    hidden: asBool(json['hidden']),
  );

  final String name;

  /// 子项的宿主绝对路径。
  final String path;

  /// 是不是目录：只有目录能进、能选。
  final bool dir;

  /// 点前缀的隐藏项（宿主 Windows 隐藏属性拿不到，只按名字近似）。
  final bool hidden;
}
