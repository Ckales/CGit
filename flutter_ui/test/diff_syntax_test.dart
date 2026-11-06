import 'package:cgit_flutter/diff_syntax.dart';
import 'package:cgit_flutter/git_text.dart';
import 'package:cgit_flutter/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

List<TextSpan> tokens(TextSpan line) => line.children!.cast<TextSpan>();

void main() {
  for (final palette in [Palette.dark, Palette.light]) {
    test(
        'multi-line comments keep colour and old/new states stay separate '
        '(${palette == Palette.dark ? 'dark' : 'light'})', () {
      final syntax = DiffSyntax(
          '@@ -1,3 +1,3 @@\n-/*\n+var n = 1;\n context\n-*/\n+var m = 2;\n',
          'main.go',
          palette);
      final old = syntax.oldLines[2]!;
      final next = syntax.newLines[2]!;
      expect(old.toPlainText(), 'context');
      expect(tokens(old).single.style!.color, isNot(palette.text));
      expect(tokens(next).single.style!.color, palette.text);
    });
  }

  test('unknown syntax preserves whitespace, unicode, plus and empty lines',
      () {
    final syntax = DiffSyntax(
        '@@ -0,0 +1,4 @@\n+  你好\t\n++value\n+\n+last\n'
            '\\ No newline at end of file\n',
        'file.unknown',
        Palette.dark);
    expect(syntax.oldLines, isEmpty);
    expect(syntax.newLines.values.map((s) => s.toPlainText()),
        ['  你好\t', '+value', '', 'last']);
  });

  test('intra-line marks cross syntax tokens and retain original colours', () {
    final syntax = DiffSyntax(
        '@@ -0,0 +1 @@\n+var s = "hello"\n', 'main.go', Palette.dark);
    final line = syntax.newLines[1]!;
    final marked = markIntra(
        line, const LinePart('va', 'r s = "hel', 'lo"'), Palette.dark.intraAdd);
    expect(marked.toPlainText(), line.toPlainText());
    final markedText = tokens(marked)
        .where((s) => s.style!.backgroundColor == Palette.dark.intraAdd)
        .map((s) => s.text)
        .join();
    expect(markedText, 'r s = "hel');
    expect(tokens(marked).map((s) => s.style!.color).toSet(),
        tokens(line).map((s) => s.style!.color).toSet());
  });
}
