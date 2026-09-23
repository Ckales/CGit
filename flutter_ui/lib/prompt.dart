import 'package:flutter/material.dart';

import 'dialogs.dart';

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
