import 'package:flutter/widgets.dart';

import 'git_text.dart';
import 'theme.dart';

const _rowHeight = 22.0;
const _laneWidth = 12.0;

/// The history list with its DAG gutter.
///
/// The DOM version draws these lanes as an inline SVG per row. Flutter has no
/// retained scene graph to hand a path to, so the gutter is a CustomPainter —
/// which is the one place in this port where the Flutter code is shorter than
/// the code it replaces.
class HistoryView extends StatelessWidget {
  const HistoryView({
    super.key,
    required this.layout,
    required this.selected,
    required this.onSelect,
    required this.controller,
  });

  final GraphLayout layout;
  final String? selected;
  final void Function(GraphCommit commit) onSelect;
  final ScrollController controller;

  @override
  Widget build(BuildContext context) {
    final palette = Theming.of(context);
    final gutter = (layout.width + 1) * _laneWidth;

    return ListView.builder(
      controller: controller,
      itemExtent: _rowHeight,
      itemCount: layout.rows.length,
      itemBuilder: (context, i) {
        final row = layout.rows[i];
        final isSelected = row.commit.id == selected;
        return _CommitRow(
          row: row,
          gutter: gutter,
          selected: isSelected,
          palette: palette,
          onTap: () => onSelect(row.commit),
        );
      },
    );
  }
}

class _CommitRow extends StatefulWidget {
  const _CommitRow({
    required this.row,
    required this.gutter,
    required this.selected,
    required this.palette,
    required this.onTap,
  });

  final GraphRow row;
  final double gutter;
  final bool selected;
  final Palette palette;
  final VoidCallback onTap;

  @override
  State<_CommitRow> createState() => _CommitRowState();
}

class _CommitRowState extends State<_CommitRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final c = widget.row.commit;
    final bg = widget.selected
        ? p.bgSel
        : _hover
            ? p.bgHover
            : null;

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: ColoredBox(
          color: bg ?? const Color(0x00000000),
          child: Row(
            children: [
              SizedBox(
                width: widget.gutter,
                height: _rowHeight,
                child: CustomPaint(painter: _LanePainter(widget.row, p)),
              ),
              for (final ref in c.refs) _RefChip(label: ref, palette: p),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(
                    c.summary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ui.copyWith(color: p.text),
                  ),
                ),
              ),
              SizedBox(
                width: 110,
                child: Text(
                  c.author,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ui.copyWith(color: p.textDim, fontSize: 11),
                ),
              ),
              SizedBox(
                width: 78,
                child: Text(
                  _stamp(c.time),
                  style: ui.copyWith(color: p.textDim, fontSize: 11),
                ),
              ),
              const SizedBox(width: 8),
            ],
          ),
        ),
      ),
    );
  }
}

String _stamp(int unixSeconds) {
  final d = DateTime.fromMillisecondsSinceEpoch(unixSeconds * 1000);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}

class _RefChip extends StatelessWidget {
  const _RefChip({required this.label, required this.palette});
  final String label;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    final isTag = label.startsWith('tag: ');
    final color = isTag ? palette.yellow : palette.accent;
    return Container(
      margin: const EdgeInsets.only(right: 4),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        border: Border.all(color: color.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        isTag ? label.substring(5) : label,
        style: ui.copyWith(fontSize: 10, color: color),
      ),
    );
  }
}

/// One row of the DAG: the lanes passing through, the lines down to this
/// commit's parents, and the node itself.
class _LanePainter extends CustomPainter {
  const _LanePainter(this.row, this.palette);
  final GraphRow row;
  final Palette palette;

  static const _laneColors = [
    Color(0xFF3574F0),
    Color(0xFF57965C),
    Color(0xFFC9A76C),
    Color(0xFFCD5B5B),
    Color(0xFF9A7FD0),
    Color(0xFF4FA8B8),
  ];

  Color _color(int col) => _laneColors[col % _laneColors.length];
  double _x(int col) => (col + 0.5) * _laneWidth + 4;

  @override
  void paint(Canvas canvas, Size size) {
    final mid = size.height / 2;
    final stroke = Paint()
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    // Lanes that pass through this row untouched: a straight line top to bottom.
    for (var col = 0; col < row.incoming.length; col++) {
      if (row.incoming[col] == null || col == row.myCol) continue;
      stroke.color = _color(col);
      canvas.drawLine(Offset(_x(col), 0), Offset(_x(col), mid), stroke);
      if (col < row.outgoing.length && row.outgoing[col] != null) {
        canvas.drawLine(Offset(_x(col), mid), Offset(_x(col), size.height), stroke);
      }
    }

    // Incoming edge for this commit's own lane.
    if (row.myCol < row.incoming.length && row.incoming[row.myCol] != null) {
      stroke.color = _color(row.myCol);
      canvas.drawLine(Offset(_x(row.myCol), 0), Offset(_x(row.myCol), mid), stroke);
    }

    // Down to each parent. A parent in another lane gets a curve rather than a
    // dogleg, which is the only reason this is a Path and not two drawLine calls.
    for (final pc in row.parentCols) {
      stroke.color = _color(pc);
      if (pc == row.myCol) {
        canvas.drawLine(
            Offset(_x(pc), mid), Offset(_x(pc), size.height), stroke);
      } else {
        final path = Path()
          ..moveTo(_x(row.myCol), mid)
          ..cubicTo(
            _x(row.myCol), mid + size.height * 0.35,
            _x(pc), mid + size.height * 0.15,
            _x(pc), size.height,
          );
        canvas.drawPath(path, stroke);
      }
    }

    final node = Paint()..color = _color(row.myCol);
    canvas.drawCircle(Offset(_x(row.myCol), mid), 3.4, node);
    canvas.drawCircle(
      Offset(_x(row.myCol), mid),
      3.4,
      Paint()
        ..color = palette.bg
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
  }

  @override
  bool shouldRepaint(_LanePainter old) => old.row != row || old.palette != palette;
}
