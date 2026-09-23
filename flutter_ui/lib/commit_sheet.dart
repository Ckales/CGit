import 'package:flutter/material.dart';

import 'ai_settings.dart';
import 'context_menu.dart';
import 'git.dart';
import 'git_text.dart';
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
    this.ai,
  });

  final List<FileStatus> changes;
  final Git git;
  final VoidCallback onClose;
  final Future<void> Function() onChanged;
  final void Function(FileStatus file) onPickFile;

  /// Null when AI settings have not loaded; the generate button stays disabled.
  final AiSettings? ai;

  @override
  State<CommitSheet> createState() => _CommitSheetState();
}

class _CommitSheetState extends State<CommitSheet> {
  final _message = TextEditingController();
  final _author = TextEditingController();
  String? _error;
  bool _busy = false;
  bool _amend = false;
  bool _signoff = false;
  bool _generating = false;

  @override
  void dispose() {
    _message.dispose();
    _author.dispose();
    super.dispose();
  }

  /// Amending starts from HEAD's message, the way `git commit --amend` does —
  /// otherwise the user retypes what they are amending.
  Future<void> _toggleAmend(bool on) async {
    setState(() => _amend = on);
    if (!on || _message.text.trim().isNotEmpty) return;
    try {
      final head = await widget.git.headMessage();
      if (mounted) _message.text = head.trim();
    } on GitError {
      // No HEAD yet (an empty repo): nothing to prefill, and amend will fail
      // on its own terms with a message git words better than we would.
    }
  }

  Future<void> _generateMessage() async {
    final ai = widget.ai;
    if (ai == null || !ai.isConfigured) return;

    setState(() {
      _generating = true;
      _error = null;
    });
    try {
      final diff = await widget.git.stagedDiff();
      if (diff.trim().isEmpty) {
        setState(() => _error = '没有已暂存的改动可供生成');
        return;
      }
      final token = await ai.readToken() ?? '';
      final text = await Git.aiChat(
        url: aiEndpoint(ai.baseUrl),
        token: token,
        model: ai.model,
        system: ai.prompt,
        user: diff,
      );
      if (mounted) _message.text = text.trim();
    } on GitError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  Future<void> _pickPastMessage(Offset at) async {
    try {
      final messages = await widget.git.recentMessages();
      if (!mounted || messages.isEmpty) return;
      await showRepoMenu(
        context: context,
        position: at,
        items: [
          for (final m in messages.take(20))
            MenuAction(
              // One line in the menu; the full text still lands in the box.
              m.split('\n').first,
              () => _message.text = m.trimRight(),
            ),
        ],
      );
    } on GitError catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
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
    // Amending is allowed with nothing staged — it rewords HEAD.
    if (_staged.isEmpty && !_amend) {
      setState(() => _error = '没有已暂存的改动');
      return;
    }
    await _run(() => widget.git.commit(
          text,
          amend: _amend,
          signoff: _signoff,
          author: _author.text.trim().isEmpty ? null : _author.text.trim(),
        ));
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
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          _Check(
                            label: '修正提交',
                            tooltip: '修补上一个提交而不新建提交',
                            value: _amend,
                            onChanged: _busy ? null : _toggleAmend,
                          ),
                          const SizedBox(width: 12),
                          _Check(
                            label: 'Sign-off',
                            tooltip: '在提交说明末尾追加 Signed-off-by',
                            value: _signoff,
                            onChanged: _busy
                                ? null
                                : (v) => setState(() => _signoff = v),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: SizedBox(
                              height: 22,
                              child: TextField(
                                controller: _author,
                                style: ui.copyWith(color: p.text, fontSize: 11),
                                cursorColor: p.accent,
                                decoration: InputDecoration(
                                  isDense: true,
                                  contentPadding:
                                      const EdgeInsets.symmetric(horizontal: 6),
                                  hintText: '作者（留空用 git 配置）',
                                  hintStyle:
                                      ui.copyWith(color: p.textDim, fontSize: 11),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(3),
                                    borderSide: BorderSide(color: p.border),
                                  ),
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(3),
                                    borderSide: BorderSide(color: p.border),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          _Button(
                            label: '历史说明',
                            onTapAt: _busy ? null : _pickPastMessage,
                          ),
                          const SizedBox(width: 6),
                          _Button(
                            label: _generating ? '生成中…' : 'AI 生成',
                            onTap: (widget.ai?.isConfigured ?? false) &&
                                    !_generating &&
                                    !_busy
                                ? _generateMessage
                                : null,
                          ),
                          const Spacer(),
                          _Button(
                            label: _busy ? '处理中…' : (_amend ? '修正提交' : '提交'),
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

/// A labelled checkbox drawn in the app's own palette rather than Material's,
/// so it matches the rest of the sheet.
class _Check extends StatelessWidget {
  const _Check({
    required this.label,
    required this.tooltip,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String tooltip;
  final bool value;
  final void Function(bool)? onChanged;

  @override
  Widget build(BuildContext context) {
    final p = Theming.of(context);
    final enabled = onChanged != null;
    return Tooltip(
      message: tooltip,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: GestureDetector(
          onTap: enabled ? () => onChanged!(!value) : null,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 13,
                height: 13,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: value ? p.accent : p.bg,
                  border: Border.all(color: value ? p.accent : p.border),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: value
                    ? const Text('✓',
                        style: TextStyle(
                            fontSize: 9,
                            color: Color(0xFFFFFFFF),
                            height: 1))
                    : null,
              ),
              const SizedBox(width: 5),
              Text(label,
                  style: ui.copyWith(
                      color: enabled ? p.text : p.textDim, fontSize: 11)),
            ],
          ),
        ),
      ),
    );
  }
}

class _Button extends StatefulWidget {
  const _Button({
    required this.label,
    this.onTap,
    this.onTapAt,
    this.primary = false,
  });
  final String label;
  final VoidCallback? onTap;

  /// For buttons that open a menu at the pointer.
  final void Function(Offset position)? onTapAt;
  final bool primary;

  @override
  State<_Button> createState() => _ButtonState();
}

class _ButtonState extends State<_Button> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = Theming.of(context);
    final enabled = widget.onTap != null || widget.onTapAt != null;
    // Same rule as the merge window: a disabled primary loses the accent
    // instead of fading it, so "cannot press this" is unmistakable.
    final bg = widget.primary && enabled
        ? p.accent
        : (_hover && enabled ? p.bgHover : p.bgElev);

    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        onTapUp: widget.onTapAt == null
            ? null
            : (d) => widget.onTapAt!(d.globalPosition),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: bg,
            border: Border.all(color: widget.primary && enabled ? bg : p.border),
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
