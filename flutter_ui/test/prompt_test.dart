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
    String title = '新建分支',
    String? hint = '分支名',
    String confirmLabel = '确定',
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
                  title: title,
                  hint: hint,
                  initial: initial,
                  confirmLabel: confirmLabel,
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
    expect(result, isNull,
        reason: 'the caller must be able to tell these apart');
  });

  testWidgets('an empty field still returns a string, for the caller to reject',
      (tester) async {
    await open(tester);

    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(result, '');
  });

  testWidgets('stash prompt lets users provide or omit the stash message',
      (tester) async {
    await open(
      tester,
      title: '储藏当前改动',
      hint: '储藏说明（留空由 Git 自动生成）',
      confirmLabel: '储藏',
    );
    expect(find.text('储藏当前改动'), findsOneWidget);
    expect(find.text('储藏说明（留空由 Git 自动生成）'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'wip: 调整导航');
    await tester.tap(find.text('储藏'));
    await tester.pumpAndSettle();

    expect(called, isTrue);
    expect(result, 'wip: 调整导航');

    await open(
      tester,
      title: '储藏当前改动',
      hint: '储藏说明（留空由 Git 自动生成）',
      confirmLabel: '储藏',
    );
    await tester.tap(find.text('储藏'));
    await tester.pumpAndSettle();

    expect(called, isTrue);
    expect(result, '',
        reason:
            'an omitted message deliberately leaves Git to generate WIP text');
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

  group('tag prompt', () {
    late ({String name, TagSubmit submit})? tagged;

    Future<void> openTag(WidgetTester tester) async {
      tagged = null;
      await tester.pumpWidget(MaterialApp(
        home: Theming(
          palette: Palette.dark,
          child: Material(
            type: MaterialType.transparency,
            child: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  tagged = await promptTagName(
                    context,
                    title: '在 HEAD 上打标签',
                  );
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

    testWidgets('创建 tags locally', (tester) async {
      await openTag(tester);

      await tester.enterText(find.byType(TextField), 'v1.1.2');
      await tester.tap(find.text('创建'));
      await tester.pumpAndSettle();

      expect(tagged?.name, 'v1.1.2');
      expect(tagged?.submit, TagSubmit.create);
    });

    testWidgets('the chevron offers 创建并推送', (tester) async {
      await openTag(tester);

      await tester.enterText(find.byType(TextField), 'v1.1.2');
      await tester.tap(find.byTooltip('更多创建方式'));
      await tester.pumpAndSettle();
      expect(find.text('创建并推送'), findsOneWidget);

      // The popup is at least as wide as the split button and shares its
      // right edge, so it sits under 创建 instead of hanging off it.
      final menu = find
          .ancestor(
            of: find.text('创建并推送'),
            matching: find.byType(Material),
          )
          .first;
      final menuRect = tester.getRect(menu);
      final createRect = tester.getRect(find.byTooltip('创建标签'));
      final chevronRect = tester.getRect(find.byTooltip('更多创建方式'));
      final buttonWidth = chevronRect.right - createRect.left;
      expect(menuRect.width, greaterThanOrEqualTo(buttonWidth - 0.5));
      expect(menuRect.left, lessThanOrEqualTo(createRect.left + 0.5));
      expect(menuRect.right, moreOrLessEquals(chevronRect.right, epsilon: 0.5));

      await tester.tap(find.text('创建并推送'));
      await tester.pumpAndSettle();

      expect(tagged?.name, 'v1.1.2');
      expect(tagged?.submit, TagSubmit.createAndPush);
    });

    testWidgets('enter keeps the plain create', (tester) async {
      await openTag(tester);

      await tester.enterText(find.byType(TextField), 'v9');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(tagged?.submit, TagSubmit.create);
    });
  });
}
