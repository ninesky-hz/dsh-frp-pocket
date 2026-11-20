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
import 'package:dsh_frp_app/widgets/chat/chat_bubbles.dart';
import 'package:dsh_frp_app/widgets/chat/image_viewer.dart';

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

  /// 工具结果的线上形状：`data.message` 里 role=tool，图片是 content 里的
  /// `{type:'image', attachment:{…}}` part（PC 端就是在工具这一行下面显示的）。
  SessionLogEvent toolResult(String attachmentId, {int seq = 7}) =>
      SessionLogEvent(
        type: 'tool/result',
        seq: seq,
        time: DateTime.fromMillisecondsSinceEpoch(1794483452600),
        data: <String, Object?>{
          'turn': 1,
          'step': 1,
          'message': <String, Object?>{
            'role': 'tool',
            'toolCallId': 'call_1',
            'content': <Object?>[
              <String, Object?>{
                'type': 'text',
                'text': '<path>D:\\out\\shot.png</path>\n<type>image</type>',
              },
              <String, Object?>{
                'type': 'image',
                'attachment': <String, Object?>{
                  'attachmentId': attachmentId,
                  'mediaType': 'image/png',
                  'width': 1200,
                  'height': 700,
                  'bytes': 70,
                  'name': 'shot.png',
                },
              },
            ],
            'isError': false,
          },
        },
      );

  testWidgets('e5 PC 端工具生成的图，手机端也能看见（挂在那条助手消息上）', (tester) async {
    final remote = await _pumpChat(tester);

    // 先来一条只调了工具、没写正文的助手消息。
    remote.frames.add(
      DshStreamFrame(
        kind: DshFrameKind.event,
        event: SessionLogEvent(
          type: 'assistant/message',
          seq: 6,
          data: <String, Object?>{
            'turn': 1,
            'step': 1,
            'message': <String, Object?>{
              'content': <Object?>[
                <String, Object?>{
                  'type': 'tool-call',
                  'id': 'call_1',
                  'name': 'read_image',
                  'arguments': '{"path":"D:\\\\out\\\\shot.png"}',
                },
              ],
            },
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    expect(find.byType(ChatImageTile), findsNothing, reason: '工具还没跑完，先没有图');

    remote.frames.add(
      DshStreamFrame(
        kind: DshFrameKind.event,
        event: toolResult('sha256:shot'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump();

    expect(find.byType(ChatImageTile), findsOneWidget);
    expect(remote.attachments, contains('sha256:shot'));

    await _disposeChat(tester, remote);
  });

  testWidgets('e6 同一条工具结果补投两次，只显示一张图', (tester) async {
    final remote = await _pumpChat(tester);

    remote.frames.add(
      DshStreamFrame(
        kind: DshFrameKind.event,
        event: SessionLogEvent(
          type: 'assistant/message',
          seq: 6,
          data: <String, Object?>{
            'message': <String, Object?>{'content': <Object?>[]},
          },
        ),
      ),
    );
    for (var i = 0; i < 2; i++) {
      remote.frames.add(
        DshStreamFrame(
          kind: DshFrameKind.event,
          event: toolResult('sha256:shot', seq: 7 + i),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(find.byType(ChatImageTile), findsOneWidget);

    await _disposeChat(tester, remote);
  });

  testWidgets('e7 点待发缩略图能放大看，关掉回到输入区', (tester) async {
    final remote = await _pumpChat(tester, pickImage: _pickOne);

    await tester.tap(find.byKey(const ValueKey<String>('chat-attach')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    // 56px 的缩略图分不清是哪张截图，点一下必须能放大。
    await tester.tap(find.byKey(const ValueKey<String>('attach-open.0')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byType(ImageViewerPage), findsOneWidget);
    // 单张不显示页码：1 / 1 只是噪音。
    expect(
      find.byKey(const ValueKey<String>('image-viewer.counter')),
      findsNothing,
    );

    await tester.tap(find.byTooltip('关闭'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byType(ImageViewerPage), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('attach-remove.0')),
      findsOneWidget,
      reason: '看完图回来，待发的图还在',
    );

    await _disposeChat(tester, remote);
  });

  testWidgets('e8 点第二张打开的就是第二张，还能按上一张/下一张翻', (tester) async {
    final remote = await _pumpChat(tester, pickImage: _pickOne);

    for (var i = 0; i < 2; i++) {
      await tester.tap(find.byKey(const ValueKey<String>('chat-attach')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
    }

    // 点第 2 张：索引要按「有字节的那些图」重算，不能直接用缩略图下标。
    await tester.tap(find.byKey(const ValueKey<String>('attach-open.1')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final counter = find.byKey(const ValueKey<String>('image-viewer.counter'));
    expect(tester.widget<Text>(counter).data, '2 / 2');

    // 放大层会吞掉横向拖动，所以要有明确的上一张/下一张。
    await tester.tap(find.byKey(const ValueKey<String>('image-viewer.prev')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.widget<Text>(counter).data, '1 / 2');

    await tester.tap(find.byKey(const ValueKey<String>('image-viewer.next')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.widget<Text>(counter).data, '2 / 2');

    // 到最后一张，下一张变灰不许点。
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const ValueKey<String>('image-viewer.next')),
          )
          .onPressed,
      isNull,
    );

    await _disposeChat(tester, remote);
  });

  testWidgets('e9 删除角标够大够点，同时不挡住缩略图中心的「看大图」', (tester) async {
    final remote = await _pumpChat(tester, pickImage: _pickOne);

    await tester.tap(find.byKey(const ValueKey<String>('chat-attach')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    final remove = find.byKey(const ValueKey<String>('attach-remove.0'));
    final removeSize = tester.getSize(remove);
    // 之前在 56px 缩略图上只能给 22px，手指点不准——这条把「够大」钉住。
    expect(removeSize.width, greaterThanOrEqualTo(kAttachRemoveHit));
    expect(removeSize.height, greaterThanOrEqualTo(kAttachRemoveHit));
    expect(kAttachRemoveHit, greaterThanOrEqualTo(30));

    // 命中区不能盖住缩略图中心：那块是「点开看大图」的地方。
    // 画出来的圆钮要小（不然压在图上一大坨），能点的那圈要大。
    final dot = tester.getSize(
      find.byKey(const ValueKey<String>('attach-remove-dot.0')),
    );
    expect(dot.width, kAttachRemoveVisual);
    expect(dot.height, kAttachRemoveVisual);
    expect(dot.width, lessThan(kAttachRemoveHit));
    expect(kAttachRemoveVisual, lessThanOrEqualTo(22));

    final removeRect = tester.getRect(remove);
    final openRect = tester.getRect(
      find.byKey(const ValueKey<String>('attach-open.0')),
    );
    expect(openRect.size.width, greaterThanOrEqualTo(kAttachThumbSize));
    expect(
      removeRect.contains(openRect.center),
      isFalse,
      reason: '删除角标盖到缩略图中心，点图放大就会变成删图',
    );

    // 角标落在右上角外侧，且仍在整行的高度内（探出去的会被列表剪掉）。
    expect(removeRect.left, greaterThan(openRect.left));
    expect(removeRect.center.dy, lessThan(openRect.top + 24));

    await tester.tap(remove);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.byKey(const ValueKey<String>('attach-remove.0')), findsNothing);
    expect(find.byKey(const ValueKey<String>('attach-open.0')), findsNothing);

    await _disposeChat(tester, remote);
  });
}
