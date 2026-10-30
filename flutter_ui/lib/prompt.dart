import 'package:flutter/material.dart';

import 'context_menu.dart';
import 'dialogs.dart';
import 'theme.dart';

/// Ask for one line of text. Returns null when the user backs out — which is
/// never the same as an empty string, because "" is a valid thing to type and
/// has to be rejected on its own terms by the caller.
Future<String?> promptText(
  BuildContext context, {
  required String title,
  String? hint,
  String initial = '',
  String confirmLabel = '确定',
}) {
  final controller = TextEditingController(text: initial);
  // Naming a branch after an existing one is the usual reason to prefill, so
  // start with it selected: typing replaces it, and an arrow key keeps it.
  controller.selection = TextSelection(
    baseOffset: 0,
    extentOffset: initial.length,
  );

  return showAppDialog<String>(
    context,
    title: title,
    minWidth: 380,
    maxWidth: 380,
    body: DialogField(
      controller: controller,
      hint: hint,
      // Enter submits: this dialog only ever holds one field.
      onSubmitted: (v) => Navigator.of(context).pop(v),
    ),
    actions: [
      DialogButton('取消', onTap: () => Navigator.of(context).pop()),
      DialogButton(
        confirmLabel,
        kind: DialogButtonKind.primary,
        onTap: () => Navigator.of(context).pop(controller.text),
      ),
    ],
  );
}

/// Which button of the tag dialog submitted it.
enum TagSubmit { create, createAndPush }

/// Ask for a tag name. Enter and 创建 tag locally; the chevron beside them also
/// offers 创建并推送, so publishing a fresh tag does not need a second trip
/// through the sidebar's context menu.
Future<({String name, TagSubmit submit})?> promptTagName(
  BuildContext context, {
  required String title,
}) {
  final controller = TextEditingController();
  ({String name, TagSubmit submit}) typed(TagSubmit submit) =>
      (name: controller.text, submit: submit);

  return showAppDialog<({String name, TagSubmit submit})>(
    context,
    title: title,
    minWidth: 380,
    maxWidth: 380,
    body: DialogField(
      controller: controller,
      hint: '标签名',
      // Enter keeps doing the plain create; pushing is an explicit choice.
      onSubmitted: (v) =>
          Navigator.of(context).pop((name: v, submit: TagSubmit.create)),
    ),
    actions: [
      DialogButton('取消', onTap: () => Navigator.of(context).pop()),
      _SubmitSplitButton(
        onTap: () => Navigator.of(context).pop(typed(TagSubmit.create)),
        onMenuAt: (position, width) => showRepoMenu(
          context: context,
          position: position,
          alignRight: true,
          // At least as wide as the split button, so the popup lines up with
          // 创建 instead of hanging off its right edge.
          minWidth: width,
          items: [
            MenuAction(
              '创建并推送',
              () => Navigator.of(context).pop(typed(TagSubmit.createAndPush)),
            ),
          ],
        ),
      ),
    ],
  );
}

/// The dialog's primary action plus a chevron for its variants — the same
/// split shape the commit box uses for 提交 / 提交并推送.
class _SubmitSplitButton extends StatefulWidget {
  const _SubmitSplitButton({required this.onTap, required this.onMenuAt});

  final VoidCallback onTap;

  /// The anchor position plus the split button's width, which the menu uses
  /// as its minimum width so the two line up.
  final void Function(Offset position, double width) onMenuAt;

  @override
  State<_SubmitSplitButton> createState() => _SubmitSplitButtonState();
}

class _SubmitSplitButtonState extends State<_SubmitSplitButton> {
  final _rowKey = GlobalKey();

  void _openMenu() {
    final context = _rowKey.currentContext;
    if (context == null) return;
    final box = context.findRenderObject() as RenderBox;
    widget.onMenuAt(
      menuAnchorBelow(context, right: true),
      box.size.width,
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = Theming.of(context);
    const radius = Radius.circular(6);
    return Row(
      key: _rowKey,
      mainAxisSize: MainAxisSize.min,
      children: [
        _Segment(
          onTap: widget.onTap,
          tooltip: '创建标签',
          minWidth: 72,
          hPadding: 16,
          border: Border.all(color: p.accent),
          borderRadius: const BorderRadius.horizontal(left: radius),
          child: Text('创建',
              style: ui.copyWith(
                  color: Colors.white, fontSize: 12.5, height: 1)),
        ),
        // A translucent divider is what makes two accents read as a split
        // button rather than one wide one.
        _Segment(
          onTapAt: _openMenu,
          tooltip: '更多创建方式',
          hPadding: 9,
          border: const Border(left: BorderSide(color: Color(0x40FFFFFF))),
          borderRadius: const BorderRadius.horizontal(right: radius),
          child: const Chevron(color: Colors.white),
        ),
      ],
    );
  }
}

class _Segment extends StatefulWidget {
  const _Segment({
    required this.tooltip,
    required this.hPadding,
    required this.border,
    required this.borderRadius,
    required this.child,
    this.onTap,
    this.onTapAt,
    this.minWidth,
  });

  final String tooltip;
  final double hPadding;
  final double? minWidth;
  final Border border;
  final BorderRadius borderRadius;
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onTapAt;

  @override
  State<_Segment> createState() => _SegmentState();
}

class _SegmentState extends State<_Segment> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = Theming.of(context);
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          onTapUp: widget.onTapAt == null ? null : (_) => widget.onTapAt!(),
          child: Container(
            height: 28,
            constraints: widget.minWidth == null
                ? null
                : BoxConstraints(minWidth: widget.minWidth!),
            padding: EdgeInsets.symmetric(horizontal: widget.hPadding),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _hover
                  ? Color.lerp(p.accent, Colors.white, 0.12)
                  : p.accent,
              border: widget.border,
              borderRadius: widget.borderRadius,
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
