import 'package:flutter/material.dart';

import '../models/host.dart';
import '../services/probe.dart';
import '../utils/time_format.dart';
import 'status_dot.dart';
import '../theme/app_icons.dart';

/// 主机列表卡片。
class HostCard extends StatelessWidget {
  const HostCard({
    super.key,
    required this.host,
    required this.result,
    required this.probing,
    required this.onTap,
    required this.onMenu,
    required this.onLongPress,
  });

  final Host host;
  final ProbeResult? result;
  final bool probing;
  final VoidCallback onTap;
  final VoidCallback onMenu;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = result?.status;
    final dshVersion = result?.dshVersion;

    return Card(
      clipBehavior: Clip.antiAlias,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: probing
                    ? SizedBox(
                        width: 10,
                        height: 10,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            theme.colorScheme.primary,
                          ),
                        ),
                      )
                    : StatusDot(status: status),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            host.name.isEmpty ? '未命名主机' : host.name,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (host.isExample)
                          Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: _Tag(
                              text: '示例',
                              color: theme.colorScheme.tertiary,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    // 域名 + DSH 版本同一行：版本是辅助信息，字号比域名还小一档、
                    // 不铺底色，避免在标题行抢走主机名的宽度（标题要能多显示几个字）。
                    // 域名用 Flexible 先省略，版本按自然宽度贴右，窄屏也不会撑破。
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            host.displayHost,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (dshVersion != null) ...[
                          Text(
                            '  ·  ',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.outline,
                            ),
                          ),
                          ConstrainedBox(
                            // 正常版本号（0.2.2-rc.3）约 80px；给到 120 就够，
                            // 真遇到带日期的 dev 串也只在这一小块里省略。
                            constraints: const BoxConstraints(maxWidth: 120),
                            child: Text(
                              'DSH $dshVersion',
                              key: const ValueKey<String>('host-dsh-version'),
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontSize: 10,
                                height: 1.3,
                                letterSpacing: 0.1,
                                color: theme.colorScheme.outline,
                                fontFeatures: const <FontFeature>[
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Text(
                          result?.statusLabel ?? '未探测',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: StatusDot.colorFor(context, status),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            result == null
                                ? '最近在线：${formatLastSeen(host.lastSeenAt)}'
                                : result!.statusDetail,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    if (host.pin.isEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          '未配置 PIN，进入后需手动登录',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.error,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '更多',
                icon: const Icon(AppIcons.more),
                onPressed: onMenu,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(
          context,
        ).textTheme.labelSmall?.copyWith(color: color, height: 1.4),
      ),
    );
  }
}
