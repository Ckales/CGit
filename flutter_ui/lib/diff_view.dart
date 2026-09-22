// SelectionArea lives in the material library, so the whole file takes that
// import; nothing below uses a Material-styled widget.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'git_text.dart';
import 'theme.dart';

enum DiffMode { split, unified }

/// One file's patch: a stack of hunks, each independently selectable.
///
/// In the DOM version this pane is rebuilt imperatively — renderHunks() clears
/// `#diff` and appends spans, and `paint()` toggles a `picked` class on the
/// rows that changed. Here the picked set is state and the rows are a pure
/// function of it, so there is no paint step: the only thing this file has that
/// main.js does not is the plumbing that carries the selection back up.
class DiffPane extends StatelessWidget {
  const DiffPane({
    super.key,
    required this.hunks,
    required this.mode,
    this.onApply,
    this.staged = false,
  });

  final List<String> hunks;
  final DiffMode mode;

  /// Called with a rebuilt partial hunk ready for `git apply`. Null makes the
  /// pane read-only — the commit-detail view, where there is nothing to stage.
  final void Function(String patch, bool reverse)? onApply;
  final bool staged;

  @override
  Widget build(BuildContext context) {
    final palette = Theming.of(context);
    if (hunks.isEmpty) {
      return Container(
        color: palette.diffBg,
        alignment: Alignment.center,
        child: Text('没有文本差异', style: ui.copyWith(color: palette.textDim)),
      );
    }

    // SelectionArea is what buys back the one thing the DOM gives for free:
    // dragging a selection across rows and copying it. It only covers the
    // widgets built below it, which is why the rows are built eagerly rather
    // than through ListView.builder.
    //
    // ponytail: eager build matches the DOM version's behaviour and keeps
    // selection whole. Switch to ListView.builder if a single file's diff ever
    // gets big enough to stutter — and accept that selection then stops at the
    // viewport edge.
    return Container(
      color: palette.diffBg,
      child: SelectionArea(
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final hunk in hunks)
                _HunkView(
                  key: ValueKey(hunk),
                  hunk: hunk,
                  mode: mode,
                  onApply: onApply,
                  staged: staged,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HunkView extends StatefulWidget {
  const _HunkView({
    super.key,
    required this.hunk,
    required this.mode,
    required this.onApply,
    required this.staged,
  });

  final String hunk;
  final DiffMode mode;
  final void Function(String patch, bool reverse)? onApply;
  final bool staged;

  @override
  State<_HunkView> createState() => _HunkViewState();
}

class _HunkViewState extends State<_HunkView> {
  final _picked = <int>{};
  int? _anchor;
  int? _hovered;

  late List<int> _pickable = selectableLines(widget.hunk);

  @override
  void didUpdateWidget(_HunkView old) {
    super.didUpdateWidget(old);
    if (old.hunk != widget.hunk) {
      _pickable = selectableLines(widget.hunk);
      _picked.clear();
      _anchor = null;
    }
  }

  bool get _shiftHeld {
    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    return keys.contains(LogicalKeyboardKey.shiftLeft) ||
        keys.contains(LogicalKeyboardKey.shiftRight);
  }

  void _tap(List<int> picks) {
    if (picks.isEmpty) return;
    setState(() {
      if (_shiftHeld && _anchor != null) {
        _picked.addAll(rangeBetween(_pickable, _anchor!, picks.first));
      } else {
        final on = picks.any(_picked.contains);
        for (final i in picks) {
          if (on) {
            _picked.remove(i);
          } else {
            _picked.add(i);
          }
        }
      }
      _anchor = picks.first;
    });
  }

  void _apply(bool reverse) {
    final patch = buildPartialHunk(widget.hunk, _picked);
    if (patch == null) return;
    widget.onApply!(patch, reverse);
    setState(() {
      _picked.clear();
      _anchor = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = Theming.of(context);
    final interactive = widget.onApply != null;
    final headerText = widget.hunk.split('\n').first;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _HunkBar(
          text: headerText,
          pickedCount: _picked.length,
          staged: widget.staged,
          onApply: interactive && _picked.isNotEmpty ? _apply : null,
        ),
        if (widget.mode == DiffMode.unified)
          ..._unifiedRows(palette, interactive)
        else
          ..._splitRows(palette, interactive),
      ],
    );
  }

  List<Widget> _unifiedRows(Palette palette, bool interactive) {
    final lines = widget.hunk
        .replaceFirst(RegExp(r'\n$'), '')
        .split('\n')
        .skip(1)
        .toList();
    final rows = <Widget>[];

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final changed = line.startsWith('+') || line.startsWith('-');
      final color = line.startsWith('+')
          ? palette.green
          : line.startsWith('-')
              ? palette.red
              : palette.text;
      rows.add(_row(
        picks: changed ? [i] : const [],
        interactive: interactive,
        palette: palette,
        child: Container(
          width: double.infinity,
          color: line.startsWith('+')
              ? palette.addRow
              : line.startsWith('-')
                  ? palette.delRow
                  : null,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(line, style: mono.copyWith(color: color)),
        ),
      ));
    }
    return rows;
  }

  /// Fixed-width number columns and two equal text columns, so rows stay aligned
  /// without synchronising two scroll positions. Long lines wrap inside their
  /// own half rather than scrolling — same call the CSS version makes.
  List<Widget> _splitRows(Palette palette, bool interactive) {
    final paired = pairHunkLines(widget.hunk);
    if (paired == null) return _unifiedRows(palette, interactive);

    final rows = <Widget>[];
    for (final row in paired.rows) {
      IntraDiff? intra;
      if (row.type == RowType.mod) {
        intra = intraLineDiff(row.left!.text, row.right!.text);
      }
      rows.add(_row(
        picks: row.picks,
        interactive: interactive,
        palette: palette,
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _NumCell(cell: row.left),
              Expanded(
                child: _TextCell(
                  cell: row.left,
                  part: intra?.left,
                  intraColor: palette.intraDel,
                  tint: row.type == RowType.del || row.type == RowType.mod
                      ? palette.delRow
                      : null,
                ),
              ),
              _NumCell(cell: row.right),
              Expanded(
                child: _TextCell(
                  cell: row.right,
                  part: intra?.right,
                  intraColor: palette.intraAdd,
                  tint: row.type == RowType.add || row.type == RowType.mod
                      ? palette.addRow
                      : null,
                ),
              ),
            ],
          ),
        ),
      ));
    }
    return rows;
  }

  /// The pickable-row wrapper: hover feedback, click/shift-click, and the
  /// selected outline. In CSS this is three rules (`.pickable`, `.pickable:hover
  /// .split-text`, `.picked`); here every one of them is explicit state.
  Widget _row({
    required List<int> picks,
    required bool interactive,
    required Palette palette,
    required Widget child,
  }) {
    final key = picks.isEmpty ? -1 : picks.first;
    final pickable = interactive && picks.isNotEmpty;
    final picked = picks.any(_picked.contains);
    final hovered = pickable && _hovered == key;

    Widget content = DecoratedBox(
      decoration: BoxDecoration(
        border: picked ? Border.all(color: palette.accent, width: 1) : null,
      ),
      child: child,
    );

    if (hovered) {
      // CSS does this with `filter: brightness(1.25)`. Flutter has no filter
      // shorthand, so it is an explicit overlay.
      content = Stack(
        children: [
          content,
          Positioned.fill(
            child: IgnorePointer(
              child: ColoredBox(color: palette.text.withValues(alpha: 0.05)),
            ),
          ),
        ],
      );
    }

    if (!pickable) return content;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = key),
      onExit: (_) => setState(() => _hovered = null),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // SelectionArea claims drag gestures for text selection; a tap still
        // reaches here, which is why picking is click-only and ranges use shift.
        onTap: () => _tap(picks),
        child: content,
      ),
    );
  }
}

class _HunkBar extends StatelessWidget {
  const _HunkBar({
    required this.text,
    required this.pickedCount,
    required this.staged,
    required this.onApply,
  });

  final String text;
  final int pickedCount;
  final bool staged;
  final void Function(bool reverse)? onApply;

  @override
  Widget build(BuildContext context) {
    final palette = Theming.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: palette.bgAlt,
        border: Border(bottom: BorderSide(color: palette.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: mono.copyWith(color: palette.accent),
            ),
          ),
          if (onApply != null) ...[
            Text('已选 $pickedCount 行',
                style: ui.copyWith(color: palette.textDim, fontSize: 11)),
            const SizedBox(width: 8),
            _SmallButton(
              label: staged ? '取消暂存所选' : '暂存所选',
              onTap: () => onApply!(staged),
            ),
          ],
        ],
      ),
    );
  }
}

class _NumCell extends StatelessWidget {
  const _NumCell({required this.cell});
  final DiffCell? cell;

  @override
  Widget build(BuildContext context) {
    final palette = Theming.of(context);
    return Container(
      width: 44,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      alignment: Alignment.topRight,
      decoration: BoxDecoration(
        color: palette.bgAlt,
        border: Border(right: BorderSide(color: palette.border)),
      ),
      // Line numbers must stay out of a copied selection, which in CSS is
      // `user-select: none` and here is an explicit opt-out widget.
      child: SelectionContainer.disabled(
        child: Text(
          cell == null ? '' : '${cell!.no}',
          style: mono.copyWith(color: palette.textDim),
        ),
      ),
    );
  }
}

class _TextCell extends StatelessWidget {
  const _TextCell({
    required this.cell,
    required this.part,
    required this.intraColor,
    required this.tint,
  });

  final DiffCell? cell;
  final LinePart? part;
  final Color intraColor;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final palette = Theming.of(context);

    // An added line has no left-hand counterpart (and vice versa); hatch the gap
    // so it reads as "nothing here", not as an empty line of content.
    if (cell == null) {
      return CustomPaint(
        painter: _HatchPainter(palette.emptyCell),
        child: const SizedBox(width: double.infinity),
      );
    }

    final style = mono.copyWith(color: palette.text);
    final Widget text = part == null
        ? Text(cell!.text, style: style)
        : Text.rich(
            TextSpan(children: [
              TextSpan(text: part!.prefix),
              if (part!.mid.isNotEmpty)
                TextSpan(
                  text: part!.mid,
                  style: TextStyle(backgroundColor: intraColor),
                ),
              TextSpan(text: part!.suffix),
            ]),
            style: style,
          );

    return Container(
      width: double.infinity,
      color: tint,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: text,
    );
  }
}

/// `repeating-linear-gradient(45deg, …)` has no Flutter equivalent; the 4px
/// stripes are painted by hand.
class _HatchPainter extends CustomPainter {
  const _HatchPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 4;
    for (var x = -size.height; x < size.width; x += 8) {
      canvas.drawLine(
          Offset(x, size.height), Offset(x + size.height, 0), paint);
    }
  }

  @override
  bool shouldRepaint(_HatchPainter old) => old.color != color;
}

class _SmallButton extends StatefulWidget {
  const _SmallButton({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  State<_SmallButton> createState() => _SmallButtonState();
}

class _SmallButtonState extends State<_SmallButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final palette = Theming.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: _hover ? palette.bgHover : palette.bgElev,
            border: Border.all(color: palette.border),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(widget.label, style: ui.copyWith(fontSize: 11)),
        ),
      ),
    );
  }
}
