import 'package:cgit_flutter/git.dart';
import 'package:cgit_flutter/rebase_plan.dart';
import 'package:flutter_test/flutter_test.dart';

/// An interactive rebase rewrites history. The part that can go wrong silently
/// is the pairing between the todo list and the reword queue: git pops one
/// message per reword as it walks the todo top to bottom, so a mismatch does
/// not fail — it puts one commit's message onto another commit.
RebasePlan _plan(List<(String, String)> commits) => RebasePlan.fromTodo([
      for (final (oid, summary) in commits)
        TodoCommit(oid: oid, summary: summary),
    ]);

void main() {
  group('todo text', () {
    test('defaults every commit to pick, oldest first', () {
      final plan = _plan([('aaa', 'first'), ('bbb', 'second')]);
      expect(plan.todoText, 'pick aaa first\npick bbb second\n');
    });

    test('reflects the chosen action per commit', () {
      final plan = _plan([('aaa', 'first'), ('bbb', 'second')]);
      plan.steps[1].action = RebaseAction.fixup;
      expect(plan.todoText, 'pick aaa first\nfixup bbb second\n');
    });
  });

  group('reordering', () {
    test('moving a step down swaps it with the next', () {
      final plan = _plan([('aaa', 'a'), ('bbb', 'b'), ('ccc', 'c')]);
      plan.move(0, 1);
      expect(plan.steps.map((s) => s.oid), ['bbb', 'aaa', 'ccc']);
    });

    test('moving past either end does nothing', () {
      final plan = _plan([('aaa', 'a'), ('bbb', 'b')]);
      plan.move(0, -1);
      plan.move(1, 1);
      expect(plan.steps.map((s) => s.oid), ['aaa', 'bbb']);
    });
  });

  group('reword messages', () {
    test('are emitted in todo order, not commit order', () {
      final plan = _plan([('aaa', 'a'), ('bbb', 'b'), ('ccc', 'c')]);
      plan.steps[0].action = RebaseAction.reword;
      plan.steps[0].message = 'first reworded';
      plan.steps[2].action = RebaseAction.reword;
      plan.steps[2].message = 'third reworded';

      // Move the third commit to the top: the queue has to follow.
      plan.move(2, -2);

      expect(plan.steps.map((s) => s.oid), ['ccc', 'aaa', 'bbb']);
      expect(plan.rewordMessages, ['third reworded', 'first reworded'],
          reason: 'the queue is consumed in todo order');
    });

    test('only rewords contribute a message', () {
      final plan = _plan([('aaa', 'a'), ('bbb', 'b')]);
      plan.steps[0].action = RebaseAction.squash;
      plan.steps[0].message = 'ignored';
      plan.steps[1].action = RebaseAction.reword;
      plan.steps[1].message = 'kept';

      expect(plan.rewordMessages, ['kept']);
    });

    test('an untouched or blanked reword falls back to the summary', () {
      final plan = _plan([('aaa', 'original summary')]);
      plan.steps[0].action = RebaseAction.reword;
      expect(plan.rewordMessages, ['original summary']);

      plan.steps[0].message = '   ';
      expect(plan.rewordMessages, ['original summary'],
          reason: 'an empty message would wipe the commit subject');
    });
  });

  group('refusals', () {
    test('the first commit cannot squash or fix up', () {
      final plan = _plan([('aaa', 'a'), ('bbb', 'b')]);
      plan.steps[0].action = RebaseAction.squash;

      // git aborts the whole rebase on this, so it is caught before starting.
      expect(plan.stepIsValid(0), isFalse);
      expect(plan.problem, contains('第一个提交'));

      plan.steps[0].action = RebaseAction.fixup;
      expect(plan.problem, isNotNull);
    });

    test('dropping everything is refused', () {
      final plan = _plan([('aaa', 'a'), ('bbb', 'b')]);
      for (final s in plan.steps) {
        s.action = RebaseAction.drop;
      }
      expect(plan.problem, '不能删除全部提交');
    });

    test('an empty range is refused', () {
      expect(_plan([]).problem, '没有可变基的提交');
    });

    test('a plan that changes nothing is a no-op', () {
      final plan = _plan([('aaa', 'a'), ('bbb', 'b')]);
      expect(plan.isNoop, isTrue,
          reason: 'running it would rewrite every hash for nothing');

      plan.markReordered();
      expect(plan.isNoop, isFalse);
    });

    test('a valid plan has no problem', () {
      final plan = _plan([('aaa', 'a'), ('bbb', 'b')]);
      plan.steps[1].action = RebaseAction.squash;
      expect(plan.problem, isNull);
    });
  });
}
