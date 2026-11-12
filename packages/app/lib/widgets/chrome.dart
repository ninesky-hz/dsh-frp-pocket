import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../services/probe.dart';
import 'status_dot.dart';

/// 悬浮玻璃控件：一层模糊底 + 半透明填充 + 一像素描边。
///
/// 参考 dsh-Go 网页模式的做法——页面上不放 AppBar，控件直接浮在内容上，
/// 靠材质（模糊 + 半透明）跟网页内容分层，而不是靠一条实心标题栏把空间吃掉。
class GlassPill extends StatelessWidget {
  const GlassPill({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    this.radius = 999,
    this.blur = 18,
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  final double radius;
  final double blur;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fill = isDark
        ? const Color(0xFF15161A).withValues(alpha: 0.72)
        : Colors.white.withValues(alpha: 0.76);
    final stroke = isDark
        ? Colors.white.withValues(alpha: 0.14)
        : Colors.black.withValues(alpha: 0.07);
    final borderRadius = BorderRadius.circular(radius);

    final surface = ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: fill,
            borderRadius: borderRadius,
            border: Border.all(color: stroke),
          ),
          child: Padding(padding: padding, child: child),
        ),
      ),
    );

    if (onTap == null) return surface;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: borderRadius,
        onTap: onTap,
        child: surface,
      ),
    );
  }
}

/// 玻璃圆钮：返回 / 刷新 / 更多。
class GlassIconButton extends StatelessWidget {
  const GlassIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.size = 40,
    this.iconSize = 20,
    this.badge = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final double size;
  final double iconSize;

  /// 右侧按钮组里做一个轻微的强调（例如「更多」里有需要处理的事）。
  final bool badge;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: tooltip,
      child: GlassPill(
        radius: size / 2,
        padding: EdgeInsets.zero,
        onTap: onPressed,
        child: SizedBox(
          width: size,
          height: size,
          child: Stack(
            alignment: Alignment.center,
            children: <Widget>[
              Icon(
                icon,
                size: iconSize,
                color: onPressed == null
                    ? theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4)
                    : theme.colorScheme.onSurface,
              ),
              if (badge)
                Positioned(
                  right: 9,
                  top: 9,
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.error,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 网页顶部的悬浮控制行：左返回、中间状态胶囊、右刷新与更多。
///
/// 单独抽出来是为了能在窄屏（320/360dp）下验证不会溢出——中文主机名很长时
/// 最容易在这里把 Row 撑破。
class WebToolbar extends StatelessWidget {
  const WebToolbar({
    super.key,
    required this.name,
    required this.status,
    this.latencyMs,
    required this.onBack,
    required this.onRefresh,
    required this.onMore,
    required this.onStatus,
  });

  final String name;
  final ProbeStatus? status;
  final int? latencyMs;
  final VoidCallback onBack;
  final VoidCallback onRefresh;
  final VoidCallback onMore;
  final VoidCallback onStatus;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = name.isEmpty ? '未命名主机' : name;
    return Row(
      children: <Widget>[
        GlassIconButton(
          icon: Icons.chevron_left_rounded,
          iconSize: 24,
          tooltip: '返回',
          onPressed: onBack,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: GlassPill(
              onTap: onStatus,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  StatusDot(status: status, size: 8),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge,
                    ),
                  ),
                  if (latencyMs != null) ...<Widget>[
                    const SizedBox(width: 8),
                    Text(
                      '${latencyMs}ms',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        GlassIconButton(
          icon: Icons.refresh_rounded,
          tooltip: '刷新',
          onPressed: onRefresh,
        ),
        const SizedBox(width: 8),
        GlassIconButton(
          icon: Icons.more_horiz_rounded,
          tooltip: '更多',
          onPressed: onMore,
        ),
      ],
    );
  }
}
