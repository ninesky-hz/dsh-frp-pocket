import 'package:flutter/material.dart';

// 设置页那套行/分组的统一版式。
//
// 只有一处来源，因为这一页最容易长成「每行各写各的 padding」：之前确实如此——
// 权限块是 16/10/16/12，`SwitchListTile` 用 Material 自带的内边距，分段控件又是
// 另一套，于是同一列文字左边缘能差出 10px 来。
//
// 约定：
// - 行内边距 16/12，图标固定 20 宽，图标与文字间距 12（标签永远从第 48px 起）。
// - 分组标题：13/500，次要色，上 24 下 8。**不用强调色**——强调色留给「有信号」
//   的东西（在线、已允许、选中），给标题上色会让整页都在喊。
// - 行与行之间一条 8% 的细线，从头像列之后起，用来分块而不是分隔。
// - 机器值（版本号、缓存占用、上次事件、接口前缀）统一用等宽数字，像终端回显。

/// 设置页的图标尺寸：一个值，不许在页面里各写各的。
const double kSettingsIconSize = 20;

/// 图标列宽 + 图标到文字的间距：标题文字固定在 16 + 20 + 12 = 48。
const double kSettingsIconGap = 12;

/// 行内上下内边距。
const double kSettingsRowPadV = 12;

/// 分组标题的上/下留白。
const double kSettingsSectionTop = 24;
const double kSettingsSectionBottom = 8;

/// 机器值：等宽数字、零字距。版本号、缓存占用、上次事件都用它。
const TextStyle kSettingsMachine = TextStyle(
  fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
  letterSpacing: 0,
);


/// 分段控件的统一外观：圆角 10、hairline 边框、紧凑高度。
///
/// M3 默认是胶囊形（stadium），跟这一页 12 的卡片圆角摆在一起像两种语言。
ButtonStyle settingsSegmentStyle(ThemeData theme) {
  return SegmentedButton.styleFrom(
    visualDensity: VisualDensity.compact,
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    minimumSize: const Size(0, 36),
    padding: const EdgeInsets.symmetric(horizontal: 10),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    side: BorderSide(color: theme.colorScheme.outlineVariant),
    textStyle: theme.textTheme.labelLarge?.copyWith(
      fontSize: 13,
      fontWeight: FontWeight.w500,
    ),
  );
}

/// 一个分组：标题 + 若干行，行之间一条细线。
class SettingsSection extends StatelessWidget {
  const SettingsSection({
    super.key,
    required this.title,
    required this.children,
    this.top = kSettingsSectionTop,
  });

  final String title;
  final List<Widget> children;
  final double top;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.fromLTRB(16, top, 16, kSettingsSectionBottom),
          child: Text(
            title,
            style: theme.textTheme.bodySmall?.copyWith(
              fontSize: 13,
              height: 18 / 13,
              fontWeight: FontWeight.w500,
              color: theme.colorScheme.onSurfaceVariant,
              letterSpacing: 0,
            ),
          ),
        ),
        for (var i = 0; i < children.length; i++) ...<Widget>[
          if (i > 0 &&
              children[i] is! SettingsInset &&
              children[i - 1] is! SettingsInset)
            const SettingsDivider(),
          children[i],
        ],
      ],
    );
  }
}

/// 行之间的细线：从中性灰阶里拿一条 1px，不抢视线。
class SettingsDivider extends StatelessWidget {
  const SettingsDivider({super.key, this.indent = 16});

  final double indent;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(left: indent),
      child: Divider(
        height: 1,
        thickness: 1,
        color: Theme.of(context).colorScheme.outlineVariant,
      ),
    );
  }
}

/// 一行设置：图标 + 标题 +（可选）说明 + 右侧控件。
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.titleKey,
    this.subtitleKey,
  });

  final IconData? icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final Key? titleKey;

  /// 说明文字的 key（有些行要断言副标题内容）。
  final Key? subtitleKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subtitle = this.subtitle;
    final body = Padding(
      padding: const EdgeInsets.fromLTRB(16, kSettingsRowPadV, 16, kSettingsRowPadV),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            SizedBox(
              width: kSettingsIconSize,
              child: Icon(icon, size: kSettingsIconSize),
            ),
            const SizedBox(width: kSettingsIconGap),
          ] else
            const SizedBox(width: kSettingsIconSize + kSettingsIconGap),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  title,
                  key: titleKey,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontSize: 15,
                    height: 20 / 15,
                    fontWeight: FontWeight.w500,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                if (subtitle != null) ...<Widget>[
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    key: subtitleKey,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: 13,
                      height: 18 / 13,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...<Widget>[
            const SizedBox(width: 12),
            trailing!,
          ],
        ],
      ),
    );
    if (onTap == null) return body;
    return InkWell(onTap: onTap, child: body);
  }
}

/// 开关行：整行可点，右侧一个 M3 开关。
class SettingsSwitchRow extends StatelessWidget {
  const SettingsSwitchRow({
    super.key,
    this.icon,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final IconData? icon;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SettingsRow(
      icon: icon,
      title: title,
      subtitle: subtitle,
      onTap: () => onChanged(!value),
      trailing: Switch(value: value, onChanged: onChanged),
    );
  }
}

/// 分段控件行：标题（+说明）一行，控件另起一行的宽度吃满。
class SettingsSegmentRow<T> extends StatelessWidget {
  const SettingsSegmentRow({
    super.key,
    this.icon,
    this.title,
    this.subtitle,
    required this.segments,
    required this.selected,
    required this.onChanged,
  });

  final IconData? icon;

  /// 有标题就先出一行标题，控件另起一行；没有标题时控件自己占这段（如「外观」）。
  final String? title;
  final String? subtitle;
  final List<ButtonSegment<T>> segments;
  final T selected;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = this.title;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (title != null) SettingsRow(icon: icon, title: title, subtitle: subtitle),
        Padding(
          padding: EdgeInsets.fromLTRB(16, title == null ? kSettingsRowPadV : 0, 16, 12),
          child: Align(
            alignment: Alignment.centerLeft,
            child: SegmentedButton<T>(
              style: settingsSegmentStyle(theme),
              segments: segments,
              selected: <T>{selected},
                          onSelectionChanged: (selection) => onChanged(selection.first),
            ),
          ),
        ),
      ],
    );
  }
}

/// 右侧的机器值文字：等宽数字 + 次要色。仓库地址、版本号这类就用它。
class SettingsValue extends StatelessWidget {
  const SettingsValue(this.text, {super.key, this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text,
      textAlign: TextAlign.end,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodySmall?.copyWith(
        fontSize: 12,
        color: color ?? theme.colorScheme.onSurfaceVariant,
      ).merge(kSettingsMachine),
    );
  }
}


/// 一坨自带外框的内容（比如权限状态卡）：分组不为它画上下细线。
class SettingsInset extends StatelessWidget {
  const SettingsInset({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// 页面里的一句说明：分组尾巴上的灰色小字，最多两行。
class SettingsFootnote extends StatelessWidget {
  const SettingsFootnote(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          fontSize: 12,
          height: 16 / 12,
          color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.9),
        ),
      ),
    );
  }
}
