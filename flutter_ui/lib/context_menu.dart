import 'package:flutter/material.dart';

import 'theme.dart';

/// One row of a context menu.
class MenuAction {
  const MenuAction(this.label, this.onTap, {this.danger = false, this.enabled = true});

  final String label;
  final VoidCallback onTap;

  /// Destructive actions (drop a stash, delete a branch) are tinted so they are
  /// not one careless click away from the harmless ones above them.
  final bool danger;

  final bool enabled;
}

/// Show a context menu at a global position.
///
/// The DOM version hand-writes the placement, the screen-edge clamping and the
/// dismiss-on-outside-click; Flutter's own `showMenu` already does all three,
/// so this is only the styling and the MenuAction plumbing.
///
/// ponytail: flat menus only. The Tauri UI nests submenus in a dozen places,
/// and Flutter has no equivalent of the "keep the submenu open while the mouse
/// crosses to it" timer that makes those usable — worth building when the first
/// feature actually needs one, not before.
Future<void> showRepoMenu({
  required BuildContext context,
  required Offset position,
  required List<MenuAction> items,
}) async {
  final p = Theming.of(context);
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;

  final picked = await showMenu<MenuAction>(
    context: context,
    color: p.bgElev,
    surfaceTintColor: Colors.transparent,
    shape: RoundedRectangleBorder(
      side: BorderSide(color: p.border),
      borderRadius: BorderRadius.circular(6),
    ),
    position: RelativeRect.fromRect(
      Rect.fromLTWH(position.dx, position.dy, 0, 0),
      Offset.zero & overlay.size,
    ),
    items: [
      for (final item in items)
        PopupMenuItem<MenuAction>(
          value: item,
          enabled: item.enabled,
          height: 30,
          child: Text(
            item.label,
            style: ui.copyWith(
              color: !item.enabled
                  ? p.textDim
                  : item.danger
                      ? p.red
                      : p.text,
            ),
          ),
        ),
    ],
  );

  picked?.onTap();
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
