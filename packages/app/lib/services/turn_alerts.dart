import 'package:flutter/foundation.dart';

/// 一条「这一轮答完了」的提醒。
///
/// 它只描述内容，不关心怎么显示：前台时交给顶部灵动岛
/// （`widgets/dynamic_island.dart`），后台时交给系统通知
/// （`services/platform_bridge.dart`）。
@immutable
class TurnAlert {
  const TurnAlert({
    required this.sessionId,
    required this.title,
    required this.body,
    required this.at,
    this.onOpen,
  });

  /// 触发提醒的会话 id。
  final String sessionId;

  /// 会话标题；宿主还没起标题时是「新会话」。
  final String title;

  /// 回复摘要：已经压成一行并截断，够看出「它答了些什么」。
  final String body;

  /// 这一轮结束的时刻（灵动岛右上角那个几点几分）。
  final DateTime at;

  /// 点了胶囊之后干什么。会话页给的是「滚到最新」，页面已经不在时是 null。
  final VoidCallback? onOpen;

  @override
  String toString() => 'TurnAlert($sessionId, $title, ${body.length} 字)';
}

/// 灵动岛的内容源。
///
/// 做成全局单例而不是塞进 `AppScope`：会话页是唯一的生产者，胶囊却挂在
/// `MaterialApp.builder` 上（在 Navigator 之外），两边没有共同的祖先可以注入，
/// 走一条 [ChangeNotifier] 比给每个页面传一遍回调省事。
///
/// 任何时刻最多只留一条：新一轮进来直接顶掉上一轮，和手机上那种「只显示最新
/// 提醒」的胶囊一致。
///
/// 计时（先展开、再收成小胶囊、最后消失）不在这里，而是归显示方
/// `DynamicIslandHost` 管——它就是一块贴片，什么时候收起属于「怎么显示」，
/// 不属于「提醒是什么」。这样也顺带避免了「没人显示却挂着计时器」。
class TurnAlertCenter extends ChangeNotifier {
  TurnAlertCenter();

  /// 全局那一份（线上用）。
  static final TurnAlertCenter instance = TurnAlertCenter();

  TurnAlert? _current;

  /// 当前要显示的那条；null = 不显示。
  TurnAlert? get current => _current;

  bool get isShowing => _current != null;

  /// 弹一条提醒：顶掉上一条。
  void show(TurnAlert alert) {
    _current = alert;
    notifyListeners();
  }

  /// 收起，之后不再显示。
  void dismiss() {
    if (_current == null) return;
    _current = null;
    notifyListeners();
  }
}
