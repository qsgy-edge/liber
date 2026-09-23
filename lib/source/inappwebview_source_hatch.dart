import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'inappwebview_book_source_adapter.dart';
import 'source_hatch.dart';

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
    if (!await showSourceHatchConfirmation(context, request)) {
      return SourceHatchAnswer.refused;
    }
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
Future<bool> showSourceHatchConfirmation(
  BuildContext context,
  SourceHatchRequest request,
) async {
  final name = request.sourceName.isEmpty
      ? request.sourceRef
      : request.sourceName;
  final image = request.kind == SourceHatchKind.waitingImage;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(image ? '书源请求显示验证码图片' : '书源请求在应用内显示页面'),
      content: SelectableText(
        '书源“$name”请求${image ? '显示下面的验证码图片' : '在应用内打开下面的地址'}：\n\n'
        '${request.url}\n\n'
        '${request.waits ? '书源会一直等待你的操作，最长 5 分钟。' : '页面显示后，书源不会等待。'}\n'
        '页面或图片由该书源指定，可能看起来像该网站的登录页。只有你信任该书源时才继续。',
      ),
      actions: [
        TextButton(
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(image ? '显示图片' : '打开页面'),
        ),
      ],
    ),
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
      builder: (context) => AlertDialog(
        title: const Text('验证码'),
        content: SizedBox(
          width: 360,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('书源：$name'),
                const SizedBox(height: 8),
                if (image.bytes != null)
                  Image.memory(
                    Uint8List.fromList(image.bytes!),
                    key: const ValueKey('hatch-image'),
                  )
                else
                  Text(
                    '图片加载失败：${image.failure}',
                    key: const ValueKey('hatch-image-failure'),
                  ),
                const SizedBox(height: 8),
                SelectableText(request.url),
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('hatch-code'),
                  controller: controller,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: '验证结果'),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.of(context).pop(SourceHatchAnswer.closed),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(
              context,
            ).pop(SourceHatchAnswer(SourceHatchOutcome.answered, controller.text)),
            child: const Text('确定'),
          ),
        ],
      ),
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
        title: Text(_title.isEmpty ? '书源页面' : _title),
        actions: [
          if (request.waits)
            TextButton(
              key: const ValueKey('hatch-page-done'),
              onPressed: _submit,
              child: const Text('完成'),
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
        onLoadStop: (controller, url) async {
          final title = await controller.getTitle();
          if (!mounted) return;
          setState(() {
            if (title != null && title.isNotEmpty) _title = title;
          });
        },
      ),
    );
  }

  static String? _userAgent(SourceHatchRequest request) {
    for (final entry in request.headers.entries) {
      if (entry.key.toLowerCase() == 'user-agent') return entry.value;
    }
    return null;
  }
}
