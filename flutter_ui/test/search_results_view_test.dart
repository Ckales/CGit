import 'package:cgit_flutter/git.dart';
import 'package:cgit_flutter/history_view.dart';
import 'package:cgit_flutter/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('filtered commits keep refs, author and time in the history row',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final time = DateTime(2026, 9, 29, 11, 52).millisecondsSinceEpoch ~/ 1000;
    final commit = CommitInfo(
      id: '585033c123456789',
      summary: 'feat: 添加储藏当前改动提示框功能',
      author: 'Chales',
      time: time,
      refs: const ['main', 'origin/main', 'HEAD'],
    );
    GraphCommit? selected;
    await tester.pumpWidget(MaterialApp(
      home: Theming(
        palette: Palette.light,
        child: SearchResultsView(
          commits: [commit],
          selected: null,
          onSelect: (value) => selected = value,
        ),
      ),
    ));

    expect(find.text('585033c'), findsOneWidget);
    expect(find.text('main'), findsOneWidget);
    expect(find.text('origin/main'), findsOneWidget);
    expect(find.text('HEAD'), findsOneWidget);
    expect(find.text('feat: 添加储藏当前改动提示框功能'), findsOneWidget);
    expect(find.text('Chales'), findsOneWidget);
    expect(find.text('09-29 11:52'), findsOneWidget);

    await tester.tap(find.text('feat: 添加储藏当前改动提示框功能'));
    expect(selected?.id, commit.id);
    expect(selected?.refs, commit.refs);
  });
}
