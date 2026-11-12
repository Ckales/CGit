import 'dart:ui' as ui;

import 'package:cgit_flutter/merge_view.dart';
import 'package:cgit_flutter/theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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

const twBase = 'one\ntwo\nthree\nfour\nfive\n';
const twOurs = 'one\nOURS two\nthree\nfour\nfive\n';
const twTheirs = 'one\nTHEIRS two\nthree\nfour\nTHEIRS five\n';

class _Harness {
  String? saved;
  String? side;
  bool closed = false;
}

Widget _host(_Harness h, String content,
        {String? base,
        String? ours,
        String? theirs,
        String? oursLabel,
        String? theirsLabel,
        Palette palette = Palette.dark}) =>
    MaterialApp(
      home: Theming(
        palette: palette,
        child: Material(
          type: MaterialType.transparency,
          child: Stack(
            children: [
              MergeWindow(
                file: 'src/app.dart',
                content: content,
                base: base,
                ours: ours,
                theirs: theirs,
                oursLabel: oursLabel,
                theirsLabel: theirsLabel,
                onClose: () => h.closed = true,
                onResolveWith: (c) async => h.saved = c,
                onResolveSide: (s) async => h.side = s,
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

String _resultText(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField)).controller!.text;

dynamic _resultStripes(WidgetTester tester) => tester
    .widget<CustomPaint>(find.byKey(const ValueKey('merge-result-stripes')))
    .painter;

void main() {
  testWidgets(
      'linked scrolling anchors a source-only range one third down the viewport',
      (tester) async {
    final before = List.generate(60, (i) => 'before-$i').join('\n');
    final after = List.generate(100, (i) => 'after-$i').join('\n');
    final ours = List.generate(30, (i) => 'ours-$i').join('\n');
    final theirs = List.generate(10, (i) => 'theirs-$i').join('\n');
    await tester.pumpWidget(_host(_Harness(), '',
        base: '$before\n$after',
        ours: '$before\n$ours\n$after',
        theirs: '$before\n$theirs\n$after'));
    await tester.pumpAndSettle();
    final panes = find.byWidgetPredicate((w) =>
        w is SingleChildScrollView &&
        w.scrollDirection == Axis.vertical &&
        w.controller != null);
    final source =
        tester.widget<SingleChildScrollView>(panes.first).controller!;
    final result =
        tester.widget<SingleChildScrollView>(panes.at(1)).controller!;
    final painter = tester
        .widget<CustomPaint>(find.byKey(const ValueKey('merge-connectors-0')))
        .painter! as dynamic;
    final double lineHeight = painter.lineHeight;
    source.jumpTo(75 * lineHeight - source.position.viewportDimension / 3);
    await tester.pumpAndSettle();
    expect(60 * lineHeight - result.offset,
        closeTo(result.position.viewportDimension / 3, 0.1),
        reason: 'an empty middle range stays at the viewport reference point');
    source.jumpTo(95 * lineHeight - source.position.viewportDimension / 3);
    await tester.pumpAndSettle();
    expect(65 * lineHeight - result.offset,
        closeTo(result.position.viewportDimension / 3, 0.1),
        reason: 'common context after the insertion lines up again');
  });

  testWidgets('conflict code and gutters use one red treatment on both sides',
      (tester) async {
    await tester.pumpWidget(_host(_Harness(), '',
        base: 'head\nobject_to_array\ntail',
        ours: 'head\nfailFormat\nreturn false\nobject_to_array\ntail',
        theirs: 'head\nshowData\nobject_to_array\ntail'));
    await tester.pumpAndSettle();
    final left = tester
        .widget<Container>(find.byKey(const ValueKey('merge-source-0-0')));
    final right = tester
        .widget<Container>(find.byKey(const ValueKey('merge-source-2-0')));
    expect(right.color, left.color,
        reason: 'both alternatives belong to the same unresolved conflict');
    for (final pane in [0, 2]) {
      final paint = tester
          .widget<CustomPaint>(find.byKey(ValueKey('merge-connectors-$pane')))
          .painter! as dynamic;
      expect(paint.marks.single.fill.a, 1,
          reason: 'the source gutter is solid, not a translucent tapered band');
      final recorder = ui.PictureRecorder();
      paint.paint(Canvas(recorder), const Size(78, 120));
      final picture = recorder.endRecording();
      await tester.runAsync(() async {
        final image = await picture.toImage(78, 120);
        final bytes =
            await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        final int y = (6 + (pane == 0 ? 2.5 : 1.5) * paint.lineHeight).floor();
        final solidX = pane == 0 ? 40 : 37;
        expect(bytes!.getUint8((y * 78 + solidX) * 4 + 3), 255,
            reason: 'the action strip stays solid across the source height');
        final seamX = pane == 0 ? 77 : 0;
        expect(bytes.getUint8((y * 78 + seamX) * 4 + 3), 0,
            reason: 'only the narrow divider tapers to the middle boundary');
        image.dispose();
      });
      picture.dispose();
      final button =
          tester.getRect(_gutter(pane == 0 ? '合并我方这段 → 结果' : '合并对方这段 → 结果'));
      final block =
          tester.getRect(find.byKey(ValueKey('merge-source-$pane-0')));
      expect((button.top - block.top).abs(), lessThan(3),
          reason: 'conflict actions start at the block boundary');
    }
  });

  testWidgets(
      'ordinary conflict blocks connect both source ranges while scrolling',
      (tester) async {
    final before = List.generate(30, (i) => 'before-$i').join('\n');
    final after = List.generate(100, (i) => 'after-$i').join('\n');
    await tester.pumpWidget(_host(_Harness(), '',
        base: '$before\nbase one\nbase two\nbase three\n$after',
        ours: '$before\nours one\nours two\n$after',
        theirs:
            '$before\ntheirs one\ntheirs two\ntheirs three\ntheirs four\n$after'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('同步滚动：开'));
    await tester.pump();
    final panes = find.byWidgetPredicate((w) =>
        w is SingleChildScrollView &&
        w.scrollDirection == Axis.vertical &&
        w.controller != null);
    for (final (pane, offset) in [(0, 19.0), (1, 37.0), (2, 61.0)]) {
      tester
          .widget<SingleChildScrollView>(panes.at(pane))
          .controller!
          .jumpTo(offset);
    }
    await tester.pump();
    for (final (pane, length, offset) in [(0, 2, 19.0), (2, 4, 61.0)]) {
      final link = find.byKey(ValueKey('merge-connectors-$pane'));
      expect(link, findsOneWidget,
          reason:
              'ordinary modified blocks need the same scrolling connection as deletions');
      final painter = tester.widget<CustomPaint>(link).painter! as dynamic;
      final mark = painter.marks.single;
      expect(mark.sourceFirst, 30);
      expect(mark.sourceEnd, 30 + length);
      expect(mark.resultFirst, 30);
      expect(mark.resultEnd, 33);
      expect(painter.sourceOffset, offset);
      expect(painter.resultOffset, 37);
      final recorder = ui.PictureRecorder();
      painter.paint(Canvas(recorder), const Size(56, 1000));
      final picture = recorder.endRecording();
      await tester.runAsync(() async {
        final image = await picture.toImage(56, 1000);
        final bytes =
            await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        final sourceY =
            (6 + (30 + length / 2) * painter.lineHeight - offset).floor();
        final resultY = (6 + 31.5 * painter.lineHeight - 37).floor();
        final sourceX = pane == 0 ? 0 : 55;
        final resultX = pane == 0 ? 55 : 0;
        expect(
            bytes!.getUint8((sourceY * 56 + sourceX) * 4 + 3), greaterThan(0),
            reason: 'the curve reaches the actual source block');
        expect(bytes.getUint8((resultY * 56 + resultX) * 4 + 3), greaterThan(0),
            reason: 'the curve reaches the actual result block');
        expect(bytes.getUint8(3), 0,
            reason: 'unchanged rows remain outside the connector');
        image.dispose();
      });
      picture.dispose();
    }
    expect(
        _resultText(tester), '$before\nbase one\nbase two\nbase three\n$after');
  });

  for (final palette in [Palette.dark, Palette.light]) {
    testWidgets(
        'conflicting insertions connect to an empty result then follow decisions ${palette == Palette.dark ? 'dark' : 'light'}',
        (tester) async {
      await tester.pumpWidget(_host(_Harness(), '',
          palette: palette,
          base: 'head\nobject_to_array\ntail',
          ours: 'head\nfailFormat\nreturn false\nobject_to_array\ntail',
          theirs: 'head\nshowData\nobject_to_array\ntail'));
      await tester.pumpAndSettle();
      dynamic mark(int pane) => (tester
              .widget<CustomPaint>(
                  find.byKey(ValueKey('merge-connectors-$pane')))
              .painter! as dynamic)
          .marks
          .single;
      for (final pane in [0, 2]) {
        if (identical(palette, Palette.light)) {
          final block = tester
              .widget<Container>(find.byKey(ValueKey('merge-source-$pane-0')));
          expect(block.color, Color.alphaBlend(palette.delRow, palette.diffBg),
              reason:
                  'light conflict code keeps the original red diff background');
          expect(palette.mergeConflictInline, palette.intraDel,
              reason: 'changed text uses the original red highlight');
        }
        expect(mark(pane).sourceFirst, 1);
        expect(mark(pane).sourceEnd, pane == 0 ? 3 : 2);
        expect(mark(pane).resultFirst, 1);
        expect(mark(pane).resultEnd, 1,
            reason: 'unaccepted insertions connect to a line boundary');
        expect(mark(pane).fill, palette.mergeConflictMarker);
      }
      expect(_resultText(tester), 'head\nobject_to_array\ntail');
      await tester.tap(_gutter('合并我方这段 → 结果'));
      await tester.pumpAndSettle();
      for (final pane in [0, 2]) {
        expect(mark(pane).resultFirst, 1);
        expect(mark(pane).resultEnd, 3);
      }
      await tester.tap(find.byTooltip('撤销'));
      await tester.pumpAndSettle();
      expect(mark(0).resultEnd, 1);
      expect(mark(2).resultEnd, 1);
      await tester.enterText(find.byType(TextField),
          'head\nmanual one\nmanual two\nmanual three\nobject_to_array\ntail');
      await tester.pumpAndSettle();
      expect(mark(0).resultEnd, 4);
      expect(mark(2).resultEnd, 4);
    });
  }

  for (final sides in ['ours', 'theirs', 'both']) {
    testWidgets('$sides clean changes keep connectors after accepting',
        (tester) async {
      await tester.pumpWidget(_host(_Harness(), '',
          base: 'a\nbase\nb',
          ours: sides == 'theirs' ? 'a\nbase\nb' : 'a\nnew\nb',
          theirs: sides == 'ours' ? 'a\nbase\nb' : 'a\nnew\nb'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('应用全部不冲突的更改'));
      await tester.pumpAndSettle();
      for (final pane in [0, 2]) {
        final hasChange = sides == 'both' ||
            (pane == 0 ? sides == 'ours' : sides == 'theirs');
        final link = find.byKey(ValueKey('merge-connectors-$pane'));
        expect(link, hasChange ? findsOneWidget : findsNothing);
        if (hasChange) {
          final mark = (tester.widget<CustomPaint>(link).painter! as dynamic)
              .marks
              .single;
          expect(mark.sourceFirst, 1);
          expect(mark.sourceEnd, 2);
          expect(mark.resultFirst, 1);
          expect(mark.resultEnd, 2);
        }
      }
      expect(_resultText(tester), 'a\nnew\nb');
    });
  }

  testWidgets('pending insertions at EOF connect after the last context line',
      (tester) async {
    await tester.pumpWidget(_host(_Harness(), '',
        base: 'head', ours: 'head\nours', theirs: 'head\ntheirs'));
    await tester.pumpAndSettle();
    for (final pane in [0, 2]) {
      final mark = (tester
              .widget<CustomPaint>(
                  find.byKey(ValueKey('merge-connectors-$pane')))
              .painter! as dynamic)
          .marks
          .single;
      expect(mark.sourceFirst, 1);
      expect(mark.resultFirst, 1);
      expect(mark.resultEnd, 1,
          reason:
              'EOF without a newline still has a boundary after its final row');
    }
  });

  for (final palette in [Palette.dark, Palette.light]) {
    testWidgets(
        'deletion collapses the source and shades the full retained block ${palette == Palette.dark ? 'dark' : 'light'}',
        (tester) async {
      await tester.pumpWidget(_host(_Harness(), '',
          palette: palette,
          base: 'a\ngone one\ngone two\nb',
          ours: 'a\nb',
          theirs: 'a\ngone one\ngone two\nb'));
      await tester.pumpAndSettle();
      final panes = find.byWidgetPredicate((w) =>
          w is SingleChildScrollView &&
          w.scrollDirection == Axis.vertical &&
          w.controller != null);
      final source = tester.widgetList<Text>(
          find.descendant(of: panes.first, matching: find.byType(Text)));
      final sourceText =
          source.map((w) => w.data ?? w.textSpan!.toPlainText()).join('\n');
      expect(sourceText, isNot(contains('gone one')),
          reason:
              'the deleted side must show its actual file, without ghost code');
      final painter = tester
          .widget<CustomPaint>(
              find.byKey(const ValueKey('merge-result-deletions')))
          .painter!;
      final recorder = ui.PictureRecorder();
      painter.paint(Canvas(recorder), const Size(360, 120));
      final picture = recorder.endRecording();
      await tester.runAsync(() async {
        final image = await picture.toImage(360, 120);
        final bytes =
            await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        expect(bytes!.getUint8((25 * 360 + 300) * 4 + 3), greaterThan(0),
            reason: 'the retained code is shaded across the full pane');
        final offset = (25 * 360 + 300) * 4;
        expect(bytes.getUint8(offset),
            palette.deletedFragment.toARGB32() >> 16 & 255);
        expect(bytes.getUint8(offset + 1),
            palette.deletedFragment.toARGB32() >> 8 & 255);
        expect(bytes.getUint8(offset + 2),
            palette.deletedFragment.toARGB32() & 255);
        image.dispose();
      });
      picture.dispose();
      expect(_resultText(tester), 'a\ngone one\ngone two\nb');
    });
  }

  testWidgets('deletion connectors track independently scrolled panes',
      (tester) async {
    final before = List.generate(30, (i) => 'before-$i').join('\n');
    final removed = List.generate(30, (i) => 'gone-$i').join('\n');
    final after = List.generate(100, (i) => 'after-$i').join('\n');
    await tester.pumpWidget(_host(_Harness(), '',
        base: '$before\n$removed\n$after',
        ours: '$before\n$after',
        theirs: '$before\n$removed\n$after'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('同步滚动：开'));
    await tester.pump();
    final panes = find.byWidgetPredicate((w) =>
        w is SingleChildScrollView &&
        w.scrollDirection == Axis.vertical &&
        w.controller != null);
    final source =
        tester.widget<SingleChildScrollView>(panes.first).controller!;
    final result =
        tester.widget<SingleChildScrollView>(panes.at(1)).controller!;
    source.jumpTo(19);
    result.jumpTo(37);
    await tester.pump();
    final connector = tester
        .widget<CustomPaint>(find.byKey(const ValueKey('merge-connectors-0')))
        .painter! as dynamic;
    expect(connector.sourceOffset, 19);
    expect(connector.resultOffset, 37);
    expect(connector.marks.single.sourceFirst, 30);
    expect(connector.marks.single.sourceEnd, 30);
    expect(connector.marks.single.resultFirst, 30);
    expect(connector.marks.single.resultEnd, 60);
  });

  for (final location in ['start', 'end', 'entire']) {
    testWidgets(
        '$location deletion leaves visible controls and no phantom rows',
        (tester) async {
      final base = location == 'start' ? 'gone\na' : 'a\ngone';
      final ours = location == 'entire' ? '' : 'a';
      await tester.pumpWidget(
          _host(_Harness(), '', base: base, ours: ours, theirs: base));
      await tester.pumpAndSettle();
      final accept = _gutter('合并我方这处非冲突修改 → 结果');
      final button = tester.getRect(accept);
      final rail =
          tester.getRect(find.byKey(const ValueKey('merge-connectors-0')));
      expect(button.top, greaterThanOrEqualTo(rail.top));
      expect(button.bottom, lessThanOrEqualTo(rail.bottom));
      await tester.tapAt(Offset(button.center.dx, button.bottom - 1));
      await tester.pumpAndSettle();
      expect(_resultText(tester), ours);
    });
  }

  testWidgets(
      'mouse clicks on gutter edges accept and ignore without moving scrollbars',
      (tester) async {
    final before = List.generate(60, (i) => 'before-$i').join('\n');
    final after = List.generate(100, (i) => 'after-$i').join('\n');
    await tester.pumpWidget(_host(_Harness(), '',
        base: '$before\nbase\n$after',
        ours: '$before\nours\n$after',
        theirs: '$before\ntheirs\n$after'));
    await tester.pumpAndSettle();
    final scrolls = find.byWidgetPredicate((w) =>
        w is SingleChildScrollView &&
        w.scrollDirection == Axis.vertical &&
        w.controller != null);
    final paneControllers = tester
        .widgetList<SingleChildScrollView>(find.byWidgetPredicate(
            (w) => w is SingleChildScrollView && w.controller != null))
        .map((w) => w.controller!)
        .toSet();
    expect(paneControllers, hasLength(6));
    for (final controller in paneControllers) {
      expect(
          find.byWidgetPredicate(
              (w) => w is RawScrollbar && w.controller == controller),
          findsOneWidget,
          reason: 'no duplicate scrollbar for a pane axis');
    }
    List<double> offsets() => tester
        .widgetList<SingleChildScrollView>(scrolls)
        .map((w) => w.controller!.offset)
        .toList();
    final originalOffsets = offsets();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer();
    addTearDown(mouse.removePointer);
    Future<void> click(Finder button, {required bool rightEdge}) async {
      final rect = tester.getRect(button);
      final point =
          Offset(rightEdge ? rect.right - 3 : rect.left + 3, rect.center.dy);
      await mouse.moveTo(point);
      await tester.pump(const Duration(milliseconds: 700));
      await mouse.down(point);
      await mouse.up();
      await tester.pumpAndSettle();
    }

    await click(_gutter('合并我方这段 → 结果'), rightEdge: true);
    expect(_resultText(tester), '$before\nours\n$after');
    expect(offsets(), originalOffsets);
    await click(_gutter('不合并我方这段'), rightEdge: false);
    expect(_resultText(tester), '$before\nbase\n$after');
    await click(_gutter('合并对方这段 → 结果'), rightEdge: false);
    expect(_resultText(tester), '$before\ntheirs\n$after');
    expect(offsets(), originalOffsets);
    // Wheel over the gutter scrolls the pane it belongs to: the rail listens
    // for pointer signals itself because it sits outside the scrollbar.
    final button = _gutter('合并我方这段 → 结果');
    final buttonBefore = tester.getRect(button);
    tester.binding.handlePointerEvent(PointerScrollEvent(
        position: buttonBefore.center, scrollDelta: const Offset(0, 34)));
    await tester.pumpAndSettle();
    expect(offsets().first, originalOffsets.first + 34);
    expect(tester.getRect(button).top, closeTo(buttonBefore.top - 34, 0.1));
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('scrollbars hug the pane edges instead of the content',
      (tester) async {
    final lines = List.generate(80, (i) => "line-$i ${'wide ' * 30}".trim());
    final body = lines.join('\n');
    await tester.pumpWidget(_host(_Harness(), '',
        base: '$body\nbase', ours: '$body\nours', theirs: '$body\ntheirs'));
    await tester.pumpAndSettle();
    final viewports = find.byWidgetPredicate((w) =>
        w is SingleChildScrollView &&
        w.scrollDirection == Axis.vertical &&
        w.controller != null);
    expect(viewports, findsNWidgets(3));
    final controllers = tester
        .widgetList<SingleChildScrollView>(find.byWidgetPredicate(
            (w) => w is SingleChildScrollView && w.controller != null))
        .map((w) => w.controller!)
        .toSet();
    // The multiline result field brings its own scrollbars; only the panes' own
    // controllers are under test.
    final bars = tester
        .widgetList<Scrollbar>(find.byType(Scrollbar))
        .where((bar) => controllers.contains(bar.controller))
        .toList();
    expect(bars, hasLength(6),
        reason: 'one vertical and one horizontal bar per pane');
    final viewport = tester.getRect(viewports.first);
    for (final bar in bars) {
      final rect =
          tester.getRect(find.byWidgetPredicate((w) => identical(w, bar)));
      // The bar's own box must be the visible pane: a horizontal bar nested in
      // the vertical content instead reports the whole document's height and
      // paints hundreds of pixels below the pane.
      expect(rect.top, closeTo(viewport.top, 0.1));
      expect(rect.bottom, closeTo(viewport.bottom, 0.1));
    }
    final verticalBars = bars
        .where((bar) => bar.thumbVisibility ?? false)
        .toList()
      ..sort((a, b) => tester
          .getRect(find.byWidgetPredicate((w) => identical(w, a)))
          .left
          .compareTo(tester
              .getRect(find.byWidgetPredicate((w) => identical(w, b)))
              .left));
    expect(verticalBars, hasLength(3),
        reason: 'the vertical bar stays visible like the reference dialog');
    // The reference dialog mirrors its left pane: scrollbar outside, line
    // numbers facing the result. The result and right panes keep the bar on
    // their right edge.
    expect(verticalBars.first.scrollbarOrientation, ScrollbarOrientation.left);
    expect(verticalBars.last.scrollbarOrientation,
        isNot(ScrollbarOrientation.left));
    // The left pane's gutter faces the result, so its joined line-number text
    // ends where the pane's scroll area ends; the right pane's starts there.
    final gutters = find.byWidgetPredicate(
        (w) => w is Text && (w.data?.startsWith('1\n') ?? false));
    expect(gutters, findsNWidgets(2));
    final oursGutter = tester.getRect(gutters.at(0));
    final theirsGutter = tester.getRect(gutters.at(1));
    final oursBar = tester.getRect(
        find.byWidgetPredicate((w) => identical(w, verticalBars.first)));
    final theirsBar = tester.getRect(
        find.byWidgetPredicate((w) => identical(w, verticalBars.last)));
    expect(oursGutter.right, closeTo(oursBar.right, 0.1));
    expect(theirsGutter.left, closeTo(theirsBar.left, 0.1));
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('empty conflict controls do not overlap the next block',
      (tester) async {
    await tester.pumpWidget(_host(
        _Harness(),
        'head\n<<<<<<< HEAD\n=======\n>>>>>>> other\n'
        '<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> other\ntail'));
    await tester.pumpAndSettle();
    final buttons = _gutter('合并我方这段 → 结果');
    expect(buttons, findsNWidgets(2));
    final first = tester.getRect(buttons.at(0));
    final second = tester.getRect(buttons.at(1));
    expect(first.height, greaterThan(0));
    expect(first.bottom, lessThanOrEqualTo(second.top));
    await tester.tap(buttons.at(0));
    await tester.pump();
    expect(find.text('2 个冲突。'), findsOneWidget);
    expect(find.text('1 处冲突未处理'), findsOneWidget);
  });

  for (final scale in [12 / 13, 1.0, 15 / 13]) {
    testWidgets('opening and navigation show block starts at text scale $scale',
        (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      String lines(String prefix, int count) =>
          List.generate(count, (i) => '$prefix-$i').join('\n');
      final before = '${lines('before', 80)}\n';
      final between = '${lines('between', 80)}\n';
      final after = lines('after', 80);
      await tester.pumpWidget(_host(_Harness(), '',
          base:
              '$before\n${lines('base-one', 60)}\n$between\n${lines('base-two', 90)}\n$after',
          ours:
              '$before\n${lines('ours-one', 100)}\n$between\n${lines('ours-two', 120)}\n$after',
          theirs:
              '$before\n${lines('theirs-one', 120)}\n$between\n${lines('theirs-two', 100)}\n$after'));
      await tester.pumpAndSettle();
      final panes = find.byWidgetPredicate((w) =>
          w is SingleChildScrollView &&
          w.scrollDirection == Axis.vertical &&
          w.controller != null);
      expect(panes, findsNWidgets(3));
      void expectStarts(String block) {
        for (final (pane, side) in [(0, 'ours'), (2, 'theirs')]) {
          final viewport = tester.getRect(panes.at(pane));
          final firstLine = tester.getRect(find.text('$side-$block-0'));
          expect(
              firstLine.top, inInclusiveRange(viewport.top, viewport.top + 100),
              reason: '$side $block starts near the viewport top');
        }
        final controller =
            tester.widget<TextField>(find.byType(TextField)).controller!;
        expect(controller.text.substring(controller.selection.start),
            startsWith('base-$block-0'));
        final editor = tester.allRenderObjects
            .whereType<RenderEditable>()
            .where((editor) => editor.text?.toPlainText() == controller.text)
            .single;
        final caret = editor.localToGlobal(editor
            .getLocalRectForCaret(
                TextPosition(offset: controller.selection.start))
            .topLeft);
        final viewport = tester.getRect(panes.at(1));
        expect(caret.dy, inInclusiveRange(viewport.top, viewport.top + 100));
        final sourceStart = tester.getRect(find.text('ours-$block-0')).top;
        expect((caret.dy - sourceStart).abs(), lessThan(5),
            reason:
                'blank context lines must not accumulate result-pane drift');
      }

      expectStarts('one');
      await tester.tap(find.byTooltip('下一处差异'));
      await tester.pumpAndSettle();
      expectStarts('two');
      await tester.tap(find.byTooltip('上一处差异'));
      await tester.pumpAndSettle();
      expectStarts('one');
    });
  }

  testWidgets('opening and navigating long lines show their beginnings',
      (tester) async {
    final long = 'abcdefghij' * 60;
    await tester.pumpWidget(_host(_Harness(), '',
        base: 'head\nbase_$long\ncontext\nbase_second_$long\ntail',
        ours: 'head\nours_$long\ncontext\nours_second_$long\ntail',
        theirs: 'head\ntheirs_$long\ncontext\ntheirs_second_$long\ntail'));
    await tester.pumpAndSettle();
    // The toolbar also scrolls horizontally, without a controller; only the
    // three panes are linked.
    final horizontal = find.byWidgetPredicate((w) =>
        w is SingleChildScrollView &&
        w.scrollDirection == Axis.horizontal &&
        w.controller != null);
    List<ScrollController> controllers() => tester
        .widgetList<SingleChildScrollView>(horizontal)
        .map((w) => w.controller!)
        .toList();
    expect(controllers(), hasLength(3));
    for (final controller in controllers()) {
      expect(controller.offset, 0);
    }

    await tester.tap(find.byTooltip('下一处差异'));
    await tester.pumpAndSettle();
    expect(find.text('2 / 2'), findsOneWidget);
    for (final controller in controllers()) {
      expect(controller.offset, 0,
          reason:
              'navigation must not reveal a selection endpoint at the line end');
    }
    final result = tester.widget<TextField>(find.byType(TextField)).controller!;
    expect(result.selection.isCollapsed, isTrue);
    expect(result.text.substring(result.selection.start),
        startsWith('base_second_'));

    // A deliberate horizontal scroll remains useful until navigating elsewhere.
    controllers().first.jumpTo(150);
    await tester.pumpAndSettle();
    for (final controller in controllers()) {
      expect(controller.offset, 150);
    }
    await tester.tap(find.byTooltip('上一处差异'));
    await tester.pumpAndSettle();
    for (final controller in controllers()) {
      expect(controller.offset, 0);
    }
  });

  testWidgets(
      'loading another document resets horizontal scrolling even without changes',
      (tester) async {
    final long = 'abcdefghij' * 60;
    await tester.pumpWidget(_host(_Harness(), '',
        base: 'base_$long', ours: 'ours_$long', theirs: 'theirs_$long'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('下一处差异'));
    await tester.pumpAndSettle();
    final horizontal = find.byWidgetPredicate((w) =>
        w is SingleChildScrollView &&
        w.scrollDirection == Axis.horizontal &&
        w.controller != null);
    tester
        .widget<SingleChildScrollView>(horizontal.first)
        .controller!
        .jumpTo(150);
    await tester.pumpAndSettle();
    await tester.pumpWidget(
        _host(_Harness(), '', base: long, ours: long, theirs: long));
    await tester.pumpAndSettle();
    for (final scroll in tester.widgetList<SingleChildScrollView>(horizontal)) {
      expect(scroll.controller!.offset, 0);
    }
  });

  testWidgets('accept and ignore controls sit beside the result pane',
      (tester) async {
    await tester.pumpWidget(_host(_Harness(), conflicted));
    await tester.pumpAndSettle();
    final leftAccept = tester.getRect(_gutter('合并我方这段 → 结果'));
    final leftIgnore = tester.getRect(_gutter('不合并我方这段'));
    final rightAccept = tester.getRect(_gutter('合并对方这段 → 结果'));
    final rightIgnore = tester.getRect(_gutter('不合并对方这段'));
    final result = tester.getRect(find.byType(TextField));
    expect(result.left - leftAccept.right, inInclusiveRange(0, 90));
    expect(leftIgnore.right, lessThanOrEqualTo(leftAccept.left));
    expect(rightAccept.right, lessThanOrEqualTo(rightIgnore.left));
    expect(rightAccept.left, greaterThan(result.left));
    expect(rightIgnore.right,
        lessThan(tester.getRect(find.text('theirs one')).left));
  });

  testWidgets(
      'opening selects the first difference and arrows also visit clean changes',
      (tester) async {
    await tester.pumpWidget(_host(_Harness(), '',
        base: 'a\nb\nc\nd\ne\nf\ng',
        ours: 'a\nOURS b\nc\nOURS d\ne\nf\ng',
        theirs: 'a\nb\nc\nTHEIRS d\ne\nf\nTHEIRS g'));
    await tester.pumpAndSettle();
    final original = _resultText(tester);
    expect(original, 'a\nb\nc\nd\ne\nf\ng');
    expect(find.text('1 / 3'), findsOneWidget);
    expect(find.text('2 个更改。1 个冲突。'), findsOneWidget);
    expect(find.text('1 处冲突未处理'), findsOneWidget);
    await tester.tap(find.byTooltip('下一处差异'));
    await tester.pumpAndSettle();
    expect(find.text('2 / 3'), findsOneWidget);
    await tester.tap(find.byTooltip('下一处差异'));
    await tester.pumpAndSettle();
    expect(find.text('3 / 3'), findsOneWidget);
    await tester.tap(find.byTooltip('下一处差异'));
    await tester.pumpAndSettle();
    expect(find.text('1 / 3'), findsOneWidget);
    await tester.tap(find.byTooltip('上一处差异'));
    await tester.pumpAndSettle();
    expect(find.text('3 / 3'), findsOneWidget);
    expect(_resultText(tester), original);
  });

  testWidgets('a merge with only clean changes still has navigation',
      (tester) async {
    await tester.pumpWidget(_host(_Harness(), '',
        base: twBase,
        ours: twOurs,
        theirs: 'one\ntwo\nthree\nfour\nTHEIRS five\n'));
    await tester.pumpAndSettle();
    expect(find.text('1 / 2'), findsOneWidget);
    await tester.tap(find.byTooltip('下一处差异'));
    await tester.pumpAndSettle();
    expect(find.text('2 / 2'), findsOneWidget);
    expect(find.text('2 个更改。'), findsOneWidget);
  });

  testWidgets('F7 navigates all differences immediately after opening',
      (tester) async {
    await tester.pumpWidget(_host(_Harness(), '',
        base: twBase,
        ours: twOurs,
        theirs: 'one\ntwo\nthree\nfour\nTHEIRS five\n'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.f7);
    await tester.pumpAndSettle();
    expect(find.text('2 / 2'), findsOneWidget);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.f7);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(find.text('1 / 2'), findsOneWidget);
  });

  testWidgets('keeping the ancestor does not force acceptance of clean changes',
      (tester) async {
    final h = _Harness();
    await tester
        .pumpWidget(_host(h, '', base: twBase, ours: twOurs, theirs: twBase));
    expect(_resultText(tester), twBase);
    await tester.tap(find.text('应用'));
    expect(h.saved, twBase);
  });

  testWidgets('bulk arrows apply one side without touching the other',
      (tester) async {
    await tester.pumpWidget(_host(_Harness(), '',
        base: 'a\nb\nc\nd\ne\nf\ng',
        ours: 'a\nOURS b\nc\nd\ne\nf\ng',
        theirs: 'a\nb\nc\nTHEIRS d\ne\nf\nTHEIRS g'));
    await tester.pumpAndSettle();
    expect(_resultText(tester), 'a\nb\nc\nd\ne\nf\ng');

    await tester.tap(find.byTooltip('只应用我方的非冲突更改'));
    await tester.pump();
    expect(_resultText(tester), 'a\nOURS b\nc\nd\ne\nf\ng');

    await tester.tap(find.byTooltip('只应用对方的非冲突更改'));
    await tester.pump();
    expect(_resultText(tester), 'a\nOURS b\nc\nTHEIRS d\ne\nf\nTHEIRS g');
  });

  testWidgets('headers name both branches and the result file', (tester) async {
    await tester.pumpWidget(_host(_Harness(), '',
        base: twBase,
        ours: twOurs,
        theirs: twTheirs,
        oursLabel: 'dev',
        theirsLabel: 'dev-temp'));
    await tester.pumpAndSettle();
    expect(find.text('来自 dev 的更改'), findsOneWidget);
    expect(find.text('来自 dev-temp 的更改'), findsOneWidget);
    expect(find.text('结果 src/app.dart'), findsOneWidget);
  });

  group('deciding each side', () {
    testWidgets('refuses to save while a conflict is undecided',
        (tester) async {
      final h = _Harness();
      await tester.pumpWidget(_host(h, conflicted));

      expect(find.text('1 处冲突未处理'), findsOneWidget);

      await tester.tap(find.text('应用'));
      await tester.pump();
      expect(h.saved, isNull,
          reason: 'an undecided block would save as "ours"');
    });

    testWidgets('taking ours drops theirs from the saved file', (tester) async {
      final h = _Harness();
      await tester.pumpWidget(_host(h, conflicted));

      await tester.tap(find.text('全部采用我方'));
      await tester.pump();
      expect(find.text('1 处冲突未处理'), findsNothing);

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

    testWidgets('dropping both sides removes the block entirely',
        (tester) async {
      final h = _Harness();
      await tester.pumpWidget(_host(h, conflicted));

      await tester.tap(_gutter('不合并我方这段'));
      await tester.pump();
      await tester.tap(_gutter('不合并对方这段'));
      await tester.pump();

      expect(find.text('1 处冲突未处理'), findsNothing);
      await tester.tap(find.text('应用'));
      await tester.pump();
      expect(h.saved, 'head line\ntail line');
    });
  });

  group('real three-way versions', () {
    testWidgets('show all changes but initialize the complete result from base',
        (tester) async {
      final h = _Harness();
      await tester.pumpWidget(
          _host(h, '', base: twBase, ours: twOurs, theirs: twTheirs));

      // Both sides are visible as their own versions, not as a pre-merged file.
      expect(find.text('OURS two'), findsOneWidget);
      expect(find.text('THEIRS two'), findsOneWidget);
      expect(find.text('THEIRS five'), findsOneWidget);

      // Neither conflicting nor clean changes have been accepted yet.
      expect(_resultText(tester), twBase);
      expect(find.text('1 个更改。1 个冲突。'), findsOneWidget);
      expect(find.text('1 处冲突未处理'), findsOneWidget);
      expect(find.textContaining('共同祖先：two'), findsOneWidget);
    });

    testWidgets(
        'a clean change is applied only after accepting and can be ignored',
        (tester) async {
      await tester.pumpWidget(
          _host(_Harness(), '', base: twBase, ours: twOurs, theirs: twTheirs));
      expect(_resultText(tester), twBase);
      expect(find.byTooltip('忽略对方这处非冲突修改'), findsOneWidget);

      await tester.tap(find.byTooltip('合并对方这处非冲突修改 → 结果'));
      await tester.pump();
      expect(_resultText(tester), 'one\ntwo\nthree\nfour\nTHEIRS five\n');
      // Applied: the result bar is the marker, so the chip is gone.
      expect(find.byTooltip('合并对方这处非冲突修改 → 结果'), findsNothing);
      expect(find.byTooltip('忽略对方这处非冲突修改'), findsNothing);
      expect(_resultStripes(tester).lines, [4]);
      expect(_resultStripes(tester).color, Palette.dark.green);

      await tester.tap(find.text('撤销'));
      await tester.pump();
      expect(_resultText(tester), twBase);
      expect(_resultStripes(tester).lines, isEmpty);
      await tester.tap(find.byTooltip('忽略对方这处非冲突修改'));
      await tester.pump();
      expect(_resultText(tester), twBase);
      expect(_resultStripes(tester).lines, isEmpty);
    });

    testWidgets(
        'bulk merging accepts clean changes and keeps conflicts pending',
        (tester) async {
      final h = _Harness();
      await tester.pumpWidget(
          _host(h, '', base: twBase, ours: twOurs, theirs: twTheirs));
      expect(_resultText(tester), twBase);
      await tester.tap(find.byTooltip('应用全部不冲突的更改'));
      await tester.pump();
      expect(_resultText(tester), 'one\ntwo\nthree\nfour\nTHEIRS five\n');
      expect(find.text('1 个更改。1 个冲突。'), findsOneWidget);
      // The applied line is a solid result bar, not a blue « × chip.
      expect(_resultStripes(tester).lines, [4]);
      expect(_resultStripes(tester).color, Palette.dark.green);
      expect(_resultStripes(tester).color, isNot(Palette.dark.addRow));
      expect(find.byTooltip('合并对方这处非冲突修改 → 结果'), findsNothing);
      expect(_gutter('合并对方这段 → 结果'), findsOneWidget);
      await tester.tap(find.text('应用'));
      expect(h.saved, isNull);
      await tester.tap(_gutter('合并对方这段 → 结果'));
      await tester.pump();
      await tester.tap(find.text('应用'));
      expect(h.saved, 'one\nTHEIRS two\nthree\nfour\nTHEIRS five\n');
    });

    testWidgets('choosing theirs resolves only the conflict, not the rest',
        (tester) async {
      final h = _Harness();
      await tester.pumpWidget(
          _host(h, '', base: twBase, ours: twOurs, theirs: twTheirs));

      await tester.tap(_gutter('合并对方这段 → 结果'));
      await tester.pump();
      expect(_resultText(tester), 'one\nTHEIRS two\nthree\nfour\nfive\n');
      expect(find.text('1 个更改。1 个冲突。'), findsOneWidget);
      expect(find.text('1 处冲突未处理'), findsNothing);

      await tester.tap(find.text('应用'));
      await tester.pump();
      expect(h.saved, 'one\nTHEIRS two\nthree\nfour\nfive\n');
    });

    testWidgets('add/add has no ancestor strip and still resolves',
        (tester) async {
      final h = _Harness();
      await tester.pumpWidget(
          _host(h, '', base: null, ours: 'ours\n', theirs: 'theirs\n'));

      expect(find.text('收起祖先参考'), findsNothing);
      expect(find.textContaining('共同祖先'), findsNothing);

      await tester.tap(find.text('全部采用对方'));
      await tester.pump();
      await tester.tap(find.text('应用'));
      await tester.pump();
      expect(h.saved, 'theirs\n');
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

    testWidgets('hiding base is presentation only and preserves edits',
        (tester) async {
      final h = _Harness();
      await tester.pumpWidget(_host(h, withBase));

      await tester.enterText(
          find.byType(TextField), 'top\nhand merged\nbottom');
      await tester.tap(find.text('收起祖先参考'));
      await tester.pump();
      expect(find.textContaining('共同祖先：ANCESTOR'), findsNothing);
      await tester.tap(find.text('应用'));
      expect(h.saved, 'top\nhand merged\nbottom');
    });

    testWidgets('is never obtained by rewriting the conflicted file',
        (tester) async {
      await tester.pumpWidget(_host(_Harness(), conflicted));
      expect(find.text('显示共同祖先'), findsNothing);
      expect(find.text('收起祖先参考'), findsNothing);
    });
  });

  group('hand editing', () {
    testWidgets('typing settles a block without touching either side',
        (tester) async {
      final h = _Harness();
      await tester.pumpWidget(_host(h, conflicted));

      expect(find.byType(TextField), findsOneWidget);
      await tester.enterText(
          find.byType(TextField), 'head line\nmerged by hand\ntail line');
      await tester.pump();

      expect(find.text('1 处冲突未处理'), findsNothing);
      await tester.tap(find.text('应用'));
      await tester.pump();
      expect(h.saved, 'head line\nmerged by hand\ntail line');
    });

    testWidgets('a side button replaces what was typed', (tester) async {
      final h = _Harness();
      await tester.pumpWidget(_host(h, conflicted));

      await tester.enterText(
          find.byType(TextField), 'head line\nscratch text\ntail line');
      await tester.pump();
      await tester.tap(find.text('全部采用对方'));
      await tester.pump();

      await tester.tap(find.text('应用'));
      await tester.pump();
      expect(h.saved, isNot(contains('scratch text')));
      expect(h.saved, 'head line\ntheirs one\ntail line');
    });
  });

  testWidgets(
      'one accept settles a conflict and undo restores its pending state',
      (tester) async {
    final h = _Harness();
    await tester.pumpWidget(_host(h, conflicted));
    await tester.tap(_gutter('合并对方这段 → 结果'));
    await tester.pump();
    expect(find.text('1 处冲突未处理'), findsNothing);
    expect(_resultText(tester), 'head line\ntheirs one\ntail line');
    await tester.tap(find.text('撤销'));
    await tester.pump();
    expect(find.text('1 处冲突未处理'), findsOneWidget);
    await tester.tap(find.text('重做'));
    await tester.pump();
    await tester.tap(find.text('应用'));
    expect(h.saved, 'head line\ntheirs one\ntail line');
  });

  testWidgets('continuous edits and side choices share keyboard undo history',
      (tester) async {
    final h = _Harness();
    await tester.pumpWidget(_host(h, conflicted));
    await tester.enterText(
        find.byType(TextField), 'head line\nhand edit\ntail line');
    await tester.tap(_gutter('合并对方这段 → 结果'));
    await tester.pump();
    await tester.tap(find.byType(TextField));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
    await tester.pump();
    expect(_resultText(tester), 'head line\nhand edit\ntail line');
    await tester.tap(find.text('同步滚动：开'));
    await tester.pump();
    await tester.tap(find.text('应用'));
    expect(h.saved, 'head line\nhand edit\ntail line');
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

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
    for (final text in ['ours one', 'ours two', 'theirs one', 'head line']) {
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
    final gesture = await tester.startGesture(
        box.centerLeft + const Offset(1, 0),
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
    await tester.pumpWidget(
        _host(_Harness(), 'a\n<<<<<<< HEAD\n$long\n=======\nb\n>>>>>>> o\nz'));
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

    final field = find.byType(TextField);
    await tester.tap(field);
    await tester.pump();
    final controller = tester.widget<TextField>(field).controller!;
    controller.selection = TextSelection(
        baseOffset: 'head line\n'.length,
        extentOffset: 'head line\nours one\nours two'.length);
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
    expect(find.text('1 / 2'), findsOneWidget);

    await tester.tap(find.byTooltip('下一处差异'));
    await tester.pumpAndSettle();
    expect(find.text('2 / 2'), findsOneWidget);
    // Scrolled far enough that the second block sits inside the window.
    final window = tester.getRect(find.byType(MergeWindow));
    final second = tester.getRect(find.text('second ours'));
    expect(second.top, greaterThan(window.top));
    expect(second.bottom, lessThan(window.bottom));

    // Wraps around at the end, and ↑ goes back.
    await tester.tap(find.byTooltip('下一处差异'));
    await tester.pumpAndSettle();
    expect(find.text('1 / 2'), findsOneWidget);
    await tester.tap(find.byTooltip('上一处差异'));
    await tester.pumpAndSettle();
    expect(find.text('2 / 2'), findsOneWidget);
  });

  for (final pane in [0, 2]) {
    testWidgets('deletion on pane $pane has a boundary and working controls',
        (tester) async {
      const base = 'a\ngone one\ngone two\nb';
      final h = _Harness();
      await tester.pumpWidget(_host(h, '',
          base: base,
          ours: pane == 0 ? 'a\nb' : base,
          theirs: pane == 2 ? 'a\nb' : base));
      await tester.pumpAndSettle();
      dynamic marks() => tester
          .widget<CustomPaint>(
              find.byKey(const ValueKey('merge-result-deletions')))
          .painter! as dynamic;
      final mark = marks().marks.single;
      expect(mark.pane, pane);
      expect(mark.sourceLine, 1);
      expect(mark.first, 1);
      expect(mark.last, 2);
      final boundary = tester
          .widget<CustomPaint>(
              find.byKey(ValueKey('merge-deletion-boundaries-$pane')))
          .foregroundPainter! as dynamic;
      expect(boundary.lines, [1]);
      expect(boundary.color, Palette.dark.deletedFragment);
      final link = find.byKey(ValueKey('merge-connectors-$pane'));
      expect(link, findsOneWidget);
      expect(tester.getSize(link).width, 56);
      final side = pane == 0 ? '我方' : '对方';
      final accept = _gutter('合并$side这处非冲突修改 → 结果');
      expect(tester.getSize(accept).height, greaterThan(0),
          reason: 'a collapsed deletion still has a clickable control');
      await tester.tap(accept);
      await tester.pumpAndSettle();
      expect(_resultText(tester), 'a\nb');
      expect(marks().marks, isEmpty);
      await tester.tap(find.text('应用'));
      expect(h.saved, 'a\nb',
          reason: 'no display padding enters the saved file');
      await tester.tap(find.byTooltip('撤销'));
      await tester.pumpAndSettle();
      expect(_resultText(tester), base);
      expect(marks().marks, hasLength(1));
      await tester.tap(_gutter('忽略$side这处非冲突修改'));
      await tester.pumpAndSettle();
      expect(_resultText(tester), base);
      expect(marks().marks, hasLength(1));
    });
  }

  testWidgets('a conflict deletion preserves real source and editable ancestor',
      (tester) async {
    await tester.pumpWidget(_host(_Harness(), '',
        base: 'a\ngone\nb', ours: 'a\nb', theirs: 'a\npageLimit\nb'));
    await tester.pumpAndSettle();
    final result = tester
        .widget<CustomPaint>(
            find.byKey(const ValueKey('merge-result-deletions')))
        .painter! as dynamic;
    expect(result.marks.single.pane, 0);
    expect(result.marks.single.first, 1);
    expect(_resultText(tester), contains('gone'));
    expect(find.text('pageLimit'), findsOneWidget);
    final source = tester.widget<CustomPaint>(
        find.byKey(const ValueKey('merge-deletion-boundaries-0')));
    expect(
        tester.getSize(find.byKey(const ValueKey('merge-source-0-0'))).height,
        0);
    expect((source.foregroundPainter! as dynamic).lines, [1]);
    await tester.tap(_gutter('合并我方这段 → 结果'));
    await tester.pumpAndSettle();
    expect(_resultText(tester), 'a\nb');
  });
}
