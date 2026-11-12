import 'package:cgit_flutter/git_text.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  List<MergeGroupKind> kinds(ThreeWayMerge m) =>
      [for (final g in m.groups) g.kind];

  test('changes on different sides merge without a conflict', () {
    final m = threeWayMerge(
      base: 'a\nb\nc\nd\ne',
      ours: 'a\nB\nc\nd\ne',
      theirs: 'a\nb\nc\nD\ne',
    );

    expect(kinds(m), [
      MergeGroupKind.common,
      MergeGroupKind.oursOnly,
      MergeGroupKind.common,
      MergeGroupKind.theirsOnly,
      MergeGroupKind.common,
    ]);
    expect(m.groups[1].oursLines, ['B']);
    expect(m.groups[1].theirsLines, ['b']);
    expect(m.groups[3].oursLines, ['d']);
    expect(m.groups[3].theirsLines, ['D']);
    expect(m.hasConflict, isFalse);
  });

  test('overlapping edits are one conflict group', () {
    final m = threeWayMerge(
      base: 'head\nbase\ntail',
      ours: 'head\nmine\ntail',
      theirs: 'head\nyours\ntail',
    );

    expect(kinds(m), [
      MergeGroupKind.common,
      MergeGroupKind.conflict,
      MergeGroupKind.common,
    ]);
    final conflict = m.groups[1];
    expect(conflict.baseLines, ['base']);
    expect(conflict.oursLines, ['mine']);
    expect(conflict.theirsLines, ['yours']);
    expect(conflict.rows.length, 1);
    expect(conflict.rows.single.base, 'base');
    expect(conflict.rows.single.ours, 'mine');
    expect(conflict.rows.single.theirs, 'yours');
  });

  test('the same edit on both sides is not a conflict', () {
    final m = threeWayMerge(
      base: 'a\nb',
      ours: 'a\nsame',
      theirs: 'a\nsame',
    );
    expect(kinds(m), [MergeGroupKind.common, MergeGroupKind.bothSame]);
    expect(m.groups[1].oursLines, ['same']);
    expect(m.groups[1].theirsLines, ['same']);
    expect(m.hasConflict, isFalse);
  });

  test('an insertion keeps a balanced row for the other side', () {
    final m = threeWayMerge(
      base: 'a\nb',
      ours: 'a\ninserted\nb',
      theirs: 'a\nb',
    );

    final inserted = m.groups[1];
    expect(inserted.kind, MergeGroupKind.oursOnly);
    expect(inserted.baseLines, isEmpty);
    expect(inserted.oursLines, ['inserted']);
    expect(inserted.rows.single.ours, 'inserted');
    expect(inserted.rows.single.theirs, isNull);

    // The rows before and after remain real context rows.
    expect(m.groups[0].rows.single.ours, 'a');
    expect(m.groups[2].rows.single.ours, 'b');
  });

  test('a deletion leaves a blank cell on the deleting side', () {
    final m = threeWayMerge(
      base: 'a\nb\nc',
      ours: 'a\nc',
      theirs: 'a\nb\nc',
    );

    final deleted = m.groups[1];
    expect(deleted.kind, MergeGroupKind.oursOnly);
    expect(deleted.oursLines, isEmpty);
    expect(deleted.rows.single.ours, isNull);
    expect(deleted.rows.single.theirs, 'b');
  });

  test('add/add without a base still produces one conflict group', () {
    final m = threeWayMerge(base: '', ours: 'ours\n', theirs: 'theirs\n');
    expect(m.groups.length, 1);
    expect(m.groups.single.kind, MergeGroupKind.conflict);
    expect(m.groups.single.oursLines, ['ours', '']);
    expect(m.groups.single.theirsLines, ['theirs', '']);
  });

  test('multiple conflicts keep their own groups and context', () {
    final m = threeWayMerge(
      base: 'a\nb\nc\nd\ne',
      ours: 'a\nB\nc\nD\ne',
      theirs: 'a\nX\nc\nY\ne',
    );
    expect(kinds(m), [
      MergeGroupKind.common,
      MergeGroupKind.conflict,
      MergeGroupKind.common,
      MergeGroupKind.conflict,
      MergeGroupKind.common,
    ]);
  });
}
