import 'dart:async';

import 'package:flutter/material.dart';

import 'git.dart';
import 'theme.dart';

/// Clone a repository, showing git's own progress as it arrives.
///
/// This is the one screen driven by a stream rather than a future: core reports
/// progress through a StreamSink. The last value is the path of the created worktree.
class CloneSheet extends StatefulWidget {
  const CloneSheet({
    super.key,
    required this.onClose,
    required this.onCloned,
    required this.pickDirectory,
  });

  final VoidCallback onClose;

  /// Called with the created worktree path once the clone finishes.
  final void Function(String path) onCloned;

  /// Returns the parent directory to clone into, or null if the user backs out.
  final Future<String?> Function() pickDirectory;

  @override
  State<CloneSheet> createState() => _CloneSheetState();
}

class _CloneSheetState extends State<CloneSheet> {
  final _url = TextEditingController();
  String? _dir;
  StreamSubscription<String>? _sub;

  /// git writes progress with \r for updates and \n for messages; core splits
  /// on either, so each value replaces the line rather than appending to a log.
  String _progress = '';
  String? _error;
  bool _running = false;

  @override
  void dispose() {
    _url.dispose();
    _sub?.cancel();
    super.dispose();
  }

  bool get _ready => _url.text.trim().isNotEmpty && _dir != null && !_running;

  Future<void> _pickDir() async {
    final dir = await widget.pickDirectory();
    if (dir != null && mounted) setState(() => _dir = dir);
  }

  void _start() {
    final dir = _dir;
    if (dir == null) return;

    setState(() {
      _running = true;
      _error = null;
      _progress = '准备中…';
    });

    String? last;
    _sub = Git.clone(_url.text.trim(), dir).listen(
      (line) {
        last = line;
        if (mounted) setState(() => _progress = line);
      },
      onError: (Object e) {
        if (mounted) {
          setState(() {
            _running = false;
            _error = e.toString();
          });
        }
      },
      onDone: () {
        if (!mounted) return;
        setState(() => _running = false);
        // The final value is the created worktree path; without one the clone
        // produced nothing to open.
        final path = last?.trim();
        if (path != null && path.isNotEmpty) widget.onCloned(path);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = Theming.of(context);

    return Positioned.fill(
      child: ColoredBox(
        color: const Color(0x99000000),
        child: Center(
          child: Container(
            width: 560,
            decoration: BoxDecoration(
              color: p.bg,
              border: Border.all(color: p.border),
              borderRadius: BorderRadius.circular(8),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  height: 34,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: p.bgAlt,
                    border: Border(bottom: BorderSide(color: p.border)),
                  ),
                  child: Row(
                    children: [
                      Text('克隆仓库', style: ui.copyWith(color: p.text)),
                      const Spacer(),
                      MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(
                          // Closing mid-clone cancels the stream, but git keeps
                          // going — it is its own process. Say so rather than
                          // implying the clone stopped.
                          onTap: widget.onClose,
                          child:
                              Text('✕', style: ui.copyWith(color: p.textDim)),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        height: 28,
                        child: TextField(
                          controller: _url,
                          enabled: !_running,
                          autofocus: true,
                          style: ui.copyWith(color: p.text, fontSize: 12),
                          cursorColor: p.accent,
                          onChanged: (_) => setState(() {}),
                          decoration: InputDecoration(
                            isDense: true,
                            contentPadding:
                                const EdgeInsets.symmetric(horizontal: 8),
                            hintText: '仓库地址（https://… 或 git@…）',
                            hintStyle:
                                ui.copyWith(color: p.textDim, fontSize: 11),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(4),
                              borderSide: BorderSide(color: p.border),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(4),
                              borderSide: BorderSide(color: p.border),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              _dir ?? '还没选择存放位置',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: ui.copyWith(
                                color: _dir == null ? p.textDim : p.text,
                                fontSize: 11,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          _button(p, '选择位置…', _running ? null : _pickDir),
                        ],
                      ),
                      if (_progress.isNotEmpty || _error != null) ...[
                        const SizedBox(height: 10),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: p.diffBg,
                            border: Border.all(color: p.border),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            _error ?? _progress,
                            style: mono.copyWith(
                              color: _error != null ? p.red : p.textDim,
                              fontSize: 11,
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          _button(p, '取消', widget.onClose),
                          const SizedBox(width: 6),
                          _button(
                            p,
                            _running ? '克隆中…' : '克隆',
                            _ready ? _start : null,
                            primary: true,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _button(Palette p, String label, VoidCallback? onTap,
          {bool primary = false}) =>
      MouseRegion(
        cursor:
            onTap == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: primary && onTap != null ? p.accent : p.bgElev,
              border: Border.all(
                  color: primary && onTap != null ? p.accent : p.border),
              borderRadius: BorderRadius.circular(5),
            ),
            child: Text(
              label,
              style: ui.copyWith(
                color: onTap == null
                    ? p.textDim
                    : (primary ? const Color(0xFFFFFFFF) : p.text),
              ),
            ),
          ),
        ),
      );
}
