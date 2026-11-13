import 'package:flutter/cupertino.dart';

/// 全 App 统一的图标表。
///
/// 只有一个理由：**别让每个页面各挑一个变体**。之前 `Icons.refresh`（实心）、
/// `Icons.refresh_rounded`（圆角）、`Icons.refresh_outlined`（线性）同时出现在
/// 三个页面里，风格自然就散了。
///
/// 现在统一到 **Cupertino Icons**：笔画细、端点圆、视觉重量轻，跟 iOS 系统
/// 设置菜单一个调子，也和 dsh-Go 的按钮图标一致（那套 1537 处图标全是
/// Cupertino）。业务代码里只允许写 `AppIcons.xxx`，`CupertinoIcons.*` 只出现在
/// 本文件——换风格时改这一处即可。
///
/// 尺寸同样只有四档，避免 12/14/16/18/20/22 到处飘：
/// - [inline] 16：嵌在文字里的小图标（气泡小字、徽章、错误行）
/// - [small] 20：卡片内的按钮、输入框前后缀
/// - [normal] 22：AppBar 按钮、列表项前导图标（也是全局默认值，对齐 dsh-Go）
/// - [hero] 56：空态 / 错误页的大图
///
/// 例外只有一处：**表示「已激活」的图标用实心**（[pinned]），靠填充度区分状态，
/// 不然「已置顶」和「未置顶」长得一模一样。
abstract final class AppIcons {
  // ---------------------------------------------------------------- 尺寸
  static const double inline = 16;
  static const double small = 20;
  static const double normal = 22;
  static const double hero = 56;

  // ------------------------------------------------------------ 导航/动作
  static const IconData back = CupertinoIcons.chevron_back;
  static const IconData forward = CupertinoIcons.chevron_forward;
  static const IconData expand = CupertinoIcons.chevron_down;
  static const IconData collapse = CupertinoIcons.chevron_up;
  static const IconData more = CupertinoIcons.ellipsis;
  static const IconData close = CupertinoIcons.xmark;
  static const IconData check = CupertinoIcons.checkmark;
  static const IconData add = CupertinoIcons.plus;
  static const IconData refresh = CupertinoIcons.arrow_clockwise;
  static const IconData search = CupertinoIcons.search;
  static const IconData searchEmpty = CupertinoIcons.doc_text_search;
  static const IconData sortDown = CupertinoIcons.arrow_down;
  static const IconData send = CupertinoIcons.arrow_up;
  static const IconData stop = CupertinoIcons.stop_circle;

  // -------------------------------------------------------------- 列表/会话
  static const IconData newSession = CupertinoIcons.plus_bubble;
  static const IconData chat = CupertinoIcons.chat_bubble;
  static const IconData forum = CupertinoIcons.conversation_bubble;
  static const IconData edit = CupertinoIcons.pencil;
  static const IconData copy = CupertinoIcons.doc_on_doc;
  static const IconData archive = CupertinoIcons.archivebox;
  static const IconData archiveBox = CupertinoIcons.tray;
  static const IconData folder = CupertinoIcons.folder;
  static const IconData list = CupertinoIcons.list_bullet;
  static const IconData grid = CupertinoIcons.square_grid_2x2;
  static const IconData pin = CupertinoIcons.pin;

  /// 已置顶：唯一的实心图标，见类注释。
  static const IconData pinned = CupertinoIcons.pin_fill;
  static const IconData delete = CupertinoIcons.trash;
  static const IconData notes = CupertinoIcons.text_alignleft;
  static const IconData schedule = CupertinoIcons.clock;

  // -------------------------------------------------------------- 主机/连接
  static const IconData qrScan = CupertinoIcons.qrcode_viewfinder;
  static const IconData qrCode = CupertinoIcons.qrcode;
  static const IconData link = CupertinoIcons.link;
  static const IconData browser = CupertinoIcons.compass;
  static const IconData key = CupertinoIcons.lock_shield;
  static const IconData network = CupertinoIcons.wifi;
  static const IconData hub = CupertinoIcons.antenna_radiowaves_left_right;
  static const IconData dns = CupertinoIcons.globe;
  static const IconData cloudOff = CupertinoIcons.wifi_slash;
  static const IconData cloudSync = CupertinoIcons.arrow_2_circlepath;
  static const IconData settings = CupertinoIcons.gear;

  // ---------------------------------------------------------------- 状态/提示
  static const IconData info = CupertinoIcons.info_circle;
  static const IconData help = CupertinoIcons.question_circle;
  static const IconData error = CupertinoIcons.exclamationmark_triangle;
  static const IconData shield = CupertinoIcons.shield;
  static const IconData shieldWarn = CupertinoIcons.exclamationmark_shield;
  static const IconData label = CupertinoIcons.tag;
  static const IconData lock = CupertinoIcons.lock;

  // ------------------------------------------------------------------ 外观
  static const IconData themeSystem = CupertinoIcons.circle_lefthalf_fill;
  static const IconData themeLight = CupertinoIcons.sun_max;
  static const IconData themeDark = CupertinoIcons.moon;

  // ------------------------------------------------------------------ 图片
  static const IconData image = CupertinoIcons.photo;
  static const IconData imageBroken = CupertinoIcons.exclamationmark_circle;
  static const IconData noPhoto = CupertinoIcons.camera;
  static const IconData flashOn = CupertinoIcons.bolt_fill;
  static const IconData flashOff = CupertinoIcons.bolt_slash_fill;
  static const IconData visible = CupertinoIcons.eye;
  static const IconData hidden = CupertinoIcons.eye_slash;
}
