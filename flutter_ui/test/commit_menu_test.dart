import 'package:cgit_flutter/commit_menu.dart';
import 'package:flutter_test/flutter_test.dart';

/// This menu holds the only entry in the app that can destroy uncommitted work
/// (hard reset) and several that rewrite history. What matters is that the
/// dangerous one is marked, that each entry dispatches its own command, and
/// that an unavailable entry is visibly unavailable rather than silently inert.
void main() {
  test('every entry dispatches its own command, in order', () {
    final calls = <CommitCommand>[];
    for (final item in commitMenu(run: calls.add)) {
      item.onTap();
    }

    expect(calls, [
      CommitCommand.resetMixed,
      CommitCommand.resetSoft,
      CommitCommand.resetHard,
      CommitCommand.revert,
      CommitCommand.cherryPick,
      CommitCommand.rebaseFrom,
      CommitCommand.tag,
      CommitCommand.patchToClipboard,
      CommitCommand.patchToFile,
    ]);
  });

  test('only the hard reset is marked destructive', () {
    final items = commitMenu(run: (_) {});
    final danger = items.where((i) => i.danger).map((i) => i.label).toList();

    // soft and mixed keep the work; revert and cherry-pick add commits rather
    // than dropping any. Marking more than one dilutes the warning.
    expect(danger, ['重置(hard)到此']);
  });

  test('the patch choice is flat, not nested behind one entry', () {
    final labels = commitMenu(run: (_) {}).map((i) => i.label).toList();

    expect(labels, contains('创建补丁到剪贴板'));
    expect(labels, contains('创建补丁到文件…'));
    expect(labels, isNot(contains('创建补丁')),
        reason: 'a binary choice does not earn a submenu');
  });

  test('the file option can be disabled without disappearing', () {
    final items = commitMenu(run: (_) {}, canPatchToFile: false);
    final toFile = items.firstWhere((i) => i.label == '创建补丁到文件…');

    // Still listed: the user should see the feature exists and is unavailable,
    // not wonder whether the app can do it at all.
    expect(toFile.enabled, isFalse);
    expect(items.firstWhere((i) => i.label == '创建补丁到剪贴板').enabled, isTrue);
  });

  test('an ellipsis marks the entries that open a dialog', () {
    final labels = commitMenu(run: (_) {}).map((i) => i.label).toList();
    final withDialog = labels.where((l) => l.endsWith('…')).toList();

    expect(withDialog, ['在此提交上打标签…', '创建补丁到文件…']);
  });
}
