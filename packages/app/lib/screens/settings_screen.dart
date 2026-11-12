import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../app_scope.dart';
import '../constants.dart';
import '../models/app_settings.dart';

/// 设置页（CONTRACT §7.2.4）。
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  Future<void> _clearCookies(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清除全部 Cookie'),
        content: const Text('所有主机的登录状态都会失效，下次进入 WebView 需要重新用 PIN 登录。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    var ok = false;
    try {
      await CookieManager.instance().deleteAllCookies();
      ok = true;
    } catch (_) {
      ok = false;
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(ok ? '已清除全部 Cookie' : '清除失败，请重试')),
      );
  }

  void _showAbout(BuildContext context) {
    showAboutDialog(
      context: context,
      applicationName: 'DSH 口袋隧道',
      applicationVersion: '$kAppVersion ($kBuildNumber)',
      applicationIcon: const Icon(Icons.hub_outlined, size: 40),
      children: const <Widget>[
        SizedBox(height: 12),
        Text('通过自建 frp 隧道，在手机上远程使用家里的 DeepSeek Harness。'),
        SizedBox(height: 12),
        Text('契约版本：$kContractVersion'),
        Text('网关接口：$kApiPrefix'),
        SizedBox(height: 8),
        Text('本 App 不保存任何服务器口令，只在本机保存主机地址与 PIN。'),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = AppScope.of(context).settings;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: AnimatedBuilder(
        animation: settings,
        builder: (context, _) {
          return ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: <Widget>[
              _SectionHeader(title: '外观'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: SegmentedButton<AppThemeMode>(
                  segments: const <ButtonSegment<AppThemeMode>>[
                    ButtonSegment<AppThemeMode>(
                      value: AppThemeMode.system,
                      label: Text('跟随系统'),
                      icon: Icon(Icons.brightness_auto_outlined),
                    ),
                    ButtonSegment<AppThemeMode>(
                      value: AppThemeMode.light,
                      label: Text('浅色'),
                      icon: Icon(Icons.light_mode_outlined),
                    ),
                    ButtonSegment<AppThemeMode>(
                      value: AppThemeMode.dark,
                      label: Text('深色'),
                      icon: Icon(Icons.dark_mode_outlined),
                    ),
                  ],
                  selected: <AppThemeMode>{settings.themeMode},
                  onSelectionChanged: (selection) {
                    settings.setThemeMode(selection.first);
                  },
                ),
              ),
              const SizedBox(height: 8),
              _SectionHeader(title: '使用时'),
              SwitchListTile(
                value: settings.keepAwake,
                onChanged: settings.setKeepAwake,
                title: const Text('保持屏幕常亮'),
                subtitle: const Text('用手机长时间盯着任务进度时不熄屏'),
                secondary: const Icon(Icons.screen_lock_portrait_outlined),
              ),
              SwitchListTile(
                value: settings.desktopUserAgent,
                onChanged: settings.setDesktopUserAgent,
                title: const Text('使用桌面 User-Agent'),
                subtitle: const Text('排查 dsh web 布局差异用，改动后需重进 WebView'),
                secondary: const Icon(Icons.desktop_windows_outlined),
              ),
              _SectionHeader(title: '数据'),
              ListTile(
                leading: Icon(
                  Icons.cleaning_services_outlined,
                  color: theme.colorScheme.error,
                ),
                title: const Text('清除全部 Cookie'),
                subtitle: const Text('所有主机退出登录'),
                onTap: () => _clearCookies(context),
              ),
              _SectionHeader(title: '关于'),
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: const Text('版本与契约'),
                subtitle: Text('App $kAppVersion ($kBuildNumber) · 契约 $kContractVersion'),
                onTap: () => _showAbout(context),
              ),
              ListTile(
                leading: const Icon(Icons.link),
                title: const Text('接口前缀'),
                subtitle: const Text('$kApiPrefix（info / login / health）'),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(
        title,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
