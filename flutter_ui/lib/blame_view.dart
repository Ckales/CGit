import 'package:flutter/material.dart';

import 'git.dart';
import 'theme.dart';

/// Per-line authorship, shown in the diff pane.
///
/// Consecutive lines from the same commit only print their sha and author once:
/// a file where every row repeats the same hash is unreadable, and the run
/// boundaries are the thing the eye is actually looking for.
class BlameView extends StatelessWidget {
  const BlameView({
    super.key,
    required this.lines,
    required this.onOpenCommit,
  });

  final List<BlameLine> lines;

  /// Clicking a sha opens that commit's diff for this file.
  final void Function(String oid) onOpenCommit;

  @override
  Widget build(BuildContext context) {
    final p = Theming.of(context);
    if (lines.isEmpty) {
      return Container(
        color: p.diffBg,
        alignment: Alignment.center,
        child: Text('没有可归属的内容', style: ui.copyWith(color: p.textDim)),
      );
    }

    return Container(
      color: p.diffBg,
      child: SelectionArea(
        child: ListView.builder(
          itemCount: lines.length,
          itemBuilder: (context, i) {
            final line = lines[i];
            final startsRun = i == 0 || lines[i - 1].oid != line.oid;
            return _BlameRow(
              line: line,
              number: i + 1,
              startsRun: startsRun,
              onOpenCommit: () => onOpenCommit(line.oid),
            );
          },
        ),
      ),
    );
  }
}

class _BlameRow extends StatefulWidget {
  const _BlameRow({
    required this.line,
    required this.number,
    required this.startsRun,
    required this.onOpenCommit,
  });

  final BlameLine line;
  final int number;
  final bool startsRun;
  final VoidCallback onOpenCommit;

  @override
  State<_BlameRow> createState() => _BlameRowState();
}

class _BlameRowState extends State<_BlameRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = Theming.of(context);
    final l = widget.line;

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: ColoredBox(
        color:
            _hover ? p.bgHover.withValues(alpha: 0.4) : const Color(0x00000000),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // The sha is the only clickable part, so it is the only part that
            // takes the pointer cursor.
            SizedBox(
              width: 72,
              child: widget.startsRun
                  ? Tooltip(
                      message: '${l.summary}\n${l.author}',
                      child: MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(
                          onTap: widget.onOpenCommit,
                          child: Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: Text(
                              l.oid.substring(0, 7),
                              style: mono.copyWith(color: p.accent),
                            ),
                          ),
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
            SizedBox(
              width: 120,
              child: widget.startsRun
                  ? Text(
                      l.author,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: mono.copyWith(color: p.textDim),
                    )
                  : const SizedBox.shrink(),
            ),
            SizedBox(
              width: 52,
              child: SelectionContainer.disabled(
                child: Text(
                  '${widget.number}',
                  textAlign: TextAlign.right,
                  style: mono.copyWith(color: p.textDim),
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(left: 10),
                child: Text(l.content, style: mono.copyWith(color: p.text)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
