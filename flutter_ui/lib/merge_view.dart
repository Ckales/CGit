import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'git_text.dart';
import 'theme.dart';

/// The three-pane merge window: ours | result | theirs.
///
/// Rows are laid out as triplets so a row is as tall as its tallest pane and
/// the three stay aligned block by block with no scroll-syncing. The CSS
/// version gets that from one grid; here it is a Column of IntrinsicHeight
/// Rows, which is the same bargain — correct alignment, at the cost of an
/// intrinsic-size pass per row.
///
/// Long lines are clipped, not wrapped, and one shared horizontal offset moves
/// all three panes together. Wrapping would be far less code, but three panes
/// each get a third of the window and wrapped code stops being comparable line
/// by line — which is the entire point of this view.
class MergeWindow extends StatefulWidget {
  const MergeWindow({
    super.key,
    required this.file,
    required this.content,
    required this.onClose,
    required this.onResolveWith,
    required this.onResolveSide,
    required this.onToggleBase,
  });

  final String file;

  /// The worktree file, markers and all.
  final String content;

  final VoidCallback onClose;

  /// Write this text and mark the file resolved.
  final Future<void> Function(String content) onResolveWith;

  /// Take one whole side — the no-marker fallback.
  final Future<void> Function(String side) onResolveSide;

  /// Ask git to regenerate the markers with or without the common ancestor.
  /// `wantBase` is what the user is asking for, not what the file has now.
  final Future<void> Function(bool wantBase) onToggleBase;

  @override
  State<MergeWindow> createState() => _MergeWindowState();
}

class _MergeWindowState extends State<MergeWindow> {
  late ParsedConflicts _parsed;
  late List<ConflictBlock> _conflicts;

  /// One controller per editable cell. Clicking » or « rewrites the result
  /// text, so the controllers have to outlive a rebuild.
  final _editors = <ConflictBlock, TextEditingController>{};

  /// The shared horizontal offset every pane's text is translated by.
  double _scrollX = 0;
  double _widest = 0;

  final _wholeFile = TextEditingController();

  @override
  void initState() {
    super.initState();
    _parse();
  }

  @override
  void didUpdateWidget(MergeWindow old) {
    super.didUpdateWidget(old);
    // Toggling the base re-reads the regenerated file; everything resets.
    if (old.content != widget.content) {
      for (final c in _editors.values) {
        c.dispose();
      }
      _editors.clear();
      _scrollX = 0;
      _parse();
    }
  }

  void _parse() {
    _parsed = parseConflicts(widget.content);
    _conflicts =
        _parsed.blocks.where((b) => b.type == BlockType.conflict).toList();
    _wholeFile.text = widget.content;
  }

  @override
  void dispose() {
    for (final c in _editors.values) {
      c.dispose();
    }
    _wholeFile.dispose();
    super.dispose();
  }

  bool get _hasBase => _conflicts.any((b) => b.base.isNotEmpty);
  int get _undecided => _conflicts.where((b) => !b.decided).length;

  /// Edits are picked up through TextField.onChanged, not a controller
  /// listener: a listener also fires when the gutter buttons rewrite the text
  /// programmatically, which would record a machine-written line as a hand edit
  /// and make the block look decided when it is not.
  TextEditingController _editor(ConflictBlock b, String initial) => _editors
      .putIfAbsent(b, () => TextEditingController(text: b.edited ?? initial));

  void _decide(ConflictBlock b, String side, bool take) {
    setState(() {
      if (side == 'ours') {
        b.takeOurs = take;
      } else {
        b.takeTheirs = take;
      }
      // An explicit pick replaces whatever was typed.
      b.edited = null;
      b.syncResolution();
      _editors[b]?.text = b.resultLines.join('\n');
    });
  }

  void _setAll(bool ours, bool theirs) {
    setState(() {
      for (final b in _conflicts) {
        b.takeOurs = ours;
        b.takeTheirs = theirs;
        b.edited = null;
        b.syncResolution();
        _editors[b]?.text = b.resultLines.join('\n');
      }
    });
  }

  void _shift(double dx, double viewportWidth) {
    final overflow = (_widest - viewportWidth).clamp(0.0, double.infinity);
    setState(() => _scrollX = (_scrollX + dx).clamp(0.0, overflow));
  }

  @override
  Widget build(BuildContext context) {
    final p = Theming.of(context);

    return Positioned.fill(
      child: ColoredBox(
        color: const Color(0x99000000),
        child: Center(
          child: Container(
            width: 1180,
            height: 760,
            decoration: BoxDecoration(
              color: p.bg,
              border: Border.all(color: p.border),
              borderRadius: BorderRadius.circular(8),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                _titleBar(p),
                Expanded(
                  child:
                      _parsed.hasConflict ? _mergeGrid(p) : _wholeFilePane(p),
                ),
                _parsed.hasConflict ? _mergeActions(p) : _wholeFileActions(p),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _titleBar(Palette p) => Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: p.bgAlt,
          border: Border(bottom: BorderSide(color: p.border)),
        ),
        child: Row(
          children: [
            Text('合并 — ${widget.file}', style: ui.copyWith(color: p.text)),
            const Spacer(),
            _IconText(label: '✕', onTap: widget.onClose),
          ],
        ),
      );

  /* ---------- the no-markers fallback ---------- */

  Widget _wholeFilePane(Palette p) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            color: p.bgAlt,
            child: Text('无文本冲突标记 — 整文件处理',
                style: ui.copyWith(color: p.textDim, fontSize: 11)),
          ),
          Expanded(
            child: Container(
              color: p.diffBg,
              padding: const EdgeInsets.all(8),
              child: TextField(
                controller: _wholeFile,
                maxLines: null,
                expands: true,
                style: mono.copyWith(color: p.text),
                cursorColor: p.accent,
                decoration: const InputDecoration.collapsed(hintText: ''),
              ),
            ),
          ),
        ],
      );

  Widget _wholeFileActions(Palette p) => _bar(p, [
        _Btn(label: '采用我方', onTap: () => widget.onResolveSide('ours')),
        _Btn(label: '采用对方', onTap: () => widget.onResolveSide('theirs')),
        _Btn(label: '取消', onTap: widget.onClose),
        _Btn(
          label: '标记为已解决',
          primary: true,
          onTap: () => widget.onResolveWith(_wholeFile.text),
        ),
      ]);

  /* ---------- the three-pane view ---------- */

  Widget _mergeGrid(Palette p) => LayoutBuilder(
        builder: (context, box) {
          // Each pane owns a third of the window, minus its cell padding.
          final paneWidth = box.maxWidth / 3 - 16;
          return Column(
            children: [
              _headRow(p),
              Expanded(
                child: Listener(
                  // A sideways trackpad swipe anywhere over the panes drives the
                  // shared offset; there is no per-pane scroll to fight with.
                  onPointerSignal: (e) {
                    if (e is PointerScrollEvent &&
                        e.scrollDelta.dx.abs() > e.scrollDelta.dy.abs()) {
                      _shift(e.scrollDelta.dx, paneWidth);
                    }
                  },
                  child: SingleChildScrollView(
                    child: Column(
                      children: [
                        for (final b in _parsed.blocks)
                          if (b.type == BlockType.conflict)
                            _conflictRow(p, b)
                          else if (b.lines.join().isNotEmpty)
                            // A blank filler block is still saved, just not shown.
                            _contextRow(p, b),
                      ],
                    ),
                  ),
                ),
              ),
              if (_widest > paneWidth) _hBar(p, paneWidth),
            ],
          );
        },
      );

  Widget _headRow(Palette p) => Container(
        decoration: BoxDecoration(
          color: p.bgAlt,
          border: Border(bottom: BorderSide(color: p.border)),
        ),
        child: Row(
          children: [
            for (final label in const [
              '我方（当前分支）',
              '结果（可编辑）',
              '对方（传入）',
            ])
              Expanded(
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Text(label,
                      style: ui.copyWith(color: p.textDim, fontSize: 11)),
                ),
              ),
          ],
        ),
      );

  Widget _contextRow(Palette p, ConflictBlock b) {
    final text = b.lines.join('\n');
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: _clipped(p, text, dim: true)),
          Expanded(child: _resultCell(p, b, text, conflicted: false)),
          Expanded(child: _clipped(p, text, dim: true)),
        ],
      ),
    );
  }

  Widget _conflictRow(Palette p, ConflictBlock b) => IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: _sideCell(p, b, 'ours')),
            Expanded(
              child:
                  _resultCell(p, b, b.resultLines.join('\n'), conflicted: true),
            ),
            Expanded(child: _sideCell(p, b, 'theirs')),
          ],
        ),
      );

  /// A side's text plus its gutter. The chevron points at the result pane and ✕
  /// drops that side, like IDEA's gutter controls; merging both sides in is two
  /// clicks, » then «.
  Widget _sideCell(Palette p, ConflictBlock b, String side) {
    final ours = side == 'ours';
    final take = ours ? b.takeOurs : b.takeTheirs;
    final lines = ours ? b.ours : b.theirs;

    final tint = take == null
        ? (ours ? p.delRow : p.addRow)
        : take
            ? p.accent.withValues(alpha: 0.14)
            : p.textDim.withValues(alpha: 0.08);

    final gutter = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _GutterButton(
          label: ours ? '»' : '«',
          tooltip: ours ? '合并我方这段 → 结果' : '合并对方这段 → 结果',
          active: take == true,
          onTap: () => _decide(b, side, true),
        ),
        _GutterButton(
          label: '✕',
          tooltip: ours ? '不合并我方这段' : '不合并对方这段',
          active: take == false,
          onTap: () => _decide(b, side, false),
        ),
      ],
    );

    return Container(
      color: tint,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!ours) gutter,
          Expanded(
            child: Opacity(
              opacity: take == false ? 0.4 : 1,
              child: _clipped(p, lines.join('\n')),
            ),
          ),
          if (ours) gutter,
        ],
      ),
    );
  }

  /// Every result cell is editable — that is the only way to touch the lines git
  /// merged cleanly, since those carry no conflict for a side button.
  Widget _resultCell(
    Palette p,
    ConflictBlock b,
    String initial, {
    required bool conflicted,
  }) {
    final controller = _editor(b, initial);
    final undecided = conflicted && !b.decided;

    return Container(
      decoration: BoxDecoration(
        color: undecided ? p.yellow.withValues(alpha: 0.10) : null,
        border: Border(
          left: BorderSide(color: p.border),
          right: BorderSide(color: p.border),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Base is reference only: it lives outside the editor, so it can never
          // end up in the saved file.
          if (b.base.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                '共同祖先：${b.base.join(' ⏎ ')}',
                style: ui.copyWith(color: p.textDim, fontSize: 10),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          TextField(
            controller: controller,
            maxLines: null,
            style: mono.copyWith(color: p.text),
            cursorColor: p.accent,
            decoration: const InputDecoration.collapsed(hintText: ''),
            // Typing is a decision: it settles the block even if neither side
            // button was pressed.
            onChanged: (text) => setState(() => b.edited = text),
          ),
        ],
      ),
    );
  }

  /// One pane's text: measured for the shared scrollbar, shifted by the shared
  /// offset, and clipped to its third of the window.
  Widget _clipped(Palette p, String text, {bool dim = false}) {
    _measure(text);
    return ClipRect(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Transform.translate(
          offset: Offset(-_scrollX, 0),
          child: Align(
            alignment: Alignment.topLeft,
            child: Text(
              text,
              softWrap: false,
              maxLines: null,
              style: mono.copyWith(color: dim ? p.textDim : p.text),
            ),
          ),
        ),
      ),
    );
  }

  /// The widest line decides how far the shared bar can travel. Measuring during
  /// build and storing it would loop, so the new value is applied after the
  /// frame that discovered it.
  void _measure(String text) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: mono),
      maxLines: null,
      textDirection: TextDirection.ltr,
    )..layout();
    if (painter.width > _widest) {
      final w = painter.width;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && w > _widest) setState(() => _widest = w);
      });
    }
  }

  Widget _hBar(Palette p, double paneWidth) {
    final overflow = _widest - paneWidth;
    return SizedBox(
      height: 12,
      child: LayoutBuilder(
        builder: (context, box) {
          final frac = paneWidth / _widest;
          final thumbW = (box.maxWidth * frac).clamp(40.0, box.maxWidth);
          final travel = box.maxWidth - thumbW;
          final x = overflow <= 0 ? 0.0 : (_scrollX / overflow) * travel;
          return GestureDetector(
            onHorizontalDragUpdate: (d) => _shift(
                d.delta.dx / (travel == 0 ? 1 : travel) * overflow, paneWidth),
            child: Container(
              color: p.bgAlt,
              child: Stack(
                children: [
                  Positioned(
                    left: x,
                    top: 3,
                    child: Container(
                      width: thumbW,
                      height: 6,
                      decoration: BoxDecoration(
                        color: p.border,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _mergeActions(Palette p) {
    final left = _undecided;
    return _bar(p, [
      Text(
        left > 0
            ? '${_conflicts.length} 处冲突，$left 处未处理'
            : '${_conflicts.length} 处冲突，已全部处理',
        style:
            ui.copyWith(color: left > 0 ? p.yellow : p.textDim, fontSize: 11),
      ),
      const Spacer(),
      _Btn(label: '全部采用我方', onTap: () => _setAll(true, false)),
      _Btn(label: '全部采用对方', onTap: () => _setAll(false, true)),
      _Btn(
        label: _hasBase ? '隐藏共同祖先' : '显示共同祖先',
        onTap: () => widget.onToggleBase(!_hasBase),
      ),
      _Btn(label: '取消', onTap: widget.onClose),
      _Btn(
        label: '应用',
        primary: true,
        // Saving with an undecided block would silently fall back to "ours".
        onTap: left > 0
            ? null
            : () => widget.onResolveWith(assembleConflict(_parsed.blocks)),
      ),
    ]);
  }

  Widget _bar(Palette p, List<Widget> children) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: p.border)),
        ),
        child: Row(
          children: [
            for (final c in children) ...[
              c,
              if (c != children.last) const SizedBox(width: 6),
            ],
          ],
        ),
      );
}

class _GutterButton extends StatelessWidget {
  const _GutterButton({
    required this.label,
    required this.tooltip,
    required this.active,
    required this.onTap,
  });

  final String label;
  final String tooltip;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = Theming.of(context);
    return Tooltip(
      message: tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            width: 18,
            height: 18,
            margin: const EdgeInsets.all(1),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: active ? p.accent : p.bgElev,
              border: Border.all(color: p.border),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(
              label,
              style: ui.copyWith(
                fontSize: 11,
                color: active ? const Color(0xFFFFFFFF) : p.text,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _IconText extends StatelessWidget {
  const _IconText({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = Theming.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Text(label, style: ui.copyWith(color: p.textDim)),
      ),
    );
  }
}

class _Btn extends StatefulWidget {
  const _Btn({required this.label, required this.onTap, this.primary = false});
  final String label;
  final VoidCallback? onTap;
  final bool primary;

  @override
  State<_Btn> createState() => _BtnState();
}

class _BtnState extends State<_Btn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = Theming.of(context);
    final enabled = widget.onTap != null;
    // A disabled primary drops the accent entirely rather than fading it: a
    // washed-out blue still reads as clickable, and a primary button that does
    // nothing when pressed is worse than one that is plainly greyed out.
    final bg = widget.primary && enabled
        ? p.accent
        : (_hover && enabled ? p.bgHover : p.bgElev);

    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: bg,
            border:
                Border.all(color: widget.primary && enabled ? bg : p.border),
            borderRadius: BorderRadius.circular(5),
          ),
          child: Text(
            widget.label,
            style: ui.copyWith(
              color: !enabled
                  ? p.textDim
                  : (widget.primary ? const Color(0xFFFFFFFF) : p.text),
            ),
          ),
        ),
      ),
    );
  }
}
