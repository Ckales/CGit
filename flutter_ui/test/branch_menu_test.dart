import 'package:cgit_flutter/branch_menu.dart';
import 'package:cgit_flutter/git.dart';
import 'package:flutter_test/flutter_test.dart';

/// Which entries a branch row offers depends on whether it is the checked-out
/// one. Getting it wrong offers actions that do nothing (check out the branch
/// you are on) or that git will refuse anyway (delete it), which reads as the
/// app being broken.
BranchInfo _branch(String name, {bool current = false}) =>
    BranchInfo(name: name, isCurrent: current);

List<MenuEntry> _entries(BranchInfo b, String current) {
  final calls = <BranchCommand>[];
  final items = branchMenu(
    branch: b,
    currentBranch: current,
    run: calls.add,
  );
  return [
    for (final i in items)
      MenuEntry(i.label, enabled: i.enabled, danger: i.danger, fire: i.onTap),
  ];
}

class MenuEntry {
  MenuEntry(this.label, {required this.enabled, required this.danger, required this.fire});
  final String label;
  final bool enabled;
  final bool danger;
  final void Function() fire;
}

void main() {
  test('another branch offers checkout and merge', () {
    final labels =
        _entries(_branch('feature'), 'main').map((e) => e.label).toList();

    expect(labels, contains('检出'));
    expect(labels, contains("将 'feature' 合并到 'main' 中"));
    expect(labels, contains("从 'feature' 新建分支…"));
  });

  test('the checked-out branch drops the two no-op entries', () {
    final labels =
        _entries(_branch('main', current: true), 'main').map((e) => e.label).toList();

    expect(labels, isNot(contains('检出')),
        reason: 'checking out the branch you are on does nothing');
    expect(labels.where((l) => l.contains('合并到')), isEmpty,
        reason: 'a branch cannot be merged into itself');
    // The rest still apply: you can branch from it, update it, push it, rename it.
    expect(labels, contains('更新'));
    expect(labels, contains('推送'));
    expect(labels, contains('重命名…'));
  });

  test('deleting is offered but disabled on the checked-out branch', () {
    final onCurrent =
        _entries(_branch('main', current: true), 'main').firstWhere((e) => e.label == '删除');
    final onOther =
        _entries(_branch('feature'), 'main').firstWhere((e) => e.label == '删除');

    expect(onCurrent.enabled, isFalse);
    expect(onOther.enabled, isTrue);
    // Both are marked destructive either way.
    expect(onCurrent.danger, isTrue);
    expect(onOther.danger, isTrue);
  });

  test('a detached HEAD offers no merge target', () {
    // currentBranch is empty when HEAD is not on a branch: there is no name to
    // put in the label and nothing to receive the merge.
    final labels = _entries(_branch('feature'), '').map((e) => e.label).toList();

    expect(labels.where((l) => l.contains('合并到')), isEmpty);
    expect(labels, contains('检出'), reason: 'checking one out is still valid');
  });

  test('each entry dispatches its own command', () {
    final calls = <BranchCommand>[];
    final items = branchMenu(
      branch: _branch('feature'),
      currentBranch: 'main',
      run: calls.add,
    );

    for (final item in items) {
      item.onTap();
    }

    expect(calls, [
      BranchCommand.checkout,
      BranchCommand.newFrom,
      BranchCommand.mergeInto,
      BranchCommand.update,
      BranchCommand.push,
      BranchCommand.rename,
      BranchCommand.delete,
    ]);
  });
}
