import 'package:dsh_frp_app/models/host.dart';
import 'package:dsh_frp_app/services/scan_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('normalizeUrl', () {
    test('空输入返回空串', () {
      expect(normalizeUrl(''), '');
      expect(normalizeUrl('   '), '');
    });

    test('缺少 scheme 时补 https', () {
      expect(
        normalizeUrl('home.dsh.example.com'),
        'https://home.dsh.example.com',
      );
      expect(
        normalizeUrl('//studio.dsh.example.com'),
        'https://studio.dsh.example.com',
      );
    });

    test('去掉 path / query / fragment，host 转小写', () {
      expect(
        normalizeUrl('https://Home.DSH.example.com/some/path?x=1#frag'),
        'https://home.dsh.example.com',
      );
    });

    test('去尾斜杠与默认端口', () {
      expect(
        normalizeUrl('https://home.dsh.example.com/'),
        'https://home.dsh.example.com',
      );
      expect(
        normalizeUrl('http://home.dsh.example.com:80/'),
        'http://home.dsh.example.com',
      );
      expect(
        normalizeUrl('https://home.dsh.example.com:443'),
        'https://home.dsh.example.com',
      );
    });

    test('保留非默认端口', () {
      expect(
        normalizeUrl('https://home.dsh.example.com:8443/abc'),
        'https://home.dsh.example.com:8443',
      );
    });

    test('非 http(s) scheme 换成 https', () {
      expect(
        normalizeUrl('ftp://home.dsh.example.com'),
        'https://home.dsh.example.com',
      );
    });

    test('含空白字符视为非法', () {
      expect(normalizeUrl('home dsh.example.com'), '');
      expect(normalizeUrl('https://home.dsh.example.com /x'), '');
    });

    test('没有 host 的字符串返回空串', () {
      expect(normalizeUrl('https://'), '');
      expect(normalizeUrl('http:///'), '');
    });
  });

  group('Host JSON 往返', () {
    test('toJson / fromJson 保持一致', () {
      final host = Host.create(
        name: '家里',
        url: 'https://home.dsh.example.com/',
        pin: 'abcd1234',
        hostId: 'home-1a2b3c4d',
      );
      final restored = Host.fromJson(host.toJson());

      expect(restored.id, host.id);
      expect(restored.name, '家里');
      expect(restored.url, 'https://home.dsh.example.com');
      expect(restored.pin, 'abcd1234');
      expect(restored.hostId, 'home-1a2b3c4d');
      expect(restored, host);
    });

    test('字段缺失时容错', () {
      final host = Host.fromJson(<String, dynamic>{
        'name': '工作室',
        'url': 'studio.dsh.example.com',
      });
      expect(host.id, '');
      expect(host.url, 'https://studio.dsh.example.com');
      expect(host.pin, '');
      expect(host.lastOk, isNull);
      expect(host.lastSeenAt, isNull);
    });

    test('lastOk / lastSeenAt 往返', () {
      final host = Host.create(
        name: '家里',
        url: 'home.dsh.example.com',
      ).withProbe(online: true, nowMillis: 1700000000000);
      final restored = Host.fromJson(host.toJson());
      expect(restored.lastOk, isTrue);
      expect(restored.lastSeenAt, 1700000000000);
    });
  });

  group('Host 派生字段', () {
    test('webEntryUrl 带 PIN 时拼 ?pin= 并编码', () {
      const host = Host(
        id: 'h1',
        name: '家里',
        url: 'https://home.dsh.example.com',
        pin: 'ab cd&12',
      );
      expect(
        host.webEntryUrl,
        'https://home.dsh.example.com/?pin=ab+cd%2612',
      );
    });

    test('无 PIN 时 webEntryUrl 就是根地址', () {
      const host = Host(
        id: 'h1',
        name: '家里',
        url: 'https://home.dsh.example.com',
      );
      expect(host.webEntryUrl, 'https://home.dsh.example.com');
    });

    test('displayHost 带端口', () {
      const host = Host(
        id: 'h1',
        name: '家里',
        url: 'https://home.dsh.example.com:8443',
      );
      expect(host.displayHost, 'home.dsh.example.com:8443');
    });

    test('deepLink 可被 parseScanPayload 还原', () {
      const host = Host(
        id: 'h1',
        name: '家里',
        url: 'https://home.dsh.example.com',
        pin: 'abcd1234',
        hostId: 'home-1a2b3c4d',
      );
      final payload = parseScanPayload(host.deepLink);
      expect(payload, isNotNull);
      expect(payload!.url, host.url);
      expect(payload.pin, host.pin);
      expect(payload.name, host.name);
      expect(payload.hostId, host.hostId);
    });

    test('isExample 识别预置示例主机', () {
      const example = Host(
        id: 'example-home',
        name: '家里（示例）',
        url: 'https://home.dsh.example.com',
      );
      expect(example.isExample, isTrue);
      expect(
        Host.create(name: 'x', url: 'https://x.dsh.example.com').isExample,
        isFalse,
      );
    });
  });

  group('withProbe', () {
    test('在线时刷新 lastSeenAt，离线时保留', () {
      final host = Host.create(name: 'a', url: 'https://a.dsh.example.com');
      final online = host.withProbe(online: true, nowMillis: 1000);
      expect(online.lastOk, isTrue);
      expect(online.lastSeenAt, 1000);

      final offline = online.withProbe(online: false, nowMillis: 2000);
      expect(offline.lastOk, isFalse);
      expect(offline.lastSeenAt, 1000);
    });
  });
}
