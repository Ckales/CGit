import 'dart:ui' show ViewFocusDirection, ViewFocusEvent, ViewFocusState;

import 'package:cgit_flutter/context_menu.dart';
import 'package:cgit_flutter/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
