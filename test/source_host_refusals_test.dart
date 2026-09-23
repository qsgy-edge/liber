import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/source/js_source_runtime.dart';
import 'package:liber/source/native_library.dart';
import 'package:liber/source/source_notice.dart';
import 'package:liber/store/workspace.dart';

import 'native_library.dart';

import 'l10n_support.dart';

void main() {
  group('SourceNoticeLimiter', () {
    test('delivers the first notice and suppresses the window', () {
      final limiter = SourceNoticeLimiter();
      expect(limiter.allows(1000), isTrue);
      expect(limiter.allows(1000), isFalse);
      expect(limiter.allows(1000 + sourceNoticeWindowMillis - 1), isFalse);
      expect(limiter.allows(1000 + sourceNoticeWindowMillis), isTrue);
    });
  });

  testWidgets('a source notice is shown as one capped line', (tester) async {
    late BuildContext context;
    await tester.pumpWidget(
      localizedApp(
        home: Builder(
          builder: (buildContext) {
            context = buildContext;
            return const Scaffold(body: SizedBox());
          },
        ),
      ),
    );
    showSourceNotice(
      context,
      SourceHostMessage('toast', 'line one\nline two  ${'x' * 400}'),
    );
    await tester.pump();
    final shown = tester.widget<Text>(
      find.descendant(of: find.byType(SnackBar), matching: find.byType(Text)),
    );
    expect(shown.data, isNot(contains('\n')));
    expect(shown.data, hasLength(maxSourceNoticeChars + 1));
  });

  group('installation androidId', () {
    test('is generated once, persisted, and stable across a restart', () async {
      final directory = await Directory.systemTemp.createTemp(
        'liber-android-id-',
      );
      try {
        final first = await Workspace.open(root: directory);
        final id = await first.androidId();
        // The frozen `AppConst.androidId` shape: 16 lowercase hex characters
        // (`AppConst.kt:58-60`), opaque and per install (ADR 0011 §6).
        expect(id, matches(RegExp(r'^[0-9a-f]{16}$')));
        await first.close();
        final second = await Workspace.open(root: directory);
        expect(await second.androidId(), id);
        await second.close();
      } finally {
        await directory.delete(recursive: true);
      }
    });
  });

  group('InProcessSourceScriptRuntime host surface', () {
    setUpAll(() => NativeLibrary.initialize(libraryPath: nativeLibraryPath()));
    tearDownAll(NativeLibrary.dispose);

    Future<Object?> evaluate(
      InProcessSourceScriptRuntime runtime,
      String script, {
      String sourceKey = 'https://a.test/source',
    }) => runtime.evaluate(
      source: script,
      input: {
        'sourceKey': sourceKey,
        'source': {'bookSourceUrl': sourceKey},
      },
      timeout: const Duration(seconds: 15),
    );

    test('a deferred member refuses by name and writes the reason to the log', () async {
      final runtime = InProcessSourceScriptRuntime();
      await expectLater(
        evaluate(runtime, 'java.getFile("/tmp/x")'),
        throwsA(
          isA<SourceScriptError>()
              .having((error) => error.category, 'category', 'policy')
              .having((error) => error.message, 'message', contains('java.getFile'))
              .having((error) => error.message, 'message', contains('deferred')),
        ),
      );
      expect(runtime.messages, hasLength(1));
      expect(runtime.messages.single.kind, 'refused');
      expect(runtime.messages.single.message, contains('java.getFile'));
    });

    test('androidId is the installation value for two sources', () async {
      const id = '0123456789abcdef';
      final runtime = InProcessSourceScriptRuntime(androidId: id);
      expect(await evaluate(runtime, 'java.androidId()'), id);
      expect(
        await evaluate(
          runtime,
          'java.androidId()',
          sourceKey: 'https://b.test/source',
        ),
        id,
      );
      final userAgent = await evaluate(runtime, 'java.getWebViewUA()');
      expect(userAgent, isA<String>());
      expect(userAgent as String, isNotEmpty);
      expect(userAgent, startsWith('Mozilla/5.0'));
    });

    test('the log is bounded and toasts are delivered rate-limited', () async {
      final notices = <SourceHostMessage>[];
      final runtime = InProcessSourceScriptRuntime(
        onMessage: (message) => notices.add(message),
      );
      await evaluate(
        runtime,
        'for (let i = 0; i < ${sourceMessageLogLimit + 10}; i++) java.toast("t" + i);',
      );
      expect(runtime.messages, hasLength(sourceMessageLogLimit));
      expect(runtime.messages.first.message, 't10');
      expect(runtime.messages.last.message, 't${sourceMessageLogLimit + 9}');
      expect(notices, hasLength(1));
      expect(notices.single.message, 't0');
    });
  });
}
