import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_frp_app/models/host.dart';
import 'package:dsh_frp_app/models/host_event.dart';
import 'package:dsh_frp_app/models/prompt_image.dart';
import 'package:dsh_frp_app/models/session_event.dart';
import 'package:dsh_frp_app/models/session_summary.dart';
import 'package:dsh_frp_app/screens/session_chat_screen.dart';
import 'package:dsh_frp_app/services/dsh_remote.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_frp_app/theme/app_icons.dart';

const Host _host = Host(
  id: 'host-img',
  name: '测试网关',
  url: 'https://gw.example.com',
  pin: '1234',
);

const SessionSummary _session = SessionSummary(
  sessionId: 'session-img',
  title: '图片会话',
  cwd: r'D:\Ai-Project\dsh-frp-pocket',
);

/// 1×1 透明 PNG：真实字节，预览行里 `Image.memory` 能正常解码。
final Uint8List _tinyPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
  'AAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

/// 只关心「图片有没有跟着 prompt 发出去」的假件。
class _ImageRemote extends DshRemote {
  _ImageRemote() : super(host: _host);

  final StreamController<DshStreamFrame> frames =
      StreamController<DshStreamFrame>.broadcast();
  final StreamController<DshHostEvent> hostEvents =
      StreamController<DshHostEvent>.broadcast();
  final StreamController<DshLinkState> states =
      StreamController<DshLinkState>.broadcast();

  /// 每次 `prompt` 的实参：文本 + 图片张数。
  final List<({String text, int images})> prompts =
      <({String text, int images})>[];

  /// 每次 `cachedAttachment` 的 attachmentId（历史图片取字节）。
  final List<String> attachments = <String>[];

  @override
  DshLinkState get linkState => DshLinkState.online;

  @override
  Stream<DshLinkState> get linkStates => states.stream;

  @override
  void reconnectNow() {}

  @override
  Stream<DshStreamFrame> followSession(String sessionId, {int? maxMessages}) =>
      frames.stream;

  @override
  Stream<DshHostEvent> followEvents() => hostEvents.stream;

  @override
  Future<SessionHistory> page(
    String sessionId, {
    required int throughSeq,
    int? beforeSeq,
    int maxMessages = 20,
  }) async =>
      const SessionHistory(
        cursor: 1,
        records: <SessionLogEvent>[],
        hasMore: false,
      );

  @override
  Future<String> prompt(
    String sessionId,
    String text, {
    String? requestId,
    List<PromptImage> images = const <PromptImage>[],
  }) async {
    prompts.add((text: text, images: images.length));
    return requestId ?? 'req-${prompts.length}';
  }

  @override
  Future<Uint8List> cachedAttachment(
    String sessionId, {
    required String attachmentId,
    String? mediaType,
    int? bytes,
    int? width,
    int? height,
    String? name,
  }) async {
    attachments.add(attachmentId);
    return _tinyPng;
  }

  @override
  Future<void> cancel(String sessionId) async {}

  Future<void> close() async {
    await states.close();
    await frames.close();
    await hostEvents.close();
  }
}

Future<_ImageRemote> _pumpChat(
  WidgetTester tester, {
  Future<PromptImage?> Function()? pickImage,
}) async {
  final remote = _ImageRemote();
  await tester.pumpWidget(
    MaterialApp(
      home: SessionChatScreen(
        host: _host,
        session: _session,
        remote: remote,
        pickImage: pickImage,
        snapshotTimeout: Duration.zero,
      ),
    ),
  );
  remote.frames.add(
    const DshStreamFrame(kind: DshFrameKind.snapshot, asOfSeq: 1),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
  return remote;
}

Future<void> _disposeChat(WidgetTester tester, _ImageRemote remote) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
  await remote.close();
}

/// 注入一张固定的图：测试不碰真实相册，走的是同一个 seam。
Future<PromptImage?> _pickOne() async => PromptImage.fromBytes(
  _tinyPng,
  mediaType: 'image/png',
  name: 'probe.png',
);

void main() {
  testWidgets('e1 输入区有选图按钮', (tester) async {
    final remote = await _pumpChat(tester);

    expect(find.byKey(const ValueKey<String>('chat-attach')), findsOneWidget);
    expect(find.byIcon(AppIcons.image), findsOneWidget);

    await _disposeChat(tester, remote);
  });

  testWidgets('e2 选中图片后出现缩略图，点关闭按钮可以移除', (tester) async {
    final remote = await _pumpChat(tester, pickImage: _pickOne);

    await tester.tap(find.byKey(const ValueKey<String>('chat-attach')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    final remove = find.byKey(const ValueKey<String>('attach-remove.0'));
    expect(remove, findsOneWidget);

    await tester.tap(remove);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    expect(find.byKey(const ValueKey<String>('attach-remove.0')), findsNothing);

    await _disposeChat(tester, remote);
  });

  testWidgets('e3 只有图没有文字时也能发，prompt 收到 1 张图且 text 为空', (tester) async {
    final remote = await _pumpChat(tester, pickImage: _pickOne);

    await tester.tap(find.byKey(const ValueKey<String>('chat-attach')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    // 文本为空、只有图：发送按钮必须是可点的。
    final send = tester.widget<IconButton>(
      find.byKey(const Key('chat-send')),
    );
    expect(send.onPressed, isNotNull);

    await tester.tap(find.byKey(const Key('chat-send')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    expect(remote.prompts, hasLength(1));
    expect(remote.prompts.single.text, '');
    expect(remote.prompts.single.images, 1);
    // 发完输入区清空。
    expect(find.byKey(const ValueKey<String>('attach-remove.0')), findsNothing);

    await _disposeChat(tester, remote);
  });

  testWidgets('e4 历史里只有 attachmentId 的图片会去服务端取字节', (tester) async {
    final remote = await _pumpChat(tester);

    remote.frames.add(
      DshStreamFrame(
        kind: DshFrameKind.event,
        event: SessionLogEvent(
          type: 'user/message',
          seq: 5,
          time: DateTime.fromMillisecondsSinceEpoch(1794483452521),
          data: <String, Object?>{
            'message': <String, Object?>{
              'role': 'user',
              'source': <String, Object?>{'kind': 'user'},
              'content': <Object?>[
                <String, Object?>{
                  'type': 'image',
                  'attachment': <String, Object?>{
                    'attachmentId': 'sha256:c414',
                    'mediaType': 'image/png',
                    'width': 1,
                    'height': 1,
                    'bytes': 70,
                    'name': 'probe.png',
                  },
                },
              ],
            },
          },
        ),
      ),
    );
    // 事件到达后的重建被合并到下一帧（见 `_scheduleFlush`），多走一帧。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump();

    expect(remote.attachments, <String>['sha256:c414']);

    await _disposeChat(tester, remote);
  });
}
