import 'package:cgit_flutter/code_field.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

TextEditingValue _v(String text, int base, [int? extent]) => TextEditingValue(
    text: text,
    selection: TextSelection(baseOffset: base, extentOffset: extent ?? base));

void main() {
  test('Tab at a caret inserts one unit there', () {
    final out = indentValue(_v('ab', 1), '    ', outdent: false);
    expect(out.text, 'a    b');
    expect(out.selection, const TextSelection.collapsed(offset: 5));
  });

  test('Tab over a selection indents every line it touches', () {
    // Selection from inside line 1 to inside line 2; line 3 untouched.
    final out = indentValue(_v('one\ntwo\nthree', 1, 5), '  ', outdent: false);
    expect(out.text, '  one\n  two\nthree');
    expect(out.selection, const TextSelection(baseOffset: 3, extentOffset: 9));
  });

  test('a selection ending at a line start leaves that line alone', () {
    final out = indentValue(_v('one\ntwo', 0, 4), '\t', outdent: false);
    expect(out.text, '\tone\ntwo');
  });

  test('Shift+Tab outdents by up to one unit, never into the text', () {
    final out =
        indentValue(_v('    a\n  b\nc', 0, 11), '    ', outdent: true);
    expect(out.text, 'a\nb\nc');

    // Caret inside the indent lands at the line start, not before it.
    final caret = indentValue(_v('x\n    y', 4), '    ', outdent: true);
    expect(caret.text, 'x\ny');
    expect(caret.selection, const TextSelection.collapsed(offset: 2));
  });

  test('the indent unit follows the file', () {
    expect(indentUnitOf('a\n\tb'), '\t');
    expect(indentUnitOf('def f():\n  x\n    y'), '  ');
    expect(indentUnitOf('no indent'), '    ');
  });
}
