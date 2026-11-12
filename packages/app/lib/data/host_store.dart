import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants.dart';
import '../models/host.dart';

/// 主机列表的本地存储（shared_preferences JSON 数组，CONTRACT §7.1）。
class HostStore extends ChangeNotifier {
  static const String storageKey = 'dsh_frp.hosts.v1';
  static const String exampleHomeId = 'example-home';
  static const String exampleStudioId = 'example-studio';

  List<Host> _hosts = <Host>[];
  bool _loaded = false;

  List<Host> get hosts => List<Host>.unmodifiable(_hosts);
  bool get isLoaded => _loaded;
  bool get isEmpty => _hosts.isEmpty;
  bool get hasExampleHosts => _hosts.any((h) => h.isExample);

  /// 首次启动预置两条示例主机（占位域名，UI 上标注“示例”）。
  static List<Host> seedHosts() => <Host>[
    const Host(
      id: exampleHomeId,
      name: '家里（示例）',
      url: kExampleHomeUrl,
      pin: '',
    ),
    const Host(
      id: exampleStudioId,
      name: '工作室（示例）',
      url: kExampleStudioUrl,
      pin: '',
    ),
  ];

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(storageKey);
      if (raw == null) {
        _hosts = seedHosts();
        _loaded = true;
        notifyListeners();
        await _persist();
        return;
      }
      final decoded = jsonDecode(raw);
      final list = <Host>[];
      if (decoded is List) {
        for (final item in decoded) {
          if (item is Map) {
            final host = Host.fromJson(Map<String, dynamic>.from(item));
            if (host.id.isNotEmpty && host.url.isNotEmpty) list.add(host);
          }
        }
      }
      _hosts = list;
    } catch (_) {
      // 存储损坏时退回空列表，用户可重新添加。
      _hosts = <Host>[];
    }
    _loaded = true;
    notifyListeners();
  }

  Host? byId(String id) {
    for (final host in _hosts) {
      if (host.id == id) return host;
    }
    return null;
  }

  /// 新增或按 id 覆盖。
  Future<void> upsert(Host host) async {
    final index = _hosts.indexWhere((h) => h.id == host.id);
    if (index >= 0) {
      final next = List<Host>.of(_hosts);
      next[index] = host;
      _hosts = next;
    } else {
      _hosts = <Host>[..._hosts, host];
    }
    notifyListeners();
    await _persist();
  }

  Future<void> remove(String id) async {
    final next = _hosts.where((h) => h.id != id).toList(growable: false);
    if (next.length == _hosts.length) return;
    _hosts = next;
    notifyListeners();
    await _persist();
  }

  /// 写回探测结果（在线状态、最近在线时间）。
  Future<void> applyProbe(String id, {required bool online}) async {
    final host = byId(id);
    if (host == null) return;
    await upsert(host.withProbe(online: online));
  }

  /// 回填服务端上报的 hostId（首次连接时）。
  Future<void> applyServerIdentity(String id, String serverHostId) async {
    if (serverHostId.isEmpty) return;
    final host = byId(id);
    if (host == null || host.hostId == serverHostId) return;
    await upsert(host.copyWith(hostId: serverHostId));
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final payload = jsonEncode(_hosts.map((h) => h.toJson()).toList());
      await prefs.setString(storageKey, payload);
    } catch (_) {
      // 忽略写入失败：内存态仍然可用。
    }
  }
}
