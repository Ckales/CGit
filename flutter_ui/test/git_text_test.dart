import 'package:cgit_flutter/git_text.dart';
import 'package:flutter_test/flutter_test.dart';

/// Ported from test/git-text.test.js, case for case, on the functions this
/// port actually carries over. The conflict-merge, AI-endpoint, push-rejection
/// and path-tree suites stay unported because their functions do — see README.
const hunk = '@@ -1,3 +1,4 @@ fn main\n a\n-b\n+B\n+c\n d\n';

void main() {
  group('partial staging', () {
    test('selectableLines finds only the +/- lines', () {
      expect(selectableLines(hunk), [1, 2, 3]);
    });

    test('staging one addition drops the other and neutralises the deletion',
        () {
      expect(
        buildPartialHunk(hunk, {2}),
        ['@@ -1,3 +1,4 @@ fn main', ' a', ' b', '+B', ' d', ''].join('\n'),
      );
    });

    test('staging one deletion drops both additions', () {
      expect(
        buildPartialHunk(hunk, {1}),
        ['@@ -1,3 +1,2 @@ fn main', ' a', '-b', ' d', ''].join('\n'),
      );
    });

    test('line counts always match the body it emits', () {
      for (final sel in [
        {1},
        {2},
        {3},
        {1, 2},
        {2, 3},
        {1, 2, 3},
      ]) {
        final patch = buildPartialHunk(hunk, sel)!;
        final lines = patch.replaceFirst(RegExp(r'\n$'), '').split('\n');
        final m =
            RegExp(r'^@@ -\d+,(\d+) \+\d+,(\d+) @@').firstMatch(lines.first)!;
        final body = lines.sublist(1);
        final oldSide =
            body.where((l) => l.startsWith(' ') || l.startsWith('-')).length;
        final newSide =
            body.where((l) => l.startsWith(' ') || l.startsWith('+')).length;
        expect(int.parse(m[1]!), oldSide, reason: 'old count for $sel');
        expect(int.parse(m[2]!), newSide, reason: 'new count for $sel');
      }
    });

    test('selecting everything reproduces the original hunk', () {
      expect(buildPartialHunk(hunk, {1, 2, 3}), hunk);
    });

    test('returns null when nothing is selected', () {
      expect(buildPartialHunk(hunk, {}), isNull);
      expect(buildPartialHunk('not a hunk', {0}), isNull);
    });

    test('keeps the no-newline marker with its line', () {
      // Marker after the old last line: that line is emitted either as "-a"
      // (selected) or as context " a" (not), so the marker travels with it.
      const oldSide = '@@ -1 +1 @@\n-a\n\\ No newline at end of file\n+b\n';
      expect(buildPartialHunk(oldSide, {0}), contains('-a\n\\ No newline'));
      expect(buildPartialHunk(oldSide, {2}), contains(' a\n\\ No newline'));

      // Marker after an added line: dropping that addition must drop the
      // marker, or the patch claims a no-newline state for the line above.
      const newSide = '@@ -1 +1 @@\n-a\n+b\n\\ No newline at end of file\n';
      expect(buildPartialHunk(newSide, {1}), contains('\\ No newline'));
      expect(buildPartialHunk(newSide, {0}), isNot(contains('\\ No newline')));
    });
  });

  group('shift-range selection', () {
    // hunk body: 0=ctx 1=+ 2=+ 3=ctx 4=- 5=+ 6=ctx
    const pickable = [1, 2, 4, 5];

    test('selects only pickable lines inside the range', () {
      expect(rangeBetween(pickable, 1, 5), {1, 2, 4, 5});
      // Context lines inside the span must not be swept in.
      expect(rangeBetween(pickable, 2, 4), {2, 4});
      // Direction must not matter — dragging upward is the same range.
      expect(rangeBetween(pickable, 5, 1), {1, 2, 4, 5});
      // A range with a single endpoint is just that line.
      expect(rangeBetween(pickable, 4, 4), {4});
      // Endpoints that aren't pickable still bound the range correctly.
      expect(rangeBetween(pickable, 0, 3), {1, 2});
    });
  });

  group('side-by-side pairing', () {
    test('separates the file header from each hunk', () {
      const patch = 'diff --git a/x b/x\n--- a/x\n+++ b/x\n'
          '@@ -1 +1 @@\n-a\n+b\n'
          '@@ -9 +9 @@\n-c\n+d\n';
      final split = splitPatchText(patch);
      expect(split.header, 'diff --git a/x b/x\n--- a/x\n+++ b/x\n');
      expect(split.hunks.length, 2);
      expect(split.hunks.first, '@@ -1 +1 @@\n-a\n+b\n');
    });

    test('aligns deletions against additions and numbers both sides', () {
      final rows =
          pairHunkLines('@@ -10,3 +20,3 @@\n keep\n-old\n+new\n tail\n')!.rows;
      expect(
        rows.map((r) =>
            [r.type, r.left?.no, r.left?.text, r.right?.no, r.right?.text]),
        [
          [RowType.ctx, 10, 'keep', 20, 'keep'],
          [RowType.mod, 11, 'old', 21, 'new'],
          [RowType.ctx, 12, 'tail', 22, 'tail'],
        ],
      );
    });

    test('leaves the opposite cell empty for unbalanced runs', () {
      final rows = pairHunkLines('@@ -1,3 +1,2 @@\n-a\n-b\n+A\n c\n')!.rows;
      expect(rows.map((r) => r.type), [RowType.mod, RowType.del, RowType.ctx]);
      expect(rows[1].right, isNull,
          reason: 'second deletion has no counterpart');
      // Numbering must not advance on the side that has no line.
      expect(
        rows.map((r) => [r.left?.no, r.right?.no]),
        [
          [1, 1],
          [2, null],
          [3, 2],
        ],
      );
    });

    test('carries the body indices that staging needs', () {
      const h = '@@ -1,2 +1,2 @@\n x\n-a\n+A\n';
      final rows = pairHunkLines(h)!.rows;
      expect(rows[0].picks, isEmpty, reason: 'context is not stageable');
      // Picking a modified row must stage both halves of the change.
      expect(rows[1].picks, [1, 2]);
      expect(buildPartialHunk(h, rows[1].picks.toSet()), h);
    });

    test('never loops on malformed body lines', () {
      final paired = pairHunkLines('@@ -1,1 +1,1 @@\n???unexpected\n-a\n+b\n');
      expect(paired!.rows, isNotEmpty, reason: 'returns instead of hanging');
      expect(pairHunkLines('no header here'), isNull);
    });
  });

  group('intra-line diff', () {
    test('highlights only the changed middle', () {
      const a = '【UniFly萤火虫】令牌变更通知 · {令牌名称}';
      const b = '【UniFly萤火虫】令牌变更通11知 · {令牌名称}';
      final d = intraLineDiff(a, b)!;
      expect(d.left.mid, '', reason: 'nothing was removed');
      expect(d.right.mid, '11',
          reason: 'only the inserted text is highlighted');
      expect(d.left.prefix, d.right.prefix);
      expect(d.left.suffix, d.right.suffix);
      // Reassembling each side must give back the original line.
      expect(d.left.prefix + d.left.mid + d.left.suffix, a);
      expect(d.right.prefix + d.right.mid + d.right.suffix, b);
    });

    test('returns null for identical lines and handles no overlap', () {
      expect(intraLineDiff('same', 'same'), isNull);
      final d = intraLineDiff('abc', 'xyz')!;
      expect(d.left.mid, 'abc');
      expect(d.right.mid, 'xyz');
    });

    test('splits on code points, not UTF-16 units', () {
      // U+1F600 and U+1F601 share a high surrogate and differ only in the low
      // one, so a UTF-16-unit scan stops inside the pair and leaves a lone
      // surrogate in the prefix. Dart's String indexing has exactly the same
      // hazard as JS's, which is why both versions iterate code points.
      final d = intraLineDiff('a\u{1F600}b', 'a\u{1F601}b')!;
      expect(d.left.mid, '\u{1F600}');
      expect(d.right.mid, '\u{1F601}');
      expect(d.left.prefix, 'a');
      expect(d.left.suffix, 'b');

      for (final part in [d.left, d.right]) {
        for (final piece in [part.prefix, part.mid, part.suffix]) {
          expect(_wellFormed(piece), isTrue,
              reason: 'broken UTF-16 in "$piece"');
        }
      }
    });
  });

  group('graph layout', () {
    test('keeps a linear history in one lane', () {
      final layout = layoutGraph([
        _c('c', ['b']),
        _c('b', ['a']),
        _c('a', []),
      ]);
      expect(layout.width, 1);
      expect(layout.rows.map((r) => r.myCol), [0, 0, 0]);
    });

    test('gives a merge two parent lanes and reuses them', () {
      final layout = layoutGraph([
        _c('m', ['a', 'b']),
        _c('a', ['base']),
        _c('b', ['base']),
        _c('base', []),
      ]);
      expect(layout.width, 2);
      expect(layout.rows[0].parentCols.length, 2,
          reason: 'merge fans out to both parents');
      expect(layout.rows[1].myCol, 0);
      expect(layout.rows[2].myCol, 1);
      // The lanes collapse back once both sides reach the shared ancestor.
      expect(layout.rows[3].myCol, 0);
      expect(layout.rows[3].outgoing, isEmpty);
    });

    test('tolerates parents outside the loaded page', () {
      final layout = layoutGraph([
        _c('x', ['missing'])
      ]);
      expect(layout.rows[0].myCol, 0);
      expect(layout.rows[0].outgoing, ['missing']);
    });
  });
}

GraphCommit _c(String id, List<String> parents) => GraphCommit(
      id: id,
      summary: id,
      author: 'a',
      time: 0,
      parents: parents,
      refs: const [],
    );

/// Dart has no String.isWellFormed, so this is the check the JS test gets from
/// the platform: no unpaired surrogate anywhere in the piece.
bool _wellFormed(String s) {
  for (var i = 0; i < s.length; i++) {
    final u = s.codeUnitAt(i);
    final isHigh = u >= 0xD800 && u <= 0xDBFF;
    final isLow = u >= 0xDC00 && u <= 0xDFFF;
    if (isHigh) {
      if (i + 1 >= s.length) return false;
      final next = s.codeUnitAt(i + 1);
      if (next < 0xDC00 || next > 0xDFFF) return false;
      i++;
    } else if (isLow) {
      return false;
    }
  }
  return true;
}
