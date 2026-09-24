import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/book_source_service.dart';
import 'package:liber/source/book_source_webview_adapter.dart';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/inappwebview_source_hatch.dart';
import 'package:liber/source/source_hatch.dart';
import 'package:liber/source/native_library.dart';
import 'package:liber/source/source_host_state.dart';
import 'package:liber/source/source_tls_confirmation.dart';

import 'l10n_support.dart';
import 'native_library.dart';

/// ADR 0011 §5 on the WebView paths (#75).
///
/// The rendered stage's certificate failure is the transport's own
/// [SourceTlsCertificateFailure], so the same confirmation the `dart:io` path
/// shows asks once, remembers the exception for that source and host, and the
/// retried render proceeds through the certificate. The visible confirmed page
/// reaches the same confirmation and the same stored row.
const _sourceRef = 'https://a.test/book';
const _host = 'a.test';
const _renderedBook =
    '<div class="item"><h3><a href="/book/1">渲染的书</a></h3></div>';

Map<String, dynamic> _renderedSearchSource() => {
  'bookSourceUrl': _sourceRef,
  'bookSourceName': 'A 书源',
  'searchUrl':
      '/search?key={{key}},{"webView":true,"webJs":"document.body.innerText"}',
  'ruleSearch': {
    'bookList': 'class.item',
    'name': 'tag.h3@tag.a@text',
    'bookUrl': 'tag.a@href',
  },
};

/// The rendered stage as the fixed adapter reports it: the engine's trust
/// callback rejects a host no stored exception allows, with the failure the
/// model layer names, and renders the page once the exception is stored.
///
/// The gate is [BookSourceWebViewAdapterFactory.allowsInvalidCertificate], the
/// method the native adapter's `onReceivedServerTrustAuthRequest` consults, so
/// the rows bind the store's decision to the render rather than to a stub of
/// their own.
class _TlsGateAdapter implements BookSourceWebViewAdapter {
  _TlsGateAdapter(this._scope);

  final _TlsGateFactory _scope;

  @override
  Future<SourceWebViewResponse> load(SourceWebViewRequest request) async {
    if (!_scope.allowsInvalidCertificate(_host)) {
      throw sourceWebViewUntrustedCertificateFailure(
        sourceRef: _scope.sourceRef,
        host: _host,
      );
    }
    return SourceWebViewResponse.page(request.url!, _renderedBook);
  }

  @override
  void destroy() {}

  @override
  bool get isDisposed => false;

  @override
  bool get hasWebView => true;
}

class _TlsGateFactory extends BookSourceWebViewAdapterFactory {
  _TlsGateFactory({required super.sourceRef, required super.hostState});

  /// One adapter per render attempt, as the pipeline creates one per operation.
  int attempts = 0;

  @override
  BookSourceWebViewAdapter create() {
    attempts++;
    return _TlsGateAdapter(this);
  }
}

/// A transport the rendered stage must not be asked for.
class _Pages implements BookSourceTransport {
  final requests = <String>[];

  @override
  Future<String> request({
    required BookSourceStage stage,
    required String path,
  }) async {
    requests.add(path);
    throw StateError('the rendered stage must not use the transport');
  }
}

void main() {
  setUpAll(() => NativeLibrary.initialize(libraryPath: nativeLibraryPath()));
  tearDownAll(NativeLibrary.dispose);

  /// Runs one rendered WebView stage under [withTlsExceptionConfirmation], the
  /// way the pages that show sources do.
  ///
  /// The stage is the adapter's own [BookSourceWebViewAdapter.load]; the real
  /// pipeline's rule adapter is Rust, and a widget test's binding never settles
  /// its pending work, so the pipeline itself is driven by the plain rows below.
  Future<void> pumpRenderedStage(
    WidgetTester tester, {
    required SourceHostState state,
    required _TlsGateFactory factory,
    required void Function(String? body, Object? error) onDone,
  }) async {
    await tester.pumpWidget(
      localizedApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              try {
                final response = await withTlsExceptionConfirmation(
                  context: context,
                  hostState: state,
                  sourceRef: _sourceRef,
                  sourceName: 'A 书源',
                  run: () => factory.create().load(
                    SourceWebViewRequest(url: '$_sourceRef/search'),
                  ),
                );
                onDone(response.body, null);
              } catch (error) {
                onDone(null, error);
              }
            },
            child: const Text('run'),
          ),
        ),
      ),
    );
  }

  testWidgets(
    'a rendered certificate failure asks once, remembers and proceeds',
    (tester) async {
      final state = SourceHostState();
      final factory = _TlsGateFactory(sourceRef: _sourceRef, hostState: state);
      String? body;
      Object? error;
      await pumpRenderedStage(
        tester,
        state: state,
        factory: factory,
        onDone: (value, thrown) {
          body = value;
          error = thrown;
        },
      );

      await tester.tap(find.text('run'));
      await tester.pumpAndSettle();

      // The existing confirmation, with the existing copy: the source and the
      // host the engine rejected, and nothing stored yet.
      expect(find.text('证书校验失败'), findsOneWidget);
      expect(find.textContaining('A 书源'), findsOneWidget);
      expect(find.textContaining(_host), findsOneWidget);
      expect(state.allowsInvalidCertificate(_sourceRef, _host), isFalse);

      await tester.tap(find.text('继续（不安全）'));
      await tester.pumpAndSettle();

      // The exception is remembered and the operation re-ran: the second render
      // found it stored and returned the page, and the dialog is gone.
      expect(error, isNull);
      expect(body, _renderedBook);
      expect(factory.attempts, 2);
      expect(state.allowsInvalidCertificate(_sourceRef, _host), isTrue);
      expect(find.text('证书校验失败'), findsNothing);
    },
  );

  testWidgets('declining leaves the rendered failure named and stores nothing', (
    tester,
  ) async {
    final state = SourceHostState();
    final factory = _TlsGateFactory(sourceRef: _sourceRef, hostState: state);
    String? body;
    Object? error;
    await pumpRenderedStage(
      tester,
      state: state,
      factory: factory,
      onDone: (value, thrown) {
        body = value;
        error = thrown;
      },
    );

    await tester.tap(find.text('run'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(body, isNull);
    expect(error, isA<SourceTlsCertificateFailure>());
    expect(factory.attempts, 1);
    expect(state.allowsInvalidCertificate(_sourceRef, _host), isFalse);
  });

  testWidgets('a remembered exception is not asked about again', (tester) async {
    final state = SourceHostState();
    await state.allowInvalidCertificate(_sourceRef, _host);
    final factory = _TlsGateFactory(sourceRef: _sourceRef, hostState: state);
    String? body;
    Object? error;
    await pumpRenderedStage(
      tester,
      state: state,
      factory: factory,
      onDone: (value, thrown) {
        body = value;
        error = thrown;
      },
    );

    await tester.tap(find.text('run'));
    await tester.pumpAndSettle();

    expect(error, isNull);
    expect(body, _renderedBook);
    expect(factory.attempts, 1);
    expect(find.text('证书校验失败'), findsNothing);
  });

  test('the rendered pipeline reports the certificate failure by name', () async {
    final state = SourceHostState();
    final pipeline = HtmlSourcePipeline(
      _renderedSearchSource(),
      _Pages(),
      hostState: state,
      webViewFactory: _TlsGateFactory(
        sourceRef: _sourceRef,
        hostState: state,
      ),
    );

    // Nothing between the adapter and the caller renames or swallows it: the
    // failure the confirmation catches is the failure the stage raised, with the
    // source, the host and the plain-words reason it carries.
    await expectLater(
      pipeline.search('keyword'),
      throwsA(
        isA<SourceTlsCertificateFailure>()
            .having((error) => error.sourceRef, 'sourceRef', _sourceRef)
            .having((error) => error.host, 'host', _host)
            .having(
              (error) => error.reason,
              'reason',
              SourceTlsCertificateFailure.unspecifiedReason,
            ),
      ),
    );
  });

  test('a stored exception lets the rendered pipeline render', () async {
    final state = SourceHostState();
    await state.allowInvalidCertificate(_sourceRef, _host);
    final factory = _TlsGateFactory(sourceRef: _sourceRef, hostState: state);
    final pipeline = HtmlSourcePipeline(
      _renderedSearchSource(),
      _Pages(),
      hostState: state,
      webViewFactory: factory,
    );

    final hits = await pipeline.search('keyword');
    expect(hits.single.title, '渲染的书');
    expect(factory.attempts, 1);
  });

  group('the headless callback decision', () {
    // The challenged host is not the source's own host: the decision must report
    // and store the host the engine named, not the one the source was written for.
    const challengedHost = 'cdn.a.test';

    /// Runs the production decision with recording effects.
    ({SourceWebViewTrustDecision decision, List<Object> failures, int destroys})
    decide(BookSourceWebViewAdapterFactory factory, {String host = challengedHost}) {
      final failures = <Object>[];
      var destroys = 0;
      final decision = sourceWebViewTrustDecision(
        scope: factory,
        host: host,
        fail: failures.add,
        destroy: () => destroys++,
      );
      return (decision: decision, failures: failures, destroys: destroys);
    }

    test('no stored exception refuses the challenge and fails the operation', () {
      final factory = BookSourceWebViewAdapterFactory(
        sourceRef: _sourceRef,
        hostState: SourceHostState(),
      );

      final outcome = decide(factory);

      expect(outcome.decision, SourceWebViewTrustDecision.refuse);
      expect(outcome.destroys, 1);
      final failure = outcome.failures.single;
      expect(
        failure,
        isA<SourceTlsCertificateFailure>()
            .having((error) => error.sourceRef, 'sourceRef', _sourceRef)
            .having((error) => error.host, 'host', challengedHost)
            .having(
              (error) => error.reason,
              'reason',
              SourceTlsCertificateFailure.unspecifiedReason,
            ),
      );
    });

    test('a stored exception proceeds and reports nothing', () async {
      final state = SourceHostState();
      await state.allowInvalidCertificate(_sourceRef, challengedHost);
      final factory = BookSourceWebViewAdapterFactory(
        sourceRef: _sourceRef,
        hostState: state,
      );

      final outcome = decide(factory);

      expect(outcome.decision, SourceWebViewTrustDecision.proceed);
      expect(outcome.failures, isEmpty);
      expect(outcome.destroys, 0);
    });

    test('the exception is per source and host, not per source', () async {
      final state = SourceHostState();
      await state.allowInvalidCertificate(_sourceRef, 'other.test');
      final factory = BookSourceWebViewAdapterFactory(
        sourceRef: _sourceRef,
        hostState: state,
      );

      final outcome = decide(factory);

      expect(outcome.decision, SourceWebViewTrustDecision.refuse);
      expect(outcome.destroys, 1);
      expect(
        (outcome.failures.single as SourceTlsCertificateFailure).host,
        challengedHost,
      );
    });
  });

  group('the visible confirmed page', () {
    /// The hatch's own request: the page the user confirmed, for this source and
    /// the space's host state.
    SourceHatchRequest hatchRequest(SourceHostState? state) => SourceHatchRequest(
      member: 'java.startBrowser',
      kind: SourceHatchKind.page,
      sourceRef: _sourceRef,
      sourceName: 'A 书源',
      url: 'https://$_host/verify',
      hostState: state,
    );

    /// Runs the page's certificate decision through the hatch's own function, the
    /// way its server-trust callback does.
    Future<void> pumpPageDecision(
      WidgetTester tester, {
      required SourceHostState? state,
      required void Function(bool allowed) onDone,
    }) async {
      final request = hatchRequest(state);
      await tester.pumpWidget(
        localizedApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async => onDone(
                await confirmHatchPageCertificate(
                  context,
                  request: request,
                  host: _host,
                ),
              ),
              child: const Text('load'),
            ),
          ),
        ),
      );
    }

    testWidgets('asks with the same dialog and remembers on continue', (
      tester,
    ) async {
      final state = SourceHostState();
      bool? allowed;
      await pumpPageDecision(
        tester,
        state: state,
        onDone: (value) => allowed = value,
      );

      await tester.tap(find.text('load'));
      await tester.pumpAndSettle();
      // The dialog names the hatch's own source and the challenged host.
      expect(find.text('证书校验失败'), findsOneWidget);
      expect(find.textContaining('A 书源'), findsOneWidget);
      expect(find.textContaining(_host), findsOneWidget);

      await tester.tap(find.text('继续（不安全）'));
      await tester.pumpAndSettle();
      expect(allowed, isTrue);
      expect(state.allowsInvalidCertificate(_sourceRef, _host), isTrue);
    });

    testWidgets('a stored exception proceeds without asking', (tester) async {
      final state = SourceHostState();
      await state.allowInvalidCertificate(_sourceRef, _host);
      bool? allowed;
      await pumpPageDecision(
        tester,
        state: state,
        onDone: (value) => allowed = value,
      );

      await tester.tap(find.text('load'));
      await tester.pumpAndSettle();
      expect(allowed, isTrue);
      expect(find.text('证书校验失败'), findsNothing);
    });

    testWidgets('a refusal cancels the load and stores nothing', (tester) async {
      final state = SourceHostState();
      bool? allowed;
      await pumpPageDecision(
        tester,
        state: state,
        onDone: (value) => allowed = value,
      );

      await tester.tap(find.text('load'));
      await tester.pumpAndSettle();
      // Dismissing the barrier is the dialog's default, a refusal.
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(allowed, isFalse);
      expect(state.allowsInvalidCertificate(_sourceRef, _host), isFalse);
    });

    testWidgets('a process with no host state refuses without asking', (
      tester,
    ) async {
      bool? allowed;
      await pumpPageDecision(
        tester,
        state: null,
        onDone: (value) => allowed = value,
      );

      await tester.tap(find.text('load'));
      await tester.pumpAndSettle();
      // There is no store to remember an answer in, so the page is not let
      // through on an answer that outlives nothing.
      expect(allowed, isFalse);
      expect(find.text('证书校验失败'), findsNothing);
    });
  });
}
