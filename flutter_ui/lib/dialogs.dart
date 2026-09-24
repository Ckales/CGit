import 'package:flutter/material.dart';

import 'theme.dart';

/// The round badge beside a dialog title.
enum DialogBadge { info, danger }

enum DialogButtonKind { normal, primary, danger }

/// The window every dialog in this app sits in: bgAlt,
/// hairline border, 12px corners, a soft drop shadow — rather than Material's
/// grey slab. [badge] adds the round icon and indents [body] under the title.
Future<T?> showAppDialog<T>(
  BuildContext context, {
  required String title,
  required Widget body,
  required List<Widget> actions,
  DialogBadge? badge,
  double minWidth = 320,
  double maxWidth = 520,
}) {
  final p = Theming.of(context);
  return showDialog<T>(
    context: context,
    barrierColor: const Color(0x66000000),
    // A dialog is its own route, above the Theming that wraps RepoScreen, so
    // the palette is handed across for the badge, buttons and field.
    builder: (context) => Theming(
      palette: p,
      child: Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.all(40),
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: minWidth, maxWidth: maxWidth),
          child: IntrinsicWidth(
            child: Container(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
              decoration: BoxDecoration(
                color: p.bgAlt,
                border: Border.all(color: p.border),
                borderRadius: BorderRadius.circular(12),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x40000000),
                    blurRadius: 32,
                    offset: Offset(0, 10),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      if (badge != null) ...[
                        _Badge(badge: badge),
                        const SizedBox(width: 10),
                      ],
                      Flexible(
                        child: Text(
                          title,
                          style: ui.copyWith(
                            color: p.text,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Padding(
                    padding: EdgeInsets.only(left: badge == null ? 0 : 36),
                    child: body,
                  ),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      for (final (i, action) in actions.indexed) ...[
                        if (i > 0) const SizedBox(width: 8),
                        action,
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Dim message text for [showAppDialog] bodies.
class DialogText extends StatelessWidget {
  const DialogText(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final p = Theming.of(context);
    return Text(
      text,
      style: ui.copyWith(color: p.textDim, fontSize: 13, height: 1.55),
    );
  }
}

/// A one-line notice that stays until dismissed.
Future<void> showNotice(BuildContext context, String message) =>
    showAppDialog<void>(
      context,
      title: '提示',
      badge: DialogBadge.info,
      body: DialogText(message),
      actions: [
        DialogButton(
          '确定',
          kind: DialogButtonKind.primary,
          autofocus: true,
          onTap: () => Navigator.of(context).pop(),
        ),
      ],
    );

class _Badge extends StatelessWidget {
  const _Badge({required this.badge});
  final DialogBadge badge;

  @override
  Widget build(BuildContext context) {
    final p = Theming.of(context);
    final danger = badge == DialogBadge.danger;
    return Container(
      width: 26,
      height: 26,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: danger ? p.red : p.accent,
        shape: BoxShape.circle,
      ),
      child: Text(
        danger ? '!' : 'i',
        style: TextStyle(
          fontFamily: danger ? ui.fontFamily : 'Georgia',
          fontSize: 15,
          fontWeight: FontWeight.w700,
          color: Colors.white,
          height: 1,
        ),
      ),
    );
  }
}

/// A normal or primary dialog button, plus a red one for actions that
/// throw work away. [autofocus] makes Enter press it.
class DialogButton extends StatefulWidget {
  const DialogButton(
    this.label, {
    super.key,
    required this.onTap,
    this.kind = DialogButtonKind.normal,
    this.autofocus = false,
  });

  final String label;
  final VoidCallback onTap;
  final DialogButtonKind kind;
  final bool autofocus;

  @override
  State<DialogButton> createState() => _DialogButtonState();
}

class _DialogButtonState extends State<DialogButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = Theming.of(context);
    final (Color fill, Color border, Color text) = switch (widget.kind) {
      DialogButtonKind.normal => (
          _hover ? p.bgHover : p.bgElev,
          p.border,
          p.text,
        ),
      DialogButtonKind.primary => (
          _hover ? Color.lerp(p.accent, Colors.white, 0.12)! : p.accent,
          p.accent,
          Colors.white,
        ),
      DialogButtonKind.danger => (
          _hover ? Color.lerp(p.red, Colors.white, 0.12)! : p.red,
          p.red,
          Colors.white,
        ),
    };
    return FocusableActionDetector(
      autofocus: widget.autofocus,
      mouseCursor: SystemMouseCursors.click,
      onShowHoverHighlight: (v) => setState(() => _hover = v),
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap();
            return null;
          },
        ),
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          constraints: const BoxConstraints(minWidth: 72),
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: fill,
            border: Border.all(color: border),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            widget.label,
            style: ui.copyWith(color: text, fontSize: 12.5, height: 1),
          ),
        ),
      ),
    );
  }
}

/// A dialog text field: a sunken box whose border turns accent on focus.
class DialogField extends StatelessWidget {
  const DialogField({
    super.key,
    required this.controller,
    this.hint,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String? hint;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    final p = Theming.of(context);
    OutlineInputBorder edge(Color c) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: c),
        );
    return TextField(
      controller: controller,
      autofocus: true,
      style: ui.copyWith(color: p.text, fontSize: 13),
      cursorColor: p.accent,
      cursorWidth: 1.5,
      decoration: InputDecoration(
        isDense: true,
        filled: true,
        fillColor: p.bg,
        hintText: hint,
        hintStyle: ui.copyWith(color: p.textDim, fontSize: 13),
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        enabledBorder: edge(p.border),
        focusedBorder: edge(p.accent),
      ),
      onSubmitted: onSubmitted,
    );
  }
}
