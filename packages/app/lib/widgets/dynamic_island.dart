import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/turn_alerts.dart';

/// 灵动岛：贴在屏幕顶部中央的一枚胶囊，专门报「这一轮答完了」。
///
/// 挂在 `MaterialApp.builder` 上（Navigator 之外），所以它浮在所有页面、弹窗
/// 之上，看起来就像系统自己的那一块。内容来自 [TurnAlertCenter]：会话页在
/// `turn/end` 时 push 一条，这里负责显示、计时收起、点开/上滑收起。
///
/// 计时归这里而不归 [TurnAlertCenter]：一块贴片什么时候收起来是「怎么显示」，
/// 不是「提醒是什么」。顺带的好处是没人显示的时候，一条计时器都不会挂在那儿。
///
/// 为什么背景固定是黑的、不跟主题走：灵动岛是「系统 UI」的隐喻，浅色主题下
/// 一块深色胶囊才认得出来；跟主题走反而会被当成普通 SnackBar。
class DynamicIslandHost extends StatefulWidget {
  const DynamicIslandHost({
    super.key,
    required this.child,
    this.center,
    this.shrinkAfter = const Duration(seconds: 3),
    this.dwell = const Duration(seconds: 7),
  });

  /// 原本的页面树（Navigator 那一坨）。
  final Widget child;

  /// 内容源；测试注入自己的实例，线上用 [TurnAlertCenter.instance]。
  final TurnAlertCenter? center;

  /// 展开态停多久，然后收成小胶囊。
  final Duration shrinkAfter;

  /// 收起之后再留多久，然后彻底消失。
  final Duration dwell;

  @override
  State<DynamicIslandHost> createState() => _DynamicIslandHostState();
}

class _DynamicIslandHostState extends State<DynamicIslandHost> {
  late final TurnAlertCenter _center = widget.center ?? TurnAlertCenter.instance;

  Timer? _shrinkTimer;
  Timer? _dismissTimer;

  /// 正在显示的那条：用来判断「是不是换了一条新的」。
  TurnAlert? _shown;

  /// 展开态：刚弹出来是展开的（能读到摘要），一会儿后收成小胶囊。
  bool _expanded = true;

  @override
  void initState() {
    super.initState();
    _center.addListener(_onChanged);
    // 挂上来时可能已经有一条在等着（热重载、或者页面比岛先建好）。
    _shown = _center.current;
    if (_shown != null) _arm(_shown!);
  }

  @override
  void dispose() {
    _shrinkTimer?.cancel();
    _dismissTimer?.cancel();
    _center.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    final alert = _center.current;
    if (identical(alert, _shown)) return;
    _shown = alert;
    _arm(alert);
    if (mounted) setState(() => _expanded = alert != null);
  }

  /// 换了一条（或没了）就重排计时：新的一条重新展开、重新开始算。
  void _arm(TurnAlert? alert) {
    _shrinkTimer?.cancel();
    _dismissTimer?.cancel();
    if (alert == null) return;
    _shrinkTimer = Timer(widget.shrinkAfter, () {
      if (!mounted || _shown == null) return;
      setState(() => _expanded = false);
    });
    _dismissTimer = Timer(widget.shrinkAfter + widget.dwell, _center.dismiss);
  }

  /// 点胶囊：先收起（不然它会盖住刚跳过去的页面），再做提醒自己带过来的动作。
  void _open(TurnAlert alert) {
    _center.dismiss();
    alert.onOpen?.call();
  }

  @override
  Widget build(BuildContext context) {
    final alert = _center.current;
    // `builder` 在 MediaQuery 之下、Directionality 之上，这里补一个方向性再落
    // Stack / Row，省得「没有 Directionality 祖先」的报错。
    final textDirection = Directionality.maybeOf(context) ?? TextDirection.ltr;
    return Directionality(
      textDirection: textDirection,
      child: Stack(
        children: <Widget>[
          widget.child,
          if (alert != null)
            Positioned(
              top: MediaQuery.paddingOf(context).top + 6,
              left: 0,
              right: 0,
              child: Center(
                child: _IslandPill(
                  alert: alert,
                  expanded: _expanded,
                  onTap: () => _open(alert),
                  onDismiss: _center.dismiss,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 动画时长：iOS 那颗药丸展开/收起差不多就是这个手感。
const Duration kIslandDuration = Duration(milliseconds: 220);

/// 收起态胶囊的宽度。
const double kIslandCollapsedWidth = 172;

/// 胶囊本体。
class _IslandPill extends StatelessWidget {
  const _IslandPill({
    required this.alert,
    required this.expanded,
    required this.onTap,
    required this.onDismiss,
  });

  final TurnAlert alert;
  final bool expanded;
  final VoidCallback onTap;
  final VoidCallback onDismiss;

  /// 胶囊底色：接近纯黑、留一点透明，压在任何页面底色上都像一块实体。
  static const Color _fill = Color(0xF20A0A0C);

  /// 上下两态的高度：收起 38、展开 82（标题一行 + 摘要两行刚好）。
  static const double _collapsedHeight = 38;
  static const double _expandedHeight = 82;

  static const TextStyle _titleStyle = TextStyle(
    color: Color(0xF2FFFFFF),
    fontSize: 13,
    fontWeight: FontWeight.w600,
    height: 1.2,
  );
  static const TextStyle _bodyStyle = TextStyle(
    color: Color(0xB8FFFFFF),
    fontSize: 12,
    height: 1.3,
  );
  static const TextStyle _hintStyle = TextStyle(
    color: Color(0x8AFFFFFF),
    fontSize: 11,
    height: 1.2,
  );

  String get _clock {
    final at = alert.at;
    final hh = at.hour.toString().padLeft(2, '0');
    final mm = at.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final expandedWidth = math.max(200.0, math.min(screenWidth - 40, 380.0));
    final width = expanded ? expandedWidth : kIslandCollapsedWidth;
    final height = expanded ? _expandedHeight : _collapsedHeight;

    return Semantics(
      key: const ValueKey<String>('dynamic-island'),
      label: '灵动岛：${alert.title} 已回复',
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        // 上滑收起：不想看就往上推，比等它自己消失快。
        onVerticalDragEnd: (details) {
          if ((details.primaryVelocity ?? 0) < -80) onDismiss();
        },
        child: AnimatedContainer(
          duration: kIslandDuration,
          curve: Curves.easeOutCubic,
          width: width,
          height: height,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: _fill,
            borderRadius: BorderRadius.circular(expanded ? 24 : 19),
            border: Border.all(color: const Color(0x1FFFFFFF)),
            boxShadow: const <BoxShadow>[
              BoxShadow(
                color: Color(0x33000000),
                blurRadius: 18,
                offset: Offset(0, 6),
              ),
            ],
          ),
          // 高度在 38↔82 之间补间，内容却按「自然高度」排版：宽度定死、高度放开，
          // 多出来的部分交给外层 clip 裁掉。直接塞进当前高度的盒子里会报 overflow
          // ——展开态的内容比收起态高，补间到一半时被压成 38 就会溢出。
          child: ClipRect(
            child: OverflowBox(
              alignment: Alignment.center,
              minWidth: width,
              maxWidth: width,
              minHeight: 0,
              maxHeight: double.infinity,
              child: AnimatedSwitcher(
                duration: kIslandDuration,
                switchInCurve: Curves.easeOut,
                switchOutCurve: Curves.easeIn,
                child: expanded ? _buildExpanded() : _buildCollapsed(),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCollapsed() {
    return Row(
      key: const ValueKey<String>('island-collapsed'),
      mainAxisAlignment: MainAxisAlignment.center,
      children: const <Widget>[
        _IslandDot(),
        SizedBox(width: 8),
        Text('回复完成', style: _titleStyle),
        SizedBox(width: 4),
        Icon(Icons.keyboard_arrow_down, size: 15, color: Color(0x8AFFFFFF)),
      ],
    );
  }

  Widget _buildExpanded() {
    return Padding(
      key: const ValueKey<String>('island-expanded'),
      padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: _IslandDot(),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        alert.title,
                        key: const ValueKey<String>('island-title'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: _titleStyle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(_clock, style: _hintStyle),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  alert.body,
                  key: const ValueKey<String>('island-body'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: _bodyStyle,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 胶囊上那颗小绿点：表示「有结果了」。
class _IslandDot extends StatelessWidget {
  const _IslandDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 9,
      height: 9,
      decoration: const BoxDecoration(
        color: Color(0xFF3DDC97),
        shape: BoxShape.circle,
        boxShadow: <BoxShadow>[
          BoxShadow(color: Color(0x663DDC97), blurRadius: 6, spreadRadius: 1),
        ],
      ),
    );
  }
}
