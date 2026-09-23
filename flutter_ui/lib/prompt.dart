import 'package:flutter/material.dart';

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

  final p = Theming.of(context);

  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: p.bgElev,
      title: Text(title, style: ui.copyWith(color: p.text, fontSize: 15)),
      content: SizedBox(
        width: 420,
        child: TextField(
          controller: controller,
          autofocus: true,
          style: ui.copyWith(color: p.text),
          cursorColor: p.accent,
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: ui.copyWith(color: p.textDim),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: p.border),
            ),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: p.accent),
            ),
          ),
          // Enter submits: this dialog only ever holds one field.
          onSubmitted: (v) => Navigator.of(context).pop(v),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('取消', style: ui.copyWith(color: p.textDim)),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(controller.text),
          child: Text(confirmLabel, style: ui.copyWith(color: p.accent)),
        ),
      ],
    ),
  );
}
