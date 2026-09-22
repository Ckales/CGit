import 'package:cgit_flutter/diff_view.dart';
import 'package:cgit_flutter/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The widget half of the port. The JS version has no equivalent suite — its
/// rendering is only exercised by hand — so these cover the one interaction
/// that can corrupt the index if it is wrong: which lines a click actually
/// stages.
const hunk = '@@ -1,3 +1,4 @@ fn main\n a\n-b\n+B\n+c\n d\n';

Widget _host(Widget child) => MaterialApp(
      home: Theming(palette: Palette.dark, child: child),
    );

void main() {
  testWidgets('split view numbers both sides and keeps the hunk header', (tester) async {
    await tester.pumpWidget(_host(
      const DiffPane(hunks: [hunk], mode: DiffMode.split),
    ));

    expect(find.text('@@ -1,3 +1,4 @@ fn main'), findsOneWidget);
    // Old side runs 1..3 (a, b, d); new side 1..4 (a, B, c, d). The add row
    // must leave the left cell — and its number — empty.
    expect(find.text('4'), findsOneWidget, reason: 'only the new side reaches 4');
  });

  testWidgets('clicking a modified row selects both halves and stages exactly them',
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

    // A modified row carries two body indices, so one click selects two lines.
    expect(find.text('已选 2 行'), findsOneWidget);

    await tester.tap(find.text('暂存所选'));
    await tester.pump();

    // The unselected "+c" must be dropped and the counts rewritten to match.
    expect(patch, '@@ -1,3 +1,3 @@ fn main\n a\n-b\n+B\n d\n');
    expect(reverse, isFalse);
    // Selection clears once applied, so a second click cannot stage it twice.
    expect(find.textContaining('已选'), findsNothing);
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

    await tester.tap(find.text('2').first);
    await tester.pump();
    expect(find.text('取消暂存所选'), findsOneWidget);

    await tester.tap(find.text('取消暂存所选'));
    await tester.pump();
    expect(reverse, isTrue);
  });

  testWidgets('read-only panes offer nothing to stage', (tester) async {
    await tester.pumpWidget(_host(
      const DiffPane(hunks: [hunk], mode: DiffMode.split),
    ));

    await tester.tap(find.text('2').first);
    await tester.pump();
    expect(find.textContaining('已选'), findsNothing);
    expect(find.text('暂存所选'), findsNothing);
  });

  testWidgets('unified view renders raw patch lines', (tester) async {
    await tester.pumpWidget(_host(
      const DiffPane(hunks: [hunk], mode: DiffMode.unified),
    ));

    expect(find.text('-b'), findsOneWidget);
    expect(find.text('+B'), findsOneWidget);
    expect(find.text('+c'), findsOneWidget);
  });

  testWidgets('an empty patch says so instead of rendering nothing', (tester) async {
    await tester.pumpWidget(_host(
      const DiffPane(hunks: [], mode: DiffMode.split),
    ));
    expect(find.text('没有文本差异'), findsOneWidget);
  });
}
