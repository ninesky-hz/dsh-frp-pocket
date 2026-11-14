import 'package:flutter/widgets.dart';

// 聊天列表自己的滚动控制器。
//
// 两个诉求：插入历史时视口不动、第一帧就落到底，而且都要在**布局阶段**算清，
// 不能靠 post-frame 回调（那时已经晚了一帧，用户会看见跳动）。

/// 让「插入历史后视口不动」和「第一帧就落到底」都在布局阶段一次算清。
///
/// `applyContentDimensions` 里 `correctBy(correction)` 之后返回 `false`：Flutter
/// 会用同一个 layout 再问一次，不会把这次修正当成滚动事件外传，也就不会打断
/// 正在进行的拖拽或惯性。
class ChatScrollController extends ScrollController {
  ChatScrollController({
    required this.prependCorrection,
    required this.startsAtBottom,
  });

  /// 同一行在新旧两帧里的 sliver 坐标差；正数表示内容整体下沉了这么多像素。
  final double Function() prependCorrection;

  /// 视口此刻是否停在底部（extentAfter 小于阈值）。为真时每次内容尺寸变化
  /// 都会在布局阶段把像素校正到底边，不会作为滚动事件外传。
  final bool Function() startsAtBottom;

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) {
    return ChatScrollPosition(
      prependCorrection: prependCorrection,
      startsAtBottom: startsAtBottom,
      physics: physics,
      context: context,
      initialPixels: initialScrollOffset,
      keepScrollOffset: keepScrollOffset,
      oldPosition: oldPosition,
      debugLabel: debugLabel,
    );
  }
}

class ChatScrollPosition extends ScrollPositionWithSingleContext {
  ChatScrollPosition({
    required this.prependCorrection,
    required this.startsAtBottom,
    required super.physics,
    required super.context,
    super.initialPixels,
    super.keepScrollOffset,
    super.oldPosition,
    super.debugLabel,
  });

  final double Function() prependCorrection;
  final bool Function() startsAtBottom;

  /// 亚像素级别的差异不值得再重排一帧。
  static const double _tolerance = 1e-9;

  @override
  bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    final correction = prependCorrection();
    if (correction.abs() > _tolerance) {
      // 同一帧里重试：位置和像素在同一帧对齐，用户看不到中间状态。
      correctBy(correction);
      return false;
    }
    // 手指还按在屏幕上（或者刚甩出去、还在惯性里）：这时候把像素拽回底边，
    // 等于每一帧都把用户拖出来的那点位移抹掉 —— 小步往上拉会「卡住」，
    // 得猛地甩一下、单帧位移超过贴底阈值才跑得掉。
    //
    // 所以贴底只在「没有手势在跑」时生效：内容自己长大（流式、新消息）时
    // 照旧跟到底边，用户主动往上翻时一秒都不拦。
    final holding =
        activity is DragScrollActivity || activity is BallisticScrollActivity;
    if (!holding &&
        startsAtBottom() &&
        (pixels - maxScrollExtent).abs() > _tolerance) {
      // 停在底部时，任何内容尺寸变化都要在**这一帧的布局里**跟到底边。
      // 只靠 post-frame 回调量 maxScrollExtent 会用到旧值：新消息那一行
      // 还没排完就跳，跳完 max 又长大，于是停在半路（少 48px）。
      correctPixels(maxScrollExtent);
      return false;
    }
    return super.applyContentDimensions(minScrollExtent, maxScrollExtent);
  }
}
