import 'git.dart';

/// What to do with one commit in an interactive rebase.
enum RebaseAction { pick, reword, squash, fixup, drop }

const rebaseActionLabels = {
  RebaseAction.pick: '保留',
  RebaseAction.reword: '改写说明',
  RebaseAction.squash: '压缩合并',
  RebaseAction.fixup: '并入上一个',
  RebaseAction.drop: '删除',
};

/// One editable row of the todo list.
class RebaseStep {
  RebaseStep(this.oid, this.summary);

  final String oid;
  final String summary;
  RebaseAction action = RebaseAction.pick;

  /// The replacement message, only meaningful for [RebaseAction.reword].
  /// Null until the user types; the summary stands in until then.
  String? message;

  String get effectiveMessage {
    final typed = message?.trim();
    return (typed == null || typed.isEmpty) ? summary : typed;
  }
}

/// The plan a rebase dialog assembles, and the two strings git needs from it.
///
/// Kept apart from the widget because the ordering is load-bearing: git applies
/// the todo top to bottom, and the reword messages are consumed in that same
/// order by a queue. A mismatch between the two silently puts one commit's
/// message on another commit.
class RebasePlan {
  RebasePlan(this.steps);

  final List<RebaseStep> steps;

  static RebasePlan fromTodo(List<TodoCommit> todo) =>
      RebasePlan([for (final c in todo) RebaseStep(c.oid, c.summary)]);

  /// Move a step one place up or down. Out-of-range moves are ignored rather
  /// than clamped, so a held-down arrow key cannot quietly reorder anything.
  void move(int index, int by) {
    final target = index + by;
    if (index < 0 || index >= steps.length) return;
    if (target < 0 || target >= steps.length) return;
    final step = steps.removeAt(index);
    steps.insert(target, step);
  }

  /// The todo file git reads, one `action oid summary` line per step.
  String get todoText =>
      '${steps.map((s) => '${s.action.name} ${s.oid} ${s.summary}').join('\n')}\n';

  /// Replacement messages, in todo order — this is a queue git pops from as it
  /// reaches each reword, so the order has to match [todoText] exactly.
  List<String> get rewordMessages => [
        for (final s in steps)
          if (s.action == RebaseAction.reword) s.effectiveMessage,
      ];

  /// A plan that changes nothing is worth refusing: running it would rewrite
  /// every commit's hash for no benefit.
  bool get isNoop => steps.every((s) => s.action == RebaseAction.pick) &&
      !_reordered;

  bool _reorderedFlag = false;
  bool get _reordered => _reorderedFlag;
  void markReordered() => _reorderedFlag = true;

  /// The first step cannot squash or fix up: there is no earlier commit in the
  /// range to fold into, and git aborts the whole rebase when asked to.
  bool stepIsValid(int index) {
    if (index != 0) return true;
    final a = steps[0].action;
    return a != RebaseAction.squash && a != RebaseAction.fixup;
  }

  String? get problem {
    if (steps.isEmpty) return '没有可变基的提交';
    if (!stepIsValid(0)) return '第一个提交不能压缩或并入上一个——它前面没有提交';
    if (steps.every((s) => s.action == RebaseAction.drop)) {
      return '不能删除全部提交';
    }
    return null;
  }
}
