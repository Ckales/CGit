import 'package:cgit_flutter/blame_view.dart';
import 'package:cgit_flutter/git.dart';
import 'package:cgit_flutter/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

BlameLine _line(String oid, String author, String content) => BlameLine(
      oid: oid,
      author: author,
      summary: 'summary of $oid',
      content: content,
    );

Widget _host(List<BlameLine> lines, {void Function(String)? onOpen}) =>
    MaterialApp(
      home: Theming(
        palette: Palette.dark,
        child: Material(
          type: MaterialType.transparency,
          child: BlameView(
            lines: lines,
            onOpenCommit: onOpen ?? (_) {},
          ),
        ),
      ),
    );

void main() {
  testWidgets('a run of lines from one commit prints its sha once',
      (tester) async {
    await tester.pumpWidget(_host([
      _line('aaaaaaa111', 'Ada', 'first'),
      _line('aaaaaaa111', 'Ada', 'second'),
      _line('bbbbbbb222', 'Bob', 'third'),
    ]));

    // Three lines, two runs: repeating the same hash on every row is what makes
    // a real file unreadable.
    expect(find.text('aaaaaaa'), findsOneWidget);
    expect(find.text('bbbbbbb'), findsOneWidget);
    expect(find.text('Ada'), findsOneWidget);
    expect(find.text('Bob'), findsOneWidget);

    // Every line still shows its own content and number.
    for (final t in ['first', 'second', 'third']) {
      expect(find.text(t), findsOneWidget);
    }
    for (final n in ['1', '2', '3']) {
      expect(find.text(n), findsOneWidget);
    }
  });

  testWidgets('the same commit returning later starts a new run', (tester) async {
    await tester.pumpWidget(_host([
      _line('aaaaaaa111', 'Ada', 'one'),
      _line('bbbbbbb222', 'Bob', 'two'),
      _line('aaaaaaa111', 'Ada', 'three'),
    ]));

    // Runs are about adjacency, not identity: the reader needs to see where
    // authorship changes back.
    expect(find.text('aaaaaaa'), findsNWidgets(2));
  });

  testWidgets('clicking a sha asks for that commit', (tester) async {
    String? opened;
    await tester.pumpWidget(_host(
      [_line('abc1234def', 'Ada', 'line')],
      onOpen: (oid) => opened = oid,
    ));

    await tester.tap(find.text('abc1234'));
    await tester.pump();
    expect(opened, 'abc1234def', reason: 'the full oid, not the short form');
  });

  testWidgets('an empty file says so instead of rendering nothing',
      (tester) async {
    await tester.pumpWidget(_host(const []));
    expect(find.text('没有可归属的内容'), findsOneWidget);
  });
}
