import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'blame_view.dart';
import 'branch_menu.dart';
import 'commit_menu.dart';
import 'commit_sheet.dart';
import 'context_menu.dart';
import 'diff_view.dart';
import 'git.dart';
import 'git_text.dart';
import 'history_view.dart';
import 'merge_view.dart';
import 'network_ops.dart';
import 'prefs.dart';
import 'prompt.dart';
import 'theme.dart';

Future<void> main(List<String> args) async {
  // The Rust side lives in cgit_rust.framework; nothing below can call it until
  // this resolves, so it blocks rather than racing the first repo load.
  WidgetsFlutterBinding.ensureInitialized();
  await initGitBridge();
  final prefs = await Prefs.load();

  // argv wins when given, then the most recently opened repo, then the working
  // directory — so relaunching lands where the user left off.
  final start = args.isNotEmpty
      ? args.first
      : (prefs.recentRepos.firstOrNull ?? defaultRepoPath);

  runApp(CGitApp(startPath: start, prefs: prefs));
}

class CGitApp extends StatefulWidget {
  const CGitApp({super.key, required this.startPath, required this.prefs});
  final String startPath;
  final Prefs prefs;

  @override
  State<CGitApp> createState() => _CGitAppState();
}

class _CGitAppState extends State<CGitApp> {
  late Palette _palette =
      widget.prefs.isDark ? Palette.dark : Palette.light;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'cgit — Git 客户端',
      debugShowCheckedModeBanner: false,
      home: Theming(
        palette: _palette,
        // This app draws its own chrome rather than using Scaffold, and Scaffold
        // is what normally supplies the Material ancestor that TextField and the
        // other material widgets assert on. Without this, the commit box renders
        // as a red "No Material widget found" block instead of an input.
        // `transparency` provides the ancestor without painting a background.
        child: Material(
          type: MaterialType.transparency,
          child: RepoScreen(
            startPath: widget.startPath,
            prefs: widget.prefs,
            onToggleTheme: () {
              final dark = _palette != Palette.dark;
              setState(() => _palette = dark ? Palette.dark : Palette.light);
              widget.prefs.setDark(dark);
            },
          ),
        ),
      ),
    );
  }
}

/// What the diff pane is currently showing. The DOM version keeps this in a
/// handful of module-level `let`s and a `diff-back-btn` that knows how to undo
/// the last transition; one sealed type is the same thing with the states named.
sealed class DiffTarget {
  const DiffTarget();
}

class NoDiff extends DiffTarget {
  const NoDiff();
}

class WorkingFileDiff extends DiffTarget {
  const WorkingFileDiff(this.path, this.staged);
  final String path;
  final bool staged;
}

class CommitFileDiff extends DiffTarget {
  const CommitFileDiff(this.oid, this.path);
  final String oid;
  final String path;
}

/// Per-line authorship rather than a diff. It shares the pane because it
/// answers the same question from the other end: who last touched this line.
class BlameTarget extends DiffTarget {
  const BlameTarget(this.path);
  final String path;
}

class RepoScreen extends StatefulWidget {
  const RepoScreen({
    super.key,
    required this.startPath,
    required this.prefs,
    required this.onToggleTheme,
  });
  final String startPath;
  final Prefs prefs;
  final VoidCallback onToggleTheme;

  @override
  State<RepoScreen> createState() => _RepoScreenState();
}

class _RepoScreenState extends State<RepoScreen> {
  Git? _git;
  String _repoName = '未打开仓库';
  String _branch = '';
  String _status = '就绪';

  List<BranchInfo> _branches = const [];
  List<String> _tags = const [];
  List<RemoteInfo> _remotes = const [];
  List<FileStatus> _changes = const [];
  GraphLayout _graph = const GraphLayout([], 1);

  GraphCommit? _selectedCommit;
  List<FileStatus> _commitFiles = const [];
  DiffTarget _target = const NoDiff();
  List<String> _hunks = const [];
  List<BlameLine> _blame = const [];

  late DiffMode _mode =
      widget.prefs.isSplitDiff ? DiffMode.split : DiffMode.unified;
  bool _commitOpen = false;

  /// Files still carrying conflict markers, and which multi-step operation the
  /// repo is in the middle of ("none" when it is not). They travel together:
  /// a merge, rebase, cherry-pick and revert all stop on conflict but each has
  /// its own continue/abort, and `git merge --abort` during a cherry-pick fails
  /// outright.
  List<String> _conflicts = const [];
  String _op = 'none';

  /// Where HEAD stands against its upstream. Drives the ahead/behind counters
  /// and what the push button says it will do.
  Tracking? _tracking;
  List<StashEntry> _stashes = const [];

  /// One network call at a time: they all touch the same refs, and a fetch
  /// racing a push produces failures that are nobody's fault.
  bool _netBusy = false;

  /// The file open in the merge window, and its worktree text.
  String? _mergeFile;
  String _mergeContent = '';

  late double _sidebarWidth = widget.prefs.sidebarWidth ?? 220;
  late double _historyHeight = widget.prefs.historyHeight ?? 260;

  final _historyScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _openRepo(widget.startPath);
  }

  @override
  void dispose() {
    _historyScroll.dispose();
    super.dispose();
  }

  Future<void> _openRepo(String path) async {
    final workspace = await Git.discover(path);
    if (workspace == null || workspace.repos.isEmpty) {
      setState(() => _status = '不是 Git 仓库：$path');
      return;
    }
    // A workspace can hold sibling repos; the sidebar picker for those is not
    // built yet, so open the first and keep the rest for when it is.
    final repo = workspace.repos.first;
    setState(() {
      _git = Git(repo.path);
      _repoName = repo.name;
    });
    await widget.prefs.rememberRepo(repo.path);
    await _refresh();
  }

  /// One reload for everything the window shows. The DOM version splits this
  /// into refreshStatus / refreshBranches / refreshGraph because it repaints
  /// each list independently; here a rebuild is cheap enough not to bother.
  Future<void> _refresh() async {
    final git = _git;
    if (git == null) return;
    try {
      final results = await Future.wait([
        git.currentBranch(),
        git.branches(),
        git.tags(),
        git.remotes(),
        git.status(),
        git.graph(),
        git.conflicts(),
        git.repoState(),
        git.tracking(),
        git.stashList(),
      ]);
      if (!mounted) return;
      setState(() {
        _branch = results[0] as String;
        _branches = results[1] as List<BranchInfo>;
        _tags = results[2] as List<String>;
        _remotes = results[3] as List<RemoteInfo>;
        _changes = results[4] as List<FileStatus>;
        _graph = layoutGraph(results[5] as List<GraphCommit>);
        _conflicts = results[6] as List<String>;
        _op = results[7] as String;
        _tracking = results[8] as Tracking;
        _stashes = results[9] as List<StashEntry>;
        _status = '就绪';
      });
      await _reloadDiff();
    } on GitError catch (e) {
      if (mounted) setState(() => _status = e.message);
    }
  }

  Future<void> _reloadDiff() async {
    final git = _git;
    if (git == null) return;
    try {
      final hunks = switch (_target) {
        NoDiff() => const Hunks(header: '', hunks: []),
        WorkingFileDiff(:final path, :final staged) =>
          await git.hunks(path, staged: staged),
        CommitFileDiff(:final oid, :final path) =>
          // A commit's diff comes back as one patch; core hands the working-tree
          // diff back pre-split, so only this path needs splitting.
          Hunks(
            header: '',
            hunks: splitPatchText(await git.commitDiff(oid, path)).hunks,
          ),
        // Blame renders from its own list, not from hunks.
        BlameTarget() => const Hunks(header: '', hunks: []),
      };
      if (mounted) setState(() => _hunks = hunks.hunks);
    } on GitError catch (e) {
      if (mounted) setState(() => _status = e.message);
    }
  }

  /* ---------- history ---------- */

  List<MenuAction> _commitMenu(GraphCommit c) => commitMenu(
        run: (cmd) => switch (cmd) {
          CommitCommand.resetMixed =>
            _stashAction('重置到 ${_short(c)}', () => _git!.resetTo(c.id, 'mixed')),
          CommitCommand.resetSoft =>
            _stashAction('重置到 ${_short(c)}', () => _git!.resetTo(c.id, 'soft')),
          CommitCommand.resetHard => _stashAction(
              '重置到 ${_short(c)}',
              () => _git!.resetTo(c.id, 'hard'),
              // The only entry here that throws away work git cannot give back.
              confirm: 'hard 重置到 ${_short(c)}「${c.summary}」？\n\n'
                  '当前所有未提交的改动会被丢弃，且无法通过 reflog 找回。',
            ),
          CommitCommand.revert =>
            _stashAction('回退 ${_short(c)}', () => _git!.revert(c.id)),
          CommitCommand.cherryPick =>
            _stashAction('拣选 ${_short(c)}', () => _git!.cherryPick(c.id)),
          CommitCommand.rebaseFrom => _notYet('交互式变基'),
          CommitCommand.tag => _newTag(oid: c.id),
          CommitCommand.patchToClipboard => _patchToClipboard(c),
          CommitCommand.patchToFile => _patchToFile(c),
        },
      );

  String _short(GraphCommit c) => c.id.substring(0, 7);

  /// Entries whose backing UI is not built yet say so instead of doing nothing —
  /// a menu item that silently no-ops reads as a broken app.
  void _notYet(String what) {
    setState(() => _status = '$what 还没做');
  }

  Future<void> _patchToClipboard(GraphCommit c) async {
    final git = _git;
    if (git == null) return;
    try {
      final patch = await git.commitPatch(c.id);
      await git.copyToClipboard(patch);
      if (mounted) setState(() => _status = '已复制 ${_short(c)} 的补丁到剪贴板');
    } on GitError catch (e) {
      if (mounted) setState(() => _status = e.message);
    }
  }

  Future<void> _newTag({String? oid}) async {
    final name = await promptText(
      context,
      title: oid == null ? '在 HEAD 上打标签' : '在 ${oid.substring(0, 7)} 上打标签',
      hint: '标签名',
      confirmLabel: '创建',
    );
    if (name == null || name.trim().isEmpty) return;
    await _stashAction(
      '打标签 ${name.trim()}',
      () => _git!.createTag(name.trim(), oid: oid),
    );
  }

  /* ---------- branches ---------- */

  /// Wraps a branch command with confirm / report / refresh. Void commands pass
  /// a message of their own since git says nothing on success.
  Future<void> _branchAction(
    String done,
    Future<void> Function() action, {
    String? confirm,
  }) async {
    if (_git == null) return;
    if (confirm != null && !await _confirm(title: done, body: confirm)) return;
    try {
      await action();
      await _refresh();
      if (mounted) setState(() => _status = done);
    } on GitError catch (e) {
      if (mounted) setState(() => _status = e.message);
    }
  }

  List<MenuAction> _branchMenu(BranchInfo b) => branchMenu(
        branch: b,
        currentBranch: _branch,
        run: (cmd) => switch (cmd) {
          BranchCommand.checkout => _branchAction(
              '已切换到 ${b.name}', () => _git!.checkout(b.name)),
          BranchCommand.newFrom => _newBranch(base: b.name),
          BranchCommand.mergeInto =>
            _stashAction('合并 ${b.name}', () => _git!.mergeBranch(b.name)),
          BranchCommand.update =>
            _stashAction('更新 ${b.name}', () => _git!.updateBranch(b.name)),
          BranchCommand.push =>
            _network('推送 ${b.name}', () => _git!.pushBranch(b.name)),
          BranchCommand.rename => _renameBranch(b.name),
          BranchCommand.delete => _branchAction(
              '已删除分支 ${b.name}',
              () => _git!.deleteBranch(b.name),
              confirm: '删除分支「${b.name}」？未合并的提交只能靠 reflog 找回。',
            ),
        },
      );

  Future<void> _newBranch({String? base}) async {
    final name = await promptText(
      context,
      title: base == null ? '新建分支' : "从 '$base' 新建分支",
      hint: '分支名',
      confirmLabel: '创建并检出',
    );
    if (name == null || name.trim().isEmpty) return;
    await _branchAction(
      '已创建并检出 ${name.trim()}',
      () => _git!.createBranch(name.trim(), base: base),
    );
  }

  Future<void> _renameBranch(String name) async {
    final next = await promptText(
      context,
      title: '重命名分支',
      initial: name,
      confirmLabel: '重命名',
    );
    if (next == null || next.trim().isEmpty || next.trim() == name) return;
    await _branchAction(
      '已重命名为 ${next.trim()}',
      () => _git!.renameBranch(name, next.trim()),
    );
  }

  List<MenuAction> _fileMenu(FileStatus f) => [
        MenuAction(f.staged ? '取消暂存' : '暂存', () {
          _stashAction(
            f.staged ? '取消暂存' : '暂存',
            () async {
              if (f.staged) {
                await _git!.unstage(f.path);
              } else {
                await _git!.stage(f.path);
              }
              return '';
            },
          );
        }),
        MenuAction('逐行归属 (blame)', () => _showBlame(f.path)),
      ];

  /// Pick a repository (or a folder of sibling repos) with the native dialog.
  ///
  /// The sandbox is off, so a chosen path stays readable for the whole session
  /// without security-scoped bookmarks. Turning the sandbox back on — which a
  /// Mac App Store build would require — makes those mandatory and rules out
  /// the argv path entirely.
  Future<void> _pickRepo() async {
    final dir = await getDirectoryPath(confirmButtonText: '打开');
    if (dir == null) return;
    await _openRepo(dir);
  }

  Future<void> _patchToFile(GraphCommit c) async {
    final git = _git;
    if (git == null) return;
    try {
      final patch = await git.commitPatch(c.id);
      final location = await getSaveLocation(
        // format-patch's own naming: 0001-subject.patch. Keeping the shape
        // means the other end can `git am` a directory of them in order.
        suggestedName: patchFileName(c.summary),
        acceptedTypeGroups: const [
          XTypeGroup(label: 'patch', extensions: ['patch', 'diff']),
        ],
      );
      if (location == null) return;
      await git.savePatch(location.path, patch);
      if (mounted) setState(() => _status = '已导出补丁到 ${location.path}');
    } on GitError catch (e) {
      if (mounted) setState(() => _status = e.message);
    }
  }

  Future<void> _showBlame(String file) async {
    final git = _git;
    if (git == null) return;
    try {
      final lines = await git.blame(file);
      if (!mounted) return;
      setState(() {
        _blame = lines;
        _target = BlameTarget(file);
      });
    } on GitError catch (e) {
      if (mounted) setState(() => _status = e.message);
    }
  }

  Future<void> _showFile(FileStatus file) async {
    setState(() => _target = WorkingFileDiff(file.path, file.staged));
    await _reloadDiff();
  }

  Future<void> _selectCommit(GraphCommit commit) async {
    final git = _git;
    if (git == null) return;
    setState(() {
      _selectedCommit = commit;
      _commitFiles = const [];
    });
    try {
      final files = await git.commitFiles(commit.id);
      if (!mounted) return;
      setState(() {
        _commitFiles = files;
        _target = files.isEmpty
            ? const NoDiff()
            : CommitFileDiff(commit.id, files.first.path);
      });
      await _reloadDiff();
    } on GitError catch (e) {
      if (mounted) setState(() => _status = e.message);
    }
  }

  /* ---------- stash ---------- */

  /// Wraps the stash commands with the same report-and-refresh the network
  /// actions get. `confirm` is the prompt shown first for destructive ones.
  Future<void> _stashAction(
    String label,
    Future<String> Function() action, {
    String? confirm,
  }) async {
    final git = _git;
    if (git == null) return;
    if (confirm != null && !await _confirm(title: label, body: confirm)) return;

    try {
      final out = await action();
      await _refresh();
      if (mounted) setState(() => _status = out.trim().isEmpty ? '已$label' : out.trim());
    } on GitError catch (e) {
      if (mounted) setState(() => _status = e.message);
    }
  }

  List<MenuAction> _stashMenu(StashEntry s) => [
        MenuAction('弹出（应用并删除）',
            () => _stashAction('弹出储藏', () => _git!.stashPop(s.index.toInt()))),
        MenuAction(
          '删除',
          () => _stashAction(
            '删除储藏',
            () => _git!.stashDrop(s.index.toInt()),
            // git keeps dropped stashes unreachable for a while, but nothing in
            // the UI can get them back — so this asks.
            confirm: '删除储藏「${s.message}」？该储藏不会再出现在列表里。',
          ),
          danger: true,
        ),
      ];

  /* ---------- network ---------- */

  /// Runs one network action at a time, reporting through the status bar and
  /// refreshing afterwards either way — a fetch that fails halfway still moved
  /// some refs, and a pull that stops on conflict has already written files.
  Future<void> _network(String label, Future<String> Function() action) async {
    if (_netBusy) return;
    setState(() {
      _netBusy = true;
      _status = '$label…';
    });
    try {
      final out = await action();
      await _refresh();
      if (!mounted) return;
      final last = out.split('\n').where((l) => l.trim().isNotEmpty).lastOrNull;
      setState(() => _status = last == null ? '$label完成' : '$label完成。$last');
    } on GitError catch (e) {
      await _refresh();
      if (mounted) setState(() => _status = networkErrorText(e.message));
    } finally {
      if (mounted) setState(() => _netBusy = false);
    }
  }

  Future<void> _fetch() => _network('抓取', () => _git!.fetch());

  Future<void> _pull() => _network('拉取', () => _git!.pull());

  Future<void> _push() => _network(
        '推送',
        () => pushWithRetry(
          _git!,
          chooseStrategy: _askUpdateStrategy,
          onProgress: (m) {
            if (mounted) setState(() => _status = m);
          },
        ),
      );

  /// Only asked when git config says nothing about `pull.rebase`. Cancelling
  /// aborts the push retry rather than picking a default — rebasing someone's
  /// commits because they dismissed a dialog is not a recoverable mistake.
  Future<UpdateStrategy?> _askUpdateStrategy() async {
    final p = Theming.of(context);
    return showDialog<UpdateStrategy>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: p.bgElev,
        title: Text('远端有新提交',
            style: ui.copyWith(color: p.text, fontSize: 15)),
        content: Text(
          '推送被拒绝：远端已经领先。要先用哪种方式更新本地分支？\n\n'
          'git 配置里没有 pull.rebase，所以这次由你决定。',
          style: ui.copyWith(color: p.text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('取消推送', style: ui.copyWith(color: p.textDim)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(UpdateStrategy.merge),
            child: Text('合并', style: ui.copyWith(color: p.accent)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(UpdateStrategy.rebase),
            child: Text('变基', style: ui.copyWith(color: p.accent)),
          ),
        ],
      ),
    );
  }

  /* ---------- conflicts ---------- */

  /// Labels for the four operations that stop on conflict. Each has its own
  /// --continue / --abort, which is why the banner names the operation instead
  /// of saying "continue".
  static const _opLabels = {
    'rebase': '变基',
    'cherry-pick': '拣选',
    'revert': '回退',
    'merge': '合并',
  };

  String get _opLabel => _opLabels[_op] ?? '操作';

  Future<void> _openMerge(String file) async {
    final git = _git;
    if (git == null) return;
    try {
      final content = await git.readFile(file);
      if (!mounted) return;
      setState(() {
        _mergeFile = file;
        _mergeContent = content;
      });
    } on GitError catch (e) {
      if (mounted) setState(() => _status = e.message);
    }
  }

  Future<void> _resolveWith(String content) async {
    final git = _git;
    final file = _mergeFile;
    if (git == null || file == null) return;
    try {
      await git.resolveWith(file, content);
      if (mounted) setState(() => _mergeFile = null);
      await _refresh();
      if (mounted) setState(() => _status = '已解决 $file');
    } on GitError catch (e) {
      if (mounted) setState(() => _status = e.message);
    }
  }

  Future<void> _resolveSide(String side) async {
    final git = _git;
    final file = _mergeFile;
    if (git == null || file == null) return;
    try {
      await git.resolveSide(file, side);
      if (mounted) setState(() => _mergeFile = null);
      await _refresh();
      if (mounted) {
        setState(() => _status = '已采用${side == 'ours' ? '我方' : '对方'} — $file');
      }
    } on GitError catch (e) {
      if (mounted) setState(() => _status = e.message);
    }
  }

  /// Per-block base text only exists in diff3-style markers, so getting it means
  /// asking git to regenerate the file — which throws away manual edits to it.
  /// Hence the confirmation before, and the re-read after.
  Future<void> _toggleBase(bool wantBase) async {
    final git = _git;
    final file = _mergeFile;
    if (git == null || file == null) return;

    final ok = await _confirm(
      title: wantBase ? '显示共同祖先' : '隐藏共同祖先',
      body: '将重新生成 "$file" 的冲突标记'
          '${wantBase ? '（加入 base 段）' : '（移除 base 段）'}。'
          '该文件上的手工修改会丢失，已选择的取舍也会重置。继续？',
    );
    if (!ok) return;

    try {
      await git.setConflictStyle(file, wantBase ? 'diff3' : 'merge');
      final content = await git.readFile(file);
      if (mounted) setState(() => _mergeContent = content);
    } on GitError catch (e) {
      if (mounted) setState(() => _status = e.message);
    }
  }

  Future<void> _opAction(String action) async {
    final git = _git;
    if (git == null) return;

    if (action == 'abort') {
      final ok = await _confirm(
        title: '中止$_opLabel',
        body: '中止$_opLabel？已解决的内容会被丢弃。',
      );
      if (!ok) return;
    }

    try {
      final out = await git.opAction(_op, action);
      await _refresh();
      if (!mounted) return;
      final verb = {'continue': '继续', 'abort': '中止', 'skip': '跳过'}[action];
      final last = out.split('\n').where((l) => l.trim().isNotEmpty).lastOrNull;
      setState(() => _status = last ?? '已$verb$_opLabel');
    } on GitError catch (e) {
      // Refresh either way: the operation may have advanced before failing.
      await _refresh();
      if (mounted) setState(() => _status = e.message);
    }
  }

  Future<bool> _confirm({required String title, required String body}) async {
    final p = Theming.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: p.bgElev,
        title: Text(title, style: ui.copyWith(color: p.text, fontSize: 15)),
        content: Text(body, style: ui.copyWith(color: p.text)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('取消', style: ui.copyWith(color: p.textDim)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('继续', style: ui.copyWith(color: p.red)),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _applyPartial(String patch, bool reverse) async {
    final git = _git;
    if (git == null) return;
    try {
      await git.applyHunk(patch, reverse: reverse);
      setState(() => _status = reverse ? '已取消暂存所选行' : '已暂存所选行');
      await _refresh();
    } on GitError catch (e) {
      if (mounted) setState(() => _status = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Theming.of(context);

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): () {
          if (_git != null) setState(() => _commitOpen = true);
        },
        const SingleActivator(LogicalKeyboardKey.keyR, meta: true): _refresh,
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_commitOpen) setState(() => _commitOpen = false);
        },
      },
      child: Focus(
        autofocus: true,
        child: DefaultTextStyle(
          style: ui.copyWith(color: p.text),
          child: ColoredBox(
            color: p.bg,
            child: Stack(
              children: [
                Column(
                  children: [
                    _toolbar(p),
                    Expanded(
                      child: Row(
                        children: [
                          SizedBox(width: _sidebarWidth, child: _sidebar(p)),
                          _Splitter(
                            axis: Axis.horizontal,
                            palette: p,
                            onDrag: (d) => setState(() => _sidebarWidth =
                                (_sidebarWidth + d).clamp(140.0, 480.0)),
                            // Written on release, not on every drag frame: one
                            // drag produces dozens of updates and the plist does
                            // not need to see each of them.
                            onDragEnd: () =>
                                widget.prefs.setSidebarWidth(_sidebarWidth),
                            onReset: () {
                              setState(() => _sidebarWidth = 220);
                              widget.prefs.setSidebarWidth(220);
                            },
                          ),
                          Expanded(child: _mainRight(p)),
                        ],
                      ),
                    ),
                    _statusBar(p),
                  ],
                ),
                if (_mergeFile != null)
                  MergeWindow(
                    file: _mergeFile!,
                    content: _mergeContent,
                    onClose: () => setState(() => _mergeFile = null),
                    onResolveWith: _resolveWith,
                    onResolveSide: _resolveSide,
                    onToggleBase: _toggleBase,
                  ),
                if (_commitOpen)
                  CommitSheet(
                    changes: _changes,
                    git: _git!,
                    onClose: () => setState(() => _commitOpen = false),
                    onChanged: _refresh,
                    onPickFile: _showFile,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _toolbar(Palette p) {
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: p.bgAlt,
        border: Border(bottom: BorderSide(color: p.border)),
      ),
      child: Row(
        children: [
          Text(_git == null ? '未打开仓库' : '$_repoName — $_branch',
              style: ui.copyWith(color: p.textDim)),
          _trackingChip(p),
          const Spacer(),
          _ToolButton(
              label: '提交',
              enabled: _git != null,
              onTap: () {
                setState(() => _commitOpen = true);
              }),
          // Disabled while any network action runs: they all move the same refs,
          // and a fetch racing a push fails in ways that are nobody's fault.
          _ToolButton(
            label: '推送',
            enabled: _git != null && !_netBusy,
            onTap: _push,
            tooltip: _tracking == null ? null : pushTargetText(_tracking!),
          ),
          _ToolButton(
              label: '拉取', enabled: _git != null && !_netBusy, onTap: _pull),
          _ToolButton(
              label: '抓取', enabled: _git != null && !_netBusy, onTap: _fetch),
          _ToolButton(
            label: '打开…',
            enabled: true,
            onTap: _pickRepo,
            // Right-click reaches the recent list without a dialog; left-click
            // still goes straight to the picker, which is what a fresh install
            // needs and what an empty list would offer anyway.
            onSecondaryTapAt: (pos) {
              final recent = widget.prefs.recentRepos;
              if (recent.isEmpty) return;
              showRepoMenu(
                context: context,
                position: pos,
                items: [
                  for (final path in recent)
                    MenuAction(path.split('/').last, () => _openRepo(path)),
                ],
              );
            },
          ),
          _ToolButton(label: '刷新', enabled: _git != null, onTap: _refresh),
          _ToolButton(
            label: _mode == DiffMode.split ? '并排' : '统一',
            enabled: true,
            onTap: () => setState(() => _mode =
                _mode == DiffMode.split ? DiffMode.unified : DiffMode.split),
          ),
          _ToolButton(label: '主题', enabled: true, onTap: widget.onToggleTheme),
        ],
      ),
    );
  }

  Widget _sidebar(Palette p) {
    return Container(
      decoration: BoxDecoration(
        color: p.bg,
        border: Border(right: BorderSide(color: p.border)),
      ),
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 6),
        children: [
          _SectionHead(
            label: '分支',
            palette: p,
            action: _git == null
                ? null
                : _SectionAction('＋', '新建分支', () => _newBranch()),
          ),
          for (final b in _branches)
            ContextMenuRegion(
              items: () => _branchMenu(b),
              child: _SidebarRow(
                label: b.name,
                palette: p,
                active: b.isCurrent,
                leading: b.isCurrent ? '●' : null,
                // Left click checks out, like the Tauri version; the menu holds
                // everything else.
                onTap: b.isCurrent
                    ? null
                    : () => _branchAction(
                          '已切换到 ${b.name}',
                          () => _git!.checkout(b.name),
                        ),
              ),
            ),
          _SectionHead(label: '远端', palette: p),
          for (final r in _remotes) _SidebarRow(label: r.name, palette: p),
          _SectionHead(
            label: '标签',
            palette: p,
            action: _git == null
                ? null
                : _SectionAction('＋', '在 HEAD 上打标签', () => _newTag()),
          ),
          for (final tag in _tags)
            ContextMenuRegion(
              items: () => [
                MenuAction(
                  '删除标签',
                  () => _stashAction(
                    '删除标签 $tag',
                    () => _git!.deleteTag(tag),
                    confirm: '删除本地标签「$tag」？远端上的同名标签不受影响。',
                  ),
                  danger: true,
                ),
              ],
              child: _SidebarRow(label: tag, palette: p),
            ),
          _SectionHead(
            label: '储藏',
            palette: p,
            action: _git == null ? null : _SectionAction('⤓', '储藏当前改动', () {
              _stashAction('储藏改动', () => _git!.stashSave());
            }),
          ),
          for (final st in _stashes)
            ContextMenuRegion(
              items: () => _stashMenu(st),
              child: _SidebarRow(
                label: st.message,
                palette: p,
                leading: '${st.index}',
                leadingColor: p.textDim,
                // Left click opens the same menu: a stash row has no primary
                // action worth guessing at, and hunting for the right mouse
                // button to find out a row is actionable is worse.
                onTapAt: (pos) => showRepoMenu(
                  context: context,
                  position: pos,
                  items: _stashMenu(st),
                ),
              ),
            ),
          _SectionHead(label: '改动', palette: p),
          for (final f in _changes)
            ContextMenuRegion(
              items: () => _fileMenu(f),
              child: _SidebarRow(
                label: f.path,
                palette: p,
                leading: f.status,
                leadingColor: f.staged ? p.green : p.yellow,
                onTap: () => _showFile(f),
                active: switch (_target) {
                  WorkingFileDiff(:final path, :final staged) =>
                    path == f.path && staged == f.staged,
                  _ => false,
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _mainRight(Palette p) {
    return Column(
      children: [
        SizedBox(
          height: _historyHeight,
          child: Column(
            children: [
              _PaneHead(title: '历史', palette: p),
              Expanded(
                child: HistoryView(
                  layout: _graph,
                  selected: _selectedCommit?.id,
                  onSelect: _selectCommit,
                  controller: _historyScroll,
                  menuFor: _commitMenu,
                ),
              ),
            ],
          ),
        ),
        // Between history and diff, where the Tauri version puts it: the user
        // sees it right after the operation that stopped.
        if (_conflicts.isNotEmpty || _op != 'none') _conflictBanner(p),
        _Splitter(
          axis: Axis.vertical,
          palette: p,
          onDrag: (d) => setState(
              () => _historyHeight = (_historyHeight + d).clamp(80.0, 700.0)),
          onDragEnd: () => widget.prefs.setHistoryHeight(_historyHeight),
          onReset: () {
            setState(() => _historyHeight = 260);
            widget.prefs.setHistoryHeight(260);
          },
        ),
        Expanded(child: _diffPane(p)),
      ],
    );
  }

  Widget _diffPane(Palette p) {
    final title = switch (_target) {
      NoDiff() => '差异',
      WorkingFileDiff(:final path, :final staged) =>
        '$path${staged ? '（已暂存）' : ''}',
      CommitFileDiff(:final path) => path,
      BlameTarget(:final path) => '逐行归属 — $path',
    };
    final staged = switch (_target) {
      WorkingFileDiff(:final staged) => staged,
      _ => false,
    };
    final interactive = _target is WorkingFileDiff;

    return Column(
      children: [
        _PaneHead(title: title, palette: p),
        Expanded(
          child: Row(
            children: [
              if (_selectedCommit != null && _target is CommitFileDiff)
                SizedBox(
                  width: 200,
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border(right: BorderSide(color: p.border)),
                    ),
                    child: ListView(
                      children: [
                        for (final f in _commitFiles)
                          _SidebarRow(
                            label: f.path,
                            // Core reports each file's status in the commit,
                            // so the list can say added / modified / deleted.
                            leading: f.status,
                            leadingColor: p.textDim,
                            palette: p,
                            active: switch (_target) {
                              CommitFileDiff(:final path) => path == f.path,
                              _ => false,
                            },
                            onTap: () async {
                              setState(() => _target =
                                  CommitFileDiff(_selectedCommit!.id, f.path));
                              await _reloadDiff();
                            },
                          ),
                      ],
                    ),
                  ),
                ),
              Expanded(
                child: switch (_target) {
                  BlameTarget() => BlameView(
                      lines: _blame,
                      // A sha jumps to that commit's diff for this file — the
                      // usual next question after "who wrote this line".
                      onOpenCommit: (oid) async {
                        final path = (_target as BlameTarget).path;
                        setState(() => _target = CommitFileDiff(oid, path));
                        await _reloadDiff();
                      },
                    ),
                  _ => DiffPane(
                      hunks: _hunks,
                      mode: _mode,
                      staged: staged,
                      onApply: interactive ? _applyPartial : null,
                    ),
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// How far HEAD is from its upstream. Nothing is shown when the branch is in
  /// step — a pair of zeroes is noise, and their absence is the same message.
  Widget _trackingChip(Palette p) {
    final t = _tracking;
    if (t == null || (t.ahead == BigInt.zero && t.behind == BigInt.zero)) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Row(
        children: [
          if (t.ahead > BigInt.zero)
            Text('↑${t.ahead}',
                style: ui.copyWith(color: p.green, fontSize: 11)),
          if (t.ahead > BigInt.zero && t.behind > BigInt.zero)
            const SizedBox(width: 4),
          if (t.behind > BigInt.zero)
            Text('↓${t.behind}',
                style: ui.copyWith(color: p.yellow, fontSize: 11)),
        ],
      ),
    );
  }

  /// The conflict banner: what stopped, which files are still unresolved, and
  /// the continue/abort that matches the operation. Continue stays disabled
  /// while any file is unresolved — git would refuse anyway, with a worse
  /// message.
  Widget _conflictBanner(Palette p) {
    final blocked = _conflicts.isNotEmpty;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: p.yellow.withValues(alpha: 0.12),
        border: Border(
          top: BorderSide(color: p.border),
          bottom: BorderSide(color: p.border),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            blocked
                ? '$_opLabel进行中 — ${_conflicts.length} 处冲突待解决'
                : '$_opLabel进行中 — 冲突已解决，可继续',
            style: ui.copyWith(color: p.yellow),
          ),
          const SizedBox(height: 4),
          for (final f in _conflicts)
            _SidebarRow(
              label: f,
              palette: p,
              leading: '!',
              leadingColor: p.red,
              onTap: () => _openMerge(f),
            ),
          if (_op != 'none') ...[
            const SizedBox(height: 6),
            Row(
              children: [
                _ToolButton(
                  label: '继续$_opLabel',
                  enabled: !blocked,
                  onTap: () => _opAction('continue'),
                ),
                _ToolButton(
                  label: '中止$_opLabel',
                  enabled: true,
                  onTap: () => _opAction('abort'),
                ),
                // Only the replaying operations can skip a commit; a merge has
                // nothing to skip.
                if (_op != 'merge')
                  _ToolButton(
                    label: '跳过此提交',
                    enabled: true,
                    onTap: () => _opAction('skip'),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _statusBar(Palette p) {
    return Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: p.bgAlt,
        border: Border(top: BorderSide(color: p.border)),
      ),
      child: Text(_status, style: ui.copyWith(color: p.textDim, fontSize: 11)),
    );
  }
}

/// A draggable divider. The DOM version gets the cursor and the hit area from
/// CSS and the drag from three pointer listeners; here the whole thing is one
/// widget, which is the trade this port keeps making.
class _Splitter extends StatelessWidget {
  const _Splitter({
    required this.axis,
    required this.palette,
    required this.onDrag,
    required this.onReset,
    this.onDragEnd,
  });

  final Axis axis;
  final Palette palette;
  final void Function(double delta) onDrag;
  final VoidCallback onReset;

  /// Called once when the drag finishes — the moment worth persisting.
  final VoidCallback? onDragEnd;

  @override
  Widget build(BuildContext context) {
    final horizontal = axis == Axis.horizontal;
    return MouseRegion(
      cursor: horizontal
          ? SystemMouseCursors.resizeColumn
          : SystemMouseCursors.resizeRow,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onDoubleTap: onReset,
        onHorizontalDragUpdate: horizontal ? (d) => onDrag(d.delta.dx) : null,
        onVerticalDragUpdate: horizontal ? null : (d) => onDrag(d.delta.dy),
        onHorizontalDragEnd: horizontal ? (_) => onDragEnd?.call() : null,
        onVerticalDragEnd: horizontal ? null : (_) => onDragEnd?.call(),
        child: Container(
          width: horizontal ? 7 : null,
          height: horizontal ? null : 7,
          color: palette.bgAlt,
        ),
      ),
    );
  }
}

class _ToolButton extends StatefulWidget {
  const _ToolButton({
    required this.label,
    required this.enabled,
    required this.onTap,
    this.tooltip,
    this.onSecondaryTapAt,
  });
  final String label;
  final bool enabled;
  final VoidCallback onTap;

  /// A right-click alternative, handed the pointer position for a menu.
  final void Function(Offset position)? onSecondaryTapAt;

  /// Where a push would land, for the push button: `main → origin : main`.
  final String? tooltip;

  @override
  State<_ToolButton> createState() => _ToolButtonState();
}

class _ToolButtonState extends State<_ToolButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = Theming.of(context);
    final button = MouseRegion(
      cursor:
          widget.enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.enabled ? widget.onTap : null,
        onSecondaryTapUp: widget.onSecondaryTapAt == null
            ? null
            : (d) => widget.onSecondaryTapAt!(d.globalPosition),
        child: Container(
          margin: const EdgeInsets.only(left: 6),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: _hover && widget.enabled ? p.bgHover : p.bgElev,
            border: Border.all(color: p.border),
            borderRadius: BorderRadius.circular(5),
          ),
          child: Text(
            widget.label,
            style: ui.copyWith(color: widget.enabled ? p.text : p.textDim),
          ),
        ),
      ),
    );

    // The push button says where it would land; the others need no explaining.
    return widget.tooltip == null
        ? button
        : Tooltip(message: widget.tooltip!, child: button);
  }
}

/// The ＋ / ⤓ button some sidebar sections carry.
class _SectionAction {
  const _SectionAction(this.glyph, this.tooltip, this.onTap);
  final String glyph;
  final String tooltip;
  final VoidCallback onTap;
}

class _SectionHead extends StatelessWidget {
  const _SectionHead({required this.label, required this.palette, this.action});
  final String label;
  final Palette palette;
  final _SectionAction? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 10, 6, 4),
      child: Row(
        children: [
          Text(
            label,
            style: ui.copyWith(
                color: palette.textDim, fontSize: 11, letterSpacing: 0.4),
          ),
          const Spacer(),
          if (action != null)
            Tooltip(
              message: action!.tooltip,
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: action!.onTap,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(action!.glyph,
                        style: ui.copyWith(color: palette.textDim)),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _PaneHead extends StatelessWidget {
  const _PaneHead({required this.title, required this.palette});
  final String title;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 26,
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: palette.bgAlt,
        border: Border(bottom: BorderSide(color: palette.border)),
      ),
      child: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: ui.copyWith(color: palette.textDim, fontSize: 11),
      ),
    );
  }
}

class _SidebarRow extends StatefulWidget {
  const _SidebarRow({
    required this.label,
    required this.palette,
    this.leading,
    this.leadingColor,
    this.active = false,
    this.onTap,
    this.onTapAt,
  });

  final String label;
  final Palette palette;
  final String? leading;
  final Color? leadingColor;
  final bool active;
  final VoidCallback? onTap;

  /// Like [onTap], but handed the click position — for rows whose action is to
  /// open a menu, which has to appear where the pointer is.
  final void Function(Offset position)? onTapAt;

  @override
  State<_SidebarRow> createState() => _SidebarRowState();
}

class _SidebarRowState extends State<_SidebarRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return MouseRegion(
      cursor: widget.onTap == null
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onTapUp: widget.onTapAt == null
            ? null
            : (d) => widget.onTapAt!(d.globalPosition),
        child: Container(
          height: 22,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          color: widget.active
              ? p.bgSel
              : _hover
                  ? p.bgHover
                  : null,
          child: Row(
            children: [
              if (widget.leading != null) ...[
                SizedBox(
                  width: 14,
                  child: Text(
                    widget.leading!,
                    style: mono.copyWith(
                      fontSize: 11,
                      color: widget.leadingColor ?? p.accent,
                    ),
                  ),
                ),
              ],
              Expanded(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ui.copyWith(color: p.text),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
