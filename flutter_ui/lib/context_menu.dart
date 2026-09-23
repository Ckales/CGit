import 'package:flutter/material.dart';

import 'theme.dart';

/// One row of a context menu.
class MenuAction {
  const MenuAction(this.label, this.onTap,
      {this.danger = false,
      this.enabled = true,
      this.checked = false,
      this.current = false,
      this.sublabel = ''})
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
  /// clickable. Same as the Tauri `.context-item.current`.
  final bool current;

  /// A second, dimmer line under the label — the path under a project name.
  final String sublabel;

  final bool header;

  static void _noop() {}
}

/// Where a dropdown opens: under the left edge of the widget that owns
/// [context], not wherever the pointer happened to land on it — a menu that
/// shifts with the click point looks like it is chasing the mouse. [right]
/// anchors under the right edge instead, for [showRepoMenu]'s `alignRight`.
Offset menuAnchorBelow(BuildContext context, {bool right = false}) {
  final box = context.findRenderObject() as RenderBox;
  return box.localToGlobal(
      Offset(right ? box.size.width : 0, box.size.height + 4));
}

/// Show a context menu at a global position.
///
/// The DOM version hand-writes the placement, the screen-edge clamping and the
/// dismiss-on-outside-click; Flutter's own `showMenu` already does all three.
/// The rows are our own entries rather than `PopupMenuItem`, whose Material
/// ink hover can't be restyled into the Tauri accent highlight.
///
/// ponytail: flat menus only. The Tauri UI nests submenus in a dozen places,
/// and Flutter has no equivalent of the "keep the submenu open while the mouse
/// crosses to it" timer that makes those usable — worth building when the first
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
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  // The tick column is only reserved in menus that tick something, or every
  // plain menu would carry a blank gutter.
  final hasChecks = items.any((i) => i.checked);

  final picked = await showMenu<MenuAction>(
    context: context,
    color: p.bgElev,
    surfaceTintColor: Colors.transparent,
    elevation: 6,
    menuPadding: const EdgeInsets.all(4),
    constraints: const BoxConstraints(minWidth: 140, maxWidth: 420),
    shape: RoundedRectangleBorder(
      side: BorderSide(color: p.border),
      borderRadius: BorderRadius.circular(6),
    ),
    // alignRight: left > right makes showMenu grow leftwards with its right
    // edge on position.dx — the split button's chevron, whose menu belongs
    // under the button, not hanging off past it.
    position: alignRight
        ? RelativeRect.fromLTRB(overlay.size.width, position.dy,
            overlay.size.width - position.dx, overlay.size.height - position.dy)
        : RelativeRect.fromRect(
            Rect.fromLTWH(position.dx, position.dy, 0, 0),
            Offset.zero & overlay.size,
          ),
    items: [
      for (var i = 0; i < items.length; i++)
        items[i].header
            ? _MenuHeader(items[i].label, palette: p, first: i == 0)
            : _MenuRow(items[i], palette: p, hasChecks: hasChecks),
    ],
  );

  picked?.onTap();
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
  const _MenuRow(this.item, {required this.palette, required this.hasChecks});

  final MenuAction item;
  final Palette palette;
  final bool hasChecks;

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
