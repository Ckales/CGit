import 'dart:async';
import 'dart:io' show Platform;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'ai_settings.dart';
import 'blame_view.dart';
import 'branch_menu.dart';
import 'clone_sheet.dart';
import 'commit_menu.dart';
import 'commit_sheet.dart';
import 'context_menu.dart';
import 'diff_view.dart';
import 'git.dart';
import 'git_text.dart';
import 'history_view.dart';
import 'merge_view.dart';
import 'network_ops.dart';
import 'op_log.dart';
import 'prefs.dart';
import 'dialogs.dart';
import 'prompt.dart';
import 'push_dialog.dart';
import 'rebase_plan.dart';
import 'rebase_sheet.dart';
import 'settings_sheet.dart';
import 'theme.dart';
import 'watch_debounce.dart';

Future<void> main(List<String> args) async {
  // The Rust side lives in cgit_rust.framework; nothing below can call it until
  // this resolves, so it blocks rather than racing the first repo load.
  WidgetsFlutterBinding.ensureInitialized();
  await initGitBridge();
  final prefs = await Prefs.load();
  OpLog.enabled = prefs.opLog;

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
  late Palette _palette = widget.prefs.isDark ? Palette.dark : Palette.light;
  late int _fontSize = widget.prefs.fontSize;

  /// Theme and font size, applied without saving. The settings dialog previews
  /// with this and puts the stored values back when it is cancelled.
  void _apply(bool dark, int fontSize) => setState(() {
        _palette = dark ? Palette.dark : Palette.light;
        _fontSize = fontSize;
      });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'cgit — Git 客户端',
      debugShowCheckedModeBanner: false,
      home: Builder(
        builder: (context) => MediaQuery(
          // One text scale is the single font-size knob — the alternative is
          // threading a size through a few hundred call sites.
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(_fontSize / Prefs.baseFontSize),
          ),
          child: Theming(
            palette: _palette,
            // This app draws its own chrome rather than using Scaffold, and
            // Scaffold is what normally supplies the Material ancestor that
            // TextField and the other material widgets assert on. Without this,
            // the commit box renders as a red "No Material widget found" block
            // instead of an input. `transparency` provides the ancestor without
            // painting a background.
            child: Material(
              type: MaterialType.transparency,
              child: RepoScreen(
                startPath: widget.startPath,
                prefs: widget.prefs,
                onApplyLook: _apply,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// What the diff pane is currently showing, as one sealed type with the states
/// named.
sealed class DiffTarget {
  const DiffTarget();
}

class NoDiff extends DiffTarget {
  const NoDiff();
}

/// A working-tree file. [repo] is its repo's path: the commit dialog lists
/// every repo in the workspace, not only the active one.
class WorkingFileDiff extends DiffTarget {
  const WorkingFileDiff(this.repo, this.path, this.staged);
  final String repo;
  final String path;
  final bool staged;

  @override
  bool operator ==(Object other) =>
      other is WorkingFileDiff &&
      other.repo == repo &&
      other.path == path &&
      other.staged == staged;

  @override
  int get hashCode => Object.hash(repo, path, staged);
}

class CommitFileDiff extends DiffTarget {
  const CommitFileDiff(this.oid, this.path);
  final String oid;
  final String path;

  @override
  bool operator ==(Object other) =>
      other is CommitFileDiff && other.oid == oid && other.path == path;

  @override
  int get hashCode => Object.hash(oid, path);
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
    required this.onApplyLook,
  });
  final String startPath;
  final Prefs prefs;

  /// Applies 主题 / 字号 to the whole app without saving them.
  final void Function(bool dark, int fontSize) onApplyLook;

  @override
  State<RepoScreen> createState() => _RepoScreenState();
}

class _RepoScreenState extends State<RepoScreen> {
  Git? _git;
  String _repoName = '未打开仓库';
  String _repoPath = '';

  /// The workspace root when several repos share one, the repo itself
  /// otherwise — this is what the project pill names and what goes in the
  /// recent list.
  String _workspaceRoot = '';
  String _branch = '';
  String _statusText = '就绪';

  /// Set while the status bar shows a failure: the full text behind the one
  /// line, opened by clicking it.
  String? _statusDetail;

  /// Every status write goes through here, so a later success clears the red
  /// state and the operation log sees each message.
  String get _status => _statusText;
  set _status(String v) {
    _statusText = v;
    _statusDetail = null;
    OpLog.info(v);
  }

  /// A failure: one line in the status bar, the whole text a click away. git's
  /// stderr is several lines and the reason is rarely the first.
  void _fail(String detail, {String? summary}) {
    final line = summary ?? errorSummary(detail);
    OpLog.error(line);
    setState(() {
      _statusText = line;
      _statusDetail = detail.trim();
    });
  }

  List<BranchInfo> _branches = const [];
  List<String> _tags = const [];
  List<RemoteInfo> _remotes = const [];
  List<FileStatus> _changes = const [];
  GraphLayout _graph = const GraphLayout([], 1);

  GraphCommit? _selectedCommit;
  List<FileStatus> _commitFiles = const [];

  /// Folded folders in the commit file tree, by path. Kept across commits: a
  /// folder the user closed once is usually one they don't care about.
  final _collapsedCommitDirs = <String>{};
  DiffTarget _target = const NoDiff();

  /// One entry per run of changed lines in the open diff, "hunkIndex:rowIndex",
  /// in the order they appear. This is what ↑/↓ step through — by block, not by
  /// line, as IDEA does.
  List<String> _blocks = const [];
  final _blockKeys = <String, GlobalKey>{};
  int _blockIndex = -1;

  /// Where ← goes back to. Blame and file history take over the whole pane, so
  /// without this the only way out of them is ✕, which closes everything.
  DiffTarget? _paneBack;
  List<String> _hunks = const [];

  /// Shown when a file has no hunks — untracked, newly added or binary. The
  /// diff pane falls back to plain text rather than saying there is no diff,
  /// which for a brand-new file would be wrong.
  String _plainDiff = '';
  List<BlameLine> _blame = const [];

  late DiffMode _mode =
      widget.prefs.isSplitDiff ? DiffMode.split : DiffMode.unified;
  bool _commitOpen = false;

  /// The commit panel docked under the history for the active repo — only
  /// ever for one with changes; a clean repo gets no empty box.
  bool _commitDocked = false;
  bool _settingsOpen = false;
  bool _cloneOpen = false;

  /// Sibling repositories found alongside the open one, for the workspace
  /// switcher. A single-repo folder leaves this at one entry and the switcher
  /// stays hidden.
  List<RepoRef> _workspaceRepos = const [];

  /// Status of every workspace repo, by path. The
  /// commit dialog lists these, and a non-empty one puts * in the 仓库 list.
  Map<String, List<FileStatus>> _repoChanges = const {};

  /// Every workspace repo's upstream standing, by path. Puts ↑N in the 仓库
  /// list; refreshed alongside [_repoChanges].
  Map<String, Tracking> _repoTracking = const {};

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

  /// Editors found on this machine, loaded once — the list only changes when
  /// the user installs something, which is not worth polling for.
  /// App icons for the editors picked in settings, keyed by app name. Null
  /// means "asked and there is none" — apps that pack icons into Assets.car
  /// have none to extract, and that is a text-only button, not an error.
  Map<String, Uint8List?> _editorIcons = const {};
  AiSettings? _ai;
  List<StashEntry> _stashes = const [];
  List<String> _remoteBranches = const [];

  /// Search is a separate view over history rather than a filter on the graph:
  /// searchCommits returns a flat list with no parent links, so there are no
  /// lanes to draw. Empty filters mean the graph is showing.
  final _searchText = TextEditingController();
  final _searchAuthor = TextEditingController();
  List<CommitInfo>? _searchResults;

  /// One network call at a time: they all touch the same refs, and a fetch
  /// racing a push produces failures that are nobody's fault.
  bool _netBusy = false;

  /// The file open in the merge window, and its worktree text.
  String? _mergeFile;
  String _mergeContent = '';

  /// The in-progress interactive rebase plan, and the base it rewrites onto.
  RebasePlan? _rebasePlan;
  String _rebaseBase = '';

  late double _sidebarWidth = widget.prefs.sidebarWidth ?? 220;
  late double _historyHeight = widget.prefs.historyHeight ?? 260;

  final _historyScroll = ScrollController();

  /// The file-system watcher for the open repo. Cancelled and replaced when
  /// another repo is opened, so a closed repo stops driving refreshes.
  StreamSubscription<String>? _watch;

  /// Coalesces a burst of file events into one refresh, and decides its depth.
  WatchDebounce? _watchDebounce;

  /// Siblings are not watched, so their * is re-read when the window comes
  /// back to the front — the usual moment after editing them elsewhere.
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: () {
      if (_git != null) _refreshRepoChanges();
    });
    _openRepo(widget.startPath);
    AiSettings.load().then((ai) {
      if (mounted) setState(() => _ai = ai);
    });
    _loadEditorIcons();
  }

  Future<void> _onSettingsSaved() async {
    setState(() {
      _settingsOpen = false;
      _mode = widget.prefs.isSplitDiff ? DiffMode.split : DiffMode.unified;
      OpLog.enabled = widget.prefs.opLog;
      _status = '设置已保存';
    });
    await _loadEditorIcons();
    // 每页条数变了要重新取图，所以这里是全量刷新而不是只重画。
    if (_git != null) await _refresh();
  }

  /// Fetched once per chosen editor and reused. Each one costs a `sips` call,
  /// so this runs off the open path rather than inside the toolbar build.
  Future<void> _loadEditorIcons() async {
    final names = widget.prefs.editors;
    final icons = await Future.wait(names.map(Git.editorIcon));
    if (mounted) {
      setState(() =>
          _editorIcons = {for (final (i, n) in names.indexed) n: icons[i]});
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _watch?.cancel();
    _watchDebounce?.cancel();
    _historyScroll.dispose();
    _searchText.dispose();
    _searchAuthor.dispose();
    super.dispose();
  }

  /// Re-run the search, or drop back to the graph when both fields are empty.
  Future<void> _runSearch() async {
    final git = _git;
    if (git == null) return;
    final query = _searchText.text.trim();
    final author = _searchAuthor.text.trim();
    if (query.isEmpty && author.isEmpty) {
      setState(() => _searchResults = null);
      return;
    }
    try {
      final found = await git.searchCommits(query: query, author: author);
      if (mounted) setState(() => _searchResults = found);
    } on GitError catch (e) {
      if (mounted) _fail(e.message);
    }
  }

  Future<void> _openRepo(String path) async {
    final workspace = await Git.discover(path);
    if (workspace == null || workspace.repos.isEmpty) {
      _fail('不是 Git 仓库：$path');
      return;
    }
    // A workspace can hold sibling repos; the sidebar picker for those is not
    // built yet, so open the first and keep the rest for when it is.
    // A workspace can hold sibling repos; keep them for the switcher and open
    // the one the user asked for when the path names it exactly.
    final repo = workspace.repos.firstWhere(
      (r) => r.path == path,
      orElse: () => workspace.repos.first,
    );
    setState(() {
      _workspaceRoot = workspace.root;
      _workspaceRepos = workspace.repos;
    });
    // The root, not the member: a member path reopens as a lone repo.
    await widget.prefs.rememberRepo(workspace.root);
    await _setActiveRepo(repo);
  }

  /// Point the panels at one repo of the open workspace. The sidebar's 仓库
  /// list comes here, not to [_openRepo]: rediscovering from a member's path
  /// finds only that member, and the rest of the list would disappear.
  Future<void> _setActiveRepo(RepoRef repo) async {
    setState(() {
      _git = Git(repo.path);
      _repoName = repo.name;
      _repoPath = repo.path;
      _commitDocked = false;
      // Selection, open diff and search all name the previous repo's objects.
      _selectedCommit = null;
      _commitFiles = const [];
      _searchResults = null;
      _target = const NoDiff();
      _paneBack = null;
    });
    _startWatching(repo.path);
    await _refresh();
  }

  /// A click in the sidebar's 仓库 list: switch to
  /// the repo, and dock its commit panel only when it has something to commit.
  Future<void> _openRepoCommit(RepoRef repo) async {
    await _setActiveRepo(repo);
    if (!mounted) return;
    if (_changes.isEmpty) {
      setState(() => _status = '${repo.name} 没有可提交内容');
      return;
    }
    setState(() {
      _commitDocked = true;
      _commitOpen = false;
    });
  }

  /// Only the active repo is watched, so a sibling's status is as fresh as the
  /// last refresh.
  Future<void> _refreshRepoChanges() async {
    final results =
        await Future.wait([_readRepoChanges(), _readRepoTracking()]);
    if (!mounted) return;
    setState(() {
      _repoChanges = results[0] as Map<String, List<FileStatus>>;
      _repoTracking = results[1] as Map<String, Tracking>;
    });
  }

  /// Every workspace repo's tracking, read in parallel. A repo that fails to
  /// read is left out; the push dialog lists it as unreadable.
  Future<Map<String, Tracking>> _readRepoTracking() async {
    final tracking = <String, Tracking>{};
    await Future.wait([
      for (final r in _workspaceRepos)
        Git(r.path).tracking().then((t) {
          tracking[r.path] = t;
        }, onError: (Object e) {
          debugPrint('tracking of ${r.path} failed: $e');
        }),
    ]);
    return tracking;
  }

  /// One repo's tracking. The active repo's is [_tracking], read on every
  /// refresh; siblings' only move on a full refresh.
  Tracking? _trackingOf(String path) =>
      path == _repoPath ? _tracking : _repoTracking[path];

  /// Every workspace repo's status, read live and in parallel. A repo that
  /// fails to read is left out; opening it shows git's own error.
  Future<Map<String, List<FileStatus>>> _readRepoChanges() async {
    final changes = <String, List<FileStatus>>{};
    await Future.wait([
      for (final r in _workspaceRepos)
        Git(r.path).status().then((files) {
          changes[r.path] = files;
        }, onError: (Object e) {
          debugPrint('status of ${r.path} failed: $e');
        }),
    ]);
    return changes;
  }

  /// One repo's changes. The active repo's is [_changes], which the watcher
  /// keeps freshest; [_repoChanges] only moves on a full refresh.
  List<FileStatus> _changesOf(String path) =>
      path == _repoPath ? _changes : (_repoChanges[path] ?? const []);

  /// What the commit sheet lists: docked, the active repo alone; as a dialog,
  /// every repo with changes in sidebar order.
  List<RepoChanges> _commitGroups() {
    final docked = _commitDocked && !_commitOpen;
    final groups = <RepoChanges>[];
    for (final r in _workspaceRepos) {
      if (docked && r.path != _repoPath) continue;
      final changes = _changesOf(r.path);
      if (changes.isEmpty) continue;
      groups.add((repo: r, changes: changes));
    }
    return groups;
  }

  RepoRef get _activeRepo => _repoAt(_repoPath);

  RepoRef _repoAt(String path) =>
      _workspaceRepos.firstWhere((r) => r.path == path);

  /// Make [path] the active repo unless it already is. For file actions whose
  /// views (history list, blame) read through [_git].
  Future<void> _activate(String path) async {
    if (path == _repoPath) return;
    await _setActiveRepo(_repoAt(path));
  }

  /// [_workspaceRepos] with one repo's branch badge replaced.
  List<RepoRef> _withRepoBranch(String path, String branch) => [
        for (final r in _workspaceRepos)
          r.path == path
              ? RepoRef(path: r.path, name: r.name, branch: branch)
              : r,
      ];

  /// Right-click on a 仓库 row: that repo's
  /// local and remote branches, a click checks one out there. The selected
  /// repo stays as it is.
  Future<void> _showRepoBranchMenu(RepoRef repo, Offset position) async {
    final git = Git(repo.path);
    final List<BranchInfo> locals;
    final List<String> remotes;
    try {
      locals = await git.branches();
      remotes = await git.remoteBranches();
    } on GitError catch (e) {
      if (mounted) _fail(e.message);
      return;
    }
    if (!mounted) return;
    await showRepoMenu(
      context: context,
      position: position,
      items: [
        MenuAction.header('${repo.name} · 本地分支'),
        for (final b in locals)
          MenuAction(
            b.name,
            b.isCurrent
                ? () {}
                : () =>
                    _checkoutInRepo(repo, b.name, () => git.checkout(b.name)),
            current: b.isCurrent,
          ),
        // Every remote branch as git lists it, matching the 远端分支 panel.
        if (remotes.isNotEmpty) ...[
          const MenuAction.header('远端分支'),
          for (final full in remotes)
            MenuAction(
              full,
              () => _checkoutInRepo(repo, full, () => git.checkoutRef(full)),
            ),
        ],
      ],
    );
  }

  Future<void> _checkoutInRepo(
    RepoRef repo,
    String label,
    Future<void> Function() action,
  ) async {
    final active = repo.path == _repoPath;
    try {
      await action();
      if (active) {
        await _refresh();
      } else {
        final branch = await Git(repo.path).currentBranch();
        if (!mounted) return;
        setState(() => _workspaceRepos = _withRepoBranch(repo.path, branch));
      }
    } on GitError catch (e) {
      if (mounted) _fail(e.message);
      return;
    }
    if (!mounted) return;
    setState(
        () => _status = active ? '已切换到 $label' : '${repo.name} 已切换到 $label');
  }

  /// Watch the open repo so changes made outside this app — a commit from the
  /// terminal, a checkout in an IDE — show up without pressing 刷新.
  void _startWatching(String path) {
    _watch?.cancel();
    _watchDebounce?.cancel();

    // A working-tree edit changes no commit and no branch label, so it gets the
    // light refresh. A checkout or a commit made elsewhere does, and the watcher
    // is the only thing that tells us about those — our own actions call
    // _refresh() directly.
    _watchDebounce = WatchDebounce(
      onRefresh: (full) => full ? _refresh() : _refreshLight(),
    );

    _watch = Git(path).watch().listen(
          _watchDebounce!.add,
          // A watcher that dies is not worth a dialog: the manual refresh still
          // works, and the next repo open starts a new one.
          onError: (_) {},
        );
  }

  /// Changes, branches and conflicts — everything a working-tree edit can move.
  /// The commit graph is left alone because no commit changed.
  Future<void> _refreshLight() async {
    final git = _git;
    if (git == null) return;
    try {
      final results = await Future.wait([
        git.status(),
        git.branches(),
        git.conflicts(),
        git.repoState(),
      ]);
      if (!mounted) return;
      setState(() {
        _changes = results[0] as List<FileStatus>;
        _branches = results[1] as List<BranchInfo>;
        _conflicts = results[2] as List<String>;
        _op = results[3] as String;
      });
      await _reloadDiff();
    } on GitError {
      // A refresh the user did not ask for stays quiet; the next explicit
      // action will report the same failure with context.
    }
  }

  /// One reload for everything the window shows; a rebuild is cheap enough not
  /// to split it per list.
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
        git.graph(limit: widget.prefs.historyPageSize),
        git.conflicts(),
        git.repoState(),
        git.tracking(),
        git.stashList(),
        git.remoteBranches(),
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
        _remoteBranches = results[10] as List<String>;
        // The 仓库 badges were read once at discover; keep the open one in step
        // with checkouts made here or elsewhere.
        _workspaceRepos = _withRepoBranch(_repoPath, _branch);
        _status = '就绪';
      });
      await Future.wait([_reloadDiff(), _refreshRepoChanges()]);
    } on GitError catch (e) {
      if (mounted) _fail(e.message);
    }
  }

  /// Recomputed from the hunks rather than collected while rendering, so ↑/↓
  /// works the same whether or not a row has been built yet. Keys are reused
  /// across rebuilds — a fresh GlobalKey every frame would detach the element
  /// ensureVisible is aiming at.
  void _recomputeBlocks() {
    final split = _mode == DiffMode.split;
    final blocks = <String>[];
    for (final (i, hunk) in _hunks.indexed) {
      for (final row in changeBlockRows(hunk, split: split)) {
        blocks.add('$i:$row');
      }
    }
    _blocks = blocks;
    _blockIndex = -1;
    _blockKeys.removeWhere((id, _) => !blocks.contains(id));
    for (final id in blocks) {
      _blockKeys.putIfAbsent(id, GlobalKey.new);
    }
  }

  /// The files ↑/↓ walk into once the current one runs out, in the order of
  /// whatever list produced this diff.
  List<({String label, DiffTarget target})> get _navFiles => switch (_target) {
        WorkingFileDiff() => [
            for (final g in _commitGroups())
              for (final f in g.changes)
                (
                  label: f.path,
                  target: WorkingFileDiff(g.repo.path, f.path, f.staged),
                ),
          ],
        CommitFileDiff(:final oid) => [
            for (final f in _commitFiles)
              (label: f.path, target: CommitFileDiff(oid, f.path)),
          ],
        _ => const [],
      };

  int get _navIndex => _navFiles.indexWhere((f) => f.target == _target);

  /// Step to the previous (-1) or next (+1) change, continuing into the
  /// adjacent file once this one runs out — the behaviour of IDEA's ↑/↓.
  Future<void> _navigateChange(int dir) async {
    if (_git == null) return;
    final files = _navFiles;

    var target = nextChangeTarget(
      blockIndex: _blockIndex,
      blockCount: _blocks.length,
      navIndex: _navIndex,
      navCount: files.length,
      dir: dir,
    );

    // Walk files until one actually renders a block: a binary file or a pure
    // rename has nothing to step through, and stopping on it would look broken.
    while (target.kind == ChangeTargetKind.file) {
      setState(() => _target = files[target.index].target);
      await _reloadDiff();
      if (_blocks.isNotEmpty) {
        _focusBlock(dir > 0 ? 0 : _blocks.length - 1);
        return;
      }
      target = nextChangeTarget(
        blockIndex: -1,
        blockCount: 0,
        navIndex: target.index,
        navCount: files.length,
        dir: dir,
      );
    }

    if (target.kind == ChangeTargetKind.block) {
      _focusBlock(target.index);
      return;
    }
    setState(() => _status = dir > 0 ? '没有更多改动了' : '已经到第一处改动了');
  }

  void _focusBlock(int index) {
    setState(() {
      _blockIndex = index;
      final where = _navIndex < 0 ? '' : ' — ${_navFiles[_navIndex].label}';
      _status = '第 ${index + 1}/${_blocks.length} 处改动$where';
    });
    final ctx = _blockKeys[_blocks[index]]?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx,
          alignment: 0.3, duration: const Duration(milliseconds: 120));
    }
  }

  Future<void> _reloadDiff() async {
    final git = switch (_target) {
      WorkingFileDiff(:final repo) => Git(repo),
      _ => _git,
    };
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
      // No hunks does not mean no content: an untracked or newly added file has
      // everything to show and nothing to stage line by line.
      var plain = '';
      if (hunks.hunks.isEmpty) {
        plain = switch (_target) {
          WorkingFileDiff(:final path, :final staged) => staged
              ? await git.stagedDiff(file: path)
              : await git.unstagedDiff(file: path),
          _ => '',
        };
      }
      if (mounted) {
        setState(() {
          _hunks = hunks.hunks;
          _plainDiff = plain;
          _recomputeBlocks();
        });
      }
    } on GitError catch (e) {
      if (mounted) _fail(e.message);
    }
  }

  /* ---------- history ---------- */

  List<MenuAction> _commitMenu(GraphCommit c) => commitMenu(
        run: (cmd) => switch (cmd) {
          CommitCommand.resetMixed => _stashAction(
              '重置到 ${_short(c)}', () => _git!.resetTo(c.id, 'mixed')),
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
          CommitCommand.rebaseFrom => _openRebase(c.id),
          CommitCommand.tag => _newTag(oid: c.id),
          CommitCommand.patchToClipboard => _patchToClipboard(c),
          CommitCommand.patchToFile => _patchToFile(c),
        },
      );

  String _short(GraphCommit c) => c.id.substring(0, 7);

  /// `base..HEAD` is what gets rewritten, so the commit the user right-clicked
  /// is the base — it stays put and everything after it is replayed.
  Future<void> _openRebase(String base) async {
    final git = _git;
    if (git == null) return;
    try {
      final todo = await git.rebaseTodo(base);
      if (!mounted) return;
      if (todo.isEmpty) {
        setState(() => _status = '该提交之后没有可变基的提交');
        return;
      }
      setState(() {
        _rebaseBase = base;
        _rebasePlan = RebasePlan.fromTodo(todo);
      });
    } on GitError catch (e) {
      if (mounted) _fail(e.message);
    }
  }

  Future<void> _startRebase({
    required String todo,
    required List<String> messages,
    required bool autostash,
  }) async {
    final git = _git;
    final base = _rebaseBase;
    if (git == null) return;
    setState(() => _rebasePlan = null);
    await _stashAction(
      '变基',
      () => git.rebaseInteractive(
        base: base,
        todo: todo,
        messages: messages,
        autostash: autostash,
      ),
    );
  }

  /// Check out any ref by name — a remote branch, a tag, or a sha.
  Future<void> _checkoutRef(String refName) => _stashAction(
        '检出 $refName',
        () => _git!.checkoutRef(refName),
      );

  Future<void> _showFileHistory(String file) async {
    final git = _git;
    if (git == null) return;
    try {
      final history = await git.fileHistory(file);
      if (!mounted) return;
      if (history.isEmpty) {
        setState(() => _status = '$file 没有提交历史');
        return;
      }
      // Reuses the search list: a file's history is a flat commit list with no
      // lanes, exactly like a search result.
      setState(() {
        _searchResults = history;
        _searchText.text = '';
        _searchAuthor.text = '';
        _status = '$file 的历史（${history.length} 条）';
      });
    } on GitError catch (e) {
      if (mounted) _fail(e.message);
    }
  }

  Future<void> _patchToClipboard(GraphCommit c) async {
    final git = _git;
    if (git == null) return;
    try {
      final patch = await git.commitPatch(c.id);
      await git.copyToClipboard(patch);
      if (mounted) setState(() => _status = '已复制 ${_short(c)} 的补丁到剪贴板');
    } on GitError catch (e) {
      if (mounted) _fail(e.message);
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
      if (mounted) _fail(e.message);
    }
  }

  List<MenuAction> _branchMenu(BranchInfo b) => branchMenu(
        branch: b,
        currentBranch: _branch,
        run: (cmd) => switch (cmd) {
          BranchCommand.checkout =>
            _branchAction('已切换到 ${b.name}', () => _git!.checkout(b.name)),
          BranchCommand.newFrom => _newBranch(base: b.name),
          BranchCommand.mergeInto =>
            _stashAction('合并 ${b.name}', () => _git!.mergeBranch(b.name)),
          BranchCommand.update =>
            _stashAction('更新 ${b.name}', () => _git!.updateBranch(b.name)),
          BranchCommand.push =>
            _network('推送 ${b.name}', () => _git!.pushBranch(b.name)),
          BranchCommand.applyPatchFromFile => _applyPatchFromFile(),
          BranchCommand.applyPatchFromClipboard =>
            _applyPatchFrom(() => _git!.readClipboard(), '剪贴板'),
          BranchCommand.rename => _renameBranch(b.name),
          BranchCommand.delete => _branchAction(
              '已删除分支 ${b.name}',
              () => _git!.deleteBranch(b.name),
              confirm: '删除分支「${b.name}」？未合并的提交只能靠 reflog 找回。',
            ),
        },
      );

  Future<void> _addRemote() async {
    final name = await promptText(context,
        title: '添加远端', hint: '名称，例如 origin', confirmLabel: '下一步');
    if (name == null || name.trim().isEmpty) return;
    // Two dialogs in sequence: the window can close between them, and reusing
    // a dead context throws rather than quietly doing nothing.
    if (!mounted) return;
    final url = await promptText(context,
        title: "远端 '${name.trim()}' 的地址", hint: 'https://… 或 git@…');
    if (url == null || url.trim().isEmpty) return;
    await _stashAction(
        '添加远端 ${name.trim()}', () => _git!.addRemote(name.trim(), url.trim()));
  }

  /// `origin/feature` splits into the remote and the branch: core needs them
  /// apart, and a branch name may itself contain slashes.
  Future<void> _deleteRemoteBranch(String full) async {
    final cut = full.indexOf('/');
    if (cut < 0) return;
    final remote = full.substring(0, cut);
    final branch = full.substring(cut + 1);
    await _stashAction(
      '删除 $full',
      () => _git!.deleteRemoteBranch(remote, branch),
      confirm: '删除远端分支「$full」？这会改动远端仓库，其他人也会看到。',
    );
  }

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

  /// A working-tree file: the past-commit menu plus 丢弃改动.
  List<MenuAction> _fileMenu(RepoRef repo, FileStatus f) => [
        ..._commitFileMenu(f.path, repo: repo.path),
        MenuAction('丢弃改动', () => _discardFile(repo, f), danger: true),
      ];

  /// A file in a past commit — the same menu without 丢弃改动, which
  /// has nothing to discard there. Editor, history and blame all act on the
  /// working-tree copy.
  /// [repo] is the file's repo when it is not the active one — the commit
  /// dialog lists them all. History and blame show in views that read through
  /// [_git], so those switch to it first.
  List<MenuAction> _commitFileMenu(String path, {String? repo}) {
    final root = repo ?? _repoPath;
    return [
      MenuAction('从项目打开', () => _openProjectAtFile(path, Git(root))),
      MenuAction('编辑文件', () => _openFile(path, Git(root))),
      MenuAction('复制文件路径', () async {
        final full = '$root/$path';
        await Git(root).copyToClipboard(full);
        if (mounted) setState(() => _status = '已复制 $full');
      }),
      MenuAction('文件历史', () async {
        await _activate(root);
        await _showFileHistory(path);
      }),
      MenuAction('逐行归属 (blame)', () async {
        await _activate(root);
        await _showBlame(path);
      }),
    ];
  }

  /// The diff shown belonged to the dialog; left open it would drop into the
  /// main window on its own.
  /// Asked live rather than read off [_changes], which is only as fresh as the
  /// last refresh. A clean repo would open a
  /// dialog with an empty list and a dead 提交 button.
  Future<void> _openCommitDialog() async {
    if (_git == null) return;
    // The dialog spans the workspace, so any repo with changes is enough.
    final changes = await _readRepoChanges();
    if (!mounted) return;
    setState(() => _repoChanges = changes);
    var any = false;
    for (final files in changes.values) {
      if (files.isNotEmpty) any = true;
    }
    if (!any) {
      await _notify('当前没有可提交内容');
      return;
    }
    setState(() {
      _commitDocked = false;
      _commitOpen = true;
    });
  }

  void _closeCommit() => setState(() {
        _commitOpen = false;
        _commitDocked = false;
        _target = const NoDiff();
        _paneBack = null;
      });

  Future<void> _discardFile(RepoRef repo, FileStatus f) async {
    if (!await _confirm(
      title: '丢弃改动',
      body: '丢弃「${f.path}」的改动？未提交的内容无法找回。',
    )) {
      return;
    }
    await _stashAction('丢弃 ${f.path} 的改动', () async {
      await Git(repo.path).discard(f.path);
      return '';
    });
  }

  Future<void> _openFile(String file, Git git) async {
    try {
      await git.openInEditor(file, editor: widget.prefs.editor);
    } on GitError catch (e) {
      if (mounted) _fail(e.message);
    }
  }

  /// The toolbar's 打开项目 plus the file — same project and same editor.
  Future<void> _openProjectAtFile(String file, Git git) async {
    try {
      await git.openProjectWithFile(
        file,
        project: _workspaceRoot,
        editor: _projectEditor,
      );
    } on GitError catch (e) {
      if (mounted) _fail(e.message);
    }
  }

  /* ---------- patches ---------- */

  Future<void> _applyPatchFrom(
      Future<String> Function() source, String from) async {
    final git = _git;
    if (git == null) return;
    try {
      final patch = await source();
      if (patch.trim().isEmpty) {
        if (mounted) setState(() => _status = '$from 没有补丁内容');
        return;
      }
      await git.applyPatchFile(patch);
      await _refresh();
      if (mounted) setState(() => _status = '已从$from应用补丁');
    } on GitError catch (e) {
      if (mounted) _fail(e.message);
    }
  }

  Future<void> _applyPatchFromFile() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'patch', extensions: ['patch', 'diff']),
      ],
    );
    if (file == null) return;
    await _applyPatchFrom(() => _git!.readPatchFile(file.path), '文件');
  }

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

  /// The whole working tree as one patch — core's `create_patch`, which is
  /// what the 补丁 button in the commit dialog exports. Per-commit patches go
  /// through [_patchToFile]; this one is the uncommitted work.
  Future<void> _createWorkingPatch({required bool toClipboard}) async {
    final git = _git;
    if (git == null) return;
    try {
      final patch = await git.createPatch();
      if (patch.trim().isEmpty) {
        if (mounted) setState(() => _status = '没有可导出的改动');
        return;
      }
      if (toClipboard) {
        await git.copyToClipboard(patch);
        if (mounted) setState(() => _status = '补丁已复制到剪贴板');
        return;
      }
      final location = await getSaveLocation(
        suggestedName: patchFileName(_repoName),
        acceptedTypeGroups: const [
          XTypeGroup(label: 'patch', extensions: ['patch', 'diff']),
        ],
      );
      if (location == null) return;
      await git.savePatch(location.path, patch);
      if (mounted) setState(() => _status = '已导出补丁到 ${location.path}');
    } on GitError catch (e) {
      if (mounted) _fail(e.message);
    }
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
      if (mounted) _fail(e.message);
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
        _paneBack = _target is BlameTarget ? _paneBack : _target;
        _target = BlameTarget(file);
      });
    } on GitError catch (e) {
      if (mounted) _fail(e.message);
    }
  }

  Future<void> _showFile(RepoRef repo, FileStatus file) async {
    setState(() {
      _paneBack = null;
      _target = WorkingFileDiff(repo.path, file.path, file.staged);
    });
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
      final raw = await git.commitFiles(commit.id);
      if (!mounted) return;
      // Stored in the tree's drawing order, so ↑/↓ and the first file opened
      // follow the list as the user sees it, not git's flat path order.
      final byPath = {for (final f in raw) f.path: f};
      final files = [
        for (final leaf in treeOrder(
            pathTree([for (final f in raw) TreeFile(f.path, f.status)])))
          byPath[leaf.path]!,
      ];
      setState(() {
        _commitFiles = files;
        _target = files.isEmpty
            ? const NoDiff()
            : CommitFileDiff(commit.id, files.first.path);
      });
      await _reloadDiff();
    } on GitError catch (e) {
      if (mounted) _fail(e.message);
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
      if (mounted) {
        setState(() => _status = out.trim().isEmpty ? '已$label' : out.trim());
      }
    } on GitError catch (e) {
      if (mounted) _fail(e.message);
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
      if (mounted) {
        final hint = networkErrorHint(e.message);
        _fail(hint == null ? e.message : '$hint\n\n${e.message.trim()}',
            summary: hint);
      }
    } finally {
      if (mounted) setState(() => _netBusy = false);
    }
  }

  Future<void> _fetch() => _network('抓取', () => _git!.fetch());

  Future<void> _pull() => _network('拉取', () => _git!.pull());

  /// One repo needs no dialog — there is nothing to choose. A workspace opens
  /// the push dialog with the repos that have commits pre-checked.
  Future<void> _push() async {
    if (_workspaceRepos.length <= 1) return _pushRepos([_repoPath]);
    // Read live: a commit made in a terminal since the last refresh has to be
    // in the list, pre-checked.
    final tracking = await _readRepoTracking();
    if (!mounted) return;
    setState(() => _repoTracking = tracking);
    final rows = <PushRow>[
      for (final r in _workspaceRepos) (repo: r, tracking: tracking[r.path]),
    ];
    final picked = ValueNotifier<Set<String>>({
      for (final row in rows)
        if (hasPushWork(row.tracking)) row.repo.path,
    });
    final targets = await showAppDialog<Set<String>>(
      context,
      title: '推送提交',
      maxWidth: 720,
      body: PushDialogBody(
        rows: rows,
        picked: picked,
        loadFiles: (path) => Git(path).pushFiles(),
      ),
      actions: [
        DialogButton('取消', onTap: () => Navigator.of(context).pop()),
        ValueListenableBuilder(
          valueListenable: picked,
          builder: (context, value, _) => DialogButton(
            value.length > 1 ? '推送 ${value.length} 个仓库' : '推送',
            kind: DialogButtonKind.primary,
            onTap: () => Navigator.of(context).pop(value),
          ),
        ),
      ],
    );
    picked.dispose();
    if (targets == null || targets.isEmpty) return;
    // Sidebar order, not the order the boxes were ticked in.
    await _pushRepos([
      for (final r in _workspaceRepos)
        if (targets.contains(r.path)) r.path,
    ]);
  }

  /// Push each repo in turn after a commit that reached several. One refusing
  /// does not stop the rest; the failures come back together.
  Future<void> _pushRepos(List<String> paths) => _network('推送', () async {
        var last = '';
        final failures = <String>[];
        for (final path in paths) {
          try {
            last = await pushWithRetry(
              Git(path),
              chooseStrategy: _askUpdateStrategy,
              onProgress: (m) {
                if (mounted) setState(() => _status = m);
              },
            );
          } on GitError catch (e) {
            failures.add(paths.length > 1
                ? '${_repoAt(path).name}：${e.message}'
                : e.message);
          }
        }
        if (failures.isNotEmpty) throw GitError(failures.join('；'));
        return last;
      });

  /// Right-click on 推送. `--force-with-lease`, so it still refuses to clobber
  /// commits this repo has never seen — but it rewrites the remote branch, so
  /// it is behind a right-click and marked dangerous rather than sitting next
  /// to the ordinary push.
  Future<void> _pushForce() => _network('强制推送', () => _git!.pushForce());

  /// Only asked when git config says nothing about `pull.rebase`. Cancelling
  /// aborts the push retry rather than picking a default — rebasing someone's
  /// commits because they dismissed a dialog is not a recoverable mistake.
  Future<UpdateStrategy?> _askUpdateStrategy() async {
    return showAppDialog<UpdateStrategy>(
      context,
      title: '远端有新提交',
      badge: DialogBadge.info,
      maxWidth: 460,
      body: const DialogText(
        '推送被拒绝：远端已经领先。要先用哪种方式更新本地分支？\n'
        'git 配置里没有 pull.rebase，所以这次由你决定。',
      ),
      actions: [
        DialogButton('取消推送', onTap: () => Navigator.of(context).pop()),
        DialogButton(
          '合并',
          onTap: () => Navigator.of(context).pop(UpdateStrategy.merge),
        ),
        DialogButton(
          '变基',
          kind: DialogButtonKind.primary,
          onTap: () => Navigator.of(context).pop(UpdateStrategy.rebase),
        ),
      ],
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
      if (mounted) _fail(e.message);
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
      if (mounted) _fail(e.message);
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
      if (mounted) _fail(e.message);
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
      if (mounted) _fail(e.message);
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
      if (mounted) _fail(e.message);
    }
  }

  /// A request that did not happen: status bar plus a box that stays until
  /// dismissed.
  Future<void> _notify(String message) {
    setState(() => _status = message);
    return showNotice(context, message);
  }

  /// Every caller is about to throw something away, hence the red badge and
  /// button; Enter does not press it.
  Future<bool> _confirm({required String title, required String body}) async {
    final ok = await showAppDialog<bool>(
      context,
      title: title,
      badge: DialogBadge.danger,
      body: DialogText(body),
      actions: [
        DialogButton('取消', onTap: () => Navigator.of(context).pop(false)),
        DialogButton(
          '继续',
          kind: DialogButtonKind.danger,
          onTap: () => Navigator.of(context).pop(true),
        ),
      ],
    );
    return ok ?? false;
  }

  Future<void> _applyPartial(String patch, bool reverse) async {
    final target = _target;
    if (target is! WorkingFileDiff) return;
    final git = Git(target.repo);
    try {
      await git.applyHunk(patch, reverse: reverse);
      setState(() => _status = reverse ? '已取消暂存所选行' : '已暂存所选行');
      await _refresh();
    } on GitError catch (e) {
      if (mounted) _fail(e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Theming.of(context);

    return CallbackShortcuts(
      // These stay live while the user is typing: a Flutter TextField gives
      // these keys no behaviour of its own, so there is nothing to yield to and no reason to
      // track focus. ⌘↵ inside the commit box commits, which is what it should
      // do there anyway.
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyO, meta: true): _pickRepo,
        const SingleActivator(LogicalKeyboardKey.comma, meta: true): () {
          setState(() => _settingsOpen = true);
        },
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): () {
          if (_git != null) _openCommitDialog();
        },
        const SingleActivator(LogicalKeyboardKey.keyR, meta: true): () {
          if (_git != null) _refresh();
        },
        const SingleActivator(LogicalKeyboardKey.keyT, meta: true): () {
          if (_git != null && !_netBusy) _fetch();
        },
        const SingleActivator(LogicalKeyboardKey.keyL, meta: true): () {
          if (_git != null && !_netBusy) _pull();
        },
        const SingleActivator(LogicalKeyboardKey.keyP, meta: true): () {
          if (_git != null && !_netBusy) _push();
        },
        const SingleActivator(LogicalKeyboardKey.keyN, meta: true): () {
          if (_git != null) _newBranch();
        },
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true): () {
          if (_git != null) {
            _stashAction('储藏改动', () => _git!.stashSave());
          }
        },
        const SingleActivator(LogicalKeyboardKey.escape): () {
          // Innermost first: the sheet the user is looking at closes, not
          // whatever happens to be listed first.
          if (_cloneOpen) {
            setState(() => _cloneOpen = false);
          } else if (_settingsOpen) {
            setState(() => _settingsOpen = false);
          } else if (_rebasePlan != null) {
            setState(() => _rebasePlan = null);
          } else if (_mergeFile != null) {
            setState(() => _mergeFile = null);
          } else if (_commitOpen) {
            _closeCommit();
          }
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
                if (_cloneOpen)
                  CloneSheet(
                    onClose: () => setState(() => _cloneOpen = false),
                    pickDirectory: () =>
                        getDirectoryPath(confirmButtonText: '选择'),
                    onCloned: (path) {
                      setState(() => _cloneOpen = false);
                      _openRepo(path);
                    },
                  ),
                if (_rebasePlan != null)
                  RebaseSheet(
                    plan: _rebasePlan!,
                    dirtyWorktree: _changes.isNotEmpty,
                    onClose: () => setState(() => _rebasePlan = null),
                    onStart: _startRebase,
                  ),
                if (_settingsOpen)
                  SettingsSheet(
                    git: _git,
                    prefs: widget.prefs,
                    ai: _ai,
                    onClose: () => setState(() => _settingsOpen = false),
                    onPreview: widget.onApplyLook,
                    onSaved: _onSettingsSaved,
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
                if (_commitOpen) _commitSheet(p),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _toolbar(Palette p) {
    final multi = _workspaceRepos.length > 1;
    // Left: where you are. Centre pill: which project, and the way to switch.
    // Right: the actions. 打开…/克隆… live in
    // the pill menu and 主题/差异视图 in 设置 → 外观, so neither is a button here.
    final where = _git == null
        ? '未打开仓库'
        : multi
            ? '$_repoPath   ·   $_branch   （工作区共 ${_workspaceRepos.length} 个仓库）'
            : '$_repoPath   ·   $_branch';

    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: p.bgAlt,
        border: Border(bottom: BorderSide(color: p.border)),
      ),
      // The pill is centred on the window,
      // not placed in the row, so the buttons stay flush right. The path stops
      // 200px short of centre (half the pill's cap plus a gap) so a long one
      // never slides under it.
      child: LayoutBuilder(
        builder: (context, box) => Stack(
          alignment: Alignment.center,
          children: [
            Row(
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(
                      maxWidth:
                          (box.maxWidth / 2 - 200).clamp(0, box.maxWidth)),
                  child: Text(
                    where,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ui.copyWith(color: p.textDim),
                  ),
                ),
                _trackingChip(p),
                const Spacer(),
                _ToolButton(
                    label: '提交',
                    enabled: _git != null,
                    tooltip: '提交 (⌘↵)',
                    onTap: _openCommitDialog),
                // Disabled while any network action runs: they all move the same refs,
                // and a fetch racing a push fails in ways that are nobody's fault.
                _ToolButton(
                  label: '推送',
                  enabled: _git != null && !_netBusy,
                  onTap: _push,
                  tooltip: _tracking == null
                      ? '推送 (⌘P) — 右键可强制推送'
                      : '${pushTargetText(_tracking!)} — 右键可强制推送',
                  onSecondaryTapAt: _git == null
                      ? null
                      : (pos) => showRepoMenu(
                            context: context,
                            position: pos,
                            items: [
                              MenuAction(
                                  '强制推送 (--force-with-lease)', _pushForce,
                                  danger: true),
                            ],
                          ),
                ),
                _ToolButton(
                    label: '拉取',
                    enabled: _git != null && !_netBusy,
                    tooltip: '拉取 (⌘L)',
                    onTap: _pull),
                _ToolButton(
                    label: '抓取',
                    enabled: _git != null && !_netBusy,
                    tooltip: '抓取 (⌘T)',
                    onTap: _fetch),
                _ToolButton(
                  label: '设置',
                  enabled: true,
                  tooltip: '设置 (⌘,)',
                  onTap: () => setState(() => _settingsOpen = true),
                ),
                const SizedBox(width: 6),
                _OpenProjectButton(
                  palette: p,
                  enabled: _git != null,
                  editor: _projectEditor,
                  icon: _editorIcons[_projectEditor],
                  onOpen: () => _openProject(_projectEditor),
                  onPickAt: _showEditorMenu,
                ),
              ],
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: _ProjectPill(
                label: _git == null
                    ? '未打开仓库'
                    : multi
                        ? '${_projectName(_workspaceRoot)} / $_repoName'
                        : _repoName,
                tooltip: _git == null ? '打开一个仓库' : where,
                palette: p,
                onTapAt: _showProjectMenu,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _projectName(String path) {
    final parts = path.split('/').where((s) => s.isNotEmpty);
    return parts.isEmpty ? path : parts.last;
  }

  /// `~` for the home directory, the way the recent list prints paths.
  String _prettyPath(String path) {
    final home = Platform.environment['HOME'] ?? '';
    return home.isNotEmpty && path.startsWith('$home/')
        ? '~${path.substring(home.length)}'
        : path;
  }

  /// Which editor opens the current project: its own choice if it has one,
  /// otherwise the default. Empty means the system handler.
  String get _projectEditor =>
      widget.prefs.projectEditors[_repoPath] ?? widget.prefs.editor;

  void _showProjectMenu(Offset pos) {
    final recent = widget.prefs.recentRepos;
    showRepoMenu(
      context: context,
      position: pos,
      items: [
        MenuAction('打开…', _pickRepo),
        MenuAction('克隆仓库…', () => setState(() => _cloneOpen = true)),
        if (recent.isNotEmpty) ...[
          const MenuAction.header('最近的项目'),
          for (final path in recent)
            MenuAction(
              _projectName(path),
              () => _openRepo(path),
              sublabel: _prettyPath(path),
              current: path == _workspaceRoot,
            ),
        ],
      ],
    );
  }

  void _showEditorMenu(Offset pos) {
    final editors = widget.prefs.editors;
    showRepoMenu(
      context: context,
      position: pos,
      items: [
        if (editors.isEmpty)
          MenuAction('去设置里添加编辑器…', () => setState(() => _settingsOpen = true))
        else ...[
          MenuAction('系统默认', () => _setProjectEditor('')),
          for (final e in editors)
            MenuAction(e, () => _setProjectEditor(e),
                enabled: e != _projectEditor),
        ],
      ],
    );
  }

  Future<void> _setProjectEditor(String editor) async {
    final map = {...widget.prefs.projectEditors};
    // An empty choice is stored, not dropped: "this project uses the system
    // handler" has to survive a later change of the default editor.
    map[_repoPath] = editor;
    await widget.prefs.setProjectEditors(map);
    if (mounted) setState(() {});
  }

  Future<void> _openProject(String editor) async {
    try {
      await _git!.openProject(editor: editor);
    } on GitError catch (e) {
      if (mounted) _fail(e.message);
    }
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
          // Only with siblings: a 仓库 list holding one entry is a heading that
          // tells you nothing.
          if (_workspaceRepos.length > 1) ...[
            _SectionHead(label: '仓库', palette: p),
            for (final r in _workspaceRepos)
              // Not a ContextMenuRegion: the menu lists the repo's branches,
              // which have to be read before it can open.
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onSecondaryTapUp: (d) =>
                    _showRepoBranchMenu(r, d.globalPosition),
                child: _SidebarRow(
                  label: r.name,
                  badge: r.branch.isEmpty ? null : r.branch,
                  palette: p,
                  bold: r.path == _repoPath,
                  dirty: _changesOf(r.path).isNotEmpty,
                  ahead: _trackingOf(r.path)?.ahead.toInt() ?? 0,
                  tooltip: '${r.path}\n右键切换分支',
                  onTap: () => _openRepoCommit(r),
                ),
              ),
          ],
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
                dirty: b.isCurrent && _changes.isNotEmpty,
                ahead: b.isCurrent ? (_tracking?.ahead.toInt() ?? 0) : 0,
                // Left click checks out; the menu holds
                // everything else.
                onTap: b.isCurrent
                    ? null
                    : () => _branchAction(
                          '已切换到 ${b.name}',
                          () => _git!.checkout(b.name),
                        ),
              ),
            ),
          _SectionHead(
            label: '远端',
            palette: p,
            action:
                _git == null ? null : _SectionAction('＋', '添加远端', _addRemote),
          ),
          for (final r in _remotes)
            ContextMenuRegion(
              items: () => [
                MenuAction(
                  '移除远端',
                  () => _stashAction(
                    '移除远端 ${r.name}',
                    () => _git!.removeRemote(r.name),
                    confirm: '移除远端「${r.name}」（${r.url}）？'
                        '本地分支和提交不受影响。',
                  ),
                  danger: true,
                ),
              ],
              child: _SidebarRow(
                label: r.name,
                palette: p,
                // The URL is what tells two remotes apart; the name alone does
                // not say whether origin points where you think it does.
                tooltip: r.url,
              ),
            ),
          if (_remoteBranches.isNotEmpty) ...[
            _SectionHead(label: '远端分支', palette: p),
            for (final rb in _remoteBranches)
              ContextMenuRegion(
                items: () => [
                  MenuAction(
                    '删除远端分支',
                    () => _deleteRemoteBranch(rb),
                    danger: true,
                  ),
                ],
                child: _SidebarRow(
                  label: rb,
                  palette: p,
                  // git DWIMs origin/foo into a local tracking branch.
                  onTap: () => _checkoutRef(rb),
                ),
              ),
          ],
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
                MenuAction('推送标签到远端',
                    () => _network('推送标签 $tag', () => _git!.pushTag(tag))),
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
              child: _SidebarRow(
                label: tag,
                palette: p,
                // Checking out a tag detaches HEAD, which git handles and the
                // banner will report.
                onTap: () => _checkoutRef(tag),
              ),
            ),
          _SectionHead(
            label: '储藏',
            palette: p,
            action: _git == null
                ? null
                : _SectionAction('⤓', '储藏当前改动', () {
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
        ],
      ),
    );
  }

  Widget _commitSheet(Palette p, {bool docked = false}) => CommitSheet(
        groups: _commitGroups(),
        active: _activeRepo,
        diffPane: _diffPane(p),
        selected: switch (_target) {
          WorkingFileDiff(:final repo, :final path, :final staged) => (
              repo: repo,
              path: path,
              staged: staged
            ),
          _ => null,
        },
        menuFor: _fileMenu,
        onDiscard: _discardFile,
        onClose: _closeCommit,
        onChanged: _refresh,
        onPickFile: _showFile,
        onCommitAndPush: _pushRepos,
        onCreatePatch: _createWorkingPatch,
        ai: _ai,
        prefs: widget.prefs,
        docked: docked,
      );

  Widget _mainRight(Palette p) {
    // Nothing selected means no lower half at
    // all, and the history takes the window. The dialog, when open, holds the
    // diff pane, so the main window has nothing to show below either.
    final docked = _commitDocked && !_commitOpen;
    final lowerOpen = docked ||
        (!_commitOpen && (_target is! NoDiff || _selectedCommit != null));
    final history = Column(
      children: [
        _historyHead(p),
        Expanded(
          child: _searchResults != null
              ? _searchList(p)
              : HistoryView(
                  layout: _graph,
                  selected: _selectedCommit?.id,
                  onSelect: _selectCommit,
                  controller: _historyScroll,
                  menuFor: _commitMenu,
                ),
        ),
      ],
    );
    return Column(
      children: [
        if (lowerOpen)
          SizedBox(height: _historyHeight, child: history)
        else
          Expanded(child: history),
        // Between history and diff: the user
        // sees it right after the operation that stopped.
        if (_conflicts.isNotEmpty || _op != 'none') _conflictBanner(p),
        if (lowerOpen) ...[
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
          // One diff pane, one place:
          // building it twice would mount its block GlobalKeys twice.
          Expanded(
              child: docked ? _commitSheet(p, docked: true) : _diffPane(p)),
        ],
      ],
    );
  }

  /// The commit's files as a folder tree. Read-only, so single-child folder
  /// chains collapse into one row — the commit sheet keeps every level only
  /// because each one carries a checkbox.
  List<Widget> _commitFileRows(Palette p) {
    final byPath = {for (final f in _commitFiles) f.path: f};
    final root =
        pathTree([for (final f in _commitFiles) TreeFile(f.path, f.status)]);
    final rows = <Widget>[];
    void addNode(TreeNode node, String parent, int depth) {
      for (final dir in node.dirs) {
        final path = parent.isEmpty ? dir.name : '$parent/${dir.name}';
        final open = !_collapsedCommitDirs.contains(path);
        rows.add(_SidebarRow(
          label: dir.name,
          palette: p,
          indent: depth * 12,
          icon: Row(mainAxisSize: MainAxisSize.min, children: [
            Disclosure(open: open, color: p.textDim),
            const SizedBox(width: 4),
            FolderIcon(color: p.textDim),
          ]),
          tooltip: path,
          onTap: () => setState(() {
            if (!_collapsedCommitDirs.remove(path)) {
              _collapsedCommitDirs.add(path);
            }
          }),
        ));
        if (open) addNode(dir, path, depth + 1);
      }
      for (final leaf in node.files) {
        final f = byPath[leaf.path]!;
        rows.add(ContextMenuRegion(
          items: () => _commitFileMenu(f.path),
          child: _SidebarRow(
            label: f.path.split('/').last,
            palette: p,
            // Past the disclosure triangle's width, so a file lines up with
            // its folder's name rather than with the folder's arrow.
            indent: depth * 12 + (depth > 0 ? 12 : 0),
            icon: StatusBadge(status: f.status),
            tooltip: f.path,
            active: switch (_target) {
              CommitFileDiff(:final path) => path == f.path,
              _ => false,
            },
            onTap: () async {
              setState(
                  () => _target = CommitFileDiff(_selectedCommit!.id, f.path));
              await _reloadDiff();
            },
          ),
        ));
      }
    }

    addNode(root, '', 0);
    return rows;
  }

  Widget _diffPane(Palette p) {
    final title = switch (_target) {
      NoDiff() => '差异',
      WorkingFileDiff(:final repo, :final path, :final staged) =>
        '${_workspaceRepos.length > 1 ? '${_repoAt(repo).name} / ' : ''}'
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
        _PaneHead(
          title: title,
          palette: p,
          onBack: _paneBack == null
              ? null
              : () async {
                  setState(() {
                    _target = _paneBack!;
                    _paneBack = null;
                  });
                  await _reloadDiff();
                },
          actions: _target is NoDiff
              ? const []
              : [
                  (
                    label: '\u2191',
                    tooltip: '上一处改动（到头则跳上一个文件）',
                    onTap: () => _navigateChange(-1),
                  ),
                  (
                    label: '\u2193',
                    tooltip: '下一处改动（到底则跳下一个文件）',
                    onTap: () => _navigateChange(1),
                  ),
                  (
                    label: _mode == DiffMode.split ? '并排' : '统一',
                    tooltip: '切换并排 / 统一视图',
                    onTap: () => setState(() {
                          _mode = _mode == DiffMode.split
                              ? DiffMode.unified
                              : DiffMode.split;
                          // Split and unified pair lines differently, so the block
                          // positions move with the view.
                          _recomputeBlocks();
                        }),
                  ),
                  (
                    label: '✕',
                    tooltip: '关闭差异区',
                    onTap: () => setState(() {
                          _target = const NoDiff();
                          _paneBack = null;
                          _selectedCommit = null;
                          _commitFiles = const [];
                        }),
                  ),
                ],
        ),
        Expanded(
          child: Row(
            // Stretch, or a short diff shrinks to its content and floats in the
            // middle of the pane instead of starting at the top.
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_selectedCommit != null && _target is CommitFileDiff)
                SizedBox(
                  width: 200,
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border(right: BorderSide(color: p.border)),
                    ),
                    child: ListView(children: _commitFileRows(p)),
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
                  _ => _hunks.isEmpty && _plainDiff.trim().isNotEmpty
                      ? _PlainDiff(text: _plainDiff, palette: p)
                      : DiffPane(
                          blockKeys: _blockKeys,
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

  /// A bold 历史 and two search boxes sharing
  /// the width, filled rather than outlined.
  Widget _historyHead(Palette p) => Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: p.bg,
          border: Border(bottom: BorderSide(color: p.border)),
        ),
        child: Row(
          children: [
            Text('历史',
                style: ui.copyWith(
                    color: p.textDim,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5)),
            const SizedBox(width: 8),
            Expanded(child: _searchField(p, _searchText, '搜索提交说明')),
            const SizedBox(width: 8),
            Expanded(child: _searchField(p, _searchAuthor, '作者')),
            if (_searchResults != null) ...[
              const SizedBox(width: 8),
              Text('${_searchResults!.length} 条结果',
                  style: ui.copyWith(color: p.textDim, fontSize: 11)),
            ],
          ],
        ),
      );

  Widget _searchField(
    Palette p,
    TextEditingController controller,
    String hint,
  ) {
    OutlineInputBorder border(Color color) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: BorderSide(color: color),
        );
    return TextField(
      controller: controller,
      style: ui.copyWith(color: p.text, fontSize: 11),
      cursorColor: p.accent,
      // Searching runs git log, so it waits for Enter rather than firing on
      // every keystroke the way a client-side filter could.
      onSubmitted: (_) => _runSearch(),
      decoration: InputDecoration(
        isDense: true,
        // 22px box: 11px × 1.3 line + 8px each side, less
        // the 8px desktop's compact visual density takes off. `constraints`
        // does not work here — it grows the widget but not the painted box.
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

  /// Search results are a flat list: searchCommits has no parent links, so
  /// there are no lanes to draw and pretending otherwise would draw a wrong
  /// graph rather than no graph.
  Widget _searchList(Palette p) => ListView.builder(
        itemExtent: 26,
        itemCount: _searchResults!.length,
        itemBuilder: (context, i) {
          final c = _searchResults![i];
          return _SidebarRow(
            label: c.summary,
            palette: p,
            leading: c.id.substring(0, 7),
            leadingColor: p.accent,
            active: _selectedCommit?.id == c.id,
            onTap: () => _selectCommit(GraphCommit(
              id: c.id,
              summary: c.summary,
              author: c.author,
              time: c.time,
              parents: const [],
              refs: const [],
            )),
          );
        },
      );

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
      child: _statusDetail == null
          ? Text(_status,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ui.copyWith(color: p.textDim, fontSize: 11))
          : MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: _showStatusDetail,
                child: Row(
                  children: [
                    Container(
                      width: 13,
                      height: 13,
                      alignment: Alignment.center,
                      decoration:
                          BoxDecoration(color: p.red, shape: BoxShape.circle),
                      child: const Text('!',
                          style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFFFFFFFF),
                              height: 1)),
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(_status,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ui.copyWith(color: p.red, fontSize: 11)),
                    ),
                    const SizedBox(width: 8),
                    Text('查看详情',
                        style: ui.copyWith(color: p.accent, fontSize: 11)),
                  ],
                ),
              ),
            ),
    );
  }

  Future<void> _showStatusDetail() {
    final detail = _statusDetail!;
    return showAppDialog<void>(
      context,
      title: '操作失败',
      badge: DialogBadge.danger,
      maxWidth: 640,
      body: SelectableText(
        detail,
        style: ui.copyWith(
            color: Theming.of(context).textDim, fontSize: 12, height: 1.5),
      ),
      actions: [
        DialogButton('复制', onTap: () {
          Clipboard.setData(ClipboardData(text: detail));
          Navigator.of(context).pop();
        }),
        DialogButton(
          '确定',
          kind: DialogButtonKind.primary,
          autofocus: true,
          onTap: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}

/// A draggable divider: cursor, hit area and drag in one widget.
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
/// The toolbar's repo label when the workspace holds more than one repository.
/// The centre pill: which project is open, and the menu that switches it.
///
/// It carries the *project* name — the workspace root for a multi-repo
/// workspace — while the left label carries the full path. The pill is for
/// recognising and switching, the label is for
/// knowing exactly where you are.
class _ProjectPill extends StatefulWidget {
  const _ProjectPill({
    required this.label,
    required this.tooltip,
    required this.palette,
    required this.onTapAt,
  });

  final String label;
  final String tooltip;
  final Palette palette;
  final void Function(Offset position) onTapAt;

  @override
  State<_ProjectPill> createState() => _ProjectPillState();
}

class _ProjectPillState extends State<_ProjectPill> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: () => widget.onTapAt(menuAnchorBelow(context)),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 260),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: _hover ? p.bgHover : p.bgElev,
              border: Border.all(color: p.border),
              borderRadius: BorderRadius.circular(5),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ui.copyWith(color: p.text)),
                ),
                const SizedBox(width: 6),
                Chevron(color: p.textDim),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 打开项目: one button that opens, one arrow that picks which editor opens it.
///
/// A split button rather than a right-click, because "which editor" is a choice
/// people change often enough to deserve a visible control, with the chosen
/// editor's own icon on the main half.
class _OpenProjectButton extends StatefulWidget {
  const _OpenProjectButton({
    required this.palette,
    required this.enabled,
    required this.editor,
    required this.icon,
    required this.onOpen,
    required this.onPickAt,
  });

  final Palette palette;
  final bool enabled;
  final String editor;
  final Uint8List? icon;
  final VoidCallback onOpen;
  final void Function(Offset position) onPickAt;

  @override
  State<_OpenProjectButton> createState() => _OpenProjectButtonState();
}

class _OpenProjectButtonState extends State<_OpenProjectButton> {
  bool _hoverMain = false;
  bool _hoverArrow = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final on = widget.enabled;
    final icon = widget.icon;

    return Tooltip(
      message:
          widget.editor.isEmpty ? '用系统默认程序打开当前项目' : '用 ${widget.editor} 打开当前项目',
      waitDuration: const Duration(milliseconds: 600),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: p.border),
          borderRadius: BorderRadius.circular(5),
        ),
        clipBehavior: Clip.antiAlias,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            MouseRegion(
              cursor: on ? SystemMouseCursors.click : SystemMouseCursors.basic,
              onEnter: (_) => setState(() => _hoverMain = true),
              onExit: (_) => setState(() => _hoverMain = false),
              child: GestureDetector(
                onTap: on ? widget.onOpen : null,
                child: Container(
                  height: 24,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  color: on && _hoverMain ? p.bgHover : p.bgElev,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (icon != null) ...[
                        SizedBox(
                          width: 14,
                          height: 14,
                          child: Image.memory(icon),
                        ),
                        const SizedBox(width: 5),
                      ],
                      Text('打开项目',
                          style: ui.copyWith(color: on ? p.text : p.textDim)),
                    ],
                  ),
                ),
              ),
            ),
            Container(width: 1, height: 24, color: p.border),
            MouseRegion(
              cursor: on ? SystemMouseCursors.click : SystemMouseCursors.basic,
              onEnter: (_) => setState(() => _hoverArrow = true),
              onExit: (_) => setState(() => _hoverArrow = false),
              child: GestureDetector(
                onTapUp: on ? (d) => widget.onPickAt(d.globalPosition) : null,
                child: Container(
                  height: 24,
                  width: 20,
                  alignment: Alignment.center,
                  color: on && _hoverArrow ? p.bgHover : p.bgElev,
                  child: Chevron(color: on ? p.text : p.textDim),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A file with no hunks: shown verbatim, with no per-line staging because
/// there is nothing for `git apply` to act on.
class _PlainDiff extends StatelessWidget {
  const _PlainDiff({required this.text, required this.palette});
  final String text;
  final Palette palette;

  @override
  Widget build(BuildContext context) => Container(
        color: palette.diffBg,
        child: SelectionArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(8),
            child: SizedBox(
              width: double.infinity,
              child: Text(text, style: mono.copyWith(color: palette.text)),
            ),
          ),
        ),
      );
}

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
      padding: const EdgeInsets.fromLTRB(10, 10, 6, 6),
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

typedef PaneAction = ({String label, String tooltip, VoidCallback onTap});

class _PaneHead extends StatelessWidget {
  const _PaneHead({
    required this.title,
    required this.palette,
    this.onBack,
    this.actions = const [],
  });

  final String title;
  final Palette palette;

  /// Shown only when there is somewhere to go back to — an always-visible
  /// arrow that does nothing is worse than no arrow.
  final VoidCallback? onBack;
  final List<PaneAction> actions;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 26,
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: palette.bgAlt,
        border: Border(bottom: BorderSide(color: palette.border)),
      ),
      child: Row(
        children: [
          if (onBack != null)
            _PaneHeadButton(
              label: '\u2190',
              tooltip: '返回上一视图',
              onTap: onBack,
              palette: palette,
            ),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ui.copyWith(color: palette.textDim, fontSize: 11),
            ),
          ),
          for (final a in actions)
            _PaneHeadButton(
              label: a.label,
              tooltip: a.tooltip,
              onTap: a.onTap,
              palette: palette,
            ),
        ],
      ),
    );
  }
}

class _PaneHeadButton extends StatefulWidget {
  const _PaneHeadButton({
    required this.label,
    required this.tooltip,
    required this.onTap,
    required this.palette,
  });

  final String label;
  final String tooltip;
  final VoidCallback? onTap;
  final Palette palette;

  @override
  State<_PaneHeadButton> createState() => _PaneHeadButtonState();
}

class _PaneHeadButtonState extends State<_PaneHeadButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final on = widget.onTap != null;
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        cursor: on ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 2),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: on && _hover ? p.bgHover : null,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              widget.label,
              style:
                  ui.copyWith(color: on ? p.textDim : p.border, fontSize: 11),
            ),
          ),
        ),
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
    this.tooltip,
    this.indent = 0,
    this.icon,
    this.badge,
    this.bold = false,
    this.dirty = false,
    this.ahead = 0,
  });

  final String label;

  /// Green ↑N after the label: commits waiting to be pushed. Zero shows nothing.
  final int ahead;

  /// A yellow * after the label: the repo has uncommitted changes.
  final bool dirty;

  /// Small bordered tag after the label — the repo list's branch name.
  final String? badge;

  /// Marks the current entry by weight instead of the [active] fill.
  final bool bold;
  final Palette palette;

  /// Extra left padding, for tree rows.
  final double indent;

  /// A drawn lead-in (status badge, folder) — [leading] is the text one.
  final Widget? icon;
  final String? leading;
  final Color? leadingColor;
  final bool active;
  final VoidCallback? onTap;

  /// Like [onTap], but handed the click position — for rows whose action is to
  /// open a menu, which has to appear where the pointer is.
  final void Function(Offset position)? onTapAt;

  final String? tooltip;

  @override
  State<_SidebarRow> createState() => _SidebarRowState();
}

class _SidebarRowState extends State<_SidebarRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final row = MouseRegion(
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
            : (_) => widget.onTapAt!(menuAnchorBelow(context)),
        child: Container(
          height: 26,
          padding: EdgeInsets.only(left: 10 + widget.indent, right: 10),
          color: widget.active
              ? p.bgSel
              : _hover
                  ? p.bgHover
                  : null,
          child: Row(
            children: [
              if (widget.icon != null) ...[
                widget.icon!,
                const SizedBox(width: 6),
              ],
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
              Flexible(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ui.copyWith(
                    color: p.text,
                    fontWeight: widget.bold ? FontWeight.w600 : null,
                  ),
                ),
              ),
              if (widget.dirty)
                Tooltip(
                  message: '有未提交的改动',
                  child: Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Text('*',
                        style: ui.copyWith(
                            color: p.yellow, fontWeight: FontWeight.w700)),
                  ),
                ),
              if (widget.ahead > 0)
                Tooltip(
                  message: '${widget.ahead} 个提交待推送',
                  child: Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Text('↑${widget.ahead}',
                        style: ui.copyWith(color: p.green, fontSize: 11)),
                  ),
                ),
              if (widget.badge != null) ...[
                const SizedBox(width: 6),
                Flexible(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5),
                    decoration: BoxDecoration(
                      color: p.bgElev,
                      border: Border.all(color: p.border),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Text(
                      widget.badge!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ui.copyWith(fontSize: 10, color: p.textDim),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );

    return widget.tooltip == null
        ? row
        : Tooltip(message: widget.tooltip!, child: row);
  }
}
