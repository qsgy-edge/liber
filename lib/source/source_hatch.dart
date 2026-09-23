import 'dart:async';
import 'dart:typed_data';

import '../domain/contracts.dart';

/// Which surface one user-confirmed hatch shows (ADR 0011 §4).
///
/// The four members this covers ask first and, for the waiting kinds, park the
/// source's execution until the user answers. A kind is what the surface needs
/// to know; [SourceHatchRequest.member] is what the source log and a failure
/// name.
enum SourceHatchKind {
  /// `java.startBrowser`: the confirmed page is shown and the script continues
  /// (the frozen member returns nothing and does not wait).
  page,

  /// `java.startBrowserAwait`: the confirmed page is shown and the script waits
  /// for the page's answer.
  waitingPage,

  /// `java.getVerificationCode`: the confirmed image is shown and the script
  /// waits for the text the user types.
  waitingImage,

  /// `java.openUrl`: the confirmed page is shown and the script continues.
  ///
  /// The frozen member hands the URL to the system browser
  /// (`OpenUrlConfirmActivity`); this product has no external-opening path, so
  /// the page is the same in-app one `java.startBrowser` shows. Recorded
  /// divergence.
  openUrl,
}

/// Everything one hatch asks the user to look at, as the surface receives it.
///
/// The confirmation names the source ([sourceName], falling back to
/// [sourceRef]) and what it wants to show; the surface must not show anything
/// before the user has agreed, which is why this object carries the page's own
/// inputs rather than a ready-made view of them.
class SourceHatchRequest {
  const SourceHatchRequest({
    required this.member,
    required this.kind,
    required this.sourceRef,
    required this.sourceName,
    required this.url,
    this.title = '',
    this.headers = const {},
    this.refetchAfterSuccess = true,
    this.fetchImage,
    this.onPageCookies,
  });

  /// The frozen member's name (`java.startBrowser`), which the source log, the
  /// refusal and the wait's failure all report.
  final String member;

  final SourceHatchKind kind;

  /// The source this hatch belongs to: its `bookSourceUrl`.
  final String sourceRef;

  /// The source's name for the confirmation, empty when the caller has none.
  final String sourceName;

  /// The page or image address, normalized the way the frozen `AnalyzeUrl`
  /// normalizes it: the text before the first `,{…}` option tail, with the
  /// tail's headers merged into [headers]. The frozen `WebViewActivity` loads
  /// and names that address, not the script's raw argument.
  final String url;

  /// The page title the source passed (`startBrowser*`), or empty.
  final String title;

  /// The source's header map with the login header and the option tail's own
  /// headers — the frozen `WebViewActivity`'s `headerMap`, so the confirmed page
  /// speaks with the source's session, and the image request the same.
  final Map<String, String> headers;

  /// The frozen third argument of `startBrowserAwait`: with it, the answer is a
  /// fresh HTTP GET of [url] rather than the page's own HTML, so the surface
  /// only has to read the page's HTML when it is false.
  final bool refetchAfterSuccess;

  /// Fetches the verification-code image through the source's own request path
  /// (its headers, its cookie jar and its `concurrentRate`), for the surface to
  /// call once the user has agreed. Null for every kind but
  /// [SourceHatchKind.waitingImage].
  final Future<SourceHatchImage> Function()? fetchImage;

  /// Receives the cookies the confirmed page left in the platform's cookie
  /// store for [pageUrl], the write the frozen `WebViewActivity.onPageFinished`
  /// makes for the source's key (`CookieStore.setCookie`). That write is what
  /// makes the session the user just established reach
  /// `startBrowserAwait`'s refetch and the source's later requests; the
  /// surface hands over the platform store's string form of them.
  final Future<void> Function(String pageUrl, String cookies)? onPageCookies;

  /// Whether the source's execution parks until the user answers.
  bool get waits =>
      kind == SourceHatchKind.waitingPage ||
      kind == SourceHatchKind.waitingImage;
}

/// The verification-code image one source request produced, or the failure that
/// request met. A failed image is not a failed hatch: the frozen dialog shows a
/// placeholder and still takes the user's answer.
class SourceHatchImage {
  const SourceHatchImage(this.bytes) : failure = '';
  const SourceHatchImage.failed(this.failure) : bytes = null;

  /// The image's bytes, or null when the request failed.
  final Uint8List? bytes;

  /// The failure in plain words, empty when the bytes are there.
  final String failure;
}

/// The wait's end: the 5-minute absolute cap or the analysis's cancellation
/// fires [end], and the surface closes what it shows so no page outlives the
/// wait that was waiting for it.
class SourceHatchStop {
  final _ended = Completer<void>();

  /// Completes when the wait ended without the user's answer.
  Future<void> get ended => _ended.future;

  /// Whether the wait has already ended, so a surface can tell without waiting
  /// whether showing anything is still meaningful.
  bool get isEnded => _ended.isCompleted;

  void end() {
    if (!_ended.isCompleted) _ended.complete();
  }
}

/// What the user did at a hatch.
enum SourceHatchOutcome {
  /// The confirmation was refused (or never answered): nothing was opened.
  refused,

  /// A non-waiting member's confirmed page is on screen and the script
  /// continues.
  presented,

  /// The user finished the confirmed page or image; [SourceHatchAnswer.text] is
  /// what it produced (the page's HTML, or the code the user typed).
  answered,

  /// The user closed the surface without answering: the frozen dialog-close
  /// result, an empty answer.
  closed,

  /// The wait ended without the user: the cap or the analysis's cancellation.
  /// The runtime tells the two apart by its own cancellation token.
  ended,
}

/// What a hatch interaction produced.
class SourceHatchAnswer {
  const SourceHatchAnswer(this.outcome, [this.text = '']);

  /// The user finished the surface with [text] — the page's own HTML, or the
  /// code the user typed.
  const SourceHatchAnswer.answered(this.text)
    : outcome = SourceHatchOutcome.answered;

  static const refused = SourceHatchAnswer(SourceHatchOutcome.refused);
  static const presented = SourceHatchAnswer(SourceHatchOutcome.presented);
  static const closed = SourceHatchAnswer(SourceHatchOutcome.closed);
  static const ended = SourceHatchAnswer(SourceHatchOutcome.ended);

  final SourceHatchOutcome outcome;
  final String text;
}

/// The user-facing half of the hatches: the confirmation, the confirmed page or
/// image, and the answer the user gave.
///
/// The model layer owns the wait, its cap and the shape of the answer; a surface
/// owns only what the user sees. [installed] is the composition root's binding
/// (`lib/main.dart`), because the platform page reaches `dart:ui` and the gates,
/// the tools and the unit tests run on a plain Dart VM: a process with no
/// surface refuses the hatches by name instead of showing nothing at all, which
/// is also what makes "the default is refuse" structural rather than a
/// convention.
abstract interface class SourceHatchSurface {
  /// The surface the composition root installed, or null in a process with no
  /// window.
  static SourceHatchSurface? installed;

  /// Asks the user, then shows what the confirmation allowed and answers what
  /// the user did.
  ///
  /// The surface must call [SourceHatchRequest.fetchImage] only after the user
  /// agreed. It must close what it shows when [stop] fires, and a closed or
  /// unanswerable confirmation is a refusal.
  Future<SourceHatchAnswer> interact(
    SourceHatchRequest request,
    SourceHatchStop stop,
  );
}

/// The absolute cap on one hatch interaction (ADR 0011 §4).
///
/// The frozen wait has no total timeout at all (`SourceVerificationHelp.kt:29-58`
/// parks until the user answers), so this cap is a deliberate divergence: it is
/// what keeps a page no one answers from parking an analysis for ever. It bounds
/// the user interaction, not the script's own budget — the interaction is paused
/// against the execution's deadline while it runs.
const sourceHatchWaitCap = Duration(minutes: 5);

/// Runs one hatch interaction under [cap] and the analysis's cancellation, and
/// answers what the user did.
///
/// The cap and the cancellation both end the wait with
/// [SourceHatchOutcome.ended] and tell the surface to close what it shows, so a
/// user who never answers — or an analysis the user cancelled — cannot leave a
/// page behind or a source parked.
Future<SourceHatchAnswer> runSourceHatchInteraction({
  required SourceHatchSurface surface,
  required SourceHatchRequest request,
  required Duration cap,
  SourceCancellation? cancellation,
}) async {
  final stop = SourceHatchStop();
  final ended = Completer<void>();
  void end() {
    if (!ended.isCompleted) ended.complete();
  }

  final timer = Timer(cap, end);
  final unlisten = cancellation?.listen(end);
  final interaction = surface.interact(request, stop);
  // A wait that ends while the surface is still showing something abandons this
  // future; its failure must not become an unhandled asynchronous error.
  interaction.then<void>((_) {}, onError: (Object _) {});
  try {
    final result = await Future.any([
      interaction.then((answer) => (answer: answer, stopped: false)),
      ended.future.then((_) => (answer: SourceHatchAnswer.ended, stopped: true)),
    ]);
    if (!result.stopped) return result.answer;
    stop.end();
    return SourceHatchAnswer.ended;
  } finally {
    timer.cancel();
    unlisten?.call();
  }
}
