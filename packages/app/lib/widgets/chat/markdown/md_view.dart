import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'md_doc.dart';
import 'md_highlight.dart';
import 'md_style.dart';

/// 流式期间的解析节流间隔。
///
/// 宿主每来一帧 token 就重建一次气泡，逐帧重解析 + 重排版会在长回答里把滚动
/// 拖成幻灯片。120ms 是「肉眼看不出停顿、解析压力又降一个量级」的折中。
const Duration kMdStreamThrottle = Duration(milliseconds: 120);

/// 流式期间超过这个字数就不解析了，直接当纯文本贴。
///
/// 解析本身是线性的，贵的是每 120ms 重建上百个 Widget；几万字的长回答（贴日志、
/// 贴整个文件）在手机上滚起来会抖。这类内容本来也不是靠排版看的，等定稿之后再
/// 渲染成正式的 markdown 就行。
const int kMdStreamPlainLimit = 8000;

/// 一条消息的 markdown 正文。
///
/// 两种状态：
///
/// - 定稿消息：直接解析一次，全量渲染；
/// - 流式中：节流解析（[kMdStreamThrottle]），超长降级成纯文本（[kMdStreamPlainLimit]）。
///
/// 定稿消息的预览/展开由调用方处理（`chat_bubbles.dart` 里对
/// `previewMarkdown` 的使用）——这里只管「给一段 markdown，画出来」。
class MdView extends StatefulWidget {
  const MdView({
    super.key,
    required this.text,
    required this.style,
    this.streaming = false,
    this.selectable = true,
    this.onSelectionChanged,
  });

  final String text;
  final MdStyle style;
  final bool streaming;

  final bool selectable;
  final ValueChanged<TextSelection>? onSelectionChanged;

  /// 流式光标那块的 key。测试与「光标消失了吗」的判断都靠它。
  static const Key caretKey = ValueKey<String>('md-caret');

  @override
  State<MdView> createState() => _MdViewState();
}

class _MdViewState extends State<MdView> {
  List<MdBlock> _blocks = const <MdBlock>[];
  Timer? _timer;
  bool _pending = false;

  @override
  void initState() {
    super.initState();
    _parseNow();
  }

  @override
  void didUpdateWidget(covariant MdView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text == widget.text) return;
    if (!widget.streaming) {
      _timer?.cancel();
      _timer = null;
      _pending = false;
      _parseNow();
      return;
    }
    if (widget.text.length > kMdStreamPlainLimit) {
      _timer?.cancel();
      _timer = null;
      _pending = false;
      // 降级态不需要解析结果，清掉省内存。
      if (_blocks.isNotEmpty) setState(() => _blocks = const <MdBlock>[]);
      return;
    }
    // 头部直接解析，尾巴用一次性定时器合并：连续出字时每 [kMdStreamThrottle]
    // 最多解析一次，既不会每帧重排，也不会让正文落后到一句话。
    //
    // 刻意不读 `DateTime.now()`：窗口要跟着宿主时钟走（测试里就是假时钟），
    // 读墙钟会让节流在快慢两种时钟下表现不一致。
    if (_timer == null) {
      _parseNow();
      _armTimer();
      return;
    }
    _pending = true;
  }

  void _armTimer() {
    _timer?.cancel();
    _timer = Timer(kMdStreamThrottle, () {
      _timer = null;
      if (!mounted) return;
      if (_pending) {
        _pending = false;
        _parseNow();
        _armTimer();
      }
    });
  }

  void _parseNow() {
    final next = parseMarkdown(widget.text);
    if (!mounted) {
      _blocks = next;
      return;
    }
    setState(() => _blocks = next);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 超长流式：纯文本 + 光标。等定稿再走下面的渲染路径。
    if (widget.streaming && widget.text.length > kMdStreamPlainLimit) {
      return Text(
        '${widget.text}▊',
        style: widget.style.body,
      );
    }
    if (_blocks.isEmpty && widget.text.trim().isEmpty) {
      return widget.streaming ? _caret() : const SizedBox.shrink();
    }
    if (_blocks.isEmpty) {
      // 节流窗口里还没解析完：先按纯文本顶上，别让正文空一拍闪一下。
      return Text(
        widget.text,
        style: widget.style.body,
      );
    }

    final children = <Widget>[
      for (final block in _blocks) _blockWidget(block),
    ];

    if (widget.streaming) {
      // 光标贴在最后一块的下面：单独一路小方块夹在正文中间会显得突兀。
      children.add(_caret());
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }

  Widget _caret() => Padding(
        key: MdView.caretKey,
        padding: const EdgeInsets.only(top: 2),
        child: SizedBox(
          width: 7,
          height: 15,
          child: ColoredBox(color: widget.style.text.withValues(alpha: 0.75)),
        ),
      );

  Widget _blockWidget(MdBlock block) {
    final style = widget.style;
    return switch (block) {
      MdParagraph(:final inlines) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _rich(inlines, style.body),
        ),
      MdHeading(:final level, :final inlines) => Padding(
          padding: EdgeInsets.only(top: level <= 2 ? 6 : 4, bottom: 8),
          child: _rich(inlines, style.heading(level)),
        ),
      MdList(:final ordered, :final items) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (var i = 0; i < items.length; i++)
                Padding(
                  padding: EdgeInsets.only(top: i == 0 ? 0 : 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      SizedBox(
                        width: ordered ? 20 : 14,
                        child: Text(
                          ordered ? '${i + 1}.' : '•',
                          style: style.body.copyWith(
                            color: style.textTertiary,
                            fontWeight: ordered ? FontWeight.w600 : FontWeight.w400,
                          ),
                        ),
                      ),
                      Expanded(child: _rich(items[i], style.body)),
                    ],
                  ),
                ),
            ],
          ),
        ),
      MdQuote(:final inlines) => Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.only(left: 11),
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: style.quoteBar, width: 2)),
          ),
          child: _rich(
            inlines,
            style.body.copyWith(color: style.textSecondary),
          ),
        ),
      MdCodeBlock() => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: MdCodeBlockView(block: block, style: style),
        ),
      MdTable() => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: MdTableView(block: block, style: style),
        ),
      MdRule() => Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Container(height: 1, color: style.tableBorder),
        ),
    };
  }

  Widget _rich(List<MdInline> inlines, TextStyle base) {
    final span = _spanOf(inlines, base);
    if (!widget.selectable) return Text.rich(span);
    return SelectableText.rich(
      span,
      onSelectionChanged: (selection, cause) =>
          widget.onSelectionChanged?.call(selection),
    );
  }

  TextSpan _spanOf(List<MdInline> inlines, TextStyle base) {
    final spans = <InlineSpan>[];
    for (final node in inlines) {
      switch (node) {
        case MdText(:final text):
          spans.add(TextSpan(text: text, style: base));
        case MdCodeSpan(:final text):
          spans.add(WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              margin: const EdgeInsets.symmetric(horizontal: 1),
              decoration: widget.style.inlineCodeBox,
              child: Text(text, style: widget.style.inlineCodeText),
            ),
          ));
        case MdStrong(:final children):
          spans.add(_spanOf(children, base.copyWith(
            fontWeight: widget.style.strongWeight,
          )));
        case MdEmph(:final children):
          spans.add(_spanOf(children, base.copyWith(
            fontStyle: FontStyle.italic,
          )));
        case MdStrike(:final children):
          spans.add(_spanOf(children, base.copyWith(
            decoration: TextDecoration.lineThrough,
            color: widget.style.textSecondary,
          )));
        case MdLink(:final children):
          // 链接只做视觉可辨：点开要引入 url_launcher 依赖，本轮不做（版本
          // 说明里写了「链接暂不可点」）。想让它可点，就在这套 Span 外面套
          // TapGestureRecognizer。
          spans.add(_spanOf(children, base.copyWith(
            color: widget.style.link,
            decoration: TextDecoration.underline,
            decorationColor: widget.style.link.withValues(alpha: 0.35),
          )));
      }
    }
    return TextSpan(children: spans, style: base);
  }
}

/// 围栏代码块：语言标签 + 复制 + 横向滚动。
class MdCodeBlockView extends StatelessWidget {
  const MdCodeBlockView({super.key, required this.block, required this.style});

  final MdCodeBlock block;
  final MdStyle style;

  @override
  Widget build(BuildContext context) {
    final label = block.lang.isEmpty ? '代码' : block.lang;
    return Container(
      decoration: BoxDecoration(
        color: style.codeBg,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: style.codeBorder),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            padding: const EdgeInsets.fromLTRB(10, 5, 6, 5),
            decoration: BoxDecoration(
              color: style.codeHeaderBg,
              border: Border(bottom: BorderSide(color: style.codeBorder)),
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    label,
                    style: style.mono.copyWith(
                      fontSize: 11.4,
                      color: style.textSecondary,
                      letterSpacing: 0.3,
                    ),
                  ),
                ),
                if (!block.closed)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Text(
                      '输出中',
                      style: style.mono.copyWith(
                        fontSize: 10.8,
                        color: style.textTertiary,
                      ),
                    ),
                  ),
                _CopyButton(text: block.code, style: style),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(11, 8, 11, 8),
            child: SelectableText.rich(
              TextSpan(children: highlightCode(block.code, block.lang, style)),
            ),
          ),
        ],
      ),
    );
  }
}

class _CopyButton extends StatelessWidget {
  const _CopyButton({required this.text, required this.style});

  final String text;
  final MdStyle style;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: const ValueKey<String>('md-copy'),
      borderRadius: BorderRadius.circular(5),
      onTap: () async {
        await Clipboard.setData(ClipboardData(text: text));
        if (!context.mounted) return;
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('已复制'), duration: Duration(seconds: 1)),
        );
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
        decoration: BoxDecoration(
          color: style.tableHeaderBg,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: style.codeBorder),
        ),
        child: Text(
          '复制',
          style: style.mono.copyWith(fontSize: 10.8, color: style.textSecondary),
        ),
      ),
    );
  }
}

/// GFM 表格。窄屏放不下就横向滚，不把列硬压成两三个字。
class MdTableView extends StatelessWidget {
  const MdTableView({super.key, required this.block, required this.style});

  final MdTable block;
  final MdStyle style;

  @override
  Widget build(BuildContext context) {
    TextAlign alignOf(int index) {
      final align = index < block.align.length ? block.align[index] : -1;
      return switch (align) {
        0 => TextAlign.center,
        1 => TextAlign.right,
        _ => TextAlign.left,
      };
    }

    TableRow row(List<List<MdInline>> cells, {required bool header}) {
      return TableRow(
        decoration: header ? BoxDecoration(color: style.tableHeaderBg) : null,
        children: <Widget>[
          for (var i = 0; i < cells.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
              child: Text.rich(
                _inlineSpan(cells[i], header),
                textAlign: alignOf(i),
              ),
            ),
        ],
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Table(
        defaultColumnWidth: const IntrinsicColumnWidth(),
        border: TableBorder.all(color: style.tableBorder, width: 1),
        children: <TableRow>[
          row(block.header, header: true),
          for (final cells in block.rows) row(cells, header: false),
        ],
      ),
    );
  }

  TextSpan _inlineSpan(List<MdInline> inlines, bool header) {
    final base = style.body.copyWith(
      fontSize: 13,
      height: 1.45,
      fontWeight: header ? FontWeight.w600 : FontWeight.w400,
      color: header ? style.textSecondary : style.text,
    );
    final builder = _InlineSpanBuilder(style);
    return builder.build(inlines, base);
  }
}

/// 表格单元格里只有一层行内样式，不需要 MdView 的 state。
class _InlineSpanBuilder {
  const _InlineSpanBuilder(this.style);
  final MdStyle style;

  TextSpan build(List<MdInline> inlines, TextStyle base) {
    final spans = <InlineSpan>[];
    for (final node in inlines) {
      switch (node) {
        case MdText(:final text):
          spans.add(TextSpan(text: text, style: base));
        case MdCodeSpan(:final text):
          spans.add(TextSpan(
            text: text,
            style: style.mono.copyWith(fontSize: 12, color: style.codeText),
          ));
        case MdStrong(:final children):
          spans.add(build(children, base.copyWith(fontWeight: FontWeight.w700)));
        case MdEmph(:final children):
          spans.add(build(children, base.copyWith(fontStyle: FontStyle.italic)));
        case MdStrike(:final children):
          spans.add(build(children, base.copyWith(
            decoration: TextDecoration.lineThrough,
          )));
        case MdLink(:final children):
          spans.add(build(children, base.copyWith(color: style.link)));
      }
    }
    return TextSpan(children: spans, style: base);
  }
}
