import 'dart:convert';
import 'dart:typed_data';

/// 一条待发送的图片 part。
///
/// 为什么把 base64 存在模型里而不是持有原始字节：`session/prompt` 的线上契约
/// 就是 base64（`content[].data`），离线队列还要把它整条落盘。持有 base64
/// 让「发一条」和「存一条」共用同一份数据，不用在两处来回转码。
class PromptImage {
  const PromptImage({
    required this.mediaType,
    required this.base64Data,
    this.name,
  });

  /// 从原始字节造一条：调用方只需要关心「这张图是什么类型」。
  factory PromptImage.fromBytes(
    Uint8List bytes, {
    required String mediaType,
    String? name,
  }) {
    return PromptImage(
      mediaType: mediaType,
      base64Data: base64Encode(bytes),
      name: name,
    );
  }

  /// 从落盘 JSON 读回。
  ///
  /// 读回时给的是 `toJson()` 的形状，但也容忍只有 `mediaType`/`data` 的老数据；
  /// 缺关键字段就返回 null —— 队列里一条坏图不该拖垮整批待发消息。
  static PromptImage? fromJson(Object? value) {
    if (value is! Map) return null;
    final mediaType = value['mediaType'];
    final data = value['data'];
    if (mediaType is! String || mediaType.isEmpty) return null;
    if (data is! String || data.isEmpty) return null;
    final name = value['name'];
    return PromptImage(
      mediaType: mediaType,
      base64Data: data,
      name: name is String && name.trim().isNotEmpty ? name : null,
    );
  }

  final String mediaType;

  /// 已编码的图片内容（不带 `data:` 前缀）。
  final String base64Data;
  final String? name;

  /// 服务端只认这四种；其余类型在选图阶段就被挡掉，避免发出去才失败。
  static const Set<String> supportedMediaTypes = <String>{
    'image/png',
    'image/jpeg',
    'image/webp',
    'image/gif',
  };

  /// 按扩展名推 mediaType；认不出来返回 null，由调用方兜底。
  ///
  /// 只看后缀而不嗅探文件头：选图器给的名字通常是对的，嗅探的代价（读一遍
  /// 前几个字节）换不来更多准确度，真正的校验在服务端。
  static String? mediaTypeForPath(String path) {
    final lower = path.toLowerCase();
    // 带 query 的路径（少见，但本地缓存路径可能出现）先截掉问号之后的部分。
    final query = lower.indexOf('?');
    final clean = query >= 0 ? lower.substring(0, query) : lower;
    if (clean.endsWith('.png')) return 'image/png';
    if (clean.endsWith('.jpg') || clean.endsWith('.jpeg')) return 'image/jpeg';
    if (clean.endsWith('.webp')) return 'image/webp';
    if (clean.endsWith('.gif')) return 'image/gif';
    return null;
  }

  /// 线上形状：`{type: 'image', mediaType, data, name?}`。
  ///
  /// `name` 为 null 时整键省掉：服务端按可选字段解析，塞一个 `null` 反而可能
  /// 被当成长度为 0 的名字。
  Map<String, Object?> toJson() {
    return <String, Object?>{
      'type': 'image',
      'mediaType': mediaType,
      'data': base64Data,
      'name': ?name,
    };
  }

  @override
  String toString() =>
      'PromptImage($mediaType, ${base64Data.length}字符, name=$name)';
}
