import 'package:cgit_flutter/prompt.dart';
import 'package:cgit_flutter/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// promptText feeds branch names and tag names straight into git, so the
/// distinction that matters is null (backed out) versus "" (typed nothing):
/// treating them the same would create a branch named after whatever the
/// caller's fallback happened to be.
void main() {
  late String? result;
  late bool called;

  Future<void> open(
    WidgetTester tester, {
    String initial = '',
  }) async {
    result = null;
    called = false;

    await tester.pumpWidget(MaterialApp(
      home: Theming(
        palette: Palette.dark,
        child: Material(
          type: MaterialType.transparency,
          child: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await promptText(
                  context,
                  title: '新建分支',
                  hint: '分支名',
                  initial: initial,
                );
                called = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('returns what was typed', (tester) async {
    await open(tester);

    await tester.enterText(find.byType(TextField), 'feature/login');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(called, isTrue);
    expect(result, 'feature/login');
  });

  testWidgets('cancelling returns null, not an empty string', (tester) async {
    await open(tester);

    await tester.enterText(find.byType(TextField), 'typed then abandoned');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(called, isTrue);
    expect(result, isNull, reason: 'the caller must be able to tell these apart');
  });

  testWidgets('an empty field still returns a string, for the caller to reject',
      (tester) async {
    await open(tester);

    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(result, '');
  });

  testWidgets('enter submits without reaching for the button', (tester) async {
    await open(tester);

    await tester.enterText(find.byType(TextField), 'hotfix');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(result, 'hotfix');
  });

  testWidgets('a prefilled value comes back selected so typing replaces it',
      (tester) async {
    await open(tester, initial: 'old-name');

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, 'old-name');
    expect(
      field.controller!.selection,
      const TextSelection(baseOffset: 0, extentOffset: 8),
    );
  });
}
