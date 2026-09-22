import 'package:flutter/material.dart';

import 'git.dart';
import 'theme.dart';

/// The commit modal. In the DOM version this markup sits in index.html behind
/// `display: none` and a click handler flips it; here it exists only while it is
/// open, which is why the message box needs its state kept somewhere that
/// survives a rebuild — a StatefulWidget rather than a hidden element.
class CommitSheet extends StatefulWidget {
  const CommitSheet({
    super.key,
    required this.changes,
    required this.git,
    required this.onClose,
    required this.onChanged,
    required this.onPickFile,
  });

  final List<FileStatus> changes;
  final Git git;
  final VoidCallback onClose;
  final Future<void> Function() onChanged;
  final void Function(FileStatus file) onPickFile;

  @override
  State<CommitSheet> createState() => _CommitSheetState();
}

class _CommitSheetState extends State<CommitSheet> {
  final _message = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  List<FileStatus> get _staged =>
      widget.changes.where((f) => f.staged).toList();
  List<FileStatus> get _unstaged =>
      widget.changes.where((f) => !f.staged).toList();

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      await widget.onChanged();
    } on GitError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _commit() async {
    final text = _message.text.trim();
    if (text.isEmpty) {
      setState(() => _error = '提交说明不能为空');
      return;
    }
    if (_staged.isEmpty) {
      setState(() => _error = '没有已暂存的改动');
      return;
    }
    await _run(() => widget.git.commit(text));
    if (mounted && _error == null) {
      _message.clear();
      widget.onClose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Theming.of(context);

    return Positioned.fill(
      child: ColoredBox(
        color: const Color(0x99000000),
        child: Center(
          child: Container(
            width: 620,
            height: 520,
            decoration: BoxDecoration(
              color: p.bg,
              border: Border.all(color: p.border),
              borderRadius: BorderRadius.circular(8),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
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
                      Text('提交', style: ui.copyWith(color: p.text)),
                      const Spacer(),
                      GestureDetector(
                        onTap: widget.onClose,
                        child: MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child:
                              Text('✕', style: ui.copyWith(color: p.textDim)),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.only(bottom: 8),
                    children: [
                      _group(p, '已暂存 (${_staged.length})', _staged,
                          staged: true),
                      _group(p, '未暂存 (${_unstaged.length})', _unstaged,
                          staged: false),
                    ],
                  ),
                ),
                if (_error != null)
                  Container(
                    width: double.infinity,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    color: p.red.withValues(alpha: 0.15),
                    child: Text(_error!,
                        style: ui.copyWith(color: p.red, fontSize: 11)),
                  ),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    border: Border(top: BorderSide(color: p.border)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        height: 80,
                        decoration: BoxDecoration(
                          color: p.bgAlt,
                          border: Border.all(color: p.border),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        child: TextField(
                          controller: _message,
                          maxLines: null,
                          expands: true,
                          style: ui.copyWith(color: p.text),
                          cursorColor: p.accent,
                          decoration: InputDecoration.collapsed(
                            hintText: '提交说明',
                            hintStyle: ui.copyWith(color: p.textDim),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          _Button(
                            label: _busy ? '处理中…' : '提交',
                            primary: true,
                            onTap: _busy ? null : _commit,
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

  Widget _group(Palette p, String title, List<FileStatus> files,
      {required bool staged}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
          child:
              Text(title, style: ui.copyWith(color: p.textDim, fontSize: 11)),
        ),
        for (final f in files)
          _FileRow(
            file: f,
            palette: p,
            actionLabel: staged ? '−' : '＋',
            onAction: _busy
                ? null
                : () => _run(() => staged
                    ? widget.git.unstage(f.path)
                    : widget.git.stage(f.path)),
            onTap: () => widget.onPickFile(f),
          ),
      ],
    );
  }
}

class _FileRow extends StatefulWidget {
  const _FileRow({
    required this.file,
    required this.palette,
    required this.actionLabel,
    required this.onAction,
    required this.onTap,
  });

  final FileStatus file;
  final Palette palette;
  final String actionLabel;
  final VoidCallback? onAction;
  final VoidCallback onTap;

  @override
  State<_FileRow> createState() => _FileRowState();
}

class _FileRowState extends State<_FileRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          height: 22,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          color: _hover ? p.bgHover : null,
          child: Row(
            children: [
              SizedBox(
                width: 14,
                child: Text(
                  widget.file.status,
                  style: mono.copyWith(
                    fontSize: 11,
                    color: widget.file.staged ? p.green : p.yellow,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  widget.file.path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ui.copyWith(color: p.text),
                ),
              ),
              // The DOM version keeps this button in the markup and hides it
              // with `.row:hover .act { visibility: visible }`. Opacity is the
              // closest thing that does not change the row's layout.
              Opacity(
                opacity: _hover ? 1 : 0,
                child: GestureDetector(
                  onTap: widget.onAction,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Text(widget.actionLabel,
                        style: ui.copyWith(color: p.accent, fontSize: 14)),
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

class _Button extends StatefulWidget {
  const _Button(
      {required this.label, required this.onTap, this.primary = false});
  final String label;
  final VoidCallback? onTap;
  final bool primary;

  @override
  State<_Button> createState() => _ButtonState();
}

class _ButtonState extends State<_Button> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = Theming.of(context);
    final enabled = widget.onTap != null;
    final bg = widget.primary
        ? (enabled ? p.accent : p.accent.withValues(alpha: 0.4))
        : (_hover ? p.bgHover : p.bgElev);

    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: bg,
            border: Border.all(color: widget.primary ? bg : p.border),
            borderRadius: BorderRadius.circular(5),
          ),
          child: Text(
            widget.label,
            style: ui.copyWith(
              color: widget.primary ? const Color(0xFFFFFFFF) : p.text,
            ),
          ),
        ),
      ),
    );
  }
}
