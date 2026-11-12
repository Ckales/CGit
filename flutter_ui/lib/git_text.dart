import 'src/rust/api/git.dart' show GraphCommit;

export 'src/rust/api/git.dart' show GraphCommit;

/* Pure text/graph helpers, free of Flutter imports so they can be unit-tested
   with `flutter test`. These are the functions that silently
   corrupt user data when they're wrong. */

/* ---------- partial (line-level) staging ---------- */

class HunkHeader {
  const HunkHeader(this.oldStart, this.newStart, this.tail);
  final int oldStart;
  final int newStart;
  final String tail;
}

final _hunkRe = RegExp(r'^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@(.*)$');

HunkHeader? parseHunkHeader(String line) {
  final m = _hunkRe.firstMatch(line);
  if (m == null) return null;
  return HunkHeader(int.parse(m[1]!), int.parse(m[2]!), m[3] ?? '');
}

/// Rebuild a hunk containing only the selected body lines, so `git apply` stages
/// (or with --reverse, unstages) exactly those lines.
///
/// An unselected `+` line is dropped — that addition stays out of the index.
/// An unselected `-` line becomes context — that deletion is not applied.
/// `keep` holds indices into the hunk body (header excluded).
String? buildPartialHunk(String hunk, Set<int> keep) {
  final lines = hunk.replaceFirst(RegExp(r'\n$'), '').split('\n');
  final head = parseHunkHeader(lines[0]);
  if (head == null) return null;

  final out = <String>[];
  var oldCount = 0;
  var newCount = 0;
  var kept = 0;
  var lastKept = false;

  final body = lines.sublist(1);
  for (var i = 0; i < body.length; i++) {
    final line = body[i];
    final kind = line.isEmpty ? ' ' : line[0];

    if (kind == '\\') {
      // "\ No newline at end of file" qualifies the line above it.
      if (lastKept) out.add(line);
      continue;
    }
    if (kind == '+') {
      if (keep.contains(i)) {
        out.add(line);
        newCount++;
        kept++;
        lastKept = true;
      } else {
        lastKept = false;
      }
      continue;
    }
    if (kind == '-') {
      if (keep.contains(i)) {
        out.add(line);
        oldCount++;
        kept++;
      } else {
        out.add(' ${line.substring(1)}');
        oldCount++;
        newCount++;
      }
      lastKept = true;
      continue;
    }
    out.add(line);
    oldCount++;
    newCount++;
    lastKept = true;
  }

  if (kept == 0) return null;
  return '@@ -${head.oldStart},$oldCount +${head.newStart},$newCount @@${head.tail}\n'
      '${out.join('\n')}\n';
}

/// Body-line indices of a hunk that are selectable (i.e. +/- lines).
List<int> selectableLines(String hunk) {
  final body =
      hunk.replaceFirst(RegExp(r'\n$'), '').split('\n').skip(1).toList();
  final out = <int>[];
  for (var i = 0; i < body.length; i++) {
    if (body[i].startsWith('+') || body[i].startsWith('-')) out.add(i);
  }
  return out;
}

/// The pickable line indices between two endpoints, inclusive, in either
/// direction. Context lines inside the span are skipped: a shift-range means
/// "these changes", and a context line is not a change you can stage.
Set<int> rangeBetween(List<int> pickable, int a, int b) {
  final lo = a < b ? a : b;
  final hi = a < b ? b : a;
  return pickable.where((i) => i >= lo && i <= hi).toSet();
}

/* ---------- side-by-side diff ---------- */

class Patch {
  const Patch(this.header, this.hunks);
  final String header;
  final List<String> hunks;
}

/// Split a unified patch into its file header and hunks, verbatim.
Patch splitPatchText(String text) {
  final lines = text.replaceFirst(RegExp(r'\n$'), '').split('\n');
  final header = <String>[];
  final hunks = <String>[];
  List<String>? cur;

  for (final line in lines) {
    if (line.startsWith('@@')) {
      if (cur != null) hunks.add('${cur.join('\n')}\n');
      cur = [line];
    } else if (cur != null) {
      cur.add(line);
    } else {
      header.add(line);
    }
  }
  if (cur != null) hunks.add('${cur.join('\n')}\n');
  return Patch(header.isEmpty ? '' : '${header.join('\n')}\n', hunks);
}

class DiffCell {
  const DiffCell(this.no, this.text);
  final int no;
  final String text;
}

enum RowType { ctx, add, del, mod }

class DiffRow {
  const DiffRow(this.type, this.left, this.right, this.picks);
  final RowType type;
  final DiffCell? left;
  final DiffCell? right;
  final List<int> picks;
}

class PairedHunk {
  const PairedHunk(this.head, this.rows);
  final HunkHeader head;
  final List<DiffRow> rows;
}

/// Turn a unified hunk into aligned left/right rows for a two-column view.
///
/// A run of `-` lines is paired positionally against the run of `+` lines that
/// follows it, which is what makes an edited line show up as one row with both
/// versions instead of two unrelated rows. A side's line number only advances
/// when that side has a line.
///
/// Pure deletions are not padded with an empty cell on the new side. That gap
/// is what made a removal look like an insertion (a full-height blank) or like
/// a hatch floating next to the surviving code. [deletionFragments] turns the
/// same run into one polygon on the divider, the way the side-by-side viewer
/// draws a deleted fragment.
///
/// `picks` carries the original body indices, so [buildPartialHunk] can stage
/// exactly the rows the user selected.
PairedHunk? pairHunkLines(String hunk) {
  final lines = hunk.replaceFirst(RegExp(r'\n$'), '').split('\n');
  final head = parseHunkHeader(lines[0]);
  if (head == null) return null;
  final body = lines.sublist(1);

  var oldNo = head.oldStart;
  var newNo = head.newStart;
  final rows = <DiffRow>[];
  var i = 0;

  void skipMarkers() {
    while (i < body.length && body[i].startsWith('\\')) {
      i++;
    }
  }

  while (i < body.length) {
    final line = body[i];
    if (line.startsWith('\\')) {
      i++;
      continue;
    }
    if (!line.startsWith('+') && !line.startsWith('-')) {
      final text = line.startsWith(' ') ? line.substring(1) : line;
      rows.add(DiffRow(
        RowType.ctx,
        DiffCell(oldNo++, text),
        DiffCell(newNo++, text),
        const [],
      ));
      i++;
      continue;
    }

    final start = i;
    final dels = <({String text, int idx})>[];
    while (i < body.length && body[i].startsWith('-')) {
      dels.add((text: body[i].substring(1), idx: i));
      i++;
    }
    skipMarkers();
    final adds = <({String text, int idx})>[];
    while (i < body.length && body[i].startsWith('+')) {
      adds.add((text: body[i].substring(1), idx: i));
      i++;
    }
    skipMarkers();
    // Belt and braces: never leave the loop without consuming input.
    if (i == start) {
      i++;
      continue;
    }

    final n = dels.length > adds.length ? dels.length : adds.length;
    for (var k = 0; k < n; k++) {
      final d = k < dels.length ? dels[k] : null;
      final a = k < adds.length ? adds[k] : null;
      // A deletion with nothing inserted in the whole run is not a row.
      // Emitting one would pad the new side with a blank the height of the
      // removed code, which is the "this looks added" reading. A leftover
      // inside a modification (more `-` than `+`) still needs its row so the
      // two versions stay aligned; only the pure run is a fragment.
      if (d != null && a == null && adds.isEmpty) {
        oldNo++;
        continue;
      }
      final picks = <int>[];
      if (d != null) picks.add(d.idx);
      if (a != null) picks.add(a.idx);
      rows.add(DiffRow(
        d != null && a != null
            ? RowType.mod
            : (d != null ? RowType.del : RowType.add),
        d == null ? null : DiffCell(oldNo++, d.text),
        a == null ? null : DiffCell(newNo++, a.text),
        picks,
      ));
    }
  }
  return PairedHunk(head, rows);
}

/// One removed run, drawn on the divider between the two panes.
///
/// [before] is the number of paired rows above the run, so the polygon's left
/// edge starts there. [lines] is how many old lines were removed. The right
/// edge collapses to a point on the boundary after [before]: the new file has
/// no lines there. That is the JetBrains deleted fragment — a gray trapezoid
/// in the stripe, not a blank row and not a hatch beside the surviving code.
class DeletionFragment {
  const DeletionFragment(this.before, this.lines, this.picks);
  final int before;
  final int lines;

  /// Body indices of the `-` lines, so clicking the fragment stages the deletion.
  final List<int> picks;
}

/// Removed runs that [pairHunkLines] deliberately does not turn into rows.
///
/// A deletion that sits inside a modification (more `-` than `+`) is not one of
/// these: that leftover still needs a row so the two versions stay aligned.
/// Only a run with no following `+` lines is a fragment.
List<DeletionFragment> deletionFragments(String hunk) {
  final lines = hunk.replaceFirst(RegExp(r'\n$'), '').split('\n');
  if (parseHunkHeader(lines[0]) == null) return const [];
  final body = lines.sublist(1);

  final out = <DeletionFragment>[];
  var i = 0;
  var before = 0;

  void skipMarkers() {
    while (i < body.length && body[i].startsWith('\\')) {
      i++;
    }
  }

  while (i < body.length) {
    if (body[i].startsWith('\\')) {
      i++;
      continue;
    }
    if (!body[i].startsWith('+') && !body[i].startsWith('-')) {
      before++;
      i++;
      continue;
    }

    final start = i;
    final dels = <int>[];
    while (i < body.length && body[i].startsWith('-')) {
      dels.add(i);
      i++;
    }
    skipMarkers();
    var adds = 0;
    while (i < body.length && body[i].startsWith('+')) {
      adds++;
      i++;
    }
    skipMarkers();
    if (i == start) {
      i++;
      continue;
    }

    final paired = dels.length < adds ? dels.length : adds;
    if (adds == 0 && dels.isNotEmpty) {
      out.add(DeletionFragment(before, dels.length, dels));
    }
    // Rows emitted for this change: the paired lines, plus an addition row for
    // every extra `+`. Extra `-` lines stay as rows (see pairHunkLines) so they
    // are not fragments.
    before += paired + (adds - paired);
  }
  return out;
}

class LinePart {
  const LinePart(this.prefix, this.mid, this.suffix);
  final String prefix;
  final String mid;
  final String suffix;
}

class IntraDiff {
  const IntraDiff(this.left, this.right);
  final LinePart left;
  final LinePart right;
}

/// Where two versions of one line actually differ: the shared prefix and suffix
/// are trimmed off and what remains is the highlight.
///
/// Iterating runes (not UTF-16 units) is what keeps CJK and emoji intact; a
/// `codeUnitAt` scan can stop mid-surrogate and render a broken glyph.
///
/// ponytail: prefix/suffix trimming, not a token LCS. Exact for the common
/// single-edit case, coarse for scattered edits — upgrade to a word-level LCS
/// if that ever actually reads badly.
IntraDiff? intraLineDiff(String a, String b) {
  if (a == b) return null;
  final A = a.runes.toList();
  final B = b.runes.toList();

  var p = 0;
  while (p < A.length && p < B.length && A[p] == B[p]) {
    p++;
  }
  var s = 0;
  while (s < A.length - p &&
      s < B.length - p &&
      A[A.length - 1 - s] == B[B.length - 1 - s]) {
    s++;
  }

  LinePart cut(List<int> arr) => LinePart(
        String.fromCharCodes(arr.sublist(0, p)),
        String.fromCharCodes(arr.sublist(p, arr.length - s)),
        String.fromCharCodes(arr.sublist(arr.length - s)),
      );
  return IntraDiff(cut(A), cut(B));
}

/* ---------- history DAG layout ---------- */

class GraphRow {
  const GraphRow(
      this.commit, this.myCol, this.incoming, this.outgoing, this.parentCols);
  final GraphCommit commit;
  final int myCol;
  final List<String?> incoming;
  final List<String?> outgoing;
  final List<int> parentCols;
}

class GraphLayout {
  const GraphLayout(this.rows, this.width);
  final List<GraphRow> rows;
  final int width;
}

/// Assign each commit a lane (column) and record incoming/outgoing lane state.
///
/// Takes the same GraphCommit cgit-core returns, rather than a local copy of
/// the shape: two structurally identical types would drift the moment core
/// grows a field.
GraphLayout layoutGraph(List<GraphCommit> commits) {
  final lanes = <String?>[]; // lanes[col] = oid expected next in that column
  final rows = <GraphRow>[];

  int allocFree() {
    final i = lanes.indexOf(null);
    if (i != -1) return i;
    lanes.add(null);
    return lanes.length - 1;
  }

  for (final c in commits) {
    final incoming = List<String?>.from(lanes);
    final mergeCols = <int>[];
    for (var i = 0; i < incoming.length; i++) {
      if (incoming[i] == c.id) mergeCols.add(i);
    }

    int myCol;
    if (mergeCols.isNotEmpty) {
      myCol = mergeCols[0];
      for (var k = 1; k < mergeCols.length; k++) {
        lanes[mergeCols[k]] = null;
      }
    } else {
      myCol = allocFree();
    }

    final parentCols = <int>[];
    if (c.parents.isNotEmpty) {
      lanes[myCol] = c.parents[0];
      parentCols.add(myCol);
      for (var p = 1; p < c.parents.length; p++) {
        var pc = lanes.indexOf(c.parents[p]);
        if (pc == -1) pc = allocFree();
        lanes[pc] = c.parents[p];
        parentCols.add(pc);
      }
    } else {
      lanes[myCol] = null;
    }

    // trim trailing free lanes so the graph doesn't stay wide after branches end
    while (lanes.isNotEmpty && lanes.last == null) {
      lanes.removeLast();
    }

    rows.add(
        GraphRow(c, myCol, incoming, List<String?>.from(lanes), parentCols));
  }

  var width = 1;
  for (final r in rows) {
    if (r.incoming.length > width) width = r.incoming.length;
    if (r.outgoing.length > width) width = r.outgoing.length;
  }
  return GraphLayout(rows, width);
}

/* ---------- conflict markers ---------- */

enum BlockType { ctx, conflict }

/// One block of a conflicted file: either plain context, or a conflict with the
/// two (or three) sides git recorded.
class ConflictBlock {
  ConflictBlock.context(this.lines)
      : type = BlockType.ctx,
        ours = const [],
        base = const [],
        theirs = const [];

  ConflictBlock.conflict({
    required this.ours,
    required this.base,
    required this.theirs,
  })  : type = BlockType.conflict,
        lines = const [];

  final BlockType type;
  final List<String> lines;
  final List<String> ours;
  final List<String> base;
  final List<String> theirs;

  /// Which side the user picked: null (default to ours), 'ours', 'theirs',
  /// 'both', or 'none' when both sides are rejected. [assembleConflict] reads
  /// only this and [edited].
  String? resolution;

  /// Hand-edited replacement text. Wins over [resolution].
  String? edited;
}

class ParsedConflicts {
  const ParsedConflicts(this.blocks, this.hasConflict);
  final List<ConflictBlock> blocks;
  final bool hasConflict;
}

/// Split a file containing conflict markers into context and conflict blocks.
ParsedConflicts parseConflicts(String text) {
  final lines = text.split('\n');
  final blocks = <ConflictBlock>[];
  var ctx = <String>[];
  var hasConflict = false;
  var i = 0;

  void flushCtx() {
    if (ctx.isNotEmpty) {
      blocks.add(ConflictBlock.context(ctx));
      ctx = <String>[];
    }
  }

  while (i < lines.length) {
    if (lines[i].startsWith('<<<<<<<')) {
      hasConflict = true;
      flushCtx();
      i++;
      final ours = <String>[];
      while (i < lines.length &&
          !lines[i].startsWith('|||||||') &&
          !lines[i].startsWith('=======')) {
        ours.add(lines[i]);
        i++;
      }
      final base = <String>[];
      if (i < lines.length && lines[i].startsWith('|||||||')) {
        i++;
        while (i < lines.length && !lines[i].startsWith('=======')) {
          base.add(lines[i]);
          i++;
        }
      }
      if (i < lines.length && lines[i].startsWith('=======')) i++;
      final theirs = <String>[];
      while (i < lines.length && !lines[i].startsWith('>>>>>>>')) {
        theirs.add(lines[i]);
        i++;
      }
      if (i < lines.length && lines[i].startsWith('>>>>>>>')) i++;
      blocks
          .add(ConflictBlock.conflict(ours: ours, base: base, theirs: theirs));
    } else {
      ctx.add(lines[i]);
      i++;
    }
  }
  flushCtx();
  return ParsedConflicts(blocks, hasConflict);
}

/// Rebuild file content from blocks, applying each block's chosen resolution.
///
/// The common ancestor is never written out: it is context for the human, not
/// a side that can be picked.
String assembleConflict(List<ConflictBlock> blocks) {
  final out = <String>[];
  for (final b in blocks) {
    if (b.edited != null) {
      out.addAll(b.edited!.split('\n'));
    } else if (b.type == BlockType.ctx) {
      out.addAll(b.lines);
    } else if (b.resolution == 'none') {
      continue; // both sides rejected
    } else if (b.resolution == 'theirs') {
      out.addAll(b.theirs);
    } else if (b.resolution == 'both') {
      out.addAll(b.ours);
      out.addAll(b.theirs);
    } else {
      out.addAll(b.ours); // default / "ours"
    }
  }
  return out.join('\n');
}

/* ---------- three-way line merge ---------- */

enum MergeGroupKind { common, oursOnly, theirsOnly, bothSame, conflict }

/// One aligned row inside a [MergeGroup]. A null cell means that side has no
/// line here; source editors omit it and connectors link the actual ranges.
class MergeRow {
  const MergeRow({this.base, this.ours, this.theirs});
  final String? base;
  final String? ours;
  final String? theirs;
}

/// A run of lines that changed on at least one side, with all three versions
/// already line-aligned. Each source editor uses its own lines; group boundaries
/// provide the anchors for linked scrolling when line counts differ.
class MergeGroup {
  const MergeGroup({
    required this.kind,
    required this.rows,
    required this.baseLines,
    required this.oursLines,
    required this.theirsLines,
  });

  final MergeGroupKind kind;
  final List<MergeRow> rows;
  final List<String> baseLines;
  final List<String> oursLines;
  final List<String> theirsLines;

  bool get isConflict => kind == MergeGroupKind.conflict;
  bool get isChange => kind != MergeGroupKind.common;
}

class ThreeWayMerge {
  const ThreeWayMerge(this.groups);
  final List<MergeGroup> groups;
  bool get hasConflict => groups.any((g) => g.isConflict);
}

List<String> _mergeLines(String text) =>
    text.isEmpty ? const <String>[] : text.split('\n');

bool _sameLines(List<String> a, List<String> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class _Change {
  const _Change(this.baseStart, this.baseEnd, this.lines);
  final int baseStart;
  final int baseEnd;
  final List<String> lines;
}

/// One row of the LCS length table for `a[aLo..aHi)` against `b[bLo..bHi)`.
List<int> _lcsRow(
    List<String> a, int aLo, int aHi, List<String> b, int bLo, int bHi) {
  final m = bHi - bLo;
  var prev = List<int>.filled(m + 1, 0);
  var cur = List<int>.filled(m + 1, 0);
  for (var i = aLo; i < aHi; i++) {
    cur[0] = 0;
    final ai = a[i];
    for (var j = 0; j < m; j++) {
      if (ai == b[bLo + j]) {
        cur[j + 1] = prev[j] + 1;
      } else {
        cur[j + 1] = prev[j + 1] >= cur[j] ? prev[j + 1] : cur[j];
      }
    }
    final swap = prev;
    prev = cur;
    cur = swap;
  }
  return prev;
}

/// Hirschberg's linear-space LCS: O(n*m) time, O(min(n,m)) memory, so a large
/// conflicted file cannot blow up the heap just because it has two versions.
void _lcsMatches(List<String> a, int aLo, int aHi, List<String> b, int bLo,
    int bHi, List<(int, int)> out) {
  if (aLo >= aHi || bLo >= bHi) return;
  if (aHi - aLo == 1) {
    for (var j = bLo; j < bHi; j++) {
      if (a[aLo] == b[j]) {
        out.add((aLo, j));
        return;
      }
    }
    return;
  }
  final aMid = (aLo + aHi) >> 1;
  final left = _lcsRow(a, aLo, aMid, b, bLo, bHi);
  final revA = [for (var i = aHi - 1; i >= aMid; i--) a[i]];
  final revB = [for (var j = bHi - 1; j >= bLo; j--) b[j]];
  final right = _lcsRow(revA, 0, revA.length, revB, 0, revB.length);
  final m = bHi - bLo;
  var bestK = 0;
  var best = -1;
  for (var k = 0; k <= m; k++) {
    final score = left[k] + right[m - k];
    if (score > best) {
      best = score;
      bestK = k;
    }
  }
  _lcsMatches(a, aLo, aMid, b, bLo, bLo + bestK, out);
  _lcsMatches(a, aMid, aHi, b, bLo + bestK, bHi, out);
}

const _lcsCellLimit = 20000000;

/// The changed runs that turn [base] into [side], with their replacement lines.
/// Common prefix and suffix are stripped first, so a small edit in a huge file
/// stays cheap; only the changed middle goes through LCS.
List<_Change> _changesFor(List<String> base, List<String> side) {
  final minLen = base.length < side.length ? base.length : side.length;
  var pre = 0;
  while (pre < minLen && base[pre] == side[pre]) {
    pre++;
  }
  var suf = 0;
  while (suf < minLen - pre &&
      base[base.length - 1 - suf] == side[side.length - 1 - suf]) {
    suf++;
  }
  final aLo = pre, aHi = base.length - suf;
  final bLo = pre, bHi = side.length - suf;
  final aLen = aHi - aLo, bLen = bHi - bLo;
  if (aLen == 0 && bLen == 0) return const [];
  // A pathological middle (generated files) falls back to one replacement;
  // that may over-report a conflict, but never writes the wrong content.
  if (aLen == 0 || bLen == 0 || aLen * bLen > _lcsCellLimit) {
    return [_Change(aLo, aHi, side.sublist(bLo, bHi))];
  }

  final matches = <(int, int)>[];
  _lcsMatches(base, aLo, aHi, side, bLo, bHi, matches);
  final out = <_Change>[];
  var bi = aLo, si = bLo;
  for (final m in matches) {
    if (m.$1 > bi || m.$2 > si) {
      out.add(_Change(bi, m.$1, side.sublist(si, m.$2)));
    }
    bi = m.$1 + 1;
    si = m.$2 + 1;
  }
  if (bi < aHi || si < bHi) {
    out.add(_Change(bi, aHi, side.sublist(si, bHi)));
  }
  return out;
}

/// 删除范围及其在删除后文件中的行边界，行号从 0 开始。
List<({int first, int end, int sideLine})> deletedLineRanges(
    List<String> before, List<String> after) {
  final ranges = <({int first, int end, int sideLine})>[];
  var delta = 0;
  for (final change in _changesFor(before, after)) {
    if (change.lines.isEmpty && change.baseEnd > change.baseStart) {
      ranges.add((
        first: change.baseStart,
        end: change.baseEnd,
        sideLine: change.baseStart + delta,
      ));
    }
    delta += change.lines.length - (change.baseEnd - change.baseStart);
  }
  return ranges;
}

List<String> _applyChanges(
    List<String> base, int start, int end, List<_Change> changes) {
  final out = <String>[];
  var at = start;
  for (final c in changes) {
    out.addAll(base.sublist(at, c.baseStart));
    out.addAll(c.lines);
    at = c.baseEnd;
  }
  out.addAll(base.sublist(at, end));
  return out;
}

({Map<int, String?> cells, Map<int, List<String>> inserts}) _sideCells(
    List<String> base, int start, int end, List<_Change> changes) {
  final cells = <int, String?>{for (var i = start; i < end; i++) i: base[i]};
  final inserts = <int, List<String>>{};
  for (final c in changes) {
    if (c.baseStart == c.baseEnd) {
      (inserts[c.baseStart] ??= []).addAll(c.lines);
      continue;
    }
    final cover = c.baseEnd - c.baseStart;
    for (var k = 0; k < cover; k++) {
      cells[c.baseStart + k] = k < c.lines.length ? c.lines[k] : null;
    }
    if (c.lines.length > cover) {
      (inserts[c.baseEnd] ??= []).addAll(c.lines.sublist(cover));
    }
  }
  return (cells: cells, inserts: inserts);
}

List<MergeRow> _alignedRows(List<String> base, int start, int end,
    List<_Change> oursChanges, List<_Change> theirsChanges) {
  final o = _sideCells(base, start, end, oursChanges);
  final t = _sideCells(base, start, end, theirsChanges);
  final rows = <MergeRow>[];
  for (var i = start; i <= end; i++) {
    final ol = o.inserts[i] ?? const <String>[];
    final tl = t.inserts[i] ?? const <String>[];
    final n = ol.length > tl.length ? ol.length : tl.length;
    for (var k = 0; k < n; k++) {
      rows.add(MergeRow(
        ours: k < ol.length ? ol[k] : null,
        theirs: k < tl.length ? tl[k] : null,
      ));
    }
    if (i < end) {
      rows.add(MergeRow(base: base[i], ours: o.cells[i], theirs: t.cells[i]));
    }
  }
  return rows;
}

MergeGroup _group(List<String> base, int start, int end,
    List<_Change> oursChanges, List<_Change> theirsChanges) {
  final hasOurs = oursChanges.isNotEmpty;
  final hasTheirs = theirsChanges.isNotEmpty;
  final oursLines = _applyChanges(base, start, end, oursChanges);
  final theirsLines = _applyChanges(base, start, end, theirsChanges);
  final MergeGroupKind kind;
  if (!hasOurs && !hasTheirs) {
    kind = MergeGroupKind.common;
  } else if (hasOurs && !hasTheirs) {
    kind = MergeGroupKind.oursOnly;
  } else if (!hasOurs) {
    kind = MergeGroupKind.theirsOnly;
  } else {
    kind = _sameLines(oursLines, theirsLines)
        ? MergeGroupKind.bothSame
        : MergeGroupKind.conflict;
  }
  return MergeGroup(
    kind: kind,
    rows: _alignedRows(base, start, end, oursChanges, theirsChanges),
    baseLines: base.sublist(start, end),
    oursLines: oursLines,
    theirsLines: theirsLines,
  );
}

/// Merge three full-file versions into aligned groups.
///
/// This is the diff3 combination step: diff the base against each side, then
/// walk both change lists together. Overlapping changes go into one group;
/// identical results on both sides are not a conflict.
ThreeWayMerge threeWayMerge(
    {required String base, required String ours, required String theirs}) {
  final b = _mergeLines(base);
  final oc = _changesFor(b, _mergeLines(ours));
  final tc = _changesFor(b, _mergeLines(theirs));
  final groups = <MergeGroup>[];
  var oi = 0, ti = 0, cursor = 0;
  const far = 1 << 30;

  while (oi < oc.length || ti < tc.length) {
    final os = oi < oc.length ? oc[oi].baseStart : far;
    final ts = ti < tc.length ? tc[ti].baseStart : far;
    final start = os < ts ? os : ts;
    if (start > cursor) {
      groups.add(_group(b, cursor, start, const [], const []));
      cursor = start;
    }

    var end = start;
    final og = <_Change>[];
    final tg = <_Change>[];
    var grew = true;
    while (grew) {
      grew = false;
      while (oi < oc.length && oc[oi].baseStart <= end) {
        final c = oc[oi++];
        og.add(c);
        if (c.baseEnd > end) {
          end = c.baseEnd;
          grew = true;
        }
      }
      while (ti < tc.length && tc[ti].baseStart <= end) {
        final c = tc[ti++];
        tg.add(c);
        if (c.baseEnd > end) {
          end = c.baseEnd;
          grew = true;
        }
      }
    }
    groups.add(_group(b, start, end, og, tg));
    cursor = end;
  }
  if (cursor < b.length) {
    groups.add(_group(b, cursor, b.length, const [], const []));
  }
  return ThreeWayMerge(groups);
}

/* ---------- change navigation ---------- */

/// Row indices that start a run of changed rows in one hunk — what ↑/↓ step
/// through, rather than every single changed line.
///
/// Pure, and deliberately mirroring how the pane builds its rows: unified mode
/// has one row per body line, split mode one row per paired row. Computing it
/// here instead of collecting keys while rendering keeps navigation working the
/// same whether or not the rows are on screen.
List<int> changeBlockRows(String hunk, {required bool split}) {
  final changed = <bool>[];

  final paired = split ? pairHunkLines(hunk) : null;
  if (paired != null) {
    for (final row in paired.rows) {
      changed.add(row.picks.isNotEmpty);
    }
  } else {
    final lines = hunk.replaceFirst(RegExp(r'\n\$'), '').split('\n').skip(1);
    for (final line in lines) {
      changed.add(line.startsWith('+') || line.startsWith('-'));
    }
  }

  final starts = <int>[];
  var prev = false;
  for (var i = 0; i < changed.length; i++) {
    if (changed[i] && !prev) starts.add(i);
    prev = changed[i];
  }
  return starts;
}

enum ChangeTargetKind { block, file, none }

class ChangeTarget {
  const ChangeTarget(this.kind, [this.index = -1]);
  final ChangeTargetKind kind;
  final int index;
}

/// Decide the first step of a prev/next-change move. Split out from the widget
/// tree so the index arithmetic — the part that is all off-by-one risk — is
/// testable.
///
/// Returns a `block` target to move within the current file, `file` to open an
/// adjacent one, or `none` when there is nowhere left to go. The caller keeps
/// walking files on a `file` result until one actually renders a block.
ChangeTarget nextChangeTarget({
  required int blockIndex,
  required int blockCount,
  required int navIndex,
  required int navCount,
  required int dir,
}) {
  final far = dir > 0 ? 0 : blockCount - 1;
  // Nothing focused yet: enter the current file from the end we came from.
  if (blockIndex == -1 && blockCount > 0) {
    return ChangeTarget(ChangeTargetKind.block, far);
  }
  final next = blockIndex + dir;
  if (next >= 0 && next < blockCount) {
    return ChangeTarget(ChangeTargetKind.block, next);
  }
  final file = navIndex + dir;
  if (file >= 0 && file < navCount) {
    return ChangeTarget(ChangeTargetKind.file, file);
  }
  return const ChangeTarget(ChangeTargetKind.none);
}

/* ---------- AI endpoint ---------- */

/// Normalize the AI 请求地址 preference into a /chat/completions endpoint.
String aiEndpoint(String baseUrl) {
  final url = baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
  return url.endsWith('/chat/completions') ? url : '$url/chat/completions';
}

/* ---------- push rejection ---------- */

/// Whether a `git push` failure is "the remote moved ahead" — i.e. updating the
/// local branch and pushing again can resolve it. Everything else (auth, a
/// refusing hook, a protected branch) is a real failure.
bool isPushRejected(String stderr) =>
    stderr.contains('[rejected]') ||
    stderr.contains('fetch first') ||
    stderr.contains('non-fast-forward');

class AuthFailure {
  const AuthFailure(this.kind, this.username);
  final String kind;
  final String? username;
}

/// Classify credential failures and retain the authenticated GitHub account
/// when the remote names it. An HTTP 403 alone is not enough: repositories and
/// proxies use it for failures unrelated to credentials.
AuthFailure? authFailureInfo(String stderr) {
  final denied = RegExp(
          r'^remote: Permission to .+ denied to ([A-Za-z0-9-]+)\.\s*$',
          multiLine: true)
      .firstMatch(stderr);
  if (denied != null &&
      stderr.contains('The requested URL returned error: 403')) {
    return AuthFailure('github-403', denied[1]);
  }
  if (stderr.contains('could not read Username') ||
      stderr.contains('could not read Password')) {
    return const AuthFailure('https-prompt', null);
  }
  if (stderr.contains('Authentication failed')) {
    return const AuthFailure('https-auth', null);
  }
  if (stderr.contains('Permission denied (publickey)')) {
    return const AuthFailure('ssh-publickey', null);
  }
  return null;
}

bool isAuthFailure(String stderr) => authFailureInfo(stderr) != null;

/// The one line of a git failure worth putting in the status bar. git's stderr
/// often opens with context ("To https://…", "hint: …") and puts the reason
/// later, so a rejected ref or a fatal/error line wins over the first line.
String errorSummary(String stderr) {
  final lines = [
    for (final l in stderr.split('\n'))
      if (l.trim().isNotEmpty) l.trim(),
  ];
  if (lines.isEmpty) return '';
  for (final l in lines) {
    if (l.contains('[remote rejected]') || l.contains('[rejected]')) {
      return l.startsWith('! ') ? l.substring(2) : l;
    }
  }
  for (final l in lines) {
    if (l.startsWith('fatal:') || l.startsWith('error:')) return l;
  }
  return lines.first;
}

/// Decide whether the combined credential button can reuse the current helper
/// entry or needs a new token. The token itself never leaves the input field.
String credentialAction({
  required bool hasCredential,
  required String? infoUsername,
  required String username,
  required String token,
}) {
  final u = username.trim();
  final t = token.trim();
  if (u.isEmpty) return 'missing-username';
  if (t.isNotEmpty) return 'save-and-test';
  if (hasCredential && u == infoUsername) return 'test';
  return 'missing-token';
}

/* ---------- folder tree (push dialog) ---------- */

class TreeFile {
  const TreeFile(this.path, this.status);
  final String path;
  final String status;
}

class TreeNode {
  const TreeNode(this.name, this.dirs, this.files, this.count);
  final String name;
  final List<TreeNode> dirs;
  final List<TreeFile> files;
  final int count;
}

class _MutableNode {
  _MutableNode(this.name);
  String name;
  final dirs = <String, _MutableNode>{};
  final files = <TreeFile>[];
}

/// Groups files into a folder tree. Folders sort before files and carry the
/// number of files below them. Single-child folder chains collapse by default;
/// interactive callers can keep every level visible. The root keeps an empty
/// name — the caller labels it with the repo name.
TreeNode pathTree(List<TreeFile> files, {bool collapseSingleChild = true}) {
  final root = _MutableNode('');
  for (final f in files) {
    final parts = f.path.split('/');
    var node = root;
    for (final dir in parts.sublist(0, parts.length - 1)) {
      node = node.dirs.putIfAbsent(dir, () => _MutableNode(dir));
    }
    node.files.add(f);
  }
  return _closeTree(root, collapseSingleChild);
}

TreeNode _closeTree(_MutableNode node, bool collapseSingleChild) {
  // Collapse a chain of single-child folders into one row. The root is exempt:
  // it is the repo, and swallowing "app" into it would hide a real folder.
  var cur = node;
  while (collapseSingleChild &&
      cur.name.isNotEmpty &&
      cur.files.isEmpty &&
      cur.dirs.length == 1) {
    final only = cur.dirs.values.first;
    final merged = _MutableNode('${cur.name}/${only.name}');
    merged.dirs.addAll(only.dirs);
    merged.files.addAll(only.files);
    cur = merged;
  }

  final dirs = cur.dirs.values
      .map((d) => _closeTree(d, collapseSingleChild))
      .toList()
    ..sort((a, b) => a.name.compareTo(b.name));
  final own = cur.files.toList()..sort((a, b) => a.path.compareTo(b.path));

  var count = own.length;
  for (final d in dirs) {
    count += d.count;
  }
  return TreeNode(cur.name, dirs, own, count);
}

/// The files under [node] in the order the tree shows them — each folder's
/// subfolders first, then its own files — so ↑/↓ walks the list as drawn.
List<TreeFile> treeOrder(TreeNode node) => [
      for (final d in node.dirs) ...treeOrder(d),
      ...node.files,
    ];

/* ---------- patch file names ---------- */

/// The filename `git format-patch` would give a commit: a numbered prefix, the
/// summary reduced to what a filesystem will take, and `.patch`.
///
/// Truncation walks runes rather than code units. A summary is free-form text
/// and may hold an emoji; cutting at a UTF-16 boundary would leave half a
/// surrogate pair in the name — the same hazard intraLineDiff avoids.
String patchFileName(String summary, {int maxLength = 50}) {
  final cleaned = summary
      .replaceAll(RegExp(r'[^\w\u4e00-\u9fff]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  if (cleaned.isEmpty) return '0001-patch.patch';

  final runes = cleaned.runes.toList();
  final slug = runes.length <= maxLength
      ? cleaned
      : String.fromCharCodes(runes.sublist(0, maxLength));
  return '0001-$slug.patch';
}

/* ---------- imported patch text ---------- */

/// One file's complete diff text extracted from an imported patch.
class ImportPatchFile {
  const ImportPatchFile({
    required this.path,
    required this.patch,
    required this.status,
    String? targetPath,
  }) : _targetPath = targetPath;

  final String path;
  final String patch;
  final String status;
  final String? _targetPath;

  /// The resulting file path, useful for matching conflicts or destination
  /// files. For a rename, [path] also shows both names for display.
  String get targetPath => _targetPath ?? path;
}

/// Splits a Git patch into per-file diffs. A format-patch mail envelope and
/// its trailing signature are not part of the returned per-file patch text.
/// The file diff itself is kept verbatim, including mode, binary, and newline
/// records. This only parses text; it does not apply the patch or touch Git.
List<ImportPatchFile> splitImportPatch(String text) {
  final lines = _PatchLines(text);
  final gitHeaders = <int>[];
  for (var i = 0; i < lines.values.length; i++) {
    if (lines.values[i].content.startsWith('diff --git ')) {
      gitHeaders.add(i);
    }
  }

  if (gitHeaders.isNotEmpty) {
    final end = _withoutFormatPatchSignature(lines);
    return [
      for (var i = 0; i < gitHeaders.length; i++)
        if (gitHeaders[i] < end)
          _gitPatchFile(
            lines,
            gitHeaders[i],
            i + 1 < gitHeaders.length ? gitHeaders[i + 1] : end,
          ),
    ];
  }

  final unified = _splitUnifiedPatch(lines);
  if (unified.isNotEmpty) return unified;
  throw const FormatException('无法识别补丁格式：未找到 Git diff 或 unified diff 文件头');
}

class _PatchLine {
  const _PatchLine(this.content, this.raw);
  final String content;
  final String raw;
}

class _PatchLines {
  _PatchLines(String text) {
    var start = 0;
    for (var i = 0; i < text.length; i++) {
      if (text.codeUnitAt(i) == 10) {
        final hasCr = i > start && text.codeUnitAt(i - 1) == 13;
        final contentEnd = hasCr ? i - 1 : i;
        values.add(_PatchLine(
          text.substring(start, contentEnd),
          text.substring(start, i + 1),
        ));
        start = i + 1;
      }
    }
    if (start < text.length) {
      values.add(_PatchLine(text.substring(start), text.substring(start)));
    }
  }

  final values = <_PatchLine>[];
}

int _withoutFormatPatchSignature(_PatchLines lines) {
  for (var i = lines.values.length - 2; i >= 0; i--) {
    if (lines.values[i].content == '-- ' &&
        lines.values[i + 1].content.isNotEmpty &&
        RegExp(r'^\d+(?:\.\d+)*').hasMatch(lines.values[i + 1].content)) {
      return i;
    }
  }
  return lines.values.length;
}

ImportPatchFile _gitPatchFile(_PatchLines lines, int start, int end) {
  final header = lines.values[start].content.substring('diff --git '.length);
  final pair = _parseGitPathPair(header);
  var oldPath = _stripDiffPrefix(pair.$1, 'a/');
  var newPath = _stripDiffPrefix(pair.$2, 'b/');
  var renamed = false;
  var added = false;
  var deleted = false;
  var inHunk = false;

  for (var i = start + 1; i < end; i++) {
    final line = lines.values[i].content;
    if (line.startsWith('@@ ')) inHunk = true;
    if (inHunk) continue;
    if (line.startsWith('rename from ')) {
      oldPath = _decodeGitLabel(line.substring('rename from '.length));
      renamed = true;
    } else if (line.startsWith('rename to ')) {
      newPath = _decodeGitLabel(line.substring('rename to '.length));
      renamed = true;
    } else if (line == 'deleted file mode' ||
        line.startsWith('deleted file mode ')) {
      deleted = true;
    } else if (line == 'new file mode' || line.startsWith('new file mode ')) {
      added = true;
    } else if (line.startsWith('--- ')) {
      oldPath = _stripDiffPrefix(_decodeGitPath(line.substring(4)), 'a/');
      if (oldPath == '/dev/null') added = true;
    } else if (line.startsWith('+++ ')) {
      newPath = _stripDiffPrefix(_decodeGitPath(line.substring(4)), 'b/');
      if (newPath == '/dev/null') deleted = true;
    }
  }

  final status = renamed
      ? 'renamed'
      : added || oldPath == '/dev/null'
          ? 'added'
          : deleted || newPath == '/dev/null'
              ? 'deleted'
              : 'modified';
  final path = renamed
      ? '$oldPath → $newPath'
      : status == 'deleted'
          ? oldPath
          : newPath;
  return ImportPatchFile(
    path: path,
    patch: lines.values.sublist(start, end).map((line) => line.raw).join(),
    status: status,
    targetPath: newPath,
  );
}

(String, String) _parseGitPathPair(String value) {
  final first = _readGitPath(value, 0);
  final secondStart = _skipSpaces(value, first.$2);
  final second = _readGitPath(value, secondStart);
  if (first.$1.isEmpty ||
      second.$1.isEmpty ||
      value.substring(second.$2).trim().isNotEmpty) {
    throw const FormatException('无法识别补丁格式：Git diff 文件路径格式无效');
  }
  return (first.$1, second.$1);
}

(String, int) _readGitPath(String value, int offset) {
  if (offset >= value.length) return ('', offset);
  if (value.codeUnitAt(offset) != 34) {
    var end = value.indexOf(' ', offset);
    if (end < 0) end = value.length;
    return (value.substring(offset, end), end);
  }

  final bytes = <int>[];
  var i = offset + 1;
  while (i < value.length && value.codeUnitAt(i) != 34) {
    final code = value.codeUnitAt(i++);
    if (code != 92) {
      _appendUtf8(bytes, code);
      continue;
    }
    if (i >= value.length) break;
    final escaped = value.codeUnitAt(i++);
    const simple = <int, int>{
      34: 34,
      92: 92,
      110: 10,
      114: 13,
      116: 9,
      98: 8,
      102: 12,
      118: 11,
    };
    if (simple.containsKey(escaped)) {
      bytes.add(simple[escaped]!);
    } else if (escaped >= 48 && escaped <= 55) {
      var octal = escaped - 48;
      var count = 1;
      while (count < 3 && i < value.length) {
        final digit = value.codeUnitAt(i);
        if (digit < 48 || digit > 55) break;
        octal = octal * 8 + digit - 48;
        i++;
        count++;
      }
      bytes.add(octal & 255);
    } else {
      bytes.add(escaped);
    }
  }
  if (i >= value.length || value.codeUnitAt(i) != 34) {
    throw const FormatException('无法识别补丁格式：Git diff 引号路径未闭合');
  }
  return (_decodeUtf8(bytes), i + 1);
}

void _appendUtf8(List<int> bytes, int rune) {
  if (rune <= 0x7f) {
    bytes.add(rune);
  } else if (rune <= 0x7ff) {
    bytes
      ..add(0xc0 | (rune >> 6))
      ..add(0x80 | (rune & 0x3f));
  } else if (rune <= 0xffff) {
    bytes
      ..add(0xe0 | (rune >> 12))
      ..add(0x80 | ((rune >> 6) & 0x3f))
      ..add(0x80 | (rune & 0x3f));
  } else {
    bytes
      ..add(0xf0 | (rune >> 18))
      ..add(0x80 | ((rune >> 12) & 0x3f))
      ..add(0x80 | ((rune >> 6) & 0x3f))
      ..add(0x80 | (rune & 0x3f));
  }
}

String _decodeUtf8(List<int> bytes) {
  final runes = <int>[];
  for (var i = 0; i < bytes.length;) {
    final first = bytes[i++];
    if (first < 0x80) {
      runes.add(first);
      continue;
    }
    final count = first >= 0xf0
        ? 3
        : first >= 0xe0
            ? 2
            : first >= 0xc2
                ? 1
                : 0;
    if (count == 0 || i + count > bytes.length) {
      runes.add(0xfffd);
      continue;
    }
    var rune = first &
        (count == 1
            ? 0x1f
            : count == 2
                ? 0x0f
                : 0x07);
    var valid = true;
    for (var j = 0; j < count; j++) {
      final next = bytes[i++];
      if ((next & 0xc0) != 0x80) {
        valid = false;
        i--;
        break;
      }
      rune = (rune << 6) | (next & 0x3f);
    }
    if (!valid || rune > 0x10ffff || (rune >= 0xd800 && rune <= 0xdfff)) {
      runes.add(0xfffd);
    } else {
      runes.add(rune);
    }
  }
  return String.fromCharCodes(runes);
}

int _skipSpaces(String value, int offset) {
  var i = offset;
  while (i < value.length && value.codeUnitAt(i) == 32) {
    i++;
  }
  return i;
}

String _decodeGitPath(String value) => _readGitPath(value, 0).$1;

String _decodeGitLabel(String value) =>
    value.startsWith('"') ? _decodeGitPath(value) : value;

String _stripDiffPrefix(String path, String prefix) =>
    path.startsWith(prefix) ? path.substring(prefix.length) : path;

List<ImportPatchFile> _splitUnifiedPatch(_PatchLines lines) {
  final starts = <int>[];
  for (var i = 0; i + 2 < lines.values.length; i++) {
    final oldLine = lines.values[i].content;
    final newLine = lines.values[i + 1].content;
    if (oldLine.startsWith('--- ') &&
        newLine.startsWith('+++ ') &&
        lines.values[i + 2].content.startsWith('@@ ')) {
      starts.add(i);
    }
  }
  if (starts.isEmpty) return const [];

  return [
    for (var i = 0; i < starts.length; i++)
      _unifiedPatchFile(
        lines,
        starts[i],
        i + 1 < starts.length ? starts[i + 1] : lines.values.length,
      ),
  ];
}

ImportPatchFile _unifiedPatchFile(_PatchLines lines, int start, int end) {
  final oldPath = _stripDiffPrefix(
    _decodeGitPath(lines.values[start].content.substring(4)),
    'a/',
  );
  final newPath = _stripDiffPrefix(
    _decodeGitPath(lines.values[start + 1].content.substring(4)),
    'b/',
  );
  final added = oldPath == '/dev/null';
  final deleted = newPath == '/dev/null';
  return ImportPatchFile(
    path: deleted ? oldPath : newPath,
    patch: lines.values.sublist(start, end).map((line) => line.raw).join(),
    status: added
        ? 'added'
        : deleted
            ? 'deleted'
            : 'modified',
    targetPath: deleted ? oldPath : newPath,
  );
}
