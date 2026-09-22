/* Port of src/git-text.js. Pure text/graph helpers, free of Flutter imports so
   they can be unit-tested with `flutter test` — same reason the JS version
   stays free of DOM and Tauri imports. These are the functions that silently
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
  final body = hunk.replaceFirst(RegExp(r'\n$'), '').split('\n').skip(1).toList();
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
/// versions instead of two unrelated rows. Leftovers get an empty cell on the
/// other side, and a side's line number only advances when that side has a line.
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
      final picks = <int>[];
      if (d != null) picks.add(d.idx);
      if (a != null) picks.add(a.idx);
      rows.add(DiffRow(
        d != null && a != null ? RowType.mod : (d != null ? RowType.del : RowType.add),
        d == null ? null : DiffCell(oldNo++, d.text),
        a == null ? null : DiffCell(newNo++, a.text),
        picks,
      ));
    }
  }
  return PairedHunk(head, rows);
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

class GraphCommit {
  const GraphCommit({
    required this.id,
    required this.summary,
    required this.author,
    required this.time,
    required this.parents,
    required this.refs,
  });
  final String id;
  final String summary;
  final String author;
  final int time;
  final List<String> parents;
  final List<String> refs;
}

class GraphRow {
  const GraphRow(this.commit, this.myCol, this.incoming, this.outgoing, this.parentCols);
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

    rows.add(GraphRow(c, myCol, incoming, List<String?>.from(lanes), parentCols));
  }

  var width = 1;
  for (final r in rows) {
    if (r.incoming.length > width) width = r.incoming.length;
    if (r.outgoing.length > width) width = r.outgoing.length;
  }
  return GraphLayout(rows, width);
}
