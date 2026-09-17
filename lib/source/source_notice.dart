import 'package:flutter/material.dart';

import 'js_source_runtime.dart';

/// The display cap on a source's untrusted `toast`/`longToast` text. The message
/// is recorded in full in the source log; only the notice shown to the user is
/// flattened and truncated.
const maxSourceNoticeChars = 300;

/// Shows one source notice (a `toast`/`longToast` [SourceHostMessage]) as a
/// plain, single-line SnackBar. The runtime has already rate-limited the
/// delivery ([sourceNoticeWindowMillis], ADR 0011 §6); the text is untrusted, so
/// it is collapsed to one line and capped, with no action buttons.
void showSourceNotice(BuildContext context, SourceHostMessage message) {
  final text = message.message.replaceAll(RegExp(r'\s+'), ' ').trim();
  final shown = text.length > maxSourceNoticeChars
      ? '${text.substring(0, maxSourceNoticeChars)}…'
      : text;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(shown)));
}
