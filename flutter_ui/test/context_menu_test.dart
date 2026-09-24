import 'package:cgit_flutter/context_menu.dart';
import 'package:cgit_flutter/theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Context menus are how the destructive actions are reached (drop a stash,
/// delete a branch), so what matters is that the right entry fires and that a
/// dangerous one is visibly marked before it does.
Widget _host(Widget child) => MaterialApp(
      home: Theming(
        palette: Palette.dark,
        child: Material(
          type: MaterialType.transparency,
          child: Center(child: child),
        ),
      ),
    );

void main() {
  testWidgets('a right click opens the menu and the picked action fires',
      (tester) async {
    final fired = <String>[];

    await tester.pumpWidget(_host(
      ContextMenuRegion(
        items: () => [
          MenuAction('弹出', () => fired.add('pop')),
          MenuAction('删除', () => fired.add('drop'), danger: true),
        ],
        child: const SizedBox(width: 200, height: 24, child: Text('stash@0')),
      ),
    ));

    await tester.tapAt(tester.getCenter(find.text('stash@0')),
        buttons: kSecondaryButton);
    await tester.pumpAndSettle();

    expect(find.text('弹出'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);

    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(fired, ['drop'], reason: 'only the picked entry runs');
  });

  testWidgets('a destructive entry is tinted apart from the harmless ones',
      (tester) async {
    await tester.pumpWidget(_host(
      ContextMenuRegion(
        items: () => [
          MenuAction('弹出', () {}),
          MenuAction('删除', () {}, danger: true),
        ],
        child: const SizedBox(width: 200, height: 24, child: Text('row')),
      ),
    ));

    await tester.tapAt(tester.getCenter(find.text('row')),
        buttons: kSecondaryButton);
    await tester.pumpAndSettle();

    Color colorOf(String label) =>
        tester.widget<Text>(find.text(label)).style!.color!;

    expect(colorOf('删除'), Palette.dark.red);
    expect(colorOf('弹出'), isNot(Palette.dark.red));
  });

  testWidgets('a disabled entry cannot be picked', (tester) async {
    var fired = false;

    await tester.pumpWidget(_host(
      ContextMenuRegion(
        items: () => [
          MenuAction('继续', () => fired = true, enabled: false),
        ],
        child: const SizedBox(width: 200, height: 24, child: Text('row')),
      ),
    ));

    await tester.tapAt(tester.getCenter(find.text('row')),
        buttons: kSecondaryButton);
    await tester.pumpAndSettle();

    await tester.tap(find.text('继续'));
    await tester.pumpAndSettle();
    expect(fired, isFalse);
  });

  testWidgets('the entries are rebuilt per open, not captured once',
      (tester) async {
    var label = '第一次';

    await tester.pumpWidget(_host(
      ContextMenuRegion(
        items: () => [MenuAction(label, () {})],
        child: const SizedBox(width: 200, height: 24, child: Text('row')),
      ),
    ));

    await tester.tapAt(tester.getCenter(find.text('row')),
        buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('第一次'), findsOneWidget);

    // Dismiss, change the state the menu depends on, reopen.
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    label = '第二次';

    await tester.tapAt(tester.getCenter(find.text('row')),
        buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('第二次'), findsOneWidget,
        reason: 'a menu built once would still say 第一次');
  });

  testWidgets(
      'a dropdown opens in the same place wherever the button is clicked',
      (tester) async {
    await tester.pumpWidget(_host(
      Builder(
        builder: (context) => GestureDetector(
          onTapUp: (_) => showRepoMenu(
            context: context,
            position: menuAnchorBelow(context),
            items: [
              const MenuAction.header('最近的项目'),
              MenuAction('CGit', () {}, sublabel: '~/Work/codelab/CGit'),
            ],
          ),
          child: const SizedBox(width: 200, height: 24, child: Text('pill')),
        ),
      ),
    ));

    final box = tester.getRect(find.text('pill'));
    Future<Offset> openAt(Offset at) async {
      await tester.tapAt(at);
      await tester.pumpAndSettle();
      final where = tester.getTopLeft(find.text('CGit'));
      await tester.tapAt(const Offset(1, 1)); // dismiss
      await tester.pumpAndSettle();
      return where;
    }

    final left = await openAt(box.centerLeft + const Offset(5, 0));
    final right = await openAt(box.centerRight - const Offset(5, 0));
    expect(right, left, reason: 'the menu must not follow the pointer');
  });

  /// The menu's own box: the nearest Material around one of its rows.
  Rect menuRect(WidgetTester tester, String label) => tester.getRect(find
      .ancestor(of: find.text(label), matching: find.byType(Material))
      .first);

  testWidgets('a right-click menu opens centred right below the pointer',
      (tester) async {
    await tester.pumpWidget(_host(
      ContextMenuRegion(
        items: () => [MenuAction('复制文件路径', () {})],
        child: const SizedBox(width: 600, height: 24, child: Text('row')),
      ),
    ));

    final row = tester.getRect(find.text('row'));
    // Either half of the window: showMenu used to flip sides between them.
    for (final at in [
      row.centerLeft + const Offset(120, 0),
      row.centerRight - const Offset(120, 0),
    ]) {
      await tester.tapAt(at, buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      final menu = menuRect(tester, '复制文件路径');
      expect(menu.center.dx, moreOrLessEquals(at.dx, epsilon: 0.5));
      expect(menu.top, moreOrLessEquals(at.dy, epsilon: 0.5));
      await tester.tapAt(const Offset(1, 1)); // dismiss
      await tester.pumpAndSettle();
    }
  });

  testWidgets(
      'a right-click menu near the bottom opens right above the pointer',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Theming(
        palette: Palette.dark,
        child: Material(
          type: MaterialType.transparency,
          child: Align(
            alignment: Alignment.bottomCenter,
            child: ContextMenuRegion(
              items: () => [
                for (final label in ['从项目打开', '编辑文件', '复制文件路径', '文件历史'])
                  MenuAction(label, () {}),
              ],
              child: const SizedBox(width: 600, height: 24, child: Text('row')),
            ),
          ),
        ),
      ),
    ));

    final at = tester.getCenter(find.text('row'));
    await tester.tapAt(at, buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    final menu = menuRect(tester, '从项目打开');
    expect(menu.bottom, moreOrLessEquals(at.dy, epsilon: 0.5),
        reason: 'the menu ends at the pointer instead of sliding over it');
    expect(menu.center.dx, moreOrLessEquals(at.dx, epsilon: 0.5));
  });
}
