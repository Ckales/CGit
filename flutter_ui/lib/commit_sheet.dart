import 'package:flutter/material.dart';

import 'ai_settings.dart';
import 'context_menu.dart';
import 'git.dart';
import 'git_text.dart';
import 'prefs.dart';
import 'theme.dart';

/// One repo's rows in the change tree.
typedef RepoChanges = ({RepoRef repo, List<FileStatus> changes});

/// The commit modal: the change tree and commit box on the left, the main
/// window's diff pane on the right.
///
/// It spans the workspace: one tree per repo with changes, and 提交 commits
/// every repo that has something staged.
///
/// The diff pane is [diffPane]: main.dart hands over the widget it already
/// builds, so hunk and line staging, ↑/↓ navigation and 并排 all work
/// here with no second diff view to keep in step.
class CommitSheet extends StatefulWidget {
  const CommitSheet({
    super.key,
    required this.groups,
    required this.active,
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
    this.prefs,
    this.docked = false,
    this.gitFor = Git.new,
  });

  /// Remembers 树形 / 平铺. Tests leave it out and get the tree.
  final Prefs? prefs;

  /// Inline under the history, scoped to the repo picked in the sidebar,
  /// instead of a dialog over the window.
  final bool docked;

  /// Every workspace repo with changes, in sidebar order. Docked, only the
  /// active repo.
  final List<RepoChanges> groups;

  /// The repo the main window is on. 修正提交, 历史说明 and 补丁 act on it alone:
  /// each repo has its own HEAD, and rewording several at once is a guess.
  final RepoRef active;
  final Widget diffPane;
  final VoidCallback onClose;
  final Future<void> Function() onChanged;
  final void Function(RepoRef repo, FileStatus file) onPickFile;

  /// The file the diff pane is showing, highlighted in the tree.
  final ({String repo, String path, bool staged})? selected;

  /// The same right-click menu the main window's changes list uses.
  final List<MenuAction> Function(RepoRef repo, FileStatus file)? menuFor;

  /// 丢弃 on an unstaged row. The caller confirms first.
  final Future<void> Function(RepoRef repo, FileStatus file)? onDiscard;

  /// Runs after a successful commit with the repos committed. Push is the
  /// caller's business — it owns the network lock and the rejected-push retry,
  /// neither of which belongs in a dialog.
  final Future<void> Function(List<String> repoPaths) onCommitAndPush;

  /// Tests hand in fakes; the app uses the real bridge.
  final Git Function(String path) gitFor;

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

  /// The identity git will commit as when the author field is left empty,
  /// shown as that field's hint.
  String _identity = '正在读取当前 Git 身份…';

  /// Folded tree nodes. Kept across refreshes so staging a file does not reopen what was folded.
  final _collapsed = <String>{};

  /// 平铺：each file on one row under its repo, labelled by its full path.
  late bool _flat = widget.prefs?.isFlatChanges ?? false;

  Git get _activeGit => widget.gitFor(widget.active.path);

  @override
  void initState() {
    super.initState();
    _loadIdentity();
  }

  @override
  void didUpdateWidget(CommitSheet old) {
    super.didUpdateWidget(old);
    if (old.active.path != widget.active.path) _loadIdentity();
  }

  Future<void> _loadIdentity() async {
    final path = widget.active.path;
    String text;
    try {
      final id = await widget.gitFor(path).identity();
      text = id.name.isNotEmpty && id.email.isNotEmpty
          ? '${id.name} <${id.email}>'
          : id.name.isNotEmpty || id.email.isNotEmpty
              ? '${id.name}${id.email}'
              : '未配置 Git 身份';
    } on GitError {
      text = '未读取到 Git 身份';
    }
    // A slower read for the previously active repo must not overwrite this one.
    if (mounted && path == widget.active.path) setState(() => _identity = text);
  }

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
      final head = await _activeGit.headMessage();
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
      // Every repo's staged diff, headed by its name when there are several.
      final parts = <String>[];
      for (final g in widget.groups) {
        if (!g.changes.any((f) => f.staged)) continue;
        final diff = await widget.gitFor(g.repo.path).stagedDiff();
        if (diff.trim().isEmpty) continue;
        parts.add(
            widget.groups.length > 1 ? '# 仓库：${g.repo.name}\n$diff' : diff);
      }
      if (parts.isEmpty) {
        setState(() => _error = '没有已暂存的改动可供生成');
        return;
      }
      final diff = parts.join('\n');
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
      final messages = await _activeGit.recentMessages();
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
  List<FileStatus> get _allChanges => [
        for (final g in widget.groups) ...g.changes,
      ];
  List<FileStatus> get _staged => _allChanges.where((f) => f.staged).toList();
  List<FileStatus> get _unstaged =>
      _allChanges.where((f) => !f.staged).toList();

  /// ＋全部 / −全部 across the workspace, repo by repo.
  Future<void> _stageEverything({required bool stage}) async {
    for (final g in widget.groups) {
      final git = widget.gitFor(g.repo.path);
      if (stage && g.changes.any((f) => !f.staged)) await git.stageAll();
      if (!stage && g.changes.any((f) => f.staged)) await git.unstageAll();
    }
  }

  /// 储藏勾选的文件：每个有勾选的仓库各储藏一次，遇到失败即停。
  Future<void> _stashStaged() async {
    final message = _message.text.trim();
    for (final g in widget.groups) {
      if (!g.changes.any((f) => f.staged)) continue;
      try {
        await widget.gitFor(g.repo.path).stashStaged(message: message);
      } on GitError catch (e) {
        if (widget.groups.length == 1) rethrow;
        throw GitError('${g.repo.name}：${e.message}');
      }
    }
  }

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
    // Amending rewords the active repo's HEAD and is allowed with nothing
    // staged. A plain commit goes to every repo with something staged, one
    // `git commit` each.
    final targets = <RepoRef>[];
    if (_amend) {
      targets.add(widget.active);
    } else {
      for (final g in widget.groups) {
        if (g.changes.any((f) => f.staged)) targets.add(g.repo);
      }
    }
    if (targets.isEmpty) {
      setState(() => _error = '没有已暂存的改动');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    final author = _author.text.trim();
    final committed = <String>[];
    final failures = <String>[];
    for (final repo in targets) {
      try {
        await widget.gitFor(repo.path).commit(
              text,
              amend: _amend,
              signoff: _signoff,
              author: author.isEmpty ? null : author,
            );
        committed.add(repo.path);
      } on GitError catch (e) {
        failures
            .add(targets.length > 1 ? '${repo.name}：${e.message}' : e.message);
      }
    }
    await widget.onChanged();
    if (!mounted) return;
    setState(() => _busy = false);

    // Not atomic: a hook refusing one repo leaves the others committed. The
    // failed ones keep their staged files, so the dialog stays up to retry.
    if (failures.isNotEmpty) {
      setState(() => _error = committed.isEmpty
          ? failures.join('\n')
          : '已提交 ${committed.length} 个仓库，失败：\n${failures.join('\n')}');
      return;
    }
    _message.clear();
    widget.onClose();
    // Closed first: the push reports through the status bar, and a dialog
    // sitting on top of it would hide the one thing worth watching.
    if (push) await widget.onCommitAndPush(committed);
  }

  @override
  Widget build(BuildContext context) {
    final p = Theming.of(context);

    final panel = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(widget.docked ? '提交 · ${widget.active.name}' : '提交',
                style: ui.copyWith(color: p.text, fontWeight: FontWeight.w600)),
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
              // At most 1240 wide, 96% of the window; 88% of its height.
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
    // 补丁 exports the active repo's working tree only.
    var hasChanges = false;
    for (final g in widget.groups) {
      if (g.repo.path == widget.active.path && g.changes.isNotEmpty) {
        hasChanges = true;
      }
    }
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
            const SizedBox(width: 6),
            _Btn(
              tooltip: _flat ? '切换为树形结构' : '切换为平铺列表',
              icon: true,
              onTap: () {
                setState(() => _flat = !_flat);
                widget.prefs?.setFlatChanges(_flat);
              },
              child: _flat
                  ? _Glyph.tree(color: p.text)
                  : _Glyph.list(color: p.text),
            ),
            const SizedBox(width: 6),
            _Btn(
              tooltip: '暂存全部',
              icon: true,
              onTap: _busy || _unstaged.isEmpty
                  ? null
                  : () => _run(() => _stageEverything(stage: true)),
              child: _label(p, '＋全部', size: 11),
            ),
            const SizedBox(width: 6),
            _Btn(
              tooltip: '取消暂存全部',
              icon: true,
              onTap: _busy || _staged.isEmpty
                  ? null
                  : () => _run(() => _stageEverything(stage: false)),
              child: _label(p, '−全部', size: 11),
            ),
            const SizedBox(width: 6),
            _Btn(
              tooltip: '储藏勾选的文件，提交说明有内容时用作储藏说明',
              icon: true,
              onTap: _busy || _staged.isEmpty ? null : () => _run(_stashStaged),
              child: _label(p, '储藏', size: 11),
            ),
            const SizedBox(width: 6),
            _Btn(
              tooltip: '把 ${widget.active.name} 的本地改动导出成补丁（右键复制到剪贴板）',
              icon: true,
              onTap: _busy || !hasChanges
                  ? null
                  : () => widget.onCreatePatch(toClipboard: false),
              onSecondaryTap: _busy || !hasChanges
                  ? null
                  : () => widget.onCreatePatch(toClipboard: true),
              child: _label(p, '补丁', size: 11),
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
    final rows = <Widget>[];
    for (final g in widget.groups) {
      final files = needle.isEmpty
          ? g.changes
          : g.changes
              .where((f) => f.path.toLowerCase().contains(needle))
              .toList();
      if (files.isEmpty) continue;
      rows.addAll(_repoRows(p, g.repo, files, forceOpen: needle.isNotEmpty));
    }
    if (rows.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(6),
        child: Text(needle.isEmpty ? '工作区干净' : '没有匹配的文件',
            style: ui.copyWith(color: p.textDim, fontSize: 12)),
      );
    }
    return ListView(children: rows);
  }

  /// One repo's root row and, unless folded, its folders and files. A filter
  /// forces every node open, or a match could sit in a folded folder.
  List<Widget> _repoRows(
    Palette p,
    RepoRef repo,
    List<FileStatus> files, {
    required bool forceOpen,
  }) {
    // A path staged and then edited again shows up twice. Both stay leaves,
    // and only that pair gets a 已暂存 / 未暂存 suffix.
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

    String label(FileStatus f, String name) => (occurrences[f.path] ?? 0) > 1
        ? '$name · ${f.staged ? '已暂存' : '未暂存'}'
        : name;

    final rows = <Widget>[];
    void addNode(TreeNode node, String parent, int depth) {
      for (final dir in node.dirs) {
        final path = parent.isEmpty ? dir.name : '$parent/${dir.name}';
        // Keyed by repo too: two repos can both have a src/.
        final key = 'dir|${repo.path}|$path';
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
          check: _groupCheck(p, repo, dirFiles),
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
        rows.add(_fileRow(p, repo, f, depth, label(f, name)));
      }
    }

    final rootKey = 'root|${repo.path}';
    final rootOpen = forceOpen || !_collapsed.contains(rootKey);
    rows.add(_TreeRow(
      depth: 0,
      open: rootOpen,
      onToggle: forceOpen ? null : () => _toggleNode(rootKey),
      check: _groupCheck(p, repo, files),
      tooltip: repo.path,
      children: [
        Flexible(
          child: Text(
            '${repo.name}  ${_distinctPaths(files)} 个文件',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ui.copyWith(
                color: p.accent, fontSize: 12, fontWeight: FontWeight.w700),
          ),
        ),
        if (repo.branch.isNotEmpty) ...[
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: p.bgElev,
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(repo.branch,
                style: ui.copyWith(color: p.textDim, fontSize: 10)),
          ),
        ],
      ],
    ));
    if (rootOpen && _flat) {
      for (final f in files) {
        rows.add(_fileRow(p, repo, f, 1, label(f, f.path)));
      }
    } else if (rootOpen) {
      addNode(root, '', 1);
    }
    return rows;
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
  Widget _groupCheck(Palette p, RepoRef repo, List<FileStatus> files) {
    final actionable = files.where((f) => f.status != 'conflict').toList();
    final stagedCount = actionable.where((f) => f.staged).length;
    final all = actionable.isNotEmpty && stagedCount == actionable.length;
    final paths = actionable.map((f) => f.path).toSet().toList();
    return Check3(
      value: all ? true : (stagedCount > 0 ? null : false),
      tooltip: actionable.isEmpty ? '先解决冲突' : (all ? '取消暂存此组' : '暂存此组'),
      onTap: _busy || actionable.isEmpty
          ? null
          : () => _run(() => all
              ? widget.gitFor(repo.path).unstageAll(files: paths)
              : widget.gitFor(repo.path).stageAll(files: paths)),
    );
  }

  Widget _fileRow(
      Palette p, RepoRef repo, FileStatus f, int depth, String label) {
    final conflict = f.status == 'conflict';
    final sel = widget.selected;
    return _TreeRow(
      depth: depth,
      leaf: true,
      selected: sel != null &&
          sel.repo == repo.path &&
          sel.path == f.path &&
          sel.staged == f.staged,
      tooltip: f.path,
      onPress: () => widget.onPickFile(repo, f),
      onMenuAt: widget.menuFor == null
          ? null
          : (pos) => showRepoMenu(
              context: context, position: pos, items: widget.menuFor!(repo, f)),
      check: Check3(
        value: f.staged,
        tooltip: conflict ? '先解决冲突' : (f.staged ? '取消暂存' : '暂存'),
        onTap: _busy || conflict
            ? null
            : () => _run(() => f.staged
                ? widget.gitFor(repo.path).unstage(f.path)
                : widget.gitFor(repo.path).stage(f.path)),
      ),
      // Discarding restores the worktree from the index, so it means nothing
      // on a staged row — only offered where it does something.
      trailing: !f.staged && !conflict && widget.onDiscard != null
          ? _DiscardButton(onTap: () => widget.onDiscard!(repo, f))
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
        MessageBox(controller: _message),
        const SizedBox(height: 8),
        Row(
          children: [
            CheckLabel(
              // Amend only ever touches the active repo; say which when the
              // tree holds others.
              label: widget.groups.any((g) => g.repo.path != widget.active.path)
                  ? '修正提交（仅 ${widget.active.name}）'
                  : '修正提交',
              tooltip: '修补上一个提交而不新建提交',
              value: _amend,
              onChanged: _busy ? null : _toggleAmend,
            ),
            const SizedBox(width: 14),
            CheckLabel(
              label: 'Sign-off 提交',
              tooltip: '在提交说明末尾追加 Signed-off-by',
              value: _signoff,
              onChanged: _busy ? null : (v) => setState(() => _signoff = v),
            ),
          ],
        ),
        const SizedBox(height: 8),
        // Its own row: the column is 360px wide, and next to the checkboxes or
        // the buttons the identity hint was cut to a few characters.
        Row(
          children: [
            Text('作者', style: ui.copyWith(color: p.textDim, fontSize: 11)),
            const SizedBox(width: 6),
            Expanded(
              child: Tooltip(
                message: '当前 Git 身份：$_identity；填写后仅覆盖本次提交',
                waitDuration: const Duration(milliseconds: 600),
                child: _Field(controller: _author, hint: _identity),
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
/// the row's own content. Indented `6 + depth × 14`px.
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
        // On press: a watcher refresh landing between
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

/// The disclosure triangle on folder rows, turned 90° when open.
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

/// A checkbox with three states: ticked, clear, and dashed
/// (`value == null`) for a folder that is partly staged.
class Check3 extends StatelessWidget {
  const Check3(
      {super.key, required this.value, required this.tooltip, this.onTap});
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

/// The commit message box: 70px, own background, accent border on focus.
class MessageBox extends StatefulWidget {
  const MessageBox({super.key, required this.controller});
  final TextEditingController controller;

  @override
  State<MessageBox> createState() => _MessageBoxState();
}

class _MessageBoxState extends State<MessageBox> {
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
        // The dialog opens to write a message.
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
class CheckLabel extends StatelessWidget {
  const CheckLabel({
    super.key,
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
              Check3(
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

/// The sheet's button: raised background, 6px corners, 0.45 opacity when
/// disabled. `icon` gives tight horizontal padding; `primary` is
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
            : (_) => widget
                .onTapAt!(menuAnchorBelow(context, right: widget.joinLeft)),
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

/// The two 16×16 stroked icons of the commit actions.
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

  /// 平铺: three equal lines, 1.3 wide.
  factory _Glyph.list({required Color color}) => _Glyph._(
      (path) => path
        ..moveTo(3, 4)
        ..lineTo(13, 4)
        ..moveTo(3, 8)
        ..lineTo(13, 8)
        ..moveTo(3, 12)
        ..lineTo(13, 12),
      color,
      1.3);

  /// 树形: a parent line and two indented children on a connector, 1.3 wide.
  factory _Glyph.tree({required Color color}) => _Glyph._(
      (path) => path
        ..moveTo(2.5, 4)
        ..lineTo(13, 4)
        ..moveTo(4, 5.5)
        ..lineTo(4, 12)
        ..lineTo(5.5, 12)
        ..moveTo(4, 8)
        ..lineTo(5.5, 8)
        ..moveTo(7.5, 8)
        ..lineTo(13, 8)
        ..moveTo(7.5, 12)
        ..lineTo(13, 12),
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
