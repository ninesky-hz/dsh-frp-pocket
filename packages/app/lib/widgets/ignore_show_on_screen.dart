import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// 把子树里发起的「把我滚到可见处」（`showOnScreen`）就地截住。
///
/// `SelectableText` 每次落点、选区变化都会请求祖先把光标露出来，这个请求会一路
/// 冒泡到最近的 `Scrollable`，最后变成 `ensureVisible`。聊天列表里一条消息常常
/// 比整屏还高，`ensureVisible` 满足不了「整段可见」，就会把整条列表拽到底 ——
/// 表现就是长按上面的一段话，页面直接掉到输入框那一头，根本选不到想选的句子。
///
/// 选字的时候视口本来就不该自己动，所以在这里把请求吞掉：视口位置由用户的手势
/// 和我们自己的「跟底部」逻辑决定，不由某段文字的光标决定。
class IgnoreShowOnScreen extends SingleChildRenderObjectWidget {
  const IgnoreShowOnScreen({super.key, super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderIgnoreShowOnScreen();
}

class _RenderIgnoreShowOnScreen extends RenderProxyBox {
  @override
  void showOnScreen({
    RenderObject? descendant,
    Rect? rect,
    Duration duration = Duration.zero,
    Curve curve = Curves.ease,
  }) {
    // 故意不往上传：由我们自己决定要不要滚动。
  }
}
