import 'package:cgit_flutter/date_range_dialog.dart';
import 'package:cgit_flutter/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('calendar range picker stays compact and applies only on confirm',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    DateTimeRange? result;
    await tester.pumpWidget(MaterialApp(
      home: Theming(
        palette: Palette.light,
        child: Material(
          child: Builder(
            builder: (context) => TextButton(
              onPressed: () async => result = await showCommitDateRangeDialog(
                context,
                DateTimeRange(
                  start: DateTime(2026, 9, 29),
                  end: DateTime(2026, 9, 29),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final dialogSurface = find
        .descendant(of: find.byType(Dialog), matching: find.byType(Material))
        .first;
    expect(tester.getSize(dialogSurface).width, lessThan(500));
    expect(result, isNull);

    await tester.tap(find.text('1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('3'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(result?.start, DateTime(2026, 9, 1));
    expect(result?.end, DateTime(2026, 9, 3));
  });

  testWidgets('invalid typed dates cannot be applied', (tester) async {
    DateTimeRange? result;
    await tester.pumpWidget(MaterialApp(
      home: Theming(
        palette: Palette.dark,
        child: Material(
          child: Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  result = await showCommitDateRangeDialog(context, null),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '2026-02-30');
    await tester.enterText(find.byType(TextField).last, '2026-03-01');
    await tester.pumpAndSettle();
    expect(find.text('请输入有效日期（1900—2100）'), findsOneWidget);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, '2026-02-28');
    await tester.pumpAndSettle();
    expect(find.text('已选择 2 天'), findsOneWidget);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(result?.start, DateTime(2026, 2, 28));
    expect(result?.end, DateTime(2026, 3, 1));
  });
}
