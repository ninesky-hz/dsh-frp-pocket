import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../theme/app_icons.dart';

/// 全屏看大图（单张）。
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
  return showImageViewerGallery(
    context,
    images: <Uint8List>[bytes],
    labels: <String?>[label],
  );
}

/// 全屏看图（一张或多张，左右翻）。
///
/// 多张的场合是「输入框上方那排待发图片」：挑了三四张截图，得挨张放大才能确认
/// 挑对没挑错，来回关掉再点下一张太别扭。翻页用 [PageView]，每一页各自独立缩放
/// ——上一页放大过不影响下一张。
Future<void> showImageViewerGallery(
  BuildContext context, {
  required List<Uint8List> images,
  List<String?>? labels,
  int initialIndex = 0,
}) {
  if (images.isEmpty) return Future<void>.value();
  final start = initialIndex.clamp(0, images.length - 1);
  return Navigator.of(context).push<void>(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 180),
      reverseTransitionDuration: const Duration(milliseconds: 140),
      pageBuilder: (context, animation, secondaryAnimation) => ImageViewerPage(
        images: images,
        labels: labels,
        initialIndex: start,
      ),
      transitionsBuilder: (context, animation, secondaryAnimation, child) =>
          FadeTransition(opacity: animation, child: child),
    ),
  );
}

class ImageViewerPage extends StatefulWidget {
  const ImageViewerPage({
    super.key,
    required this.images,
    this.labels,
    this.initialIndex = 0,
  });

  final List<Uint8List> images;

  /// 与 [images] 一一对应的文件名（有就显示在底部；没有也不占位）。
  final List<String?>? labels;
  final int initialIndex;

  @override
  State<ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends State<ImageViewerPage> {
  late final PageController _pages = PageController(
    initialPage: widget.initialIndex,
  );
  late int _index = widget.initialIndex;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  String? get _label {
    final labels = widget.labels;
    if (labels == null || _index < 0 || _index >= labels.length) return null;
    return labels[_index];
  }

  void _go(int index) {
    if (index < 0 || index >= widget.images.length) return;
    _pages.animateToPage(
      index,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final label = _label?.trim() ?? '';
    final total = widget.images.length;
    return Scaffold(
      backgroundColor: Colors.black.withValues(alpha: 0.94),
      body: Stack(
        children: <Widget>[
          Positioned.fill(
            child: PageView.builder(
              controller: _pages,
              itemCount: total,
              onPageChanged: (index) => setState(() => _index = index),
              itemBuilder: (context, index) =>
                  _ZoomPage(bytes: widget.images[index]),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (total > 1)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.35),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '${_index + 1} / $total',
                            key: const ValueKey<String>('image-viewer.counter'),
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                    IconButton(
                      tooltip: '关闭',
                      icon: const Icon(AppIcons.close),
                      color: Colors.white,
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.black.withValues(alpha: 0.35),
                      ),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (total > 1)
            SafeArea(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 48),
                  // 缩放层会吞掉横向拖动，靠甩手势翻页在放大后必然失效，
                  // 所以给一对明确的上一张/下一张。
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      _NavButton(
                        buttonKey: const ValueKey<String>('image-viewer.prev'),
                        icon: AppIcons.back,
                        tooltip: '上一张',
                        onPressed: _index > 0 ? () => _go(_index - 1) : null,
                      ),
                      const SizedBox(width: 12),
                      _NavButton(
                        buttonKey: const ValueKey<String>('image-viewer.next'),
                        icon: AppIcons.forward,
                        tooltip: '下一张',
                        onPressed: _index < total - 1
                            ? () => _go(_index + 1)
                            : null,
                      ),
                    ],
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

/// 一页：双指缩放 + 拖动，双击在原位放大/还原。
///
/// 每页各有一份 [TransformationController]：翻到下一张时从原始大小看起，
/// 不会继承上一张的缩放。
class _ZoomPage extends StatefulWidget {
  const _ZoomPage({required this.bytes});

  final Uint8List bytes;

  @override
  State<_ZoomPage> createState() => _ZoomPageState();
}

class _ZoomPageState extends State<_ZoomPage>
    with SingleTickerProviderStateMixin {
  final TransformationController _transform = TransformationController();
  late final AnimationController _zoomTicker = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  );
  Animation<Matrix4>? _zoomTween;
  Offset? _doubleTapAt;
  bool _zoomed = false;

  /// 当前这页的可视区域尺寸，双击放大时要靠它把位移夹回来。
  Size _viewport = Size.zero;

  /// 放大到这个倍数就够看截图里的字了；再大只是糊。
  static const double _doubleTapScale = 2.5;

  @override
  void initState() {
    super.initState();
    _zoomTicker.addListener(() {
      final tween = _zoomTween;
      if (tween != null) _transform.value = tween.value;
    });
    _transform.addListener(_onZoomChanged);
  }

  /// 放大之后才允许拖动。
  ///
  /// 不这么做的话，`InteractiveViewer` 连原始大小也吃横向拖动——多张图时
  /// 左右翻页会彻底失效（手势被它抢走）。
  void _onZoomChanged() {
    final zoomed = _scale > 1.01;
    if (zoomed == _zoomed) return;
    setState(() => _zoomed = zoomed);
  }

  @override
  void dispose() {
    _transform.removeListener(_onZoomChanged);
    _zoomTicker.dispose();
    _transform.dispose();
    super.dispose();
  }

  double get _scale => _transform.value.getMaxScaleOnAxis();

  void _rememberDoubleTap(TapDownDetails details) {
    _doubleTapAt = details.localPosition;
  }

  /// 以 [focal] 为中心放大到 [scale] 倍，并**把位移夹在图片范围内**。
  ///
  /// 只写 `translate → scale → translate` 那个经典写法会出问题：位移是自由量，
  /// 图片能被拖到屏幕外面无穷远（用户看到的就是「能一直往外移」）。
  /// 图铺满整页时（`BoxFit.contain` + `SizedBox.expand` 撑满），缩放后内容宽高是
  /// `viewport * scale`，要让视口始终被内容盖住，平移量只能落在
  /// `[viewport - viewport * scale, 0]` 这段里。
  Matrix4 _zoomAt(Offset focal, double scale) {
    final w = _viewport.width;
    final h = _viewport.height;
    if (scale <= 1 || w <= 0 || h <= 0) return Matrix4.identity();
    final maxX = w * (scale - 1);
    final maxY = h * (scale - 1);
    final tx = (w / 2 - scale * focal.dx).clamp(-maxX, 0.0);
    final ty = (h / 2 - scale * focal.dy).clamp(-maxY, 0.0);
    return Matrix4.identity()
      ..translateByDouble(tx, ty, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1);
  }

  /// 双击：正放大着就还原，否则以落点为焦点放大。
  ///
  /// 焦点很重要：双击在图片左上角却把中心放大，用户还得自己把图拖回来。
  void _toggleZoom() {
    final Matrix4 target;
    if (_scale > 1.05) {
      target = Matrix4.identity();
    } else {
      target = _zoomAt(_doubleTapAt ?? Offset.zero, _doubleTapScale);
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
    return LayoutBuilder(
      builder: (context, constraints) {
        _viewport = constraints.biggest;
        return GestureDetector(
          // 只认双击：单击留给关闭按钮和返回手势，免得看图时误触退出。
          onDoubleTapDown: _rememberDoubleTap,
          onDoubleTap: _toggleZoom,
          child: InteractiveViewer(
            transformationController: _transform,
            minScale: 1,
            maxScale: 5,
            // 没放大时不许拖：一来图本来就在居中的位置，二来拖动会被这层抢走，
            // 多张时左右翻页就废了。
            panEnabled: _zoomed,
            // 边距必须留 0。给 `double.infinity` 等于「随便拖多远都行」，
            // 图能被拖到屏幕外无穷远，这正是「可以无限往外面移」的来源。
            boundaryMargin: EdgeInsets.zero,
            // 撑满整页再 contain：这样内容盒就是视口大小，位移的边界能算准；
            // 交给 `Center` 自适应尺寸的话，边界跟着图片实际尺寸走，算出来会偏。
            child: SizedBox.expand(
              child: Image.memory(
                widget.bytes,
                fit: BoxFit.contain,
                gaplessPlayback: true,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 全屏看图时的上一张/下一张：半透明圆底，和关闭按钮同一套语言。
class _NavButton extends StatelessWidget {
  const _NavButton({
    required this.buttonKey,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final Key buttonKey;
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return IconButton(
      key: buttonKey,
      tooltip: tooltip,
      icon: Icon(icon),
      iconSize: 20,
      onPressed: onPressed,
      color: enabled ? Colors.white : Colors.white24,
      disabledColor: Colors.white24,
      style: IconButton.styleFrom(
        backgroundColor: Colors.black.withValues(alpha: 0.35),
        minimumSize: const Size(40, 40),
      ),
    );
  }
}
