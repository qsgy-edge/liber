import 'package:flutter/material.dart';

import '../domain/contracts.dart';
import 'source_host_state.dart';

/// Runs one source operation under ADR 0011 §5's per-source TLS exception.
///
/// The first certificate failure asks the user once; only a confirmed "continue
/// (unsafe)" remembers the exception and re-runs [run], so the retry's requests
/// to that host validate no further. A refusal — the dialog's default — leaves
/// validation as it was and rethrows the failure, and the caller reports it as
/// it found it.
///
/// [sourceRef] is the source's `bookSourceUrl`; [sourceName] is the name shown
/// in the confirmation.
Future<T> withTlsExceptionConfirmation<T>({
  required BuildContext context,
  required SourceHostState hostState,
  required String sourceRef,
  required String sourceName,
  required Future<T> Function() run,
}) async {
  try {
    return await run();
  } on SourceTlsCertificateFailure catch (failure) {
    if (!context.mounted) rethrow;
    final confirmed = await showTlsExceptionConfirmation(
      context,
      sourceName: sourceName,
      failure: failure,
    );
    if (!confirmed) rethrow;
    await hostState.allowInvalidCertificate(
      failure.sourceRef.isEmpty ? sourceRef : failure.sourceRef,
      failure.host,
    );
    return run();
  }
}

/// The confirmation itself: it names the source and the host, states the
/// certificate problem in plain words, and defaults to refusing. The barrier is
/// dismissible and 取消 carries the focus, so Escape, Enter and a tap outside
/// all mean "do not continue"; only 继续（不安全） remembers the exception.
Future<bool> showTlsExceptionConfirmation(
  BuildContext context, {
  required String sourceName,
  required SourceTlsCertificateFailure failure,
}) async {
  final name = sourceName.isEmpty ? failure.sourceRef : sourceName;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('证书校验失败'),
      content: Text(
        '书源“$name”访问 ${failure.host} 时，TLS 证书校验失败：${failure.reason}。\n\n'
        '继续访问可能让你的连接被窃听或篡改。是否仅为此书源记住此次例外？',
      ),
      actions: [
        TextButton(
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('继续（不安全）'),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
