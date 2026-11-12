import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'code_field.dart';
import 'git_text.dart';
import 'merge_document.dart';
import 'theme.dart';

/// Three aligned source panes around one continuous, editable merge result.
///
/// When the caller can read the index stages, the panes show the real
/// base/ours/theirs files and every change is attributed — auto-merged changes
/// included, not only the conflicts. The marker path stays as a fallback for
/// patch import and for conflicts whose blobs are not readable.
class MergeWindow extends StatefulWidget {
  const MergeWindow({
    super.key,
    required this.file,
    required this.content,
    required this.onClose,
    required this.onResolveWith,
    required this.onResolveSide,
    this.base,
    this.ours,
    this.theirs,
    this.oursLabel,
    this.theirsLabel,
    this.patchImport = false,
  });

  final String file;

  final bool patchImport;

  /// The worktree file, markers and all. Used when [ours] or [theirs] is null.
  final String content;

  /// The three index stages, when they are readable. [base] is null for an
  /// add/add conflict, which has no common ancestor.
  final String? base;
  final String? ours;
  final String? theirs;

  /// Branch names for the "来自 … 的更改" headers. Null keeps the generic
  /// wording — rebase and cherry-pick have no branch on the other side.
  final String? oursLabel;
  final String? theirsLabel;

  final VoidCallback onClose;

  /// Write this text and mark the file resolved.
  final Future<void> Function(String content) onResolveWith;

  /// Take one whole side — the no-marker fallback.
  final Future<void> Function(String side) onResolveSide;

  @override
  State<MergeWindow> createState() => _MergeWindowState();
}

class _MergeWindowState extends State<MergeWindow> {
  late ParsedConflicts _parsed;
  late MergeDocument _document;
  late Syntax _syntax;
  late String _indent;
  late CodeController _result;
  final _focus = FocusNode();
  final _vertical = List.generate(3, (_) => ScrollController());
  final _horizontal = List.generate(3, (_) => ScrollController());
  bool _syncing = false;
  bool _syncScroll = true;
  bool _showBase = true;
  bool _highlightWords = true;
  bool _threePane = false;
  int _current = -1;
  TextScaler? _lineHeightScaler;
  double _measuredLineHeight = 0;

  double get _lineHeight {
    final scaler = MediaQuery.textScalerOf(context);
    if (_lineHeightScaler != scaler) {
      final painter = TextPainter(
        text: const TextSpan(text: ' ', style: mono),
        strutStyle: StrutStyle.fromTextStyle(mono, forceStrutHeight: true),
        textScaler: scaler,
        textDirection: TextDirection.ltr,
      )..layout();
      _measuredLineHeight = painter.preferredLineHeight;
      painter.dispose();
      _lineHeightScaler = scaler;
    }
    return _measuredLineHeight;
  }

  bool get _mergeMode => _threePane || _parsed.hasConflict;
  int get _conflictCount => _document.conflictCount;
  int get _changeCount => _document.changeStates.length;
  List<int> get _differenceGroups => _document.differenceGroupIndices;
  int get _differenceCount => _differenceGroups.length;
  bool get _hasBase => _document.baseAvailable;
  int get _pendingAll => _document.pendingChangeCount;

  /// Pending clean changes one side can contribute; identical edits count for
  /// both, since applying them twice is a no-op.
  int get _pendingOurs => _pendingChanges(ours: true);
  int get _pendingTheirs => _pendingChanges(ours: false);

  int _pendingChanges({required bool ours}) => _document.changeStates
      .where((g) =>
          g.changeAccepted == null &&
          !g.manual &&
          (g.group.kind == MergeGroupKind.bothSame ||
              (ours
                  ? g.group.kind == MergeGroupKind.oursOnly
                  : g.group.kind == MergeGroupKind.theirsOnly)))
      .length;

  @override
  void initState() {
    super.initState();
    _syntax = Syntax(widget.file);
    _result = CodeController(syntax: _syntax);
    _parse();
    for (var i = 0; i < 3; i++) {
      _vertical[i].addListener(() => _sync(i));
      _horizontal[i].addListener(() => _syncHorizontal(i));
    }
  }

  @override
  void didUpdateWidget(MergeWindow old) {
    super.didUpdateWidget(old);
    if (old.content != widget.content ||
        old.base != widget.base ||
        old.ours != widget.ours ||
        old.theirs != widget.theirs ||
        old.file != widget.file) {
      if (old.file != widget.file) {
        _result.dispose();
        _syntax = Syntax(widget.file);
        _result = CodeController(syntax: _syntax);
      }
      _current = -1;
      _parse();
    }
  }

  void _parse() {
    _parsed = parseConflicts(widget.content);
    _threePane = widget.ours != null && widget.theirs != null;
    _document = _threePane
        ? MergeDocument.threeWay(
            base: widget.base, ours: widget.ours!, theirs: widget.theirs!)
        : MergeDocument(_parsed);
    _indent = indentUnitOf(_threePane ? widget.ours! : widget.content);
    _result.text = _mergeMode ? _document.text : widget.content;
    _current = _differenceCount > 0 ? 0 : -1;
    final document = _document;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && identical(document, _document)) {
        if (_current == 0) {
          _showDifference(0, focus: false);
        } else {
          for (final controller in _horizontal) {
            if (controller.hasClients) controller.jumpTo(0);
          }
        }
      }
    });
  }

  @override
  void dispose() {
    _result.dispose();
    _focus.dispose();
    for (final c in [..._vertical, ..._horizontal]) {
      c.dispose();
    }
    super.dispose();
  }

  int _sourceRowCount(MergeGroupState group, int pane) {
    final lines = pane == 0 ? group.group.oursLines : group.group.theirsLines;
    // 没有祖先的空冲突保留按钮行；真正删除的内容不占源文件行。
    if (group.isConflict && group.group.baseLines.isEmpty && lines.isEmpty) {
      return 1;
    }
    return lines.length;
  }

  /// 结果中的显示行范围，文件尾的空块位于最后一行之后。
  ({int first, int end}) _resultLineRange(MergeGroupState group) {
    var first = _document.lineAt(group.start);
    if (!group.hasLines &&
        group.start == _document.text.length &&
        _document.text.isNotEmpty &&
        !_document.text.endsWith('\n')) {
      first++;
    }
    final end = group.hasLines
        ? _document
                .lineAt(group.end > group.start ? group.end - 1 : group.start) +
            1
        : first;
    return (first: first, end: end);
  }

  List<double> _anchors(int pane) {
    if (pane == 1) {
      // Use actual document positions: counting each group's occupied lines
      // misses empty trailing lines and drifts away from the source panes.
      return [
        for (final g in _document.groups)
          _resultLineRange(g).first * _lineHeight,
        _document.text.split('\n').length * _lineHeight,
      ];
    }
    final out = <double>[0];
    var y = 0.0;
    for (final g in _document.groups) {
      y += _sourceRowCount(g, pane) * _lineHeight;
      out.add(y);
    }
    return out;
  }

  double _mapOffset(double offset, List<double> from, List<double> to) {
    for (var i = 1; i < from.length; i++) {
      if (offset < from[i] && from[i] > from[i - 1]) {
        return to[i - 1] +
            (offset - from[i - 1]) /
                (from[i] - from[i - 1]) *
                (to[i] - to[i - 1]);
      }
    }
    return to.last + offset - from.last;
  }

  void _sync(int source) {
    if (_syncing || !_syncScroll || !_vertical[source].hasClients) return;
    _syncing = true;
    final from = _anchors(source);
    // 与 JB 一样，以可视区内三分之一处为对齐点，避免长插入块把上下文顶到边缘。
    final reference = _vertical[source].offset +
        _vertical[source].position.viewportDimension / 3;
    for (var i = 0; i < 3; i++) {
      if (i == source || !_vertical[i].hasClients) continue;
      final target = _vertical[i];
      target.jumpTo((_mapOffset(reference, from, _anchors(i)) -
              target.position.viewportDimension / 3)
          .clamp(0.0, target.position.maxScrollExtent));
    }
    _syncing = false;
  }

  void _syncHorizontal(int source) {
    if (_syncing || !_syncScroll || !_horizontal[source].hasClients) return;
    _syncing = true;
    for (var i = 0; i < 3; i++) {
      if (i == source || !_horizontal[i].hasClients) continue;
      _horizontal[i].jumpTo(_horizontal[source]
          .offset
          .clamp(0.0, _horizontal[i].position.maxScrollExtent));
    }
    _syncing = false;
  }

  void _refreshResult() {
    final offset =
        _result.selection.isValid ? _result.selection.extentOffset : 0;
    _result.value = TextEditingValue(
        text: _document.text,
        selection: TextSelection.collapsed(
            offset: offset.clamp(0, _document.text.length)));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _sync(1);
    });
  }

  void _decide(int conflict, String side, bool take) => setState(() {
        _current =
            _differenceGroups.indexOf(_document.conflictGroupIndices[conflict]);
        _document.choose(conflict,
            ours: side == 'ours' ? take : null,
            theirs: side == 'theirs' ? take : null);
        _refreshResult();
      });

  void _chooseChange(int groupIndex, bool accept) => setState(() {
        _current = _differenceGroups.indexOf(groupIndex);
        _document.chooseChange(groupIndex, accept: accept);
        _refreshResult();
      });

  void _acceptNonConflicting({bool? ours}) => setState(() {
        _document.acceptNonConflicting(ours: ours);
        _refreshResult();
      });

  void _setAll(bool ours) => setState(() {
        _document.chooseAll(ours: ours);
        _refreshResult();
      });

  void _history(bool redo) => setState(() {
        redo ? _document.redo() : _document.undo();
        _refreshResult();
      });

  void _jump(int delta) {
    if (_differenceCount == 0) return;
    final next = _current < 0
        ? (delta > 0 ? 0 : _differenceCount - 1)
        : (_current + delta + _differenceCount) % _differenceCount;
    _showDifference(next);
  }

  void _showDifference(int next, {bool focus = true}) {
    setState(() => _current = next);
    final groupIndex = _differenceGroups[next];
    final state = _document.groups[groupIndex];
    // An extended selection makes EditableText reveal its far endpoint,
    // scrolling long lines sideways (and moving the linked source panes).
    _result.selection = TextSelection.collapsed(offset: state.start);
    _syncing = true;
    for (var i = 0; i < 3; i++) {
      if (_vertical[i].hasClients) {
        _vertical[i].jumpTo((_anchors(i)[groupIndex] - 60)
            .clamp(0.0, _vertical[i].position.maxScrollExtent));
      }
      if (_horizontal[i].hasClients) _horizontal[i].jumpTo(0);
    }
    _syncing = false;
    if (focus) _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final p = Theming.of(context);
    return Positioned.fill(
        child: ColoredBox(
      color: const Color(0x99000000),
      child: Padding(
          padding: const EdgeInsets.all(12),
          child: Container(
            decoration: BoxDecoration(
                color: p.bg,
                border: Border.all(color: p.border),
                borderRadius: BorderRadius.circular(8)),
            clipBehavior: Clip.antiAlias,
            child: ScrollConfiguration(
                behavior:
                    ScrollConfiguration.of(context).copyWith(scrollbars: false),
                child: CallbackShortcuts(
                    bindings: {
                      const SingleActivator(LogicalKeyboardKey.f7): () =>
                          _jump(1),
                      const SingleActivator(LogicalKeyboardKey.f7, shift: true):
                          () => _jump(-1),
                      if (_mergeMode) ...{
                        const SingleActivator(LogicalKeyboardKey.keyZ,
                            meta: true): () => _history(false),
                        const SingleActivator(LogicalKeyboardKey.keyZ,
                            meta: true, shift: true): () => _history(true),
                      },
                    },
                    child: Focus(
                        autofocus: true,
                        child: Column(children: [
                          _mergeMode ? _toolbar(p) : _titleBar(p),
                          Expanded(
                              child: _mergeMode
                                  ? _mergeGrid(p)
                                  : _wholeFilePane(p)),
                          _mergeMode ? _mergeActions(p) : _wholeFileActions(p),
                        ])))),
          )),
    ));
  }

  /// The whole merge chrome in one row, following the JetBrains merge dialog:
  /// bulk application of clean changes and view options on the left, then
  /// navigation and the change/conflict totals on the right.
  Widget _toolbar(Palette p) => Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
          color: p.bgAlt, border: Border(bottom: BorderSide(color: p.border))),
      child: Row(children: [
        Expanded(
            child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: [
                  Padding(
                      padding: const EdgeInsets.only(right: 2),
                      child: Text('应用不冲突的更改：',
                          style: ui.copyWith(color: p.textDim, fontSize: 11))),
                  _NavButton(
                      label: '»',
                      tooltip: '只应用我方的非冲突更改',
                      onTap: _pendingOurs > 0
                          ? () => _acceptNonConflicting(ours: true)
                          : null),
                  _NavButton(
                      label: '»«',
                      tooltip: '应用全部不冲突的更改',
                      onTap: _pendingAll > 0
                          ? () => _acceptNonConflicting()
                          : null),
                  _NavButton(
                      label: '«',
                      tooltip: '只应用对方的非冲突更改',
                      onTap: _pendingTheirs > 0
                          ? () => _acceptNonConflicting(ours: false)
                          : null),
                  _toolbarDivider(p),
                  _ToolText(
                      label: '撤销',
                      onTap: _document.canUndo ? () => _history(false) : null),
                  _ToolText(
                      label: '重做',
                      onTap: _document.canRedo ? () => _history(true) : null),
                  _toolbarDivider(p),
                  _ToolText(
                      label: '高亮单词：${_highlightWords ? '开' : '关'}',
                      active: _highlightWords,
                      tooltip: '高亮显示单词',
                      onTap: () =>
                          setState(() => _highlightWords = !_highlightWords)),
                  _ToolText(
                      label: _syncScroll ? '同步滚动：开' : '同步滚动：关',
                      active: _syncScroll,
                      onTap: () => setState(() {
                            _syncScroll = !_syncScroll;
                            if (_syncScroll) _sync(1);
                          })),
                  if (_hasBase)
                    _ToolText(
                        label: _showBase ? '收起祖先参考' : '展开祖先参考',
                        active: _showBase,
                        onTap: () => setState(() => _showBase = !_showBase)),
                ]))),
        // Navigation sits at the far end like the reference dialog, beside the
        // change totals.
        const SizedBox(width: 4),
        _NavButton(
            label: '↑',
            tooltip: '上一处差异',
            onTap: _differenceCount > 0 ? () => _jump(-1) : null),
        _NavButton(
            label: '↓',
            tooltip: '下一处差异',
            onTap: _differenceCount > 0 ? () => _jump(1) : null),
        Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
                _differenceCount > 0
                    ? '${_current + 1} / $_differenceCount'
                    : '无差异',
                style: ui.copyWith(color: p.textDim, fontSize: 11))),
        const SizedBox(width: 8),
        Text(_summary,
            style: ui.copyWith(color: _summaryColor(p), fontSize: 11)),
        const SizedBox(width: 6),
        _IconText(label: '✕', onTap: widget.onClose),
      ]));

  Widget _toolbarDivider(Palette p) => Container(
      width: 1,
      height: 18,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      color: p.border);

  Color _summaryColor(Palette p) {
    if (_conflictCount == 0) return p.textDim;
    return _document.undecided > 0 ? p.yellow : p.green;
  }

  /// Fallback chrome for a file with no markers and no three-way index stages:
  /// there is nothing to navigate or bulk-apply, only the whole-file choice.
  Widget _titleBar(Palette p) => Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
          color: p.bgAlt, border: Border(bottom: BorderSide(color: p.border))),
      child: Row(children: [
        Expanded(
            child: Text(
                '${widget.patchImport ? '补丁冲突' : '合并'} — ${widget.file}',
                overflow: TextOverflow.ellipsis,
                style: ui.copyWith(color: p.text))),
        _IconText(label: '✕', onTap: widget.onClose),
      ]));

  Widget _wholeFilePane(Palette p) =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
            padding: const EdgeInsets.all(8),
            color: p.bgAlt,
            child:
                Text('无文本冲突标记 — 整文件处理', style: ui.copyWith(color: p.textDim))),
        Expanded(
            child: Padding(
                padding: const EdgeInsets.all(8),
                child: CodeField(
                    controller: _result, indentUnit: _indent, expands: true))),
      ]);

  Widget _wholeFileActions(Palette p) => _bar(p, [
        _Btn(label: '采用我方', onTap: () => widget.onResolveSide('ours')),
        _Btn(label: '采用对方', onTap: () => widget.onResolveSide('theirs')),
        _Btn(label: '取消', onTap: widget.onClose),
        _Btn(
            label: '标记为已解决',
            primary: true,
            onTap: () => widget.onResolveWith(_result.text)),
      ]);

  double _textWidth() {
    var widest = 0.0;
    void measure(String text) {
      final painter = TextPainter(
          text: TextSpan(text: text, style: mono),
          textScaler: MediaQuery.textScalerOf(context),
          textDirection: TextDirection.ltr)
        ..layout();
      widest = math.max(widest, painter.width);
      painter.dispose();
    }

    measure(_result.text);
    for (final g in _document.groups) {
      measure(g.group.baseLines.join('\n'));
      measure(_sourceText(g.group, 0));
      measure(_sourceText(g.group, 2));
    }
    return widest + 24;
  }

  String _sourceText(MergeGroup g, int pane) =>
      (pane == 0 ? g.oursLines : g.theirsLines).join('\n');

  Widget _mergeGrid(Palette p) => ScrollbarTheme(
      // Material's default thumb is black-on-light: invisible on our dark
      // palettes. Paint a JetBrains-style slim thumb instead.
      data: ScrollbarThemeData(
          thumbColor: WidgetStatePropertyAll(p.textDim.withValues(alpha: 0.5)),
          thickness: const WidgetStatePropertyAll(8),
          radius: const Radius.circular(8)),
      child: Column(children: [
        Expanded(child: LayoutBuilder(builder: (context, box) {
          final width = math.max(_textWidth(), box.maxWidth / 3 - 92);
          return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(
                child: _pane(
                    p,
                    _sideTitle(
                        p,
                        widget.patchImport
                            ? '本地版本'
                            : widget.oursLabel ?? '当前分支'),
                    _sourcePane(p, 0, width))),
            Expanded(child: _pane(p, _resultTitle(p), _resultPane(p, width))),
            Expanded(
                child: _pane(
                    p,
                    _sideTitle(
                        p,
                        widget.patchImport
                            ? '补丁版本'
                            : widget.theirsLabel ?? '传入版本'),
                    _sourcePane(p, 2, width))),
          ]);
        })),
        if (_hasBase && _showBase) _baseStrip(p),
      ]));

  /// "来自 branch 的更改", with the name standing out the way the JetBrains
  /// merge dialog does.
  Widget _sideTitle(Palette p, String name) => Text.rich(
      TextSpan(children: [
        const TextSpan(text: '来自 '),
        TextSpan(
            text: name,
            style: TextStyle(color: p.yellow, fontWeight: FontWeight.w600)),
        const TextSpan(text: ' 的更改'),
      ]),
      overflow: TextOverflow.ellipsis,
      style: ui.copyWith(color: p.textDim, fontSize: 11));

  /// "结果 path" — the file name belongs here rather than in a separate window
  /// title, so the three headers line up like the reference dialog.
  Widget _resultTitle(Palette p) => Text.rich(
      TextSpan(children: [
        const TextSpan(text: '结果 '),
        TextSpan(text: widget.file, style: TextStyle(color: p.text)),
      ]),
      overflow: TextOverflow.ellipsis,
      style: ui.copyWith(color: p.textDim, fontSize: 11));

  Widget _pane(Palette p, Widget title, Widget body) => Container(
      decoration:
          BoxDecoration(border: Border(right: BorderSide(color: p.border))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            alignment: Alignment.centerLeft,
            color: p.bgAlt,
            child: title),
        Expanded(child: ColoredBox(color: p.diffBg, child: body)),
      ]));

  Color? _sourceTint(Palette p, MergeGroupState g, int pane) {
    switch (g.group.kind) {
      case MergeGroupKind.common:
        return null;
      case MergeGroupKind.oursOnly:
        if (pane != 0) return null;
        return g.changeAccepted == false
            ? p.textDim.withValues(alpha: 0.06)
            : p.addRow;
      case MergeGroupKind.theirsOnly:
        if (pane != 2) return null;
        return g.changeAccepted == false
            ? p.textDim.withValues(alpha: 0.06)
            : p.addRow;
      case MergeGroupKind.bothSame:
        return g.changeAccepted == false
            ? p.textDim.withValues(alpha: 0.06)
            : p.addRow;
      case MergeGroupKind.conflict:
        final take = pane == 0 ? g.ours : g.theirs;
        if (take == false) return p.textDim.withValues(alpha: 0.06);
        return p.mergeConflictRow;
    }
  }

  /// 冲突保留原来的红色标记，其他标记与正文底色保持一致。
  Color? _sourceMarker(Palette p, MergeGroupState group, int pane) {
    final tint = _sourceTint(p, group, pane);
    if (tint == null) return null;
    if (group.isConflict && (pane == 0 ? group.ours : group.theirs) != false) {
      return p.mergeConflictMarker;
    }
    return Color.alphaBlend(tint, p.diffBg);
  }

  List<Widget> _gutterActions(
      Palette p, int groupIndex, int conflict, int pane) {
    final g = _document.groups[groupIndex];
    if (g.isConflict) {
      final accept = _GutterButton(
          label: pane == 0 ? '»' : '«',
          tooltip: pane == 0 ? '合并我方这段 → 结果' : '合并对方这段 → 结果',
          active: (pane == 0 ? g.ours : g.theirs) == true,
          onTap: () => _decide(conflict, pane == 0 ? 'ours' : 'theirs', true));
      final ignore = _GutterButton(
          label: '✕',
          tooltip: pane == 0 ? '不合并我方这段' : '不合并对方这段',
          active: (pane == 0 ? g.ours : g.theirs) == false,
          onTap: () => _decide(conflict, pane == 0 ? 'ours' : 'theirs', false));
      return pane == 0 ? [ignore, accept] : [accept, ignore];
    }
    final origin = switch (g.group.kind) {
      MergeGroupKind.oursOnly => pane == 0,
      MergeGroupKind.theirsOnly => pane == 2,
      MergeGroupKind.bothSame => true,
      _ => false,
    };
    if (!origin) return const [];
    // Applied already: the result gutter bar is the marker. Leaving the chip
    // active painted a blue « × on the result edge instead of that bar.
    if (g.changeAccepted == true) return const [];
    final accept = _GutterButton(
        label: pane == 0 ? '»' : '«',
        tooltip: pane == 0 ? '合并我方这处非冲突修改 → 结果' : '合并对方这处非冲突修改 → 结果',
        active: g.changeAccepted == true,
        onTap: () => _chooseChange(groupIndex, true));
    final ignore = _GutterButton(
        label: '✕',
        tooltip: pane == 0 ? '忽略我方这处非冲突修改' : '忽略对方这处非冲突修改',
        active: g.changeAccepted == false,
        onTap: () => _chooseChange(groupIndex, false));
    return pane == 0 ? [ignore, accept] : [accept, ignore];
  }

  Widget _sourcePane(Palette p, int pane, double width) {
    var line = 1;
    var conflict = 0;
    var hasActions = false;
    final numbers = <Widget>[];
    final actions = <Widget>[];
    final blocks = <Widget>[];
    var sourceTop = 0.0;
    for (var gi = 0; gi < _document.groups.length; gi++) {
      final g = _document.groups[gi];
      final rows = g.group.rows;
      final height = _sourceRowCount(g, pane) * _lineHeight;
      final lineNumbers = <String>[];
      for (final row in rows) {
        final cell = pane == 0 ? row.ours : row.theirs;
        if (cell != null) lineNumbers.add('${line++}');
      }
      numbers.add(Container(
          color: _sourceMarker(p, g, pane),
          height: height,
          child: height > 0
              ? Text(lineNumbers.join('\n'),
                  textAlign: TextAlign.right,
                  style: mono.copyWith(color: p.textDim),
                  strutStyle:
                      StrutStyle.fromTextStyle(mono, forceStrutHeight: true))
              : const SizedBox.shrink()));
      final groupActions =
          _gutterActions(p, gi, g.isConflict ? conflict++ : -1, pane);
      if (groupActions.isNotEmpty) hasActions = true;
      if (groupActions.isNotEmpty) {
        actions.add(Positioned(
            top: height == 0
                ? math.max(0, sourceTop - _lineHeight / 2)
                : sourceTop,
            left: 0,
            right: 0,
            height: _lineHeight,
            child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: groupActions)));
      }
      sourceTop += height;
      final content = g.isConflict
          ? _conflictRows(p, g.group, pane, width)
          : (height > 0
              ? Text.rich(
                  _syntax.cached(
                      _sourceText(g.group, pane), mono.copyWith(color: p.text),
                      dark: Syntax.isDark(p), theme: Theming.syntaxOf(context)),
                  softWrap: false,
                  strutStyle:
                      StrutStyle.fromTextStyle(mono, forceStrutHeight: true))
              : const SizedBox.shrink());
      blocks.add(Container(
          key: g.isConflict
              ? ValueKey('merge-source-$pane-${conflict - 1}')
              : null,
          width: width,
          height: height,
          color: _sourceTint(p, g, pane),
          alignment: Alignment.topLeft,
          child: content));
    }
    final numberRail = SizedBox(
        width: 34,
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch, children: numbers));
    final deletionMarks =
        _deletionMarks().where((m) => m.pane == pane).toList();
    final connectors = _mergeConnectors(p, pane, deletionMarks);
    final actionRail = hasActions || connectors.isNotEmpty
        ? _actionRail(pane, actions, connectors)
        : null;
    final code = SingleChildScrollView(
        controller: _horizontal[pane],
        scrollDirection: Axis.horizontal,
        child: SelectionArea(
            child: SizedBox(
                width: width,
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: blocks))));
    // The horizontal bar wraps the vertical scroll view instead of sitting in
    // its content: an inner bar paints below the whole document, far outside
    // the visible pane. Out here it stays on the pane's bottom edge.
    // The reference dialog mirrors the left pane: its gutter faces the result
    // and its scrollbar sits on the outer edge. The right pane already has that
    // shape by default.
    final mirrored = pane == 0;
    final viewport = Scrollbar(
        controller: _horizontal[pane],
        notificationPredicate: (n) => n.metrics.axis == Axis.horizontal,
        child: Scrollbar(
            controller: _vertical[pane],
            thumbVisibility: true,
            scrollbarOrientation: mirrored
                ? ScrollbarOrientation.left
                : ScrollbarOrientation.right,
            child: SingleChildScrollView(
                controller: _vertical[pane],
                padding: const EdgeInsets.only(top: 6, bottom: 24),
                child: CustomPaint(
                    key: ValueKey('merge-deletion-boundaries-$pane'),
                    foregroundPainter: _DeletionBoundaries(lines: [
                      for (final mark in deletionMarks) mark.sourceLine
                    ], lineHeight: _lineHeight, color: p.deletedFragment),
                    child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (!mirrored) numberRail,
                          Expanded(child: code),
                          if (mirrored) numberRail,
                        ])))));
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (pane == 2 && actionRail != null) actionRail,
      Expanded(child: viewport),
      if (pane == 0 && actionRail != null) actionRail,
    ]);
  }

  /// The action rail mirrors the code's vertical offset, but is outside every
  /// scrollbar's hit region. Desktop hover-expanded thumbs cannot steal clicks.
  Widget _actionRail(
          int pane, List<Widget> actions, List<_MergeConnector> marks) =>
      SizedBox(
        width: marks.any((mark) => !mark.isDeletion) ? 78 : 56,
        child: Listener(
            onPointerSignal: (event) {
              if (event is! PointerScrollEvent || !_vertical[pane].hasClients) {
                return;
              }
              GestureBinding.instance.pointerSignalResolver.register(event,
                  (_) {
                final vertical = _vertical[pane];
                vertical.jumpTo((vertical.offset + event.scrollDelta.dy)
                    .clamp(0.0, vertical.position.maxScrollExtent));
                final horizontal = _horizontal[pane];
                if (horizontal.hasClients) {
                  horizontal.jumpTo((horizontal.offset + event.scrollDelta.dx)
                      .clamp(0.0, horizontal.position.maxScrollExtent));
                }
              });
            },
            child: AnimatedBuilder(
                animation: Listenable.merge([_vertical[pane], _vertical[1]]),
                builder: (context, _) {
                  final offset =
                      _vertical[pane].hasClients ? _vertical[pane].offset : 0.0;
                  final resultOffset =
                      _vertical[1].hasClients ? _vertical[1].offset : 0.0;
                  return ClipRect(
                    child: CustomPaint(
                      key: ValueKey('merge-connectors-$pane'),
                      painter: _MergeConnectors(
                          marks: marks,
                          lineHeight: _lineHeight,
                          sourceOffset: offset,
                          resultOffset: resultOffset),
                      child: Stack(clipBehavior: Clip.hardEdge, children: [
                        Positioned(
                            top: 6 - offset,
                            left: pane == 0 ? 4 : 0,
                            right: 0,
                            height: _anchors(pane).last + _lineHeight,
                            child: Stack(children: actions)),
                      ]),
                    ),
                  );
                })),
      );

  Widget _conflictRows(Palette p, MergeGroup g, int pane, double width) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (final row in g.rows)
          if ((pane == 0 ? row.ours : row.theirs) != null)
            _conflictRow(p, row, pane, width),
      ]);

  Widget _conflictRow(Palette p, MergeRow row, int pane, double width) =>
      SizedBox(
        width: width,
        height: _lineHeight,
        child: Text.rich(
          _rowSpan(p, row, pane),
          softWrap: false,
          strutStyle: StrutStyle.fromTextStyle(mono, forceStrutHeight: true),
        ),
      );

  /// One conflict line: the differing middle is tinted inside the line, so a
  /// one-character change is visible without reading both sides in full.
  TextSpan _rowSpan(Palette p, MergeRow row, int pane) {
    final mine = pane == 0 ? row.ours : row.theirs;
    final other = pane == 0 ? row.theirs : row.ours;
    final base = mono.copyWith(color: p.text);
    if (mine == null) return const TextSpan(text: '');
    if (other == null || !_highlightWords) {
      return TextSpan(text: mine, style: base);
    }
    final diff = intraLineDiff(row.ours ?? '', row.theirs ?? '');
    if (diff == null) return TextSpan(text: mine, style: base);
    final part = pane == 0 ? diff.left : diff.right;
    return TextSpan(style: base, children: [
      TextSpan(text: part.prefix),
      TextSpan(
          text: part.mid,
          style: TextStyle(backgroundColor: p.mergeConflictInline)),
      TextSpan(text: part.suffix),
    ]);
  }

  int get _currentGroupIndex {
    final indices = _differenceGroups;
    if (indices.isEmpty) return -1;
    return indices[_current < 0 ? 0 : _current];
  }

  Widget _baseStrip(Palette p) {
    final index = _currentGroupIndex;
    final base =
        index < 0 ? const <String>[] : _document.groups[index].group.baseLines;
    return Container(
        constraints: const BoxConstraints(maxHeight: 100),
        width: double.infinity,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
            color: p.bgAlt, border: Border(top: BorderSide(color: p.border))),
        child: SingleChildScrollView(
            child: SelectableText('共同祖先：${base.join('\n')}',
                style: mono.copyWith(color: p.textDim))));
  }

  /// Per-line result tints, in display-line order.
  List<Color> _resultTints(Palette p) {
    final count = math.max(1, _result.text.split('\n').length);
    final byLine = <int, Color>{};
    // 删除范围由中性灰底标记，不叠加冲突或新增色。
    final deletedLines = <int>{
      for (final mark in _deletionMarks())
        for (var line = mark.first; line <= mark.last; line++) line,
    };
    for (var gi = 0; gi < _document.groups.length; gi++) {
      final g = _document.groups[gi];
      if (!g.hasLines) continue;
      Color? tint;
      if (g.isConflict) {
        tint = g.decided ? p.addRow : p.mergeConflictRow;
      } else if (g.isChange && (g.changeAccepted == true || g.manual)) {
        tint = p.addRow;
      }
      if (tint == null) continue;
      final first = _document.lineAt(g.start);
      final last = _document.lineAt(g.end > g.start ? g.end - 1 : g.start);
      for (var line = first; line <= last && line < count; line++) {
        if (deletedLines.contains(line)) continue;
        byLine.putIfAbsent(line, () => tint!);
      }
    }
    return [for (var i = 0; i < count; i++) byLine[i] ?? Colors.transparent];
  }

  /// 把结果中的保留原文连接到源文件的删除边界。
  List<_DeletionMark> _deletionMarks() {
    final out = <_DeletionMark>[];
    final sourceRows = [0, 0, 0];
    for (final g in _document.groups) {
      if (g.hasLines) {
        final retained = _document.text.substring(g.start, g.end).split('\n');
        final first = _document.lineAt(g.start);
        for (final pane in [0, 2]) {
          final dropped = g.group.rows.any(
              (r) => r.base != null && (pane == 0 ? r.ours : r.theirs) == null);
          if (!dropped) continue;
          final source = pane == 0 ? g.group.oursLines : g.group.theirsLines;
          for (final range in deletedLineRanges(retained, source)) {
            out.add(_DeletionMark(
                pane: pane,
                sourceLine: sourceRows[pane] + range.sideLine,
                first: first + range.first,
                last: first + range.end - 1));
          }
        }
      }
      for (final pane in [0, 2]) {
        sourceRows[pane] += _sourceRowCount(g, pane);
      }
    }
    return out;
  }

  /// 用实际行范围连接修改块，删除块沿用灰色的收缩边界。
  List<_MergeConnector> _mergeConnectors(
      Palette p, int pane, List<_DeletionMark> deletions) {
    final marks = <_MergeConnector>[];
    var sourceFirst = 0;
    for (final g in _document.groups) {
      final source = pane == 0 ? g.group.oursLines : g.group.theirsLines;
      final fill = _sourceMarker(p, g, pane);
      if (fill != null) {
        final range = _resultLineRange(g);
        final first = range.first;
        final end = range.end;
        final collapsedDeletion = source.isEmpty &&
            deletions.any((mark) => mark.first >= first && mark.last < end);
        if (!collapsedDeletion && (source.isNotEmpty || end > first)) {
          marks.add(_MergeConnector(
              pane: pane,
              sourceFirst: sourceFirst,
              sourceEnd: sourceFirst + source.length,
              resultFirst: first,
              resultEnd: end,
              fill: fill));
        }
      }
      sourceFirst += _sourceRowCount(g, pane);
    }
    for (final deletion in deletions) {
      marks.add(_MergeConnector(
          pane: pane,
          sourceFirst: deletion.sourceLine,
          sourceEnd: deletion.sourceLine,
          resultFirst: deletion.first,
          resultEnd: deletion.last + 1,
          fill: p.deletedFragment,
          isDeletion: true));
    }
    return marks;
  }

  /// Display lines of non-conflicting changes that have been applied.
  /// The JetBrains result pane marks those lines with a solid gutter bar,
  /// not with the accept chip that copied them in.
  List<int> _acceptedResultLines() {
    final count = math.max(1, _result.text.split('\n').length);
    final lines = <int>[];
    for (final g in _document.groups) {
      if (!g.isChange ||
          g.isConflict ||
          g.changeAccepted != true ||
          !g.hasLines) {
        continue;
      }
      final first = _document.lineAt(g.start);
      final last = _document.lineAt(g.end > g.start ? g.end - 1 : g.start);
      for (var line = first; line <= last && line < count; line++) {
        lines.add(line);
      }
    }
    return lines;
  }

  Widget _resultPane(Palette p, double width) {
    final text = _result.text;
    final count = math.max(1, text.split('\n').length);
    final tints = _resultTints(p);
    final deletions = _deletionMarks();
    final boundaries = [
      for (final pane in [0, 2])
        for (final mark in _mergeConnectors(
            p, pane, deletions.where((mark) => mark.pane == pane).toList()))
          if (mark.resultFirst == mark.resultEnd) mark,
    ];
    final numbers = CustomPaint(
        key: const ValueKey('merge-result-stripes'),
        painter: _ResultStripes(
            lines: _acceptedResultLines(),
            lineHeight: _lineHeight,
            color: p.green),
        child: SizedBox(
            width: 44,
            child: Column(children: [
              for (var i = 0; i < count; i++)
                Container(
                    height: _lineHeight,
                    alignment: Alignment.centerRight,
                    decoration: BoxDecoration(
                        border: Border(
                            left: BorderSide(width: 3, color: tints[i]))),
                    child: Text('${i + 1} ',
                        style: mono.copyWith(color: p.textDim),
                        strutStyle: StrutStyle.fromTextStyle(mono,
                            forceStrutHeight: true))),
            ])));
    final code = SingleChildScrollView(
        controller: _horizontal[1],
        scrollDirection: Axis.horizontal,
        child: SizedBox(
            width: width,
            child: Stack(children: [
              Column(children: [
                for (var i = 0; i < count; i++)
                  SizedBox(
                      width: width,
                      height: _lineHeight,
                      child: ColoredBox(color: tints[i])),
              ]),
              CodeField(
                  key: const ValueKey('merge-result'),
                  controller: _result,
                  focusNode: _focus,
                  indentUnit: _indent,
                  onChanged: (text) => setState(() => _document.edit(text))),
            ])));
    return Scrollbar(
        controller: _horizontal[1],
        notificationPredicate: (n) => n.metrics.axis == Axis.horizontal,
        child: Scrollbar(
            controller: _vertical[1],
            thumbVisibility: true,
            child: SingleChildScrollView(
                controller: _vertical[1],
                padding: const EdgeInsets.only(top: 6, bottom: 24),
                child: CustomPaint(
                    key: const ValueKey('merge-result-deletions'),
                    painter: _ResultDeletions(
                        marks: deletions,
                        lineHeight: _lineHeight,
                        fill: p.deletedFragment),
                    foregroundPainter: _ResultBoundaries(
                        marks: boundaries, lineHeight: _lineHeight),
                    child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [numbers, Expanded(child: code)])))));
  }

  Widget _mergeActions(Palette p) => _bar(p, [
        if (_document.undecided > 0)
          Text('${_document.undecided} 处冲突未处理',
              style: ui.copyWith(color: p.yellow, fontSize: 11)),
        if (_conflictCount > 0) ...[
          _Btn(label: '全部采用我方', onTap: () => _setAll(true)),
          _Btn(label: '全部采用对方', onTap: () => _setAll(false)),
        ],
        _Btn(label: '取消', onTap: widget.onClose),
        _Btn(
            label: '应用',
            primary: true,
            onTap: _document.undecided > 0
                ? null
                : () => widget.onResolveWith(_document.text)),
      ]);

  /// The reference dialog's totals: non-conflict changes, then conflicts.
  /// Whether they are still pending is carried by the colour and the bottom
  /// hint, so the counts stay short enough for the toolbar's right edge.
  String get _summary {
    final changes = _changeCount > 0 ? '$_changeCount 个更改。' : '';
    final conflicts = _conflictCount > 0 ? '$_conflictCount 个冲突。' : '';
    return '$changes$conflicts'.isEmpty ? '无更改。' : '$changes$conflicts';
  }

  Widget _bar(Palette p, List<Widget> children) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration:
          BoxDecoration(border: Border(top: BorderSide(color: p.border))),
      child: Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: children));
}

class _GutterButton extends StatefulWidget {
  const _GutterButton({
    required this.label,
    required this.tooltip,
    required this.active,
    required this.onTap,
  });

  final String label;
  final String tooltip;
  final bool active;
  final VoidCallback onTap;

  @override
  State<_GutterButton> createState() => _GutterButtonState();
}

class _GutterButtonState extends State<_GutterButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = Theming.of(context);
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            width: 26,
            height: 20,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: widget.active ? p.accent : (_hover ? p.bgHover : null),
              border: Border.all(
                  color:
                      widget.active || _hover ? p.textDim : Colors.transparent),
              borderRadius: BorderRadius.circular(4),
            ),
            // Drawn, not typed: at any font size » came out a fraction of ✕.
            child: CustomPaint(
              size: const Size(16, 16),
              painter: _GutterGlyph(widget.label,
                  widget.active ? const Color(0xFFFFFFFF) : p.text),
            ),
          ),
        ),
      ),
    );
  }
}

/// » « »« are the JetBrains ApplyNonConflicts icons (filled chevrons from the
/// 16×16 SVGs). ✕ ↑ ↓ stay thin strokes with flat cut ends.
class _GutterGlyph extends CustomPainter {
  _GutterGlyph(this.label, this.color);
  final String label;
  final Color color;

  static const _view = 16.0;

  // applyNotConflictsLeft.svg, group translate(2 3).
  static const _applyLeft = <List<Offset>>[
    [
      Offset(3.675, 3),
      Offset(2.5, 4.175),
      Offset(6.317, 8),
      Offset(2.5, 11.825),
      Offset(3.675, 13),
      Offset(8.675, 8),
    ],
    [
      Offset(8.175, 3),
      Offset(7, 4.175),
      Offset(10.817, 8),
      Offset(7, 11.825),
      Offset(8.175, 13),
      Offset(13.175, 8),
    ],
  ];

  // applyNotConflictsRight.svg, matrix(-1 0 0 1 14 3).
  static const _applyRight = <List<Offset>>[
    [
      Offset(12.325, 3),
      Offset(13.5, 4.175),
      Offset(9.683, 8),
      Offset(13.5, 11.825),
      Offset(12.325, 13),
      Offset(7.325, 8),
    ],
    [
      Offset(7.825, 3),
      Offset(9, 4.175),
      Offset(5.183, 8),
      Offset(9, 11.825),
      Offset(7.825, 13),
      Offset(2.825, 8),
    ],
  ];

  // applyNotConflicts.svg. The lower pair is already mirrored into viewBox space.
  static const _applyAll = <List<Offset>>[
    [
      Offset(1.868, 2),
      Offset(1, 2.868),
      Offset(3.818, 5.692),
      Offset(1, 8.517),
      Offset(1.868, 9.385),
      Offset(5.56, 5.692),
    ],
    [
      Offset(4.945, 2),
      Offset(4.077, 2.868),
      Offset(6.895, 5.692),
      Offset(4.077, 8.517),
      Offset(4.945, 9.385),
      Offset(8.637, 5.692),
    ],
    [
      Offset(14.132, 6.62),
      Offset(15, 7.488),
      Offset(12.182, 10.312),
      Offset(15, 13.137),
      Offset(14.132, 14.005),
      Offset(10.44, 10.312),
    ],
    [
      Offset(11.055, 6.62),
      Offset(11.923, 7.488),
      Offset(9.104, 10.312),
      Offset(11.923, 13.137),
      Offset(11.055, 14.005),
      Offset(7.363, 10.312),
    ],
  ];

  static void _fill(
      Canvas canvas, Size size, Color color, List<List<Offset>> polygons) {
    final sx = size.width / _view;
    final sy = size.height / _view;
    final path = Path();
    for (final poly in polygons) {
      path.moveTo(poly.first.dx * sx, poly.first.dy * sy);
      for (final point in poly.skip(1)) {
        path.lineTo(point.dx * sx, point.dy * sy);
      }
      path.close();
    }
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (label == '»') {
      _fill(canvas, size, color, _applyLeft);
      return;
    }
    if (label == '«') {
      _fill(canvas, size, color, _applyRight);
      return;
    }
    if (label == '»«') {
      _fill(canvas, size, color, _applyAll);
      return;
    }
    final path = Path();
    if (label == '✕') {
      path
        ..moveTo(3, 3)
        ..lineTo(11, 11)
        ..moveTo(11, 3)
        ..lineTo(3, 11);
    } else {
      path
        ..moveTo(3, 9)
        ..lineTo(7, 5)
        ..lineTo(11, 9);
      if (label == '↓') {
        canvas.translate(0, size.height);
        canvas.scale(1, -1);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeCap = StrokeCap.butt
        ..strokeJoin = StrokeJoin.miter,
    );
  }

  @override
  bool shouldRepaint(_GutterGlyph old) =>
      old.label != label || old.color != color;
}

/// Solid gutter bars for lines copied in by "apply non-conflicting changes".
/// Sits on the right of the result line numbers, between them and the code.
class _ResultStripes extends CustomPainter {
  _ResultStripes({
    required this.lines,
    required this.lineHeight,
    required this.color,
  });

  final List<int> lines;
  final double lineHeight;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (lines.isEmpty || size.width < 3) return;
    final paint = Paint()..color = color;
    final width = 3.0;
    final left = size.width - width;
    for (final line in lines) {
      canvas.drawRect(
        Rect.fromLTWH(left, line * lineHeight, width, lineHeight),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_ResultStripes old) =>
      old.lineHeight != lineHeight ||
      old.color != color ||
      old.lines.length != lines.length ||
      !_sameLines(old.lines);

  bool _sameLines(List<int> other) {
    for (var i = 0; i < lines.length; i++) {
      if (lines[i] != other[i]) return false;
    }
    return true;
  }
}

class _DeletionMark {
  const _DeletionMark({
    required this.pane,
    required this.sourceLine,
    required this.first,
    required this.last,
  });

  final int pane;
  final int sourceLine;
  final int first;
  final int last;
}

/// 保留原文整块铺灰，连接形状只画在栏间。
class _ResultDeletions extends CustomPainter {
  _ResultDeletions({
    required this.marks,
    required this.lineHeight,
    required this.fill,
  });

  final List<_DeletionMark> marks;
  final double lineHeight;
  final Color fill;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = fill;
    for (final mark in marks) {
      canvas.drawRect(
          Rect.fromLTWH(0, mark.first * lineHeight, size.width,
              (mark.last - mark.first + 1) * lineHeight),
          paint);
    }
  }

  @override
  bool shouldRepaint(_ResultDeletions old) =>
      old.lineHeight != lineHeight || old.fill != fill || old.marks != marks;
}

/// 删除侧只显示文件中的行边界。
class _DeletionBoundaries extends CustomPainter {
  _DeletionBoundaries({
    required this.lines,
    required this.lineHeight,
    required this.color,
  });

  final List<int> lines;
  final double lineHeight;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    for (final line in lines) {
      canvas.drawRect(
          Rect.fromLTWH(0, line * lineHeight, size.width, 1), paint);
    }
  }

  @override
  bool shouldRepaint(_DeletionBoundaries old) =>
      old.lineHeight != lineHeight || old.color != color || old.lines != lines;
}

class _MergeConnector {
  const _MergeConnector({
    required this.pane,
    required this.sourceFirst,
    required this.sourceEnd,
    required this.resultFirst,
    required this.resultEnd,
    required this.fill,
    this.isDeletion = false,
  });

  final int pane;
  final int sourceFirst;
  final int sourceEnd;
  final int resultFirst;
  final int resultEnd;
  final Color fill;
  final bool isDeletion;
}

/// 中间尚未采用的插入块以横线表示，不填充后面的上下文。
class _ResultBoundaries extends CustomPainter {
  _ResultBoundaries({required this.marks, required this.lineHeight});

  final List<_MergeConnector> marks;
  final double lineHeight;

  @override
  void paint(Canvas canvas, Size size) {
    for (final mark in marks) {
      final top = math.max(0.0, mark.resultFirst * lineHeight - 1);
      canvas.drawRect(
          Rect.fromLTWH(0, top, size.width, 1), Paint()..color = mark.fill);
    }
  }

  @override
  bool shouldRepaint(_ResultBoundaries old) =>
      old.lineHeight != lineHeight || old.marks != marks;
}

/// 栏间曲面连接两侧代码块，跟随各自的滚动位置。
class _MergeConnectors extends CustomPainter {
  _MergeConnectors({
    required this.marks,
    required this.lineHeight,
    required this.sourceOffset,
    required this.resultOffset,
  });

  final List<_MergeConnector> marks;
  final double lineHeight;
  final double sourceOffset;
  final double resultOffset;

  @override
  void paint(Canvas canvas, Size size) {
    for (final mark in marks) {
      var sourceTop = 6 + mark.sourceFirst * lineHeight - sourceOffset;
      final sourceBottom = 6 + mark.sourceEnd * lineHeight - sourceOffset;
      var top = 6 + mark.resultFirst * lineHeight - resultOffset;
      final bottom = 6 + mark.resultEnd * lineHeight - resultOffset;
      if (mark.sourceFirst == mark.sourceEnd) sourceTop--;
      if (mark.resultFirst == mark.resultEnd) top--;
      canvas.save();
      if (mark.pane == 2) {
        canvas.translate(size.width, 0);
        canvas.scale(-1, 1);
      }
      final strip = mark.isDeletion ? 0.0 : math.max(0.0, size.width - 22);
      final curve = size.width - strip;
      final path = Path()
        ..moveTo(0, sourceTop)
        ..lineTo(strip, sourceTop)
        ..cubicTo(strip + curve * 0.3, sourceTop, strip + curve * 0.7, top,
            size.width, top)
        ..lineTo(size.width, bottom)
        ..cubicTo(strip + curve * 0.7, bottom, strip + curve * 0.3,
            sourceBottom, strip, sourceBottom)
        ..lineTo(0, sourceBottom)
        ..close();
      canvas.drawPath(path, Paint()..color = mark.fill);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_MergeConnectors old) =>
      old.lineHeight != lineHeight ||
      old.sourceOffset != sourceOffset ||
      old.resultOffset != resultOffset ||
      old.marks != marks;
}

class _NavButton extends StatelessWidget {
  const _NavButton(
      {required this.label, required this.tooltip, required this.onTap});
  final String label;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = Theming.of(context);
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        cursor:
            onTap == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(5),
            child: CustomPaint(
              size: const Size(16, 16),
              painter: _GutterGlyph(label,
                  onTap == null ? p.textDim.withValues(alpha: 0.4) : p.text),
            ),
          ),
        ),
      ),
    );
  }
}

class _IconText extends StatelessWidget {
  const _IconText({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = Theming.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Text(label, style: ui.copyWith(color: p.textDim)),
      ),
    );
  }
}

/// A flat toolbar action. Toggles stay legible when off instead of vanishing,
/// so the user can always tell which view options are available.
class _ToolText extends StatelessWidget {
  const _ToolText({
    required this.label,
    required this.onTap,
    this.active = false,
    this.tooltip,
  });

  final String label;
  final VoidCallback? onTap;
  final bool active;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final p = Theming.of(context);
    final enabled = onTap != null;
    final color = !enabled
        ? p.textDim.withValues(alpha: 0.4)
        : (active ? p.accent : p.text);
    return Tooltip(
      message: tooltip ?? label,
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: GestureDetector(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
            child: Text(label, style: ui.copyWith(color: color, fontSize: 11)),
          ),
        ),
      ),
    );
  }
}

class _Btn extends StatefulWidget {
  const _Btn({required this.label, required this.onTap, this.primary = false});
  final String label;
  final VoidCallback? onTap;
  final bool primary;

  @override
  State<_Btn> createState() => _BtnState();
}

class _BtnState extends State<_Btn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = Theming.of(context);
    final enabled = widget.onTap != null;
    // A disabled primary drops the accent entirely rather than fading it: a
    // washed-out blue still reads as clickable, and a primary button that does
    // nothing when pressed is worse than one that is plainly greyed out.
    final bg = widget.primary && enabled
        ? p.accent
        : (_hover && enabled ? p.bgHover : p.bgElev);

    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: bg,
            border:
                Border.all(color: widget.primary && enabled ? bg : p.border),
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
