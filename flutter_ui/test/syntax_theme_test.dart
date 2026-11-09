import 'package:cgit_flutter/code_field.dart';
import 'package:cgit_flutter/diff_syntax.dart';
import 'package:cgit_flutter/diff_view.dart';
import 'package:cgit_flutter/syntax_theme.dart';
import 'package:cgit_flutter/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

List<Color?> colours(TextSpan span) => [
      if (span.text?.isNotEmpty ?? false) span.style?.color,
      for (final child in span.children ?? <InlineSpan>[])
        ...colours(child as TextSpan),
    ];

const source = 'const message = "Hello";';
const hunk =
    '@@ -1 +1 @@\n-const message = "Old";\n+const message = "Hello";\n';

void main() {
  test('each theme colours code and cached merge spans without changing text',
      () {
    final syntax = Syntax('example.js');
    final results = <List<Color?>>[];
    for (final theme in SyntaxTheme.values) {
      final span = syntax.cached(source, mono, dark: true, theme: theme);
      expect(span.toPlainText(), source);
      expect(colours(span).whereType<Color>(), isNotEmpty);
      expect(
          identical(
              span, syntax.cached(source, mono, dark: true, theme: theme)),
          isTrue);
      results.add(colours(span));
      final diff = DiffSyntax(hunk, 'example.js', Palette.dark, theme: theme);
      expect(diff.newLines[1]!.toPlainText(), source);
      expect(colours(diff.newLines[1]!),
          containsAll(colours(span).whereType<Color>()));
    }
    for (var i = 0; i < results.length; i++) {
      for (var j = i + 1; j < results.length; j++) {
        expect(results[i], isNot(results[j]));
      }
    }
  });

  test('GitHub follows light and dark appearance', () {
    final syntax = Syntax('example.js');
    expect(
        colours(syntax.highlight(source, mono,
            dark: true, theme: SyntaxTheme.github)),
        isNot(colours(syntax.highlight(source, mono,
            dark: false, theme: SyntaxTheme.github))));
  });

  testWidgets('code editor refreshes unchanged text when theme changes',
      (tester) async {
    final controller =
        CodeController(text: source, syntax: Syntax('example.js'));
    addTearDown(controller.dispose);
    late BuildContext context;
    Future<void> pump(SyntaxTheme theme) async {
      await tester.pumpWidget(MaterialApp(
          home: Theming(
        palette: Palette.dark,
        syntaxTheme: theme,
        child: Material(child: Builder(builder: (c) {
          context = c;
          return CodeField(controller: controller, indentUnit: '  ');
        })),
      )));
    }

    await pump(SyntaxTheme.atomOne);
    final paintedBefore = colours(tester.allRenderObjects
        .whereType<RenderEditable>()
        .single
        .text! as TextSpan);
    final before = controller.buildTextSpan(
        context: context, style: mono, withComposing: false);
    await pump(SyntaxTheme.dracula);
    final after = controller.buildTextSpan(
        context: context, style: mono, withComposing: false);
    expect(colours(after), isNot(colours(before)));
    expect(
        colours(tester.allRenderObjects.whereType<RenderEditable>().single.text!
            as TextSpan),
        isNot(paintedBefore));
    expect(controller.text, source);
    expect(
        controller.buildTextSpan(
            context: context, style: mono, withComposing: false),
        same(after));
  });

  for (final mode in DiffMode.values) {
    testWidgets('$mode diff refreshes unchanged hunk when theme changes',
        (tester) async {
      Future<void> pump(SyntaxTheme theme) async {
        await tester.pumpWidget(MaterialApp(
            home: Theming(
          palette: Palette.dark,
          syntaxTheme: theme,
          child: Material(
              child: SingleChildScrollView(
                  child: DiffPane(
            file: 'example.js',
            hunks: const [hunk],
            mode: mode,
          ))),
        )));
      }

      TextSpan newLine() => tester
          .widgetList<RichText>(find.byType(RichText))
          .map((w) => w.text)
          .whereType<TextSpan>()
          .firstWhere((s) =>
              s.toPlainText() ==
              (mode == DiffMode.unified ? '+$source' : source));
      await pump(SyntaxTheme.atomOne);
      final before = colours(newLine());
      await pump(SyntaxTheme.monokai);
      expect(colours(newLine()), isNot(before));
    });
  }
}
