import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:re_highlight/languages/bash.dart';
import 'package:re_highlight/languages/c.dart';
import 'package:re_highlight/languages/cpp.dart';
import 'package:re_highlight/languages/csharp.dart';
import 'package:re_highlight/languages/css.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/languages/dockerfile.dart';
import 'package:re_highlight/languages/go.dart';
import 'package:re_highlight/languages/ini.dart';
import 'package:re_highlight/languages/java.dart';
import 'package:re_highlight/languages/javascript.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/kotlin.dart';
import 'package:re_highlight/languages/less.dart';
import 'package:re_highlight/languages/lua.dart';
import 'package:re_highlight/languages/makefile.dart';
import 'package:re_highlight/languages/markdown.dart';
import 'package:re_highlight/languages/objectivec.dart';
import 'package:re_highlight/languages/php.dart';
import 'package:re_highlight/languages/properties.dart';
import 'package:re_highlight/languages/protobuf.dart';
import 'package:re_highlight/languages/python.dart';
import 'package:re_highlight/languages/ruby.dart';
import 'package:re_highlight/languages/rust.dart';
import 'package:re_highlight/languages/scala.dart';
import 'package:re_highlight/languages/scss.dart';
import 'package:re_highlight/languages/sql.dart';
import 'package:re_highlight/languages/swift.dart';
import 'package:re_highlight/languages/typescript.dart';
import 'package:re_highlight/languages/vue.dart';
import 'package:re_highlight/languages/xml.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/re_highlight.dart';
import 'package:re_highlight/styles/atom-one-dark.dart';
import 'package:re_highlight/styles/atom-one-light.dart';

import 'theme.dart';

/// ponytail: a hand-picked set of grammars, not re_highlight's all 197 — the
/// rest only add binary size. Add a line here when a repo needs one.
final _highlight = Highlight()
  ..registerLanguages({
    'bash': langBash,
    'c': langC,
    'cpp': langCpp,
    'csharp': langCsharp,
    'css': langCss,
    'dart': langDart,
    'dockerfile': langDockerfile,
    'go': langGo,
    'ini': langIni,
    'java': langJava,
    'javascript': langJavascript,
    'json': langJson,
    'kotlin': langKotlin,
    'less': langLess,
    'lua': langLua,
    'makefile': langMakefile,
    'markdown': langMarkdown,
    'objectivec': langObjectivec,
    'php': langPhp,
    'properties': langProperties,
    'protobuf': langProtobuf,
    'python': langPython,
    'ruby': langRuby,
    'rust': langRust,
    'scala': langScala,
    'scss': langScss,
    'sql': langSql,
    'swift': langSwift,
    'typescript': langTypescript,
    'vue': langVue,
    'xml': langXml,
    'yaml': langYaml,
  });

/// The theme minus its root background: the panes keep their own tints.
Map<String, TextStyle> _themeOf(Map<String, TextStyle> theme) =>
    {...theme}..remove('root');
final _dark = _themeOf(atomOneDarkTheme);
final _light = _themeOf(atomOneLightTheme);

/// One file's syntax colouring, picked by extension (grammar aliases cover
/// py / ts / rs / yml …); Dockerfile and Makefile go by their whole name.
class Syntax {
  Syntax(String file) : _language = _languageFor(file);

  final String? _language;
  final _cache = <(String, TextStyle, bool), TextSpan>{};

  static String? _languageFor(String file) {
    final name = file.split('/').last.toLowerCase();
    final dot = name.lastIndexOf('.');
    final key = dot < 0 ? name : name.substring(dot + 1);
    return _highlight.getLanguage(key) == null ? null : key;
  }

  static bool isDark(Palette p) => p.bg.computeLuminance() < 0.5;

  TextSpan highlight(String text, TextStyle base, {required bool dark}) {
    final language = _language;
    if (language == null) return TextSpan(text: text, style: base);
    final result = _highlight.highlight(code: text, language: language);
    final renderer = TextSpanRenderer(base, dark ? _dark : _light);
    result.render(renderer);
    return renderer.span ?? TextSpan(text: text, style: base);
  }

  /// For text that does not change, like the two sides of a merge.
  TextSpan cached(String text, TextStyle base, {required bool dark}) =>
      _cache.putIfAbsent(
          (text, base, dark), () => highlight(text, base, dark: dark));
}

/// A controller whose text paints through [Syntax].
class CodeController extends TextEditingController {
  CodeController({super.text, required this.syntax});

  final Syntax syntax;
  bool dark = true;

  String? _lastText;
  TextStyle? _lastStyle;
  bool? _lastDark;
  TextSpan? _lastSpan;

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    // Mid-IME the composing underline matters more than colour.
    if (withComposing && value.isComposingRangeValid) {
      return super.buildTextSpan(
          context: context, style: style, withComposing: withComposing);
    }
    final base = style ?? const TextStyle();
    if (text != _lastText || base != _lastStyle || dark != _lastDark) {
      _lastText = text;
      _lastStyle = base;
      _lastDark = dark;
      _lastSpan = syntax.highlight(text, base, dark: dark);
    }
    return _lastSpan!;
  }
}

/// The indent the file already uses: a tab if any line starts with one,
/// otherwise the smallest leading run of spaces (2–8), else four spaces.
String indentUnitOf(String content) {
  var smallest = 0;
  for (final line in content.split('\n')) {
    if (line.startsWith('\t')) return '\t';
    var n = 0;
    while (n < line.length && line[n] == ' ') {
      n++;
    }
    if (n >= 2 && n < line.length && (smallest == 0 || n < smallest)) {
      smallest = n;
    }
  }
  return ' ' * (smallest == 0 || smallest > 8 ? 4 : smallest);
}

/// Tab / Shift+Tab. A collapsed Tab inserts one unit at the caret; otherwise
/// every line the selection touches is indented, or outdented by up to one
/// unit, and the selection follows its text.
TextEditingValue indentValue(TextEditingValue v, String unit,
    {required bool outdent}) {
  final sel = v.selection;
  if (!sel.isValid) return v;
  final text = v.text;
  final start = sel.start;
  final end = sel.end;

  if (!outdent && sel.isCollapsed) {
    return TextEditingValue(
      text: text.replaceRange(start, start, unit),
      selection: TextSelection.collapsed(offset: start + unit.length),
    );
  }

  final lineStart = start == 0 ? 0 : text.lastIndexOf('\n', start - 1) + 1;
  // A selection ending at the very start of a line leaves that line alone.
  final lastChar = end > start && text[end - 1] == '\n' ? end - 1 : end;
  final newline = text.indexOf('\n', lastChar);
  final lineEnd = newline < 0 ? text.length : newline;

  final lines = text.substring(lineStart, lineEnd).split('\n');
  var firstDelta = 0;
  var totalDelta = 0;
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    var delta = 0;
    if (!outdent) {
      lines[i] = unit + line;
      delta = unit.length;
    } else {
      var cut = 0;
      if (line.startsWith(unit)) {
        cut = unit.length;
      } else if (line.startsWith('\t')) {
        cut = 1;
      } else {
        while (cut < unit.length && cut < line.length && line[cut] == ' ') {
          cut++;
        }
      }
      lines[i] = line.substring(cut);
      delta = -cut;
    }
    if (i == 0) firstDelta = delta;
    totalDelta += delta;
  }

  final newStart = (start + firstDelta).clamp(lineStart, text.length);
  final newEnd = (end + totalDelta).clamp(newStart, text.length + totalDelta);
  return TextEditingValue(
    text: text.replaceRange(lineStart, lineEnd, lines.join('\n')),
    selection: TextSelection(baseOffset: newStart, extentOffset: newEnd),
  );
}

/// A code editor field: syntax colours, and Tab / Shift+Tab indent instead of
/// moving focus. Edits made by Tab reach [onChanged] like typed ones.
class CodeField extends StatelessWidget {
  const CodeField({
    super.key,
    required this.controller,
    required this.indentUnit,
    this.onChanged,
    this.expands = false,
  });

  final CodeController controller;
  final String indentUnit;
  final ValueChanged<String>? onChanged;
  final bool expands;

  @override
  Widget build(BuildContext context) {
    final p = Theming.of(context);
    controller.dark = Syntax.isDark(p);
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
          return KeyEventResult.ignored;
        }
        if (event.logicalKey != LogicalKeyboardKey.tab ||
            controller.value.isComposingRangeValid) {
          return KeyEventResult.ignored;
        }
        controller.value = indentValue(controller.value, indentUnit,
            outdent: HardwareKeyboard.instance.isShiftPressed);
        onChanged?.call(controller.text);
        return KeyEventResult.handled;
      },
      child: TextField(
        controller: controller,
        maxLines: null,
        expands: expands,
        style: mono.copyWith(color: p.text),
        cursorColor: p.accent,
        decoration: const InputDecoration.collapsed(hintText: ''),
        onChanged: onChanged,
      ),
    );
  }
}
