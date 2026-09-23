import 'context_menu.dart';

/// What a history row's context menu can do.
enum CommitCommand {
  resetMixed,
  resetSoft,
  resetHard,
  revert,
  cherryPick,
  rebaseFrom,
  tag,
  patchToClipboard,
  patchToFile,
}

/// Build the context menu for one commit in the history list.
///
/// The three resets are listed separately rather than nested: they differ only
/// in how much they throw away, and burying that behind a hover makes the
/// dangerous one easier to reach by accident, not harder.
///
/// The Tauri menu nests "创建补丁" over a file/clipboard pair. Flattened here:
/// the choice is binary, so a submenu costs a hover and buys nothing — and
/// Flutter has no equivalent of the timer that keeps a submenu open while the
/// pointer crosses to it.
List<MenuAction> commitMenu({
  required void Function(CommitCommand command) run,
  bool canPatchToFile = true,
}) =>
    [
      MenuAction('重置(mixed)到此', () => run(CommitCommand.resetMixed)),
      MenuAction('重置(soft)到此', () => run(CommitCommand.resetSoft)),
      // The only one that destroys uncommitted work.
      MenuAction('重置(hard)到此', () => run(CommitCommand.resetHard),
          danger: true),
      MenuAction('回退此提交', () => run(CommitCommand.revert)),
      MenuAction('拣选到当前分支', () => run(CommitCommand.cherryPick)),
      MenuAction('从此处交互式变基', () => run(CommitCommand.rebaseFrom)),
      MenuAction('在此提交上打标签…', () => run(CommitCommand.tag)),
      MenuAction('创建补丁到剪贴板', () => run(CommitCommand.patchToClipboard)),
      MenuAction(
        '创建补丁到文件…',
        () => run(CommitCommand.patchToFile),
        enabled: canPatchToFile,
      ),
    ];
