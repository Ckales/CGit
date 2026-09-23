import 'package:flutter/widgets.dart';

/// The palette from src/styles.css, transcribed. CSS custom properties cascade
/// and re-theme the whole tree on one attribute flip; here the values are
/// plain constants and the swap is an InheritedWidget rebuild.
class Palette {
  const Palette({
    required this.bg,
    required this.bgAlt,
    required this.bgElev,
    required this.border,
    required this.text,
    required this.textDim,
    required this.accent,
    required this.bgHover,
    required this.green,
    required this.red,
    required this.yellow,
    required this.diffBg,
    required this.bgSel,
  });

  final Color bg, bgAlt, bgElev, border, text, textDim, accent, bgHover;
  final Color green, red, yellow, diffBg, bgSel;

  static const dark = Palette(
    bg: Color(0xFF1E1F22),
    bgAlt: Color(0xFF2B2D30),
    bgElev: Color(0xFF313438),
    border: Color(0xFF393B40),
    text: Color(0xFFDFE1E5),
    textDim: Color(0xFF8D9199),
    accent: Color(0xFF3574F0),
    bgHover: Color(0xFF3C3F43),
    green: Color(0xFF57965C),
    red: Color(0xFFCD5B5B),
    yellow: Color(0xFFC9A76C),
    diffBg: Color(0xFF1B1C1E),
    bgSel: Color(0xFF2E436E),
  );

  static const light = Palette(
    bg: Color(0xFFFFFFFF),
    bgAlt: Color(0xFFF2F3F5),
    bgElev: Color(0xFFE6E8EB),
    border: Color(0xFFD3D5D9),
    text: Color(0xFF1F2328),
    textDim: Color(0xFF6B7078),
    accent: Color(0xFF2F6BDC),
    bgHover: Color(0xFFDCDEE2),
    green: Color(0xFF2C7A34),
    red: Color(0xFFB3261E),
    yellow: Color(0xFF8A6116),
    diffBg: Color(0xFFFAFBFC),
    bgSel: Color(0xFFD3E2FF),
  );

  // Row tints. In CSS these are rgba() over the pane background; Flutter has
  // Color.withValues for the same thing, so the numbers carry over 1:1.
  Color get delRow => red.withValues(alpha: 0.12);
  Color get addRow => green.withValues(alpha: 0.14);
  Color get intraDel => red.withValues(alpha: 0.42);
  Color get intraAdd => green.withValues(alpha: 0.45);
  Color get emptyCell => textDim.withValues(alpha: 0.09);
}

class Theming extends InheritedWidget {
  const Theming({super.key, required this.palette, required super.child});
  final Palette palette;

  static Palette of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<Theming>()!.palette;

  @override
  bool updateShouldNotify(Theming old) => old.palette != palette;
}

/// The one monospace style the diff is built from. `height: 1.4` matches the
/// line-height the CSS diff pane uses.
const mono = TextStyle(
  fontFamily: 'Menlo',
  fontFamilyFallback: ['SF Mono', 'monospace'],
  fontSize: 12,
  height: 1.4,
);

const ui = TextStyle(
  fontFamily: '.SF NS',
  fontFamilyFallback: ['Helvetica Neue'],
  fontSize: 13,
  height: 1.3,
);

/// The ⌄ used by every dropdown and menu button in this app.
///
/// Painted as the same stroke the Tauri app's select uses (a 10×6 viewBox,
/// `M1 1.25 5 4.75 9 1.25`, 1.4 wide). Not `Icons.arrow_drop_down`:
/// `pubspec.yaml` keeps `uses-material-design: false`, so that renders as a
/// missing-glyph box. Not the text '▾' either: it is tiny in the system font.
class Chevron extends StatelessWidget {
  const Chevron({super.key, required this.color, this.size = 10});

  final Color color;

  /// Width; height is 0.6 of it, as in the SVG.
  final double size;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size(size, size * 0.6),
        painter: _ChevronPainter(color),
      );
}

class _ChevronPainter extends CustomPainter {
  _ChevronPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 10;
    final path = Path()
      ..moveTo(1 * k, 1.25 * k)
      ..lineTo(5 * k, 4.75 * k)
      ..lineTo(9 * k, 1.25 * k);
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4 * k
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_ChevronPainter old) => old.color != color;
}
