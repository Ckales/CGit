import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'commit_sheet.dart';
import 'diff_view.dart';
import 'git.dart';
import 'git_text.dart';
import 'history_view.dart';
import 'theme.dart';

Future<void> main(List<String> args) async {
  // The Rust side lives in cgit_rust.framework; nothing below can call it until
  // this resolves, so it blocks rather than racing the first repo load.
  WidgetsFlutterBinding.ensureInitialized();
  await initGitBridge();

  // The repo comes from argv so the app has something to show without a file
  // picker. Opening a folder needs the file_selector plugin — see README.
  runApp(CGitApp(startPath: args.isEmpty ? defaultRepoPath : args.first));
}

class CGitApp extends StatefulWidget {
  const CGitApp({super.key, required this.startPath});
  final String startPath;

  @override
  State<CGitApp> createState() => _CGitAppState();
}

class _CGitAppState extends State<CGitApp> {
  Palette _palette = Palette.dark;

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
            onToggleTheme: () => setState(
              () => _palette =
                  _palette == Palette.dark ? Palette.light : Palette.dark,
            ),
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

class RepoScreen extends StatefulWidget {
  const RepoScreen(
      {super.key, required this.startPath, required this.onToggleTheme});
  final String startPath;
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

  DiffMode _mode = DiffMode.split;
  bool _commitOpen = false;

  double _sidebarWidth = 220;
  double _historyHeight = 260;

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
      ]);
      if (!mounted) return;
      setState(() {
        _branch = results[0] as String;
        _branches = results[1] as List<BranchInfo>;
        _tags = results[2] as List<String>;
        _remotes = results[3] as List<RemoteInfo>;
        _changes = results[4] as List<FileStatus>;
        _graph = layoutGraph(results[5] as List<GraphCommit>);
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
      };
      if (mounted) setState(() => _hunks = hunks.hunks);
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
                            onReset: () => setState(() => _sidebarWidth = 220),
                          ),
                          Expanded(child: _mainRight(p)),
                        ],
                      ),
                    ),
                    _statusBar(p),
                  ],
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
          const Spacer(),
          _ToolButton(
              label: '提交',
              enabled: _git != null,
              onTap: () {
                setState(() => _commitOpen = true);
              }),
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
          _SectionHead(label: '分支', palette: p),
          for (final b in _branches)
            _SidebarRow(
              label: b.name,
              palette: p,
              active: b.isCurrent,
              leading: b.isCurrent ? '●' : null,
            ),
          _SectionHead(label: '远端', palette: p),
          for (final r in _remotes) _SidebarRow(label: r.name, palette: p),
          _SectionHead(label: '标签', palette: p),
          for (final t in _tags) _SidebarRow(label: t, palette: p),
          _SectionHead(label: '改动', palette: p),
          for (final f in _changes)
            _SidebarRow(
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
                ),
              ),
            ],
          ),
        ),
        _Splitter(
          axis: Axis.vertical,
          palette: p,
          onDrag: (d) => setState(
              () => _historyHeight = (_historyHeight + d).clamp(80.0, 700.0)),
          onReset: () => setState(() => _historyHeight = 260),
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
                child: DiffPane(
                  hunks: _hunks,
                  mode: _mode,
                  staged: staged,
                  onApply: interactive ? _applyPartial : null,
                ),
              ),
            ],
          ),
        ),
      ],
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
  });

  final Axis axis;
  final Palette palette;
  final void Function(double delta) onDrag;
  final VoidCallback onReset;

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
  const _ToolButton(
      {required this.label, required this.enabled, required this.onTap});
  final String label;
  final bool enabled;
  final VoidCallback onTap;

  @override
  State<_ToolButton> createState() => _ToolButtonState();
}

class _ToolButtonState extends State<_ToolButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = Theming.of(context);
    return MouseRegion(
      cursor:
          widget.enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.enabled ? widget.onTap : null,
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
  }
}

class _SectionHead extends StatelessWidget {
  const _SectionHead({required this.label, required this.palette});
  final String label;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 4),
      child: Text(
        label,
        style: ui.copyWith(
            color: palette.textDim, fontSize: 11, letterSpacing: 0.4),
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
  });

  final String label;
  final Palette palette;
  final String? leading;
  final Color? leadingColor;
  final bool active;
  final VoidCallback? onTap;

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
