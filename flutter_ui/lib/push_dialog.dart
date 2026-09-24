import 'package:flutter/material.dart';

import 'commit_sheet.dart';
import 'git.dart';
import 'git_text.dart';
import 'network_ops.dart';
import 'theme.dart';

/// One workspace repo and where its HEAD stands. A null [tracking] means it
/// could not be read; that repo is listed but never pre-checked.
typedef PushRow = ({RepoRef repo, Tracking? tracking});

/// Whether a repo has something to push, as IDEA pre-checks it: commits ahead
/// of the upstream, or a branch the remote does not have yet.
bool hasPushWork(Tracking? t) =>
    t != null &&
    t.branch != null &&
    (t.upstream == null || t.ahead > BigInt.zero);

/// The workspace push dialog's body: one row per repo with where it lands, and
/// the files the focused repo's push carries. [picked] holds the checked repo
/// paths, so the dialog's 推送 button can read it.
class PushDialogBody extends StatefulWidget {
  const PushDialogBody({
    super.key,
    required this.rows,
    required this.picked,
    required this.loadFiles,
  });

  final List<PushRow> rows;
  final ValueNotifier<Set<String>> picked;
  final Future<List<FileStatus>> Function(String path) loadFiles;

  @override
  State<PushDialogBody> createState() => _PushDialogBodyState();
}

class _PushDialogBodyState extends State<PushDialogBody> {
  late PushRow _focus;
  Future<List<FileStatus>>? _files;

  @override
  void initState() {
    super.initState();
    // Open on a repo worth looking at: the first one with something to push.
    _select(widget.rows.firstWhere(
      (r) => widget.picked.value.contains(r.repo.path),
      orElse: () => widget.rows.first,
    ));
  }

  void _select(PushRow row) {
    _focus = row;
    // Only a branch with an upstream has a diff to show; the others explain
    // themselves in the right pane without a call.
    _files =
        row.tracking?.upstream == null ? null : widget.loadFiles(row.repo.path);
  }

  void _toggle(String path) {
    final next = {...widget.picked.value};
    if (!next.remove(path)) next.add(path);
    widget.picked.value = next;
  }

  @override
  Widget build(BuildContext context) {
    final p = Theming.of(context);
    return SizedBox(
      width: 680,
      height: 340,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 300,
            child: ValueListenableBuilder(
              valueListenable: widget.picked,
              builder: (context, picked, _) => ListView(
                children: [
                  for (final row in widget.rows) _repoRow(p, row, picked),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: p.bg,
                border: Border.all(color: p.border),
                borderRadius: BorderRadius.circular(6),
              ),
              padding: const EdgeInsets.all(6),
              child: _filesPane(p),
            ),
          ),
        ],
      ),
    );
  }

  Widget _repoRow(Palette p, PushRow row, Set<String> picked) {
    final t = row.tracking;
    final path = row.repo.path;
    final canPush = t != null && t.branch != null;
    return GestureDetector(
      key: ValueKey('push-row-$path'),
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _select(row)),
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: _focus.repo.path == path ? p.bgSel : null,
          borderRadius: BorderRadius.circular(5),
        ),
        child: Row(
          children: [
            Check3(
              value: picked.contains(path),
              tooltip: canPush ? '推送此仓库' : '无法推送',
              onTap: canPush ? () => _toggle(path) : null,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          row.repo.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ui.copyWith(
                              color: p.text, fontWeight: FontWeight.w600),
                        ),
                      ),
                      if (t != null && t.ahead > BigInt.zero)
                        Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: Text('↑${t.ahead}',
                              style: ui.copyWith(color: p.green, fontSize: 11)),
                        ),
                    ],
                  ),
                  Text(
                    t == null ? '读取分支状态失败' : pushTargetText(t),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ui.copyWith(color: p.textDim, fontSize: 11),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _filesPane(Palette p) {
    final name = _focus.repo.name;
    final t = _focus.tracking;
    if (t == null) return _note(p, '$name：读取分支状态失败');
    if (t.branch == null) return _note(p, '$name：HEAD 不在分支上，无法推送');
    if (t.upstream == null) {
      return _note(p, '$name：新分支，推送后在 origin 上创建');
    }
    return FutureBuilder(
      future: _files,
      builder: (context, snap) {
        if (snap.hasError) return _note(p, snap.error.toString());
        final files = snap.data;
        if (files == null) return _note(p, '载入中…');
        if (files.isEmpty) return _note(p, '$name：没有要推送的提交');
        final root = pathTree([
          for (final f in files) TreeFile(f.path, f.status),
        ]);
        return ListView(
          children: [
            _treeLine(p, 0, null, '$name  ${root.count} 个文件', bold: true),
            ..._treeRows(p, root, 1),
          ],
        );
      },
    );
  }

  /// Folders first with their file counts, then the files themselves — the
  /// shape IDEA shows next to the repo list.
  List<Widget> _treeRows(Palette p, TreeNode node, int depth) => [
        for (final dir in node.dirs) ...[
          _treeLine(p, depth, FolderIcon(color: p.textDim),
              '${dir.name}  ${dir.count} 个文件'),
          ..._treeRows(p, dir, depth + 1),
        ],
        for (final f in node.files)
          Tooltip(
            message: f.path,
            waitDuration: const Duration(milliseconds: 800),
            child: _treeLine(p, depth, StatusBadge(status: f.status),
                f.path.split('/').last),
          ),
      ];

  Widget _treeLine(Palette p, int depth, Widget? icon, String label,
          {bool bold = false}) =>
      SizedBox(
        height: 24,
        child: Padding(
          padding: EdgeInsets.only(left: 4.0 + depth * 14),
          child: Row(
            children: [
              if (icon != null) ...[icon, const SizedBox(width: 6)],
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ui.copyWith(
                    color: p.text,
                    fontWeight: bold ? FontWeight.w600 : null,
                  ),
                ),
              ),
            ],
          ),
        ),
      );

  Widget _note(Palette p, String text) => Padding(
        padding: const EdgeInsets.all(6),
        child: Text(text, style: ui.copyWith(color: p.textDim)),
      );
}
