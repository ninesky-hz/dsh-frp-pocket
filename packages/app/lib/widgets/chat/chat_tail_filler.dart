import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// 短会话的尾部空白：让第一条消息顶上视口顶边。
///
/// 会话列表是 `center` + `anchor: 1`：负方向（历史段）从底边往上铺，正方向
/// （当前段）从底边往下长。内容不满一屏时整段贴着底边，上方空出一大片，
/// 而且没有滚动余量 —— 用户往回拉也拉不动，第一条消息永远到不了顶部。
///
/// 想让它贴顶，总内容高度就得正好等于视口高度：尾部补
/// `V - (负方向已有 + 正方向已有)`。负方向那段高度 `SliverFillRemaining`
/// 看不见（它只有 `precedingScrollExtent`，那是同方向的累计），所以这里自己
/// 算：尾部 sliver 布局时负方向早就布局完了（`RenderViewport._attemptLayout`
/// 先走 `childBefore(center)`，再走 center 与 `childAfter`），直接从兄弟
/// sliver 的 `geometry.scrollExtent` 求和就拿到。
///
/// 只在「所有行都建出来了」时生效。行没建全说明内容本来就超过一屏，这时
/// lazy 列表报的 extent 还是估算值，照它补空白会把空白加到真实内容下面；
/// 这种时候返回 0，视觉完全保持原来的「最新一条贴底边」。
class ChatTailFiller extends LeafRenderObjectWidget {
  const ChatTailFiller({
    super.key,
    required this.centerKey,
    required this.rowCount,
  });

  /// 会话列表的 `center` sliver（`CustomScrollView.center`）。
  final GlobalKey centerKey;

  /// 行总数（历史段 + 当前段），用来判断是不是所有行都建出来了。
  final int rowCount;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      ChatTailFillerRender(centerKey: centerKey, rowCount: rowCount);

  @override
  void updateRenderObject(BuildContext context, ChatTailFillerRender renderObject) {
    if (!identical(renderObject.centerKey, centerKey)) {
      renderObject.centerKey = centerKey;
      renderObject.markNeedsLayout();
    }
    if (renderObject.rowCount != rowCount) {
      renderObject.rowCount = rowCount;
      renderObject.markNeedsLayout();
    }
  }
}

class ChatTailFillerRender extends RenderSliver {
  ChatTailFillerRender({required this.centerKey, required this.rowCount});

  /// 会话列表的 `center` sliver 的 `GlobalKey`。
  GlobalKey centerKey;

  /// 行总数（历史段 + 当前段）。
  int rowCount;

  @override
  void performLayout() {
    final double fill = _tailFill();
    // 只占滚动范围、不画东西：内容贴不贴顶由滚动上限决定，绘制交给别人。
    geometry = SliverGeometry(
      scrollExtent: fill,
      paintExtent: 0,
      maxPaintExtent: fill,
    );
  }

  /// 尾部要补的空白高度；0 表示内容本来就超过一屏，不加。
  double _tailFill() {
    final RenderObject? viewport = parent;
    final RenderObject? center = centerKey.currentContext?.findRenderObject();
    if (viewport == null || center == null) return 0;

    var before = 0.0; // 负方向（center 之前）已经占掉的高度
    var builtRows = 0; // 已经建出来的行数
    var passedCenter = false;
    RenderSliver? centerSliver;
    viewport.visitChildren((RenderObject child) {
      if (child is! RenderSliver) return;
      if (identical(child, center)) {
        passedCenter = true;
        centerSliver = child;
        return;
      }
      if (passedCenter) return;
      before += child.geometry?.scrollExtent ?? 0;
      builtRows += _builtRowCount(child);
    });
    builtRows += _builtRowCount(centerSliver);

    // 有行没建出来：内容超一屏，保持「最新一条贴底边」。
    if (builtRows != rowCount) return 0;

    final double fill =
        constraints.viewportMainAxisExtent -
        before -
        constraints.precedingScrollExtent;
    return fill > 0 ? fill : 0;
  }

  /// sliver 里已经建出来的行数（只对列表型 sliver 有意义）。
  int _builtRowCount(RenderSliver? sliver) {
    if (sliver is! RenderSliverMultiBoxAdaptor) return 0;
    var count = 0;
    for (
      RenderBox? child = sliver.firstChild;
      child != null;
      child = sliver.childAfter(child)
    ) {
      count += 1;
    }
    return count;
  }
}
