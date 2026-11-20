import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_scope.dart';
import '../constants.dart';
import '../models/app_settings.dart';
import '../services/platform_bridge.dart';
import '../theme/app_icons.dart';
import '../widgets/image_cache_tile.dart';
import '../widgets/settings_parts.dart';
import '../widgets/turn_alert_permission_tile.dart';

/// 设置页（CONTRACT §7.2.4）。
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  void _showAbout(BuildContext context) {
    showAboutDialog(
      context: context,
      applicationName: 'DSH 口袋隧道',
      applicationVersion: '$kAppVersion ($kBuildNumber)',
      applicationIcon: const Icon(AppIcons.hub, size: 40),
      children: <Widget>[
        const SizedBox(height: 12),
        const Text('通过自建 frp 隧道，在手机上远程使用家里的 DeepSeek Harness。'),
        const SizedBox(height: 12),
        const Text('作者：$kAppAuthor'),
        const SizedBox(height: 4),
        _RepoLink(onTap: () => _openRepo(context)),
        const SizedBox(height: 12),
        const Text('契约版本：$kContractVersion'),
        const Text('网关接口：$kApiPrefix'),
        const SizedBox(height: 8),
        const Text('本 App 不保存任何服务器口令，只在本机保存主机地址与 PIN。'),
      ],
    );
  }

  /// 打开开源仓库：能叫起系统浏览器就叫，叫不起来就退化成复制链接。
  Future<void> _openRepo(BuildContext context) async {
    const bridge = PlatformBridge();
    if (await bridge.openUrl(kRepoUrl)) return;
    await Clipboard.setData(const ClipboardData(text: kRepoUrl));
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text('打不开浏览器，仓库地址已复制')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = AppScope.of(context).settings;

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: AnimatedBuilder(
        animation: settings,
        builder: (context, _) {
          return ListView(
            padding: const EdgeInsets.only(top: 4, bottom: 40),
            children: <Widget>[
              SettingsSection(
                title: '外观',
                top: 12,
                children: <Widget>[
                  SettingsSegmentRow<AppThemeMode>(
                    segments: const <ButtonSegment<AppThemeMode>>[
                      ButtonSegment<AppThemeMode>(
                        value: AppThemeMode.system,
                        label: Text('跟随系统'),
                        icon: Icon(AppIcons.themeSystem),
                      ),
                      ButtonSegment<AppThemeMode>(
                        value: AppThemeMode.light,
                        label: Text('浅色'),
                        icon: Icon(AppIcons.themeLight),
                      ),
                      ButtonSegment<AppThemeMode>(
                        value: AppThemeMode.dark,
                        label: Text('深色'),
                        icon: Icon(AppIcons.themeDark),
                      ),
                    ],
                    selected: settings.themeMode,
                    onChanged: settings.setThemeMode,
                  ),
                ],
              ),
              SettingsSection(
                title: '使用时',
                children: <Widget>[
                  SettingsSwitchRow(
                    icon: AppIcons.brightness,
                    title: '保持屏幕常亮',
                    subtitle: '用手机长时间盯着任务进度时不熄屏',
                    value: settings.keepAwake,
                    onChanged: settings.setKeepAwake,
                  ),
                ],
              ),
              SettingsSection(
                title: '会话',
                children: <Widget>[
                  SettingsSwitchRow(
                    key: const ValueKey<String>('settings.turnAlertIsland'),
                    icon: AppIcons.island,
                    title: '答完提醒 · 灵动岛',
                    subtitle: 'App 正开着时，一轮答完在屏幕顶部弹一条摘要',
                    value: settings.turnAlertIsland,
                    onChanged: settings.setTurnAlertIsland,
                  ),
                  SettingsSwitchRow(
                    key: const ValueKey<String>('settings.turnAlertSystem'),
                    icon: AppIcons.notification,
                    title: '答完提醒 · 系统通知',
                    subtitle: '切到后台或锁屏时，答完了发一条通知栏提醒',
                    value: settings.turnAlertSystem,
                    onChanged: settings.setTurnAlertSystem,
                  ),
                  if (settings.turnAlertSystem)
                    const SettingsInset(child: TurnAlertPermissionTile()),
                  SettingsSwitchRow(
                    icon: AppIcons.notes,
                    title: '完成后收起过程',
                    subtitle: '一轮答完把思考和工具调用折成一行摘要，点开再看细节',
                    value: settings.foldNotesWhenDone,
                    onChanged: settings.setFoldNotesWhenDone,
                  ),
                  SettingsSegmentRow<ChatNotesMode>(
                    icon: AppIcons.list,
                    title: '工具调用显示',
                    subtitle: settings.chatNotesMode == ChatNotesMode.compact
                        ? '折叠成「思考 · 2 次工具调用」'
                        : '逐项列出，带工具参数摘要',
                    segments: const <ButtonSegment<ChatNotesMode>>[
                      ButtonSegment<ChatNotesMode>(
                        value: ChatNotesMode.detailed,
                        label: Text('详细'),
                      ),
                      ButtonSegment<ChatNotesMode>(
                        value: ChatNotesMode.compact,
                        label: Text('简洁'),
                      ),
                    ],
                    selected: settings.chatNotesMode,
                    onChanged: settings.setChatNotesMode,
                  ),
                ],
              ),
              SettingsSection(
                title: '存储',
                children: const <Widget>[ImageCacheTile()],
              ),
              SettingsSection(
                title: '关于',
                children: <Widget>[
                  SettingsRow(
                    icon: AppIcons.info,
                    title: '版本与契约',
                    subtitle: 'App $kAppVersion ($kBuildNumber) · 契约 $kContractVersion',
                    trailing: const Icon(AppIcons.forward, size: AppIcons.inline),
                    onTap: () => _showAbout(context),
                  ),
                  SettingsRow(
                    key: const ValueKey<String>('about-repo'),
                    icon: AppIcons.link,
                    title: '开源仓库',
                    subtitle: kRepoUrl,
                    trailing: const Icon(AppIcons.forward, size: AppIcons.inline),
                    onTap: () => _openRepo(context),
                  ),
                  SettingsRow(
                    key: const ValueKey<String>('about-author'),
                    icon: AppIcons.person,
                    title: '作者',
                    trailing: const SettingsValue(kAppAuthor),
                  ),
                  SettingsRow(
                    icon: AppIcons.dns,
                    title: '接口前缀',
                    trailing: const SettingsValue(kApiPrefix),
                  ),
                ],
              ),
              const SettingsFootnote('口令只在发请求时用一次，不落盘。'),
            ],
          );
        },
      ),
    );
  }
}

/// 「关于」弹窗里的仓库地址：一行带下划线的可点文字。
class _RepoLink extends StatelessWidget {
  const _RepoLink({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(
          kRepoUrl,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.primary,
            decoration: TextDecoration.underline,
          ),
        ),
      ),
    );
  }
}
