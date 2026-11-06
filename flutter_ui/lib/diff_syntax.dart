import 'package:flutter/material.dart';

import 'code_field.dart';
import 'git_text.dart';
import 'theme.dart';

/// Parse each side separately so removed text cannot change the syntax state
/// of added text. Multi-line tokens keep their colour within the hunk.
class DiffSyntax {
  DiffSyntax(String hunk, String file, Palette palette) {
    final body = hunk.replaceFirst(RegExp(r'\n$'), '').split('\n').skip(1);
    final head = parseHunkHeader(hunk.split('\n').first);
    var oldNo = head?.oldStart ?? 0;
    var newNo = head?.newStart ?? 0;
    final oldText = <String>[];
    final newText = <String>[];
    final oldNumbers = <int>[];
    final newNumbers = <int>[];
    for (final line in body) {
      if (line.startsWith('\\')) continue;
      final text = line.isEmpty ? '' : line.substring(1);
      if (!line.startsWith('+')) {
        oldText.add(text);
        oldNumbers.add(oldNo++);
      }
      if (!line.startsWith('-')) {
        newText.add(text);
        newNumbers.add(newNo++);
      }
    }
    final syntax = Syntax(file);
    final base = mono.copyWith(color: palette.text);
    void colour(List<String> text, List<int> numbers, Map<int, TextSpan> out) {
      if (text.isEmpty) return;
      final spans = _lines(syntax.highlight(text.join('\n'), base,
          dark: Syntax.isDark(palette)));
      for (var i = 0; i < numbers.length; i++) {
        out[numbers[i]] = spans[i];
      }
    }

    colour(oldText, oldNumbers, oldLines);
    colour(newText, newNumbers, newLines);
  }

  final oldLines = <int, TextSpan>{};
  final newLines = <int, TextSpan>{};
}

/// Flatten nested syntax scopes once and split them without losing inherited
/// styles, empty lines, or the state of multi-line strings/comments.
List<TextSpan> _lines(TextSpan root) {
  final lines = <List<InlineSpan>>[[]];
  void visit(TextSpan span, TextStyle inherited) {
    final style = inherited.merge(span.style);
    final pieces = (span.text ?? '').split('\n');
    for (var i = 0; i < pieces.length; i++) {
      if (i > 0) lines.add([]);
      if (pieces[i].isNotEmpty) {
        lines.last.add(TextSpan(text: pieces[i], style: style));
      }
    }
    for (final child in span.children ?? <InlineSpan>[]) {
      visit(child as TextSpan, style);
    }
  }

  visit(root, const TextStyle());
  return [for (final line in lines) TextSpan(children: line)];
}

/// Add an intra-line background while preserving the syntax foreground.
TextSpan markIntra(TextSpan span, LinePart? part, Color colour) {
  if (part == null || part.mid.isEmpty) return span;
  final start = part.prefix.length;
  final end = start + part.mid.length;
  var offset = 0;
  final children = <TextSpan>[];
  for (final child in span.children!.cast<TextSpan>()) {
    final text = child.text!;
    final from = (start - offset).clamp(0, text.length);
    final to = (end - offset).clamp(0, text.length);
    if (from > 0) {
      children.add(TextSpan(text: text.substring(0, from), style: child.style));
    }
    if (to > from) {
      children.add(TextSpan(
          text: text.substring(from, to),
          style: child.style?.copyWith(backgroundColor: colour)));
    }
    if (to < text.length) {
      children.add(TextSpan(text: text.substring(to), style: child.style));
    }
    offset += text.length;
  }
  return TextSpan(children: children);
}
