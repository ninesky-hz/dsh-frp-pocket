import 'package:flutter/material.dart';

import '../services/image_cache.dart';
import '../theme/app_icons.dart';
import 'settings_parts.dart';

/// 设置页「存储 → 图片缓存」那一行。
///
/// 三件事必须一起给用户：**看得到占多少**、**能一键清**、**清之前说清代价**。
/// 只有按钮没有数字，用户不知道点了有没有用；不解释代价，他会以为连历史
/// 一起删了。
class ImageCacheTile extends StatefulWidget {
  const ImageCacheTile({super.key, this.store});

  /// 测试注入；生产用 [DiskImageCache.instance]。
  final ImageCacheStore? store;

  /// 整行的 key（`find.byKey` 用）。
  static const Key tileKey = ValueKey<String>('image-cache');

  /// 副标题（占用文案）的 key。
  static const Key sizeKey = ValueKey<String>('image-cache.size');

  /// 「清除」按钮的 key。
  static const Key clearKey = ValueKey<String>('image-cache.clear');

  /// 确认框里的「清除」。
  static const Key confirmKey = ValueKey<String>('image-cache.confirm');

  /// 确认框里的「取消」。
  static const Key cancelKey = ValueKey<String>('image-cache.cancel');

  @override
  State<ImageCacheTile> createState() => _ImageCacheTileState();
}

class _ImageCacheTileState extends State<ImageCacheTile> {
  late final ImageCacheStore _store = widget.store ?? DiskImageCache.instance;

  ImageCacheStats? _stats;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final stats = await _store.stats();
    if (!mounted) return;
    setState(() => _stats = stats);
  }

  /// 确认框：说清「清的是什么、不清什么」。
  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清除图片缓存？'),
        content: const Text(
          '清掉之后图片要重新从电脑加载，第一次打开会话会慢一点。\n\n'
          '历史消息、文字和电脑上的原件都不受影响；还没发出去的图也不会被清。',
        ),
        actions: <Widget>[
          TextButton(
            key: ImageCacheTile.cancelKey,
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            key: ImageCacheTile.confirmKey,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _busy = true);
    final removed = await _store.clear();
    // 内存里那几份也作废：否则屏幕上还挂着旧图，看着像没清掉。
    bumpImageCacheEpoch();
    final stats = await _store.stats();
    if (!mounted) return;
    setState(() {
      _stats = stats;
      _busy = false;
    });
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          removed.isEmpty
              ? '本来就没有缓存'
              : '已清除 ${formatCacheSize(removed.bytes)}（${removed.count} 张）',
        ),
      ),
    );
  }

  String get _subtitle {
    final stats = _stats;
    if (stats == null) return '正在统计…';
    if (stats.isEmpty) return '还没有缓存 · 图片看一次就从电脑拉一次';
    return '已用 ${formatCacheSize(stats.bytes)} · ${stats.count} 张'
        '\n清掉只影响本机副本，历史与电脑上的原件不动';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stats = _stats;
    final canClear = !_busy && stats != null && !stats.isEmpty;
    return SettingsRow(
      key: ImageCacheTile.tileKey,
      icon: AppIcons.image,
      title: '图片缓存',
      subtitle: _subtitle,
      subtitleKey: ImageCacheTile.sizeKey,
      trailing: _busy
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : TextButton(
              key: ImageCacheTile.clearKey,
              onPressed: canClear ? _confirmClear : null,
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 30),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
                textStyle: theme.textTheme.labelLarge?.copyWith(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
              child: const Text('清除'),
            ),
    );
  }
}
