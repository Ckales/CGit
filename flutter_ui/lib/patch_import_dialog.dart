import 'package:flutter/material.dart';

import 'dialogs.dart';
import 'diff_view.dart';
import 'git_text.dart';
import 'merge_view.dart';
import 'theme.dart';

class PatchImportConflict {
  const PatchImportConflict({required this.path, required this.content,
    required this.ours, required this.theirs, this.binary = false});
  final String path;
  final String content;
  final String ours;
  final String theirs;
  final bool binary;
}

class PreparedPatch {
  const PreparedPatch({required this.token, required this.files});
  factory PreparedPatch.fromJson(Map<String, dynamic> json) => PreparedPatch(
    token: json['token'] as String,
    files: [for (final f in json['files'] as List)
      if (f['conflict'] == true) PatchImportConflict(
        path: f['path'] as String, content: f['content'] as String? ?? '',
        ours: f['ours'] as String? ?? '', theirs: f['theirs'] as String? ?? '',
        binary: f['binary'] == true,
      ),
    ],
  );
  final String token;
  /// Clean results remain in the isolated backend session.
  final List<PatchImportConflict> files;
}

/// Selection and conflict decisions stay here until the final apply succeeds.
class PatchImportDialog extends StatefulWidget {
  const PatchImportDialog({super.key, required this.files, required this.source,
    required this.prepare, required this.finish, required this.discard});
  final List<ImportPatchFile> files;
  final String source;
  final Future<PreparedPatch> Function(String patch) prepare;
  final Future<void> Function(String token, Map<String, Map<String, String>> resolutions) finish;
  final Future<void> Function(String token) discard;

  @override
  State<PatchImportDialog> createState() => _PatchImportDialogState();
}

class _PatchImportDialogState extends State<PatchImportDialog> {
  late final _picked = {for (var i = 0; i < widget.files.length; i++) i};
  int _active = 0;
  bool _busy = false;
  String? _error;
  PreparedPatch? _prepared;
  final _resolved = <String, Map<String, String>>{};
  PatchImportConflict? _editing;
  DiffMode _mode = DiffMode.split;

  Future<void> _cancel() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final session = _prepared;
      if (session != null) await widget.discard(session.token);
      if (mounted) Navigator.of(context).pop(false);
    } catch (e) {
      if (mounted) setState(() { _busy = false; _error = '$e'; });
    }
  }

  Future<void> _apply() async {
    if (_busy || _picked.isEmpty) return;
    setState(() { _busy = true; _error = null; });
    try {
      if (_prepared == null) {
        final patch = [for (var i = 0; i < widget.files.length; i++)
          if (_picked.contains(i)) widget.files[i].patch].join();
        _prepared = await widget.prepare(patch);
      }
      if (!mounted) {
        await widget.discard(_prepared!.token);
        return;
      }
      final pending = _prepared!.files.where((f) => !_resolved.containsKey(f.path));
      if (pending.isNotEmpty) {
        setState(() { _busy = false; _editing = pending.first; });
        return;
      }
      await widget.finish(_prepared!.token, _resolved);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      // Keep the selection and all manual resolutions so the user can inspect
      // the error and retry without losing their work.
      if (mounted) setState(() { _busy = false; _error = '$e'; });
    }
  }

  Future<void> _saveResolution(String content) async {
    setState(() { _resolved[_editing!.path] = {'content': content}; _editing = null; });
  }

  Future<void> _saveSide(String side) async {
    setState(() { _resolved[_editing!.path] = {'side': side}; _editing = null; });
  }

  @override
  Widget build(BuildContext context) {
    final p = Theming.of(context);
    final session = _prepared;
    final left = session?.files.where((f) => !_resolved.containsKey(f.path)).length ?? 0;
    final file = widget.files[_active];
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) { if (!didPop) _cancel(); },
      child: Dialog(
        backgroundColor: p.bg,
        insetPadding: const EdgeInsets.all(24),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(width: 1160, height: 760,
          child: Stack(children: [
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Padding(padding: const EdgeInsets.all(16), child: Row(children: [
                Expanded(child: Text('应用补丁 · ${widget.source}',
                  style: ui.copyWith(color: p.text, fontWeight: FontWeight.w600))),
                Text('${_picked.length} / ${widget.files.length} 个文件',
                  style: ui.copyWith(color: p.textDim)),
              ])),
              Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Text(session == null
                  ? '选择要应用的文件，点击文件查看差异。确认应用后写入工作区。'
                  : left > 0 ? '$left 个冲突待解决，解决后再应用全部所选文件。'
                  : '冲突已全部解决，可以应用到工作区。',
                  style: ui.copyWith(color: left > 0 ? p.yellow : p.textDim))),
              Expanded(child: LayoutBuilder(builder: (context, box) {
                final list = _fileList(p);
                final preview = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Container(color: p.bgAlt, padding: const EdgeInsets.all(8), child: Row(children: [
                    Expanded(child: Text(file.path, overflow: TextOverflow.ellipsis,
                      style: ui.copyWith(color: p.text))),
                    DialogButton(_mode == DiffMode.split ? '并排' : '统一', onTap: () => setState(() {
                      _mode = _mode == DiffMode.split ? DiffMode.unified : DiffMode.split;
                    })),
                  ])),
                  Expanded(child: PatchPreview(text: file.patch, file: file.path, mode: _mode)),
                ]);
                if (box.maxWidth < 720) {
                  return Column(children: [
                    SizedBox(height: box.maxHeight * .4, child: list), Expanded(child: preview),
                  ]);
                }
                return Row(children: [
                  SizedBox(width: (box.maxWidth * .3).clamp(220, 340), child: list),
                  VerticalDivider(width: 1, color: p.border), Expanded(child: preview),
                ]);
              })),
              if (_error != null) ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 120),
                child: SingleChildScrollView(padding: const EdgeInsets.all(12),
                  child: SelectableText(_error!, style: ui.copyWith(color: p.red))),
              ),
              Padding(padding: const EdgeInsets.all(12), child: Row(children: [
                if (_busy) Text('正在准备或应用补丁…', style: ui.copyWith(color: p.textDim)),
                const Spacer(),
                _button('取消应用', !_busy, _cancel),
                const SizedBox(width: 8),
                _button(session == null ? '应用所选补丁' : '应用到工作区',
                  !_busy && _picked.isNotEmpty && left == 0, _apply, primary: true),
              ])),
            ]),
            if (_editing != null && !_editing!.binary) MergeWindow(
              key: ValueKey(_editing!.path), file: _editing!.path,
              content: _resolved[_editing!.path]?['content'] ?? _editing!.content,
              patchImport: true,
              onClose: () => setState(() => _editing = null),
              onResolveWith: _saveResolution,
              onResolveSide: _saveSide,
              onToggleBase: (_) async {},
            ),
            if (_editing?.binary == true) Positioned.fill(child: ColoredBox(
              color: const Color(0x99000000), child: Center(child: Container(
                padding: const EdgeInsets.all(24), color: p.bgAlt,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text('二进制补丁冲突 · ${_editing!.path}', style: ui.copyWith(color: p.text)),
                  const SizedBox(height: 12),
                  Text('选择要保留的文件版本', style: ui.copyWith(color: p.textDim)),
                  const SizedBox(height: 16),
                  Wrap(spacing: 8, children: [
                    DialogButton('取消', onTap: () => setState(() => _editing = null)),
                    DialogButton('采用本地版本', onTap: () => _saveSide('ours')),
                    DialogButton('采用补丁版本', onTap: () => _saveSide('theirs')),
                  ]),
                ]),
              )))),
          ]),
        ),
      ),
    );
  }

  Widget _button(String label, bool enabled, VoidCallback action, {bool primary = false}) =>
    Opacity(opacity: enabled ? 1 : .4, child: IgnorePointer(ignoring: !enabled,
      child: DialogButton(label, onTap: action,
        kind: primary ? DialogButtonKind.primary : DialogButtonKind.normal)));

  Widget _fileList(Palette p) => Column(children: [
    Row(children: [
      Checkbox(tristate: true,
        value: _picked.length == widget.files.length ? true : _picked.isEmpty ? false : null,
        onChanged: _busy || _prepared != null ? null : (v) => setState(() {
          if (_picked.length == widget.files.length) { _picked.clear(); }
          else { _picked.addAll(List.generate(widget.files.length, (i) => i)); }
        })),
      Text('全选', style: ui.copyWith(color: p.textDim)),
    ]),
    Expanded(child: ListView.builder(itemCount: widget.files.length,
      itemBuilder: (context, i) {
        final file = widget.files[i];
        final conflict = _prepared?.files.where((f) => f.path == file.path).firstOrNull;
        final resolved = conflict != null && _resolved.containsKey(conflict.path);
        return Material(color: _active == i ? p.bgHover : Colors.transparent,
          child: InkWell(onTap: () => setState(() { _active = i; }),
            child: Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Row(children: [
              Checkbox(key: ValueKey('pick-$i'), value: _picked.contains(i),
                onChanged: _busy || _prepared != null ? null : (v) => setState(() {
                  if (v == true) { _picked.add(i); } else { _picked.remove(i); }
                })),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(file.path, style: ui.copyWith(color: p.text), overflow: TextOverflow.ellipsis),
                Text(conflict == null ? file.status : resolved ? '已解决' : '冲突',
                  style: ui.copyWith(color: conflict == null ? p.textDim : resolved ? p.green : p.yellow, fontSize: 11)),
              ])),
              if (conflict != null) IconButton(tooltip: '解决冲突',
                onPressed: _busy ? null : () => setState(() => _editing = conflict),
                icon: Icon(Icons.merge_type, size: 16, color: p.yellow)),
            ])),
          ),
        );
      })),
  ]);
}
