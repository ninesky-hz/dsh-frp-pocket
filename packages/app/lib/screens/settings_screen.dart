import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_scope.dart';
import '../constants.dart';
import '../models/app_settings.dart';
import '../services/platform_bridge.dart';
import '../theme/app_icons.dart';

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
                secondary: const Icon(AppIcons.lock),
              ),
              _SectionHeader(title: '会话'),
              SwitchListTile(
                value: settings.turnAlertEnabled,
                onChanged: settings.setTurnAlertEnabled,
                title: const Text('答完提醒（灵动岛）'),
                subtitle: const Text('一轮答完在屏幕顶部弹一条摘要；App 在后台时改发系统通知'),
                secondary: const Icon(AppIcons.spark),
              ),
              SwitchListTile(
                value: settings.foldNotesWhenDone,
                onChanged: settings.setFoldNotesWhenDone,
                title: const Text('完成后收起过程'),
                subtitle: const Text('一轮答完把思考和工具调用折成一行摘要，点开再看细节'),
                secondary: const Icon(AppIcons.notes),
              ),
              ListTile(
                leading: const Icon(AppIcons.notes),
                title: const Text('工具调用显示'),
                subtitle: Text(
                  settings.chatNotesMode == ChatNotesMode.compact
                      ? '折叠成「思考 · 2 次工具调用」'
                      : '逐项列出，带工具参数摘要',
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: SegmentedButton<ChatNotesMode>(
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
                  selected: <ChatNotesMode>{settings.chatNotesMode},
                  onSelectionChanged: (selection) {
                    settings.setChatNotesMode(selection.first);
                  },
                ),
              ),
              _SectionHeader(title: '关于'),
              ListTile(
                leading: const Icon(AppIcons.info),
                title: const Text('版本与契约'),
                subtitle: Text('App $kAppVersion ($kBuildNumber) · 契约 $kContractVersion'),
                onTap: () => _showAbout(context),
              ),
              ListTile(
                key: const ValueKey<String>('about-repo'),
                leading: const Icon(AppIcons.link),
                title: const Text('开源仓库'),
                subtitle: const Text(kRepoUrl),
                trailing: const Icon(AppIcons.forward, size: AppIcons.inline),
                onTap: () => _openRepo(context),
              ),
              ListTile(
                key: const ValueKey<String>('about-author'),
                leading: const Icon(AppIcons.person),
                title: const Text('作者'),
                subtitle: const Text(kAppAuthor),
              ),
              ListTile(
                leading: const Icon(AppIcons.link),
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
