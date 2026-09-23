import 'context_menu.dart';
import 'git.dart';

/// What a branch menu entry does. The rules for which entries appear are worth
/// testing on their own, so they live here rather than inside the widget.
enum BranchCommand {
  checkout,
  newFrom,
  mergeInto,
  update,
  push,
  rename,
  delete,
  applyPatchFromFile,
  applyPatchFromClipboard,
}

/// Build the context menu for one branch row.
///
/// The branch already checked out drops the two entries that would do nothing
/// on it — checking it out again, and merging it into itself — and cannot be
/// deleted. git refuses the delete anyway, but a greyed-out entry says so
/// before the click rather than after it.
List<MenuAction> branchMenu({
  required BranchInfo branch,
  required String currentBranch,
  required void Function(BranchCommand command) run,
}) {
  final name = branch.name;
  return [
    if (!branch.isCurrent)
      MenuAction('检出', () => run(BranchCommand.checkout)),
    MenuAction("从 '$name' 新建分支…", () => run(BranchCommand.newFrom)),
    // Merging needs somewhere to merge *into*; a detached HEAD has no name to
    // put in the label and no branch to receive the merge.
    if (!branch.isCurrent && currentBranch.isNotEmpty)
      MenuAction(
        "将 '$name' 合并到 '$currentBranch' 中",
        () => run(BranchCommand.mergeInto),
      ),
    MenuAction('更新', () => run(BranchCommand.update)),
    MenuAction('推送', () => run(BranchCommand.push)),
    // A patch lands in the working tree, and that only ever belongs to the
    // checked-out branch — offering these elsewhere would either lie or smuggle
    // in a checkout. Flattened from the Tauri submenu: the choice is binary.
    if (branch.isCurrent) ...[
      MenuAction('应用补丁（从文件）…', () => run(BranchCommand.applyPatchFromFile)),
      MenuAction('应用补丁（从剪贴板）',
          () => run(BranchCommand.applyPatchFromClipboard)),
    ],
    MenuAction('重命名…', () => run(BranchCommand.rename)),
    MenuAction(
      '删除',
      () => run(BranchCommand.delete),
      danger: true,
      enabled: !branch.isCurrent,
    ),
  ];
}
