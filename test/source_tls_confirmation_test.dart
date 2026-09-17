import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/source_host_state.dart';
import 'package:liber/source/source_tls_confirmation.dart';

/// ADR 0011 §5's confirmation, driven in process: it names the source and the
/// host, defaults to refusing, and only a confirmed "continue (unsafe)"
/// remembers the exception and retries.
void main() {
  const sourceRef = 'https://a.test/book';
  const failure = SourceTlsCertificateFailure(
    sourceRef: sourceRef,
    host: 'a.test',
    reason: '证书无效、过期或不受信任',
  );

  Future<void> pumpRun(
    WidgetTester tester, {
    required SourceHostState state,
    required Future<Object?> Function() run,
    required void Function(Object? result, Object? error) onDone,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              try {
                final value = await withTlsExceptionConfirmation<Object?>(
                  context: context,
                  hostState: state,
                  sourceRef: sourceRef,
                  sourceName: 'A 书源',
                  run: run,
                );
                onDone(value, null);
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
    'the dialog names the source and the host and defaults to refuse',
    (tester) async {
      final state = SourceHostState();
      var runs = 0;
      Object? result;
      Object? error;
      await pumpRun(
        tester,
        state: state,
        run: () async {
          runs++;
          throw failure;
        },
        onDone: (value, thrown) {
          result = value;
          error = thrown;
        },
      );

      await tester.tap(find.text('run'));
      await tester.pumpAndSettle();
      expect(find.text('证书校验失败'), findsOneWidget);
      expect(find.textContaining('A 书源'), findsOneWidget);
      expect(find.textContaining('a.test'), findsOneWidget);
      expect(find.textContaining('证书无效'), findsOneWidget);

      // 取消 is the default action: refusing leaves validation as it was.
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(result, isNull);
      expect(error, isA<SourceTlsCertificateFailure>());
      expect(runs, 1);
      expect(state.allowsInvalidCertificate(sourceRef, 'a.test'), isFalse);
    },
  );

  testWidgets('dismissing the barrier is a refusal', (tester) async {
    final state = SourceHostState();
    var runs = 0;
    Object? error;
    await pumpRun(
      tester,
      state: state,
      run: () async {
        runs++;
        throw failure;
      },
      onDone: (value, thrown) => error = thrown,
    );

    await tester.tap(find.text('run'));
    await tester.pumpAndSettle();
    // A tap outside the dialog settles it as `null`, which is a refusal.
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(error, isA<SourceTlsCertificateFailure>());
    expect(runs, 1);
    expect(state.allowsInvalidCertificate(sourceRef, 'a.test'), isFalse);
  });

  testWidgets('only 继续（不安全） remembers the exception and retries', (
    tester,
  ) async {
    final state = SourceHostState();
    var runs = 0;
    Object? result;
    await pumpRun(
      tester,
      state: state,
      run: () async {
        runs++;
        if (runs == 1) throw failure;
        return 'ok';
      },
      onDone: (value, error) => result = value,
    );

    await tester.tap(find.text('run'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('继续（不安全）'));
    await tester.pumpAndSettle();
    expect(result, 'ok');
    expect(runs, 2);
    expect(state.allowsInvalidCertificate(sourceRef, 'a.test'), isTrue);
  });
}
