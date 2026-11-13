import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../constants.dart';
import '../models/app_settings.dart';
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
