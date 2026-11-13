import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../theme/app_icons.dart';

/// 全屏看大图。
///
/// 为什么要有：气泡里的图被 `maxHeight: 260` 压成缩略图，一张截图里的按钮文字
/// 在手机上根本认不出，而放大只能靠系统截图再进相册放大——等于没有。
///
/// 这里不引第三方看图库：`InteractiveViewer` 自带双指缩放和拖动，缺的只是
/// 双击放大与关闭入口，几十行就够。
Future<void> showImageViewer(
  BuildContext context, {
  required Uint8List bytes,
  String? label,
}) {
  return Navigator.of(context).push<void>(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 180),
      reverseTransitionDuration: const Duration(milliseconds: 140),
      pageBuilder: (context, animation, secondaryAnimation) =>
          ImageViewerPage(bytes: bytes, label: label),
      transitionsBuilder: (context, animation, secondaryAnimation, child) =>
          FadeTransition(opacity: animation, child: child),
    ),
  );
}

class ImageViewerPage extends StatefulWidget {
  const ImageViewerPage({super.key, required this.bytes, this.label});

  final Uint8List bytes;

  /// 文件名（有就显示在底部；没有也不占位）。
  final String? label;

  @override
  State<ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends State<ImageViewerPage>
    with SingleTickerProviderStateMixin {
  final TransformationController _transform = TransformationController();
  late final AnimationController _zoomTicker = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  );
  Animation<Matrix4>? _zoomTween;
  Offset? _doubleTapAt;

  /// 放大到这个倍数就够看截图里的字了；再大只是糊。
  static const double _doubleTapScale = 2.5;

  @override
  void initState() {
    super.initState();
    _zoomTicker.addListener(() {
      final tween = _zoomTween;
      if (tween != null) _transform.value = tween.value;
    });
  }

  @override
  void dispose() {
    _zoomTicker.dispose();
    _transform.dispose();
    super.dispose();
  }

  double get _scale => _transform.value.getMaxScaleOnAxis();

  void _rememberDoubleTap(TapDownDetails details) {
    _doubleTapAt = details.localPosition;
  }

  /// 双击：正放大着就还原，否则以落点为焦点放大。
  ///
  /// 焦点很重要：双击在图片左上角却把中心放大，用户还得自己把图拖回来。
  void _toggleZoom() {
    final Matrix4 target;
    if (_scale > 1.05) {
      target = Matrix4.identity();
    } else {
      final focal = _doubleTapAt ?? Offset.zero;
      target = Matrix4.identity()
        ..translateByDouble(focal.dx, focal.dy, 0, 1)
        ..scaleByDouble(_doubleTapScale, _doubleTapScale, 1, 1)
        ..translateByDouble(-focal.dx, -focal.dy, 0, 1);
    }
    _zoomTween = Matrix4Tween(
      begin: _transform.value.clone(),
      end: target,
    ).animate(CurvedAnimation(parent: _zoomTicker, curve: Curves.easeOutCubic));
    _zoomTicker
      ..reset()
      ..forward();
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.label?.trim() ?? '';
    return Scaffold(
      backgroundColor: Colors.black.withValues(alpha: 0.94),
      body: Stack(
        children: <Widget>[
          Positioned.fill(
            child: GestureDetector(
              // 只认双击：单击留给关闭按钮和返回手势，免得看图时误触退出。
              onDoubleTapDown: _rememberDoubleTap,
              onDoubleTap: _toggleZoom,
              child: InteractiveViewer(
                transformationController: _transform,
                minScale: 1,
                maxScale: 5,
                // 放大后允许拖到边角，否则边上的字永远看不全。
                boundaryMargin: const EdgeInsets.all(double.infinity),
                child: Center(
                  child: Image.memory(
                    widget.bytes,
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: IconButton(
                  tooltip: '关闭',
                  icon: const Icon(AppIcons.close),
                  color: Colors.white,
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.black.withValues(alpha: 0.35),
                  ),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ),
            ),
          ),
          if (label.isNotEmpty)
            SafeArea(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
