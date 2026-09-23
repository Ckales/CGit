import 'package:flutter/material.dart';

import 'ai_settings.dart';
import 'context_menu.dart';
import 'git.dart';
import 'git_text.dart';
import 'theme.dart';

/// The commit modal, laid out like the Tauri one: the change tree and commit
/// box on the left, the main window's diff pane on the right.
///
/// The Tauri app moves the diff pane element into the dialog while it is open.
/// The Flutter equivalent is [diffPane]: main.dart hands over the widget it
/// already builds, so hunk and line staging, ↑/↓ navigation and 并排 all work
/// here with no second diff view to keep in step.
class CommitSheet extends StatefulWidget {
  const CommitSheet({
    super.key,
    required this.changes,
    required this.git,
    required this.repoName,
    required this.branch,
    required this.diffPane,
    required this.onClose,
    required this.onChanged,
    required this.onPickFile,
    required this.onCommitAndPush,
    required this.onCreatePatch,
    this.selected,
    this.menuFor,
    this.onDiscard,
    this.ai,
    this.docked = false,
  });

  /// Inline under the history, scoped to the repo picked in the sidebar — the
  /// Tauri docked commit panel — instead of a dialog over the window.
  final bool docked;

  final List<FileStatus> changes;
  final Git git;
  final String repoName;
  final String branch;
  final Widget diffPane;
  final VoidCallback onClose;
  final Future<void> Function() onChanged;
  final void Function(FileStatus file) onPickFile;

  /// The file the diff pane is showing, highlighted in the tree.
  final ({String path, bool staged})? selected;

  /// The same right-click menu the main window's changes list uses.
  final List<MenuAction> Function(FileStatus file)? menuFor;

  /// 丢弃 on an unstaged row. The caller confirms first.
  final Future<void> Function(FileStatus file)? onDiscard;

  /// Runs after a successful commit. Push is the caller's business — it owns
  /// the network lock and the rejected-push retry, neither of which belongs in
  /// a dialog.
  final Future<void> Function() onCommitAndPush;

  /// Export the working-tree changes as a patch. `toClipboard` picks between
  /// the clipboard and a save dialog.
  final Future<void> Function({required bool toClipboard}) onCreatePatch;

  /// Null when AI settings have not loaded; the generate button stays disabled.
  final AiSettings? ai;

  @override
  State<CommitSheet> createState() => _CommitSheetState();
}

class _CommitSheetState extends State<CommitSheet> {
  final _message = TextEditingController();
  final _author = TextEditingController();
  final _filter = TextEditingController();
  String? _error;
  bool _busy = false;
  bool _amend = false;
  bool _signoff = false;
  bool _generating = false;

  /// Folded tree nodes, keyed like the Tauri `collapsedChangeNodes`. Kept
  /// across refreshes so staging a file does not reopen what was folded.
  final _collapsed = <String>{};

  @override
  void dispose() {
    _message.dispose();
    _author.dispose();
    _filter.dispose();
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

  /// Everything, before the filter. 提交 and ＋全部 act on these — filtering the
  /// list must not quietly change what a button does to the repository.
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

  Future<void> _commit({bool push = false}) async {
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
      // Closed first: the push reports through the status bar, and a dialog
      // sitting on top of it would hide the one thing worth watching.
      if (push) await widget.onCommitAndPush();
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Theming.of(context);

    final panel = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(widget.docked ? '提交 · ${widget.repoName}' : '提交',
                style:
                    ui.copyWith(color: p.text, fontWeight: FontWeight.w600)),
            const Spacer(),
            _Btn(
              tooltip: widget.docked ? '收起' : '关闭 (Esc)',
              icon: true,
              onTap: widget.onClose,
              child: _label(p, '✕', size: 13),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: 360, child: _changesColumn(p)),
              const SizedBox(width: 12),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: p.bg,
                    border: Border.all(color: p.border),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: widget.diffPane,
                ),
              ),
            ],
          ),
        ),
      ],
    );

    if (widget.docked) {
      return Container(
        color: p.bgAlt,
        padding: const EdgeInsets.all(12),
        child: panel,
      );
    }

    return Positioned.fill(
      child: ColoredBox(
        color: const Color(0x80000000),
        child: LayoutBuilder(
          builder: (context, box) => Center(
            child: Container(
              // `width: min(1240px, 96vw); height: 88vh` in the Tauri CSS.
              width: box.maxWidth * 0.96 > 1240 ? 1240 : box.maxWidth * 0.96,
              height: box.maxHeight * 0.88,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: p.bgAlt,
                border: Border.all(color: p.border),
                borderRadius: BorderRadius.circular(8),
                boxShadow: const [
                  BoxShadow(
                      color: Color(0x80000000),
                      blurRadius: 32,
                      offset: Offset(0, 8)),
                ],
              ),
              child: panel,
            ),
          ),
        ),
      ),
    );
  }

  Widget _label(Palette p, String text, {double size = 15, Color? color}) =>
      Text(text,
          style:
              ui.copyWith(color: color ?? p.text, fontSize: size, height: 1.4));

  Widget _changesColumn(Palette p) {
    final hasChanges = widget.changes.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('改动',
                style: ui.copyWith(
                    color: p.textDim,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5)),
            const SizedBox(width: 8),
            Expanded(
              child: _Field(
                controller: _filter,
                hint: '过滤路径',
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 8),
            _Btn(
              tooltip: '暂存全部',
              icon: true,
              onTap: _busy || _unstaged.isEmpty
                  ? null
                  : () => _run(() => widget.git.stageAll()),
              child: _label(p, '＋全部'),
            ),
            const SizedBox(width: 8),
            _Btn(
              tooltip: '取消暂存全部',
              icon: true,
              onTap: _busy || _staged.isEmpty
                  ? null
                  : () => _run(() => widget.git.unstageAll()),
              child: _label(p, '−全部'),
            ),
            const SizedBox(width: 8),
            _Btn(
              tooltip: '把本地改动导出成补丁（右键复制到剪贴板）',
              icon: true,
              onTap: _busy || !hasChanges
                  ? null
                  : () => widget.onCreatePatch(toClipboard: false),
              onSecondaryTap: _busy || !hasChanges
                  ? null
                  : () => widget.onCreatePatch(toClipboard: true),
              child: _label(p, '补丁'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Expanded(child: _tree(p)),
        if (_error != null)
          Container(
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: p.red.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(4),
            ),
            child:
                Text(_error!, style: ui.copyWith(color: p.red, fontSize: 11)),
          ),
        const SizedBox(height: 12),
        _commitBox(p),
      ],
    );
  }

  /* ---------- change tree ---------- */

  Widget _tree(Palette p) {
    final needle = _filter.text.trim().toLowerCase();
    final files = needle.isEmpty
        ? widget.changes
        : widget.changes
            .where((f) => f.path.toLowerCase().contains(needle))
            .toList();
    if (files.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(6),
        child: Text(needle.isEmpty ? '工作区干净' : '没有匹配的文件',
            style: ui.copyWith(color: p.textDim, fontSize: 12)),
      );
    }

    // A path staged and then edited again shows up twice. Both stay leaves,
    // and only that pair gets a 已暂存 / 未暂存 suffix — the Tauri rule.
    final occurrences = <String, int>{};
    for (final f in files) {
      occurrences[f.path] = (occurrences[f.path] ?? 0) + 1;
    }
    // TreeFile has no ==, so an identity map takes each leaf back to its row.
    final byLeaf = Map<TreeFile, FileStatus>.identity();
    final leaves = <TreeFile>[];
    for (final f in files) {
      final leaf = TreeFile(f.path, f.status);
      byLeaf[leaf] = f;
      leaves.add(leaf);
    }
    final root = pathTree(leaves, collapseSingleChild: false);
    // A filter forces every node open, or a match could sit in a folded folder.
    final forceOpen = needle.isNotEmpty;

    final rows = <Widget>[];
    void addNode(TreeNode node, String parent, int depth) {
      for (final dir in node.dirs) {
        final path = parent.isEmpty ? dir.name : '$parent/${dir.name}';
        final key = 'dir|$path';
        final open = forceOpen || !_collapsed.contains(key);
        final dirFiles = <FileStatus>[];
        void collect(TreeNode n) {
          for (final leaf in n.files) {
            dirFiles.add(byLeaf[leaf]!);
          }
          for (final d in n.dirs) {
            collect(d);
          }
        }

        collect(dir);
        rows.add(_TreeRow(
          depth: depth,
          open: open,
          onToggle: forceOpen ? null : () => _toggleNode(key),
          check: _groupCheck(p, dirFiles),
          children: [
            FolderIcon(color: p.textDim),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                '${dir.name}  ${_distinctPaths(dirFiles)} 个文件',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ui.copyWith(color: p.text, fontSize: 12),
              ),
            ),
          ],
        ));
        if (open) addNode(dir, path, depth + 1);
      }
      for (final leaf in node.files) {
        final f = byLeaf[leaf]!;
        final name = f.path.split('/').last;
        rows.add(_fileRow(
          p,
          f,
          depth,
          (occurrences[f.path] ?? 0) > 1
              ? '$name · ${f.staged ? '已暂存' : '未暂存'}'
              : name,
        ));
      }
    }

    const rootKey = 'root';
    final rootOpen = forceOpen || !_collapsed.contains(rootKey);
    rows.add(_TreeRow(
      depth: 0,
      open: rootOpen,
      onToggle: forceOpen ? null : () => _toggleNode(rootKey),
      check: _groupCheck(p, files),
      children: [
        Flexible(
          child: Text(
            '${widget.repoName}  ${_distinctPaths(files)} 个文件',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ui.copyWith(
                color: p.accent, fontSize: 12, fontWeight: FontWeight.w700),
          ),
        ),
        if (widget.branch.isNotEmpty) ...[
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: p.bgElev,
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(widget.branch,
                style: ui.copyWith(color: p.textDim, fontSize: 10)),
          ),
        ],
      ],
    ));
    if (rootOpen) addNode(root, '', 1);

    return ListView(children: rows);
  }

  static int _distinctPaths(List<FileStatus> files) =>
      files.map((f) => f.path).toSet().length;

  void _toggleNode(String key) => setState(() {
        if (!_collapsed.remove(key)) _collapsed.add(key);
      });

  /// Tri-state box for a repo or folder row: ticked when every file under it
  /// is staged, dashed when some are. Clicking stages the rest, or unstages
  /// all when everything already was. Conflicts are left out — they have to be
  /// resolved, not staged from a checkbox.
  Widget _groupCheck(Palette p, List<FileStatus> files) {
    final actionable = files.where((f) => f.status != 'conflict').toList();
    final stagedCount = actionable.where((f) => f.staged).length;
    final all = actionable.isNotEmpty && stagedCount == actionable.length;
    final paths = actionable.map((f) => f.path).toSet().toList();
    return _Check3(
      value: all ? true : (stagedCount > 0 ? null : false),
      tooltip: actionable.isEmpty ? '先解决冲突' : (all ? '取消暂存此组' : '暂存此组'),
      onTap: _busy || actionable.isEmpty
          ? null
          : () => _run(() => all
              ? widget.git.unstageAll(files: paths)
              : widget.git.stageAll(files: paths)),
    );
  }

  Widget _fileRow(Palette p, FileStatus f, int depth, String label) {
    final conflict = f.status == 'conflict';
    final sel = widget.selected;
    return _TreeRow(
      depth: depth,
      leaf: true,
      selected: sel != null && sel.path == f.path && sel.staged == f.staged,
      tooltip: f.path,
      onPress: () => widget.onPickFile(f),
      onMenuAt: widget.menuFor == null
          ? null
          : (pos) => showRepoMenu(
              context: context, position: pos, items: widget.menuFor!(f)),
      check: _Check3(
        value: f.staged,
        tooltip: conflict ? '先解决冲突' : (f.staged ? '取消暂存' : '暂存'),
        onTap: _busy || conflict
            ? null
            : () => _run(() => f.staged
                ? widget.git.unstage(f.path)
                : widget.git.stage(f.path)),
      ),
      // Discarding restores the worktree from the index, so it means nothing
      // on a staged row — only offered where it does something.
      trailing: !f.staged && !conflict && widget.onDiscard != null
          ? _DiscardButton(onTap: () => widget.onDiscard!(f))
          : null,
      children: [
        StatusBadge(status: f.status),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ui.copyWith(color: p.text, fontSize: 12),
          ),
        ),
      ],
    );
  }

  /* ---------- commit box ---------- */

  Widget _commitBox(Palette p) {
    final aiReady =
        (widget.ai?.isConfigured ?? false) && !_generating && !_busy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _MessageBox(controller: _message),
        const SizedBox(height: 8),
        Row(
          children: [
            _Check(
              label: '修正提交',
              tooltip: '修补上一个提交而不新建提交',
              value: _amend,
              onChanged: _busy ? null : _toggleAmend,
            ),
            const SizedBox(width: 14),
            _Check(
              label: 'Sign-off 提交',
              tooltip: '在提交说明末尾追加 Signed-off-by',
              value: _signoff,
              onChanged: _busy ? null : (v) => setState(() => _signoff = v),
            ),
            const SizedBox(width: 14),
            Text('作者', style: ui.copyWith(color: p.textDim, fontSize: 11)),
            const SizedBox(width: 6),
            Expanded(
              child: Tooltip(
                message: '覆盖本次提交的作者，留空则用 git 配置',
                waitDuration: const Duration(milliseconds: 600),
                child: _Field(controller: _author, hint: '名字 <邮箱>'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 28,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              _Btn(
                tooltip: '使用历史提交说明',
                icon: true,
                onTapAt: _busy ? null : _pickPastMessage,
                child: _Glyph.history(color: p.text),
              ),
              const SizedBox(width: 6),
              _Btn(
                tooltip: _generating ? '生成中…' : '用 AI 生成提交说明',
                icon: true,
                onTap: aiReady ? _generateMessage : null,
                child: _Glyph.sparkle(color: p.text),
              ),
              const SizedBox(width: 6),
              _Btn(
                primary: true,
                joinRight: true,
                onTap: _busy ? null : () => _commit(),
                child: Text(
                  _busy ? '处理中…' : (_amend ? '修正提交' : '提交'),
                  style: ui.copyWith(color: const Color(0xFFFFFFFF)),
                ),
              ),
              _Btn(
                primary: true,
                joinLeft: true,
                tooltip: '更多提交操作',
                onTapAt: _busy
                    ? null
                    : (pos) => showRepoMenu(
                          context: context,
                          position: pos,
                          alignRight: true,
                          items: [
                            MenuAction('提交并推送', () => _commit(push: true)),
                          ],
                        ),
                child: const Chevron(color: Color(0xFFFFFFFF)),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/* ---------- pieces ---------- */

/// One row of the change tree: disclosure triangle (folders), checkbox, then
/// the row's own content. Indented `6 + depth × 14`px, as in the Tauri CSS.
class _TreeRow extends StatefulWidget {
  const _TreeRow({
    required this.depth,
    required this.check,
    required this.children,
    this.open = false,
    this.leaf = false,
    this.selected = false,
    this.onToggle,
    this.onPress,
    this.onMenuAt,
    this.trailing,
    this.tooltip,
  });

  final int depth;
  final Widget check;
  final List<Widget> children;
  final bool open;
  final bool leaf;
  final bool selected;
  final VoidCallback? onToggle;
  final VoidCallback? onPress;
  final void Function(Offset position)? onMenuAt;
  final Widget? trailing;
  final String? tooltip;

  @override
  State<_TreeRow> createState() => _TreeRowState();
}

class _TreeRowState extends State<_TreeRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = Theming.of(context);
    final row = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // On press, as in the Tauri list: a watcher refresh landing between
        // press and release would otherwise swallow the click.
        onTapDown: widget.leaf ? (_) => widget.onPress?.call() : null,
        onTap: widget.leaf ? null : widget.onToggle,
        onSecondaryTapUp: widget.onMenuAt == null
            ? null
            : (d) => widget.onMenuAt!(d.globalPosition),
        child: Container(
          height: 26,
          padding: EdgeInsets.only(left: 6.0 + widget.depth * 14, right: 6),
          decoration: BoxDecoration(
            color: widget.selected ? p.bgSel : (_hover ? p.bgElev : null),
            borderRadius: BorderRadius.circular(5),
          ),
          child: Row(
            children: [
              if (!widget.leaf) ...[
                Disclosure(open: widget.open, color: p.textDim),
                const SizedBox(width: 6),
              ],
              widget.check,
              const SizedBox(width: 6),
              ...widget.children,
              if (widget.trailing != null)
                Opacity(opacity: _hover ? 1 : 0, child: widget.trailing),
            ],
          ),
        ),
      ),
    );
    return widget.tooltip == null
        ? row
        : Tooltip(
            message: widget.tooltip!,
            waitDuration: const Duration(milliseconds: 800),
            child: row,
          );
  }
}

/// The `border: 4px solid transparent; border-left-color` triangle the Tauri
/// summary rows draw, turned 90° when open.
class Disclosure extends StatelessWidget {
  const Disclosure({super.key, required this.open, required this.color});
  final bool open;
  final Color color;

  @override
  Widget build(BuildContext context) => Transform.rotate(
        angle: open ? 1.5708 : 0,
        child: CustomPaint(
            size: const Size(8, 8), painter: _TrianglePainter(color)),
      );
}

class _TrianglePainter extends CustomPainter {
  _TrianglePainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(2, 0)
      ..lineTo(6, 4)
      ..lineTo(2, 8)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_TrianglePainter old) => old.color != color;
}

/// `.tree-folder-icon`: a 13×9 outline with a small tab on top.
class FolderIcon extends StatelessWidget {
  const FolderIcon({super.key, required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: const Size(13, 12), painter: _FolderPainter(color));
}

class _FolderPainter extends CustomPainter {
  _FolderPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawRRect(
        RRect.fromLTRBR(0.5, 3.5, 12.5, 11.5, const Radius.circular(2)),
        stroke);
    final tab = Path()
      ..moveTo(1.5, 3.5)
      ..lineTo(1.5, 1.5)
      ..quadraticBezierTo(1.5, 0.5, 2.5, 0.5)
      ..lineTo(6.5, 0.5)
      ..quadraticBezierTo(7.5, 0.5, 7.5, 1.5)
      ..lineTo(7.5, 3.5);
    canvas.drawPath(tab, stroke);
  }

  @override
  bool shouldRepaint(_FolderPainter old) => old.color != color;
}

/// `.badge`: a 16px square with the status initial.
class StatusBadge extends StatelessWidget {
  const StatusBadge({super.key, required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    final p = Theming.of(context);
    final (bg, fg) = switch (status) {
      'new' => (p.green, const Color(0xFFFFFFFF)),
      'modified' => (p.yellow, const Color(0xFF1E1F22)),
      'deleted' => (p.red, const Color(0xFFFFFFFF)),
      'renamed' => (p.accent, const Color(0xFFFFFFFF)),
      'conflict' => (p.red, const Color(0xFFFFFFFF)),
      _ => (p.textDim, const Color(0xFFFFFFFF)),
    };
    return Container(
      width: 16,
      height: 16,
      alignment: Alignment.center,
      decoration:
          BoxDecoration(color: bg, borderRadius: BorderRadius.circular(3)),
      child: Text(
        status == 'conflict' || status.isEmpty ? '!' : status[0].toUpperCase(),
        style: ui.copyWith(
            color: fg, fontSize: 10, fontWeight: FontWeight.w700, height: 1),
      ),
    );
  }
}

/// A checkbox with the Tauri tree's three states: ticked, clear, and dashed
/// (`value == null`) for a folder that is partly staged.
class _Check3 extends StatelessWidget {
  const _Check3({required this.value, required this.tooltip, this.onTap});
  final bool? value;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = Theming.of(context);
    final on = value != false;
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        cursor:
            onTap == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Opacity(
            opacity: onTap == null ? 0.45 : 1,
            child: Container(
              width: 14,
              height: 14,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: on ? p.accent : p.bg,
                border: Border.all(color: on ? p.accent : p.border),
                borderRadius: BorderRadius.circular(3),
              ),
              child: value == null
                  ? Container(
                      width: 8, height: 2, color: const Color(0xFFFFFFFF))
                  : value!
                      ? const Text('✓',
                          style: TextStyle(
                              fontSize: 10,
                              color: Color(0xFFFFFFFF),
                              height: 1,
                              fontWeight: FontWeight.w700))
                      : null,
            ),
          ),
        ),
      ),
    );
  }
}

class _DiscardButton extends StatefulWidget {
  const _DiscardButton({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_DiscardButton> createState() => _DiscardButtonState();
}

class _DiscardButtonState extends State<_DiscardButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = Theming.of(context);
    return Tooltip(
      message: '丢弃工作区改动',
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
            decoration: BoxDecoration(
              color: _hover ? p.bgElev : null,
              border: Border.all(
                  color: _hover ? p.border : const Color(0x00000000)),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text('丢弃', style: ui.copyWith(color: p.red, fontSize: 11)),
          ),
        ),
      ),
    );
  }
}

/// The Tauri `textarea`: 70px, own background, accent border on focus.
class _MessageBox extends StatefulWidget {
  const _MessageBox({required this.controller});
  final TextEditingController controller;

  @override
  State<_MessageBox> createState() => _MessageBoxState();
}

class _MessageBoxState extends State<_MessageBox> {
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = Theming.of(context);
    return Container(
      height: 70,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: p.bg,
        border: Border.all(color: _focus.hasFocus ? p.accent : p.border),
        borderRadius: BorderRadius.circular(6),
      ),
      child: TextField(
        controller: widget.controller,
        focusNode: _focus,
        // The dialog opens to write a message, as the Tauri one focuses it.
        autofocus: true,
        maxLines: null,
        expands: true,
        style: ui.copyWith(color: p.text, fontSize: 12),
        cursorColor: p.accent,
        decoration: InputDecoration.collapsed(
          hintText: '提交说明',
          hintStyle: ui.copyWith(color: p.textDim, fontSize: 12),
        ),
      ),
    );
  }
}

/// `.filter-input` / the author box: 11px, filled, accent border on focus.
class _Field extends StatelessWidget {
  const _Field({required this.controller, required this.hint, this.onChanged});
  final TextEditingController controller;
  final String hint;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    final p = Theming.of(context);
    OutlineInputBorder border(Color c) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: BorderSide(color: c),
        );
    return TextField(
      controller: controller,
      onChanged: onChanged,
      style: ui.copyWith(color: p.text, fontSize: 11),
      cursorColor: p.accent,
      decoration: InputDecoration(
        isDense: true,
        // 22px: 11px × 1.3 line + 8px each side, less the 8px desktop's
        // compact visual density takes off.
        contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        hintText: hint,
        hintStyle: ui.copyWith(color: p.textDim, fontSize: 11),
        filled: true,
        fillColor: p.bgElev,
        border: border(p.border),
        enabledBorder: border(p.border),
        focusedBorder: border(p.accent),
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
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: GestureDetector(
          onTap: enabled ? () => onChanged!(!value) : null,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _Check3(
                  value: value,
                  tooltip: tooltip,
                  onTap: enabled ? () => onChanged!(!value) : null),
              const SizedBox(width: 6),
              Text(label, style: ui.copyWith(color: p.textDim, fontSize: 11)),
            ],
          ),
        ),
      ),
    );
  }
}

/// The Tauri `button`: raised background, 6px corners, 0.45 opacity when
/// disabled. `icon` is `.icon-btn` (tight horizontal padding); `primary` is
/// the accent 提交; `joinLeft` / `joinRight` square off the split button's
/// inner corners.
class _Btn extends StatefulWidget {
  const _Btn({
    required this.child,
    this.onTap,
    this.onTapAt,
    this.onSecondaryTap,
    this.tooltip,
    this.icon = false,
    this.primary = false,
    this.joinLeft = false,
    this.joinRight = false,
  });

  final Widget child;
  final VoidCallback? onTap;
  final void Function(Offset position)? onTapAt;
  final VoidCallback? onSecondaryTap;
  final String? tooltip;
  final bool icon;
  final bool primary;
  final bool joinLeft;
  final bool joinRight;

  @override
  State<_Btn> createState() => _BtnState();
}

class _BtnState extends State<_Btn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = Theming.of(context);
    final enabled = widget.onTap != null || widget.onTapAt != null;
    final bg = widget.primary
        ? (_hover && enabled ? const Color(0xFF4A80F5) : p.accent)
        : (_hover && enabled ? p.bgHover : p.bgElev);
    const r = Radius.circular(6);
    final button = MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        onTapUp: widget.onTapAt == null
            ? null
            : (_) => widget.onTapAt!(
                menuAnchorBelow(context, right: widget.joinLeft)),
        onSecondaryTap: widget.onSecondaryTap,
        child: Opacity(
          opacity: enabled ? 1 : 0.45,
          child: Container(
            alignment: Alignment.center,
            padding: EdgeInsets.symmetric(
                horizontal: widget.joinLeft
                    ? 9
                    : widget.primary
                        ? 20
                        : (widget.icon ? 8 : 12)),
            decoration: BoxDecoration(
              color: bg,
              border: widget.joinLeft
                  ? const Border(left: BorderSide(color: Color(0x40FFFFFF)))
                  : Border.all(color: widget.primary ? p.accent : p.border),
              borderRadius: BorderRadius.horizontal(
                left: widget.joinLeft ? Radius.zero : r,
                right: widget.joinRight ? Radius.zero : r,
              ),
            ),
            child: widget.child,
          ),
        ),
      ),
    );
    return widget.tooltip == null
        ? button
        : Tooltip(
            message: widget.tooltip!,
            waitDuration: const Duration(milliseconds: 600),
            child: button,
          );
  }
}

/// The two 16×16 SVG icons of the Tauri commit actions, stroked the same way.
class _Glyph extends StatelessWidget {
  const _Glyph._(this.build_, this.color, this.width);

  /// `M2.5 4.8 V1.8 M2.5 4.8 H5.5 M2.8 4.5 A5.5 5.5 0 1 1 2.4 10.8
  /// M8 4.5 V8 L10.5 9.5`, 1.3 wide.
  factory _Glyph.history({required Color color}) => _Glyph._(
      (path) => path
        ..moveTo(2.5, 4.8)
        ..lineTo(2.5, 1.8)
        ..moveTo(2.5, 4.8)
        ..lineTo(5.5, 4.8)
        ..moveTo(2.8, 4.5)
        ..arcToPoint(const Offset(2.4, 10.8),
            radius: const Radius.circular(5.5), largeArc: true)
        ..moveTo(8, 4.5)
        ..lineTo(8, 8)
        ..lineTo(10.5, 9.5),
      color,
      1.3);

  /// Two four-point stars, 1.2 wide.
  factory _Glyph.sparkle({required Color color}) => _Glyph._(
      (path) => path
        ..moveTo(6, 1.5)
        ..lineTo(7.1, 4.9)
        ..lineTo(10.5, 6)
        ..lineTo(7.1, 7.1)
        ..lineTo(6, 10.5)
        ..lineTo(4.9, 7.1)
        ..lineTo(1.5, 6)
        ..lineTo(4.9, 4.9)
        ..close()
        ..moveTo(11.5, 9)
        ..lineTo(12.1, 10.9)
        ..lineTo(14, 11.5)
        ..lineTo(12.1, 12.1)
        ..lineTo(11.5, 14)
        ..lineTo(10.9, 12.1)
        ..lineTo(9, 11.5)
        ..lineTo(10.9, 10.9)
        ..close(),
      color,
      1.2);

  final void Function(Path path) build_;
  final Color color;
  final double width;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: const Size(15, 15),
        painter: _GlyphPainter(build_, color, width),
      );
}

class _GlyphPainter extends CustomPainter {
  _GlyphPainter(this.build_, this.color, this.width);
  final void Function(Path path) build_;
  final Color color;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 16);
    final path = Path();
    build_(path);
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_GlyphPainter old) => old.color != color;
}
