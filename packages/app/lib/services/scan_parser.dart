import 'dart:convert';

import '../constants.dart';
import '../models/host.dart';

/// 扫码结果（CONTRACT §7.3）。
class ScanPayload {
  const ScanPayload({
    required this.url,
    this.pin,
    this.name,
    this.hostId,
  });

  final String url;
  final String? pin;
  final String? name;
  final String? hostId;

  /// 转成可直接保存的主机；name 缺省时用域名兜底。
  Host toHost({String? fallbackName}) {
    final host = Host.create(
      name: (name == null || name!.trim().isEmpty)
          ? (fallbackName ?? _hostFromUrl(url))
          : name!.trim(),
      url: url,
      pin: pin ?? '',
      hostId: hostId ?? '',
    );
    return host;
  }

  static String _hostFromUrl(String url) {
    final uri = Uri.tryParse(url);
    return uri == null || uri.host.isEmpty ? url : uri.host;
  }
}

/// 解析二维码 / 深链内容。
///
/// 支持三种形态：
/// 1. `dshfrp://add?url=...&pin=...&name=...&hostId=...`（契约格式，参数需 URL 编码）
/// 2. 纯 URL / 裸域名（可带 `?pin=`）
/// 3. JSON：`{"url":"...","pin":"..."}`
///
/// 无法识别时返回 `null`。
ScanPayload? parseScanPayload(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;

  final lower = text.toLowerCase();

  if (lower.startsWith('$kDeepLinkScheme:') ||
      lower.startsWith('$kDeepLinkScheme://')) {
    return _parseDeepLink(text);
  }

  if (text.startsWith('{')) {
    return _parseJson(text);
  }

  return _parsePlainUrl(text);
}

ScanPayload? _parseDeepLink(String text) {
  Map<String, String> params = const <String, String>{};
  final uri = Uri.tryParse(text);
  if (uri != null && uri.queryParameters.isNotEmpty) {
    params = uri.queryParameters;
  } else {
    final index = text.indexOf('?');
    if (index < 0 || index == text.length - 1) return null;
    try {
      params = Uri.splitQueryString(text.substring(index + 1));
    } catch (_) {
      return null;
    }
  }

  final url = normalizeUrl(_pick(params, const ['url', 'u']) ?? '');
  if (url.isEmpty) return null;

  return ScanPayload(
    url: url,
    pin: _cleanPin(_pick(params, const ['pin', 'p'])),
    name: _cleanText(_pick(params, const ['name', 'n'])),
    hostId: _cleanText(_pick(params, const ['hostId', 'hostid', 'host_id'])),
  );
}

ScanPayload? _parseJson(String text) {
  try {
    final decoded = jsonDecode(text);
    if (decoded is! Map) return null;
    final map = Map<String, dynamic>.from(decoded);
    final url = normalizeUrl(
      (map['url'] ?? map['u'] ?? '').toString(),
    );
    if (url.isEmpty) return null;
    return ScanPayload(
      url: url,
      pin: _cleanPin(map['pin']?.toString()),
      name: _cleanText(map['name']?.toString()),
      hostId: _cleanText(map['hostId']?.toString()),
    );
  } catch (_) {
    return null;
  }
}

ScanPayload? _parsePlainUrl(String text) {
  final url = normalizeUrl(text);
  if (url.isEmpty) return null;

  String? pin;
  final uri = Uri.tryParse(text);
  if (uri != null) {
    pin = _cleanPin(uri.queryParameters['pin']);
  }
  return ScanPayload(url: url, pin: pin);
}

String? _pick(Map<String, String> params, List<String> keys) {
  for (final key in keys) {
    final value = params[key];
    if (value != null && value.isNotEmpty) return value;
  }
  return null;
}

String? _cleanText(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  return trimmed;
}

/// PIN 只保留非空白字符，长度截到 64（契约 8–64 位字母数字）。
String? _cleanPin(String? value) {
  final trimmed = value?.replaceAll(RegExp(r'\s'), '');
  if (trimmed == null || trimmed.isEmpty) return null;
  return trimmed.length > 64 ? trimmed.substring(0, 64) : trimmed;
}
