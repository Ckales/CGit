import 'dart:math' as math;

import 'git_text.dart';

/// One [MergeGroup] plus the state the editor keeps for it: where it currently
/// sits in the result text, and what the user decided.
///
/// Offsets refer to the current document, not to any source file. The model
/// never writes the worktree; applying the result stays explicit.
class MergeGroupState {
  MergeGroupState(this.group,
      {this.hasLines = false, this.useBaseForUnresolved = false});

  final MergeGroup group;
  final bool useBaseForUnresolved;
  int start = 0;
  int end = 0;

  /// Whether this group currently owns at least one line of the result.
  bool hasLines;

  /// Conflict decisions: null undecided, true merged, false dropped. Two
  /// independent tri-states because "take both" is a real outcome and rejecting
  /// a looked-at side differs from not having looked yet.
  bool? ours;
  bool? theirs;

  /// A clean change is pending until explicitly accepted or ignored.
  bool? changeAccepted;

  /// Typed over, so the group is settled regardless of its conflict state.
  bool manual = false;

  bool get isConflict => group.isConflict;
  bool get isChange => group.isChange;
  bool get decided => manual || !isConflict || (ours != null && theirs != null);

  List<String> get resultLines {
    switch (group.kind) {
      case MergeGroupKind.common:
        return group.baseLines;
      case MergeGroupKind.bothSame:
      case MergeGroupKind.oursOnly:
        return changeAccepted == true ? group.oursLines : group.baseLines;
      case MergeGroupKind.theirsOnly:
        return changeAccepted == true ? group.theirsLines : group.baseLines;
      case MergeGroupKind.conflict:
        // An unresolved three-way change starts from the ancestor. Showing a
        // side here would make an unmade decision look already accepted.
        // Ignoring both side changes likewise preserves the ancestor.
        if (useBaseForUnresolved && ours != true && theirs != true) {
          return group.baseLines;
        }
        if (ours == null && theirs == null) {
          return group.oursLines;
        }
        return [
          if (ours == true) ...group.oursLines,
          if (theirs == true) ...group.theirsLines,
        ];
    }
  }

  MergeGroupState copy() => MergeGroupState(group,
      hasLines: hasLines, useBaseForUnresolved: useBaseForUnresolved)
    ..start = start
    ..end = end
    ..ours = ours
    ..theirs = theirs
    ..changeAccepted = changeAccepted
    ..manual = manual;
}

class MergeDocument {
  /// Marker fallback: patch import, and any conflict whose index stages are
  /// unavailable. Base text only exists in diff3-style markers here.
  MergeDocument(ParsedConflicts parsed) {
    baseAvailable = parsed.blocks
        .any((b) => b.type == BlockType.conflict && b.base.isNotEmpty);
    _build(_groupsFromMarkers(parsed.blocks),
        useBaseForUnresolved: baseAvailable);
  }

  /// The real three-way model. [base] is null for add/add conflicts, where git
  /// has no common ancestor; an empty base still yields a sensible all-add
  /// result.
  MergeDocument.threeWay({
    String? base,
    required String ours,
    required String theirs,
  }) : baseAvailable = base != null {
    _build(threeWayMerge(base: base ?? '', ours: ours, theirs: theirs).groups,
        useBaseForUnresolved: true);
  }

  late String text;
  final groups = <MergeGroupState>[];
  late final bool baseAvailable;
  late List<int> _conflictGroups;
  bool _terminalNewline = false;
  final _undo = <(String, List<MergeGroupState>, bool)>[];
  final _redo = <(String, List<MergeGroupState>, bool)>[];

  int get conflictCount => _conflictGroups.length;
  int get undecided => _conflictGroups.where((i) => !groups[i].decided).length;
  bool get hasConflict => _conflictGroups.isNotEmpty;
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  /// Conflict groups in file order; each carries its current result range.
  List<MergeGroupState> get conflictStates =>
      [for (final i in _conflictGroups) groups[i]];

  /// Group indices of the conflicts, parallel to [conflictStates].
  List<int> get conflictGroupIndices => List.unmodifiable(_conflictGroups);

  /// All modified groups in file order, including clean and identical edits.
  List<int> get differenceGroupIndices => [
        for (var i = 0; i < groups.length; i++)
          if (groups[i].isChange) i,
      ];

  /// Non-conflict changes in file order, initially left out of the result.
  Iterable<MergeGroupState> get changeStates =>
      groups.where((g) => g.isChange && !g.isConflict);

  int get pendingChangeCount =>
      changeStates.where((g) => g.changeAccepted == null && !g.manual).length;

  void _build(List<MergeGroup> source, {bool useBaseForUnresolved = false}) {
    groups
      ..clear()
      ..addAll(source.map((g) =>
          MergeGroupState(g, useBaseForUnresolved: useBaseForUnresolved)));

    final lines = <String>[];
    final spans = <(int, int)>[];
    for (final g in groups) {
      final rl = g.resultLines;
      final from = lines.length;
      lines.addAll(rl);
      spans.add((from, lines.length));
      g.hasLines = rl.isNotEmpty;
    }
    text = lines.join('\n');
    // An empty final line means the source ended with a newline even when the
    // current result is literally "" (all groups emptied), which decides
    // whether a later insertion needs a separator at EOF.
    _terminalNewline =
        text.endsWith('\n') || (lines.isNotEmpty && lines.last.isEmpty);

    final starts = <int>[0];
    for (final match in '\n'.allMatches(text)) {
      starts.add(match.end);
    }
    for (var i = 0; i < groups.length; i++) {
      final (from, to) = spans[i];
      final g = groups[i];
      if (to > from) {
        g.start = starts[from];
        // The last line of the group ends before the separator that the join
        // inserted; excluding it is what makes a later replacement local.
        g.end = to < starts.length ? starts[to] - 1 : text.length;
      } else {
        g.start = from < starts.length ? starts[from] : text.length;
        g.end = g.start;
      }
    }
    _conflictGroups = [
      for (var i = 0; i < groups.length; i++)
        if (groups[i].isConflict) i
    ];
  }

  static List<MergeGroup> _groupsFromMarkers(List<ConflictBlock> blocks) {
    final out = <MergeGroup>[];
    for (final b in blocks) {
      if (b.type == BlockType.ctx) {
        out.add(MergeGroup(
          kind: MergeGroupKind.common,
          rows: [
            for (final line in b.lines)
              MergeRow(base: line, ours: line, theirs: line)
          ],
          baseLines: b.lines,
          oursLines: b.lines,
          theirsLines: b.lines,
        ));
      } else {
        final n =
            math.max(math.max(b.ours.length, b.theirs.length), b.base.length);
        out.add(MergeGroup(
          kind: MergeGroupKind.conflict,
          rows: [
            for (var k = 0; k < n; k++)
              MergeRow(
                base: k < b.base.length ? b.base[k] : null,
                ours: k < b.ours.length ? b.ours[k] : null,
                theirs: k < b.theirs.length ? b.theirs[k] : null,
              )
          ],
          baseLines: b.base,
          oursLines: b.ours,
          theirsLines: b.theirs,
        ));
      }
    }
    return out;
  }

  (String, List<MergeGroupState>, bool) _snapshot() => (
        text,
        groups.map((g) => g.copy()).toList(),
        _terminalNewline,
      );

  void _record() {
    _undo.add(_snapshot());
    _redo.clear();
  }

  void _restore((String, List<MergeGroupState>, bool) state) {
    text = state.$1;
    _terminalNewline = state.$3;
    groups
      ..clear()
      ..addAll(state.$2.map((g) => g.copy()));
    _conflictGroups = [
      for (var i = 0; i < groups.length; i++)
        if (groups[i].isConflict) i
    ];
  }

  void undo() {
    if (!canUndo) return;
    _redo.add(_snapshot());
    _restore(_undo.removeLast());
  }

  void redo() {
    if (!canRedo) return;
    _undo.add(_snapshot());
    _restore(_redo.removeLast());
  }

  /// A text input event is a single replacement (including paste/selection).
  /// Track its boundaries so later side choices leave surrounding edits alone.
  void edit(String next) {
    if (next == text) return;
    _record();
    var start = 0;
    while (start < text.length &&
        start < next.length &&
        text.codeUnitAt(start) == next.codeUnitAt(start)) {
      start++;
    }
    var end = text.length;
    var nextEnd = next.length;
    while (end > start &&
        nextEnd > start &&
        text.codeUnitAt(end - 1) == next.codeUnitAt(nextEnd - 1)) {
      end--;
      nextEnd--;
    }
    final inserted = nextEnd - start;
    final delta = inserted - (end - start);
    for (final g in groups) {
      final touches = start == end
          ? start >= g.start && start <= g.end
          : start < g.end && end > g.start;
      if (touches) g.manual = true;
      final oldStart = g.start;
      final oldEnd = g.end;
      if (end < oldStart || (end == oldStart && start != end)) {
        g.start += delta;
        g.end += delta;
      } else if (start <= g.end) {
        // Inserted text belongs to this group only if the edit began in it.
        if (start < oldStart) g.start = start + inserted;
        if (end <= g.end) {
          g.end += delta;
        } else {
          g.end = start + inserted;
        }
        g.end = g.end.clamp(g.start, next.length);
        if (touches) {
          g.hasLines =
              !(g.start == g.end && (start < oldStart || end > oldEnd));
        }
      }
    }
    text = next;
    _terminalNewline = next.endsWith('\n');
  }

  /// [index] is the conflict ordinal (0-based, file order), not a group index.
  void choose(int index, {bool? ours, bool? theirs}) {
    if (index < 0 || index >= _conflictGroups.length) return;
    _record();
    _choose(index, ours: ours, theirs: theirs);
  }

  void chooseAll({required bool ours}) {
    _record();
    for (var i = 0; i < _conflictGroups.length; i++) {
      _choose(i, ours: ours, theirs: !ours);
    }
  }

  void _choose(int conflictIndex, {bool? ours, bool? theirs}) {
    final gi = _conflictGroups[conflictIndex];
    final g = groups[gi];
    g.ours = ours ?? g.ours;
    g.theirs = theirs ?? g.theirs;
    // Accepting one side is a complete decision; a second accept appends both.
    if (ours == true && g.theirs == null) g.theirs = false;
    if (theirs == true && g.ours == null) g.ours = false;
    g.manual = false;
    _replace(gi);
  }

  /// Accept or ignore one clean change, leaving every other group untouched.
  void chooseChange(int groupIndex, {required bool accept}) {
    final g = groups[groupIndex];
    if (!g.isChange || g.isConflict) return;
    _record();
    g.changeAccepted = accept;
    g.manual = false;
    _replace(groupIndex);
  }

  /// One undo step for the pending clean changes. Manual edits and explicit
  /// decisions (including conflict decisions) remain exactly as the user left them.
  ///
  /// [ours] limits the bulk to changes made by one side; null accepts both.
  /// Identical edits count for either side because accepting them is idempotent.
  void acceptNonConflicting({bool? ours}) {
    if (pendingChangeCount == 0) return;
    _record();
    for (var i = 0; i < groups.length; i++) {
      final g = groups[i];
      if (!g.isChange || g.isConflict || g.manual || g.changeAccepted != null) {
        continue;
      }
      if (ours == true && g.group.kind == MergeGroupKind.theirsOnly) continue;
      if (ours == false && g.group.kind == MergeGroupKind.oursOnly) continue;
      g.changeAccepted = true;
      _replace(i);
    }
  }

  void _replace(int groupIndex) {
    final g = groups[groupIndex];
    final lines = g.resultLines;
    var start = g.start;
    var end = g.end;
    var replacement = lines.join('\n');
    var bodyStart = start;
    if (g.hasLines && lines.isEmpty) {
      if (end < text.length && text[end] == '\n') {
        end++;
      } else if (start > 0 && text[start - 1] == '\n') {
        start--;
      }
      bodyStart = start;
    } else if (!g.hasLines && lines.isNotEmpty) {
      final prefix = start > 0 && text[start - 1] != '\n' ? '\n' : '';
      final suffix = (start < text.length && text[start] != '\n') ||
              (start == text.length &&
                  (text.endsWith('\n') || (text.isEmpty && _terminalNewline)))
          ? '\n'
          : '';
      replacement = '$prefix$replacement$suffix';
      bodyStart += prefix.length;
    }
    final delta = replacement.length - (end - start);
    for (var i = 0; i < groups.length; i++) {
      if (i == groupIndex) continue;
      final other = groups[i];
      // Earlier empty groups anchored at this same offset stay put; groups at
      // or after the replaced range move with the new length.
      if (i < groupIndex &&
          !other.hasLines &&
          other.start == start &&
          other.end == start) {
        continue;
      }
      if (other.start >= end) {
        other.start += delta;
        other.end += delta;
      }
    }
    text = text.replaceRange(start, end, replacement);
    g.start = bodyStart;
    g.end = bodyStart + lines.join('\n').length;
    g.hasLines = lines.isNotEmpty;
  }

  String? _indexedText;
  List<int> _lineStarts = const [];
  int lineAt(int offset) {
    if (_indexedText != text) {
      _indexedText = text;
      _lineStarts = [0, for (final match in '\n'.allMatches(text)) match.end];
    }
    var low = 0;
    var high = _lineStarts.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (_lineStarts[mid] <= offset) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low - 1;
  }
}
