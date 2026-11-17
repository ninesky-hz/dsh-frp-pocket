import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/platform_bridge.dart';

/// 打开会话正文里的链接。
///
/// 走已有的原生桥（`PlatformBridge.openUrl` → `Intent.ACTION_VIEW`），不引入
/// `url_launcher`：那条依赖带原生代码，而 App 只需要「把 URL 交给系统」这一件事，
/// 桥里早就有了（设置页的仓库地址就用它）。
///
/// 打不开时（设备上没有浏览器、桥没注册、系统拦了）不留死链接：复制到剪贴板并
/// 提示一句，用户还能粘到别处去。
Future<void> openExternalLink(BuildContext context, String url) async {
  final ok = await const PlatformBridge().openUrl(url);
  if (ok || !context.mounted) return;
  await Clipboard.setData(ClipboardData(text: url));
  if (!context.mounted) return;
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
    const SnackBar(content: Text('打不开系统浏览器，链接已复制')),
  );
}
