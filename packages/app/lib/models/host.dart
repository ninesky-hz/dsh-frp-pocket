import '../constants.dart';
import '../utils/ids.dart';

const Object _unset = Object();

final RegExp _schemePattern = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.\-]*://');
final RegExp _whitespacePattern = RegExp(r'\s');

/// 只接受 ASCII 主机名 / IPv4 / 单标签主机名；IDN 与 IPv6 字面量不在 v1 支持范围。
final RegExp _hostPattern = RegExp(
  r'^[a-z0-9]([a-z0-9\-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9\-]*[a-z0-9])?)*$',
);

/// 规范化用户输入的网关地址（CONTRACT §7.1）。
///
/// 规则：
/// - 去掉首尾空白；含空白字符视为非法，返回空串。
/// - 没有 scheme 时补 `https://`；`//host` 视为 `https://host`。
/// - 非 http/https 的 scheme 一律替换成 `https`。
/// - 只保留 `scheme://host[:port]`：去掉 path / query / fragment / userinfo。
/// - host 转小写，去掉默认端口与尾斜杠。
/// - 无法解析或没有 host 时返回空串。
String normalizeUrl(String raw) {
  var text = raw.trim();
  if (text.isEmpty) return '';
  if (_whitespacePattern.hasMatch(text)) return '';

  if (text.startsWith('//')) {
    text = 'https:$text';
  } else {
    final match = _schemePattern.firstMatch(text);
    if (match == null) {
      text = 'https://$text';
    } else {
      final scheme = text.substring(0, match.end - 3).toLowerCase();
      if (scheme != 'http' && scheme != 'https') {
        text = 'https://${text.substring(match.end)}';
      }
    }
  }

  final uri = Uri.tryParse(text);
  if (uri == null) return '';

  final host = uri.host.toLowerCase();
  if (host.isEmpty || !_hostPattern.hasMatch(host)) return '';

  final scheme = uri.scheme.toLowerCase() == 'http' ? 'http' : 'https';
  final defaultPort = scheme == 'https' ? 443 : 80;
  final port =
      uri.hasPort && uri.port != defaultPort ? ':${uri.port}' : '';

  return '$scheme://$host$port';
}

/// 主机：一台电脑上的 DSH 网关（CONTRACT §7.1）。
class Host {
  const Host({
    required this.id,
    required this.name,
    required this.url,
    this.pin = '',
    this.hostId = '',
    this.lastOk,
    this.lastSeenAt,
  });

  /// 新建一台主机。带服务端 hostId 时直接用它当本地 id：
  /// 同一台机子重复扫码/重装后扫码都会覆盖同一条，而不是越加越多。
  factory Host.create({
    required String name,
    required String url,
    String pin = '',
    String hostId = '',
  }) {
    final sid = hostId.trim();
    return Host(
      id: sid.isNotEmpty ? sid : newHostLocalId(),
      name: name,
      url: normalizeUrl(url),
      pin: pin.trim(),
      hostId: sid,
    );
  }

  /// 容错解析：字段缺失或类型不对时给默认值，URL 一律规范化。
  factory Host.fromJson(Map<String, dynamic> json) {
    String asString(Object? value) {
      if (value == null) return '';
      if (value is String) return value;
      return value.toString();
    }

    bool? asBool(Object? value) {
      if (value is bool) return value;
      if (value is num) return value != 0;
      if (value is String) {
        final lower = value.toLowerCase();
        if (lower == 'true' || lower == '1') return true;
        if (lower == 'false' || lower == '0') return false;
      }
      return null;
    }

    int? asInt(Object? value) {
      if (value is int) return value;
      if (value is num) return value.toInt();
      if (value is String) return int.tryParse(value);
      return null;
    }

    return Host(
      id: asString(json['id']),
      name: asString(json['name']),
      url: normalizeUrl(asString(json['url'])),
      pin: asString(json['pin']).trim(),
      hostId: asString(json['hostId']).trim(),
      lastOk: asBool(json['lastOk']),
      lastSeenAt: asInt(json['lastSeenAt']),
    );
  }

  final String id;
  final String name;

  /// 规范化后的网关根地址，例如 `https://home.dsh.example.com`。
  final String url;
  final String pin;

  /// 服务端上报的稳定标识 `<slug>-<8hex>`（探测后回填，可为空）。
  final String hostId;
  final bool? lastOk;
  final int? lastSeenAt;

  String get displayHost {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return url;
    final port = uri.hasPort ? ':${uri.port}' : '';
    return '${uri.host}$port';
  }

  /// WebView 首屏地址：带 PIN 时拼 `?pin=`（CONTRACT §4.3）。
  String get webEntryUrl {
    if (pin.isEmpty) return url;
    return '$url/?pin=${Uri.encodeQueryComponent(pin)}';
  }

  /// 与插件设置页二维码一致的内容（CONTRACT §7.3）。
  String get deepLink {
    final params = <String, String>{'url': url};
    if (pin.isNotEmpty) params['pin'] = pin;
    if (name.isNotEmpty) params['name'] = name;
    if (hostId.isNotEmpty) params['hostId'] = hostId;
    final query = params.entries
        .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    return '$kDeepLinkScheme://add?$query';
  }

  bool get isExample => id.startsWith('example-');

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'name': name,
      'url': url,
      'pin': pin,
      'hostId': hostId,
      'lastOk': lastOk,
      'lastSeenAt': lastSeenAt,
    };
  }

  Host copyWith({
    String? id,
    String? name,
    String? url,
    String? pin,
    String? hostId,
    Object? lastOk = _unset,
    Object? lastSeenAt = _unset,
  }) {
    return Host(
      id: id ?? this.id,
      name: name ?? this.name,
      url: url == null ? this.url : normalizeUrl(url),
      pin: pin ?? this.pin,
      hostId: hostId ?? this.hostId,
      lastOk: identical(lastOk, _unset) ? this.lastOk : lastOk as bool?,
      lastSeenAt: identical(lastSeenAt, _unset)
          ? this.lastSeenAt
          : lastSeenAt as int?,
    );
  }

  /// 探测结果回填：`lastSeenAt` 只在在线时前进。
  Host withProbe({required bool online, int? nowMillis}) {
    final stamp = nowMillis ?? DateTime.now().millisecondsSinceEpoch;
    return copyWith(
      lastOk: online,
      lastSeenAt: online ? stamp : lastSeenAt,
    );
  }

  @override
  String toString() => 'Host($id, $name, $url)';

  @override
  bool operator ==(Object other) {
    return other is Host &&
        other.id == id &&
        other.name == name &&
        other.url == url &&
        other.pin == pin &&
        other.hostId == hostId &&
        other.lastOk == lastOk &&
        other.lastSeenAt == lastSeenAt;
  }

  @override
  int get hashCode =>
      Object.hash(id, name, url, pin, hostId, lastOk, lastSeenAt);
}
