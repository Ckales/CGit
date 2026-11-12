// SelectionArea lives in the material library, so the whole file takes that
// import; nothing below uses a Material-styled widget.
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'git_text.dart';
import 'diff_syntax.dart';
import 'theme.dart';
import 'syntax_theme.dart';

enum DiffMode { split, unified }

/// Width of the stripe between the two panes. JetBrains draws the deleted
/// fragment here, not as a blank row in either editor.
const _dividerWidth = 72.0;

/// Read-only preview for a complete patch, including untracked-file diffs.
class PatchPreview extends StatelessWidget {
  const PatchPreview(
      {super.key, required this.text, required this.file, required this.mode});
  final String text;
  final String file;
  final DiffMode mode;

  @override
  Widget build(BuildContext context) {
    final patch = splitPatchText(text);
    if (patch.hunks.isNotEmpty) {
      return DiffPane(file: file, hunks: patch.hunks, mode: mode);
    }
    final p = Theming.of(context);
    return Container(
      color: p.diffBg,
      child: SelectionArea(
          child: SingleChildScrollView(
        padding: const EdgeInsets.all(8),
        child: SizedBox(
            width: double.infinity,
            child: Text(text, style: mono.copyWith(color: p.text))),
      )),
    );
  }
}

/// One file's patch: a stack of hunks, each independently selectable.
///
/// The picked set is state and the rows are a pure function of it, so there is
/// no separate paint step. Beyond drawing the rows, this file is the plumbing
/// that carries the selection back up.
class DiffPane extends StatefulWidget {
  const DiffPane({
    super.key,
    required this.hunks,
    required this.mode,
    this.file = '',
    this.onApply,
    this.staged = false,
    this.blockKeys = const {},
  });

  final List<String> hunks;
  final DiffMode mode;
  final String file;

  /// Keys for the rows that start a run of changed lines, so ↑/↓ can scroll to
  /// one. Keyed "hunkIndex:rowIndex"; the owner computes the same ids from
  /// [changeBlockRows] and keeps the keys alive across rebuilds.
  final Map<String, GlobalKey> blockKeys;

  /// Called with a rebuilt partial hunk ready for `git apply`. Null makes the
  /// pane read-only — the commit-detail view, where there is nothing to stage.
  final void Function(String patch, bool reverse)? onApply;
  final bool staged;

  @override
  State<DiffPane> createState() => _DiffPaneState();
}

class _DiffPaneState extends State<DiffPane> {
  final _horizontal = ScrollController();
  final _vertical = ScrollController();
  bool _wrap = false;
  double _offset = 0;
  double _codeWidth = 0;
  List<String>? _measuredHunks;
  TextScaler? _measuredScaler;

  @override
  void initState() {
    super.initState();
    _horizontal.addListener(() => setState(() => _offset = _horizontal.offset));
  }

  @override
  void dispose() {
    _horizontal.dispose();
    _vertical.dispose();
    super.dispose();
  }

  double _measure() {
    final scaler = MediaQuery.textScalerOf(context);
    if (_measuredHunks == widget.hunks && _measuredScaler == scaler) {
      return _codeWidth;
    }
    _measuredHunks = widget.hunks;
    _measuredScaler = scaler;
    _codeWidth = 0;
    final painter =
        TextPainter(textDirection: TextDirection.ltr, textScaler: scaler);
    for (final hunk in widget.hunks) {
      for (final line in hunk.split('\n').skip(1)) {
        painter.text =
            TextSpan(text: line.isEmpty ? '' : line.substring(1), style: mono);
        painter.layout();
        _codeWidth = math.max(_codeWidth, painter.width + 24);
      }
    }
    painter.dispose();
    return _codeWidth;
  }

  @override
  Widget build(BuildContext context) {
    final p = Theming.of(context);
    if (widget.hunks.isEmpty) {
      return Container(
          color: p.diffBg,
          alignment: Alignment.center,
          child: Text('没有文本差异', style: ui.copyWith(color: p.textDim)));
    }
    return LayoutBuilder(builder: (context, box) {
      final addedFile = widget.hunks.every((hunk) {
        final paired = pairHunkLines(hunk);
        return paired != null &&
            paired.head.oldStart == 0 &&
            paired.rows.every((row) => row.left == null);
      });
      final cellWidth = widget.mode == DiffMode.split && !addedFile
          ? (box.maxWidth - 88 - _dividerWidth) / 2
          : box.maxWidth;
      final overflow = math.max(0.0, _measure() - cellWidth + 16);
      final offset = _wrap ? 0.0 : _offset.clamp(0.0, overflow);
      return Container(
          color: p.diffBg,
          child: Column(
              mainAxisSize:
                  box.hasBoundedHeight ? MainAxisSize.max : MainAxisSize.min,
              children: [
                Container(
                    height: 30,
                    color: p.bgAlt,
                    child: Row(children: [
                      const SizedBox(width: 8),
                      if (widget.mode == DiffMode.split)
                        Expanded(
                            child: Row(children: [
                          Expanded(
                              child: Text('原版本',
                                  style: ui.copyWith(
                                      color: p.textDim, fontSize: 11))),
                          Expanded(
                              child: Text('新版本',
                                  style: ui.copyWith(
                                      color: p.textDim, fontSize: 11))),
                        ]))
                      else
                        const Spacer(),
                      TextButton(
                          style: TextButton.styleFrom(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 8),
                              foregroundColor: p.textDim,
                              textStyle: ui.copyWith(fontSize: 11)),
                          onPressed: () => setState(() => _wrap = !_wrap),
                          child: Text(_wrap ? '自动换行：开' : '自动换行：关')),
                    ])),
                Flexible(
                    fit: FlexFit.loose,
                    child: Listener(
                        onPointerSignal: (event) {
                          if (_wrap ||
                              event is! PointerScrollEvent ||
                              !_horizontal.hasClients) {
                            return;
                          }
                          final dx = event.scrollDelta.dx != 0
                              ? event.scrollDelta.dx
                              : HardwareKeyboard.instance.isShiftPressed
                                  ? event.scrollDelta.dy
                                  : 0.0;
                          if (dx == 0) return;
                          GestureBinding.instance.pointerSignalResolver
                              .register(event, (_) {
                            _horizontal.jumpTo((_horizontal.offset + dx).clamp(
                                0.0, _horizontal.position.maxScrollExtent));
                          });
                        },
                        child: SelectionArea(
                            child: Scrollbar(
                                controller: _vertical,
                                child: SingleChildScrollView(
                                  controller: _vertical,
                                  child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        for (final (i, hunk)
                                            in widget.hunks.indexed)
                                          _HunkView(
                                            key: ValueKey(hunk),
                                            hunk: hunk,
                                            file: widget.file,
                                            index: i,
                                            mode: widget.mode,
                                            onApply: widget.onApply,
                                            staged: widget.staged,
                                            blockKeys: widget.blockKeys,
                                            wrap: _wrap,
                                            offset: offset,
                                            codeWidth:
                                                math.max(_codeWidth, cellWidth),
                                          ),
                                      ]),
                                ))))),
                // Keep the scrollable mounted when wrapping changes, so offset and
                // selected hunk rows survive switching presentation.
                SizedBox(
                    height: !_wrap && overflow > 0 ? 14 : 0,
                    child: Scrollbar(
                      controller: _horizontal,
                      thumbVisibility: !_wrap && overflow > 0,
                      notificationPredicate: (n) => n.depth == 0,
                      child: SingleChildScrollView(
                          controller: _horizontal,
                          scrollDirection: Axis.horizontal,
                          child: SizedBox(
                              width: box.maxWidth + overflow, height: 1)),
                    )),
              ]));
    });
  }
}

class _HunkView extends StatefulWidget {
  const _HunkView({
    super.key,
    required this.hunk,
    required this.file,
    required this.index,
    required this.mode,
    required this.onApply,
    required this.staged,
    required this.blockKeys,
    required this.wrap,
    required this.offset,
    required this.codeWidth,
  });

  final bool wrap;
  final double offset;
  final double codeWidth;
  final String hunk;
  final String file;
  final int index;
  final DiffMode mode;
  final Map<String, GlobalKey> blockKeys;
  final void Function(String patch, bool reverse)? onApply;
  final bool staged;

  @override
  State<_HunkView> createState() => _HunkViewState();
}

class _HunkViewState extends State<_HunkView> {
  /// The key for a row, when that row starts a run of changed lines.
  GlobalKey? _blockKey(int row) => widget.blockKeys['${widget.index}:$row'];

  (String, String, Palette, SyntaxTheme)? _syntaxKey;
  late DiffSyntax _syntax;

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
    final theme = Theming.syntaxOf(context);
    final syntaxKey = (widget.hunk, widget.file, palette, theme);
    if (_syntaxKey != syntaxKey) {
      _syntax = DiffSyntax(widget.hunk, widget.file, palette, theme: theme);
      _syntaxKey = syntaxKey;
    }
    final interactive = widget.onApply != null;
    final headerText = widget.hunk.split('\n').first;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (interactive)
          _HunkActions(
            staged: widget.staged,
            onWhole: () => widget.onApply!(widget.hunk, widget.staged),
            onPicked: _picked.isNotEmpty ? () => _apply(widget.staged) : null,
          ),
        _HunkBar(text: headerText),
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
    final head = parseHunkHeader(widget.hunk.split('\n').first);
    var oldNo = head?.oldStart ?? 0;
    var newNo = head?.newStart ?? 0;

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final changed = line.startsWith('+') || line.startsWith('-');
      final color = line.startsWith('+')
          ? palette.green
          : line.startsWith('-')
              ? palette.red
              : palette.text;
      TextSpan? code;
      if (!line.startsWith('\\')) {
        code = line.startsWith('-')
            ? _syntax.oldLines[oldNo]
            : _syntax.newLines[newNo];
        if (!line.startsWith('+')) oldNo++;
        if (!line.startsWith('-')) newNo++;
      }
      rows.add(_row(
        row: i,
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
          child: _CodeViewport(
              wrap: widget.wrap,
              offset: widget.offset,
              width: widget.codeWidth + 16,
              child: code == null
                  ? Text(line,
                      style: mono.copyWith(color: color), softWrap: widget.wrap)
                  : Text.rich(
                      TextSpan(children: [
                        TextSpan(
                            text: line.isEmpty ? '' : line[0],
                            style: TextStyle(color: color)),
                        code,
                      ]),
                      style: mono.copyWith(color: palette.text),
                      softWrap: widget.wrap)),
        ),
      ));
    }
    return rows;
  }

  /// Fixed-width number columns and two equal text columns, so rows stay aligned
  /// without synchronising two scroll positions. Both text columns share the
  /// horizontal offset; line numbers and actions stay fixed.
  ///
  /// A pure deletion is not a row. It is a gray trapezoid on the divider, the
  /// same fragment the side-by-side viewer paints between the panes: wide on
  /// the old side, pinched to the boundary where the new file has no lines.
  List<Widget> _splitRows(Palette palette, bool interactive) {
    final paired = pairHunkLines(widget.hunk);
    if (paired == null) return _unifiedRows(palette, interactive);

    final rows = <Widget>[];
    final addedFile = paired.head.oldStart == 0 &&
        paired.rows.every((row) => row.left == null);
    final fragments =
        addedFile ? const <DeletionFragment>[] : deletionFragments(widget.hunk);
    for (final (i, row) in paired.rows.indexed) {
      IntraDiff? intra;
      if (row.type == RowType.mod) {
        intra = intraLineDiff(row.left!.text, row.right!.text);
      }
      rows.add(_row(
        row: i,
        picks: row.picks,
        interactive: interactive,
        palette: palette,
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!addedFile) ...[
                _NumCell(cell: row.left),
                Expanded(
                  child: _TextCell(
                    wrap: widget.wrap,
                    offset: widget.offset,
                    codeWidth: widget.codeWidth,
                    cell: row.left,
                    syntax: _syntax.oldLines[row.left?.no],
                    part: intra?.left,
                    intraColor: palette.intraDel,
                    tint: row.type == RowType.del || row.type == RowType.mod
                        ? palette.delRow
                        : null,
                  ),
                ),
                _DividerSlot(
                  row: i,
                  fragments: fragments,
                  onTap: _tap,
                ),
              ],
              _NumCell(cell: row.right),
              Expanded(
                child: _TextCell(
                  wrap: widget.wrap,
                  offset: widget.offset,
                  codeWidth: widget.codeWidth,
                  cell: row.right,
                  syntax: _syntax.newLines[row.right?.no],
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
    // A deletion that ends the hunk starts past the last content row. Pad one
    // empty row per leftover line so every slice of the polygon has a line to
    // paint on; without them the removal disappears.
    if (!addedFile) {
      var tail = 0;
      for (final fragment in fragments) {
        final past = fragment.before + fragment.lines - paired.rows.length;
        if (past > tail) tail = past;
      }
      final line =
          MediaQuery.textScalerOf(context).scale(mono.fontSize!) * mono.height!;
      for (var extra = 0; extra < tail; extra++) {
        rows.add(SizedBox(
          height: line,
          child: Row(children: [
            const SizedBox(width: 44),
            const Expanded(child: SizedBox.shrink()),
            _DividerSlot(
              row: paired.rows.length + extra,
              fragments: fragments,
              onTap: _tap,
            ),
            const SizedBox(width: 44),
            const Expanded(child: SizedBox.shrink()),
          ]),
        ));
      }
    }
    return rows;
  }

  /// The pickable-row wrapper: hover feedback, click/shift-click, and the
  /// selected outline, each of them explicit state.
  Widget _row({
    required int row,
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
      // The block key rides on the outermost node of the row so that
      // ensureVisible scrolls the whole row into view, not just its text.
      key: _blockKey(row),
      decoration: BoxDecoration(
        border: picked ? Border.all(color: palette.accent, width: 1) : null,
      ),
      child: child,
    );

    if (hovered) {
      // Hover brightens the row. Flutter has no brightness filter shorthand,
      // so it is an explicit overlay.
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

/// The bar above each working-file hunk: 暂存此块 applies the
/// whole hunk, 暂存选中行 only the picked lines (dimmed until some are), and
/// the hint says how picking works.
class _HunkActions extends StatelessWidget {
  const _HunkActions({
    required this.staged,
    required this.onWhole,
    required this.onPicked,
  });

  final bool staged;
  final VoidCallback onWhole;
  final VoidCallback? onPicked;

  @override
  Widget build(BuildContext context) {
    final palette = Theming.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 2),
      child: Row(
        children: [
          _SmallButton(label: staged ? '取消暂存此块' : '暂存此块', onTap: onWhole),
          const SizedBox(width: 4),
          _SmallButton(label: staged ? '取消暂存选中行' : '暂存选中行', onTap: onPicked),
          const Spacer(),
          SelectionContainer.disabled(
            child: Text('点选行，⇧ 点选范围',
                style: ui.copyWith(color: palette.textDim, fontSize: 10)),
          ),
        ],
      ),
    );
  }
}

class _HunkBar extends StatelessWidget {
  const _HunkBar({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final palette = Theming.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: palette.bgAlt,
        border: Border(bottom: BorderSide(color: palette.border)),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: mono.copyWith(color: palette.accent),
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
      // Line numbers must stay out of a copied selection, hence the explicit
      // opt-out widget.
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
    required this.syntax,
    required this.part,
    required this.intraColor,
    required this.tint,
    required this.wrap,
    required this.offset,
    required this.codeWidth,
  });

  final bool wrap;
  final double offset;
  final double codeWidth;
  final DiffCell? cell;
  final TextSpan? syntax;
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
    final Widget text = syntax == null
        ? Text(cell!.text, style: style, softWrap: wrap)
        : Text.rich(markIntra(syntax!, part, intraColor),
            style: style, softWrap: wrap);

    return Container(
      width: double.infinity,
      color: tint,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: _CodeViewport(
          wrap: wrap, offset: offset, width: codeWidth, child: text),
    );
  }
}

/// One line of the stripe between the panes. A deleted run is sliced across
/// the rows it covers, so nothing paints outside its own line — a taller
/// polygon is clipped by the scroll view and comes back as a blank.
class _DividerSlot extends StatelessWidget {
  const _DividerSlot({
    required this.row,
    required this.fragments,
    required this.onTap,
  });
  final int row;
  final List<DeletionFragment> fragments;
  final void Function(List<int> picks) onTap;

  @override
  Widget build(BuildContext context) {
    final palette = Theming.of(context);
    final slice = _sliceAt(row, fragments);
    return SizedBox(
      width: _dividerWidth,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: slice == null ? null : () => onTap(slice.picks),
        child: CustomPaint(
          painter: DeletionFragmentPainter(
            lines: 1,
            lineHeight: 1,
            fill: slice == null ? palette.bgAlt : palette.deletedFragment,
            border: palette.red.withValues(alpha: slice == null ? 0 : 0.55),
            topOpen: slice != null && !slice.top,
            bottomOpen: slice != null && !slice.bottom,
          ),
        ),
      ),
    );
  }
}

class _FragmentSlice {
  const _FragmentSlice(this.picks, {required this.top, required this.bottom});
  final List<int> picks;
  final bool top;
  final bool bottom;
}

/// The line of a deleted run that falls on [row], if any.
///
/// [DeletionFragment.before] is the boundary the run starts at, and the run
/// covers the next [DeletionFragment.lines] rows. A run past the last content
/// row is hosted by the padded row the caller adds.
_FragmentSlice? _sliceAt(int row, List<DeletionFragment> fragments) {
  for (final fragment in fragments) {
    final last = fragment.before + fragment.lines - 1;
    if (row < fragment.before || row > last) continue;
    return _FragmentSlice(
      fragment.picks,
      top: row == fragment.before,
      bottom: row == last,
    );
  }
  return null;
}

/// Gray trapezoid of a deleted run, copied from the divider polygon.
///
/// Left edge spans the removed lines. Right edge collapses to the boundary
/// after those lines, because the new side has nothing there. The two edges
/// meet through the same cubic the viewer uses (control points at 30% and
/// 70% of the stripe), which is what keeps a tall deletion a chevron rather
/// than a rectangle of blank lines.
class DeletionFragmentPainter extends CustomPainter {
  const DeletionFragmentPainter({
    required this.lines,
    required this.lineHeight,
    required this.fill,
    required this.border,
    this.topOpen = false,
    this.bottomOpen = false,
  });

  final int lines;
  final double lineHeight;
  final Color fill;
  final Color border;

  /// This slice continues a run that started above, so the top edge is not the
  /// point of the chevron.
  final bool topOpen;

  /// This slice continues below, so the right edge has not reached the point.
  final bool bottomOpen;

  @override
  void paint(Canvas canvas, Size size) {
    if (lines < 1 || size.width < 4 || size.height < 1) return;
    // The stripe is one line tall. A cubic that pinches inside that line
    // collapses to a diagonal stroke — the hatch the screenshots show. Fill
    // the slice instead. The first line draws the point on the left, the last
    // line draws it on the right, and the stack is the gray chevron.
    final mid = size.width * 0.5;
    final path = Path();
    if (!topOpen && !bottomOpen) {
      path
        ..moveTo(0, size.height / 2)
        ..lineTo(mid, 0)
        ..lineTo(size.width, size.height / 2)
        ..lineTo(mid, size.height)
        ..close();
    } else if (!topOpen) {
      path
        ..moveTo(0, size.height / 2)
        ..lineTo(mid, 0)
        ..lineTo(size.width, 0)
        ..lineTo(size.width, size.height)
        ..lineTo(mid, size.height)
        ..close();
    } else if (!bottomOpen) {
      path
        ..moveTo(0, 0)
        ..lineTo(size.width, size.height / 2)
        ..lineTo(0, size.height)
        ..close();
    } else {
      path.addRect(Offset.zero & size);
    }
    canvas.drawPath(path, Paint()..color = fill);
    if (border.a == 0) return;
    final edge = Paint()
      ..color = border
      ..strokeWidth = 2;
    canvas.drawLine(Offset(size.width - 1, 1),
        Offset(size.width - 1, size.height - 1), edge);
  }

  @override
  bool shouldRepaint(DeletionFragmentPainter old) =>
      old.lines != lines ||
      old.lineHeight != lineHeight ||
      old.fill != fill ||
      old.border != border ||
      old.topOpen != topOpen ||
      old.bottomOpen != bottomOpen;
}

/// Clip each column separately so scrolling never moves the divider or gutter.
class _CodeViewport extends StatelessWidget {
  const _CodeViewport(
      {required this.wrap,
      required this.offset,
      required this.width,
      required this.child});
  final bool wrap;
  final double offset;
  final double width;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (wrap) return child;
    return ClipRect(
        child: SizedBox(
            height: MediaQuery.textScalerOf(context).scale(mono.fontSize!) *
                mono.height!,
            child: OverflowBox(
              alignment: Alignment.topLeft,
              minWidth: width,
              maxWidth: width,
              child:
                  Transform.translate(offset: Offset(-offset, 0), child: child),
            )));
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

/// `.hunk-btn`: accent text, filled accent on hover, 0.45 when disabled.
class _SmallButton extends StatefulWidget {
  const _SmallButton({required this.label, required this.onTap});
  final String label;
  final VoidCallback? onTap;

  @override
  State<_SmallButton> createState() => _SmallButtonState();
}

class _SmallButtonState extends State<_SmallButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final palette = Theming.of(context);
    final enabled = widget.onTap != null;
    final hot = _hover && enabled;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Opacity(
          opacity: enabled ? 1 : 0.45,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
            decoration: BoxDecoration(
              color: hot ? palette.accent : palette.bgElev,
              border: Border.all(color: hot ? palette.accent : palette.border),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(widget.label,
                style: ui.copyWith(
                    fontSize: 11,
                    color: hot ? const Color(0xFFFFFFFF) : palette.accent)),
          ),
        ),
      ),
    );
  }
}
