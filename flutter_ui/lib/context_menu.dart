import 'dart:async';
import 'dart:math' show max;
import 'dart:ui' show ViewFocusEvent, ViewFocusState;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

/// Clicks in the native title bar never reach the Flutter barrier, and the
/// window stays key, so focus-loss doesn't fire either. The macOS runner sends
/// these here.
const windowChromeChannel = MethodChannel('cgit/window');
final windowChromeClicks = StreamController<void>.broadcast();

void bindWindowChrome() {
  windowChromeChannel.setMethodCallHandler((call) async {
    if (call.method == 'chromeClick') windowChromeClicks.add(null);
  });
}

/// One row of a context menu.
class MenuAction {
  const MenuAction(this.label, this.onTap,
      {this.danger = false,
      this.enabled = true,
      this.checked = false,
      this.current = false,
      this.sublabel = '',
      this.onRemove})
      : header = false;

  /// A non-clickable group title ("最近的项目"). Every header after the first
  /// draws a divider above itself, so no separate divider entry is needed.
  const MenuAction.header(this.label)
      : onTap = _noop,
        danger = false,
        enabled = false,
        checked = false,
        current = false,
        sublabel = '',
        onRemove = null,
        header = true;

  final String label;
  final VoidCallback onTap;

  /// Destructive actions (drop a stash, delete a branch) are tinted so they are
  /// not one careless click away from the harmless ones above them.
  final bool danger;

  final bool enabled;

  /// Marks the value a picker is currently set to. Menus that stand in for a
  /// dropdown need it — without the tick, opening one tells you your options
  /// but not which one you already have.
  final bool checked;

  /// The thing already open (the current project): tinted accent, still
  /// clickable.
  final bool current;

  /// A second, dimmer line under the label — the path under a project name.
  final String sublabel;

  /// 悬停时显示移除按钮，保存成功后从当前菜单移除这一项。
  final Future<void> Function()? onRemove;

  final bool header;

  static void _noop() {}
}

/// Where a dropdown opens: centred under the widget that owns [context], not
/// wherever the pointer happened to land on it — a menu that shifts with the
/// click point looks like it is chasing the mouse. [right] anchors under the
/// right edge instead, for [showRepoMenu]'s `alignRight`.
Offset menuAnchorBelow(BuildContext context, {bool right = false}) {
  final box = context.findRenderObject() as RenderBox;
  return box.localToGlobal(
      Offset(right ? box.size.width : box.size.width / 2, box.size.height + 4));
}

/// Show a context menu at a global position: centred right below it, or
/// right above it when the window has no room below.
///
/// Our own route rather than `showMenu`, which can only left- or right-align
/// on the point — it picked the side by which half of the window was clicked,
/// so the menu hung off the pointer's left or right. Centring needs the
/// menu's width, and only a layout delegate gets that before placing it. The
/// rows are our own entries rather than `PopupMenuItem`, whose Material ink
/// hover can't be restyled into the accent highlight.
///
/// ponytail: flat menus only. Flutter has no equivalent of the "keep the
/// submenu open while the mouse crosses to it" timer that makes submenus
/// usable — worth building when the first
/// feature actually needs one, not before.
Future<void> showRepoMenu({
  required BuildContext context,
  required Offset position,
  required List<MenuAction> items,
  bool alignRight = false,
}) async {
  final p = Theming.of(context);
  // Passed down by hand: the menu is a new route, and Theming isn't an
  // InheritedTheme, so it doesn't follow the menu there.
  final navigator = Navigator.of(context);
  final overlay = navigator.overlay!.context.findRenderObject() as RenderBox;
  final remaining = [...items];

  final picked = await navigator.push(_MenuRoute(
    anchor: overlay.globalToLocal(position),
    alignRight: alignRight,
    palette: p,
    child: StatefulBuilder(builder: (context, setState) {
      // Only menus with a checked entry need the tick column.
      final hasChecks = remaining.any((item) => item.checked);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, item) in remaining.indexed)
            // 移除分组的最后一项时，一并隐藏空标题。
            if (!item.header ||
                (i + 1 < remaining.length && !remaining[i + 1].header))
              item.header
                  ? _MenuHeader(item.label, palette: p, first: i == 0)
                  : _MenuRow(
                      item,
                      palette: p,
                      hasChecks: hasChecks,
                      onRemove: item.onRemove == null
                          ? null
                          : () async {
                              await item.onRemove!();
                              if (!context.mounted) return;
                              setState(() => remaining.remove(item));
                            },
                    ),
        ],
      );
    }),
  ));

  picked?.onTap();
}

class _MenuRoute extends PopupRoute<MenuAction> {
  _MenuRoute({
    required this.anchor,
    required this.alignRight,
    required this.palette,
    required this.child,
  });

  final Offset anchor;
  final bool alignRight;
  final Palette palette;
  final Widget child;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => '关闭菜单';

  @override
  Duration get transitionDuration => const Duration(milliseconds: 100);

  @override
  Widget buildPage(BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation) {
    final p = palette;
    return _CloseWhenUnfocused(
      child: CustomSingleChildLayout(
        delegate: _MenuLayout(anchor, alignRight),
        child: FadeTransition(
          opacity: animation,
          child: Material(
            color: p.bgElev,
            surfaceTintColor: Colors.transparent,
            elevation: 6,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              side: BorderSide(color: p.border),
              borderRadius: BorderRadius.circular(6),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 140, maxWidth: 420),
              child: IntrinsicWidth(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(4),
                  child: child,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The barrier only hears taps inside the Flutter view. The native title bar
/// and switching to another app never tap it, so those close the menu too.
class _CloseWhenUnfocused extends StatefulWidget {
  const _CloseWhenUnfocused({required this.child});

  final Widget child;

  @override
  State<_CloseWhenUnfocused> createState() => _CloseWhenUnfocusedState();
}

class _CloseWhenUnfocusedState extends State<_CloseWhenUnfocused>
    with WidgetsBindingObserver {
  late final StreamSubscription<void> _chrome;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _chrome = windowChromeClicks.stream.listen((_) => _close());
  }

  @override
  void dispose() {
    _chrome.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _close() {
    if (!mounted) return;
    final route = ModalRoute.of(context);
    if (route == null || !route.isCurrent) return;
    Navigator.of(context).pop();
  }

  @override
  void didChangeViewFocus(ViewFocusEvent event) {
    if (event.state != ViewFocusState.unfocused) return;
    final view = View.maybeOf(context);
    if (view != null && event.viewId != view.viewId) return;
    _close();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      _close();
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Centred on the anchor horizontally (right edge on it for alignRight); below
/// it when the menu fits, else above it. Either way kept 8px inside the
/// window, which slides a menu opened near an edge back in.
class _MenuLayout extends SingleChildLayoutDelegate {
  _MenuLayout(this.anchor, this.alignRight);

  final Offset anchor;
  final bool alignRight;

  static const _margin = 8.0;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.loose(constraints.biggest)
          .deflate(const EdgeInsets.all(_margin));

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final x = alignRight
        ? anchor.dx - childSize.width
        : anchor.dx - childSize.width / 2;
    final fitsBelow = anchor.dy + childSize.height <= size.height - _margin;
    final y = fitsBelow ? anchor.dy : anchor.dy - childSize.height;
    return Offset(
      x.clamp(_margin, max(_margin, size.width - childSize.width - _margin)),
      y.clamp(_margin, max(_margin, size.height - childSize.height - _margin)),
    );
  }

  @override
  bool shouldRelayout(_MenuLayout old) =>
      old.anchor != anchor || old.alignRight != alignRight;
}

class _MenuHeader extends PopupMenuEntry<MenuAction> {
  const _MenuHeader(this.label, {required this.palette, required this.first});

  final String label;
  final Palette palette;
  final bool first;

  @override
  double get height => first ? 22 : 27;

  @override
  bool represents(MenuAction? value) => false;

  @override
  State<_MenuHeader> createState() => _MenuHeaderState();
}

class _MenuHeaderState extends State<_MenuHeader> {
  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return Container(
      margin: EdgeInsets.only(top: widget.first ? 0 : 4),
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 3),
      decoration: widget.first
          ? null
          : BoxDecoration(border: Border(top: BorderSide(color: p.border))),
      child: Text(
        widget.label,
        style: ui.copyWith(
          color: p.textDim,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

class _MenuRow extends PopupMenuEntry<MenuAction> {
  const _MenuRow(this.item,
      {required this.palette, required this.hasChecks, this.onRemove});

  final MenuAction item;
  final Palette palette;
  final bool hasChecks;
  final Future<void> Function()? onRemove;

  @override
  double get height => item.sublabel.isEmpty ? 26 : 40;

  @override
  bool represents(MenuAction? value) => value == item;

  @override
  State<_MenuRow> createState() => _MenuRowState();
}

class _MenuRowState extends State<_MenuRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final item = widget.item;
    final hot = _hover && item.enabled;
    final Color fg;
    if (hot) {
      fg = Colors.white;
    } else if (!item.enabled) {
      fg = p.textDim;
    } else if (item.danger) {
      fg = p.red;
    } else if (item.current) {
      fg = p.accent;
    } else {
      fg = p.text;
    }

    return MouseRegion(
      cursor:
          item.enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: item.enabled ? () => Navigator.pop(context, item) : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: hot ? (item.danger ? p.red : p.accent) : null,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            children: [
              if (widget.hasChecks)
                SizedBox(
                  width: 16,
                  child: item.checked
                      ? Text('\u2713',
                          style: ui.copyWith(
                              color: hot ? Colors.white : p.accent,
                              fontSize: 12))
                      : null,
                ),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(item.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ui.copyWith(color: fg)),
                    if (item.sublabel.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 1),
                        child: Text(
                          item.sublabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ui.copyWith(
                            color: hot ? Colors.white70 : p.textDim,
                            fontSize: 11,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (widget.onRemove != null)
                SizedBox(
                  width: 24,
                  height: 24,
                  child: hot
                      ? IconButton(
                          tooltip: '从最近项目中移除',
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          icon: const Icon(Icons.close, size: 14),
                          color: Colors.white,
                          onPressed: widget.onRemove,
                        )
                      : null,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Wraps a row so a right-click (or a two-finger tap) opens [items].
class ContextMenuRegion extends StatelessWidget {
  const ContextMenuRegion({
    super.key,
    required this.items,
    required this.child,
  });

  /// Built on demand: a menu's entries depend on state that may have changed
  /// since the row was laid out.
  final List<MenuAction> Function() items;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTapUp: (d) => showRepoMenu(
        context: context,
        position: d.globalPosition,
        items: items(),
      ),
      child: child,
    );
  }
}
