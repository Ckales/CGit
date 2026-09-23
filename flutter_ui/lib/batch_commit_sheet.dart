import 'package:flutter/material.dart';

import 'commit_sheet.dart';
import 'git.dart';
import 'theme.dart';

/// One message, committed in several repos of the workspace.
///
/// Git has no cross-repo commit, so this runs `git commit` once per picked repo,
/// in order. It is not atomic: a hook refusing one repo leaves the others
/// committed, and the sheet stays open listing which failed and why.
/// Amend, author and push are left to the single-repo sheet — each repo has its
/// own HEAD, identity and upstream, and one setting for all of them would be a
/// guess.
class BatchCommitSheet extends StatefulWidget {
  const BatchCommitSheet({
    super.key,
    required this.repos,
    required this.onClose,
    required this.onChanged,
    required this.onDone,
    this.gitFor = Git.new,
  });

  final List<RepoRef> repos;
  final VoidCallback onClose;

  /// Runs after a commit round that left some repo failed — the main window
  /// refreshes, the sheet stays open.
  final Future<void> Function() onChanged;

  /// Every picked repo committed; `summary` goes to the status bar.
  final void Function(String summary) onDone;

  /// Tests hand in fakes; the app uses the real bridge.
  final Git Function(String path) gitFor;

  @override
  State<BatchCommitSheet> createState() => _BatchCommitSheetState();
}

class _BatchCommitSheetState extends State<BatchCommitSheet> {
  final _message = TextEditingController();

  /// Per repo path. A partly staged file counts on both sides, as git lists it.
  final _counts = <String, ({int staged, int unstaged})>{};
  final _loadErrors = <String, String>{};
  final _picked = <String>{};

  /// Per repo path, the last round's failure message.
  var _failures = <String, String>{};

  bool _stageAll = false;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load(pickChanged: true);
  }

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  Future<void> _load({bool pickChanged = false}) async {
    for (final repo in widget.repos) {
      try {
        final changes = await widget.gitFor(repo.path).status();
        var staged = 0;
        for (final f in changes) {
          if (f.staged) staged++;
        }
        _counts[repo.path] = (staged: staged, unstaged: changes.length - staged);
        _loadErrors.remove(repo.path);
        if (pickChanged && changes.isNotEmpty) _picked.add(repo.path);
      } on GitError catch (e) {
        _counts.remove(repo.path);
        _loadErrors[repo.path] = e.message;
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  /// Whether committing here would record anything: something staged, or
  /// something the 暂存全部 option is about to stage.
  bool _committable(String path) {
    final c = _counts[path];
    if (c == null) return false;
    return c.staged > 0 || (_stageAll && c.unstaged > 0);
  }

  List<RepoRef> get _targets => [
        for (final r in widget.repos)
          if (_picked.contains(r.path) && _committable(r.path)) r,
      ];

  Future<void> _commit() async {
    final text = _message.text.trim();
    if (text.isEmpty) {
      setState(() => _error = '提交说明不能为空');
      return;
    }
    final targets = _targets;
    if (targets.isEmpty) {
      setState(() => _error = '没有选中可提交的仓库');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
      _failures = {};
    });
    final failures = <String, String>{};
    for (final repo in targets) {
      final git = widget.gitFor(repo.path);
      try {
        if (_stageAll && _counts[repo.path]!.unstaged > 0) await git.stageAll();
        await git.commit(text);
      } on GitError catch (e) {
        failures[repo.path] = e.message;
      }
    }

    if (failures.isEmpty) {
      widget.onDone('已在 ${targets.length} 个仓库提交');
      return;
    }
    await widget.onChanged();
    if (!mounted) return;
    final committed = targets.length - failures.length;
    // Committed repos are unticked so a retry only reaches the failed ones.
    for (final repo in targets) {
      if (!failures.containsKey(repo.path)) _picked.remove(repo.path);
    }
    setState(() {
      _failures = failures;
      _busy = false;
      _error = '${failures.length} 个仓库提交失败，$committed 个已提交';
    });
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final p = Theming.of(context);
    final ready = !_busy && !_loading && _targets.isNotEmpty;

    return Positioned.fill(
      child: ColoredBox(
        color: const Color(0x99000000),
        child: Center(
          child: Container(
            width: 560,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: p.bgAlt,
              border: Border.all(color: p.border),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Text('批量提交',
                        style: ui.copyWith(
                            color: p.text, fontWeight: FontWeight.w600)),
                    const Spacer(),
                    MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        onTap: _busy ? null : widget.onClose,
                        child: Text('✕', style: ui.copyWith(color: p.textDim)),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 320),
                  child: _loading
                      ? Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text('读取各仓库改动…',
                              style: ui.copyWith(color: p.textDim)),
                        )
                      : ListView(
                          shrinkWrap: true,
                          children: [
                            for (final r in widget.repos) _repoRow(p, r),
                          ],
                        ),
                ),
                const SizedBox(height: 10),
                MessageBox(controller: _message),
                const SizedBox(height: 8),
                CheckLabel(
                  label: '提交前暂存全部改动（含未跟踪文件）',
                  tooltip: '关闭时只提交各仓库已暂存的改动',
                  value: _stageAll,
                  onChanged: _busy ? null : (v) => setState(() => _stageAll = v),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(_error!,
                      style: ui.copyWith(color: p.red, fontSize: 12)),
                ],
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    _button(p, '取消', _busy ? null : widget.onClose),
                    const SizedBox(width: 6),
                    _button(
                      p,
                      _busy ? '提交中…' : '提交 ${_targets.length} 个仓库',
                      ready ? _commit : null,
                      primary: true,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _repoRow(Palette p, RepoRef repo) {
    final counts = _counts[repo.path];
    final failure = _failures[repo.path];
    final loadError = _loadErrors[repo.path];
    final committable = _committable(repo.path);

    final String detail;
    if (loadError != null) {
      detail = loadError;
    } else if (counts!.staged == 0 && counts.unstaged == 0) {
      detail = '没有改动';
    } else {
      detail = '${counts.staged} 已暂存 · ${counts.unstaged} 未暂存';
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CheckLabel(
                label: repo.name,
                tooltip: repo.path,
                value: committable && _picked.contains(repo.path),
                onChanged: _busy || !committable
                    ? null
                    : (v) => setState(() {
                          if (v) {
                            _picked.add(repo.path);
                          } else {
                            _picked.remove(repo.path);
                          }
                        }),
              ),
              if (repo.branch.isNotEmpty) ...[
                const SizedBox(width: 8),
                Text(repo.branch,
                    style: ui.copyWith(color: p.accent, fontSize: 11)),
              ],
              const SizedBox(width: 12),
              Expanded(
                child: Text(detail,
                    textAlign: TextAlign.right,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ui.copyWith(
                        color: loadError != null ? p.red : p.textDim,
                        fontSize: 11)),
              ),
            ],
          ),
          if (failure != null)
            Padding(
              padding: const EdgeInsets.only(left: 22, top: 2),
              child: Text(failure,
                  style: mono.copyWith(color: p.red, fontSize: 11)),
            ),
        ],
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
