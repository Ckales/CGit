import 'package:cgit_flutter/merge_view.dart';
import 'package:cgit_flutter/theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The merge window decides what gets written into the user's file, so these
/// assert on the saved text, not on what the screen looks like. A wrong result
/// here loses work that git cannot recover.
const conflicted = 'head line\n'
    '<<<<<<< HEAD\n'
    'ours one\n'
    'ours two\n'
    '=======\n'
    'theirs one\n'
    '>>>>>>> other\n'
    'tail line';

const withBase = 'top\n'
    '<<<<<<< HEAD\n'
    'mine\n'
    '||||||| base\n'
    'ANCESTOR\n'
    '=======\n'
    'yours\n'
    '>>>>>>> other\n'
    'bottom';

const noMarkers = 'just a binary-ish file\nwith no markers\n';

class _Harness {
  String? saved;
  String? side;
  bool? wantedBase;
  bool closed = false;
}

Widget _host(_Harness h, String content) => MaterialApp(
      home: Theming(
        palette: Palette.dark,
        child: Material(
          type: MaterialType.transparency,
          child: Stack(
            children: [
              MergeWindow(
                file: 'src/app.dart',
                content: content,
                onClose: () => h.closed = true,
                onResolveWith: (c) async => h.saved = c,
                onResolveSide: (s) async => h.side = s,
                onToggleBase: (want) async => h.wantedBase = want,
              ),
            ],
          ),
        ),
      ),
    );

/// The gutter buttons are identified by their tooltip — the glyphs (» « ✕) are
/// ambiguous across the two sides, the tooltips are not. byTooltip matches the
/// message rather than rendered text, which only exists while hovering.
Finder _gutter(String tooltip) => find.byTooltip(tooltip);

void main() {
  group('deciding each side', () {
    testWidgets('refuses to save while a conflict is undecided', (tester) async {
      final h = _Harness();
      await tester.pumpWidget(_host(h, conflicted));

      expect(find.text('1 处冲突，1 处未处理'), findsOneWidget);

      await tester.tap(find.text('应用'));
      await tester.pump();
      expect(h.saved, isNull, reason: 'an undecided block would save as "ours"');
    });

    testWidgets('taking ours drops theirs from the saved file', (tester) async {
      final h = _Harness();
      await tester.pumpWidget(_host(h, conflicted));

      await tester.tap(find.text('全部采用我方'));
      await tester.pump();
      expect(find.text('1 处冲突，已全部处理'), findsOneWidget);

      await tester.tap(find.text('应用'));
      await tester.pump();
      expect(h.saved, 'head line\nours one\nours two\ntail line');
    });

    testWidgets('taking theirs drops ours', (tester) async {
      final h = _Harness();
      await tester.pumpWidget(_host(h, conflicted));

      await tester.tap(find.text('全部采用对方'));
      await tester.pump();
      await tester.tap(find.text('应用'));
      await tester.pump();

      expect(h.saved, 'head line\ntheirs one\ntail line');
    });

    testWidgets('accepting both sides keeps both, ours first', (tester) async {
      final h = _Harness();
      await tester.pumpWidget(_host(h, conflicted));

      // Two clicks, » then «, is how "take both" is expressed.
      await tester.tap(_gutter('合并我方这段 → 结果'));
      await tester.pump();
      await tester.tap(_gutter('合并对方这段 → 结果'));
      await tester.pump();

      await tester.tap(find.text('应用'));
      await tester.pump();
      expect(h.saved, 'head line\nours one\nours two\ntheirs one\ntail line');
    });

    testWidgets('dropping both sides removes the block entirely', (tester) async {
      final h = _Harness();
      await tester.pumpWidget(_host(h, conflicted));

      await tester.tap(_gutter('不合并我方这段'));
      await tester.pump();
      await tester.tap(_gutter('不合并对方这段'));
      await tester.pump();

      expect(find.text('1 处冲突，已全部处理'), findsOneWidget);
      await tester.tap(find.text('应用'));
      await tester.pump();
      expect(h.saved, 'head line\ntail line');
    });
  });

  group('the common ancestor', () {
    testWidgets('is shown for reference but never saved', (tester) async {
      final h = _Harness();
      await tester.pumpWidget(_host(h, withBase));

      expect(find.textContaining('共同祖先：ANCESTOR'), findsOneWidget);

      await tester.tap(find.text('全部采用我方'));
      await tester.pump();
      await tester.tap(find.text('应用'));
      await tester.pump();

      expect(h.saved, isNot(contains('ANCESTOR')));
      expect(h.saved, isNot(contains('|||||||')));
      expect(h.saved, 'top\nmine\nbottom');
    });

    testWidgets('the toggle asks for the opposite of what the file has',
        (tester) async {
      final h = _Harness();
      await tester.pumpWidget(_host(h, withBase));

      // This file already has base, so the button offers to hide it.
      expect(find.text('隐藏共同祖先'), findsOneWidget);
      await tester.tap(find.text('隐藏共同祖先'));
      await tester.pump();
      expect(h.wantedBase, isFalse);
    });

    testWidgets('offers to show it when the markers have none', (tester) async {
      final h = _Harness();
      await tester.pumpWidget(_host(h, conflicted));
      expect(find.text('显示共同祖先'), findsOneWidget);
    });
  });

  group('hand editing', () {
    testWidgets('typing settles a block without touching either side',
        (tester) async {
      final h = _Harness();
      await tester.pumpWidget(_host(h, conflicted));

      // The result pane's editors: the conflict block's is the second field
      // (the first context row comes before it).
      final editors = find.byType(TextField);
      await tester.enterText(editors.at(1), 'merged by hand');
      await tester.pump();

      expect(find.text('1 处冲突，已全部处理'), findsOneWidget);
      await tester.tap(find.text('应用'));
      await tester.pump();
      expect(h.saved, 'head line\nmerged by hand\ntail line');
    });

    testWidgets('a side button replaces what was typed', (tester) async {
      final h = _Harness();
      await tester.pumpWidget(_host(h, conflicted));

      await tester.enterText(find.byType(TextField).at(1), 'scratch text');
      await tester.pump();
      await tester.tap(find.text('全部采用对方'));
      await tester.pump();

      await tester.tap(find.text('应用'));
      await tester.pump();
      expect(h.saved, isNot(contains('scratch text')));
      expect(h.saved, 'head line\ntheirs one\ntail line');
    });
  });

  group('files with no markers', () {
    testWidgets('fall back to whole-file handling', (tester) async {
      final h = _Harness();
      await tester.pumpWidget(_host(h, noMarkers));

      expect(find.text('无文本冲突标记 — 整文件处理'), findsOneWidget);
      // None of the three-pane controls apply here.
      expect(find.text('应用'), findsNothing);
      expect(find.text('全部采用我方'), findsNothing);
    });

    testWidgets('can take one whole side', (tester) async {
      final h = _Harness();
      await tester.pumpWidget(_host(h, noMarkers));

      await tester.tap(find.text('采用对方'));
      await tester.pump();
      expect(h.side, 'theirs');
    });

    testWidgets('can be edited and marked resolved', (tester) async {
      final h = _Harness();
      await tester.pumpWidget(_host(h, noMarkers));

      await tester.enterText(find.byType(TextField).first, 'fixed by hand');
      await tester.tap(find.text('标记为已解决'));
      await tester.pump();
      expect(h.saved, 'fixed by hand');
    });
  });

  testWidgets('the disabled 应用 button is visibly disabled, not just inert',
      (tester) async {
    final h = _Harness();
    await tester.pumpWidget(_host(h, conflicted));

    Color bgOf(String label) {
      final box = tester.widget<Container>(
        find
            .ancestor(of: find.text(label), matching: find.byType(Container))
            .first,
      );
      return (box.decoration as BoxDecoration).color!;
    }

    // Undecided: 应用 must not wear the accent, or it reads as clickable.
    final disabled = bgOf('应用');
    expect(disabled, isNot(Palette.dark.accent));

    await tester.tap(find.text('全部采用我方'));
    await tester.pump();
    expect(bgOf('应用'), Palette.dark.accent);
  });

  testWidgets('closing does not save', (tester) async {
    final h = _Harness();
    await tester.pumpWidget(_host(h, conflicted));

    await tester.tap(find.text('全部采用我方'));
    await tester.pump();
    await tester.tap(find.text('取消'));
    await tester.pump();

    expect(h.closed, isTrue);
    expect(h.saved, isNull);
  });

  testWidgets('both sides can be selected and copied', (tester) async {
    await tester.pumpWidget(_host(_Harness(), conflicted));
    for (final text in ['ours one\nours two', 'theirs one', 'head line']) {
      expect(
          find.ancestor(
              of: find.text(text).first, matching: find.byType(SelectionArea)),
          findsOneWidget,
          reason: text);
    }

    // Drag across the theirs block and copy: the clipboard gets its text.
    String? copied;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    final theirs = find.text('theirs one').first;
    final box = tester.getRect(theirs);
    final gesture = await tester.startGesture(box.centerLeft + const Offset(1, 0),
        kind: PointerDeviceKind.mouse);
    await tester.pump();
    await gesture.moveTo(box.centerRight - const Offset(1, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
    await tester.pump();
    expect(copied, 'theirs one');
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('a long line lays out whole, so scrolling can reveal it',
      (tester) async {
    final long = 'x = "${'长' * 200}"';
    await tester.pumpWidget(_host(
        _Harness(), 'a\n<<<<<<< HEAD\n$long\n=======\nb\n>>>>>>> o\nz'));
    await tester.pump();
    // Clipped to its pane, the paragraph would be a third of 1180px wide.
    expect(tester.getSize(find.text(long).first).width, greaterThan(1000));
  });

  testWidgets('Tab indents the selected result lines instead of moving focus',
      (tester) async {
    final h = _Harness();
    await tester.pumpWidget(_host(h, conflicted));
    await tester.tap(find.text('全部采用我方'));
    await tester.pump();

    final field = find.byWidgetPredicate((w) =>
        w is TextField && w.controller?.text == 'ours one\nours two');
    await tester.tap(field);
    await tester.pump();
    final controller = tester.widget<TextField>(field).controller!;
    controller.selection =
        TextSelection(baseOffset: 0, extentOffset: controller.text.length);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    await tester.tap(find.text('应用'));
    await tester.pump();
    expect(h.saved, 'head line\n    ours one\n    ours two\ntail line');
  });

  testWidgets('↑ / ↓ step through the conflicts, scrolling each into view',
      (tester) async {
    final filler = List.generate(80, (i) => 'line $i').join('\n');
    final content = 'a\n<<<<<<< HEAD\nfirst ours\n=======\nfirst theirs\n'
        '>>>>>>> o\n$filler\n<<<<<<< HEAD\nsecond ours\n=======\n'
        'second theirs\n>>>>>>> o\nz';
    await tester.pumpWidget(_host(_Harness(), content));
    expect(find.text('- / 2'), findsOneWidget);

    await tester.tap(find.byTooltip('下一处冲突'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('下一处冲突'));
    await tester.pumpAndSettle();
    expect(find.text('2 / 2'), findsOneWidget);
    // Scrolled far enough that the second block sits inside the window.
    final window = tester.getRect(find.byType(MergeWindow));
    final second = tester.getRect(find.text('second ours'));
    expect(second.top, greaterThan(window.top));
    expect(second.bottom, lessThan(window.bottom));

    // Wraps around at the end, and ↑ goes back.
    await tester.tap(find.byTooltip('下一处冲突'));
    await tester.pumpAndSettle();
    expect(find.text('1 / 2'), findsOneWidget);
    await tester.tap(find.byTooltip('上一处冲突'));
    await tester.pumpAndSettle();
    expect(find.text('2 / 2'), findsOneWidget);
  });
}
