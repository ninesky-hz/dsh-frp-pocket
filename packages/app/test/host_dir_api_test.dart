import 'package:dsh_frp_app/models/host.dart';
import 'package:dsh_frp_app/services/dsh_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const Host _host = Host(
  id: 'h1',
  name: '家里',
  url: 'https://home.dsh.example.com',
  pin: 'abcd1234',
);

http.Response _loginEntry() => http.Response(
  '',
  303,
  headers: <String, String>{'set-cookie': 'frp_auth=token-one; Path=/; HttpOnly'},
);

http.Response _rootPage() => http.Response(
  '<html>${'x' * (kHandshakeMinBodyBytes + 10)}</html>',
  200,
  headers: <String, String>{
    'content-type': 'text/html; charset=utf-8',
    'set-cookie': 'dsh-auth-pn3CJR=token-two; Path=/',
  },
);

http.Response _json(String body, [int statusCode = 200]) => http.Response(
  body,
  statusCode,
  headers: <String, String>{'content-type': 'application/json; charset=utf-8'},
);

class _Harness {
  _Harness(this._action);

  final http.Response Function(http.Request request) _action;
  final List<http.Request> actions = <http.Request>[];

  late final MockClient client = MockClient((request) async {
    final path = request.url.path;
    if (path == '/' && request.url.queryParameters.containsKey('pin')) {
      return _loginEntry();
    }
    if (path == '/') return _rootPage();
    actions.add(request);
    return _action(request);
  });
}

const String _listingBody =
    '{"ok":true,"path":"D:\\\\Ai-Project","parent":"D:\\\\",'
    '"home":"C:\\\\Users\\\\Chen","roots":[{"name":"D:","path":"D:\\\\"}],'
    '"entries":[{"name":"demo","path":"D:\\\\Ai-Project\\\\demo","dir":true,"hidden":false},'
    '{"name":"note.txt","path":"D:\\\\Ai-Project\\\\note.txt","dir":false,"hidden":false}],'
    '"truncated":false}';

void main() {
  test('listHostDir 打网关端点：POST + cookie + 只读不需要动作头', () async {
    final harness = _Harness((request) => _json(_listingBody));
    final api = DshApi(client: harness.client);
    addTearDown(api.dispose);

    final listing = await api.listHostDir(_host, r'D:\Ai-Project');

    final request = harness.actions.single;
    expect(request.method, 'POST');
    expect(request.url.path, kFsListPath);
    expect(request.headers[kActionHeader], isNull);
    expect(request.headers['cookie'], contains('frp_auth=token-one'));
    expect(request.headers['cookie'], contains('dsh-auth-pn3CJR=token-two'));
    expect(request.body, contains(r'D:\\Ai-Project'));

    expect(listing.path, r'D:\Ai-Project');
    expect(listing.entries.map((entry) => entry.name), <String>[
      'demo',
      'note.txt',
    ]);
    expect(listing.entries.first.dir, isTrue);
  });

  test('listHostDir：路径为空时不发 path，让宿主用家目录', () async {
    final harness = _Harness((request) => _json(_listingBody));
    final api = DshApi(client: harness.client);
    addTearDown(api.dispose);

    await api.listHostDir(_host, '   ');
    expect(harness.actions.single.body, isNot(contains('"path"')));
  });

  test('listHostDir 带 showHidden', () async {
    final harness = _Harness((request) => _json(_listingBody));
    final api = DshApi(client: harness.client);
    addTearDown(api.dispose);

    await api.listHostDir(_host, r'D:\Ai-Project', showHidden: true);
    expect(harness.actions.single.body, contains('"showHidden":true'));
  });

  test('makeHostDir 带 fs.mkdir 动作头并解出新路径', () async {
    final harness = _Harness(
      (request) => _json(r'{"ok":true,"path":"D:\\Ai-Project\\demo2"}'),
    );
    final api = DshApi(client: harness.client);
    addTearDown(api.dispose);

    final created = await api.makeHostDir(
      _host,
      path: r'D:\Ai-Project',
      name: 'demo2',
    );

    final request = harness.actions.single;
    expect(request.url.path, kFsMkdirPath);
    expect(request.headers[kActionHeader], kActionFsMkdir);
    expect(request.body, contains('"name":"demo2"'));
    expect(created, r'D:\Ai-Project\demo2');
  });

  test('网关错误码原样透出（not-found 404 / exists 409）', () async {
    final missing = _Harness(
      (request) => _json('{"ok":false,"error":"not-found"}', 404),
    );
    final api = DshApi(client: missing.client);
    addTearDown(api.dispose);
    await expectLater(
      api.listHostDir(_host, r'D:\nope'),
      throwsA(
        isA<DshApiException>()
            .having((e) => e.code, 'code', 'not-found')
            .having((e) => e.statusCode, 'statusCode', 404),
      ),
    );

    final exists = _Harness(
      (request) => _json('{"ok":false,"error":"exists"}', 409),
    );
    final api2 = DshApi(client: exists.client);
    addTearDown(api2.dispose);
    await expectLater(
      api2.makeHostDir(_host, path: r'D:\Ai-Project', name: 'demo'),
      throwsA(
        isA<DshApiException>().having((e) => e.code, 'code', 'exists'),
      ),
    );
  });

  test('401 先重新握手再重试，用户看不到 401', () async {
    var calls = 0;
    final harness = _Harness((request) {
      calls += 1;
      if (calls == 1) return _json('{"ok":false,"error":"unauthorized"}', 401);
      return _json(_listingBody);
    });
    final api = DshApi(client: harness.client);
    addTearDown(api.dispose);

    final listing = await api.listHostDir(_host, r'D:\Ai-Project');
    expect(listing.path, r'D:\Ai-Project');
    expect(harness.actions, hasLength(2));
  });
}
