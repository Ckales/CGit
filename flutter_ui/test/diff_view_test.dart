import 'package:cgit_flutter/diff_view.dart';
import 'package:cgit_flutter/git_text.dart';
import 'package:cgit_flutter/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Widget tests for the diff pane. They cover the one interaction that can
/// corrupt the index if it is wrong: which lines a click actually stages.
const hunk = '@@ -1,3 +1,4 @@ fn main\n a\n-b\n+B\n+c\n d\n';

Widget _host(Widget child) => MaterialApp(
      home: Theming(palette: Palette.dark, child: child),
    );

void main() {
  testWidgets('Go syntax is coloured in split and unified views',
      (tester) async {
    for (final mode in DiffMode.values) {
      await tester.pumpWidget(_host(DiffPane(
        file: 'main.go',
        hunks: const [
          '@@ -1 +1 @@\n-var old = "before"\n+var next = "after"\n'
        ],
        mode: mode,
      )));
      final spans = tester
          .widgetList<Text>(find.byType(Text))
          .map((text) => text.textSpan)
          .whereType<TextSpan>();
      final colours = <Color>{};
      void collect(InlineSpan span) {
        if (span is TextSpan) {
          if (span.style?.color case final color?) colours.add(color);
          for (final child in span.children ?? <InlineSpan>[]) {
            collect(child);
          }
        }
      }

      for (final span in spans) {
        collect(span);
      }
      expect(colours.length, greaterThanOrEqualTo(3), reason: '$mode');
      expect(find.textContaining('after', findRichText: true), findsOneWidget);
    }
  });

  testWidgets('new-file patch shows highlighted code instead of raw headers',
      (tester) async {
    await tester.pumpWidget(_host(const PatchPreview(
      file: 'main.go',
      mode: DiffMode.split,
      text: 'diff --git a/main.go b/main.go\nnew file mode 100644\n'
          '--- /dev/null\n+++ b/main.go\n@@ -0,0 +1,2 @@\n'
          '+package main\n+var name = "hello"\n',
    )));
    expect(find.textContaining('diff --git'), findsNothing);
    expect(find.text('1'), findsOneWidget);
    expect(find.textContaining('package main', findRichText: true),
        findsOneWidget);
    final code =
        tester.getRect(find.textContaining('package main', findRichText: true));
    expect(code.width, greaterThan(600));
  });

  testWidgets('split view numbers both sides and keeps the hunk header',
      (tester) async {
    await tester.pumpWidget(_host(
      const DiffPane(hunks: [hunk], mode: DiffMode.split),
    ));

    expect(find.text('@@ -1,3 +1,4 @@ fn main'), findsOneWidget);
    // Old side runs 1..3 (a, b, d); new side 1..4 (a, B, c, d). The add row
    // must leave the left cell — and its number — empty.
    expect(find.text('4'), findsOneWidget,
        reason: 'only the new side reaches 4');
  });

  testWidgets(
      'clicking a modified row selects both halves and stages exactly them',
      (tester) async {
    String? patch;
    bool? reverse;

    await tester.pumpWidget(_host(
      DiffPane(
        hunks: const [hunk],
        mode: DiffMode.split,
        onApply: (p, r) {
          patch = p;
          reverse = r;
        },
      ),
    ));

    // Row 2 is the modified one: left "-b" at old line 2, right "+B" at new
    // line 2. Both number cells read "2" and both sit inside that row.
    await tester.tap(find.text('2').first);
    await tester.pump();

    await tester.tap(find.text('暂存选中行'));
    await tester.pump();

    // A modified row carries two body indices, so one click selects two lines;
    // the unselected "+c" must be dropped and the counts rewritten to match.
    expect(patch, '@@ -1,3 +1,3 @@ fn main\n a\n-b\n+B\n d\n');
    expect(reverse, isFalse);

    // Selection clears once applied, so a second click cannot stage it twice.
    patch = null;
    await tester.tap(find.text('暂存选中行'));
    await tester.pump();
    expect(patch, isNull);
  });

  testWidgets('暂存此块 stages the whole hunk without picking lines',
      (tester) async {
    String? patch;
    await tester.pumpWidget(_host(
      DiffPane(
        hunks: const [hunk],
        mode: DiffMode.split,
        onApply: (p, _) => patch = p,
      ),
    ));

    expect(find.text('点选行，⇧ 点选范围'), findsOneWidget);
    // Nothing picked yet: the partial button is there but does nothing.
    await tester.tap(find.text('暂存选中行'));
    await tester.pump();
    expect(patch, isNull);

    await tester.tap(find.text('暂存此块'));
    await tester.pump();
    expect(patch, hunk);
  });

  testWidgets('a staged file stages in reverse', (tester) async {
    bool? reverse;
    await tester.pumpWidget(_host(
      DiffPane(
        hunks: const [hunk],
        mode: DiffMode.split,
        staged: true,
        onApply: (_, r) => reverse = r,
      ),
    ));

    expect(find.text('取消暂存此块'), findsOneWidget);
    await tester.tap(find.text('2').first);
    await tester.pump();

    await tester.tap(find.text('取消暂存选中行'));
    await tester.pump();
    expect(reverse, isTrue);
  });

  testWidgets('read-only panes offer nothing to stage', (tester) async {
    await tester.pumpWidget(_host(
      const DiffPane(hunks: [hunk], mode: DiffMode.split),
    ));

    await tester.tap(find.text('2').first);
    await tester.pump();
    expect(find.text('暂存此块'), findsNothing);
    expect(find.text('暂存选中行'), findsNothing);
  });

  testWidgets('unified view renders raw patch lines', (tester) async {
    await tester.pumpWidget(_host(
      const DiffPane(hunks: [hunk], mode: DiffMode.unified),
    ));

    expect(find.text('-b'), findsOneWidget);
    expect(find.text('+B'), findsOneWidget);
    expect(find.text('+c'), findsOneWidget);
  });

  testWidgets('an empty patch says so instead of rendering nothing',
      (tester) async {
    await tester.pumpWidget(_host(
      const DiffPane(hunks: [], mode: DiffMode.split),
    ));
    expect(find.text('没有文本差异'), findsOneWidget);
  });

  testWidgets('every change block key is attached, so ↑/↓ can scroll to it',
      (tester) async {
    for (final mode in DiffMode.values) {
      final keys = {
        for (final row in changeBlockRows(hunk, split: mode == DiffMode.split))
          '0:$row': GlobalKey(),
      };
      expect(keys, isNotEmpty);
      await tester.pumpWidget(_host(
        DiffPane(hunks: const [hunk], mode: mode, blockKeys: keys),
      ));
      for (final key in keys.values) {
        expect(key.currentContext, isNotNull, reason: '$mode');
      }
    }
  });
}
