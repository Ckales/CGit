import 'dart:ui'
    show PointerDeviceKind, ViewFocusDirection, ViewFocusEvent, ViewFocusState;

import 'package:cgit_flutter/context_menu.dart';
import 'package:cgit_flutter/prefs.dart';
import 'package:cgit_flutter/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The barrier only dismisses a tap inside this window. Switching away used to
/// leave the menu up, still there when the window came back.
void main() {
  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Theming(
        palette: Palette.dark,
        child: Builder(
          builder: (context) => TextButton(
            onPressed: () => showRepoMenu(
              context: context,
              position: const Offset(40, 40),
              items: [MenuAction('检出', () {})],
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('检出'), findsOneWidget);
  }

  testWidgets('closes when the window loses focus', (tester) async {
    await open(tester);

    final viewId = tester.view.viewId;
    tester.binding.handleViewFocusChanged(ViewFocusEvent(
      viewId: viewId,
      state: ViewFocusState.unfocused,
      direction: ViewFocusDirection.undefined,
    ));
    await tester.pumpAndSettle();

    expect(find.text('检出'), findsNothing);
    tester.binding.handleViewFocusChanged(ViewFocusEvent(
      viewId: viewId,
      state: ViewFocusState.focused,
      direction: ViewFocusDirection.undefined,
    ));
  });

  testWidgets('closes when the app goes inactive', (tester) async {
    await open(tester);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpAndSettle();

    expect(find.text('检出'), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  testWidgets('closes when the title bar is clicked', (tester) async {
    bindWindowChrome();
    await open(tester);

    final codec = const StandardMethodCodec();
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'cgit/window',
      codec.encodeMethodCall(const MethodCall('chromeClick')),
      (_) {},
    );
    await tester.pumpAndSettle();

    expect(find.text('检出'), findsNothing);
  });

  testWidgets(
      'hover removal persists without opening a project or closing menu',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'cgit.recentRepos': ['/a', '/b'],
    });
    final prefs = await Prefs.load();
    final opened = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: Theming(
        palette: Palette.dark,
        child: Builder(
          builder: (context) => TextButton(
            onPressed: () => showRepoMenu(
              context: context,
              position: const Offset(40, 40),
              items: [
                MenuAction('打开…', () {}),
                const MenuAction.header('最近的项目'),
                for (final path in prefs.recentRepos)
                  MenuAction(
                    path,
                    () => opened.add(path),
                    onRemove: () => prefs.forgetRepo(path),
                  ),
              ],
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('从最近项目中移除'), findsNothing);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(700, 500));
    await mouse.moveTo(tester.getCenter(find.text('/a')));
    await tester.pumpAndSettle();
    expect(find.byTooltip('从最近项目中移除'), findsOneWidget);
    await mouse.moveTo(const Offset(700, 500));
    await tester.pumpAndSettle();
    expect(find.byTooltip('从最近项目中移除'), findsNothing);

    await mouse.moveTo(tester.getCenter(find.text('/a')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('从最近项目中移除'));
    await tester.pumpAndSettle();
    expect(find.text('/a'), findsNothing);
    expect(find.text('/b'), findsOneWidget);
    expect(opened, isEmpty);
    expect((await Prefs.load()).recentRepos, ['/b']);

    await mouse.moveTo(tester.getCenter(find.text('/b')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('从最近项目中移除'));
    await tester.pumpAndSettle();
    expect(find.text('最近的项目'), findsNothing);
    expect(find.text('打开…'), findsOneWidget);
    expect((await Prefs.load()).recentRepos, isEmpty);
    expect(opened, isEmpty);
    await mouse.removePointer();
  });
  Future<void> openSearch(WidgetTester tester, {bool long = false}) async {
    await tester.pumpWidget(MaterialApp(
      home: Theming(
        palette: Palette.dark,
        child: Builder(
            builder: (context) => TextButton(
                  onPressed: () => showRepoMenu(
                    context: context,
                    position: const Offset(40, 40),
                    searchHint: '搜索分支和操作',
                    items: [
                      MenuAction('更新', () {}),
                      const MenuAction.header('本地分支'),
                      MenuAction('main', () {}),
                      const MenuAction.header('远端分支'),
                      MenuAction('origin/Feature-Menu', () {}),
                      if (long)
                        for (var i = 0; i < 100; i++)
                          MenuAction('origin/branch-$i', () {}),
                    ],
                  ),
                  child: const Text('open'),
                )),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'search filters branches case insensitively and hides empty groups',
      (tester) async {
    await openSearch(tester);
    await tester.enterText(find.byType(TextField), '  FEATURE  ');
    await tester.pumpAndSettle();
    expect(find.text('origin/Feature-Menu'), findsOneWidget);
    expect(find.text('远端分支'), findsOneWidget);
    expect(find.text('本地分支'), findsNothing);
    expect(find.text('main'), findsNothing);
    expect(find.text('更新'), findsNothing);
  });

  testWidgets('search matches operations and clearing restores all items',
      (tester) async {
    await openSearch(tester);
    await tester.enterText(find.byType(TextField), '更新');
    await tester.pumpAndSettle();
    expect(find.byWidgetPredicate((w) => w is Text && w.data == '更新'),
        findsOneWidget);
    expect(find.text('远端分支'), findsNothing);
    await tester.enterText(find.byType(TextField), 'missing');
    await tester.pumpAndSettle();
    expect(find.text('无匹配结果'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();
    expect(find.text('无匹配结果'), findsNothing);
    expect(find.text('main'), findsOneWidget);
    expect(find.text('origin/Feature-Menu'), findsOneWidget);
    await tester.tap(find.text('更新'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('Escape dismisses a searchable menu while editing',
      (tester) async {
    await openSearch(tester);
    await tester.enterText(find.byType(TextField), 'main');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
  });
  testWidgets('search stays visible while a long branch list scrolls',
      (tester) async {
    await openSearch(tester, long: true);
    final top = tester.getTopLeft(find.byType(TextField));
    await tester.drag(
        find.byType(SingleChildScrollView), const Offset(0, -1500));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.byType(TextField)), top);
    await tester.enterText(find.byType(TextField), 'FEATURE');
    await tester.pumpAndSettle();
    expect(find.text('origin/Feature-Menu').hitTestable(), findsOneWidget);
    expect(tester.getTopLeft(find.byType(TextField)), top);
    expect(tester.takeException(), isNull);
  });
}
