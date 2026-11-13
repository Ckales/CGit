import 'dart:async';

import 'package:cgit_flutter/dialogs.dart';
import 'package:cgit_flutter/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late StateSetter updateHost;
  var showReporter = true;
  final shown = <String>[];

  Future<void> display(BuildContext context, String title) {
    shown.add(title);
    return showAppDialog<void>(
      context,
      title: title,
      body: Text('$title details'),
      actions: [
        Builder(
            builder: (context) => TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('close'),
                )),
      ],
    );
  }

  Future<void> open(WidgetTester tester) async {
    shown.clear();
    showReporter = true;
    await tester.pumpWidget(MaterialApp(
      home: Theming(
        palette: Palette.dark,
        child: StatefulBuilder(builder: (context, setState) {
          updateHost = setState;
          return showReporter
              ? Builder(
                  builder: (context) => TextButton(
                        onPressed: () {
                          unawaited(queueErrorDialog(
                              context, () => display(context, 'first')));
                          unawaited(queueErrorDialog(
                              context, () => display(context, 'second')));
                        },
                        child: const Text('fail'),
                      ))
              : const SizedBox();
        }),
      ),
    ));
    await tester.tap(find.text('fail'));
    await tester.pumpAndSettle();
  }

  testWidgets('concurrent errors display one at a time in arrival order',
      (tester) async {
    await open(tester);
    expect(shown, ['first']);
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.text('first details'), findsOneWidget);
    await tester.tap(find.text('close'));
    await tester.pumpAndSettle();
    expect(shown, ['first', 'second']);
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.text('second details'), findsOneWidget);
    await tester.tap(find.text('close'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
  });

  testWidgets('queued errors skip a reporter that has been disposed',
      (tester) async {
    await open(tester);
    updateHost(() => showReporter = false);
    await tester.pump();
    await tester.tap(find.text('close'));
    await tester.pumpAndSettle();
    expect(shown, ['first']);
    expect(find.byType(Dialog), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
