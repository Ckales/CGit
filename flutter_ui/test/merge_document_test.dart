import 'package:cgit_flutter/git_text.dart';
import 'package:cgit_flutter/merge_document.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  MergeDocument document(String text) => MergeDocument(parseConflicts(text));
  const first = '<<<<<<< HEAD\nmine\n=======\nyours\n>>>>>>> branch';

  test('unresolved three-way insertions start from base, without taking a side',
      () {
    const base = 'head\nobject_to_array\ntail\n';
    const ours = 'head\nfailFormat\nobject_to_array\ntail\n';
    const theirs = 'head\nshowData\nobject_to_array\ntail\n';
    final d = MergeDocument.threeWay(base: base, ours: ours, theirs: theirs);
    expect(d.text, base);
    expect(d.undecided, 1);
    d.choose(0, ours: true);
    expect(d.text, ours);
    d.undo();
    expect(d.text, base);
    expect(d.undecided, 1);
    d.choose(0, theirs: true);
    expect(d.text, theirs);
  });

  test('every three-way change starts from the complete ancestor', () {
    final d = MergeDocument.threeWay(
        base: 'a\nbase\nc\nd\ne',
        ours: 'a\nmine\nc\nd\ne',
        theirs: 'a\nyours\nc\nd\nchanged');
    expect(d.text, 'a\nbase\nc\nd\ne');
    expect(d.undecided, 1);
    d.edit('a\nhand edited\nc\nd\ne');
    d.choose(0, theirs: true);
    expect(d.text, 'a\nyours\nc\nd\ne');
    d.undo();
    expect(d.text, 'a\nhand edited\nc\nd\ne');
  });

  test(
      'bulk accepts only pending clean changes and leaves conflicts unresolved',
      () {
    const base = 'a\nb\nc\nd\ne\nf\ng';
    final d = MergeDocument.threeWay(
        base: base,
        ours: 'a\nOURS b\nc\nOURS d\ne\nf\ng',
        theirs: 'a\nb\nc\nTHEIRS d\ne\nf\nTHEIRS g');
    expect(d.text, base);
    d.acceptNonConflicting();
    expect(d.text, 'a\nOURS b\nc\nd\ne\nf\nTHEIRS g');
    expect(d.undecided, 1);
    expect(d.conflictStates.single.ours, isNull);
    expect(d.conflictStates.single.theirs, isNull);
    d.undo();
    expect(d.text, base);
    d.redo();
    expect(d.text, 'a\nOURS b\nc\nd\ne\nf\nTHEIRS g');
    expect(d.undecided, 1);
  });

  test('bulk accept can be limited to one side', () {
    final d = MergeDocument.threeWay(
        base: 'a\nb\nc\nd\ne\nf\ng',
        ours: 'a\nOURS b\nc\nd\ne\nf\ng',
        theirs: 'a\nb\nc\nTHEIRS d\ne\nf\nTHEIRS g');
    d.acceptNonConflicting(ours: true);
    expect(d.text, 'a\nOURS b\nc\nd\ne\nf\ng');
    d.acceptNonConflicting(ours: false);
    expect(d.text, 'a\nOURS b\nc\nTHEIRS d\ne\nf\nTHEIRS g');
    d.undo();
    expect(d.text, 'a\nOURS b\nc\nd\ne\nf\ng');
  });

  test('identical edits also wait for acceptance and can be ignored', () {
    final d = MergeDocument.threeWay(
        base: 'a\nbase\nc', ours: 'a\nsame\nc', theirs: 'a\nsame\nc');
    expect(d.text, 'a\nbase\nc');
    final index = d.differenceGroupIndices.single;
    d.chooseChange(index, accept: true);
    expect(d.text, 'a\nsame\nc');
    d.chooseChange(index, accept: false);
    expect(d.text, 'a\nbase\nc');
    d.acceptNonConflicting();
    expect(d.text, 'a\nbase\nc', reason: 'an explicit ignore is preserved');
  });

  test('bulk merging preserves hand edits and existing conflict decisions', () {
    final d = MergeDocument.threeWay(
        base: 'a\nb\nc\nd\ne\nf\ng',
        ours: 'a\nOURS b\nc\nOURS d\ne\nf\ng',
        theirs: 'a\nb\nc\nTHEIRS d\ne\nf\nTHEIRS g');
    d.edit('a\nhand b\nc\nd\ne\nf\ng');
    d.choose(0, theirs: true);
    d.acceptNonConflicting();
    expect(d.text, 'a\nhand b\nc\nTHEIRS d\ne\nf\nTHEIRS g');
    expect(d.undecided, 0);
  });

  test('add/add starts from the empty ancestor and still needs a decision', () {
    final d = MergeDocument.threeWay(ours: 'ours\n', theirs: 'theirs\n');
    expect(d.text, '');
    expect(d.undecided, 1);
    d.choose(0, theirs: true);
    expect(d.text, 'theirs\n');
  });

  test('ignoring both changes keeps the ancestor instead of deleting its lines',
      () {
    final d = MergeDocument.threeWay(
        base: 'head\nbase\ntail',
        ours: 'head\nmine\ntail',
        theirs: 'head\nyours\ntail');
    d.choose(0, ours: false);
    expect(d.text, 'head\nbase\ntail');
    expect(d.undecided, 1);
    d.choose(0, theirs: false);
    expect(d.text, 'head\nbase\ntail');
    expect(d.undecided, 0);
    d.undo();
    expect(d.undecided, 1);
    d.choose(0, theirs: true);
    expect(d.text, 'head\nyours\ntail');
  });

  test(
      'adjacent and empty conflicts give the same output in either decision order',
      () {
    for (final ours in ['', 'mine\n', '\n']) {
      final marker = '<<<<<<< HEAD\n$ours=======\nyours\n>>>>>>> branch';
      for (final prefix in ['', 'head\n']) {
        for (final suffix in ['', '\n', '\ntail']) {
          for (final a in ['ours', 'theirs', 'both', 'none']) {
            for (final b in ['ours', 'theirs', 'both', 'none']) {
              for (final order in [
                [0, 1],
                [1, 0]
              ]) {
                final input = '$prefix$marker\n$marker$suffix';
                final d = document(input);
                for (final i in order) {
                  final choice = [a, b][i];
                  d.choose(i,
                      ours: choice == 'ours' || choice == 'both',
                      theirs: choice == 'theirs' || choice == 'both');
                }
                final expected = parseConflicts(input);
                var i = 0;
                for (final block in expected.blocks) {
                  if (block.type == BlockType.conflict) {
                    block.resolution = [a, b][i++];
                  }
                }
                expect(d.text, assembleConflict(expected.blocks),
                    reason: '$input / $a $b / $order');
              }
            }
          }
        }
      }
    }
  });

  test('starts with a readable complete document, without resolving conflicts',
      () {
    final d = document('head\n$first\ntail\n');
    expect(d.text, 'head\nmine\ntail\n');
    expect(d.undecided, 1);
  });

  test('side choices replace only their range after context edits', () {
    final d = document('head\n$first\ntail');
    d.edit('edited head\nmine\ntail');
    d.edit('edited head\nmine\nedited tail');
    d.choose(0, ours: false, theirs: true);
    expect(d.text, 'edited head\nyours\nedited tail');
    expect(d.undecided, 0);
    d.undo();
    expect(d.text, 'edited head\nmine\nedited tail');
    d.redo();
    expect(d.text, 'edited head\nyours\nedited tail');
  });

  test('typing in one conflict does not settle the next conflict', () {
    final d = document('head\n$first\nbetween\n$first\ntail');
    d.edit(d.text.replaceFirst('mine', 'hand merged\nextra'));
    expect(d.undecided, 1);
    d.choose(1, ours: false, theirs: true);
    expect(d.text, 'head\nhand merged\nextra\nbetween\nyours\ntail');
    d.undo();
    expect(d.undecided, 1);
    d.undo();
    expect(d.undecided, 2);
  });

  test('deleting either edge conflict does not add empty lines', () {
    for (final pair in [
      ('$first\ntail', 'tail'),
      ('head\n$first', 'head'),
      ('head\n$first\ntail', 'head\ntail'),
      (first, ''),
      ('$first\n', ''),
    ]) {
      final d = document(pair.$1);
      d.choose(0, ours: false, theirs: false);
      expect(d.text, pair.$2, reason: pair.$1);
      d.choose(0, ours: false, theirs: true);
      expect(d.text, pair.$1.replaceAll(first, 'yours'));
    }
  });

  test(
      'empty-side insertions and adjacent conflicts stay independently editable',
      () {
    const empty = '<<<<<<< HEAD\n=======\nadded\n>>>>>>> branch';
    final d = document('$empty\n$first\ntail');
    d.choose(0, ours: false, theirs: true);
    d.choose(1, ours: false, theirs: true);
    expect(d.text, 'added\nyours\ntail');
    d.choose(0, ours: false, theirs: false);
    expect(d.text, 'yours\ntail');
  });

  test('replacement across context and conflict preserves inserted context',
      () {
    final d = document('head\n$first\ntail');
    d.edit('my replacement\ntail');
    d.choose(0, ours: false, theirs: true);
    expect(d.text, 'my replacement\nyours\ntail');
  });
}
