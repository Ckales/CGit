import 'src/rust/api/git.dart' show GraphCommit;

export 'src/rust/api/git.dart' show GraphCommit;

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

  /// The merge window's per-side decision: null undecided, true merged into the
  /// result, false dropped. Two independent tri-states rather than one radio
  /// choice, because "take both" is a real outcome and "I have looked at this
  /// side and rejected it" is different from "I have not looked yet".
  /// [syncResolution] collapses the pair into [resolution].
  bool? takeOurs;
  bool? takeTheirs;

  /// A block the user has finished with: either typed over, or decided on both
  /// sides. The merge window refuses to save while any conflict is undecided.
  bool get decided =>
      edited != null || (takeOurs != null && takeTheirs != null);

  /// The result lines implied by the two side decisions, before any hand edit.
  List<String> get resultLines => [
        if (takeOurs == true) ...ours,
        if (takeTheirs == true) ...theirs,
      ];

  /// Fold the two side decisions into the single resolution assembleConflict
  /// understands. Both sides dropped is 'none'; anything still undecided leaves
  /// it null, which assembles as "ours" — the same default git leaves behind.
  void syncResolution() {
    if (takeOurs == true && takeTheirs == true) {
      resolution = 'both';
    } else if (takeOurs == true) {
      resolution = 'ours';
    } else if (takeTheirs == true) {
      resolution = 'theirs';
    } else if (takeOurs == false && takeTheirs == false) {
      resolution = 'none';
    } else {
      resolution = null;
    }
  }

  /// Hand-edited replacement text. Wins over [resolution] — the merge window's
  /// middle column is editable, for context blocks as well as conflicts.
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
