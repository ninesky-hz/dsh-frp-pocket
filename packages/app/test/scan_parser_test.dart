import 'package:dsh_frp_app/models/host.dart';
import 'package:dsh_frp_app/services/scan_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseScanPayload', () {
    test('解析契约格式 dshfrp://add', () {
      const raw =
          'dshfrp://add?url=https%3A%2F%2Fhome.dsh.example.com'
          '&pin=abcd1234&name=%E5%AE%B6%E9%87%8C'
          '&hostId=home-1a2b3c4d';
      final payload = parseScanPayload(raw);

      expect(payload, isNotNull);
      expect(payload!.url, 'https://home.dsh.example.com');
      expect(payload.pin, 'abcd1234');
      expect(payload.name, '家里');
      expect(payload.hostId, 'home-1a2b3c4d');
    });

    test('只有 url 的深链', () {
      final payload = parseScanPayload(
        'dshfrp://add?url=https://studio.dsh.example.com',
      );
      expect(payload, isNotNull);
      expect(payload!.url, 'https://studio.dsh.example.com');
      expect(payload.pin, isNull);
      expect(payload.name, isNull);
    });

    test('短参数名 u / p 也认', () {
      final payload = parseScanPayload('dshfrp://add?u=home.dsh.example.com&p=abcd1234');
      expect(payload, isNotNull);
      expect(payload!.url, 'https://home.dsh.example.com');
      expect(payload.pin, 'abcd1234');
    });

    test('纯 URL 带 ?pin=', () {
      final payload = parseScanPayload(
        'https://home.dsh.example.com/?pin=abcd1234',
      );
      expect(payload, isNotNull);
      expect(payload!.url, 'https://home.dsh.example.com');
      expect(payload.pin, 'abcd1234');
    });

    test('裸域名自动补 https', () {
      final payload = parseScanPayload('studio.dsh.example.com');
      expect(payload, isNotNull);
      expect(payload!.url, 'https://studio.dsh.example.com');
      expect(payload.pin, isNull);
    });

    test('JSON 形态', () {
      final payload = parseScanPayload(
        '{"url":"home.dsh.example.com","pin":"abcd1234","name":"家里"}',
      );
      expect(payload, isNotNull);
      expect(payload!.url, 'https://home.dsh.example.com');
      expect(payload.pin, 'abcd1234');
      expect(payload.name, '家里');
    });

    test('无法识别时返回 null', () {
      expect(parseScanPayload(''), isNull);
      expect(parseScanPayload('   '), isNull);
      expect(parseScanPayload('随便一段话'), isNull);
      expect(parseScanPayload('dshfrp://add'), isNull);
      expect(parseScanPayload('dshfrp://add?pin=abcd1234'), isNull);
      expect(parseScanPayload('{"pin":"abcd1234"}'), isNull);
    });

    test('PIN 里的空白被清掉，超长截到 64', () {
      final payload = parseScanPayload(
        'dshfrp://add?url=home.dsh.example.com&pin=ab%20cd1234',
      );
      expect(payload!.pin, 'abcd1234');

      final long = 'x' * 80;
      final truncated = parseScanPayload(
        'dshfrp://add?url=home.dsh.example.com&pin=$long',
      );
      expect(truncated!.pin!.length, 64);
    });
  });

  group('ScanPayload.toHost', () {
    test('name 缺省时用域名兜底', () {
      final payload = parseScanPayload('https://home.dsh.example.com');
      final host = payload!.toHost();
      expect(host.name, 'home.dsh.example.com');
      expect(host.url, 'https://home.dsh.example.com');
      expect(host.id, isNotEmpty);
    });

    test('fallbackName 优先于域名', () {
      final payload = parseScanPayload('https://home.dsh.example.com');
      final host = payload!.toHost(fallbackName: '家里');
      expect(host.name, '家里');
    });

    test('hostId 透传，pin 归一化', () {
      final payload = parseScanPayload(
        'dshfrp://add?url=home.dsh.example.com&pin=abcd1234&hostId=home-1a2b3c4d',
      );
      final host = payload!.toHost();
      expect(host.hostId, 'home-1a2b3c4d');
      expect(host.pin, 'abcd1234');
      expect(host.url, 'https://home.dsh.example.com');
      expect(host, isA<Host>());
    });
  });
}
