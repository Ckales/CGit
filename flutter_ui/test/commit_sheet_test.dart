import 'package:cgit_flutter/commit_sheet.dart';
import 'package:cgit_flutter/git.dart';
import 'package:cgit_flutter/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// These exist because the first version of this app shipped a commit box that
/// rendered as a red "No Material widget found" error instead of an input: the
/// app draws its own chrome instead of using Scaffold, so nothing supplied the
/// Material ancestor TextField asserts on. DiffPane had widget tests; this
/// sheet did not, so a full green suite said nothing about it.
///
/// `_host` deliberately mirrors main.dart's tree — Theming, then Material, then
/// the Stack the sheet's Positioned.fill needs — so a regression in any of those
/// layers fails here rather than only on screen.
Widget _host(Widget child) => MaterialApp(
      home: Theming(
        palette: Palette.dark,
        child: Material(
          type: MaterialType.transparency,
          child: Stack(children: [child]),
        ),
      ),
    );

CommitSheet _sheet({List<FileStatus>? changes}) => CommitSheet(
      changes: changes ??
          const [
            FileStatus(path: 'src/main.js', status: 'M', staged: true),
            FileStatus(path: 'src/styles.css', status: 'M', staged: false),
          ],
      git: Git('/tmp'),
      onClose: () {},
      onChanged: () async {},
      onPickFile: (_) {},
    );

void main() {
  testWidgets('the commit box renders a real input, not an error block',
      (tester) async {
    await tester.pumpWidget(_host(_sheet()));

    expect(find.byType(TextField), findsOneWidget);
    // The framework's error widget renders its message as text; if the Material
    // ancestor goes missing again this is what shows up instead of the field.
    expect(find.textContaining('No Material widget'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the commit box accepts Chinese input', (tester) async {
    await tester.pumpWidget(_host(_sheet()));

    // Not an IME test — that needs a real input method and a real window. This
    // only pins that the field holds multi-byte text and shows it back.
    await tester.enterText(find.byType(TextField), '修复提交弹窗缺少输入框');
    await tester.pump();

    expect(find.text('修复提交弹窗缺少输入框'), findsOneWidget);
  });

  testWidgets('staged and unstaged files are grouped and counted',
      (tester) async {
    await tester.pumpWidget(_host(_sheet()));

    expect(find.text('已暂存 (1)'), findsOneWidget);
    expect(find.text('未暂存 (1)'), findsOneWidget);
  });

  testWidgets('committing an empty message is refused before touching git',
      (tester) async {
    await tester.pumpWidget(_host(_sheet()));

    // The sheet header and the button both read 提交; the button comes last.
    await tester.tap(find.text('提交').last);
    await tester.pump();

    // Git('/tmp') would throw if it were reached; the guard must fire first.
    expect(find.text('提交说明不能为空'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('committing with nothing staged is refused', (tester) async {
    await tester.pumpWidget(_host(_sheet(
      changes: const [FileStatus(path: 'src/main.js', status: 'M', staged: false)],
    )));

    await tester.enterText(find.byType(TextField), '一些改动');
    // The sheet header and the button both read 提交; the button comes last.
    await tester.tap(find.text('提交').last);
    await tester.pump();

    expect(find.text('没有已暂存的改动'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
