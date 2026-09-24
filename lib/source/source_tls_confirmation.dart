import 'package:flutter/material.dart';

import '../domain/contracts.dart';
import '../l10n/app_localizations.dart';
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

/// The visible page's certificate decision (ADR 0011 §5).
///
/// The page the user confirmed (the hatch's own surface) reaches the same
/// confirmation the `dart:io` path shows, because it is the same question about
/// the same source and host: a stored exception proceeds without asking, and
/// without one the confirmation asks once and a "continue (unsafe)" answer
/// stores the exception through [SourceHostState.allowInvalidCertificate].
///
/// [failure] is the failure the page load met, built where the engine's
/// challenge named the host. [sourceRef] is the source's `bookSourceUrl`, used
/// when the failure carries no identity, as the operation wrapper does.
///
/// A refusal — the dialog's default — answers false, stores nothing and lets the
/// caller cancel the challenge, so the page fails the way it does without the
/// exception. The answer is whether the challenge may proceed.
///
/// A null [hostState] answers false without asking, because a decision with no
/// store is not ADR 0011 §5's: there is no exception to read, and the answer the
/// user gave could not be remembered for the next request to the same source and
/// host. Every application path carries a state, so that only reaches a process
/// that speaks for no space at all ([SourceHatchRequest.hostState]).
Future<bool> confirmTlsExceptionForPage({
  required BuildContext context,
  required SourceHostState? hostState,
  required String sourceRef,
  required String sourceName,
  required SourceTlsCertificateFailure failure,
}) async {
  final state = hostState;
  if (state == null) return false;
  final ref = failure.sourceRef.isEmpty ? sourceRef : failure.sourceRef;
  await state.ready();
  if (state.allowsInvalidCertificate(ref, failure.host)) return true;
  // A page whose surface is gone has no confirmation to ask, and asking is the
  // whole decision: the challenge is refused, exactly as an unanswerable one is.
  if (!context.mounted) return false;
  final confirmed = await showTlsExceptionConfirmation(
    context,
    sourceName: sourceName,
    failure: failure,
  );
  if (!confirmed) return false;
  await state.allowInvalidCertificate(ref, failure.host);
  return true;
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
  final l10n = AppLocalizations.of(context);
  final name = sourceName.isEmpty ? failure.sourceRef : sourceName;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(l10n.certificateFailedTitle),
      content: Text(
        l10n.certificateFailedBody(name, failure.host, failure.reason),
      ),
      actions: [
        TextButton(
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.cancel),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.unsafeContinue),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
