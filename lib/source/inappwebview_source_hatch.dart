import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../l10n/app_localizations.dart';
import 'book_source_webview_adapter.dart'
    show sourceWebViewUntrustedCertificateFailure;
import 'inappwebview_book_source_adapter.dart';
import 'source_hatch.dart';
import 'source_tls_confirmation.dart';

/// The navigator the confirmed pages are pushed on. The composition root hands
/// it to `MaterialApp` (`lib/main.dart`), because a hatch happens inside a source
/// execution rather than in a page's own event handler, so the surface has no
/// `BuildContext` of its own.
final sourceHatchNavigatorKey = GlobalKey<NavigatorState>();

/// Installs the user-confirmed hatch surface as the model layer's binding.
///
/// Called once by the application entry point next to the WebView adapter
/// binding; every other process reaches the hatches with no confirmation to ask
/// and refuses them by name (ADR 0011 §4).
void installInAppWebViewSourceHatch() {
  SourceHatchSurface.installed = InAppWebViewSourceHatch();
}

/// The user-confirmed hatches as a person meets them: a confirmation naming the
/// source and the address, then the page or the image, then the answer.
///
/// The page is the same platform engine the headless adapter drives (ADR 0003),
/// shown in a route the user can close; it is not a second browser engine and it
/// is not the system browser, which this product deliberately does not use
/// (recorded divergence, ADR 0011 §4).
class InAppWebViewSourceHatch implements SourceHatchSurface {
  @override
  Future<SourceHatchAnswer> interact(
    SourceHatchRequest request,
    SourceHatchStop stop,
  ) async {
    final context = sourceHatchNavigatorKey.currentContext;
    if (context == null || !context.mounted) return SourceHatchAnswer.refused;
    // A wait that has already ended (its cap, or the analysis the user
    // cancelled) shows nothing at all: the confirmation included.
    if (stop.isEnded) return SourceHatchAnswer.refused;
    if (!await showSourceHatchConfirmation(context, request, stop: stop)) {
      return SourceHatchAnswer.refused;
    }
    // The wait can end while the user is deciding; the answer is already the
    // cap's or the cancellation's, and nothing must be shown for it.
    if (stop.isEnded) return SourceHatchAnswer.refused;
    return switch (request.kind) {
      SourceHatchKind.waitingImage => _showImage(request, stop),
      SourceHatchKind.waitingPage => _showPage(request, stop),
      SourceHatchKind.page || SourceHatchKind.openUrl => _presentPage(request),
    };
  }

  /// Shows the confirmed page and waits for the user to finish with it.
  Future<SourceHatchAnswer> _showPage(
    SourceHatchRequest request,
    SourceHatchStop stop,
  ) async {
    final navigator = sourceHatchNavigatorKey.currentState;
    if (navigator == null) return SourceHatchAnswer.closed;
    final answer = await navigator.push<SourceHatchAnswer>(
      MaterialPageRoute<SourceHatchAnswer>(
        builder: (context) => SourceHatchPage(request: request, stop: stop),
      ),
    );
    return answer ?? SourceHatchAnswer.closed;
  }

  /// Shows the confirmed page without waiting, which is the frozen
  /// `startBrowser`/`openUrl` shape: the source's script goes on, and the page
  /// is a route of its own that the user closes when they are done — as the
  /// frozen activity outlives the analysis that opened it.
  Future<SourceHatchAnswer> _presentPage(SourceHatchRequest request) async {
    final navigator = sourceHatchNavigatorKey.currentState;
    if (navigator == null) return SourceHatchAnswer.refused;
    unawaited(
      navigator.push<void>(
        MaterialPageRoute<void>(
          builder: (context) => SourceHatchPage(request: request),
        ),
      ),
    );
    return SourceHatchAnswer.presented;
  }

  /// Fetches the image the user agreed to see and asks for the code.
  Future<SourceHatchAnswer> _showImage(
    SourceHatchRequest request,
    SourceHatchStop stop,
  ) async {
    final context = sourceHatchNavigatorKey.currentContext;
    if (context == null || !context.mounted) return SourceHatchAnswer.closed;
    // The image is fetched only now, after the confirmation: the request carries
    // the source's own headers and cookies, so it is the user's agreement that
    // lets the fetch happen.
    final image = await request.fetchImage!();
    if (!context.mounted) return SourceHatchAnswer.closed;
    return await showSourceHatchImageDialog(
      context,
      request: request,
      image: image,
      stop: stop,
    );
  }
}

/// The confirmation one hatch asks before anything is shown.
///
/// It names the source and the address, states whether the source will wait, and
/// defaults to refusing: 取消 carries the focus, so Escape, Enter and a tap
/// outside all mean "do not show this".
///
/// With a [stop], the wait's end dismisses the confirmation as a refusal: a
/// source that has stopped waiting (its cap, or an analysis the user cancelled)
/// must not still be asking whether its page may be shown.
Future<bool> showSourceHatchConfirmation(
  BuildContext context,
  SourceHatchRequest request, {
  SourceHatchStop? stop,
}) async {
  final name = request.sourceName.isEmpty
      ? request.sourceRef
      : request.sourceName;
  final image = request.kind == SourceHatchKind.waitingImage;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) {
      if (stop != null) {
        unawaited(
          stop.ended.then((_) {
            if (context.mounted) Navigator.of(context).pop(false);
          }),
        );
      }
      final l10n = AppLocalizations.of(context);
      final wait = request.waits ? l10n.hatchWaits : l10n.hatchDoesNotWait;
      return AlertDialog(
        title: Text(image ? l10n.hatchImageTitle : l10n.hatchPageTitle),
        content: SelectableText(
          image
              ? l10n.hatchPageBodyImage(name, request.url, wait)
              : l10n.hatchPageBodyPage(name, request.url, wait),
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(image ? l10n.hatchShowImage : l10n.hatchOpenPage),
          ),
        ],
      );
    },
  );
  return confirmed ?? false;
}

/// The verification-code dialog: the fetched image, the source it belongs to and
/// a field for the user's answer.
///
/// A blank answer or a closed dialog is the frozen empty result, which the
/// caller reports as 验证结果为空.
Future<SourceHatchAnswer> showSourceHatchImageDialog(
  BuildContext context, {
  required SourceHatchRequest request,
  required SourceHatchImage image,
  required SourceHatchStop stop,
}) async {
  final controller = TextEditingController();
  final name = request.sourceName.isEmpty
      ? request.sourceRef
      : request.sourceName;
  unawaited(
    stop.ended.then((_) {
      if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    }),
  );
  try {
    final answer = await showDialog<SourceHatchAnswer>(
      context: context,
      builder: (context) {
        final l10n = AppLocalizations.of(context);
        return AlertDialog(
          title: Text(l10n.hatchCodeTitle),
          content: SizedBox(
            width: 360,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l10n.hatchSource(name)),
                  const SizedBox(height: 8),
                  if (image.bytes != null)
                    Image.memory(
                      Uint8List.fromList(image.bytes!),
                      key: const ValueKey('hatch-image'),
                    )
                  else
                    Text(
                      l10n.hatchImageFailed(image.failure),
                      key: const ValueKey('hatch-image-failure'),
                    ),
                  const SizedBox(height: 8),
                  SelectableText(request.url),
                  const SizedBox(height: 12),
                  TextField(
                    key: const ValueKey('hatch-code'),
                    controller: controller,
                    autofocus: true,
                    decoration: InputDecoration(labelText: l10n.hatchAnswer),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () =>
                  Navigator.of(context).pop(SourceHatchAnswer.closed),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(
                SourceHatchAnswer(SourceHatchOutcome.answered, controller.text),
              ),
              child: Text(l10n.confirm),
            ),
          ],
        );
      },
    );
    return answer ?? SourceHatchAnswer.closed;
  } finally {
    controller.dispose();
  }
}

/// One confirmed page: the platform engine in a route the user can close.
///
/// With a [stop] the page is the answer's surface — 完成 hands the page's own
/// HTML back when the source asked for it, closing it is the frozen empty result
/// — and the route is torn down when the wait ends. Without one it is a page the
/// script is not waiting for, which is `java.startBrowser` and `java.openUrl`.
class SourceHatchPage extends StatefulWidget {
  const SourceHatchPage({super.key, required this.request, this.stop});

  final SourceHatchRequest request;
  final SourceHatchStop? stop;

  @override
  State<SourceHatchPage> createState() => _SourceHatchPageState();
}

class _SourceHatchPageState extends State<SourceHatchPage> {
  InAppWebViewController? _controller;
  late String _title = widget.request.title;

  @override
  void initState() {
    super.initState();
    widget.stop?.ended.then((_) => _close(SourceHatchAnswer.ended));
  }

  void _close(SourceHatchAnswer answer) {
    if (!mounted) return;
    Navigator.of(context).pop(answer);
  }

  /// The frozen `WebViewModel.saveVerificationResult` page half: the page's own
  /// `document.documentElement.outerHTML`, read only when the source asked for
  /// the page rather than for a refetch of the address.
  Future<void> _submit() async {
    final controller = _controller;
    var html = '';
    if (!widget.request.refetchAfterSuccess && controller != null) {
      try {
        final value = await controller.evaluateJavascript(
          source: 'document.documentElement.outerHTML',
        );
        if (value != null) html = value is String ? value : value.toString();
      } on Object {
        // A page that cannot be read is the empty result the frozen evaluation
        // fails into: the caller reports 验证结果为空 rather than a page body.
        html = '';
      }
    }
    _close(SourceHatchAnswer(SourceHatchOutcome.answered, html));
  }

  @override
  Widget build(BuildContext context) {
    final request = widget.request;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _title.isEmpty ? AppLocalizations.of(context).hatchPageRoute : _title,
        ),
        actions: [
          if (request.waits)
            TextButton(
              key: const ValueKey('hatch-page-done'),
              onPressed: _submit,
              child: Text(AppLocalizations.of(context).done),
            ),
          IconButton(
            key: const ValueKey('hatch-page-close'),
            onPressed: () => _close(SourceHatchAnswer.closed),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
      body: InAppWebView(
        initialUrlRequest: URLRequest(
          url: WebUri(request.url),
          // The same load-header rule the headless adapter applies: a `Cookie`
          // entry is dropped because the platform engine ignores one there, so
          // the first request never carries an app-supplied cookie.
          headers: inAppWebViewLoadHeaders(request.headers),
        ),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          domStorageEnabled: true,
          userAgent: _userAgent(request),
          mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
        ),
        onWebViewCreated: (controller) => _controller = controller,
        // ADR 0011 §5 reaches this visible page too: without the exception the
        // engine refuses the rejected certificate by default, and the stored
        // per-source, per-host exception is what lets the page load instead. The
        // user confirmed showing this page, not continuing past a rejected
        // certificate, so the decision is the same confirmation the headless
        // path reaches: a stored exception proceeds silently, and without one the
        // dialog asks and its answer is what the load follows.
        onReceivedServerTrustAuthRequest: (controller, challenge) async =>
            await _mayProceedThroughCertificate(
              challenge.protectionSpace.host,
            )
            ? ServerTrustAuthResponse(
                action: ServerTrustAuthResponseAction.PROCEED,
              )
            : ServerTrustAuthResponse(
                action: ServerTrustAuthResponseAction.CANCEL,
              ),
        onLoadStop: (controller, url) async {
          // The frozen `WebViewActivity.onPageFinished` writes what the page
          // received back into the source's own cookie store, which is what the
          // refetch and the source's later requests then carry. A navigation
          // that just finished is exactly the moment the frozen writes.
          await _writePageCookies(url?.toString() ?? request.url);
          final title = await controller.getTitle();
          if (!mounted) return;
          setState(() {
            if (title != null && title.isNotEmpty) _title = title;
          });
        },
      ),
    );
  }

  /// Whether this page may load [host] despite the certificate the engine
  /// rejected (ADR 0011 §5).
  ///
  /// The stored exception is read first, so a page whose source and host were
  /// already confirmed does not ask again; without one the shared confirmation
  /// asks and its "continue (unsafe)" answer stores the exception.
  Future<bool> _mayProceedThroughCertificate(String host) =>
      confirmTlsExceptionForPage(
        context: context,
        hostState: widget.request.hostState,
        sourceRef: widget.request.sourceRef,
        sourceName: widget.request.sourceName,
        failure: sourceWebViewUntrustedCertificateFailure(
          sourceRef: widget.request.sourceRef,
          host: host,
        ),
      );

  /// Hands the platform store's cookies for the finished page to the source's
  /// jar. A store this process cannot read leaves the jar as it was, exactly as
  /// the headless adapter's page-cookie write does.
  Future<void> _writePageCookies(String pageUrl) async {
    final sink = widget.request.onPageCookies;
    if (sink == null || pageUrl.isEmpty) return;
    try {
      await sink(pageUrl, await inAppWebViewPageCookies(pageUrl));
    } on Object {
      // A cookie store the platform refuses to read is not a reason to close the
      // page the user is working in.
    }
  }

  static String? _userAgent(SourceHatchRequest request) {
    for (final entry in request.headers.entries) {
      if (entry.key.toLowerCase() == 'user-agent') return entry.value;
    }
    return null;
  }
}
