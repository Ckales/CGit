import 'package:flutter/material.dart';

import 'commit_sheet.dart';
import 'context_menu.dart';
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

/// The workspace push dialog's body, laid out like the Tauri one it replaces:
/// one row per repo with where it lands on the left, the focused repo's push
/// files as a folder tree on the right. [picked] holds the checked repo paths,
/// so the dialog's 推送 button can read it.
class PushDialogBody extends StatefulWidget {
  const PushDialogBody({
    super.key,
    required this.rows,
    required this.picked,
    required this.loadFiles,
    required this.fileMenu,
  });

  final List<PushRow> rows;
  final ValueNotifier<Set<String>> picked;
  final Future<List<FileStatus>> Function(String path) loadFiles;

  /// The right-click menu of a file row: repo path, then the file's path.
  final List<MenuAction> Function(String repo, String path) fileMenu;

  @override
  State<PushDialogBody> createState() => _PushDialogBodyState();
}

class _PushDialogBodyState extends State<PushDialogBody> {
  late PushRow _focus;
  Future<List<FileStatus>>? _files;

  /// Folders the user folded, by their path from the repo root. Open is the
  /// default, so only the exceptions are kept.
  final _collapsed = <String>{};

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
    _collapsed.clear();
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
    final screen = MediaQuery.sizeOf(context);
    // The old min(880px, 94vw) × min(560px, 84vh) box, less the dialog's
    // padding, title and buttons around this body.
    return SizedBox(
      width: (screen.width * 0.94 - 40).clamp(400, 840),
      height: (screen.height * 0.84 - 120).clamp(240, 440),
      child: LayoutBuilder(
        builder: (context, box) => Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: box.maxWidth * 0.44,
              child: _pane(
                p,
                ValueListenableBuilder(
                  valueListenable: widget.picked,
                  builder: (context, picked, _) => ListView(
                    children: [
                      for (final row in widget.rows) _repoRow(p, row, picked),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(child: _pane(p, _filesPane(p))),
          ],
        ),
      ),
    );
  }

  Widget _pane(Palette p, Widget child) => Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          border: Border.all(color: p.border),
          borderRadius: BorderRadius.circular(6),
        ),
        child: child,
      );

  Widget _repoRow(Palette p, PushRow row, Set<String> picked) {
    final t = row.tracking;
    final path = row.repo.path;
    final canPush = t != null && t.branch != null;
    return _HoverRow(
      key: ValueKey('push-row-$path'),
      // Hover already uses bgElev, so the row whose files are on the right
      // needs a second mark — the accent bar — to stand apart from the one
      // merely under the cursor.
      current: _focus.repo.path == path,
      onTap: () => setState(() => _select(row)),
      child: Row(
        children: [
          Check3(
            value: picked.contains(path),
            tooltip: canPush ? '推送此仓库' : '无法推送',
            onTap: canPush ? () => _toggle(path) : null,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    row.repo.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        ui.copyWith(color: p.text, fontWeight: FontWeight.w600),
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
          ),
          const SizedBox(width: 8),
          Text(
            t == null ? '读取分支状态失败' : pushTargetText(t),
            maxLines: 1,
            style: ui.copyWith(color: p.textDim),
          ),
        ],
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
            _treeRow(
              p,
              0,
              Text('$name  ${root.count} 个文件',
                  style:
                      ui.copyWith(color: p.text, fontWeight: FontWeight.w600)),
            ),
            ..._treeRows(p, root, '', 1),
          ],
        );
      },
    );
  }

  /// Folders first with their file counts, then the files themselves — the
  /// shape IDEA shows next to the repo list. [prefix] is [node]'s path from
  /// the repo root, which keys the folded folders.
  List<Widget> _treeRows(Palette p, TreeNode node, String prefix, int depth) {
    final rows = <Widget>[];
    for (final dir in node.dirs) {
      final key = '$prefix${dir.name}/';
      final open = !_collapsed.contains(key);
      rows.add(_treeRow(
        p,
        depth,
        Row(
          children: [
            Disclosure(open: open, color: p.textDim),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                '${dir.name}  ${dir.count} 个文件',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ui.copyWith(color: p.text),
              ),
            ),
          ],
        ),
        onTap: () => setState(() {
          if (!_collapsed.remove(key)) _collapsed.add(key);
        }),
      ));
      if (open) rows.addAll(_treeRows(p, dir, key, depth + 1));
    }
    for (final f in node.files) {
      rows.add(Tooltip(
        message: f.path,
        waitDuration: const Duration(milliseconds: 800),
        child: _treeRow(
          p,
          depth,
          Row(
            children: [
              StatusBadge(status: f.status),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  f.path.split('/').last,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ui.copyWith(color: p.textDim),
                ),
              ),
            ],
          ),
          onMenuAt: (pos) => showRepoMenu(
            context: context,
            position: pos,
            items: widget.fileMenu(_focus.repo.path, f.path),
          ),
        ),
      ));
    }
    return rows;
  }

  Widget _treeRow(Palette p, int depth, Widget child,
          {VoidCallback? onTap, void Function(Offset)? onMenuAt}) =>
      _HoverRow(
        indent: depth * 14,
        onTap: onTap,
        onMenuAt: onMenuAt,
        child: child,
      );

  Widget _note(Palette p, String text) => Padding(
        padding: const EdgeInsets.all(6),
        child: Text(text, style: ui.copyWith(color: p.textDim)),
      );
}

/// The old `.list li`: 26px tall, 5px corners, bgElev on hover. [current] adds
/// the accent bar on the left.
class _HoverRow extends StatefulWidget {
  const _HoverRow({
    super.key,
    required this.child,
    this.indent = 0,
    this.current = false,
    this.onTap,
    this.onMenuAt,
  });

  final Widget child;
  final double indent;
  final bool current;
  final VoidCallback? onTap;
  final void Function(Offset position)? onMenuAt;

  @override
  State<_HoverRow> createState() => _HoverRowState();
}

class _HoverRowState extends State<_HoverRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = Theming.of(context);
    final clickable = widget.onTap != null || widget.onMenuAt != null;
    return MouseRegion(
      cursor: widget.onTap == null
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      onEnter: clickable ? (_) => setState(() => _hover = true) : null,
      onExit: clickable ? (_) => setState(() => _hover = false) : null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onSecondaryTapUp: widget.onMenuAt == null
            ? null
            : (d) => widget.onMenuAt!(d.globalPosition),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(5),
          child: Container(
            height: 26,
            padding: EdgeInsets.only(left: 6 + widget.indent, right: 6),
            decoration: BoxDecoration(
              color: widget.current || _hover ? p.bgElev : null,
              border: widget.current
                  ? Border(left: BorderSide(color: p.accent, width: 2))
                  : null,
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
