import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_frp_app/models/prompt_image.dart';
import 'package:flutter_test/flutter_test.dart';

/// 1×1 透明 PNG：真实可解码，避免断言依赖假字节。
final Uint8List _tinyPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
  'AAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

void main() {
  group('PromptImage.toJson', () {
    test('有 name 时带上 name，形状与线上契约一致', () {
      final image = PromptImage(
        mediaType: 'image/png',
        base64Data: base64Encode(_tinyPng),
        name: 'probe.png',
      );

      expect(image.toJson(), <String, Object?>{
        'type': 'image',
        'mediaType': 'image/png',
        'data': base64Encode(_tinyPng),
        'name': 'probe.png',
      });
    });

    test('name 为 null 时整键省略（不发 null 给服务端）', () {
      const image = PromptImage(mediaType: 'image/webp', base64Data: 'AAAA');

      final json = image.toJson();
      expect(json.containsKey('name'), isFalse);
      expect(json, <String, Object?>{
        'type': 'image',
        'mediaType': 'image/webp',
        'data': 'AAAA',
      });
    });
  });

  group('PromptImage.fromBytes', () {
    test('内部做标准 base64 编码，可原样解回', () {
      final image = PromptImage.fromBytes(
        _tinyPng,
        mediaType: 'image/png',
        name: 'a.png',
      );

      expect(image.mediaType, 'image/png');
      expect(image.name, 'a.png');
      expect(base64Decode(image.base64Data), _tinyPng);
    });

    test('fromJson 能吃回 toJson 的输出', () {
      final image = PromptImage.fromBytes(_tinyPng, mediaType: 'image/gif');
      final round = PromptImage.fromJson(image.toJson());

      expect(round, isNotNull);
      expect(round!.mediaType, 'image/gif');
      expect(round.base64Data, image.base64Data);
      expect(round.name, isNull);
    });

    test('fromJson 对坏数据返回 null，不抛异常', () {
      expect(PromptImage.fromJson(null), isNull);
      expect(PromptImage.fromJson('nope'), isNull);
      expect(PromptImage.fromJson(<String, Object?>{'data': 'x'}), isNull);
      expect(
        PromptImage.fromJson(<String, Object?>{'mediaType': 'image/png'}),
        isNull,
      );
    });
  });

  group('PromptImage.mediaTypeForPath', () {
    test('按扩展名认出四种支持的格式', () {
      expect(PromptImage.mediaTypeForPath('/tmp/a.png'), 'image/png');
      expect(PromptImage.mediaTypeForPath('/tmp/a.jpg'), 'image/jpeg');
      expect(PromptImage.mediaTypeForPath('/tmp/a.jpeg'), 'image/jpeg');
      expect(PromptImage.mediaTypeForPath('/tmp/a.webp'), 'image/webp');
      expect(PromptImage.mediaTypeForPath('/tmp/a.gif'), 'image/gif');
    });

    test('大小写不敏感，带 query 的路径也能认', () {
      expect(PromptImage.mediaTypeForPath('/tmp/PHOTO.PNG'), 'image/png');
      expect(
        PromptImage.mediaTypeForPath('/cache/a.webp?w=120'),
        'image/webp',
      );
    });

    test('不认识的扩展名返回 null，交给调用方兜底', () {
      expect(PromptImage.mediaTypeForPath('/tmp/a.heic'), isNull);
      expect(PromptImage.mediaTypeForPath('/tmp/a'), isNull);
      expect(PromptImage.mediaTypeForPath(''), isNull);
    });

    test('supportedMediaTypes 与扩展名映射覆盖同一组格式', () {
      expect(PromptImage.supportedMediaTypes, <String>{
        'image/png',
        'image/jpeg',
        'image/webp',
        'image/gif',
      });
    });
  });
}
