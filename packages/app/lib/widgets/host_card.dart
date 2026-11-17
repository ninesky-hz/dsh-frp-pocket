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
    this.runningSessions,
  });

  final Host host;
  final ProbeResult? result;
  final bool probing;

  /// 这台主机上正在跑的会话数；`null` 表示这次没读到（未配置 PIN、DSH 没响应等），
  /// 卡片就不显示这一项，而不是硬写一个 0 骗人。
  final int? runningSessions;

  final VoidCallback onTap;
  final VoidCallback onMenu;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = result?.status;
    final dshVersion = result?.dshVersion;
    final online = result?.isOnline ?? false;

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
                    if (online || runningSessions != null) ...[
                      const SizedBox(height: 6),
                      _StatsLine(
                        latencyMs: online ? result?.infoLatencyMs : null,
                        runningSessions: runningSessions,
                      ),
                    ],
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

/// 状态行下面那行小字：响应时间 · 正在跑的会话数。
///
/// 两件事都是「用起来才关心」的信息，所以字号比状态行还小一档、颜色走
/// onSurfaceVariant，不跟「在线 / 隧道运行中」抢注意力；有会话在跑时
/// 才给那一小段上主色，扫一眼就知道这台机器在干活。
class _StatsLine extends StatelessWidget {
  const _StatsLine({this.latencyMs, this.runningSessions});

  final int? latencyMs;
  final int? runningSessions;

  /// 1000ms 以内按毫秒，超过就换成秒——5000ms 这种读起来没有 5.0s 直观。
  static String formatLatency(int ms) {
    if (ms < 1000) return '$ms ms';
    return '${(ms / 1000).toStringAsFixed(1)} s';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      fontSize: 11,
      height: 1.35,
      color: theme.colorScheme.onSurfaceVariant,
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
    );
    final running = runningSessions;
    final busy = running != null && running > 0;
    final parts = <Widget>[
      if (latencyMs != null)
        Text(
          '响应 ${formatLatency(latencyMs!)}',
          key: const ValueKey<String>('host-latency'),
          style: muted,
        ),
      if (latencyMs != null && running != null) Text(' · ', style: muted),
      if (running != null)
        Text(
          '$running 个会话在跑',
          key: const ValueKey<String>('host-running'),
          style: busy
              ? muted?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                )
              : muted,
        ),
    ];
    if (parts.isEmpty) return const SizedBox.shrink();
    // 用 Wrap 而不是 Row：窄屏（320dp）配三位数会话数时，两段挤不下就折行，
    // 不要把卡片撑破。真机上这点字（十几字）从来不会折。
    return Wrap(
      key: const ValueKey<String>('host-stats'),
      spacing: 2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: parts,
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
